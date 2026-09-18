import { Controller } from "@hotwired/stimulus"
import { DriveShareClient, DriveShareError } from "models/drive_share_client"
import {
  MAX_DRIVE_ATTACHMENTS_PER_MESSAGE,
  canonicalDriveFileUrl,
  driveKindFromMimeType,
  pinDriveAttachment,
  pinnedDriveFileIds,
  validDriveFileId
} from "helpers/drive_attachments"

// Enhanced Drive composer button: picks a file with the official Google
// Picker, then offers to attach it as-is or explicitly grant the current
// chat recipients reader access first. Renders only when the layout
// carries the google-drive-share meta tag (see RoomsHelper); otherwise
// the composer falls back to the legacy drive-picker.
//
// Authorization uses Google Identity Services with ONLY the drive.file
// scope and include_granted_scopes:false. The access token lives in JS
// memory alone: it is never written to the DOM, hidden fields, Turbo
// snapshots, storage, logs, or the server, and it is cleared on Turbo
// cache, navigation, and disconnect. Drive REST is called directly from
// the browser with an Authorization header. The server-side
// Calendar/metadata connection is untouched; recipients endpoints only
// return and validate room-member user ids, never tokens.
//
// One file per selection (repeatable up to the usual 10 attachments).
// Folders and shortcuts can be attached but never shared. Grants are
// reader-only, silent (sendNotificationEmail=false), and happen only
// through the review dialog's explicit grant action.
const DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"
const GIS_SCRIPT_URL = "https://accounts.google.com/gsi/client"
const GAPI_SCRIPT_URL = "https://apis.google.com/js/api.js"
const FOLDER_MIME_TYPE = "application/vnd.google-apps.folder"
const SHORTCUT_MIME_TYPE = "application/vnd.google-apps.shortcut"

// Cross-instance script state: loading starts on first intent and is
// shared so concurrent composers load the official scripts once.
let scriptsPromise = null

function gisLoaded() {
  return typeof window.google?.accounts?.oauth2?.initTokenClient === "function"
}

function pickerApiLoaded() {
  return typeof window.google?.picker?.PickerBuilder === "function"
}

function scriptsReady() {
  return gisLoaded() && pickerApiLoaded()
}

function loadScript(url) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = url
    script.async = true
    script.defer = true
    script.onload = () => resolve()
    script.onerror = () => reject(new Error(`failed to load ${url}`))
    document.head.append(script)
  })
}

function loadGoogleScripts() {
  if (!scriptsPromise) {
    scriptsPromise = (async () => {
      if (!gisLoaded()) await loadScript(GIS_SCRIPT_URL)
      if (!pickerApiLoaded()) {
        if (typeof window.gapi?.load !== "function") await loadScript(GAPI_SCRIPT_URL)
        await new Promise((resolve, reject) => {
          try {
            window.gapi.load("picker", { callback: resolve, onerror: reject, timeout: 15000, ontimeout: reject })
          } catch (error) {
            reject(error)
          }
        })
        if (!pickerApiLoaded()) throw new Error("picker API did not load")
      }
    })().catch((error) => {
      // A later retry must reload rather than reuse the rejection.
      scriptsPromise = null
      throw error
    })
  }
  return scriptsPromise
}

export default class extends Controller {
  static targets = [ "button", "panel" ]
  static values = { roomId: Number, threadId: String }

  connect() {
    if (!document.querySelector('meta[name="google-drive-share"][content="enabled"]')) {
      this.element.hidden = true
      return
    }

    this.flowId = 0
    this.phase = "idle"
    this.accessToken = null
    this.tokenClient = null
    this.afterAuth = null
    this.picker = null
    this.dialog = null
    this.abortController = null
    this.flowRoomId = null
    this.flowThreadId = null
    this.onTurboCache = this.#dispose.bind(this)
    this.onFormSubmitEnd = this.#clearAttachmentsOnSubmit.bind(this)
    document.addEventListener("turbo:before-cache", this.onTurboCache)
    this.form?.addEventListener("turbo:submit-end", this.onFormSubmitEnd)
  }

  disconnect() {
    this.#dispose()
    document.removeEventListener("turbo:before-cache", this.onTurboCache)
    this.form?.removeEventListener("turbo:submit-end", this.onFormSubmitEnd)
  }

  get form() {
    return this.element.closest("form")
  }

  get attachmentsStrip() {
    return this.form?.querySelector(".composer__drive-attachments")
  }

  // Entry point. When the official scripts are already loaded this click
  // is the gesture that requests the Google token; on first use the
  // scripts load now and a Continue button takes the later gesture, so a
  // slow network never loses authorization to an expired activation.
  open(event) {
    event.preventDefault()
    if (this.element.hidden) return

    if (this.phase === "review" || this.phase === "granting") {
      this.dialog?.querySelector("button:not([disabled])")?.focus()
      return
    }
    // "continue" means the scripts finished loading and the panel offers
    // a Continue button; pressing the Drive button itself works the same.
    if (this.phase !== "idle" && this.phase !== "continue") return

    const config = this.#config()
    if (!config) {
      this.#showPanel("Drive sharing is not set up.", { action: null })
      return
    }

    const flowId = ++this.flowId
    this.flowRoomId = this.roomIdValue
    this.flowThreadId = this.threadIdValue

    if (scriptsReady()) {
      this.#requestToken(flowId)
      return
    }

    this.phase = "loading"
    this.#showPanel("Loading Google Drive…", { action: null })

    loadGoogleScripts().then(
      () => {
        if (!this.#current(flowId)) return
        if (!scriptsReady()) {
          this.#failToIdle(flowId, "Google Drive did not load.", { retry: "Try again" })
          return
        }
        this.phase = "continue"
        this.#showPanel("Google Drive is ready.", { action: "Continue with Google", onAction: () => this.#requestToken(flowId) })
      },
      () => {
        if (!this.#current(flowId)) return
        this.#failToIdle(flowId, "Google Drive could not be reached. Check your connection.", { retry: "Try again" })
      }
    )
  }

  // Inline panel action (Continue / Try again). Always a fresh user
  // gesture, so token requests from here keep their activation.
  panelAction(event) {
    event.preventDefault()
    this.panelHandler?.(this.flowId)
  }

  #config() {
    const content = (name) => document.querySelector(`meta[name="${name}"]`)?.content?.trim() || ""
    const clientId = content("google-picker-client-id")
    const apiKey = content("google-picker-api-key")
    const projectNumber = content("google-cloud-project-number")
    if (!clientId || !apiKey || !projectNumber) return null
    return { clientId, apiKey, projectNumber }
  }

  #requestToken(flowId) {
    if (!this.#current(flowId)) return
    const config = this.#config()
    if (!config) {
      this.#failToIdle(flowId, "Drive sharing is not set up.", { retry: null })
      return
    }

    this.phase = "authorizing"
    this.#showPanel("Waiting for Google authorization…", {
      action: "Cancel",
      onAction: () => {
        if (!this.#current(flowId)) return
        this.#failToIdle(flowId, "Google authorization was cancelled. Nothing was shared.", { retry: "Try again" })
      }
    })

    try {
      this.tokenClient = window.google.accounts.oauth2.initTokenClient({
        client_id: config.clientId,
        scope: DRIVE_FILE_SCOPE,
        include_granted_scopes: false,
        callback: (response) => this.#onTokenResponse(response, flowId),
        error_callback: (error) => this.#onTokenError(error, flowId)
      })
      this.tokenClient.requestAccessToken({ prompt: "" })
    } catch {
      this.#failToIdle(flowId, "Google authorization failed to start.", { retry: "Try again" })
    }
  }

