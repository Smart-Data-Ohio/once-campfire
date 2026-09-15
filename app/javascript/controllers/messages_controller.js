import { Controller } from "@hotwired/stimulus"
import { nextEventLoopTick } from "helpers/timing_helpers"
import ClientMessage from "models/client_message"
import MessageFormatter, { ThreadStyle } from "models/message_formatter"
import MessagePaginator from "models/message_paginator"
import ScrollManager from "models/scroll_manager"

export default class extends Controller {
  static targets = [ "latest", "message", "body", "messages", "template" ]
  static classes = [ "firstOfDay", "formatted", "me", "mentioned", "threaded" ]
  static values = { pageUrl: String, anchorMessageId: String }

  #clientMessage
  #paginator
  #formatter
  #scrollManager

  // Lifecycle

  initialize() {
    this.#formatter = new MessageFormatter(Current.user.id, {
      firstOfDay: this.firstOfDayClass,
      formatted: this.formattedClass,
      me: this.meClass,
      mentioned: this.mentionedClass,
      threaded: this.threadedClass,
    })
  }

  connect() {
    this.#clientMessage = new ClientMessage(this.templateTarget)
    this.#paginator = new MessagePaginator(this.messagesTarget, this.pageUrlValue, this.#formatter, this.#allContentViewed.bind(this))
    this.#scrollManager = new ScrollManager(this.messagesTarget)
    this.#syncAtLatestState()

    if (this.hasAnchorMessageIdValue) {
      this.#paginator.upToDate = false
      this.#syncAtLatestState()
      this.#scrollToAnchor()
    } else if (this.#hasSearchResult) {
      this.#highlightSearchResult()
    } else {
      this.#scrollManager.autoscroll(true)
    }

    this.#paginator.monitor()
  }

  disconnect() {
    this.#paginator.disconnect()
  }

  messageTargetConnected(target) {
    this.#formatter.format(target, ThreadStyle.thread)
  }

  bodyTargetConnected(target) {
    this.#formatter.formatBody(target)
  }

  // Actions

  async beforeStreamRender(event) {
    const target = event.detail.newStream.getAttribute("target")

    if (target === this.messagesTarget.id) {
      const render = event.detail.render
      const upToDate = this.#paginator.upToDate
      const action = event.detail.newStream.getAttribute("action")
      this.#syncAtLatestState()

      if (upToDate) {
        event.detail.render = async (streamElement) => {
          const didScroll = await this.#scrollManager.autoscroll(false, async () => {
            await render(streamElement)
            await nextEventLoopTick()

            this.#positionLastMessage()
            this.#playSoundForLastMessage()
            this.#paginator.trimExcessMessages(true)
          })
          if (!didScroll) {
            this.latestTarget.hidden = false
          }
        }
      } else {
        this.latestTarget.hidden = false
        if (action === "append") {
          // An anchored page is a history window. Appending a live message to
          // its end would make the paginator mistake the window for the
          // latest page and could mark a joined thread read. Jump to newest
          // reloads the actual last page, including the deferred message.
          event.detail.render = async () => {}
        }
      }
    }
  }

  async returnToLatest() {
    this.latestTarget.hidden = true
    await this.#ensureUpToDate()
    this.#syncAtLatestState()
    await this.#scrollManager.autoscroll(true)
    this.#dispatchThreadMessagesChanged()
  }

  async editMyLastMessage(event) {
    const editor = event.target?.closest?.("textarea, trix-editor")
    const composer = editor?.closest("[data-controller~='composer']")
    const outlet = composer?.dataset.composerMessagesOutlet
    if (!editor || !composer || !outlet || document.querySelector(outlet) !== this.element) return
    const editorEmpty = editor instanceof HTMLTextAreaElement ? !editor.value : editor?.matches(":empty")

    if (editor && editorEmpty && this.#paginator.upToDate) {
      const message = this.#myLastMessage
      if (message) {
        window.dispatchEvent(new CustomEvent("message-actions:edit-last", { detail: { message } }))
      }
    }
  }

  recoverPendingMessage(event) {
    const clientMessageId = event.currentTarget.dataset.clientMessageId
    window.dispatchEvent(new CustomEvent("messages:recover", { detail: { clientMessageId } }))
    event.currentTarget.disabled = true
    event.currentTarget.textContent = "Draft restored"
  }


  // Outlet actions

  async insertPendingMessage(clientMessageId, node) {
    await this.#ensureUpToDate()
    this.#syncAtLatestState()

    return this.#scrollManager.autoscroll(true, async () => {
      const message = this.#clientMessage.render(clientMessageId, node)
      this.messagesTarget.insertAdjacentHTML("beforeend", message)
    })
  }

  updatePendingMessage(clientMessageId, body) {
    this.#clientMessage.update(clientMessageId, body)
  }

  failPendingMessage(clientMessageId) {
    this.#clientMessage.failed(clientMessageId)
  }

  // Callbacks

  #allContentViewed() {
    this.latestTarget.hidden = true
    this.#syncAtLatestState()
    this.#dispatchThreadMessagesChanged()
  }

  #syncAtLatestState() {
    if (this.#paginator) this.messagesTarget.dataset.messagesAtLatest = String(this.#paginator.upToDate)
  }

  #dispatchThreadMessagesChanged() {
    if (!this.element.closest(".thread-panel__content")) return
    this.element.dispatchEvent(new CustomEvent("thread-messages:changed", {
      bubbles: true,
      detail: { atLatest: true },
    }))
  }


  // Internal

  async #ensureUpToDate() {
    if (!this.#paginator.upToDate) {
      await this.#paginator.resetToLastPage()
    }
  }

  #highlightSearchResult() {
    const highlightId = location.pathname.split("@").pop()
    const highlightMessage = this.messagesTarget.querySelector(`.message[data-message-id="${highlightId}"]`)
    if (highlightMessage) {
      highlightMessage.classList.add("search-highlight")
      highlightMessage.scrollIntoView({ behavior: "instant", block: "center" })
    }

    this.#paginator.upToDate = false
    this.#syncAtLatestState()
  }

  #scrollToAnchor() {
    const selector = `.message[data-message-id="${CSS.escape(this.anchorMessageIdValue)}"]`
    const anchor = this.messagesTarget.querySelector(selector)
    if (!anchor) return

    anchor.scrollIntoView({ behavior: "instant", block: "center" })
    this.latestTarget.hidden = false
    this.#syncAtLatestState()
  }

  get #hasSearchResult() {
    return location.pathname.includes("@")
  }

  get #lastMessage() {
    return this.messagesTarget.children[this.messagesTarget.children.length - 1]
  }

  get #myLastMessage() {
    const myMessages = this.messagesTarget.querySelectorAll(`.${this.meClass}`)
    return myMessages[myMessages.length - 1]
  }

  #positionLastMessage() {
    const followingMessage = this.#followingMessage(this.#lastMessage)

    if (followingMessage) {
      followingMessage.before(this.#lastMessage)
    }
  }

  #playSoundForLastMessage() {
    const soundTarget = this.#lastMessage.querySelector(".sound")

    if (soundTarget) {
      this.dispatch("play", { target: soundTarget })
    }
  }

  #followingMessage(message) {
    const messageSortValue = this.#sortValue(message)
    let followingMessage = null
    let previousMessage = message.previousElementSibling

    while (messageSortValue < this.#sortValue(previousMessage)) {
      followingMessage = previousMessage
      previousMessage = previousMessage.previousElementSibling;
    }

    return followingMessage
  }

  #sortValue(node) {
    return (node && parseInt(node.dataset.sortValue)) || 0
  }
}
