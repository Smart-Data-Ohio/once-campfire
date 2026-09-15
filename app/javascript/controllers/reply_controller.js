import { Controller } from "@hotwired/stimulus"

const UNFURLED_ATTACHMENT_SELECTOR = ".og-embed"
const REPLY_PREVIEW_SELECTOR = "[data-reply-target='preview'], [data-reply-preview], [data-message-reply-preview]"

export default class extends Controller {
  static targets = [ "body", "link", "author" ]
  static outlets = [ "composer" ]

  #highlightTimer

  connect() {
    this.#formatLinkTargets()
    this.onReplyRequest = this.#onReplyRequest.bind(this)
    this.onClick = this.#onClick.bind(this)
    window.addEventListener("message:reply", this.onReplyRequest)
    this.element.addEventListener("click", this.onClick)
  }

  disconnect() {
    window.removeEventListener("message:reply", this.onReplyRequest)
    this.element.removeEventListener("click", this.onClick)
  }

  reply(event) {
    event?.preventDefault()

    const detail = {
      message: this.element,
      messageId: this.element.dataset.messageId,
      roomId: this.element.dataset.roomId || document.querySelector("meta[name='current-room-id']")?.content,
      threadId: this.element.dataset.threadId || "",
      author: this.authorTarget?.textContent.trim() || "message",
      previewText: this.#plainBodyContent,
      url: this.linkTarget?.href || "",
      notify: true,
    }

    if (this.hasComposerOutlet && typeof this.composerOutlet.startReply === "function") {
      this.composerOutlet.startReply(detail)
    } else if (this.hasComposerOutlet) {
      // Keep the quote behavior available while an older page is being
      // replaced by the main composer controller.
      this.composerOutlet.replaceMessageContent({ markdown: this.#markdownReply })
    }
  }

  #onReplyRequest(event) {
    if (event.detail?.message === this.element) this.reply(event)
  }

  #onClick(event) {
    const preview = event.target.closest(REPLY_PREVIEW_SELECTOR)
    if (!preview || !this.element.contains(preview)) return

    const targetId = preview.dataset.replyTargetId || preview.dataset.replyMessageId || preview.dataset.messageId || this.#idFromHref(preview.getAttribute("href"))
    const target = this.#findMessage(targetId)
    if (!target) return

    event.preventDefault()
    target.scrollIntoView({ behavior: "smooth", block: "center" })
    target.classList.add("message--reply-target")
    clearTimeout(this.#highlightTimer)
    this.#highlightTimer = setTimeout(() => target.classList.remove("message--reply-target"), 1_800)
  }

  #formatLinkTargets() {
    this.bodyTarget?.querySelectorAll("a").forEach(link => {
      const sameDomain = link.href.startsWith(window.location.origin)
      link.target = sameDomain ? "_top" : "_blank"
    })
  }

  get #markdownReply() {
    const quote = this.#plainBodyContent
      .split("\n")
      .map(line => line.trimEnd() ? `> ${this.#escapeMarkdown(line.trimEnd())}` : ">")
      .join("\n")
    const author = this.#escapeMarkdown(this.authorTarget?.textContent.trim() || "message")
    const href = (this.linkTarget?.href || "").replaceAll("<", "%3C").replaceAll(">", "%3E")

    return `${quote}\n>\n> — ${author} · [View original](<${href}>)\n\n`
  }

  get #plainBodyContent() {
    const body = this.#cleanBodyClone
    body.setAttribute("aria-hidden", "true")
    body.style.cssText = "position: fixed; inset: 0 auto auto -10000px; inline-size: 60ch; pointer-events: none;"
    document.body.append(body)

    const text = (body.innerText || body.textContent || "").trim()
    body.remove()
    return text
  }

  get #cleanBodyClone() {
    const content = this.bodyTarget?.querySelector(".trix-content, .markdown-body") || this.bodyTarget
    const body = content?.cloneNode(true) || document.createElement("div")

    body.querySelectorAll(".mention").forEach(mention => mention.replaceWith(mention.textContent.trim()))
    body.querySelectorAll(UNFURLED_ATTACHMENT_SELECTOR).forEach(embed => embed.remove())
    body.querySelectorAll(".markdown-code-copy, .message__reply-preview, .boosts").forEach(node => node.remove())

    return body
  }

  #findMessage(id) {
    if (!id) return null
    const normalizedId = String(id).replace(/^#/, "")
    return document.getElementById(normalizedId) || document.getElementById(`message_${normalizedId}`)
  }

  #idFromHref(href) {
    if (!href) return null
    const hash = href.split("#").pop()
    if (hash && hash !== href) return hash
    const match = href.match(/(?:messages|threads)[/_-]([^/?#]+)$/)
    return match?.[1]
  }

  #escapeMarkdown(text) {
    return text.replace(/([\\`*_{}\[\]()<>#+\-.!|~>@])/g, "\\$1")
  }
}
