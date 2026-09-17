import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/string_helpers"

export default class extends Controller {
  static targets = [
    "clientid", "fields", "fileList", "markdown", "context", "contextLabel", "contextPreview",
    "notifyControl", "replyNotify", "replyTo", "send", "feedback"
  ]
  static values = { roomId: Number, threadId: String }
  static outlets = [ "messages" ]

  #files = []
  #submitting = false
  #inFlightSubmission
  #failedDrafts = new Map()
  #mode
  #savedDraft
  #abortController
  #editSubmission

  connect() {
    this.onEditRequest = this.#startEditFromEvent.bind(this)
    window.addEventListener("message:edit", this.onEditRequest)

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.markdownTarget?.focus())
    }
  }

  disconnect() {
    window.removeEventListener("message:edit", this.onEditRequest)
    this.#abortController?.abort()
  }

  submit(event) {
    event.preventDefault()

    if (this.#mode?.type === "edit") {
      this.#submitEdit()
      return
    }

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

    if (!submission || !this.#isCurrentRoom(submission.roomId)) return

    if (event.detail.success) {
      if (this.markdownTarget.value === submission.content) {
        this.#reset()
      } else {
        // A new draft may have been typed while Turbo was waiting for the
        // previous send. Keep it, but do not accidentally make it a reply.
        this.#clearReplyContext()
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
    if (!this.#isCurrentRoom(submission.roomId)) return

    body.set("message[client_message_id]", submission.clientMessageId)
    body.set("message[markdown_source]", submission.content)
    body.delete("message[body]")

    if (submission.reply?.id) {
      body.set("message[reply_to_message_id]", submission.reply.id)
      body.set("message[reply_notify_author]", submission.reply.notify ? "1" : "0")
    } else {
      body.delete("message[reply_to_message_id]")
      body.delete("message[reply_notify_author]")
    }
  }

  recover(event) {
    const submission = this.#failedDrafts.get(event.detail.clientMessageId)
    if (!submission || !this.#isCurrentRoom(submission.roomId)) return

    const current = this.markdownTarget.value
    this.#setMarkdownValue(current === submission.content ? current : [ current, submission.content ].filter(Boolean).join("\n\n"))
    this.#failedDrafts.delete(submission.clientMessageId)
    this.markdownTarget.focus()
  }

  replaceMessageContent({ markdown }) {
    this.#setMarkdownValue(markdown)
  }

  startReply(detail = {}) {
    if (!detail.messageId || !this.#isCurrentConversation(detail.roomId, detail.threadId) || this.#submitting && this.#mode?.type === "edit") return

    if (this.#mode?.type === "edit") this.#restoreSavedDraft()

    const reply = {
      id: String(detail.messageId),
      roomId: detail.roomId,
      threadId: detail.threadId,
      author: detail.author || "message",
      previewText: detail.previewText || "",
      url: detail.url || "",
      notify: detail.notify !== false,
    }
    this.#mode = { type: "reply", ...reply }
    this.#activateReply(reply)
    this.#focusComposer()
  }

  startEdit(detail = {}) {
    if (!detail.messageId || !this.#isCurrentConversation(detail.roomId, detail.threadId) || this.#submitting) return

    const source = typeof detail.source === "string" ? detail.source : ""
    if (!source.trim()) {
      this.#showFeedback("This message does not have an editable source yet.")
      return
    }

    if (this.#mode?.type === "edit" && this.#mode.id === String(detail.messageId)) {
      this.markdownTarget.focus()
      return
    }

    if (this.#mode?.type === "edit") this.#restoreSavedDraft()

    this.#savedDraft = this.#captureDraft()
    this.#mode = {
      type: "edit",
      id: String(detail.messageId),
      roomId: detail.roomId,
      threadId: detail.threadId,
      url: detail.messageUrl || detail.updateUrl || detail.url,
      format: detail.sourceFormat || "markdown",
      previewText: detail.previewText || "",
    }

    this.#clearReplyInputs()
    this.#setContext("Editing Message", detail.previewText || "")
    this.#setMarkdownValue(source)
    this.#focusComposer()
  }

  cancelContext(event) {
    event?.preventDefault()
    if (this.#mode?.type === "edit") {
      this.#abortController?.abort()
      this.#abortController = null
      this.#editSubmission = null
      this.#submitting = false
      this.#setBusy(false)
      this.#restoreSavedDraft()
    } else if (this.#mode?.type === "reply") {
      this.#mode = null
      this.#clearContext()
      this.#focusComposer()
    }
  }

  notifyChanged() {
    if (this.#mode?.type === "reply") this.#mode.notify = this.replyNotifyTarget.checked
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

  dropFiles({ detail: { files, source } }) {
    if (source && !this.#ownsDropSource(source)) return
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

  submitByKeyboard(event) {
    if (event.defaultPrevented || event.key !== "Enter" || event.isComposing || event.keyCode === 229) return

    const modifiedEnter = event.metaKey || event.ctrlKey
    const plainEnter = !event.shiftKey && !event.altKey && !modifiedEnter

    if (modifiedEnter || (plainEnter && !this.#usingTouchDevice)) {
      this.submit(event)
    }
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

      this.#inFlightSubmission = {
        clientMessageId,
        content,
        roomId: this.roomIdValue,
        reply: this.#mode?.type === "reply" ? { id: this.#mode.id, notify: this.#mode.notify !== false } : null,
      }

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

  #startEditFromEvent(event) {
    this.startEdit(event.detail || {})
  }

  async #submitFiles() {
    const files = this.#files
    const mode = this.#mode
    const reply = mode?.type === "reply" ? { id: mode.id, notify: mode.notify !== false } : null
    const hasText = this.#validInput()
    let allSucceeded = true

    this.#files = []
    this.#updateFileList()

    for (const file of files) {
      const clientMessageId = this.#generateClientId()
      const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this), reply)

      const body = this.#pendingUploadProgress(file.name)
      await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

      try {
        const response = await uploader.upload()
        Turbo.renderStreamMessage(response)
      } catch {
        allSucceeded = false
        this.messagesOutlet.failPendingMessage(clientMessageId)
      }
    }

    if (files.length && !hasText && allSucceeded && this.#mode === mode && this.element.isConnected) {
      this.#clearReplyContext()
    }
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  async #submitEdit() {
    const edit = this.#mode
    if (!edit || edit.type !== "edit" || this.#submitting) return
    if (!this.#isCurrentConversation(edit.roomId, edit.threadId)) return

    const content = this.markdownTarget.value
    if (!this.#validInput()) {
      this.#showFeedback("Message cannot be blank.")
      return
    }

    this.#submitting = true
    this.#editSubmission = { ...edit, content }
    this.#abortController = new AbortController()
    this.#setBusy(true)
    this.#clearFeedback()

    const body = new FormData()
    if (edit.format === "rich_text") {
      // The action metadata endpoint supplies a Markdown source for legacy
      // rich-text messages. Keep this branch for older servers that label it
      // as rich_text while still accepting the faithful source.
      body.set("message[markdown_source]", content)
    } else {
      body.set("message[markdown_source]", content)
    }

    try {
      const response = await fetch(edit.url, {
        method: "PATCH",
        headers: {
          Accept: "application/json, text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
        },
        body,
        signal: this.#abortController.signal,
      })

      if (!response.ok) throw new Error(await this.#responseError(response))

      const contentType = response.headers.get("content-type") || ""
      if (contentType.includes("turbo-stream")) Turbo.renderStreamMessage(await response.text())

      if (this.#mode?.type === "edit" && this.#mode.id === edit.id && this.#isCurrentConversation(edit.roomId, edit.threadId)) {
        this.#restoreSavedDraft({ submittedContent: content })
      }
    } catch (error) {
      if (error.name !== "AbortError" && this.#mode?.type === "edit" && this.#mode.id === edit.id) {
        this.#showFeedback(error.message || "Couldn’t save message.")
      }
    } finally {
      if (this.#editSubmission?.id === edit.id) {
        this.#submitting = false
        this.#editSubmission = null
        this.#setBusy(false)
        this.#abortController = null
      }
    }
  }

  async #responseError(response) {
    const fallback = `Couldn’t save message (${response.status})`
    try {
      const payload = await response.clone().json()
      const errors = payload.errors || payload.error
      if (typeof errors === "string") return errors
      if (errors && typeof errors === "object") {
        const message = Object.values(errors).flat().find(Boolean)
        if (message) return String(message)
      }
    } catch {}
    return fallback
  }

  #captureDraft() {
    return {
      content: this.markdownTarget.value,
      files: [ ...this.#files ],
      reply: this.#mode?.type === "reply" ? { ...this.#mode } : null,
    }
  }

  #restoreSavedDraft({ submittedContent } = {}) {
    const saved = this.#savedDraft
    const current = this.markdownTarget.value
    const content = submittedContent !== undefined && current !== submittedContent ? current : saved?.content || ""
    const reply = saved?.reply

    this.#savedDraft = null
    this.#mode = null
    this.#clearContext()
    this.#setMarkdownValue(content)
    this.#files = saved?.files ? [ ...saved.files ] : []
    this.#updateFileList()

    if (reply?.id) {
      this.#mode = { type: "reply", ...reply }
      this.#activateReply(this.#mode)
    }
    this.#focusComposer()
  }

  #activateReply(reply) {
    this.#setReplyInputs(reply)
    this.#setContext(`Replying to ${reply.author || "message"}`, reply.previewText || "")
  }

  #setReplyInputs(reply) {
    if (this.hasReplyToTarget) this.replyToTarget.value = reply?.id || ""
    if (this.hasReplyNotifyTarget) {
      this.replyNotifyTarget.disabled = !reply
      this.replyNotifyTarget.checked = reply ? reply.notify !== false : true
    }
    if (this.hasNotifyControlTarget) this.notifyControlTarget.hidden = !reply
  }

  #clearReplyInputs() {
    this.#setReplyInputs(null)
  }

  #clearReplyContext() {
    if (this.#mode?.type === "reply") this.#mode = null
    this.#clearContext()
  }

  #setContext(label, preview) {
    if (!this.hasContextTarget) return
    this.contextTarget.hidden = false
    if (this.hasContextLabelTarget) this.contextLabelTarget.textContent = label
    if (this.hasContextPreviewTarget) this.contextPreviewTarget.textContent = preview
  }

  #clearContext() {
    this.#clearReplyInputs()
    if (!this.hasContextTarget) return
    this.contextTarget.hidden = true
    if (this.hasContextLabelTarget) this.contextLabelTarget.textContent = ""
    if (this.hasContextPreviewTarget) this.contextPreviewTarget.textContent = ""
    this.#clearFeedback()
  }

  #setMarkdownValue(value) {
    this.markdownTarget.value = value
    this.markdownTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  #reset() {
    this.#mode = null
    this.#savedDraft = null
    this.#setMarkdownValue("")
    this.#clearContext()
  }

  #setBusy(busy) {
    if (this.hasSendTarget) this.sendTarget.disabled = busy
    if (this.hasContextTarget) this.contextTarget.toggleAttribute("aria-busy", busy)
  }

  #showFeedback(message) {
    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = message
      this.feedbackTarget.hidden = false
    }
  }

  #clearFeedback() {
    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = ""
      this.feedbackTarget.hidden = true
    }
  }

  #focusComposer() {
    if (this.#usingTouchDevice) this.markdownTarget.scrollIntoView?.({ block: "nearest" })
    onNextEventLoopTick(() => this.markdownTarget?.focus())
  }

  #isCurrentRoom(roomId) {
    if (roomId && String(roomId) !== String(this.roomIdValue)) return false
    const currentRoomId = document.querySelector("meta[name='current-room-id']")?.content
    return Boolean(currentRoomId) && String(currentRoomId) === String(this.roomIdValue)
  }

  #isCurrentConversation(roomId, threadId) {
    if (!this.#isCurrentRoom(roomId)) return false

    const requestedThreadId = threadId ? String(threadId) : ""
    const composerThreadId = this.threadIdValue ? String(this.threadIdValue) : ""
    return requestedThreadId === composerThreadId
  }

  #ownsDropSource(source) {
    if (this.element.contains(source)) return true
    return this.hasMessagesOutlet && source === this.messagesOutlet.element
  }

  #validInput() {
    return this.markdownTarget.value.trim().length > 0 || this.#hasDriveAttachments()
  }

  // Pending Drive chips make a textless message sendable, like a file
  // upload does; the server validates the ids themselves.
  #hasDriveAttachments() {
    return Array.from(this.element.querySelectorAll(".composer__drive-attachments input[name='message[drive_file_ids][]']"))
      .some((input) => input.value.trim() !== "")
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
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