  #onTokenResponse(response, flowId) {
    if (!this.#current(flowId)) return

    if (!response || response.error || !response.access_token) {
      const code = String(response?.error || "")
      if (code === "popup_closed" || code === "access_denied") {
        this.#failToIdle(flowId, "Google authorization was cancelled. Nothing was shared.", { retry: "Try again" })
      } else if (code === "popup_blocked_by_browser") {
        this.#failToIdle(flowId, "Your browser blocked the Google window. Allow popups and try again.", { retry: "Try again" })
      } else {
        this.#failToIdle(flowId, "Google authorization failed. Nothing was shared.", { retry: "Try again" })
      }
      return
    }

    const hasGranted = window.google.accounts.oauth2.hasGrantedAllScopes
    if (typeof hasGranted === "function" && !hasGranted(response, DRIVE_FILE_SCOPE)) {
      this.#failToIdle(flowId, "Drive access was not granted. Nothing was shared.", { retry: "Try again" })
      return
    }

    // Ephemeral JS memory only: never rendered, stored, or sent anywhere
    // except Google's own endpoints in an Authorization header.
    this.accessToken = response.access_token

    const continuation = this.afterAuth
    this.afterAuth = null
    if (typeof continuation === "function") {
      continuation()
      return
    }
    this.#openPicker(flowId)
  }

  #onTokenError(_error, flowId) {
    if (!this.#current(flowId) || this.phase !== "authorizing") return
    this.#failToIdle(flowId, "Google authorization failed. Nothing was shared.", { retry: "Try again" })
  }

  #openPicker(flowId) {
    if (!this.#current(flowId)) return
    const config = this.#config()
    if (!config) {
      this.#failToIdle(flowId, "Drive sharing is not set up.", { retry: null })
      return
    }

    this.phase = "picking"
    this.#showPanel("Choose a file in the Google Drive window…", {
      action: "Cancel",
      onAction: () => {
        if (!this.#current(flowId)) return
        try { this.picker?.setVisible(false) } catch { /* picker already gone */ }
        this.picker = null
        this.#failToIdle(flowId, "No file chosen. Nothing was shared.", { retry: "Choose again" })
      }
    })

    try {
      let docsView
      if (typeof window.google.picker.DocsView === "function") {
        docsView = new window.google.picker.DocsView(window.google.picker.ViewId.DOCS)
        if (typeof docsView.setIncludeFolders === "function") docsView.setIncludeFolders(true)
        if (typeof docsView.setSelectFolderEnabled === "function") docsView.setSelectFolderEnabled(false)
        if (window.google.picker.DocsViewMode && typeof docsView.setMode === "function") {
          // LIST is recommended for narrower scopes, which cannot fetch thumbnails.
          docsView.setMode(window.google.picker.DocsViewMode.LIST)
        }
      } else {
        docsView = new window.google.picker.View(window.google.picker.ViewId.DOCS)
      }

      const builder = new window.google.picker.PickerBuilder()
        .addView(docsView)
        .setOAuthToken(this.accessToken)
        .setDeveloperKey(config.apiKey)
        .setAppId(config.projectNumber)
        .setCallback((data) => this.#onPickerAction(data, flowId))
      if (typeof builder.setOrigin === "function") builder.setOrigin(window.location.origin)
      if (typeof builder.setTitle === "function") builder.setTitle("Choose a Drive file")

      // Multiselect stays disabled: one file per selection.
      this.picker = builder.build()
      this.picker.setVisible(true)
    } catch {
      this.picker = null
      this.#failToIdle(flowId, "The Drive window could not be opened.", { retry: "Try again" })
    }
  }

