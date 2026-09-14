import { Controller } from "@hotwired/stimulus"

const AUTH_CHECK_INTERVAL = 45_000
const ACTIVE_STATES = [ "connecting", "connected", "reconnecting" ]
let liveKitPromise

const loadLiveKit = () => liveKitPromise ||= import("livekit-client").catch(error => {
  liveKitPromise = null
  throw error
})

export default class extends Controller {
  static targets = [
    "activeControls", "leaveLabel", "mute", "muteLabel", "notice", "participantCount",
    "participantList", "people", "resumeAudio", "retry", "roomName", "screens", "share", "shareLabel", "status"
  ]
  static values = { currentUserId: Number }

  initialize() {
    this.room = null
    this.roomId = null
    this.roomName = null
    this.identity = null
    this.operation = 0
    this.state = "idle"
    this.roomListeners = new Map()
    this.attachments = new Map()
  }

  connect() {
    clearTimeout(this.disconnectTimer)

    this.abortController = new AbortController()
    const options = { signal: this.abortController.signal }

    window.addEventListener("huddle:join", this.join, options)
    window.addEventListener("huddle:query", this.broadcastState, options)
    window.addEventListener("pagehide", this.pageHiding, options)
    document.addEventListener("turbo:before-render", this.beforeRender, options)
    document.addEventListener("visibilitychange", this.visibilityChanged, options)

    this.#startAuthenticationChecks()
    this.#renderState()
  }

  disconnect() {
    this.abortController?.abort()

    // Turbo can briefly disconnect a permanent element while moving it into the
    // next page. Give Stimulus one turn to reconnect before treating it as gone.
    this.disconnectTimer = setTimeout(() => {
      if (!this.element.isConnected) this.#endForAuthenticationChange()
    }, 0)
  }

  join = async ({ detail }) => {
    const requestedRoomId = Number(detail?.roomId)
    const requestedRoomName = String(detail?.roomName || "Huddle")

    if (!Number.isInteger(requestedRoomId) || requestedRoomId <= 0) return
    if (!this.#signedInAsCurrentUser()) {
      this.#endForAuthenticationChange()
      return
    }

    if (this.roomId === requestedRoomId && ACTIVE_STATES.includes(this.state)) {
      this.element.hidden = false
      return
    }

    const operation = ++this.operation
    await this.#disconnectCurrentRoom()
    if (operation !== this.operation) return

    this.roomId = requestedRoomId
    this.roomName = requestedRoomName
    this.identity = null
    this.#setState("connecting", `Connecting to ${requestedRoomName}…`)

    let room

    try {
      const [ credentials, liveKit ] = await Promise.all([
        this.#requestCredentials(requestedRoomId),
        loadLiveKit()
      ])
      if (operation !== this.operation) return

      this.liveKit = liveKit
      this.roomName = credentials.room?.name || requestedRoomName
      this.identity = credentials.identity
      this.roomNameTarget.textContent = this.roomName

      room = new liveKit.Room({ adaptiveStream: true, dynacast: true })
      this.room = room
      this.#bindRoom(room)

      await room.connect(credentials.url, credentials.token, { autoSubscribe: true })
      if (operation !== this.operation || room !== this.room) {
        await this.#disconnectRoom(room)
        return
      }

      await room.startAudio().catch(() => {})
      await room.localParticipant.setMicrophoneEnabled(true)
      if (operation !== this.operation || room !== this.room) {
        await this.#disconnectRoom(room)
        return
      }

      this.#syncSubscribedTracks(room)
      this.#renderRoster()
      this.#setState("connected", "Huddle active")
      this.#updateMediaControls()
      this.#updateAudioPlaybackControl()
      this.#startAuthenticationChecks()
    } catch (error) {
      if (operation !== this.operation) {
        if (room) await this.#disconnectRoom(room)
        return
      }

      await this.#disconnectCurrentRoom()
      this.#setState("failed", this.#joinErrorMessage(error), true)
    }
  }

  retry() {
    if (!this.roomId) return

    this.join({ detail: { roomId: this.roomId, roomName: this.roomName } })
  }

