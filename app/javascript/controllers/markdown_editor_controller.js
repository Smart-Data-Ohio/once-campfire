import { Controller } from "@hotwired/stimulus"

const PLACEHOLDERS = {
  bold: "bold text",
  italic: "italic text",
  strike: "struck text",
  code: "code",
}

export default class extends Controller {
  static targets = [ "source" ]

  connect() {
    this.resize()
  }

  resize() {
    this.sourceTarget.style.blockSize = "auto"
    this.sourceTarget.style.blockSize = `${this.sourceTarget.scrollHeight}px`
  }

  format(event) {
    event.preventDefault()

    const style = event.params.style
    if ([ "bold", "italic", "strike", "code" ].includes(style)) {
      this.#wrapSelection(style)
    } else if (style === "link") {
      this.#insertLink()
    } else if (style === "fence") {
      this.#insertFence()
    } else {
      this.#prefixLines(style)
    }
  }

  shortcut(event) {
    if (!(event.metaKey || event.ctrlKey) || event.altKey) return

    const style = { b: "bold", i: "italic", k: "link" }[event.key.toLowerCase()]
    if (style) {
      event.preventDefault()
      this.#wrapOrLink(style)
    }
  }

  #wrapOrLink(style) {
    style === "link" ? this.#insertLink() : this.#wrapSelection(style)
  }

  #wrapSelection(style) {
    const markers = { bold: "**", italic: "*", strike: "~~", code: "`" }
    const marker = markers[style]
    const selected = this.#selectedText || PLACEHOLDERS[style]
    const replacement = `${marker}${selected}${marker}`
    const selectStart = this.sourceTarget.selectionStart + marker.length

    this.#replaceSelection(replacement, selectStart, selectStart + selected.length)
  }

  #insertLink() {
    const label = this.#selectedText || "link text"
    const prefix = `[${label}](`
    const url = "https://"
    const replacement = `${prefix}${url})`
    const selectStart = this.sourceTarget.selectionStart + prefix.length

    this.#replaceSelection(replacement, selectStart, selectStart + url.length)
  }

  #insertFence() {
    const selected = this.#selectedText || "code"
    const needsLeadingNewline = this.sourceTarget.selectionStart > 0 && this.sourceTarget.value[this.sourceTarget.selectionStart - 1] !== "\n"
    const prefix = `${needsLeadingNewline ? "\n" : ""}\`\`\`\n`
    const replacement = `${prefix}${selected}\n\`\`\``
    const selectStart = this.sourceTarget.selectionStart + prefix.length

    this.#replaceSelection(replacement, selectStart, selectStart + selected.length)
  }

  #prefixLines(style) {
    const prefixes = { heading: "## ", quote: "> ", list: "- ", ordered: "1. " }
    const prefix = prefixes[style]
    if (!prefix) return

    const value = this.sourceTarget.value
    const selectionStart = this.sourceTarget.selectionStart
    const selectionEnd = this.sourceTarget.selectionEnd
    const lineStart = value.lastIndexOf("\n", selectionStart - 1) + 1
    const nextNewline = value.indexOf("\n", selectionEnd)
    const lineEnd = nextNewline === -1 ? value.length : nextNewline
    const selectedLines = value.slice(lineStart, lineEnd)
    const replacement = selectedLines.split("\n").map(line => `${prefix}${line}`).join("\n")

    this.sourceTarget.setSelectionRange(lineStart, lineEnd)
    this.#replaceSelection(replacement, lineStart, lineStart + replacement.length)
  }

  #replaceSelection(replacement, selectionStart, selectionEnd) {
    this.sourceTarget.setRangeText(replacement, this.sourceTarget.selectionStart, this.sourceTarget.selectionEnd, "end")
    this.sourceTarget.focus()
    this.sourceTarget.setSelectionRange(selectionStart, selectionEnd)
    this.sourceTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  get #selectedText() {
    return this.sourceTarget.value.slice(this.sourceTarget.selectionStart, this.sourceTarget.selectionEnd)
  }
}
