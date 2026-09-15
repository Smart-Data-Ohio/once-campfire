import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = [ "count" ]
  static values = { url: String }

  #generation
  #request
  #dirty = false

  async connect() {
    const generation = this.#generation = Symbol()
    this.#dirty = true
    document.addEventListener("visibilitychange", this.#refresh)
    document.addEventListener("turbo:load", this.#refresh)
    window.addEventListener("online", this.#refresh)
    this.#refresh()

    try {
      const subscription = await cable.subscribeTo({ channel: "ActivityChannel" }, {
        connected: () => { if (this.#generation === generation) this.#refresh() },
        received: () => { if (this.#generation === generation) this.#refresh() }
      })
      if (this.#generation === generation) {
        this.subscription = subscription
      } else {
        subscription.unsubscribe()
      }
    } catch {
      // Counts are refreshed again on navigation, reconnect, or foregrounding.
    }
  }

  disconnect() {
    this.#generation = undefined
    this.#request?.abort()
    this.#request = undefined
    this.subscription?.unsubscribe()
    this.subscription = undefined
    document.removeEventListener("visibilitychange", this.#refresh)
    document.removeEventListener("turbo:load", this.#refresh)
    window.removeEventListener("online", this.#refresh)
  }

  #refresh = async () => {
    this.#dirty = true
    if (!this.#generation || this.#request || document.visibilityState === "hidden") return

    const generation = this.#generation
    const request = this.#request = new AbortController()
    this.#dirty = false
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        cache: "no-store",
        signal: request.signal
      })
      if (!response.ok) return
      const result = await response.json()
      if (this.#generation !== generation || !Number.isSafeInteger(result.unread_count) || result.unread_count < 0) return

      const count = result.unread_count
      this.countTarget.textContent = count > 99 ? "99+" : String(count)
      this.countTarget.hidden = count === 0
      this.countTarget.setAttribute("aria-label", `${count} unread ${count === 1 ? "item" : "items"}`)
    } catch {
      // Keep the last known count when the connection is briefly unavailable.
    } finally {
      if (this.#request === request) this.#request = undefined
      if (this.#generation === generation && this.#dirty) this.#refresh()
    }
  }
}
