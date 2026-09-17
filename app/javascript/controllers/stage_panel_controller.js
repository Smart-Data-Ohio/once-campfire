import { Controller } from "@hotwired/stimulus"

// The stage drawer: a Hosts/Speakers/Listeners roster that opens from the
// room header. It is a modal dialog, so it renders in the top layer above
// the member panel and the rest of the workspace. Its contents stay live
// over Turbo Streams; this controller only opens and closes the dialog
// itself. Escape closes natively through the `close` event below.
export default class extends Controller {
  static targets = [ "panel", "toggle" ]

  toggle(event) {
    event?.preventDefault()

    if (this.panelTarget.open) {
      this.close()
    } else {
      this.panelTarget.showModal()
      this.toggleTarget.setAttribute("aria-expanded", "true")
    }
  }

  close(event) {
    event?.preventDefault()
    this.panelTarget.close()
  }

  // A click on the backdrop — the dialog itself rather than its surface —
  // closes, like the member panel's backdrop button.
  backdropClicked(event) {
    if (event.target === this.panelTarget) this.close()
  }

  wasClosed() {
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }
}
