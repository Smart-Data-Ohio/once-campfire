import { Controller } from "@hotwired/stimulus"

// One aggregate presence poll per browser: on connect and then every 15
// seconds the sidebar fetches every room with someone in the call and feeds
// each sidebar stack through the shared window event the stacks already
// listen for, so a sidebar with dozens of rows issues one request instead of
// one per row. Rooms absent from the response get an empty list; a failed
// poll keeps the last known participants. A refresh while one is already in
// flight is skipped, so the connect fetch and an interval tick never double
// up.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 15000 } }

  connect() {
    this.refresh()
    this.refreshTimer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.refreshTimer)
  }

  async refresh() {
    if (this.inFlightRefresh) return
    this.inFlightRefresh = true

    try {
      await this.#poll()
    } finally {
      this.inFlightRefresh = false
    }
  }

  async #poll() {
    let rooms

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        cache: "no-store"
      })

      if (!response.ok) return
      rooms = await response.json()
    } catch {
      return
    }

    const participantsByRoomId = new Map(rooms.map(room => [ String(room.room_id), room.participants ]))

    this.sidebarStacks.forEach(stack => {
      window.dispatchEvent(new CustomEvent("huddle-participants:updated", {
        detail: {
          url: stack.dataset.huddleParticipantsUrlValue,
          participants: participantsByRoomId.get(stack.dataset.huddlePresenceRoomId) || []
        }
      }))
    })
  }

  get sidebarStacks() {
    return this.element.querySelectorAll('[data-controller~="huddle-participants"][data-huddle-presence-room-id]')
  }
}
