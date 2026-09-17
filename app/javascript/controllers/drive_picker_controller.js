import { Controller } from "@hotwired/stimulus"
import { DRIVE_KIND_ICONS, relativeModifiedTime } from "controllers/drive_link_controller"
import { debounce } from "helpers/timing_helpers"

// Composer popover listing the viewer's Google Drive files, recent first and
// filterable by name, so a file link can be inserted without leaving
// Campfire. The button renders only when the layout carries the
// google-drive-previews meta tag; connect double-checks so a stale page
// sends zero requests. Choosing a row inserts the file's webViewLink at the
// caret; the existing preview chip renders it once the message is sent.
let pickerCount = 0

export default class extends Controller {
  static targets = [ "button", "panel", "search", "results", "status" ]

  initialize() {
    this.search = debounce(this.search.bind(this), 300)
  }

  connect() {
    if (!document.querySelector('meta[name="google-drive-previews"][content="enabled"]')) {
      this.element.hidden = true
      return
    }

    this.pickerId = ++pickerCount
    this.isOpen = false
    this.files = []
    this.activeIndex = -1
    this.requestId = 0
    this.onDocumentClick = this.#closeOnClickOutside.bind(this)
    this.resultsTarget.id = `drive-picker-results-${this.pickerId}`
    this.searchTarget.setAttribute("aria-controls", this.resultsTarget.id)
  }

  disconnect() {
    this.close()
  }

  toggle(event) {
    event.preventDefault()
    if (this.isOpen) this.close()
    else this.open()
  }

  open() {
    if (this.isOpen || this.element.hidden) return
    this.isOpen = true
    this.panelTarget.hidden = false
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.searchTarget.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.onDocumentClick)
    this.searchTarget.value = ""
    this.searchTarget.focus()
    this.fetchFiles("")
  }

  close() {
    if (!this.isOpen) return
    this.isOpen = false
    this.requestId++
    this.panelTarget.hidden = true
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.searchTarget.setAttribute("aria-expanded", "false")
    this.searchTarget.removeAttribute("aria-activedescendant")
    document.removeEventListener("click", this.onDocumentClick)
  }

  search() {
    this.fetchFiles(this.searchTarget.value)
  }

  async fetchFiles(query) {
    const requestId = ++this.requestId
    this.#setStatus("Searching Drive…")

    let files = null
    let status = ""
    try {
      const response = await fetch(`/google/drive/files?q=${encodeURIComponent(query)}`, {
        headers: { "Accept": "application/json" }
      })
      if (response.status === 429) {
        status = "Try again in a moment"
      } else if (!response.ok) {
        status = "Drive is unavailable right now"
      } else {
        files = (await response.json()).files || []
        if (files.length === 0) status = "No files found"
      }
    } catch {
      status = "Drive is unavailable right now"
    }

    if (requestId !== this.requestId) return
    this.files = files || []
    this.activeIndex = -1
    this.#renderResults()
    this.#setStatus(status)
  }

  key(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      this.buttonTarget.focus()
      return
    }

    if (event.target !== this.searchTarget) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.#moveActive(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.#moveActive(-1)
    } else if (event.key === "Enter") {
      // Never submit the composer form from the picker search field.
      event.preventDefault()
      if (this.activeIndex >= 0) this.#insert(this.files[this.activeIndex])
    }
  }

  #moveActive(delta) {
    if (this.files.length === 0) return
    this.activeIndex = (this.activeIndex + delta + this.files.length) % this.files.length
    this.#renderResults()

    const active = this.resultsTarget.querySelector(`[data-index="${this.activeIndex}"]`)
    if (active) {
      this.searchTarget.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({ block: "nearest" })
    }
  }

  #renderResults() {
    this.resultsTarget.replaceChildren(
      ...this.files.map((file, index) => this.#optionElement(file, index))
    )
    if (this.activeIndex < 0) this.searchTarget.removeAttribute("aria-activedescendant")
  }

  #optionElement(file, index) {
    const item = document.createElement("li")
    item.className = "drive-picker__item"
    if (index === this.activeIndex) item.classList.add("drive-picker__item--active")
    item.id = `drive-picker-${this.pickerId}-option-${index}`
    item.dataset.index = index
    item.setAttribute("role", "option")
    item.setAttribute("aria-selected", String(index === this.activeIndex))

    const button = document.createElement("button")
    button.type = "button"
    button.className = "drive-picker__option"
    button.tabIndex = -1

    const icon = document.createElement("span")
    icon.className = "drive-picker__icon"
    icon.setAttribute("aria-hidden", "true")
    icon.innerHTML = DRIVE_KIND_ICONS[file.kind] || DRIVE_KIND_ICONS.file

    const text = document.createElement("span")
    text.className = "drive-picker__text"

    const name = document.createElement("span")
    name.className = "drive-picker__name"
    name.textContent = file.name || "Untitled"

    const meta = document.createElement("span")
    meta.className = "drive-picker__meta"
    const modified = file.modified_at ? relativeModifiedTime(file.modified_at) : null
    const parts = []
    if (modified) parts.push(`Modified ${modified}`)
    if (file.owner) parts.push(file.owner)
    meta.textContent = parts.join(" · ")

    text.append(name, meta)
    button.append(icon, text)
    button.addEventListener("click", () => this.#insert(file))
    item.append(button)
    return item
  }

  #insert(file) {
    if (!file?.url) return

    const editor = this.element.closest("form")?.querySelector("textarea")
    if (editor) {
      const start = editor.selectionStart ?? editor.value.length
      const end = editor.selectionEnd ?? editor.value.length
      const before = editor.value.slice(0, start)
      const after = editor.value.slice(end)
      const prefix = before && !/\s$/.test(before) ? " " : ""
      const suffix = after && !/^\s/.test(after) ? " " : ""
      editor.setRangeText(`${prefix}${file.url}${suffix}`, start, end, "end")
      editor.dispatchEvent(new Event("input", { bubbles: true }))
      editor.focus()
    }
    this.close()
  }

  #closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  #setStatus(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = !message
  }
}
