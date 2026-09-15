import { Controller } from "@hotwired/stimulus"

// Announces a shared screen next to the room's huddle button so somebody who has
// scrolled away, or who has the huddle panel behind a mobile drawer, still sees
// that there is something to look at and can enlarge it in one click.
export default class extends Controller {
  static targets = [ "label" ]
  static values = { roomId: Number }

  connect() {
    this.handleChange = this.#handleChange.bind(this)
    window.addEventListener("huddle:changed", this.handleChange)

    queueMicrotask(() => window.dispatchEvent(new CustomEvent("huddle:query")))
  }

  disconnect() {
    window.removeEventListener("huddle:changed", this.handleChange)
  }

  view() {
    window.dispatchEvent(new CustomEvent("huddle:expand-screen"))
  }

  #handleChange({ detail: { roomId, sharing, expanded } }) {
    const shares = sharing || []
    const isCurrentRoom = roomId && Number(roomId) === this.roomIdValue

    this.element.hidden = !(isCurrentRoom && shares.length > 0)
    if (this.element.hidden) return

    const names = shares.map(({ name }) => name)
    const description = names.length === 1
      ? `${names[0]} is sharing a screen`
      : `${names.length} people are sharing a screen`

    const action = expanded ? `${description}. Already expanded` : `${description}. View it`
    this.labelTarget.textContent = names.length === 1 ? `${names[0]} is sharing` : `${names.length} screens shared`
    this.element.setAttribute("aria-label", action)
    this.element.setAttribute("title", action)
  }
}
