import { Controller } from "@hotwired/stimulus"
import HuddleNoiseSuppressor, { noiseSuppressionSupported } from "lib/huddle_noise_suppressor"
import HuddleMicrophoneMeter from "lib/huddle/meter"
import { audioOutputSupported, deviceLabel, listMediaDevices, loadDevicePreferences, storeDevicePreference } from "lib/huddle/devices"
import { formatConnectionStats, summarizeConnectionStats } from "lib/huddle/stats"

const AUTH_CHECK_INTERVAL = 45_000
const CONNECTION_STATS_INTERVAL = 2_000
const ACTIVE_STATES = [ "prejoin", "connecting", "connected", "reconnecting" ]
const NOISE_SUPPRESSION_STORAGE_KEY = "campfire.huddle.noiseSuppression"
const STREAM_QUALITY_STORAGE_KEY = "campfire.huddle.streamQuality"
let liveKitPromise

const loadLiveKit = () => liveKitPromise ||= import("livekit-client").catch(error => {
  liveKitPromise = null
  throw error
})

const stopMediaStream = (stream) => {
  for (const track of stream?.getTracks() || []) {
    try {
      track.stop()
    } catch (error) {
      // A track that is already gone needs no stopping.
    }
  }
}

export default class extends Controller {
  static targets = [
    "activeControls", "camera", "cameraLabel", "cameraSelect", "cameras", "checkDevices",
    "checkError", "checkJoin", "checkRetry", "connection", "connectionDetails", "devicesBlock",
    "devicesDone", "leaveLabel", "listeningNote", "meter", "meterFill", "microphoneSelect", "mute", "muteLabel",
    "noise", "noiseLabel", "notice", "participantCount", "participantList", "people",
    "prejoinMeter", "prejoinMeterFill", "preview", "previewWrap", "resumeAudio",
    "retry", "roleEvents", "roomName", "screens", "settings", "settingsRow", "share", "shareLabel",
    "sharing", "sharingExpand", "sharingName", "speakerRow", "speakerSelect",
    "statJitter", "statLoss", "statRtt", "statRx", "statSent", "statTransport", "status",
    "streamQuality", "streamQualityRow"
  ]
  static values = {
    currentUserId: Number,
    noiseWorkletUrl: String,
    noiseWasmUrl: String,
    noiseSimdWasmUrl: String
  }

  initialize() {
    this.room = null
    this.roomId = null
    this.roomName = null
    this.identity = null
    this.canPublish = true
    this.canPublishHint = undefined
    this.operation = 0
    this.state = "idle"
    this.roomListeners = new Map()
    this.attachments = new Map()
    this.expandedTrack = null
    this.fullscreenTrack = null
    this.noiseSuppressionAvailable = noiseSuppressionSupported()
    this.noiseSuppressionEnabled = this.noiseSuppressionAvailable && this.#storedNoiseSuppression()
    this.microphoneMeter = null
    this.previewOperation = 0
    this.previewAudioStream = null
    this.previewVideoStream = null
    this.devicesOpen = false
    this.connectionQuality = "unknown"
    this.streaming = null
    this.roleEventsObserver = null
    this.connectionStatsTimer = null
    this.connectionStatsSampling = false
    this.connectionStatsSummary = null
  }

  connect() {
    clearTimeout(this.disconnectTimer)

    this.abortController = new AbortController()
    const options = { signal: this.abortController.signal }

    window.addEventListener("huddle:join", this.join, options)
    window.addEventListener("huddle:role-changed", this.roleChanged, options)
    window.addEventListener("huddle:stream-start", this.streamStarted, options)
    window.addEventListener("huddle:stream-stop", this.streamStopped, options)
    window.addEventListener("huddle:query", this.broadcastState, options)
    window.addEventListener("huddle:expand-screen", this.viewSharedScreen, options)
    window.addEventListener("pagehide", this.pageHiding, options)
    document.addEventListener("fullscreenchange", this.fullscreenChanged, options)
    document.addEventListener("webkitfullscreenchange", this.fullscreenChanged, options)
    document.addEventListener("turbo:before-render", this.beforeRender, options)
    document.addEventListener("visibilitychange", this.visibilityChanged, options)
    navigator.mediaDevices?.addEventListener?.("devicechange", this.devicesChanged, options)

    // A Turbo navigation carries the panel over with its expanded screen intact,
    // but the scroll lock and the Escape handler live outside it.
    if (this.expandedTrack) {
      this.#lockTheaterScroll(true)
      window.addEventListener("keydown", this.keyPressed, options)
    }

    this.#startAuthenticationChecks()
    this.#observeRoleEvents()
    this.#updateNoiseSuppressionControl()
    this.speakerRowTarget.hidden = !audioOutputSupported()
    this.#renderState()
  }

  disconnect() {
    this.abortController?.abort()
    this.roleEventsObserver?.disconnect()
    this.roleEventsObserver = null

    // Turbo can briefly disconnect a permanent element while moving it into the
    // next page. Give Stimulus one turn to reconnect before treating it as gone.
    this.disconnectTimer = setTimeout(() => {
      if (!this.element.isConnected) this.#endForAuthenticationChange()
    }, 0)
  }

  join = async ({ detail }) => {
    const requestedRoomId = Number(detail?.roomId)
    const requestedRoomName = String(detail?.roomName || "Huddle")
    const canPublishHint = detail?.canPublishHint

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
    this.canPublish = true
    this.canPublishHint = canPublishHint
    // Storage is the preference; a transient processor failure only turned it off
    // in memory, so a fresh join gets a fresh attempt.
    this.noiseSuppressionEnabled = this.noiseSuppressionAvailable && this.#storedNoiseSuppression()

    // A browser that has never granted microphone access stops at the device
    // check first. Returning users skip it; a denied permission skips it too so
    // the denial surfaces through the usual failure notice. A stage listener
    // needs no publishing device, so a false hint skips the check and any
    // microphone acquisition and connects directly; the token remains the
    // authority for canPublish after connect.
    if (canPublishHint !== false && await this.#shouldShowPrejoinCheck()) {
      if (operation !== this.operation) return
      await this.#enterPrejoin(operation)
      return
    }
    if (operation !== this.operation) return

    await this.#connectRoom(operation)
  }

  async #connectRoom(operation) {
    this.#setState("connecting", `Connecting to ${this.roomName}…`)

    let room

