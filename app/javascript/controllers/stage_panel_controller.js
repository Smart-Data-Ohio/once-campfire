import { Controller } from "@hotwired/stimulus"

// The stage drawer: a Hosts/Speakers/Listeners roster that opens from the
// room header. Its contents stay live over Turbo Streams; this controller
// only opens and closes the drawer itself.
export default class extends Controller {
  static targets = [ "panel", "toggle" ]

  toggle(event) {
    event?.preventDefault()

    if (this.panelTarget.hidden) {
      this.panelTarget.hidden = false
      this.toggleTarget.setAttribute("aria-expanded", "true")
    } else {
      this.close()
    }
  }

  close(event) {
    event?.preventDefault()

    if (this.panelTarget.hidden) return

    this.panelTarget.hidden = true
    this.toggleTarget.setAttribute("aria-expanded", "false")
  }
}