  leave = async () => {
    ++this.operation
    await this.#disconnectCurrentRoom()
    this.roomId = null
    this.roomName = null
    this.identity = null
    this.#setState("idle", "Not in a huddle")
  }

  toggleMute = async () => {
    const room = this.room
    if (!room || this.state !== "connected" || this.muteTarget.disabled) return

    this.muteTarget.disabled = true
    try {
      await room.localParticipant.setMicrophoneEnabled(!room.localParticipant.isMicrophoneEnabled)
      if (room === this.room) {
        this.#updateMediaControls()
        this.#renderRoster()
      }
    } catch (error) {
      if (room === this.room) this.#showTemporaryStatus("The microphone could not be changed.")
    } finally {
      if (room === this.room) this.muteTarget.disabled = false
    }
  }

  toggleScreenShare = async () => {
    const room = this.room
    if (!room || this.state !== "connected" || this.shareTarget.disabled) return

    this.shareTarget.disabled = true
    const enabling = !room.localParticipant.isScreenShareEnabled

    try {
      await room.localParticipant.setScreenShareEnabled(enabling)

      if (room !== this.room) {
        await room.localParticipant.setScreenShareEnabled(false).catch(() => {})
        return
      }

      this.#syncLocalScreenShare(room)
      this.#updateMediaControls()
      this.#showTemporaryStatus(enabling ? "You’re sharing your screen" : "Screen sharing stopped")
    } catch (error) {
      if (room === this.room) {
        const message = this.#permissionWasDenied(error)
          ? "Screen sharing wasn’t started. Choose a screen and allow sharing to try again."
          : "Screen sharing could not be changed. Try again."
        this.#showTemporaryStatus(message)
        this.#updateMediaControls()
      }
    } finally {
      if (room === this.room) this.shareTarget.disabled = false
    }
  }

  resumeAudio = async () => {
    if (!this.room) return

    try {
      await this.room.startAudio()
    } finally {
      this.#updateAudioPlaybackControl()
    }
  }

  broadcastState = () => {
    window.dispatchEvent(new CustomEvent("huddle:changed", {
      detail: { roomId: this.roomId, state: this.state }
    }))
  }

  beforeRender = ({ detail }) => {
    const nextUserId = detail?.newBody?.ownerDocument
      ?.querySelector('meta[name="current-user-id"]')?.content

    if (String(nextUserId || "") !== String(this.currentUserIdValue)) {
      this.#endForAuthenticationChange()
    }
  }

  visibilityChanged = () => {
    if (document.visibilityState === "visible") this.#checkAuthentication()
  }

  pageHiding = () => {
    this.#endForAuthenticationChange()
  }

  #bindRoom(room) {
    const { RoomEvent } = this.liveKit
    const listeners = []
    const on = (event, handler) => {
      room.on(event, handler)
      listeners.push([ event, handler ])
    }