    try {
      const [ credentials, liveKit ] = await Promise.all([
        this.#requestCredentials(this.roomId),
        loadLiveKit()
      ])
      if (operation !== this.operation) return

      this.liveKit = liveKit
      this.roomName = credentials.room?.name || this.roomName
      this.identity = credentials.identity
      this.canPublish = this.#tokenCanPublish(credentials.token)
      this.roomNameTarget.textContent = this.roomName
      this.#updatePublishControls()

      room = new liveKit.Room(this.#roomOptions(liveKit))
      this.room = room
      this.#bindRoom(room)

      await room.connect(credentials.url, credentials.token, { autoSubscribe: true })
      if (operation !== this.operation || room !== this.room) {
        await this.#disconnectRoom(room)
        return
      }

      await room.startAudio().catch(() => {})
      // A listener's token cannot publish, so LiveKit would reject the
      // microphone outright. They join subscribe-only instead.
      if (this.canPublish) {
        await room.localParticipant.setMicrophoneEnabled(true, this.#audioCaptureOptions())
      }
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
      this.#applyStoredAudioOutput(room)
      this.#refreshDeviceLists()
      this.#startMicrophoneMeter()
      this.#resetConnectionIndicator(room)

      // Noise suppression is applied after the huddle is usable. A processor
      // that cannot start must never keep somebody out of the conversation.
      this.#applyNoiseSuppression(room)
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

    this.join({ detail: { roomId: this.roomId, roomName: this.roomName, canPublishHint: this.canPublishHint } })
  }

  // A stage role change revokes the old grant, so the affected browser leaves
  // and rejoins the same room with a fresh token instead of updating LiveKit
  // permissions in place. The prejoin check is skipped: this is a rejoin, not
  // a first join. A failed panel rejoins too, so a demotion that the gateway
  // enforced first still lands the member back in the call as a listener.
  roleChanged = async ({ detail }) => {
    const roomId = Number(detail?.roomId)
    if (!Number.isInteger(roomId) || roomId <= 0) return
    if (this.roomId !== roomId) return
    if (![ ...ACTIVE_STATES, "failed" ].includes(this.state)) return

    const operation = ++this.operation
    await this.#disconnectCurrentRoom()
    if (operation !== this.operation) return

    await this.#connectRoom(operation)
  }

  // A stage role change appends an event node to the persistent target in
  // this panel, which — unlike the stage panel — exists on every page. When
  // the event names the connected room, rejoin the same way the stage-panel
  // trigger does, then drop the node so it fires only once.
  #observeRoleEvents() {
    this.roleEventsObserver?.disconnect()
    this.roleEventsObserver = null
    if (!this.hasRoleEventsTarget) return

    for (const node of [ ...this.roleEventsTarget.children ]) this.#handleRoleEvent(node)

    this.roleEventsObserver = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) this.#handleRoleEvent(node)
      }
    })
    this.roleEventsObserver.observe(this.roleEventsTarget, { childList: true })
  }

  #handleRoleEvent(node) {
    if (node?.nodeType !== Node.ELEMENT_NODE) return

    // A host stopping this browser's stream: the server state is already
    // ended, so this only stops the local share. streamStopped clears the
    // streaming flag before stopping, which keeps the unpublish below from
    // DELETEing a stream that is already gone.
    if (node.dataset.huddleStreamKind === "stream-stopped") {
      const roomId = Number(node.dataset.huddleStreamRoomId)
      node.remove()
      this.streamStopped({ detail: { roomId } })
      return
    }

    const roomId = Number(node.dataset.huddleRejoinRoomId)
    const stageRole = node.dataset.huddleRejoinStageRole
    node.remove()
    this.#updatePublishHint(roomId, stageRole)
    this.roleChanged({ detail: { roomId } })
  }

  // The persistent role event carries the member's new stage role. A demoted
  // speaker's stored retry hint and page launcher would otherwise stay true,
  // stranding them in microphone prejoin on retry or on leave-and-rejoin
  // without navigating. Hosts and speakers publish; listeners do not. The
  // token stays authoritative for actual publishing.
  #updatePublishHint(roomId, stageRole) {
    if (stageRole !== "listener" && stageRole !== "speaker" && stageRole !== "host") return

    const canPublish = stageRole !== "listener"
    if (roomId === this.roomId) this.canPublishHint = canPublish

    const launcher = document.querySelector(
      `[data-controller="huddle-launcher"][data-huddle-launcher-room-id-value="${roomId}"]`
    )
    if (launcher) launcher.dataset.huddleCanPublishParam = String(canPublish)
  }

  confirmPrejoinJoin = async () => {
    if (this.state !== "prejoin" || this.checkJoinTarget.disabled) return

    const operation = this.operation
    this.#storeSelectedDevices()
    this.#stopPreview()
    await this.#connectRoom(operation)
  }

  retryPrejoin = async () => {
    if (this.state !== "prejoin") return

    await this.#startPreview()
  }

  toggleDevices = () => {
    if (this.state !== "connected" && this.state !== "reconnecting") return

    this.devicesOpen = !this.devicesOpen
    if (this.devicesOpen) this.#refreshDeviceLists()
    this.#renderDevicesBlock()
  }

  closeDevices = () => {
    this.devicesOpen = false
    this.#renderDevicesBlock()
  }

  devicesChanged = () => {
    // The room retargets its own tracks when a device vanishes; this only keeps
    // the pickers truthful. In the pre-join check it also re-acquires the
    // preview when the chosen device disappeared with it.
    if (this.state !== "prejoin" && !this.#devicesBlockVisible()) return

    const microphoneId = this.microphoneSelectTarget.value
    const cameraId = this.cameraSelectTarget.value

    this.#refreshDeviceLists().then(() => {
      if (this.state !== "prejoin") return
      if (this.microphoneSelectTarget.value !== microphoneId || this.cameraSelectTarget.value !== cameraId) {
        this.#startPreview()
      }
    })
  }

  microphoneChanged = async () => {
    const deviceId = this.microphoneSelectTarget.value
    storeDevicePreference("audioinput", deviceId)

    if (this.state === "prejoin") {
      await this.#startPreview()
      return
    }

    await this.#switchDevice("audioinput", this.microphoneSelectTarget)
  }

  speakerChanged = async () => {
    // Before joining there is nothing to retarget, so the choice is only
    // stored and applied on connect.
    storeDevicePreference("audiooutput", this.speakerSelectTarget.value)
    if (this.state === "prejoin") return

    await this.#switchDevice("audiooutput", this.speakerSelectTarget)
  }

  cameraChanged = async () => {
    const deviceId = this.cameraSelectTarget.value
    storeDevicePreference("videoinput", deviceId)

    if (this.state === "prejoin") {
      await this.#startPreviewVideo()
      return
    }

    await this.#switchDevice("videoinput", this.cameraSelectTarget)
  }

  toggleConnectionDetails = () => {
    if (this.state !== "connected" && this.state !== "reconnecting") return

    const open = this.connectionDetailsTarget.hidden
    this.connectionDetailsTarget.hidden = !open
    this.connectionTarget.setAttribute("aria-expanded", String(open))
    this.#updateConnectionLabel()

    // Statistics are sampled only while the panel is open, never in the
    // background, and never sent anywhere.
    if (open) {
      this.#startConnectionSampling()
    } else {
      this.#stopConnectionSampling()
    }
  }

  leave = async () => {
    ++this.operation
    await this.#disconnectCurrentRoom()
    this.roomId = null
    this.roomName = null
    this.identity = null
    this.#clearConnectedNotice()
    this.#setState("idle", "Not in a huddle")
  }

  toggleMute = async () => {
    const room = this.room
    if (!room || this.state !== "connected" || this.muteTarget.disabled) return

    this.muteTarget.disabled = true
    try {
      await room.localParticipant.setMicrophoneEnabled(
        !room.localParticipant.isMicrophoneEnabled,
        this.#audioCaptureOptions()
      )
      if (room === this.room) {
        this.#updateMediaControls()
        this.#renderRoster()
        this.#applyNoiseSuppression(room)
        if (room.localParticipant.isMicrophoneEnabled) {
          this.#startMicrophoneMeter()
        } else {
          this.#stopMicrophoneMeter()
        }
      }
    } catch (error) {
      if (room === this.room) this.#showTemporaryStatus("The microphone could not be changed.")
    } finally {
      if (room === this.room) this.muteTarget.disabled = false
    }
  }

  toggleNoiseSuppression = async () => {
    if (!this.noiseSuppressionAvailable || this.noiseSuppressionBusy) return

    const requested = !this.noiseSuppressionEnabled
    this.noiseSuppressionEnabled = requested
    this.#storeNoiseSuppression(requested)
    this.#updateNoiseSuppressionControl()

    if (this.state === "connected") {
      await this.#applyNoiseSuppression(this.room)

      // A failure has already explained itself; do not talk over it.
      if (this.noiseSuppressionAvailable && this.noiseSuppressionEnabled === requested) {
        this.#showTemporaryStatus(requested
          ? "Noise suppression on"
          : "Noise suppression off. Your browser's basic filtering stays on.")
      }
    }
  }

  toggleScreenShare = async () => {
    const room = this.room
    if (!room || this.state !== "connected" || this.shareTarget.disabled) return

    this.shareTarget.disabled = true
    const enabling = !room.localParticipant.isScreenShareEnabled

    try {
      if (enabling) {
        await this.#startScreenShare(room)
      } else {
        await room.localParticipant.setScreenShareEnabled(false)
      }

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

  toggleCamera = async () => {
    const room = this.room
    if (!room || this.state !== "connected" || this.cameraTarget.disabled) return

    this.cameraTarget.disabled = true
    const enabling = !room.localParticipant.isCameraEnabled

    try {
      await this.#setCameraEnabled(room, enabling)

      if (room !== this.room) {
        await this.#setCameraEnabled(room, false).catch(() => {})
        return
      }

      this.#syncLocalCamera(room)
      this.#updateMediaControls()
      if (enabling) this.#clearConnectedNotice()
      this.#showTemporaryStatus(enabling ? "Your camera is on" : "Camera off")
    } catch (error) {
      if (room === this.room) {
        const message = this.#permissionWasDenied(error)
          ? "Camera wasn’t started. Allow camera access to try again."
          : "Camera could not be changed. Try again."
        // A camera that fails to start leaves the huddle connected, so the
        // failure stays in the notice target instead of fading with the
        // four-second status line.
        if (enabling) {
          this.#showConnectedNotice(message)
        } else {
          this.#showTemporaryStatus(message)
        }
        this.#updateMediaControls()
      }
    } finally {
      if (room === this.room) this.cameraTarget.disabled = false
    }
  }

  // Unlike screen share, `setCameraEnabled(false)` only mutes: the track stays
  // published and keeps the device claimed. Turning the camera off unpublishes
  // instead, which releases the camera and removes the tile on both sides.
  async #setCameraEnabled(room, enabling) {
    if (enabling) {
      // The camera keeps frame rate under constrained bandwidth: the SDK's
      // own default for a camera track, spelled out so the camera does not
      // inherit the room's screen-share "maintain-resolution" preference.
      await room.localParticipant.setCameraEnabled(true, undefined, { degradationPreference: "maintain-framerate" })
      return
    }

    const publication = room.localParticipant.getTrackPublication(this.liveKit.Track.Source.Camera)
    if (publication?.track) {
      await room.localParticipant.unpublishTrack(publication.track)
    } else {
      await room.localParticipant.setCameraEnabled(false)
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

  // Opening from the banner or the room header goes to the most recent share,
  // which is the one somebody just started and wants to be seen. Pressing it
  // again steps through the rest rather than going dead.
  viewSharedScreen = () => {
    const tracks = this.#screenTracks()
    if (!tracks.length) return

    const expanded = tracks.indexOf(this.expandedTrack)
    this.#expandScreen(expanded === -1 ? tracks.at(-1) : tracks[(expanded + 1) % tracks.length])
  }

  // The stage panel POSTs the stream first and dispatches this on success,
  // so by the time it arrives the room is live. The share starts at the
  // stream's quality; an ordinary share keeps the room default.
  streamStarted = async ({ detail }) => {
    const roomId = Number(detail?.roomId)
    if (!Number.isInteger(roomId) || roomId <= 0) return

    // Presenting needs the call: without it there is nothing to share over.
    // The stream stays live — stopping it is the Stop control's job — and a
    // join afterwards shares through the ordinary control instead.
    if (roomId !== this.roomId || !this.room || this.state !== "connected") return

    const room = this.room
    this.streaming = { roomId, quality: detail?.quality }

    try {
      await this.#startScreenShare(room, this.#streamEncodingFor(detail?.quality))
    } catch (error) {
      // A cancelled or denied capture must not leave live state dangling.
      this.streaming = null
      await this.#deleteStream(roomId)
      if (room === this.room) {
        this.#showTemporaryStatus(this.#permissionWasDenied(error)
          ? "Screen sharing wasn’t started. Choose a screen and allow sharing to try again."
          : "Screen sharing could not be started. Try again.")
        this.#updateMediaControls()
      }
      return
    }

    if (room !== this.room) {
      this.streaming = null
      return
    }

    this.#syncLocalScreenShare(room)
    this.#updateMediaControls()
    this.#showTemporaryStatus("You’re live")
  }

  // Stop stream ends the server state first; this stops the local share once
  // that lands. Only the presenting browser holds the flag, so a host
  // stopping someone else's stream changes nothing locally.
  streamStopped = async ({ detail }) => {
    const roomId = Number(detail?.roomId)
    if (!Number.isInteger(roomId) || roomId <= 0) return
    if (this.streaming?.roomId !== roomId || !this.room) return

    // Cleared before stopping: the unpublish below would otherwise DELETE a
    // stream the form already ended.
    this.streaming = null

    try {
      await this.room.localParticipant.setScreenShareEnabled(false)
    } catch (error) {
      // The share is already gone or going; nothing to recover.
    }

    this.#updateMediaControls()
  }

  // The viewer's stream quality choice applies to the presenter's screen
  // share and is remembered like the other huddle preferences.
  streamQualityChanged = () => {
    const value = this.streamQualityTarget.value
    if (![ "auto", "low", "high" ].includes(value)) return

    this.#storeStreamQuality(value)

    const publication = this.#streamPublication()
    if (publication) this.#applyStreamViewerQuality(publication)
  }

  keyPressed = (event) => {
    if (event.key !== "Escape" || event.defaultPrevented) return
    // The browser owns Escape while an element is in real full screen.
    if (this.#fullscreenElement()) return
    if (!this.expandedTrack) return

    event.preventDefault()
    this.#collapseScreen()
  }

  fullscreenChanged = () => {
    const element = this.#fullscreenElement()

    if (!element || !this.element.contains(element)) {
      const track = this.fullscreenTrack
      this.fullscreenTrack = null
      if (track) {
        this.#updateScreenControls()
        this.#applyScreenQuality(track)
        this.attachments.get(track)?.fullscreenButton?.focus()
      }
      return
    }

    this.#updateScreenControls()
  }

  broadcastState = () => {
    window.dispatchEvent(new CustomEvent("huddle:changed", {
      detail: {
        roomId: this.roomId,
        state: this.state,
        sharing: this.#sharingDescriptions(),
        expanded: Boolean(this.expandedTrack)
      }
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

  // The first join in a browser stops at the device check; returning users
  // never see it. A denied permission skips it too, so the denial keeps its
  // existing failure notice instead of opening a second error path.
  async #shouldShowPrejoinCheck() {
    try {
      const status = await navigator.permissions?.query({ name: "microphone" })
      if (status) return status.state === "prompt"
    } catch (error) {
      // Browsers without the Permissions API fall through to device labels.
    }

    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      return !devices.some((device) => device.label)
    } catch (error) {
      return true
    }
  }

  // The check runs entirely on local getUserMedia streams: no credentials are
  // requested and nothing is published to LiveKit until Join is confirmed.
  async #enterPrejoin(operation) {
    this.#setState("prejoin", "Check your devices")

    try {
      this.liveKit = await loadLiveKit()
    } catch (error) {
      if (operation !== this.operation) return
      await this.#disconnectCurrentRoom()
      this.#setState("failed", this.#joinErrorMessage(error), true)
      return
    }
    if (operation !== this.operation || this.state !== "prejoin") return

    await this.#refreshDeviceLists()
    if (operation !== this.operation || this.state !== "prejoin") return

    await this.#startPreview()
  }

  async #startPreview() {
    const preview = ++this.previewOperation
    this.#stopPreviewStreams()
    this.#stopMicrophoneMeter()
    this.#showCheckError("")
    this.checkJoinTarget.disabled = true
    this.checkRetryTarget.hidden = true
    this.prejoinMeterTarget.hidden = true

    const audioTrack = await this.#acquirePreviewAudio(preview)
    if (preview !== this.previewOperation || this.state !== "prejoin") {
      audioTrack?.stop()
      return
    }
    if (!audioTrack) return

    this.#startMicrophoneMeterOn({ mediaStreamTrack: audioTrack })
    this.prejoinMeterTarget.hidden = false
    this.checkJoinTarget.disabled = false

    await this.#startPreviewVideo()
  }

  async #acquirePreviewAudio(preview) {
    // The pickers are authoritative here, not storage, so the stored device id
    // is swapped for the selected one.
    const { deviceId: _stored, ...audio } = this.#audioCaptureOptions()
    const selected = this.microphoneSelectTarget.value
    if (selected) audio.deviceId = { exact: selected }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio, video: false })
      const track = stream.getAudioTracks()[0]

      if (preview !== this.previewOperation || this.state !== "prejoin" || !track) {
        stopMediaStream(stream)
        return null
      }

      this.previewAudioStream = stream
      return track
    } catch (error) {
      if (preview !== this.previewOperation || this.state !== "prejoin") return null

      // A refresh covers the device that vanished between listing and capture.
      await this.#refreshDeviceLists()
      this.#showCheckError(this.#permissionWasDenied(error)
        ? "Microphone access was denied. Allow microphone access and try again. You are not connected."
        : "The microphone could not be started. Check your device and try again.")
      this.checkRetryTarget.hidden = false
      return null
    }
  }

  async #startPreviewVideo() {
    const preview = ++this.previewOperation
    this.#stopPreviewVideo()
    this.previewWrapTarget.hidden = true

    const deviceId = this.cameraSelectTarget.value
    if (!deviceId) return

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { deviceId: { exact: deviceId } },
        audio: false
      })

      if (preview !== this.previewOperation || this.state !== "prejoin") {
        stopMediaStream(stream)
        return
      }

      this.previewVideoStream = stream
      this.previewTarget.srcObject = stream
      this.previewWrapTarget.hidden = false
    } catch (error) {
      if (preview !== this.previewOperation || this.state !== "prejoin") return

      // A camera that will not preview must not block joining audio-only; the
      // pickers stay so another camera can be chosen instead.
      await this.#refreshDeviceLists()
      this.#showCheckError("The camera preview could not be started. You can still join with your microphone.")
    }
  }

  #stopPreview() {
    ++this.previewOperation
    this.#stopMicrophoneMeter()
    this.#stopPreviewStreams()
    this.previewTarget.srcObject = null
    this.previewWrapTarget.hidden = true
    this.prejoinMeterTarget.hidden = true
  }

  #stopPreviewStreams() {
    stopMediaStream(this.previewAudioStream)
    this.previewAudioStream = null
    this.#stopPreviewVideo()
  }

  #stopPreviewVideo() {
    stopMediaStream(this.previewVideoStream)
    this.previewVideoStream = null
    if (this.previewTarget.srcObject) this.previewTarget.srcObject = null
  }

  #showCheckError(message) {
    this.checkErrorTarget.textContent = message || ""
    this.checkErrorTarget.hidden = !message
  }

  #startMicrophoneMeter() {
    if (this.state !== "connected" || !this.room?.localParticipant.isMicrophoneEnabled) return
    if (!this.liveKit) return

    const track = this.room.localParticipant
      .getTrackPublication?.(this.liveKit.Track.Source.Microphone)?.audioTrack
    if (track) this.#startMicrophoneMeterOn(track)
  }

  #startMicrophoneMeterOn(track) {
    if (!this.liveKit) return

    this.microphoneMeter ||= new HuddleMicrophoneMeter(
      this.liveKit.createAudioAnalyser,
      (level) => this.#renderMeterLevel(level)
    )
    this.microphoneMeter.start(track)
  }

  #stopMicrophoneMeter() {
    this.microphoneMeter?.stop()
    this.#renderMeterLevel(0)
  }

  #renderMeterLevel(level) {
    for (const [ meter, fill ] of [
      [ this.meterTarget, this.meterFillTarget ],
      [ this.prejoinMeterTarget, this.prejoinMeterFillTarget ]
    ]) {
      meter.setAttribute("aria-valuenow", String(level))
      fill.style.width = `${level}%`
    }
  }

  async #refreshDeviceLists() {
    let grouped

    try {
      grouped = await listMediaDevices()
    } catch (error) {
      return
    }

    const preferences = loadDevicePreferences()
    this.#fillDeviceSelect(this.microphoneSelectTarget, grouped.audioinput, "audioinput",
      this.#activeDeviceId("audioinput") || preferences.audioinput)
    if (audioOutputSupported()) {
      this.#fillDeviceSelect(this.speakerSelectTarget, grouped.audiooutput, "audiooutput",
        this.#activeDeviceId("audiooutput") || preferences.audiooutput)
    }
    this.#fillDeviceSelect(this.cameraSelectTarget, grouped.videoinput, "videoinput",
      this.#activeDeviceId("videoinput") || preferences.videoinput)
  }

  #fillDeviceSelect(select, devices, kind, preferred) {
    const current = select.value
    select.replaceChildren()

    if (!devices.length) {
      const option = document.createElement("option")
      const names = { audioinput: "No microphones found", audiooutput: "No speakers found", videoinput: "No cameras found" }
      option.value = ""
      option.textContent = names[kind] || "No devices found"
      select.appendChild(option)
      return
    }

    devices.forEach((device, index) => {
      const option = document.createElement("option")
      option.value = device.deviceId
      option.textContent = deviceLabel(device, kind, index)
      select.appendChild(option)
    })

    // The preferred device — the active one in a call, the stored choice
    // otherwise — wins over the previous selection, so a picker that is open
    // during an SDK retarget shows the now-active device.
    const ids = new Set(devices.map((device) => device.deviceId))
    if (preferred && ids.has(preferred)) {
      select.value = preferred
    } else if (current && ids.has(current)) {
      select.value = current
    } else {
      select.selectedIndex = 0
    }
  }

  #activeDeviceId(kind) {
    try {
      const active = this.room?.getActiveDevice?.(kind)
      return active && active !== "default" ? active : ""
    } catch (error) {
      return ""
    }
  }

  #storeSelectedDevices() {
    storeDevicePreference("audioinput", this.microphoneSelectTarget.value)
    if (audioOutputSupported()) storeDevicePreference("audiooutput", this.speakerSelectTarget.value)
    storeDevicePreference("videoinput", this.cameraSelectTarget.value)
  }

  async #switchDevice(kind, select) {
    const room = this.room
    if (!room || this.state !== "connected") return

    const deviceId = select.value
    if (!deviceId) {
      this.#refreshDeviceLists()
      return
    }

    this.#setDeviceSelectsDisabled(true)
    try {
      await room.switchActiveDevice(kind, deviceId)
      if (room !== this.room) return
      this.#relaxSwitchedDeviceConstraint(room, kind, deviceId)
      storeDevicePreference(kind, deviceId)

      // Switching replaces the underlying track: the meter re-attaches to the
      // new one, and the noise suppressor re-syncs (a no-op when the restart
      // carried it over).
      if (kind === "audioinput") {
        this.#startMicrophoneMeter()
        this.#applyNoiseSuppression(room)
      }
    } catch (error) {
      if (room !== this.room) return
      const names = { audioinput: "microphone", audiooutput: "speaker", videoinput: "camera" }
      this.#showTemporaryStatus(`The ${names[kind] || "device"} could not be switched. Try again.`)
      await this.#refreshDeviceLists()
    } finally {
      const live = this.state === "connected" || this.state === "prejoin"
      this.#setDeviceSelectsDisabled(!live)
    }
  }

  // `switchActiveDevice` records the choice as an `exact` constraint, which
  // turns a later re-acquire — unplug the camera after an in-call switch,
  // then turn it back on — into an OverconstrainedError. The stored
  // preference is `ideal`, so the live default is relaxed to match: a missing
  // device falls back to the default instead of failing the capture.
  #relaxSwitchedDeviceConstraint(room, kind, deviceId) {
    const defaults = kind === "audioinput"
      ? room.options.audioCaptureDefaults
      : kind === "videoinput" ? room.options.videoCaptureDefaults : null
    if (defaults) defaults.deviceId = { ideal: deviceId }
  }

  #setDeviceSelectsDisabled(disabled) {
    this.microphoneSelectTarget.disabled = disabled
    this.speakerSelectTarget.disabled = disabled
    this.cameraSelectTarget.disabled = disabled
  }

  async #applyStoredAudioOutput(room) {
    if (!audioOutputSupported()) return

    const deviceId = loadDevicePreferences().audiooutput
    if (!deviceId) return

    try {
      const { audiooutput } = await listMediaDevices()
      if (!audiooutput.some((device) => device.deviceId === deviceId)) return
      await room.switchActiveDevice("audiooutput", deviceId)
    } catch (error) {
      // Output selection is a preference, never a reason to fail a join.
    }
  }

  #resetConnectionIndicator(room) {
    this.connectionStatsSummary = null
    this.#updateConnectionIndicator(room.localParticipant.connectionQuality || "unknown")
  }

  // The server reports four states; the header compresses them to three.
  // Unknown — before the first update — reads as fair rather than good, so an
  // unmeasured connection never claims to be healthy.
  #updateConnectionIndicator(quality) {
    this.connectionQuality = quality || "unknown"
    const level = quality === "excellent"
      ? "good"
      : quality === "poor" || quality === "lost" ? "poor" : "fair"

    this.connectionTarget.dataset.quality = level
    this.#updateConnectionLabel()
  }

  #updateConnectionLabel() {
    const level = this.connectionTarget.dataset.quality || "fair"
    const action = this.connectionDetailsTarget.hidden ? "Show details" : "Hide details"
    this.connectionTarget.setAttribute("aria-label", `Connection quality: ${level}. ${action}.`)
  }

  #startConnectionSampling() {
    this.#stopConnectionSampling()
    // A reopened panel starts from a fresh baseline instead of averaging the
    // next bitrate over the interval while it was closed.
    this.connectionStatsSummary = null
    this.#sampleConnectionStats()
    this.connectionStatsTimer = setInterval(() => this.#sampleConnectionStats(), CONNECTION_STATS_INTERVAL)
  }

  #stopConnectionSampling() {
    clearInterval(this.connectionStatsTimer)
    this.connectionStatsTimer = null
    this.connectionStatsSampling = false
  }

  async #sampleConnectionStats() {
    const room = this.room
    if (!room || !this.liveKit || this.connectionStatsSampling) return
    if (this.state !== "connected" && this.state !== "reconnecting") return
    if (this.connectionDetailsTarget.hidden) return

    this.connectionStatsSampling = true
    try {
      const { Track } = this.liveKit
      let publisherReport = null
      let subscriberReport = null

      try {
        const microphone = room.localParticipant.getTrackPublication(Track.Source.Microphone)?.track
        publisherReport = await microphone?.getRTCStatsReport?.()
      } catch (error) {
        // A missing sender report leaves the last sample on screen.
      }

      try {
        subscriberReport = await this.#subscriberStatsTrack(room)?.getRTCStatsReport?.()
      } catch (error) {
        // Alone in a room there is nothing subscribed to.
      }

      if (room !== this.room || this.connectionDetailsTarget.hidden) return

      this.connectionStatsSummary = summarizeConnectionStats({
        publisherReport,
        subscriberReport,
        previous: this.connectionStatsSummary?.previous
      })
      const formatted = formatConnectionStats(this.connectionStatsSummary)
      this.statRttTarget.textContent = formatted.rtt
      this.statLossTarget.textContent = formatted.loss
      this.statJitterTarget.textContent = formatted.jitter
      this.statRxTarget.textContent = formatted.received
      this.statSentTarget.textContent = formatted.sent
      this.statTransportTarget.textContent = formatted.transport
    } finally {
      this.connectionStatsSampling = false
    }
  }

  // Every subscribed track shares the subscriber peer connection, so the first
  // audio track — falling back to any track — represents the path.
  #subscriberStatsTrack(room) {
    const { Track } = this.liveKit
    let fallback = null

    for (const participant of room.remoteParticipants.values()) {
      for (const publication of participant.trackPublications.values()) {
        if (!publication.track || !publication.isSubscribed) continue
        if (publication.kind === Track.Kind.Audio) return publication.track
        fallback ||= publication.track
      }
    }

    return fallback
  }

  #roomOptions(liveKit) {
    const { AudioPresets, ScreenSharePresets, VideoPresets } = liveKit

    return {
      adaptiveStream: true,
      dynacast: true,
      // Spelled out rather than inherited so a future SDK upgrade cannot quietly
      // change what Campfire asks the browser to do with a microphone.
      audioCaptureDefaults: this.#audioCaptureOptions(),
      // The 720p/30 camera target from docs/huddle-quality.md, step 5. This is
      // the SDK's own `videoDefaults` written out, so it changes no behavior
      // today and only pins it against upgrades.
      videoCaptureDefaults: {
        deviceId: this.#storedDeviceConstraint("videoinput", "default"),
        resolution: VideoPresets.h720.resolution
      },
      publishDefaults: {
        audioPreset: AudioPresets.music,
        dtx: true,
        red: true,
        // Shared code and slides have to stay readable, so keep resolution and
        // drop frames instead when bandwidth runs short. 1080p/15 is the SDK's
        // own default; 1080p/30 waits on the bandwidth measurements in
        // docs/huddle-quality.md.
        screenShareEncoding: ScreenSharePresets.h1080fps15.encoding,
        degradationPreference: "maintain-resolution",
        // Camera top layer: 1280×720 at up to 1.7 Mbps and 30 fps. The capture
        // constraint above already holds the source at 720p, where this matches
        // what the SDK would derive on its own. Simulcast is the SDK default;
        // with it on, the publisher also sends 640×360 and 320×180 layers so
        // adaptiveStream can size each subscription from its rendered element.
        // The codec stays the SDK default (VP8); codec comparison is future
        // measurement work. The shared "maintain-resolution" preference above
        // is the screen-share setting; the camera passes the SDK's
        // camera-specific "maintain-framerate" default in its own publish
        // options (see #setCameraEnabled), so each track keeps its own default.
        videoEncoding: VideoPresets.h720.encoding,
        simulcast: true
      }
    }
  }

  #audioCaptureOptions() {
    const options = {
      autoGainControl: true,
      echoCancellation: true,
      noiseSuppression: true,
      // Chrome's stronger speech isolation where it exists; ignored elsewhere
      // because it is an "ideal" constraint rather than a required one.
      voiceIsolation: true
    }

    // The remembered microphone is an "ideal" constraint, so a device that
    // vanished since last time falls back to the default silently instead of
    // failing the join.
    const microphoneId = loadDevicePreferences().audioinput
    if (microphoneId) options.deviceId = { ideal: microphoneId }

    return options
  }

  // Same silent fallback for the remembered camera. The camera toggle passes
  // no capture options of its own, so it inherits this default.
  #storedDeviceConstraint(kind, fallback) {
    const deviceId = loadDevicePreferences()[kind]
    return { ideal: deviceId || fallback }
  }

  async #startScreenShare(room, screenShareEncoding) {
    const options = {
      contentHint: "detail",
      // No `resolution`. A preset's resolution carries its frame rate too, so
      // naming the 15 fps preset here would also cap *capture* at 15 fps. The SDK
      // fills in 1080p/30 itself, and skips it on Safari 17, which cannot be
      // constrained — a hard-coded value would lose that exemption. Encoding is
      // capped separately by `screenShareEncoding` in `#roomOptions`.
      surfaceSwitching: "include",
      // Tab audio only. Capturing system audio while sharing a whole screen
      // feeds the speakers back into the huddle on Windows.
      systemAudio: "exclude"
    }

    // Shared audio is usually music or a video rather than speech, and discontinuous
    // transmission chops it, so it publishes without DTX. The option reaches both
    // screen tracks; DTX has no meaning for the video one. A stream passes its
    // own encoding for this call only; an ordinary share inherits the default.
    const publishOptions = { dtx: false }
    if (screenShareEncoding) publishOptions.screenShareEncoding = screenShareEncoding

    try {
      await room.localParticipant.setScreenShareEnabled(true, { ...options, audio: true }, publishOptions)
    } catch (error) {
      if (!this.#displayMediaRejectedConstraints(error)) throw error

      // Only a browser that refused to *capture* with these constraints is
      // retried; a publishing failure would just show a second picker.
      await room.localParticipant.setScreenShareEnabled(true, options, publishOptions)
    }
  }

  // The stream quality select maps onto the SDK's screen-share presets. An
  // unknown value falls back to the room default rather than failing the
  // share.
  #streamEncodingFor(quality) {
    const presets = this.liveKit?.ScreenSharePresets
    if (!presets) return undefined

    switch (quality) {
      case "720p15": return presets.h720fps15.encoding
      case "1080p15": return presets.h1080fps15.encoding
      case "1080p30": return presets.h1080fps30.encoding
      default: return undefined
    }
  }

  // Ends the room's stream the way the Stop control's DELETE does. Best
  // effort: the Stop control and the automatic ends converge on the same
  // state, so a failure here only delays the end.
  async #deleteStream(roomId) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (!csrfToken) return

    try {
      await fetch(`/rooms/${encodeURIComponent(roomId)}/stage/stream`, {
        method: "DELETE",
        credentials: "same-origin",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken
        }
      })
    } catch (error) {
      // Ending is idempotent; the next trigger retries it.
    }
  }

  // getDisplayMedia reports unusable constraints as NotSupportedError or TypeError.
  // Permission denials, publishing failures and transport errors arrive as other
  // names and must not trigger a second capture attempt.
  #displayMediaRejectedConstraints(error) {
    if (this.#permissionWasDenied(error)) return false

    return error?.name === "NotSupportedError" || error?.name === "TypeError"
  }

  #bindRoom(room) {
    const { RoomEvent } = this.liveKit
    const listeners = []
    const on = (event, handler) => {
      room.on(event, handler)
      listeners.push([ event, handler ])
    }

    on(RoomEvent.Reconnecting, () => {
      if (room === this.room) {
        this.#setState("reconnecting", "Connection interrupted. Reconnecting…")
        this.#checkAuthentication()
      }
    })
    on(RoomEvent.Reconnected, () => {
      if (room === this.room) {
        this.#setState("connected", "Huddle active")
        this.#renderRoster()
        this.#updateMediaControls()
        this.#updateAudioPlaybackControl()
        // A full reconnect republishes every track, so the microphone
        // analyser is bound to a dead track until the meter restarts on the
        // new one. The restart is idempotent and stays stopped while muted.
        this.#startMicrophoneMeter()
      }
    })
    on(RoomEvent.Disconnected, (reason) => this.#unexpectedDisconnect(room, reason))
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
      this.#streamShareUnpublished(publication)
    })
    on(RoomEvent.AudioPlaybackStatusChanged, () => this.#updateAudioPlaybackControl())
    on(RoomEvent.ConnectionQualityChanged, (quality, participant) => {
      if (room === this.room && (!participant || participant === room.localParticipant)) {
        this.#updateConnectionIndicator(quality)
      }
    })
    on(RoomEvent.ActiveDeviceChanged, (kind) => {
      if (room !== this.room) return

      // The SDK retargets tracks itself when a device vanishes; the pickers
      // and the meter follow it. The stored preference keeps the user's own
      // choice, so a fallback never overwrites it: preferences are only
      // written from user selections (#switchDevice, #storeSelectedDevices,
      // and the pre-join change handlers).
      this.#refreshDeviceLists()
      if (kind === "audioinput") this.#startMicrophoneMeter()
    })

    this.roomListeners.set(room, listeners)
  }

  #unbindRoom(room) {
    for (const [ event, handler ] of this.roomListeners.get(room) || []) room.off(event, handler)
    this.roomListeners.delete(room)
  }

  async #unexpectedDisconnect(room, reason) {
    if (room !== this.room) return

    ++this.operation
    this.room = null
    this.#unbindRoom(room)
    this.#stopLocalTracks(room)
    this.#clearMedia()
    this.#stopAuthenticationChecks()
    this.#stopPreview()
    this.#stopMicrophoneMeter()
    this.#stopConnectionSampling()
    this.#setState("failed", this.#disconnectMessage(reason), true, "Huddle ended")
  }

  // The browser's own stop control and leaving the call unpublish the screen
  // share without touching the stream. Ending the server state there keeps no
  // live state dangling behind a share that is already gone.
  #streamShareUnpublished(publication) {
    if (!this.streaming || this.streaming.roomId !== this.roomId) return
    if (publication?.source !== this.liveKit?.Track?.Source?.ScreenShare) return

    const { roomId } = this.streaming
    this.streaming = null
    this.#deleteStream(roomId)
  }

  // Leaving, switching rooms, and rejoining all end the local share with the
  // old connection; the stream it carried ends alongside so no live state
  // dangles. A rejoin after a role change already ended server-side through
  // grant revocation, which makes this DELETE a harmless no-op there.
  #endStreamOnDisconnect() {
    if (!this.streaming) return

    const { roomId } = this.streaming
    this.streaming = null
    this.#deleteStream(roomId)
  }

  async #disconnectCurrentRoom() {
    const room = this.room
    this.room = null
    this.#endStreamOnDisconnect()
    this.#stopAuthenticationChecks()
    this.#stopPreview()
    this.#stopMicrophoneMeter()
    this.#stopConnectionSampling()

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
    this.#syncLocalCamera(room)
  }

  #syncLocalScreenShare(room) {
    const { Track } = this.liveKit

    for (const publication of room.localParticipant.trackPublications.values()) {
      if (publication.track && publication.source === Track.Source.ScreenShare) {
        this.#attachTrack(publication.track, publication, room.localParticipant)
      }
    }
  }

  #syncLocalCamera(room) {
    const { Track } = this.liveKit

    for (const publication of room.localParticipant.trackPublications.values()) {
      if (publication.track && publication.source === Track.Source.Camera) {
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

    if (track.kind !== Track.Kind.Video) return

    const isScreenShare = publication.source === Track.Source.ScreenShare || track.source === Track.Source.ScreenShare
    const isCamera = publication.source === Track.Source.Camera || track.source === Track.Source.Camera
    if (!isScreenShare && !isCamera) return

    const isLocal = participant === this.room?.localParticipant
    const name = `${this.#participantName(participant)}${isLocal ? " (you)" : ""}`

    if (isCamera) {
      this.#attachCamera(track, publication, name, isLocal)
      return
    }

    const figure = document.createElement("figure")
    figure.className = "huddle__screen"

    const video = track.attach()
    video.autoplay = true
    video.playsInline = true
    video.muted = isLocal

    const caption = document.createElement("figcaption")
    caption.textContent = `${name} is sharing`

    const actions = document.createElement("div")
    actions.className = "huddle__screen-actions"

    const expandButton = this.#screenButton("Expand", `Expand ${name}’s shared screen`)
    expandButton.dataset.huddleScreenExpand = ""
    expandButton.setAttribute("aria-expanded", "false")
    expandButton.addEventListener("click", () => this.#toggleScreen(track))

    const fullscreenButton = this.#screenButton("Full screen", `Show ${name}’s shared screen full screen`)
    fullscreenButton.dataset.huddleScreenFullscreen = ""
    fullscreenButton.setAttribute("aria-pressed", "false")
    fullscreenButton.addEventListener("click", () => this.#toggleFullscreen(track))

    // The video itself is the most obvious thing to reach for, so clicking it
    // enlarges the share and double-clicking goes to real full screen.
    video.addEventListener("click", () => this.#expandScreen(track))
    video.addEventListener("dblclick", () => this.#toggleFullscreen(track))

    // Mobile Safari's native player does not fire `fullscreenchange`.
    video.addEventListener("webkitendfullscreen", () => {
      if (this.fullscreenTrack !== track) return

      this.fullscreenTrack = null
      this.#updateScreenControls()
      this.#applyScreenQuality(track)
      fullscreenButton.focus()
    })

    const watching = document.createElement("p")
    watching.className = "huddle__watching"
    watching.hidden = true

    actions.append(expandButton, fullscreenButton)
    figure.append(video, actions, caption, watching)
    this.screensTarget.appendChild(figure)
    this.screensTarget.hidden = false
    this.attachments.set(track, {
      elements: [ video ],
      wrapper: figure,
      publication,
      name,
      isLocal,
      kind: "screen",
      expandButton,
      fullscreenButton,
      watching
    })

    this.#updateScreenControls()
    this.#renderSharingNotice()

    // A live stream expands itself for viewers: the presenter's share opens
    // in theater mode on arrival the way huddle:expand-screen would open it,
    // unless the viewer already expanded something else. Joining late takes
    // the same path through the connect-time sync.
    if (!isLocal && this.#isStreamTrack(track)) {
      this.#applyStreamViewerQuality(publication)
      if (!this.expandedTrack) this.#expandScreen(track)
    }
  }

  // One tile per published camera track: the local preview plus every remote
  // camera. Camera tiles have no expand or full-screen controls in this slice;
  // theater mode keeps them as small thumbnails (see huddle.css) so they never
  // cover the expanded screen.
  #attachCamera(track, publication, name, isLocal) {
    const figure = document.createElement("figure")
    figure.className = "huddle__camera"
    if (isLocal) figure.classList.add("huddle__camera--local")

    const video = track.attach()
    video.autoplay = true
    video.playsInline = true
    video.muted = isLocal

    const caption = document.createElement("figcaption")
    caption.textContent = name

    figure.append(video, caption)
    this.camerasTarget.appendChild(figure)
    this.camerasTarget.hidden = false
    this.attachments.set(track, {
      elements: [ video ],
      wrapper: figure,
      publication,
      name,
      isLocal,
      kind: "camera"
    })
  }

  #screenButton(label, description) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn huddle__screen-action"
    button.textContent = label
    button.setAttribute("aria-label", description)
    return button
  }

  #detachTrack(track, { restoreFocus = true } = {}) {
    const attachment = this.attachments.get(track)
    const heldFocus = restoreFocus && Boolean(attachment?.wrapper?.contains(document.activeElement))

    if (this.expandedTrack === track) this.#collapseScreen({ restoreFocus: false })
    if (this.fullscreenTrack === track) {
      this.fullscreenTrack = null
      this.#exitFullscreen()
    }

    try {
      for (const element of track.detach()) element.remove()
    } catch (error) {
      // A disconnect can detach the SDK track before this cleanup runs.
    }

    for (const element of attachment?.elements || []) element.remove()
    attachment?.wrapper?.remove()
    this.attachments.delete(track)
    this.screensTarget.hidden = !this.screensTarget.children.length
    this.camerasTarget.hidden = !this.camerasTarget.children.length
    this.#renderSharingNotice()

    if (heldFocus) this.#restoreFocusAfterDetach()
  }

  #clearMedia() {
    this.#collapseScreen({ restoreFocus: false })
    this.fullscreenTrack = null
    this.#exitFullscreen()

    // The whole panel is going away, so there is nowhere sensible to put focus.
    for (const track of [ ...this.attachments.keys() ]) this.#detachTrack(track, { restoreFocus: false })
    this.screensTarget.replaceChildren()
    this.screensTarget.hidden = true
    this.camerasTarget.replaceChildren()
    this.camerasTarget.hidden = true
    this.#renderSharingNotice()
  }

  #screenTracks() {
    return [ ...this.attachments.keys() ].filter(track => this.attachments.get(track).kind === "screen")
  }

  #sharingDescriptions() {
    return this.#screenTracks().map(track => {
      const { name, isLocal } = this.attachments.get(track)
      return { name, isLocal }
    })
  }

  #toggleScreen(track) {
    if (this.expandedTrack === track) {
      this.#collapseScreen()
    } else {
      this.#expandScreen(track)
    }
  }

  #expandScreen(track) {
    const attachment = this.attachments.get(track)
    if (!attachment?.wrapper || this.expandedTrack === track) return

    const previous = this.expandedTrack
    this.expandedTrack = track
    this.element.classList.add("huddle--theater")
    this.#lockTheaterScroll(true)
    // Escape belongs to the browser at every other moment, so the handler is
    // only bound while there is something to collapse. Cycling between shares
    // re-adds it; addEventListener dedupes on (type, callback, capture), so the
    // repeated add is a deliberate no-op rather than a second handler.
    window.addEventListener("keydown", this.keyPressed, { signal: this.abortController?.signal })
    this.#updateScreenControls()
    this.#applyScreenQuality(track)
    if (previous) this.#applyScreenQuality(previous)
    attachment.expandButton.focus()
    this.#renderSharingNotice()
  }

  #collapseScreen({ restoreFocus = true } = {}) {
    const track = this.expandedTrack
    if (!track) return

    this.expandedTrack = null
    this.element.classList.remove("huddle--theater")
    this.#lockTheaterScroll(false)
    window.removeEventListener("keydown", this.keyPressed)
    this.#updateScreenControls()
    this.#applyScreenQuality(track)

    const button = this.attachments.get(track)?.expandButton
    if (restoreFocus && button?.isConnected) button.focus()
    this.#renderSharingNotice()
  }

  // Turbo replaces <body> between pages, so the lock lives on <html>.
  #lockTheaterScroll(locked) {
    document.documentElement.classList.toggle("huddle-theater-open", locked)
  }

  // The share whose figure was removed cannot take the focus with it.
  #restoreFocusAfterDetach() {
    if (this.hasShareTarget && this.shareTarget.isConnected && !this.shareTarget.disabled) {
      this.shareTarget.focus()
      return
    }

    this.roomNameTarget.tabIndex = -1
    this.roomNameTarget.focus()
  }

  #updateScreenControls() {
    for (const [ track, attachment ] of this.attachments) {
      if (attachment.kind !== "screen") continue

      const expanded = this.expandedTrack === track
      const fullscreen = this.fullscreenTrack === track

      attachment.wrapper.classList.toggle("huddle__screen--expanded", expanded)
      attachment.expandButton.setAttribute("aria-expanded", String(expanded))
      attachment.expandButton.textContent = expanded ? "Collapse" : "Expand"
      attachment.expandButton.setAttribute(
        "aria-label",
        `${expanded ? "Collapse" : "Expand"} ${attachment.name}’s shared screen`
      )
      attachment.fullscreenButton.setAttribute("aria-pressed", String(fullscreen))
      attachment.fullscreenButton.textContent = fullscreen ? "Exit full screen" : "Full screen"
    }
  }

  #renderSharingNotice() {
    const sharing = this.#sharingDescriptions()
    const active = ACTIVE_STATES.includes(this.state)

    this.sharingTarget.hidden = !active || sharing.length === 0
    if (sharing.length) {
      const names = sharing.map(({ name }) => name)
      this.sharingNameTarget.textContent = names.length === 1
        ? `${names[0]} is sharing a screen`
        : `${names.length} people are sharing a screen`
      const others = sharing.length > 1
      this.sharingExpandTarget.textContent = !this.expandedTrack ? "View" : others ? "Next screen" : "Viewing"
      this.sharingExpandTarget.disabled = Boolean(this.expandedTrack) && !others
    }

    this.#renderStreamViewing()
    this.broadcastState()
  }

  // Adaptive streaming sizes a subscription from the rendered element and
  // `emitTrackUpdate` takes the *smaller* of that size and any manual request, so
  // this cannot out-argue the observer: while the element is still small the
  // adaptive size wins. It matters once the element has actually been resized,
  // where it asks for the full layer immediately instead of waiting for the next
  // observer callback.
  // The viewer's stream quality choice: Low and High pin the presenter's
  // screen-share subscription through setVideoQuality, while Auto clears the
  // explicit request so adaptive streaming sizes it from the element again.
  #applyStreamViewerQuality(publication) {
    if (typeof publication?.setVideoQuality !== "function" || !this.liveKit) return

    try {
      const { VideoQuality } = this.liveKit
      const preference = this.#storedStreamQuality()

      if (preference === "low") {
        publication.setVideoQuality(VideoQuality.LOW)
      } else if (preference === "high") {
        publication.setVideoQuality(VideoQuality.HIGH)
      } else {
        publication.requestedMaxQuality = undefined
        publication.requestedVideoDimensions = undefined
        publication.emitTrackUpdate?.()
      }
    } catch (error) {
      // Quality is a hint. A rejected hint must not break the view.
    }
  }

  #storedStreamQuality() {
    try {
      const value = window.localStorage.getItem(STREAM_QUALITY_STORAGE_KEY)
      return [ "auto", "low", "high" ].includes(value) ? value : "auto"
    } catch (error) {
      // Private browsing modes can refuse storage; the default is auto.
      return "auto"
    }
  }

  #storeStreamQuality(value) {
    try {
      window.localStorage.setItem(STREAM_QUALITY_STORAGE_KEY, value)
    } catch (error) {
      // The preference simply does not survive this session.
    }
  }

  // The Live badge names the presenter of the connected room's stream, if
  // the current page carries one. Viewed from another page there is no badge
  // to match against, so shares there expand only by hand.
  #liveStreamPresenterName() {
    if (!this.roomId) return null

    const badge = document.querySelector(
      `[data-live-stream-badge][data-room-id="${this.roomId}"]`
    )
    return badge?.dataset.liveStreamPresenterName || null
  }

  // The presenter's screen share: the local one while this browser presents,
  // otherwise a remote share whose publisher matches the Live badge. The
  // token names participants after their users, so the badge name identifies
  // the publisher; ordinary shares from other speakers never match.
  #isStreamTrack(track) {
    const attachment = this.attachments.get(track)
    if (!attachment || attachment.kind !== "screen") return false
    if (attachment.isLocal) return this.streaming?.roomId === this.roomId

    const presenter = this.#liveStreamPresenterName()
    return presenter !== null && attachment.name === presenter
  }

  // The viewed stream's remote publication, for the quality control. The
  // presenter's own share is local and never takes a viewer quality.
  #streamPublication() {
    for (const [ track, attachment ] of this.attachments) {
      if (attachment.kind === "screen" && !attachment.isLocal && this.#isStreamTrack(track)) {
        return attachment.publication
      }
    }

    return null
  }

  // Everyone in the call minus the presenter.
  #watcherCount() {
    if (!this.room) return 0

    return Math.max(0, this.room.remoteParticipants.size)
  }

  // "N watching" shows on the expanded stream only, and the quality control
  // shows while the presenter's share is attached.
  #renderStreamViewing() {
    const publication = this.#streamPublication()
    this.streamQualityRowTarget.hidden = !publication
    if (publication) this.streamQualityTarget.value = this.#storedStreamQuality()

    const count = this.#watcherCount()
    for (const [ track, attachment ] of this.attachments) {
      if (attachment.kind !== "screen" || !attachment.watching) continue

      const viewing = this.expandedTrack === track && this.#isStreamTrack(track)
      attachment.watching.hidden = !(viewing && count > 0)
      if (viewing && count > 0) attachment.watching.textContent = `${count} watching`
    }
  }

  #applyScreenQuality(track) {
    const attachment = this.attachments.get(track)
    const publication = attachment?.publication
    if (typeof publication?.setVideoQuality !== "function") return

    // A viewed stream follows the viewer's quality choice instead of the
    // default expand and collapse behavior below.
    if (this.#isStreamTrack(track)) {
      this.#applyStreamViewerQuality(publication)
      return
    }

    const { VideoQuality } = this.liveKit
    const expanded = this.expandedTrack === track || this.fullscreenTrack === track

    try {
      publication.setVideoQuality(VideoQuality.HIGH)
    } catch (error) {
      // Quality is a hint. A rejected hint must not break the view.
    }

    if (!expanded || typeof publication.setVideoDimensions !== "function") return

    requestAnimationFrame(() => {
      if (this.expandedTrack !== track && this.fullscreenTrack !== track) return

      const video = attachment.elements[0]
      const ratio = window.devicePixelRatio || 1
      const width = Math.round((video.clientWidth || 1280) * ratio)
      const height = Math.round((video.clientHeight || 720) * ratio)

      try {
        publication.setVideoDimensions({ width, height })
      } catch (error) {
        // Same as above: a rejected hint leaves the current layer in place.
      }
    })
  }

  #fullscreenElement() {
    return document.fullscreenElement || document.webkitFullscreenElement || null
  }

  #exitFullscreen() {
    if (!this.#fullscreenElement()) return

    try {
      (document.exitFullscreen || document.webkitExitFullscreen)?.call(document)
    } catch (error) {
      // Leaving full screen can be refused while a change is already running.
    }
  }

  async #toggleFullscreen(track) {
    const attachment = this.attachments.get(track)
    if (!attachment?.wrapper) return

    if (this.fullscreenTrack === track) {
      this.#exitFullscreen()
      return
    }

    const figure = attachment.wrapper
    const video = attachment.elements[0]
    this.fullscreenTrack = track

    // The figure is tried first because it carries the caption and the controls.
    // Mobile Safari only allows full screen on a video element, so the bare
    // video and then its prefixed player are the fallbacks.
    const attempts = [
      figure.requestFullscreen && (() => figure.requestFullscreen({ navigationUI: "hide" })),
      video.requestFullscreen && (() => video.requestFullscreen()),
      video.webkitEnterFullscreen && (() => video.webkitEnterFullscreen())
    ].filter(Boolean)

    let entered = false
    for (const attempt of attempts) {
      try {
        await attempt()
        entered = true
        break
      } catch (error) {
        // Try the next, narrower way of filling the screen.
      }
    }

    if (!entered) {
      this.fullscreenTrack = null
      this.#expandScreen(track)
      this.#showTemporaryStatus("Full screen isn’t available here. The shared screen is expanded instead.")
    }

    this.#updateScreenControls()
    this.#applyScreenQuality(track)
  }

  // Every caller goes through one queue. Two overlapping runs could otherwise
  // leave the processor attached while the button and localStorage say "off".
  #applyNoiseSuppression(room) {
    this.noiseOperation = Promise.resolve(this.noiseOperation)
      .catch(() => {})
      .then(() => this.#syncNoiseSuppression(room))

    return this.noiseOperation
  }

  async #syncNoiseSuppression(room) {
    if (!room || room !== this.room) return

    const { Track } = this.liveKit
    const track = room.localParticipant.getTrackPublication?.(Track.Source.Microphone)?.audioTrack
    if (!track || typeof track.setProcessor !== "function") return

    const wanted = this.noiseSuppressionAvailable && this.noiseSuppressionEnabled
    const current = track.getProcessor?.()
    if (wanted === Boolean(current)) return

    this.noiseSuppressionBusy = true
    this.#updateNoiseSuppressionControl()

    try {
      if (wanted) {
        await track.setProcessor(new HuddleNoiseSuppressor({
          workletUrl: this.noiseWorkletUrlValue,
          wasmUrl: this.noiseWasmUrlValue,
          simdWasmUrl: this.noiseSimdWasmUrlValue
        }))
      } else {
        await track.stopProcessor()
      }
    } catch (error) {
      if (!wanted) return

      // Falling back to the browser's own suppression is always better than
      // dropping the microphone out of the call.
      await track.stopProcessor().catch(() => {})

      if (this.#noiseSuppressionUnsupported(error)) {
        this.noiseSuppressionAvailable = false
        this.#showTemporaryStatus("Extra noise suppression isn’t available in this browser. Basic filtering is still on.")
      } else {
        // A worklet or model that failed to load may well load next time, so the
        // control stays usable and nothing about the failure is written to storage.
        this.noiseSuppressionEnabled = false
        this.#showTemporaryStatus("Noise suppression couldn’t start. Basic filtering is still on — try again.")
      }
    } finally {
      this.noiseSuppressionBusy = false
      this.#updateNoiseSuppressionControl()
    }
  }

  // Only a browser that genuinely cannot run the filter latches it off for the
  // rest of the page. A failed fetch or a refused AudioContext is transient.
  #noiseSuppressionUnsupported(error) {
    return !noiseSuppressionSupported() ||
      error?.name === "NotSupportedError" ||
      error?.message === "noise-suppression-unsupported"
  }

  #storedNoiseSuppression() {
    try {
      return window.localStorage.getItem(NOISE_SUPPRESSION_STORAGE_KEY) !== "off"
    } catch (error) {
      // Private browsing modes can refuse storage; the default stays on.
      return true
    }
  }

  #storeNoiseSuppression(enabled) {
    try {
      window.localStorage.setItem(NOISE_SUPPRESSION_STORAGE_KEY, enabled ? "on" : "off")
    } catch (error) {
      // The preference simply does not survive this session.
    }
  }

  #updateNoiseSuppressionControl() {
    if (!this.hasNoiseTarget) return

    const enabled = this.noiseSuppressionAvailable && this.noiseSuppressionEnabled

    this.noiseTarget.disabled = !this.noiseSuppressionAvailable || Boolean(this.noiseSuppressionBusy)
    this.noiseTarget.setAttribute("aria-pressed", String(enabled))
    this.noiseLabelTarget.textContent = this.noiseSuppressionAvailable
      ? enabled ? "Noise suppression on" : "Noise suppression off"
      : "Noise suppression unavailable"
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
    this.#renderStreamViewing()
  }

  #participantName(participant) {
    if (participant === this.room?.localParticipant) {
      return window.Current?.user?.name || participant.name || this.identity || "You"
    }

    return participant.name || participant.identity || "Participant"
  }

  // A listener joins with the microphone, camera, and screen-share controls
  // hidden and a note in their place. The token is the enforcement; hiding
  // the buttons only keeps the panel honest about what the call allows.
  #updatePublishControls() {
    const listening = this.canPublish === false
    const live = this.state === "connected" || this.state === "reconnecting"

    this.muteTarget.hidden = listening
    this.shareTarget.hidden = listening
    this.cameraTarget.hidden = listening
    this.listeningNoteTarget.hidden = !(live && listening)
  }

  #tokenCanPublish(token) {
    try {
      const payload = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")))
      return payload?.video?.canPublish !== false
    } catch (error) {
      return true
    }
  }

  #updateMediaControls() {
    if (!this.room) return

    const microphoneEnabled = this.room.localParticipant.isMicrophoneEnabled
    const screenShareEnabled = this.room.localParticipant.isScreenShareEnabled
    const cameraEnabled = this.room.localParticipant.isCameraEnabled

    this.muteLabelTarget.textContent = microphoneEnabled ? "Mute" : "Unmute"
    this.muteTarget.setAttribute("aria-pressed", String(!microphoneEnabled))
    this.muteTarget.classList.toggle("huddle__mute--muted", !microphoneEnabled)
    this.element.classList.toggle("huddle--muted", !microphoneEnabled)
    // The meter only means something while the microphone is live.
    this.meterTarget.hidden = !microphoneEnabled
    this.shareLabelTarget.textContent = screenShareEnabled ? "Stop sharing" : "Share screen"
    this.shareTarget.setAttribute("aria-pressed", String(screenShareEnabled))
    this.cameraLabelTarget.textContent = cameraEnabled ? "Camera on" : "Camera off"
    this.cameraTarget.setAttribute("aria-pressed", String(cameraEnabled))
  }

  #updateAudioPlaybackControl() {
    this.resumeAudioTarget.hidden = !this.room || this.room.canPlaybackAudio
  }

  #setState(state, message, isError = false, errorStatus = "Couldn’t join huddle") {
    this.state = state
    this.element.dataset.state = state
    this.element.hidden = state === "idle"
    this.roomNameTarget.textContent = this.roomName || "Huddle"
    this.statusTarget.textContent = isError ? errorStatus : message
    this.noticeTarget.textContent = isError ? message : ""
    this.noticeTarget.hidden = !isError

    const connected = state === "connected"
    const reconnecting = state === "reconnecting"
    const failed = state === "failed"
    const connecting = state === "connecting"
    const prejoin = state === "prejoin"
    const live = connected || reconnecting

    // A fresh join or a failure closes the in-call device step; the pre-join
    // check shows it unconditionally as the step itself.
    if (!live && !prejoin) this.devicesOpen = false

    this.activeControlsTarget.hidden = !live
    this.settingsTarget.hidden = !(live || prejoin)
    this.peopleTarget.hidden = !live
    this.connectionTarget.hidden = !live
    this.muteTarget.disabled = !connected
    this.shareTarget.disabled = !connected
    this.cameraTarget.disabled = !connected
    this.microphoneSelectTarget.disabled = !(connected || prejoin)
    this.speakerSelectTarget.disabled = !(connected || prejoin)
    this.cameraSelectTarget.disabled = !(connected || prejoin)
    this.retryTarget.hidden = !failed
    this.leaveLabelTarget.textContent = connecting || prejoin ? "Cancel" : failed ? "Close" : "Leave"
    this.resumeAudioTarget.hidden = true

    if (prejoin) {
      this.checkJoinTarget.disabled = true
      this.checkRetryTarget.hidden = true
      this.#showCheckError("")
    }
    if (!live) this.connectionDetailsTarget.hidden = true

    this.#renderDevicesBlock()
    if (!connected && !reconnecting) this.#renderRoster()
    this.#updateNoiseSuppressionControl()
    this.#updateMediaControls()
    this.#updatePublishControls()
    this.#renderSharingNotice()
  }

  #renderDevicesBlock() {
    const prejoin = this.state === "prejoin"
    const live = this.state === "connected" || this.state === "reconnecting"
    const visible = prejoin || (live && this.devicesOpen)

    this.devicesBlockTarget.hidden = !visible
    this.settingsRowTarget.hidden = !live
    this.checkJoinTarget.hidden = !prejoin
    this.devicesDoneTarget.hidden = !live
    this.checkDevicesTarget.setAttribute("aria-expanded", String(this.devicesOpen))
    // The in-call preview slot belongs to the pre-join check; the live camera
    // tile is the preview once joined.
    if (!prejoin) this.previewWrapTarget.hidden = true
  }

  #devicesBlockVisible() {
    return !this.devicesBlockTarget.hidden
  }

  #renderState() {
    if (this.state === "idle") {
      this.#setState("idle", "Not in a huddle")
    } else {
      this.element.hidden = false
      this.broadcastState()
    }
  }

  // A failure that leaves the huddle connected — a camera that would not
  // start — stays in the notice target until the camera starts or the huddle
  // is left, instead of fading with the four-second status line.
  #showConnectedNotice(message) {
    this.noticeTarget.textContent = message
    this.noticeTarget.hidden = false
  }

  #clearConnectedNotice() {
    this.noticeTarget.textContent = ""
    this.noticeTarget.hidden = true
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
    this.#setState("failed", message, true, "Huddle ended")
  }

  #endForAuthenticationChange() {
    ++this.operation
    this.#endStreamOnDisconnect()
    this.#stopAuthenticationChecks()
    this.#stopPreview()
    this.#stopMicrophoneMeter()
    this.#stopConnectionSampling()

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

  #disconnectMessage(reason) {
    const { DisconnectReason } = this.liveKit

    if (reason === DisconnectReason.PARTICIPANT_REMOVED) {
      return "Your access to this huddle ended. Join again if you still have access to the room."
    }
    if (reason === DisconnectReason.ROOM_DELETED || reason === DisconnectReason.ROOM_CLOSED) {
      return "This huddle has ended."
    }
    if (reason === DisconnectReason.DUPLICATE_IDENTITY) {
      return "This huddle connection was replaced by another connection."
    }

    return "The huddle ended because the connection was lost. Try joining again."
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
