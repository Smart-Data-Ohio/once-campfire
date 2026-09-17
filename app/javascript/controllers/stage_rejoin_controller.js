import { Controller } from "@hotwired/stimulus"

// A role change arrives as a Turbo Stream replacing the member's stage panel.
// This element exists only in that replacement: connecting it tells the
// huddle panel to leave and rejoin with a fresh token for the new role.
// LiveKit permissions are never updated in place.
export default class extends Controller {
  static values = { roomId: Number }

  connect() {
    window.dispatchEvent(new CustomEvent("huddle:role-changed", {
      detail: { roomId: this.roomIdValue }
    }))
  }
}
