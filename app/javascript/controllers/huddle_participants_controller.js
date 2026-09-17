import { Controller } from "@hotwired/stimulus"

// Who is currently in a voice channel, rendered as an avatar stack with a
// count. Server pushes replace this stack when a grant is issued, revoked, or
// first seen in the call; the interval below only covers grants that quietly
// expire, so it must not run more often than every 15 seconds.
export default class extends Controller {
  static targets = [ "avatars", "count" ]
  static values = { url: String, max: Number, interval: Number }

  connect() {
    this.refreshTimer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.refreshTimer)
  }

  async refresh() {
    if (this.revoked) return

    let participants

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        cache: "no-store"
      })
      if (response.status === 404) {
        this.#handleRevoked()
        return
      }
      if (!response.ok) return
      participants = await response.json()
    } catch {
      // Keep the last known participants when the connection is briefly unavailable.
      return
    }

    this.#render(participants)
  }

  // A 404 means the membership is gone: stop polling, clear the stack, and
  // never retry. Other failures keep the last known participants.
  #handleRevoked() {
    this.revoked = true
    clearInterval(this.refreshTimer)
    this.refreshTimer = null
    this.#render([])
  }

  #render(participants) {
    this.element.classList.toggle("voice-stack--live", participants.length > 0)

    this.avatarsTarget.replaceChildren(
      ...participants.slice(0, this.maxValue).map(participant => {
        const avatar = document.createElement("img")
        avatar.src = participant.avatar_url
        avatar.alt = ""
        avatar.title = participant.name
        avatar.width = 20
        avatar.height = 20
        avatar.className = "voice-stack__avatar"
        avatar.dataset.userId = participant.id
        return avatar
      })
    )

    this.countTarget.hidden = participants.length === 0
    this.countTarget.textContent = participants.length
    this.element.setAttribute("aria-label", participants.length > 0
      ? `${participants.length} in voice: ${participants.map(participant => participant.name).join(", ")}`
      : "Nobody in voice")
  }
}
