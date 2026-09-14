import { Controller } from "@hotwired/stimulus"

const PLACEHOLDERS = { bold: "bold text", italic: "italic text" }

export default class extends Controller {
  static targets = [ "source" ]

  connect() {
    this.resize()
  }

  resize() {
    this.sourceTarget.style.blockSize = "auto"
    this.sourceTarget.style.blockSize = `${this.sourceTarget.scrollHeight}px`
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
    const markers = { bold: "**", italic: "*" }
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
