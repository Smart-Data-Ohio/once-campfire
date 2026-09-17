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

  // A successful Go live submits the stream over Turbo first; only then does
  // the huddle panel start sharing at the chosen quality. A failed submit —
  // a listener's 403, a 409 while someone else is live — dispatches nothing.
  streamSubmitted(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement) || event.detail?.success !== true) return

    const roomId = Number(form.dataset.roomId)
    const quality = form.querySelector("select[name='quality']")?.value
    if (!Number.isInteger(roomId) || roomId <= 0) return

    window.dispatchEvent(new CustomEvent("huddle:stream-start", { detail: { roomId, quality } }))
  }

  // Stop stream ends the server state through the form's own DELETE; once it
  // lands, the presenting browser stops sharing too. Ordering it after the
  // DELETE keeps a failed stop consistent: the share keeps going while live.
  streamStopSubmitted(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement) || event.detail?.success !== true) return

    const roomId = Number(form.dataset.roomId)
    if (!Number.isInteger(roomId) || roomId <= 0) return

    window.dispatchEvent(new CustomEvent("huddle:stream-stop", { detail: { roomId } }))
  }
}
