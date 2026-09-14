import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "label" ]
  static values = { roomId: Number, roomName: String }

  connect() {
    this.handleChange = this.#handleChange.bind(this)
    window.addEventListener("huddle:changed", this.handleChange)

    queueMicrotask(() => window.dispatchEvent(new CustomEvent("huddle:query")))
  }

  disconnect() {
    window.removeEventListener("huddle:changed", this.handleChange)
  }

  join() {
    window.dispatchEvent(new CustomEvent("huddle:join", {
      detail: { roomId: this.roomIdValue, roomName: this.roomNameValue }
    }))
  }

  #handleChange({ detail: { roomId, state } }) {
    const isCurrentRoom = roomId && Number(roomId) === this.roomIdValue
    const isActive = [ "connecting", "connected", "reconnecting" ].includes(state)

    this.element.setAttribute("aria-pressed", String(Boolean(isCurrentRoom && isActive)))
    this.labelTarget.textContent = isCurrentRoom && state === "connecting"
      ? "Joining…"
      : isCurrentRoom && isActive ? "In huddle" : "Join huddle"
  }
}
