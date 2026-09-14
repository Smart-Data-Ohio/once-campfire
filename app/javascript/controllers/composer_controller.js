import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/string_helpers"

export default class extends Controller {
  static targets = [ "clientid", "fields", "fileList", "markdown", "markdownPanel", "richText", "richTextPanel", "modeLabel" ]
  static values = { roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #mode = "markdown"
  #submitting = false
  #inFlightSubmission
  #failedDrafts = new Map()

  connect() {
    this.#setMode("markdown")

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.#activeInput.focus())
    }
  }

  submit(event) {
    event.preventDefault()

    if (!this.fieldsTarget.disabled) {
      this.#submitFiles()
      this.#submitMessage()
      this.#activeInput.focus()
    }
  }

  submitEnd(event) {
    const submission = this.#inFlightSubmission
    this.#submitting = false
    this.#inFlightSubmission = null

    if (!submission) return

    if (event.detail.success) {
      if (this.#mode === submission.mode && this.#contentForMode(submission.mode) === submission.content) {
        this.#reset(submission.mode)
      }
      this.#failedDrafts.delete(submission.clientMessageId)
    } else {
      this.#failedDrafts.set(submission.clientMessageId, submission)
      this.messagesOutlet.failPendingMessage(submission.clientMessageId)
    }
  }

  prepareRequest(event) {
    const submission = this.#inFlightSubmission
    const body = event.detail.fetchOptions.body
    if (!submission || !(body instanceof FormData || body instanceof URLSearchParams)) return

    body.set("message[client_message_id]", submission.clientMessageId)

    if (submission.mode === "markdown") {
      body.set("message[markdown_source]", submission.content)
      body.delete("message[body]")
    } else {
      body.set("message[body]", submission.content)
      body.delete("message[markdown_source]")
    }
  }

  recover(event) {
    const submission = this.#failedDrafts.get(event.detail.clientMessageId)
    if (!submission) return

    this.#setMode(submission.mode)
    const current = this.#contentForMode(submission.mode)

    if (submission.mode === "markdown") {
      this.markdownTarget.value = current === submission.content ? current : [ current, submission.content ].filter(Boolean).join("\n\n")
      this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
    } else {
      const recovered = current === submission.content ? current : [ current, submission.content ].filter(Boolean).join("<br>")
      this.richTextTarget.editor.loadHTML(recovered)
    }

    this.#failedDrafts.delete(submission.clientMessageId)
    this.#activeInput.focus()
  }

  toggleMode() {
    this.#setMode(this.#mode === "markdown" ? "rich-text" : "markdown")
    onNextEventLoopTick(() => this.#activeInput.focus())
  }

  replaceMessageContent({ markdown, richText }) {
    if (this.#mode === "markdown") {
      this.markdownTarget.value = markdown
      this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
    } else {
      const editor = this.richTextTarget.editor

      editor.recordUndoEntry("Format reply")
      editor.setSelectedRange([ 0, editor.getDocument().toString().length ])
      editor.deleteInDirection("forward")
      editor.insertHTML(richText)
      editor.setSelectedRange([ editor.getDocument().toString().length - 1 ])
    }
  }

  submitByKeyboard(event) {
    if (event.defaultPrevented || event.key !== "Enter" || event.isComposing || event.keyCode === 229) return

    const modifiedEnter = event.metaKey || event.ctrlKey
    const plainEnter = !event.shiftKey && !event.altKey && !modifiedEnter

    if (modifiedEnter || (plainEnter && !this.#usingTouchDevice)) {
      this.submit(event)
    }
  }

  filePicked(event) {
    this.#addFiles(event.target.files)
    event.target.value = null
  }

  fileUnpicked(event) {
    this.#files.splice(event.params.index, 1)
    this.#updateFileList()
  }

  pasteFiles(event) {
    if (event.clipboardData.files.length > 0) {
      event.preventDefault()
      this.#addFiles(event.clipboardData.files)
    }
  }

  dropFiles({ detail: { files } }) {
    this.#addFiles(files)
  }

  preventAttachment(event) {
    event.preventDefault()
  }

  online() {
    this.fieldsTarget.disabled = false
  }

  offline() {
    this.fieldsTarget.disabled = true
  }

  get #usingTouchDevice() {
    return window.matchMedia("(pointer: coarse), (max-width: 48rem)").matches
  }

  get #activeInput() {
    return this.#mode === "markdown" ? this.markdownTarget : this.richTextTarget
  }