    on(RoomEvent.Reconnecting, () => {
      if (room === this.room) this.#setState("reconnecting", "Connection interrupted. Reconnecting…")
    })
    on(RoomEvent.Reconnected, () => {
      if (room === this.room) {
        this.#setState("connected", "Huddle active")
        this.#renderRoster()
        this.#updateMediaControls()
        this.#updateAudioPlaybackControl()
      }
    })
    on(RoomEvent.Disconnected, () => this.#unexpectedDisconnect(room))
    on(RoomEvent.ParticipantConnected, () => this.#renderRoster())
    on(RoomEvent.ParticipantDisconnected, (participant) => {
      for (const publication of participant.trackPublications.values()) {
        if (publication.track) this.#detachTrack(publication.track)
      }
      this.#renderRoster()
    })
    on(RoomEvent.ParticipantNameChanged, () => this.#renderRoster())
    on(RoomEvent.ActiveSpeakersChanged, () => this.#renderRoster())
    on(RoomEvent.TrackMuted, () => this.#renderRoster())
    on(RoomEvent.TrackUnmuted, () => this.#renderRoster())
    on(RoomEvent.TrackPublished, () => this.#renderRoster())
    on(RoomEvent.TrackUnpublished, (publication) => {
      if (publication.track) this.#detachTrack(publication.track)
      this.#renderRoster()
    })
    on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      this.#attachTrack(track, publication, participant)
      this.#renderRoster()
    })
    on(RoomEvent.TrackUnsubscribed, (track) => this.#detachTrack(track))
    on(RoomEvent.LocalTrackPublished, (publication, participant) => {
      if (publication.track) this.#attachTrack(publication.track, publication, participant)
      this.#renderRoster()
      this.#updateMediaControls()
    })
    on(RoomEvent.LocalTrackUnpublished, (publication) => {
      if (publication.track) this.#detachTrack(publication.track)
      this.#renderRoster()
      this.#updateMediaControls()
    })
    on(RoomEvent.AudioPlaybackStatusChanged, () => this.#updateAudioPlaybackControl())

    this.roomListeners.set(room, listeners)
  }

  #unbindRoom(room) {
    for (const [ event, handler ] of this.roomListeners.get(room) || []) room.off(event, handler)
    this.roomListeners.delete(room)
  }

  async #unexpectedDisconnect(room) {
    if (room !== this.room) return

    ++this.operation
    this.room = null
    this.#unbindRoom(room)
    this.#stopLocalTracks(room)
    this.#clearMedia()
    this.#stopAuthenticationChecks()
    this.#setState("failed", "The huddle ended because the connection was lost. Try joining again.", true)
  }

  async #disconnectCurrentRoom() {
    const room = this.room
    this.room = null
    this.#stopAuthenticationChecks()

    if (room) await this.#disconnectRoom(room)

    this.#clearMedia()
    this.#renderRoster()
  }

  async #disconnectRoom(room) {
    this.#unbindRoom(room)
    this.#stopLocalTracks(room)

    try {
      await room.disconnect(true)
    } catch (error) {
      // The media tracks are already stopped; there is nothing else to recover here.
    }
  }

  #stopLocalTracks(room) {
    for (const publication of room.localParticipant?.trackPublications?.values() || []) {
      publication.track?.stop()
    }
  }

  #syncSubscribedTracks(room) {
    for (const participant of room.remoteParticipants.values()) {
      for (const publication of participant.trackPublications.values()) {
        if (publication.track && publication.isSubscribed) {
          this.#attachTrack(publication.track, publication, participant)
        }
      }
    }

    this.#syncLocalScreenShare(room)
  }

  #syncLocalScreenShare(room) {
    const { Track } = this.liveKit

