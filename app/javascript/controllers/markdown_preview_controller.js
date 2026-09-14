import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "source", "writePanel", "previewPanel", "writeTab", "previewTab", "status" ]
  static values = { url: String }

  #abortController
  #previewedSource
  #requestId = 0

  disconnect() {
    this.#abortController?.abort()
  }

  showWrite() {
    this.#cancelRequest()
    this.#show("write")
    this.sourceTarget.focus()
  }

  sourceChanged() {
    if (!this.previewPanelTarget.hidden) this.showWrite()
  }

  async showPreview() {
    this.#show("preview")
    const source = this.sourceTarget.value
    this.#cancelRequest()

    if (!source.trim()) {
      this.#previewedSource = undefined
      this.#showNotice("Nothing to preview yet.")
      return
    }

    if (source === this.#previewedSource) return

    this.#abortController = new AbortController()
    const requestId = ++this.#requestId
    this.previewPanelTarget.setAttribute("aria-busy", "true")
    this.statusTarget.textContent = "Rendering preview…"

    try {
      const formData = new FormData()
      formData.append("message[markdown_source]", source)
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content,
        },
        body: formData,
        credentials: "same-origin",
        signal: this.#abortController.signal,
      })

      if (!response.ok) throw new Error(`Preview failed (${response.status})`)

      const { html } = await response.json()
      if (requestId !== this.#requestId || source !== this.sourceTarget.value || this.previewPanelTarget.hidden) return

      this.previewPanelTarget.innerHTML = html
      this.#previewedSource = source
      this.statusTarget.textContent = "Preview updated."
      this.dispatch("rendered", { target: window, detail: { preview: this.previewPanelTarget } })
    } catch (error) {
      if (error.name !== "AbortError") {
        this.#previewedSource = undefined
        this.#showNotice("Preview unavailable. Keep writing and try again.")
      }
    } finally {
      if (requestId === this.#requestId) this.previewPanelTarget.removeAttribute("aria-busy")
    }
  }

  #show(mode) {
    const writeActive = mode === "write"
    this.writePanelTarget.hidden = !writeActive
    this.previewPanelTarget.hidden = writeActive
    this.writeTabTarget.setAttribute("aria-selected", String(writeActive))
    this.previewTabTarget.setAttribute("aria-selected", String(!writeActive))
  }

  #cancelRequest() {
    this.#abortController?.abort()
    this.#abortController = null
    this.#requestId++
    this.previewPanelTarget.removeAttribute("aria-busy")
  }

  #showNotice(message) {
    const notice = document.createElement("p")
    notice.className = "composer__preview-notice"
    notice.textContent = message
    this.previewPanelTarget.replaceChildren(notice)
    this.statusTarget.textContent = message
  }
}
