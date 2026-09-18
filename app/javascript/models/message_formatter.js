import { onNextEventLoopTick } from "helpers/timing_helpers"
import { highlightCodeBlock } from "models/code_highlighter"

const THREADING_TIME_WINDOW_MILLISECONDS = 5 * 60 * 1000 // 5 minutes
const connectedCopyButtons = new WeakSet()

export const ThreadStyle = {
  none: 0,
  thread: 1,
}

export default class MessageFormatter {
  #userId
  #classes
  #dateFormatter = new Intl.DateTimeFormat(undefined, { dateStyle: "short" })

  constructor(userId, classes) {
    this.#userId = userId
    this.#classes = classes
  }

  format(message, threadstyle) {
    this.#setMeClass(message)
    this.#highlightMentions(message)

    if (threadstyle != ThreadStyle.none) {
      this.#threadMessage(message)
      this.#setFirstOfDayClass(message)
    }

    this.#makeVisible(message)
  }

  formatBody(body) {
    this.#highlightCode(body)
  }

  #setMeClass(message) {
    const isMe = message.dataset.userId == this.#userId
    message.classList.toggle(this.#classes.me, isMe)
  }

  #makeVisible(message) {
    message.classList.add(this.#classes.formatted)
  }

  #setFirstOfDayClass(message) {
    let showSeparator = true

    if (message.dataset.messageTimestamp && message.previousElementSibling?.dataset?.messageTimestamp) {
      const prev = new Date(Number(message.previousElementSibling.dataset.messageTimestamp))
      const curr = new Date(Number(message.dataset.messageTimestamp))

      showSeparator = this.#dateFormatter.format(prev) !== this.#dateFormatter.format(curr)
    }

    message.classList.toggle(this.#classes.firstOfDay, showSeparator)
  }

  #threadMessage(message) {
    if (message.previousElementSibling) {
      const isSameUser = message.previousElementSibling.dataset.userId == message.dataset.userId
      const previousMessageIsRecent = this.#previousMessageIsRecent(message)

      message.classList.toggle(this.#classes.threaded, isSameUser && previousMessageIsRecent)
    }
  }

  #highlightMentions(message) {
    const mentionsCurrentUser = message.querySelector(this.#selectorForCurrentUser) !== null
    message.classList.toggle(this.#classes.mentioned, mentionsCurrentUser)
  }

  #highlightCode(body) {
    body.querySelectorAll("pre").forEach(pre => {
      onNextEventLoopTick(() => {
        highlightCodeBlock(pre)
        this.#addCopyButton(pre)
      })
    })
  }

  #addCopyButton(pre) {
    if (!pre.closest(".markdown-body, .markdown-preview")) return

    const button = pre.querySelector(":scope > .markdown-code-copy") || document.createElement("button")
    if (connectedCopyButtons.has(button)) return

    const code = pre.querySelector(":scope > code") || pre
    const sourceText = code.textContent
    button.type = "button"
    button.className = "markdown-code-copy btn btn--borderless txt-small"
    button.textContent = "Copy code"
    button.setAttribute("aria-label", "Copy code")
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(sourceText)
        button.textContent = "Copied"
        button.setAttribute("aria-label", "Code copied")
      } catch {
        button.textContent = "Copy failed"
        button.setAttribute("aria-label", "Could not copy code")
      } finally {
        window.setTimeout(() => {
          button.textContent = "Copy code"
          button.setAttribute("aria-label", "Copy code")
        }, 1600)
      }
    })

    // Turbo caches cloned DOM without event listeners; reconnect cached copy
    // buttons without duplicating handlers on nodes that are still live.
    connectedCopyButtons.add(button)
    pre.append(button)
  }

  #previousMessageIsRecent(message) {
    const previousTimestamp = message.previousElementSibling.dataset.messageTimestamp
    const threadTimestamp = message.dataset.messageTimestamp
    return Math.abs(previousTimestamp - threadTimestamp) <= THREADING_TIME_WINDOW_MILLISECONDS
  }

  get #selectorForCurrentUser() {
    return `.mention[data-user-id="${this.#userId}"], .mention.mention--user-${this.#userId}, .mention img[src^="/users/${this.#userId}/avatar"]`
  }
}
