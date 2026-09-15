import { Controller } from "@hotwired/stimulus"

// Thread content is a normal server-rendered message stream. This controller
// owns only the conversation viewport so the room timeline's paginator and
// scroll state cannot observe or mutate thread messages.
export default class extends Controller {
  #messages
  #nearBottom = true
  #onMessagesChanged = event => {
    if (event.detail?.atLatest === true) this.#nearBottom = true
    if (event.detail?.atLatest === false) this.#nearBottom = false
  }

  connect() {
    this.#messages = this.element.querySelector(".messages") || this.element
    this.#nearBottom = !this.#messages.closest("[data-messages-anchor-message-id-value]")
    this.#messages.addEventListener("scroll", this.#rememberScroll)
    this.element.addEventListener("thread-messages:changed", this.#onMessagesChanged)
  }

  disconnect() {
    this.#messages?.removeEventListener("scroll", this.#rememberScroll)
    this.element.removeEventListener("thread-messages:changed", this.#onMessagesChanged)
  }

  beforeStreamRender(event) {
    const target = event.detail.newStream?.getAttribute("target")
    if (!target || target !== this.#messages?.id) return

    const render = event.detail.render
    const shouldStick = this.#nearBottom
    event.detail.render = async stream => {
      await render(stream)
      if (shouldStick) this.#scrollToBottom()
      this.element.dispatchEvent(new CustomEvent("thread-messages:changed", {
        bubbles: true,
        detail: {
          // Being near the bottom of an anchored page does not mean that the
          // paginator has reached the actual latest page yet.
          atLatest: this.#nearBottom && this.#messages.dataset.messagesAtLatest === "true",
        },
      }))
    }
  }

  #rememberScroll = () => {
    const element = this.#messages
    if (!element) return
    this.#nearBottom = element.scrollHeight - element.scrollTop - element.clientHeight < 48
  }

  #scrollToBottom() {
    const element = this.#messages
    if (element) element.scrollTop = element.scrollHeight
  }
}
