import { Controller } from "@hotwired/stimulus"

// Who is currently in a voice channel, rendered as an avatar stack with a
// count. Server pushes replace this stack when a grant is issued, revoked, or
// first seen in the call; the interval below only covers grants that quietly
// expire, so it must not run more often than every 15 seconds.
class ParticipantsRevoked extends Error {}

// Responses are shared across every stack watching the same room, so a room
// page issues one fallback request per interval no matter how many stacks it
// renders (sidebar, header). In-flight requests are shared too, and a 404
// stops every stack at once.
const sharedResponses = new Map()
const pendingRequests = new Map()

async function fetchParticipants(url) {
  const response = await fetch(url, {
    headers: { Accept: "application/json" },
    credentials: "same-origin",
    cache: "no-store"
  })

  if (response.status === 404) throw new ParticipantsRevoked()
  if (!response.ok) throw new Error(`participants request failed (${response.status})`)
  return response.json()
}

export default class extends Controller {
  static targets = [ "avatars", "count" ]
  static values = { url: String, max: Number, interval: Number, label: { type: String, default: "in voice" } }

  connect() {
    this.refreshTimer = setInterval(() => this.refresh(), this.intervalValue)
    this.handleSharedUpdate = ({ detail }) => {
      if (detail.url === this.urlValue && !this.revoked) this.#render(detail.participants)
    }
    this.handleSharedRemoval = ({ detail }) => {
      if (detail.url === this.urlValue) this.#handleRevoked()
    }
    window.addEventListener("huddle-participants:updated", this.handleSharedUpdate)
    window.addEventListener("huddle-participants:removed", this.handleSharedRemoval)
  }

  disconnect() {
    clearInterval(this.refreshTimer)
    window.removeEventListener("huddle-participants:updated", this.handleSharedUpdate)
    window.removeEventListener("huddle-participants:removed", this.handleSharedRemoval)
  }

  async refresh() {
    if (this.revoked) return

    try {
      this.#render(await this.#loadParticipants())
    } catch (error) {
      if (error instanceof ParticipantsRevoked) {
        sharedResponses.delete(this.urlValue)
        this.#handleRevoked()
        window.dispatchEvent(new CustomEvent("huddle-participants:removed", { detail: { url: this.urlValue } }))
      }
      // Otherwise keep the last known participants.
    }
  }

  async #loadParticipants() {
    const url = this.urlValue

    if (pendingRequests.has(url)) return pendingRequests.get(url)

    const cached = sharedResponses.get(url)
    if (cached && Date.now() - cached.fetchedAt < this.intervalValue) return cached.participants

    const request = fetchParticipants(url)
    pendingRequests.set(url, request)

    try {
      const participants = await request
      sharedResponses.set(url, { fetchedAt: Date.now(), participants })
      window.dispatchEvent(new CustomEvent("huddle-participants:updated", { detail: { url, participants } }))
      return participants
    } finally {
      pendingRequests.delete(url)
    }
  }

  // A 404 means the membership is gone: stop polling, clear the stack, and
  // never retry. Other failures keep the last known participants.
  #handleRevoked() {
    if (this.revoked) return

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
      ? `${participants.length} ${this.labelValue}: ${participants.map(participant => participant.name).join(", ")}`
      : `Nobody ${this.labelValue}`)
  }
}
