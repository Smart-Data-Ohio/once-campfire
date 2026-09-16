import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const ACTIVE_HUDDLE_STATES = [ "connecting", "connected", "reconnecting" ]

export default class extends Controller {
  static targets = [ "title", "description" ]
  static values = {
    activityItemId: Number,
    roomId: Number,
    roomName: String,
    roomPath: String,
    readPath: String
  }

  async connect() {
    this.handleHuddleJoin = this.#huddleJoined.bind(this)
    this.handleHuddleChange = this.#huddleChanged.bind(this)
    window.addEventListener("huddle:join", this.handleHuddleJoin)
    window.addEventListener("huddle:changed", this.handleHuddleChange)

    const generation = this.generation = Symbol()
    try {
      const subscription = await cable.subscribeTo({ channel: "ActivityChannel" }, {
        received: (payload) => { if (this.generation === generation) this.#activityReceived(payload) }
      })
      if (this.generation === generation) {
        this.subscription = subscription
      } else {
        subscription.unsubscribe()
      }
    } catch {
      // The invitation also lands in the activity inbox, so a missed
      // subscription only loses the real-time banner, not the call itself.
    }
  }

  disconnect() {
    this.generation = undefined
    this.subscription?.unsubscribe()
    this.subscription = undefined
    window.removeEventListener("huddle:join", this.handleHuddleJoin)
    window.removeEventListener("huddle:changed", this.handleHuddleChange)
  }

  join(event) {
    event?.preventDefault()

    const roomId = this.roomIdValue
    const roomName = this.roomNameValue
    this.#hide()
    if (!roomId) return

    if (window.location.pathname === this.roomPathValue) {
      this.#dispatchJoin(roomId, roomName)
    } else {
      // The listener is on the window, so it survives the navigation that
      // replaces this controller's element.
      window.addEventListener("turbo:load", () => this.#dispatchJoin(roomId, roomName), { once: true })
      Turbo.visit(this.roomPathValue)
    }
  }

  async dismiss(event) {
    event?.preventDefault()

    const readPath = this.readPathValue
    this.#hide()
    if (!readPath) return

    try {
      await fetch(readPath, {
        method: "PATCH",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        credentials: "same-origin"
      })
    } catch {
      // The banner is already gone; the inbox still offers Mark read.
    }
  }

  #activityReceived(payload) {
    const invitation = payload?.huddleInvitation
    if (!invitation) return

    if (invitation.eventType === "huddle_started" && invitation.state === "unread") {
      this.#show(invitation)
    } else if (invitation.activityItemId === this.activityItemIdValue) {
      this.#hide()
    }
  }

  #huddleJoined({ detail }) {
    if (detail && Number(detail.roomId) === this.roomIdValue) this.#hide()
  }

  #huddleChanged({ detail }) {
    if (!detail || Number(detail.roomId) !== this.roomIdValue) return
    if (ACTIVE_HUDDLE_STATES.includes(detail.state)) this.#hide()
  }

  #dispatchJoin(roomId, roomName) {
    window.dispatchEvent(new CustomEvent("huddle:join", {
      detail: { roomId, roomName }
    }))
  }

  #show(invitation) {
    this.activityItemIdValue = invitation.activityItemId
    this.roomIdValue = invitation.roomId
    this.roomNameValue = invitation.roomName
    this.roomPathValue = invitation.roomPath
    this.readPathValue = invitation.readPath
    this.titleTarget.textContent = `${invitation.callerName} started a huddle`
    this.descriptionTarget.textContent = `Join the huddle in ${invitation.roomName}`
    this.element.hidden = false
  }

  #hide() {
    this.activityItemIdValue = 0
    this.roomIdValue = 0
    this.element.hidden = true
  }
}