  async #submitMessage() {
    if (!this.#submitting && this.#validInput()) {
      this.#submitting = true
      const clientMessageId = this.#generateClientId()
      const mode = this.#mode
      const content = this.#contentForMode(mode)
      const pendingInput = this.#activeInput.cloneNode(true)
      if (pendingInput instanceof HTMLTextAreaElement) pendingInput.value = content

      this.#inFlightSubmission = { clientMessageId, mode, content }

      try {
        await this.messagesOutlet.insertPendingMessage(clientMessageId, pendingInput)
        await nextFrame()

        this.clientidTarget.value = clientMessageId
        this.element.requestSubmit()
      } catch (error) {
        this.#submitting = false
        this.#inFlightSubmission = null
        throw error
      }
    }
  }

  #validInput() {
    const content = this.#mode === "markdown" ? this.markdownTarget.value : this.richTextTarget.textContent
    return content.trim().length > 0
  }

  async #submitFiles() {
    const files = this.#files

    this.#files = []
    this.#updateFileList()

    for (const file of files) {
      const clientMessageId = this.#generateClientId()
      const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this))

      const body = this.#pendingUploadProgress(file.name)
      await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

      try {
        const response = await uploader.upload()
        Turbo.renderStreamMessage(response)
      } catch {
        this.messagesOutlet.failPendingMessage(clientMessageId)
      }
    }
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #reset(mode) {
    if (mode === "markdown") {
      this.markdownTarget.value = ""
      this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
    } else {
      this.richTextTarget.editor.loadHTML("")
    }
  }

  #contentForMode(mode) {
    return mode === "markdown" ? this.markdownTarget.value : this.#richTextInput.value
  }

  #setMode(mode) {
    this.#mode = mode
    const markdownActive = mode === "markdown"

    this.markdownPanelTarget.hidden = !markdownActive
    this.richTextPanelTarget.hidden = markdownActive
    this.markdownTarget.disabled = !markdownActive
    this.#richTextInput.disabled = markdownActive
    this.modeLabelTarget.textContent = markdownActive ? "Rich text" : "Markdown"
    const modeButton = this.modeLabelTarget.closest("button")
    modeButton.setAttribute("aria-label", this.modeLabelTarget.textContent)
    modeButton.setAttribute("aria-pressed", String(!markdownActive))
  }

  get #richTextInput() {
    return document.getElementById(this.richTextTarget.getAttribute("input"))
  }

  #addFiles(files) {
    this.#files.push(...files)
    this.#updateFileList()
  }

  #updateFileList() {
    this.#files.sort((a, b) => a.name.localeCompare(b.name))

    const fileNodes = this.#files.map((file, index) => {
      const parts = file.name.split(".")
      const extension = parts.length > 1 ? `.${parts.pop()}` : ""
      const filename = parts.join(".") || file.name

      const node = document.createElement("button")
      node.type = "button"
      node.style.gap = "0"
      node.dataset.action = "composer#fileUnpicked"
      node.dataset.composerIndexParam = index
      node.className = "btn btn--plain composer__file txt-normal position-relative unpad flex-column"
      node.setAttribute("aria-label", `Remove ${file.name}`)

      if (file.type.match(/^image\//)) {
        const image = document.createElement("img")
        image.role = "presentation"
        image.className = "flex-item-no-shrink composer__file-thumbnail"
        image.src = URL.createObjectURL(file)
        image.addEventListener("load", () => URL.revokeObjectURL(image.src), { once: true })
        node.append(image)
      } else {
        const thumbnail = document.createElement("span")
        thumbnail.className = "composer__file-thumbnail composer__file-thumbnail--common colorize--black"
        node.append(thumbnail)
      }

      const caption = document.createElement("span")
      caption.className = "pad-inline txt-small flex align-center max-width composer__file-caption"
      const name = document.createElement("span")
      name.className = "overflow-ellipsis"
      name.textContent = filename
      const suffix = document.createElement("span")
      suffix.className = "flex-item-no-shrink"
      suffix.textContent = extension
      caption.append(name, suffix)
      node.append(caption)

      return node
    })

    this.fileListTarget.replaceChildren(...fileNodes)
  }

  #pendingUploadProgress(filename, percent = 0) {
    return `
      <div class="message__pending-upload flex align-center gap" style="--percentage: ${percent}%">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapeHTML(filename)} - <span>${percent}%</span></div>
      </div>
    `
  }
}
