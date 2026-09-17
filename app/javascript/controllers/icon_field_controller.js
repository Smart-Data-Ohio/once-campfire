import { Controller } from "@hotwired/stimulus"
import { escapeHTML } from "helpers/string_helpers"
import { debounce } from "helpers/timing_helpers"

// Live preview and remove control for the icon shortcode field shared by the
// room and bot forms. Autocomplete itself comes from the existing
// markdown-autocomplete controller wired to the same input; this controller
// only renders the preview through the autocompletable icons endpoint.
export default class extends Controller {
  static targets = [ "input", "preview" ]
  static values = { url: String, size: { type: Number, default: 32 } }

  initialize() {
    this.updatePreview = debounce(this.updatePreview.bind(this), 250)
    this.requestId = 0
  }

  preview() {
    this.updatePreview()
  }

  clear(event) {
    event.preventDefault()
    this.requestId++
    this.inputTarget.value = ""
    this.previewTarget.innerHTML = ""
    this.inputTarget.focus()
  }

  updatePreview() {
    const name = this.inputTarget.value.trim().replace(/^:+|:+$/g, "")

    if (!/^[a-z0-9_]{2,}$/.test(name)) {
      this.previewTarget.innerHTML = ""
      return
    }

    const requestId = ++this.requestId

    fetch(`${this.urlValue}?q=${encodeURIComponent(name)}`, { headers: { "Accept": "application/json" } })
      .then(response => response.json())
      .then(icons => {
        if (requestId !== this.requestId) return
        const icon = icons.find(candidate => candidate.name === name)
        this.previewTarget.innerHTML = icon ? this.renderIcon(icon) : ""
      })
      .catch(() => {})
  }

  renderIcon(icon) {
    if (icon.kind === "brand" || icon.kind === "custom") {
      const kindClass = icon.kind === "brand" ? "icon-avatar--brand" : "icon-avatar--custom"
      return `<img class="icon-avatar ${kindClass}" src="${escapeHTML(icon.image)}" alt="${escapeHTML(icon.title)}" width="${this.sizeValue}" height="${this.sizeValue}">`
    } else {
      return `<span class="icon-avatar icon-avatar--emoji" style="font-size: ${this.sizeValue}px" role="img" aria-label="${escapeHTML(icon.title)}">${escapeHTML(icon.character)}</span>`
    }
  }
}
