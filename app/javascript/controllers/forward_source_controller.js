import { Controller } from "@hotwired/stimulus"

// Forwarded messages are rendered from shared/broadcast HTML. Fetch the source
// link separately so its visibility follows the current viewer's access.
export default class extends Controller {
  static targets = [ "link" ]
  static values = { url: String }

  connect() {
    this.#load()
  }

  async #load() {
    if (!this.hasLinkTarget || !this.urlValue) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        cache: "no-store",
      })
      if (!response.ok) return

      const payload = await response.json()
      const source = payload.source || payload.forwarded_source || payload.forwardedSource
      const url = typeof source === "string" ? source : source?.url
      if (!url) return

      this.linkTarget.href = url
      this.linkTarget.hidden = false
    } catch {
      // A denied or unavailable source should remain an ordinary forwarded label.
    }
  }
}
