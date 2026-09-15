import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { boosterIds: String }

  connect() {
    this.#syncState()
  }

  boosterIdsValueChanged() {
    this.#syncState()
  }

  #syncState() {
    const currentUserId = document.querySelector("meta[name='current-user-id']")?.content
    const active = currentUserId && this.#boosterIds.includes(String(currentUserId))
    this.element.classList.toggle("reaction-chip--active", Boolean(active))
    this.element.setAttribute("aria-pressed", String(Boolean(active)))
  }

  get #boosterIds() {
    return this.boosterIdsValue.split(",").map(value => value.trim()).filter(Boolean)
  }
}
