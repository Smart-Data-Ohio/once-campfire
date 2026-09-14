import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/string_helpers"

export default class extends Controller {
  static targets = [ "clientid", "fields", "fileList", "markdown" ]
  static values = { roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #submitting = false
  #inFlightSubmission
  #failedDrafts = new Map()

  connect() {
    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.markdownTarget.focus())
    }
  }

  submit(event) {
    event.preventDefault()

    if (!this.fieldsTarget.disabled) {
      this.#submitFiles()
      this.#submitMessage()
      this.markdownTarget.focus()
    }
  }

  submitEnd(event) {
    const submission = this.#inFlightSubmission
    this.#submitting = false
    this.#inFlightSubmission = null

    if (!submission) return

    if (event.detail.success) {
      if (this.markdownTarget.value === submission.content) this.#reset()
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
    body.set("message[markdown_source]", submission.content)
    body.delete("message[body]")
  }

  recover(event) {
    const submission = this.#failedDrafts.get(event.detail.clientMessageId)
    if (!submission) return

    const current = this.markdownTarget.value
    this.markdownTarget.value = current === submission.content ? current : [ current, submission.content ].filter(Boolean).join("\n\n")
    this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.#failedDrafts.delete(submission.clientMessageId)
    this.markdownTarget.focus()
  }

  replaceMessageContent({ markdown }) {
    this.markdownTarget.value = markdown
    this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
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

  async #submitMessage() {
    if (!this.#submitting && this.#validInput()) {
      this.#submitting = true
      const clientMessageId = this.#generateClientId()
      const content = this.markdownTarget.value
      const pendingInput = this.markdownTarget.cloneNode(true)
      pendingInput.value = content

      this.#inFlightSubmission = { clientMessageId, content }

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
    return this.markdownTarget.value.trim().length > 0
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

  #reset() {
    this.markdownTarget.value = ""
    this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
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