    for (const publication of room.localParticipant.trackPublications.values()) {
      if (publication.track && publication.source === Track.Source.ScreenShare) {
        this.#attachTrack(publication.track, publication, room.localParticipant)
      }
    }
  }

  #attachTrack(track, publication, participant) {
    const { Track } = this.liveKit

    if (this.attachments.has(track)) return

    if (track.kind === Track.Kind.Audio) {
      if (participant === this.room?.localParticipant) return

      const element = track.attach()
      element.autoplay = true
      element.hidden = true
      this.element.appendChild(element)
      this.attachments.set(track, { elements: [ element ] })
      return
    }

    const isScreenShare = publication.source === Track.Source.ScreenShare || track.source === Track.Source.ScreenShare
    if (track.kind !== Track.Kind.Video || !isScreenShare) return

    const figure = document.createElement("figure")
    figure.className = "huddle__screen"

    const video = track.attach()
    video.autoplay = true
    video.playsInline = true
    video.muted = participant === this.room?.localParticipant

    const caption = document.createElement("figcaption")
    caption.textContent = `${this.#participantName(participant)}${participant === this.room?.localParticipant ? " (you)" : ""} is sharing`

    figure.append(video, caption)
    this.screensTarget.appendChild(figure)
    this.screensTarget.hidden = false
    this.attachments.set(track, { elements: [ video ], wrapper: figure })
  }

  #detachTrack(track) {
    const attachment = this.attachments.get(track)

    try {
      for (const element of track.detach()) element.remove()
    } catch (error) {
      // A disconnect can detach the SDK track before this cleanup runs.
    }

    for (const element of attachment?.elements || []) element.remove()
    attachment?.wrapper?.remove()
    this.attachments.delete(track)
    this.screensTarget.hidden = !this.screensTarget.children.length
  }

  #clearMedia() {
    for (const track of [ ...this.attachments.keys() ]) this.#detachTrack(track)
    this.screensTarget.replaceChildren()
    this.screensTarget.hidden = true
  }

  #renderRoster() {
    this.participantListTarget.replaceChildren()

    if (!this.room) {
      this.participantCountTarget.textContent = "0 participants"
      return
    }

    const participants = [ this.room.localParticipant, ...this.room.remoteParticipants.values() ]
    const { Track } = this.liveKit
    participants.sort((left, right) => {
      if (left === this.room.localParticipant) return -1
      if (right === this.room.localParticipant) return 1
      return this.#participantName(left).localeCompare(this.#participantName(right))
    })

    for (const participant of participants) {
      const item = document.createElement("li")
      const name = document.createElement("span")
      const activity = document.createElement("span")
      const isLocal = participant === this.room.localParticipant
      const speaking = participant.isSpeaking
      const microphone = participant.getTrackPublication?.(Track.Source.Microphone)
      const muted = isLocal ? !participant.isMicrophoneEnabled : microphone?.isMuted
      const activityText = speaking ? "Speaking" : muted ? "Muted" : "Listening"

      item.className = "huddle__participant"
      item.classList.toggle("huddle__participant--speaking", speaking)
      item.setAttribute("aria-label", `${this.#participantName(participant)}, ${activityText}`)

      name.className = "huddle__participant-name overflow-ellipsis"
      name.textContent = this.#participantName(participant)
      if (isLocal) name.textContent += " (you)"

      activity.className = "huddle__participant-activity"
      activity.textContent = activityText

      item.append(name, activity)
      this.participantListTarget.appendChild(item)
    }

    const count = participants.length
    this.participantCountTarget.textContent = `${count} ${count === 1 ? "participant" : "participants"}`
  }

  #participantName(participant) {
    if (participant === this.room?.localParticipant) {
      return window.Current?.user?.name || participant.name || this.identity || "You"
    }

    return participant.name || participant.identity || "Participant"
  }

  #updateMediaControls() {
    if (!this.room) return

    const microphoneEnabled = this.room.localParticipant.isMicrophoneEnabled
    const screenShareEnabled = this.room.localParticipant.isScreenShareEnabled

    this.muteLabelTarget.textContent = microphoneEnabled ? "Mute" : "Unmute"
    this.muteTarget.setAttribute("aria-pressed", String(!microphoneEnabled))
    this.shareLabelTarget.textContent = screenShareEnabled ? "Stop sharing" : "Share screen"
    this.shareTarget.setAttribute("aria-pressed", String(screenShareEnabled))
  }

  #updateAudioPlaybackControl() {
    this.resumeAudioTarget.hidden = !this.room || this.room.canPlaybackAudio
  }

  #setState(state, message, isError = false) {
    this.state = state
    this.element.dataset.state = state
    this.element.hidden = state === "idle"
    this.roomNameTarget.textContent = this.roomName || "Huddle"
    this.statusTarget.textContent = isError ? "Couldn’t join huddle" : message
    this.noticeTarget.textContent = isError ? message : ""
    this.noticeTarget.hidden = !isError

    const connected = state === "connected"
    const reconnecting = state === "reconnecting"
    const failed = state === "failed"
    const connecting = state === "connecting"

    this.activeControlsTarget.hidden = !(connected || reconnecting)
    this.peopleTarget.hidden = !(connected || reconnecting)
    this.muteTarget.disabled = !connected
    this.shareTarget.disabled = !connected
    this.retryTarget.hidden = !failed
    this.leaveLabelTarget.textContent = connecting ? "Cancel" : failed ? "Close" : "Leave"
    this.resumeAudioTarget.hidden = true

    if (!connected && !reconnecting) this.#renderRoster()
    this.broadcastState()
  }

  #renderState() {
    if (this.state === "idle") {
      this.#setState("idle", "Not in a huddle")
    } else {
      this.element.hidden = false
      this.broadcastState()
    }
  }

  #showTemporaryStatus(message) {
    const stateAtStart = this.state
    const revision = (this.statusRevision || 0) + 1
    this.statusRevision = revision
    this.statusTarget.textContent = message

    setTimeout(() => {
      if (revision === this.statusRevision && this.state === stateAtStart && this.state === "connected") {
        this.statusTarget.textContent = "Huddle active"
      }
    }, 4_000)
  }

  async #requestCredentials(roomId) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (!csrfToken) throw new Error("missing-csrf-token")

    const response = await fetch(`/rooms/${encodeURIComponent(roomId)}/huddle`, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken
      },
      body: "{}"
    })

    let payload = {}
    try {
      payload = await response.json()
    } catch (error) {
      // The status-specific message below is more useful than a JSON parse error.
    }

    if (!response.ok) {
      const error = new Error(payload.error || payload.message || `request-failed-${response.status}`)
      error.status = response.status
      throw error
    }

    if (!payload.url || !payload.token) throw new Error("invalid-huddle-response")
    return payload
  }

  #startAuthenticationChecks() {
    if (!this.room || this.authenticationTimer) return

    this.authenticationTimer = setInterval(() => this.#checkAuthentication(), AUTH_CHECK_INTERVAL)
  }

  #stopAuthenticationChecks() {
    clearInterval(this.authenticationTimer)
    this.authenticationTimer = null
    this.authenticationCheck = null
  }

  #checkAuthentication() {
    if (!this.room || !this.roomId || this.authenticationCheck) return this.authenticationCheck

    const roomAtStart = this.room
    const check = fetch(`/rooms/${encodeURIComponent(this.roomId)}/huddle`, {
      method: "GET",
      credentials: "same-origin",
      headers: { "Accept": "application/json" }
    }).then((response) => {
      if (roomAtStart === this.room && [ 401, 403, 404 ].includes(response.status)) {
        this.#endForAuthenticationFailure(response.status)
      }
    }).catch(() => {
      // LiveKit owns network reconnection. A failed auth poll alone is not proof
      // that room access was revoked.
    }).finally(() => {
      if (this.authenticationCheck === check) this.authenticationCheck = null
    })

    this.authenticationCheck = check

    return this.authenticationCheck
  }

  async #endForAuthenticationFailure(status) {
    ++this.operation
    await this.#disconnectCurrentRoom()
    const message = status === 403 || status === 404
      ? "Your access to this room ended."
      : "Your sign-in expired. Sign in again to join a huddle."
    this.#setState("failed", message, true)
  }

  #endForAuthenticationChange() {
    ++this.operation
    this.#stopAuthenticationChecks()

    const room = this.room
    this.room = null
    if (room) this.#disconnectRoom(room)

    this.#clearMedia()
    this.roomId = null
    this.roomName = null
    this.identity = null
    this.state = "idle"
    this.element.hidden = true
    this.broadcastState()
  }

  #joinErrorMessage(error) {
    if (this.#permissionWasDenied(error)) {
      return "Microphone access was denied or cancelled. Allow microphone access and try again. You are not connected."
    }
    if (error?.status === 401) return "Your sign-in expired. Sign in again to join a huddle."
    if (error?.status === 403 || error?.status === 404) return "You no longer have access to this room."
    if (error?.message === "missing-csrf-token") return "The page session is incomplete. Refresh the page and try again."

    return "The huddle could not connect. Check your connection and try again."
  }

  #permissionWasDenied(error) {
    const message = String(error?.message || "").toLowerCase()
    return error?.name === "NotAllowedError" || message.includes("permission") || message.includes("denied")
  }

  #signedInAsCurrentUser() {
    const userId = document.querySelector('meta[name="current-user-id"]')?.content
    return String(userId || "") === String(this.currentUserIdValue)
  }
}