  #onPickerAction(data, flowId) {
    if (!this.#current(flowId)) return

    const Response = window.google.picker.Response
    const Action = window.google.picker.Action
    const docs = data?.[Response.DOCUMENTS] || data?.docs || []

    if (data?.[Response.ACTION] === Action.PICKED && docs.length > 0) {
      const Document = window.google.picker.Document
      const picked = docs[0]
      const id = picked?.[Document.ID] ?? picked?.id

      try { this.picker?.setVisible(false) } catch { /* picker already gone */ }
      this.picker = null

      if (!validDriveFileId(id)) {
        this.#failToIdle(flowId, "That selection could not be attached.", { retry: "Choose again" })
        return
      }

      this.#beginReview(flowId, {
        id,
        name: picked?.[Document.NAME] ?? picked?.name ?? "",
        mimeType: picked?.[Document.MIME_TYPE] ?? picked?.mimeType ?? ""
      })
      return
    }

    if (data?.[Response.ACTION] === Action.CANCEL) {
      this.picker = null
      this.#failToIdle(flowId, "No file chosen. Nothing was shared.", { retry: "Choose again" })
    }
  }

  // Review dialog setup: reads the file's sharing capability from Drive
  // and the current chat recipients from the server, in parallel. Either
  // may fail while attach-only stays available; nothing here mutates
  // permissions.
  async #beginReview(flowId, picked) {
    if (!this.#current(flowId)) return
    this.phase = "review"
    this.#hidePanel()

    const dialog = this.#buildDialog(picked)
    this.dialog = dialog
    document.body.append(dialog)
    dialog.showModal()
    this.#focusDialog()

    const client = new DriveShareClient({ token: this.accessToken })
    this.abortController = new AbortController()
    const signal = this.abortController.signal

    const [ fileResult, recipientsResult ] = await Promise.all([
      client.getFile(picked.id, { signal }).then(
        (file) => ({ ok: true, file }),
        (error) => ({ ok: false, error })
      ),
      this.#fetchRecipients(signal).then(
        (recipients) => ({ ok: true, recipients }),
        (error) => ({ ok: false, error })
      )
    ])

    if (!this.#current(flowId) || this.dialog !== dialog) return

    const file = fileResult.ok ? fileResult.file : null
    const name = file?.name || picked.name || "Untitled"
    const mimeType = file?.mimeType || picked.mimeType || ""
    const shareable = fileResult.ok && file?.capabilities?.canShare === true
    const kind = driveKindFromMimeType(mimeType)
    const isFolder = mimeType === FOLDER_MIME_TYPE
    const isShortcut = mimeType === SHORTCUT_MIME_TYPE

    this.#renderReview(dialog, {
      id: picked.id,
      name,
      mimeType,
      kind,
      url: canonicalDriveFileUrl(picked.id),
      shareable: shareable && !isFolder && !isShortcut,
      shareBlockedReason: isFolder || isShortcut ? "type" : (fileResult.ok ? (shareable ? null : "capability") : "file"),
      recipients: recipientsResult.ok ? recipientsResult.recipients : null,
      recipientsError: recipientsResult.ok ? null : recipientsResult.error
    })
    this.#focusDialog()
  }

  async #fetchRecipients(signal) {
    const response = await fetch(`/rooms/${this.flowRoomId}/drive_recipients`, {
      headers: { "Accept": "application/json" },
      signal
    })
    if (response.status === 429) throw new Error("rate_limited")
    if (!response.ok) throw new Error(`recipients ${response.status}`)
    const data = await response.json()
    if (!Array.isArray(data.recipients)) throw new Error("recipients invalid")
    return data.recipients.filter((recipient) => recipient?.id && recipient?.name && recipient?.email)
  }

  async #validateRecipients(ids, signal) {
    const token = document.querySelector("meta[name='csrf-token']")?.content || ""
    const response = await fetch(`/rooms/${this.flowRoomId}/drive_recipients/validate`, {
      method: "POST",
      headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": token },
      body: JSON.stringify({ user_ids: ids }),
      signal
    })
    if (response.status === 422) {
      const data = await response.json().catch(() => ({}))
      const error = new Error("invalid")
      error.invalidIds = data.invalid_ids || []
      throw error
    }
    if (!response.ok) throw new Error(`validate ${response.status}`)
    const data = await response.json()
    if (!Array.isArray(data.recipients)) throw new Error("validate invalid")
    return data.recipients
  }

  #buildDialog(picked) {
    const dialog = document.createElement("dialog")
    dialog.className = "drive-share-dialog"
    dialog.setAttribute("aria-labelledby", "drive-share-title")

    const title = document.createElement("h2")
    title.id = "drive-share-title"
    title.className = "drive-share-dialog__title"
    title.textContent = "Share a Drive file"

    const fileLine = document.createElement("p")
    fileLine.className = "drive-share-dialog__file"
    fileLine.textContent = picked.name || "Untitled"

    const status = document.createElement("p")
    status.className = "drive-share-dialog__status"
    status.setAttribute("role", "status")
    status.textContent = "Loading file and chat members…"

    const body = document.createElement("div")
    body.className = "drive-share-dialog__body"

    const footer = document.createElement("div")
    footer.className = "drive-share-dialog__footer"

    dialog.append(title, fileLine, status, body, footer)
    dialog.addEventListener("cancel", (event) => {
      event.preventDefault()
      if (this.phase !== "granting") this.#closeDialog()
    })
    return dialog
  }

  #renderReview(dialog, review) {
    dialog._driveShareReview = review
    dialog.querySelector(".drive-share-dialog__file").textContent = review.name
    const body = dialog.querySelector(".drive-share-dialog__body")
    const footer = dialog.querySelector(".drive-share-dialog__footer")
    body.replaceChildren()
    footer.replaceChildren()
    this.#setDialogStatus(dialog, "")

    const explainer = document.createElement("p")
    explainer.className = "drive-share-dialog__explainer"
    explainer.textContent = "Access grants happen immediately and stay in place even if you do not send the message, or if a recipient later leaves this chat. Future members are not added automatically. Only view access is granted, and no email notifications are sent."
    body.append(explainer)

    if (review.shareBlockedReason === "type") {
      body.append(this.#notice("Folders and shortcuts cannot be shared from here. You can still attach the link; members open it with whatever access they already have."))
    } else if (review.shareBlockedReason === "capability") {
      body.append(this.#notice("You do not have permission to share this file in Drive. You can still attach the link. To share it, change the sharing settings in Google Drive or ask the file owner; your organization's Drive policies may block sharing with people outside your organization."))
    } else if (review.shareBlockedReason === "file") {
      body.append(this.#notice("Drive did not return this file's sharing status. You can still attach the link, or try again."))
    }

    const attachOnly = this.#button("Attach only", "btn", () => this.#attachOnly(review))
    const grant = this.#button("Grant view access and attach", "btn btn--reversed", () => this.#grant(review))
    const cancel = this.#button("Cancel", "btn btn--borderless", () => this.#closeDialog())
    // Default: no recipients selected, so the grant starts disabled and
    // only enables once at least one box is checked.
    grant.disabled = true
    const grantable = review.shareable && review.recipients && review.recipients.length > 0
    const syncGrant = () => {
      grant.disabled = !grantable ||
        dialog.querySelectorAll(".drive-share-dialog__recipient input:checked").length === 0
    }

    if (!review.recipients) {
      body.append(this.#notice("Chat members could not be loaded, so recipients cannot be granted access right now. You can still attach the link."))
    } else if (review.recipients.length === 0) {
      body.append(this.#notice("There is no one else in this chat to grant access to. You can still attach the link."))
    } else {
      body.append(this.#recipientList(review.recipients, syncGrant))
    }

    footer.append(attachOnly, grant, cancel)
  }

  #recipientList(recipients, onSelectionChange = null) {
    const group = document.createElement("div")
    group.className = "drive-share-dialog__recipients"
    group.setAttribute("role", "group")
    group.setAttribute("aria-label", "Chat recipients")

    const selectAllLabel = document.createElement("label")
    selectAllLabel.className = "drive-share-dialog__select-all"
    const selectAll = document.createElement("input")
    selectAll.type = "checkbox"
    const selectAllText = document.createElement("span")
    selectAllText.textContent = `Select all (${recipients.length})`
    selectAllLabel.append(selectAll, selectAllText)
    group.append(selectAllLabel)

    const list = document.createElement("div")
    list.className = "drive-share-dialog__list"
    for (const recipient of recipients) {
      const label = document.createElement("label")
      label.className = "drive-share-dialog__recipient"
      label.dataset.recipientId = recipient.id
      // Approval covers the displayed identity, not just the id: the
      // grant re-checks this email against the canonical record.
      label.dataset.recipientEmail = recipient.email

      const checkbox = document.createElement("input")
      checkbox.type = "checkbox"
      checkbox.value = recipient.id

      const text = document.createElement("span")
      text.className = "drive-share-dialog__recipient-text"
      const name = document.createElement("span")
      name.className = "drive-share-dialog__recipient-name"
      name.textContent = recipient.name
      const email = document.createElement("span")
      email.className = "drive-share-dialog__recipient-email"
      email.textContent = recipient.email
      text.append(name, email)

      label.append(checkbox, text)
      list.append(label)
    }
    group.append(list)

    const boxes = () => Array.from(list.querySelectorAll("input[type='checkbox']"))
    selectAll.addEventListener("change", () => {
      for (const box of boxes()) box.checked = selectAll.checked
      onSelectionChange?.()
    })
    list.addEventListener("change", () => {
      const checked = boxes().filter((box) => box.checked).length
      selectAll.checked = checked > 0 && checked === boxes().length
      selectAll.indeterminate = checked > 0 && checked < boxes().length
      onSelectionChange?.()
    })
    return group
  }

  // Pins the file without touching Drive permissions: no validate call,
  // no permissions call. Re-attaching an already-pinned file is a silent
  // no-op like the legacy picker.
  #attachOnly(review) {
    if (!this.#currentRoom()) return
    const result = pinDriveAttachment(this.attachmentsStrip, review)

    if (result === "pinned" || result === "duplicate") {
      this.#closeDialog()
      this.form?.querySelector("textarea")?.focus()
    } else if (result === "full") {
      this.#setDialogStatus(this.dialog, `Up to ${MAX_DRIVE_ATTACHMENTS_PER_MESSAGE} Drive files per message`)
    }
  }

  // Explicit grant: re-validates the checked identities against current
  // room membership, preflights attachment capacity, then grants reader
  // access one at a time. Approval covers {id,email}: a changed email
  // forces a fresh explicit review instead of silently retargeting.
  async #grant(review) {
    const flowId = this.flowId
    const approved = Array.from(this.dialog.querySelectorAll(".drive-share-dialog__recipient input:checked"))
      .map((box) => ({
        id: Number(box.value),
        email: box.closest("label")?.dataset.recipientEmail || ""
      }))
      .filter((entry) => Number.isInteger(entry.id))
    if (approved.length === 0 || !this.#current(flowId) || !this.#currentRoom()) return

    this.phase = "granting"
    const dialog = this.dialog
    this.#setGrantBusy(dialog, true)
    this.#setDialogStatus(dialog, "Confirming recipients…")

    this.abortController = new AbortController()
    const signal = this.abortController.signal

    const recipients = await this.#confirmIdentities(flowId, dialog, review, approved, signal)
    if (!recipients) return
    if (!this.#grantCapacityAvailable(dialog, review)) return

    const client = new DriveShareClient({ token: this.accessToken })
    const results = recipients.map((recipient) => ({ recipient, status: "pending" }))
    await this.#grantToRecipients(flowId, dialog, review, client, results, signal)
  }

  // Confirms the approved identities against the canonical records: every
  // id must still be a member, and every email must still match what was
  // displayed. Returns the canonical recipients, or null after returning
  // the dialog to review (refreshed list, changed identities unchecked).
  async #confirmIdentities(flowId, dialog, review, approved, signal) {
    let canonical
    try {
      canonical = await this.#validateRecipients(approved.map((entry) => entry.id), signal)
    } catch (error) {
      if (!this.#current(flowId) || this.dialog !== dialog) return null
      if (error.message === "invalid") {
        this.#setDialogStatus(dialog, "Some recipients are no longer in this chat. The list was refreshed; review it and try again.")
        await this.#refreshRecipientList(dialog, review, error.invalidIds || [])
      } else {
        this.#setDialogStatus(dialog, "Recipients could not be confirmed. Try again, or attach without granting access.")
      }
      this.phase = "review"
      this.#setGrantBusy(dialog, false)
      return null
    }

    if (!this.#current(flowId) || this.dialog !== dialog) return null

    const byId = new Map(canonical.map((recipient) => [ recipient.id, recipient ]))
    const missing = approved.map((entry) => entry.id).filter((id) => !byId.has(id))
    const changed = approved
      .filter((entry) => byId.has(entry.id))
      .filter((entry) => byId.get(entry.id).email.toLowerCase() !== entry.email.toLowerCase())
      .map((entry) => entry.id)

    if (missing.length > 0 || changed.length > 0) {
      this.#setDialogStatus(dialog,
        changed.length > 0
          ? "Recipient details changed since this review. The list was refreshed with the changes unchecked; review it and confirm again."
          : "Some recipients are no longer in this chat. The list was refreshed; review it and try again.")
      await this.#refreshRecipientList(dialog, review, [ ...missing, ...changed ])
      this.phase = "review"
      this.#setGrantBusy(dialog, false)
      return null
    }

    return approved.map((entry) => byId.get(entry.id))
  }

  // No permission is mutated unless the file can actually be attached
  // afterwards (already pinned counts as attachable). Returns false after
  // returning the dialog to review.
  #grantCapacityAvailable(dialog, review) {
    const strip = this.attachmentsStrip
    const pinned = strip?.querySelector(`input[name="message[drive_file_ids][]"][value="${CSS.escape(review.id)}"]`)
    if (!strip || (!pinned && pinnedDriveFileIds(strip).length >= MAX_DRIVE_ATTACHMENTS_PER_MESSAGE)) {
      this.#setDialogStatus(dialog, `Up to ${MAX_DRIVE_ATTACHMENTS_PER_MESSAGE} Drive files per message — remove one to grant and attach.`)
      this.phase = "review"
      this.#setGrantBusy(dialog, false)
      return false
    }
    return true
  }

  async #grantToRecipients(flowId, dialog, review, client, results, signal) {
    this.#setDialogStatus(dialog, "Checking current Drive access…")

    let permissions
    try {
      permissions = await client.listPermissions(review.id, { signal })
    } catch (error) {
      if (!this.#current(flowId) || this.dialog !== dialog) return
      if (error instanceof DriveShareError && error.kind === "unauthorized") {
        this.#needsReconnect(flowId, dialog, () => this.#retryOutstanding(flowId, dialog, review, results), results)
        return
      }
      this.#setDialogStatus(dialog, "Drive access could not be checked. Try again, or attach without granting access.")
      this.phase = "review"
      this.#setGrantBusy(dialog, false)
      return
    }

    for (const result of results) {
      if (result.status !== "pending") continue
      if (DriveShareClient.alreadyHasAccess(permissions, result.recipient.email)) {
        result.status = "already"
      }
    }
    const missing = results.filter((entry) => entry.status === "pending").length
    const already = results.filter((entry) => entry.status === "already").length

    if (already > 0) {
      this.#setDialogStatus(dialog,
        missing === 0
          ? `Everyone selected already has access. Attaching the file.`
          : `${already} of ${results.length} already ${already === 1 ? "has" : "have"} access. Granting the rest…`)
    } else {
      this.#setDialogStatus(dialog, `Granting view access to ${missing}…`)
    }

    for (const result of results.filter((entry) => entry.status === "pending")) {
      if (!this.#current(flowId) || this.dialog !== dialog) return
      try {
        await client.createReaderPermission(review.id, result.recipient.email, { signal })
        result.status = "granted"
      } catch (error) {
        if (error instanceof DriveShareError && error.kind === "unauthorized") {
          this.#needsReconnect(flowId, dialog, () => this.#retryOutstanding(flowId, dialog, review, results), results)
          return
        }
        result.status = "failed"
        result.failureKind = error instanceof DriveShareError ? error.kind : "network"
      }
    }

    if (!this.#current(flowId) || this.dialog !== dialog) return
    this.#finishGrant(flowId, dialog, review, results)
  }

  // Retry grants only the outstanding recipients, revalidating their
  // current identities first: anyone who left, was deactivated, or
  // changed email while the grant was pending is never auto-granted.
  // The permission list is re-read before writing so an ambiguous
  // earlier result converges without duplicate grants or downgrades.
  async #retryOutstanding(flowId, dialog, review, results) {
    if (!this.#current(flowId) || this.dialog !== dialog) return
    this.phase = "granting"
    this.#setGrantBusy(dialog, true)
    this.#setDialogStatus(dialog, "Confirming recipients…")

    this.abortController = new AbortController()
    const signal = this.abortController.signal

    const outstanding = results.filter((entry) => entry.status === "failed" || entry.status === "pending")
    const approved = outstanding.map((entry) => ({ id: entry.recipient.id, email: entry.recipient.email }))
    const canonical = await this.#confirmResumedIdentities(flowId, dialog, review, approved, signal, results)
    if (!canonical) return

    for (const entry of outstanding) {
      entry.recipient = canonical.get(entry.recipient.id)
    }

    // Capacity is re-checked after identity confirmation: the strip may
    // have filled since the first batch, and a resumed batch must not
    // mutate permissions for a file that cannot be attached.
    if (!this.#grantCapacityAvailable(dialog, review)) return

    const client = new DriveShareClient({ token: this.accessToken })
    this.#setDialogStatus(dialog, "Checking current Drive access…")

    try {
      const permissions = await client.listPermissions(review.id, { signal })
      for (const result of results) {
        if (result.status !== "failed" && result.status !== "pending") continue
        if (DriveShareClient.alreadyHasAccess(permissions, result.recipient.email)) {
          // Access found on re-read was not newly granted by this
          // batch: it may predate the flow or come from an ambiguous
          // earlier call, so it is confirmed, never claimed.
          result.status = "confirmed"
        }
      }
    } catch (error) {
      if (!this.#current(flowId) || this.dialog !== dialog) return
      if (error instanceof DriveShareError && error.kind === "unauthorized") {
        this.#needsReconnect(flowId, dialog, () => this.#retryOutstanding(flowId, dialog, review, results), results)
        return
      }
      this.#setDialogStatus(dialog, "Drive access could not be checked. Try again, or attach without granting access.")
      this.phase = "review"
      this.#setGrantBusy(dialog, false)
      return
    }

    for (const result of results.filter((entry) => entry.status === "failed" || entry.status === "pending")) {
      if (!this.#current(flowId) || this.dialog !== dialog) return
      try {
        await client.createReaderPermission(review.id, result.recipient.email, { signal })
        result.status = "granted"
      } catch (error) {
        if (error instanceof DriveShareError && error.kind === "unauthorized") {
          this.#needsReconnect(flowId, dialog, () => this.#retryOutstanding(flowId, dialog, review, results), results)
          return
        }
        result.status = "failed"
        result.failureKind = error instanceof DriveShareError ? error.kind : "network"
      }
    }

    if (!this.#current(flowId) || this.dialog !== dialog) return
    this.#finishGrant(flowId, dialog, review, results)
  }

  // Identity re-check for a resumed batch (retry or post-reconnect): the
  // stored per-recipient identities are compared against fresh canonical
  // records. Returns a Map of id to canonical recipient, or null after
  // returning the dialog to a fresh explicit review (nothing further
  // granted, completed outcomes kept visible).
  async #confirmResumedIdentities(flowId, dialog, review, approved, signal, results) {
    let canonical
    try {
      canonical = await this.#validateRecipients(approved.map((entry) => entry.id), signal)
    } catch (error) {
      if (!this.#current(flowId) || this.dialog !== dialog) return null
      if (error.message === "invalid") {
        await this.#returnToReview(dialog, review,
          "Some recipients are no longer in this chat. Review the updated list and confirm again; nothing further was granted.",
          results)
      } else {
        this.#setDialogStatus(dialog, "Recipients could not be confirmed. Try again, or attach without granting access.")
        this.phase = "review"
        this.#setGrantBusy(dialog, false)
      }
      return null
    }

    if (!this.#current(flowId) || this.dialog !== dialog) return null

    const byId = new Map(canonical.map((recipient) => [ recipient.id, recipient ]))
    const stale = approved.filter((entry) =>
      !byId.has(entry.id) || byId.get(entry.id).email.toLowerCase() !== entry.email.toLowerCase())

    if (stale.length > 0) {
      await this.#returnToReview(dialog, review,
        "Recipient details changed while the grant was pending. Review the updated list and confirm again; nothing further was granted.",
        results)
      return null
    }

    return byId
  }

  // Returns a results-view dialog to a fresh explicit review: the
  // recipient list is rebuilt from current membership with nothing
  // checked, so any further grant needs a new deliberate approval.
  // Completed outcomes stay visible above the list so cancelling here
  // cannot be mistaken for granting nothing.
  async #returnToReview(dialog, review, message, results = []) {
    try {
      const recipients = await this.#fetchRecipients(this.abortController?.signal)
      if (this.dialog !== dialog) return
      this.#renderReview(dialog, { ...review, recipients })
    } catch {
      if (this.dialog !== dialog) return
      this.#renderReview(dialog, { ...review, recipients: null })
    }
    this.#renderCompletedOutcomes(dialog, results)
    this.#setDialogStatus(dialog, message)
    this.phase = "review"
    this.#focusDialog()
  }

  // Renders already-completed outcomes (newly granted or pre-existing
  // access) at the top of the dialog body so reconnect and refreshed
  // review states never hide access that persists in Drive, even if the
  // user then cancels instead of continuing.
  #renderCompletedOutcomes(dialog, results) {
    dialog.querySelector(".drive-share-dialog__completed")?.remove()
    const completed = results.filter((entry) =>
      entry.status === "granted" || entry.status === "already" || entry.status === "confirmed")
    if (completed.length === 0) return

    const section = document.createElement("div")
    section.className = "drive-share-dialog__completed"
    const heading = document.createElement("p")
    heading.className = "drive-share-dialog__summary"
    heading.textContent = "Already completed — these persist in Drive even if you cancel:"
    const list = document.createElement("ul")
    list.className = "drive-share-dialog__results"
    for (const entry of completed) list.append(this.#resultRow(entry))
    section.append(heading, list)
    dialog.querySelector(".drive-share-dialog__body")?.prepend(section)
  }

  // Expired or revoked Google token: the pending grant waits for a fresh
  // explicit auth gesture, then continues automatically. Completed
  // outcomes stay visible so cancelling here cannot be mistaken for
  // granting nothing.
  #needsReconnect(flowId, dialog, continuation, results = []) {
    this.accessToken = null
    this.phase = "review"
    this.#setGrantBusy(dialog, false)
    this.#renderCompletedOutcomes(dialog, results)
    this.#setDialogStatus(dialog, "Your Google session expired. Reconnect to continue; nothing further was granted.")

    const footer = dialog.querySelector(".drive-share-dialog__footer")
    footer.replaceChildren()
    const reconnect = this.#button("Reconnect Google Drive", "btn btn--reversed", () => {
      if (!this.#current(flowId) || this.dialog !== dialog) return
      this.afterAuth = () => {
        if (!this.#current(flowId) || this.dialog !== dialog) return
        this.#hidePanel()
        this.phase = "granting"
        this.#setGrantBusy(dialog, true)
        continuation()
      }
      this.#requestToken(flowId)
    })
    const attachOnly = this.#button("Attach only", "btn", () => this.#attachOnly(this.#reviewFor(dialog)))
    const cancel = this.#button("Cancel", "btn btn--borderless", () => this.#closeDialog())
    footer.append(reconnect, attachOnly, cancel)
  }

  #finishGrant(flowId, dialog, review, results) {
    const failed = results.filter((entry) => entry.status === "failed")

    // Capacity was preflighted before any mutation, but the strip may
    // have filled mid-flight. Outcomes are always preserved and shown;
    // a missed attach stays recoverable through Attach file.
    const pinResult = pinDriveAttachment(this.attachmentsStrip, review)
    const attached = pinResult === "pinned" || pinResult === "duplicate"

    const body = dialog.querySelector(".drive-share-dialog__body")
    body.replaceChildren()
    this.#setDialogStatus(dialog, "")

    const summary = document.createElement("p")
    summary.className = "drive-share-dialog__summary"
    summary.dataset.head = this.#grantSummaryHead(results)
    summary.textContent = `${summary.dataset.head} ${this.#grantSummaryTail(attached)}`
    body.append(summary)

    if (!attached) {
      body.append(this.#notice(
        `The file could not be attached because the message already has ${MAX_DRIVE_ATTACHMENTS_PER_MESSAGE} Drive files. ` +
        "Grant results are shown below and are unaffected; free a slot and choose Attach file."))
    }

    const list = document.createElement("ul")
    list.className = "drive-share-dialog__results"
    for (const entry of results) list.append(this.#resultRow(entry))
    body.append(list)

    if (failed.length > 0) {
      const hint = document.createElement("p")
      hint.className = "drive-share-dialog__explainer"
      hint.textContent = this.#grantFailureHint(failed)
      body.append(hint)
    }

    const footer = dialog.querySelector(".drive-share-dialog__footer")
    footer.replaceChildren()
    const done = this.#button("Done", failed.length > 0 || !attached ? "btn" : "btn btn--reversed", () => {
      this.#closeDialog()
      this.form?.querySelector("textarea")?.focus()
    })
    if (failed.length > 0) {
      const retry = this.#button(`Retry ${failed.length} remaining`, "btn btn--reversed", () =>
        this.#retryOutstanding(flowId, dialog, review, results))
      footer.append(retry)
    }
    if (!attached) {
      const attachFile = this.#button("Attach file", failed.length > 0 ? "btn" : "btn btn--reversed", () => {
        const retry = pinDriveAttachment(this.attachmentsStrip, review)
        if (retry === "pinned" || retry === "duplicate") {
          dialog.querySelector(".drive-share-dialog__notice")?.remove()
          summary.textContent = `${summary.dataset.head} ${this.#grantSummaryTail(true)}`
          this.#setDialogStatus(dialog, "")
          attachFile.remove()
        } else {
          this.#setDialogStatus(dialog, `Up to ${MAX_DRIVE_ATTACHMENTS_PER_MESSAGE} Drive files per message — remove one and try again.`)
        }
      })
      footer.append(attachFile)
    }
    footer.append(done)
    this.phase = "review"
    this.#focusDialog()
  }

  #resultRow(entry) {
    const item = document.createElement("li")
    item.className = `drive-share-dialog__result drive-share-dialog__result--${entry.status}`
    const marker = document.createElement("span")
    marker.className = "drive-share-dialog__result-marker"
    marker.setAttribute("aria-hidden", "true")
    marker.textContent = entry.status === "failed" ? "!" : "✓"
    const text = document.createElement("span")
    const name = document.createElement("span")
    name.className = "drive-share-dialog__recipient-name"
    name.textContent = entry.recipient.name
    const detail = document.createElement("span")
    detail.className = "drive-share-dialog__recipient-email"
    detail.textContent = `${entry.recipient.email} · ${this.#grantResultLabel(entry)}`
    text.append(name, detail)
    item.append(marker, text)
    return item
  }

  // Summary counts only actual new grants as granted; pre-existing and
  // reconciled access is reported separately so it never reads as
  // "Access granted", and "Google denied" is used only when every
  // failure really was a denial.
  #grantSummaryHead(results) {
    const total = results.length
    const fresh = results.filter((entry) => entry.status === "granted").length
    const already = results.filter((entry) => entry.status === "already").length
    const confirmed = results.filter((entry) => entry.status === "confirmed").length
    const failed = results.filter((entry) => entry.status === "failed")
    const withAccess = fresh + already + confirmed

    const notes = []
    if (fresh > 0) notes.push(`${fresh} newly granted`)
    if (already > 0) notes.push(`${already} already had access`)
    if (confirmed > 0) notes.push(`${confirmed} confirmed in Drive`)
    const note = notes.length > 0 ? ` (${notes.join("; ")})` : ""

    if (failed.length === 0) {
      if (fresh === 0) {
        if (confirmed === 0) return "Everyone selected already has access."
        if (already === 0) return "Access confirmed for everyone selected."
      }
      if (withAccess === fresh) {
        return total === 1 ? "View access granted." : `View access granted to ${fresh} recipients.`
      }
      return `All ${total} recipients have access: ${notes.join("; ")}.`
    }
    if (withAccess === 0) {
      const allDenied = failed.every((entry) => entry.failureKind === "denied")
      return allDenied ? "Google denied every grant." : "No access was granted."
    }
    if (fresh === 0) return `No new access was granted${note}.`
    if (withAccess === fresh) return `View access granted to ${fresh} of ${total}.`
    return `${withAccess} of ${total} recipients have access: ${notes.join("; ")}.`
  }

  #grantSummaryTail(attached) {
    return attached
      ? "The file is attached below."
      : "The file is not attached yet (attachment limit reached)."
  }

  #grantResultLabel(entry) {
    if (entry.status === "already") return "already had access"
    if (entry.status === "confirmed") return "access confirmed"
    if (entry.status === "granted") return "granted view access"
    switch (entry.failureKind) {
      case "denied": return "not granted (refused by Google)"
      case "rate_limited": return "not granted (rate limited — retry shortly)"
      case "not_found": return "not granted (file unavailable in Drive)"
      case "unavailable": return "not granted (Google service error — retry shortly)"
      default: return "not granted (connection failed)"
    }
  }

  #grantFailureHint(failed) {
    const kinds = new Set(failed.map((entry) => entry.failureKind))
    if (kinds.has("denied")) {
      return "Google denied these grants, often because of an organization sharing policy. You can retry, or change the sharing settings in Google Drive directly."
    }
    if (kinds.has("rate_limited")) {
      return "Google rate-limited these grants. Wait a moment, then retry the remaining."
    }
    if (kinds.has("unavailable")) {
      return "Google Drive returned a service error. Wait a moment, then retry the remaining."
    }
    if (kinds.has("not_found")) {
      return "Drive reported the file as unavailable. If it was moved or deleted, you can still attach the link."
    }
    return "The connection to Google failed. Check your connection and retry the remaining."
  }

  async #refreshRecipientList(dialog, review, invalidIds) {
    const stale = new Set(invalidIds)
    try {
      const recipients = await this.#fetchRecipients(this.abortController?.signal)
      if (this.dialog !== dialog) return
      const footer = dialog.querySelector(".drive-share-dialog__footer")
      footer.replaceChildren()
      const attachOnly = this.#button("Attach only", "btn", () => this.#attachOnly(review))
      const grant = this.#button("Grant view access and attach", "btn btn--reversed", () => this.#grant(review))
      const cancel = this.#button("Cancel", "btn btn--borderless", () => this.#closeDialog())
      grant.disabled = true
      const grantable = review.shareable && recipients.length > 0
      const syncGrant = () => {
        grant.disabled = !grantable ||
          dialog.querySelectorAll(".drive-share-dialog__recipient input:checked").length === 0
      }

      const checked = new Set(
        Array.from(dialog.querySelectorAll(".drive-share-dialog__recipient input:checked")).map((box) => Number(box.value))
      )
      const fresh = this.#recipientList(recipients, syncGrant)
      for (const box of fresh.querySelectorAll("input[type='checkbox'][value]")) {
        if (checked.has(Number(box.value)) && !stale.has(Number(box.value))) box.checked = true
      }
      dialog.querySelector(".drive-share-dialog__recipients")?.replaceWith(fresh)
      syncGrant()
      footer.append(attachOnly, grant, cancel)
    } catch {
      // The stale list stays with its error status; attach-only still works.
    }
  }

  #reviewFor(dialog) {
    return dialog?._driveShareReview || { id: null, name: "Untitled", kind: "file" }
  }

  #notice(text) {
    const paragraph = document.createElement("p")
    paragraph.className = "drive-share-dialog__notice"
    paragraph.textContent = text
    return paragraph
  }

  #button(label, className, onClick) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = className
    button.textContent = label
    button.addEventListener("click", (event) => {
      event.preventDefault()
      onClick()
    })
    return button
  }

  #setGrantBusy(dialog, busy) {
    for (const button of dialog.querySelectorAll(".drive-share-dialog__footer button")) {
      button.disabled = busy
    }
    for (const box of dialog.querySelectorAll(".drive-share-dialog__recipients input")) {
      box.disabled = busy
    }
  }

  #setDialogStatus(dialog, message) {
    const status = dialog?.querySelector(".drive-share-dialog__status")
    if (!status) return
    status.textContent = message
    status.hidden = !message
  }

  #focusDialog() {
    const dialog = this.dialog
    if (!dialog) return
    const target = dialog.querySelector(".drive-share-dialog__select-all input:not([disabled])") ||
      dialog.querySelector(".drive-share-dialog__footer button:not([disabled])")
    target?.focus({ preventScroll: true })
  }

  #showPanel(message, { action = null, onAction = null } = {}) {
    this.panelTarget.replaceChildren()
    this.panelTarget.hidden = false
    this.buttonTarget.setAttribute("aria-expanded", "true")

    const status = document.createElement("p")
    status.className = "drive-share__status"
    status.setAttribute("role", "status")
    status.textContent = message
    this.panelTarget.append(status)

    this.panelHandler = null
    if (action) {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "btn btn--reversed drive-share__action"
      button.textContent = action
      button.dataset.action = "drive-share#panelAction"
      this.panelTarget.append(button)
      this.panelHandler = onAction
    }
  }

  #hidePanel() {
    if (!this.hasPanelTarget || !this.hasButtonTarget) return
    this.panelTarget.hidden = true
    this.panelTarget.replaceChildren()
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.panelHandler = null
  }

  #failToIdle(flowId, message, { retry = null } = {}) {
    if (!this.#current(flowId)) return
    // Invalidate the flow generation and any parked post-auth resume so
    // a delayed OAuth or Picker callback can never reopen UI or resume
    // grants after cancellation or failure. Retries start a new flow.
    this.flowId++
    this.afterAuth = null
    this.phase = "idle"
    if (retry) {
      this.#showPanel(message, { action: retry, onAction: () => this.open(new Event("drive-share:retry")) })
    } else {
      this.#showPanel(message, { action: null })
    }
  }

  // True while this flow is the live one: same generation, still in the
  // document. Every async continuation checks it so a stale callback can
  // never attach or grant into another room.
  #current(flowId) {
    return flowId === this.flowId && this.element.isConnected
  }

  #currentRoom() {
    if (!this.element.isConnected) return false
    if (this.flowRoomId !== null && this.flowRoomId !== this.roomIdValue) return false
    if (this.flowThreadId !== null && this.flowThreadId !== this.threadIdValue) return false
    const currentRoomId = document.querySelector("meta[name='current-room-id']")?.content
    return !currentRoomId || String(currentRoomId) === String(this.roomIdValue)
  }

  #closeDialog() {
    this.flowId++
    this.phase = "idle"
    this.abortController?.abort()
    this.abortController = null
    this.afterAuth = null
    try { this.picker?.setVisible(false) } catch { /* picker already gone */ }
    this.picker = null
    // The token stays for reuse until navigation; it is never rendered.
    if (this.dialog) {
      this.dialog.close()
      this.dialog.remove()
      this.dialog = null
    }
    this.#hidePanel()
    this.buttonTarget.focus({ preventScroll: true })
  }

  // Turbo snapshot/navigation and Stimulus disconnect: dismiss Google UI,
  // remove the dialog (it carries recipient emails), drop the token, and
  // invalidate every pending callback.
  #dispose() {
    this.flowId++
    this.phase = "idle"
    this.abortController?.abort()
    this.abortController = null
    this.afterAuth = null
    this.accessToken = null
    this.tokenClient = null
    try { this.picker?.setVisible(false) } catch { /* picker already gone */ }
    this.picker = null
    if (this.dialog) {
      this.dialog.remove()
      this.dialog = null
    }
    if (this.hasPanelTarget) this.#hidePanel()
  }

  // A successful send consumed the pinned ids; a failed one keeps them so
  // the retry still carries them. Mirrors the legacy picker.
  #clearAttachmentsOnSubmit(event) {
    if (event.detail?.success) this.attachmentsStrip?.replaceChildren()
  }
}
