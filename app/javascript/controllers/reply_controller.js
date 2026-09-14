import { Controller } from "@hotwired/stimulus"
import { escapeHTML } from "helpers/string_helpers"

const UNFURLED_ATTACHMENT_SELECTOR = ".og-embed"

export default class extends Controller {
  static targets = [ "body", "link", "author" ]
  static outlets = [ "composer" ]

  connect() {
    this.#formatLinkTargets()
  }

  reply() {
    this.composerOutlet.replaceMessageContent({
      markdown: this.#markdownReply,
      richText: this.#richTextReply,
    })
  }

  #formatLinkTargets() {
    this.bodyTarget.querySelectorAll("a").forEach(link => {
      const sameDomain = link.href.startsWith(window.location.origin)
      link.target = sameDomain ? "_top" : "_blank"
    })
  }

  get #markdownReply() {
    const quote = this.#plainBodyContent
      .split("\n")
      .map(line => line.trimEnd() ? `> ${this.#escapeMarkdown(line.trimEnd())}` : ">")
      .join("\n")
    const author = this.#escapeMarkdown(this.authorTarget.textContent.trim())
    const href = this.linkTarget.href.replaceAll("<", "%3C").replaceAll(">", "%3E")

    return `${quote}\n>\n> — ${author} · [View original](<${href}>)\n\n`
  }

  get #richTextReply() {
    const author = escapeHTML(this.authorTarget.textContent.trim())
    const href = escapeHTML(this.linkTarget.href)
    return `<blockquote>${this.#richBodyContent}</blockquote><cite>${author} <a href="${href}">#</a></cite><br>`
  }

  get #plainBodyContent() {
    const body = this.#cleanBodyClone
    body.setAttribute("aria-hidden", "true")
    body.style.cssText = "position: fixed; inset: 0 auto auto -10000px; inline-size: 60ch; pointer-events: none;"
    document.body.append(body)

    const text = body.innerText.trim()
    body.remove()
    return text
  }

  get #richBodyContent() {
    return this.#cleanBodyClone.innerHTML
  }

  get #cleanBodyClone() {
    const content = this.bodyTarget.querySelector(".trix-content, .markdown-body") || this.bodyTarget
    const body = content.cloneNode(true)

    body.querySelectorAll(".mention").forEach(mention => mention.replaceWith(mention.textContent.trim()))

    const firstUnfurledLink = body.querySelector(`${UNFURLED_ATTACHMENT_SELECTOR} a`)?.href
    body.querySelectorAll(UNFURLED_ATTACHMENT_SELECTOR).forEach(embed => embed.remove())
    body.querySelectorAll(".markdown-code-copy").forEach(button => button.remove())

    if (firstUnfurledLink && !body.textContent.trim()) body.textContent = firstUnfurledLink
    return body
  }

  #escapeMarkdown(text) {
    return text.replace(/([\\`*_{}\[\]()<>#+\-.!|~>@])/g, "\\$1")
  }
}
