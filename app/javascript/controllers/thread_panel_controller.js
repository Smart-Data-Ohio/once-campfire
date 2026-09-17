import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const DESKTOP_QUERY = "(min-width: 80rem)"
const MOBILE_QUERY = "(max-width: 63.999rem)"
const REFRESH_INTERVAL = 12 * 1000
const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "summary",
  "[tabindex]:not([tabindex='-1'])",
].join(",")

export default class extends Controller {
  static targets = [
    "panel", "backdrop", "close", "title", "channel", "browserToggle", "browser", "filter",
    "browserStatus", "browserList", "create", "createParent", "createParentId", "createName", "createMessage",
    "createStatus", "createSubmit", "conversation", "conversationTitle", "conversationMeta",
    "threadStatus", "parent", "content", "messages", "empty", "retry", "composerMount", "composerStatus", "join", "leave",
    "preferences", "involvementControl", "involvement", "rename", "convertToWork", "removeWork", "closeThread", "reopen", "lock", "unlock", "delete", "manage",
    "autoArchiveControl", "autoArchive", "work", "workStatusLabel", "workOwnerLabel", "workManage", "workStatus", "workOwner", "workComplete", "workReopen", "workHistory", "workHistoryList",
    "workLinksFrame"
  ]

  #desktopQuery
  #mobileQuery
  #request
  #refreshTimer
  #threadContextGeneration = 0
  #threadListGeneration = 0
  #subscriptionGeneration = 0
  #currentThread
  #threadMessageId
  #threadParent
  #threads = []
  #unreadThreadIds = new Set()
  #isOpen = false
  #previouslyFocusedElement
  #onViewportChange = () => this.#syncAccessibility()
  #onMessageThread = event => this.#handleMessageThread(event)
  #onUnreadThread = payload => this.#handleUnreadThread(payload)
  #onVisibilityChange = () => this.#handleVisibilityChange()
  #onThreadPanelOpen = event => this.#handleThreadPanelOpen(event)

  connect() {
    if (!this.hasPanelTarget) return

    this.#desktopQuery = window.matchMedia(DESKTOP_QUERY)
    this.#mobileQuery = window.matchMedia(MOBILE_QUERY)
    this.#desktopQuery.addEventListener("change", this.#onViewportChange)
    this.#mobileQuery.addEventListener("change", this.#onViewportChange)
    document.addEventListener("visibilitychange", this.#onVisibilityChange)
    window.addEventListener("message:thread", this.#onMessageThread)
    window.addEventListener("thread-panel:open", this.#onThreadPanelOpen)
    this.#syncAccessibility()
    const subscriptionGeneration = ++this.#subscriptionGeneration
    this.#subscribeToUnreadThreads(subscriptionGeneration)

    const params = new URLSearchParams(window.location.search)
    const currentThreadReference = params.get("thread")
    const currentMessageReference = params.get("message_id")
    if (currentThreadReference) {
      this.openThread({ detail: { url: currentThreadReference, anchorMessageId: currentMessageReference }, preventDefault() {} })
    }
  }

  disconnect() {
    this.#subscriptionGeneration += 1
    this.#threadContextGeneration += 1
    this.#threadListGeneration += 1
    this.#desktopQuery?.removeEventListener("change", this.#onViewportChange)
    this.#mobileQuery?.removeEventListener("change", this.#onViewportChange)
    document.removeEventListener("visibilitychange", this.#onVisibilityChange)
    window.removeEventListener("message:thread", this.#onMessageThread)
    window.removeEventListener("thread-panel:open", this.#onThreadPanelOpen)
    this.#stopRefreshing()
    this.#abortRequest()
    this.channel?.unsubscribe()
    this.channel = null
    this.element.classList.remove("thread-panel-open")
  }

  toggle(event) {
    event?.preventDefault()

    if (this.#isOpen) {
      this.close()
    } else {
      this.openBrowser()
    }
  }

  openBrowser(event) {
    event?.preventDefault()
    this.#openPanel({ focus: true })
    this.showBrowser()
  }

  close(event, { restoreFocus = true } = {}) {
    if (event?.key === "Escape" && event.target?.closest?.(".message__actions-menu, dialog[open], details[open]")) return
    if (!this.#isOpen) {
      this.#invalidateThreadContext()
      return
    }
    event?.preventDefault()
    this.#invalidateThreadContext()
    this.#isOpen = false
    this.element.classList.remove("thread-panel-open")
    this.#syncAccessibility()

    if (restoreFocus) this.#restoreFocus()
  }

  showBrowser(event) {
    event?.preventDefault()
    if (!this.#isOpen) this.#openPanel({ focus: false })
    this.#stopRefreshing()
    this.#setView("browser")
    this.#loadThreads()
  }

  beginCreate(event, detail = {}) {
    event?.preventDefault()
    if (!this.#isOpen) this.#openPanel({ focus: false })
    this.#threadParent = detail.parent || null
    this.createParentIdTarget.value = detail.parentMessageId || ""
    this.createNameTarget.value = detail.name || ""
    this.createStatusTarget.textContent = ""
    this.createParentTarget.replaceChildren()
    if (this.#threadParent) {
      this.createParentTarget.hidden = false
      this.createParentTarget.append(this.#messageCard(this.#threadParent, { parent: true }))
    } else {
      this.createParentTarget.hidden = true
    }
    this.#setView("create")
    window.requestAnimationFrame(() => this.createMessageTarget.focus())
  }

  filterChanged() {
    this.#loadThreads()
  }

  messagesChanged(event) {
    if (this.#currentThread) this.#syncThreadContent(this.#currentThread)
    if (event?.detail?.atLatest) {
      this.contentTarget.dataset.threadContentAtLatest = "true"
      this.#markReadIfJoined(this.#currentThread, { requireVisible: true, requireLatest: true })
    } else if (event?.detail?.atLatest === false) {
      this.contentTarget.dataset.threadContentAtLatest = "false"
    }
  }

  async createThread(event) {
    event.preventDefault()
    if (this.createSubmitTarget.disabled) return
    const contextGeneration = this.#threadContextGeneration

    const firstMessage = this.createMessageTarget.value.trim()
    if (!firstMessage) {
      this.createStatusTarget.textContent = "Add the first message to start this thread."
      this.createMessageTarget.focus()
      return
    }

    const params = new URLSearchParams()
    params.set("thread[name]", this.createNameTarget.value.trim())
    if (this.createParentIdTarget.value) params.set("thread[parent_message_id]", this.createParentIdTarget.value)
    params.set("thread[message][markdown_source]", firstMessage)
    params.set("thread[message][client_message_id]", this.#clientMessageId())

    this.createSubmitTarget.disabled = true
    this.createStatusTarget.textContent = "Creating thread…"
    try {
      const payload = await this.#requestJSON(this.#config().createUrl, {
        method: "POST",
        body: params,
      })
      if (contextGeneration !== this.#threadContextGeneration || !this.#isOpen || this.createTarget.hidden) return
      const thread = this.#normalizeThread(payload.thread || payload)
      if (!thread.id && !thread.url) throw new Error("The thread response was incomplete")

      this.#threads = [ thread, ...this.#threads.filter(existing => String(existing.id) !== String(thread.id)) ]
      this.#setView("conversation")
      await this.openThread({ detail: { thread, url: thread.url }, preventDefault() {} })
    } catch (error) {
      if (contextGeneration !== this.#threadContextGeneration || !this.#isOpen || this.createTarget.hidden) return
      this.createStatusTarget.textContent = this.#errorMessage(error, "Couldn’t create the thread")
    } finally {
      this.createSubmitTarget.disabled = false
    }
  }

  openThreadFromList(event) {
    event.preventDefault()
    const element = event.currentTarget
    const thread = this.#threads.find(item => String(item.id) === element.dataset.threadId)
    this.openThread({ detail: { thread, url: element.dataset.threadUrl }, preventDefault() {} })
  }

  async openThread(event) {
    event?.preventDefault()
    const contextGeneration = this.#invalidateThreadContext()
    const detail = event?.detail || {}
    const threadId = this.#threadIdFromReference(detail)
    const suppliedMessageId = detail.anchorMessageId
    const messageId = suppliedMessageId === undefined || suppliedMessageId === null || suppliedMessageId === ""
      ? null
      : this.#numericThreadId(suppliedMessageId)
    if (!threadId || suppliedMessageId && !messageId) {
      this.#showInvalidThreadLink()
      return
    }

    const thread = this.#normalizeThread({ ...(detail.thread || {}), id: threadId })

    if (!this.#isOpen) this.#openPanel({ focus: false, focusTarget: detail.message })
    this.#setView("conversation")
    this.#currentThread = thread
    this.#threadMessageId = messageId
    this.#threadParent = detail.parent || thread.parent_message || thread.parentMessage || null
    this.#showConversationLoading(thread)

    try {
      const payload = await this.#requestJSON(this.#threadURL(thread))
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return
      const latestThread = this.#normalizeThread(payload.thread || payload)
      latestThread.parent_message ||= payload.parent_message || payload.parentMessage
      this.#rememberThreadParent(latestThread)
      latestThread.parent_message ||= this.#threadParent
      latestThread.messages = latestThread.messages.length > 0 ? latestThread.messages : (Array.isArray(payload.messages) ? payload.messages : [])
      if ((latestThread.id || latestThread.url) && this.#isCurrentThreadContext(thread, contextGeneration)) {
        this.#currentThread = latestThread
        this.#threads = [ latestThread, ...this.#threads.filter(item => String(item.id) !== String(latestThread.id)) ]
        this.#renderThreadMetadata(latestThread)
        const loaded = await this.#loadThreadContent(latestThread, contextGeneration)
        if (!loaded || !this.#isCurrentThreadContext(latestThread, contextGeneration)) return
        this.#startRefreshing()
      }
    } catch (error) {
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return
      this.threadStatusTarget.textContent = this.#errorMessage(error, "Couldn’t load this thread")
      this.contentTarget.replaceChildren()
    }
  }

  async join(event) {
    event?.preventDefault()
    await this.#mutateThread("POST", "join", "Joining thread…")
  }

  async leave(event) {
    event?.preventDefault()
    await this.#mutateThread("DELETE", "leave", "Leaving thread…")
  }

  async retryContent(event) {
    event?.preventDefault()
    if (this.#currentThread) await this.#loadThreadContent(this.#currentThread)
  }

  async changeInvolvement(event) {
    event?.preventDefault()
    if (!this.#currentThread || !this.involvementTarget.value) return
    const contextGeneration = this.#threadContextGeneration
    const params = new URLSearchParams()
    params.set("involvement", this.involvementTarget.value)
    await this.#mutateThread("POST", "join", "Saving notification preference…", params)
    if (contextGeneration !== this.#threadContextGeneration) return
    this.preferencesTarget.open = false
  }

  async changeAutoArchive(event) {
    event?.preventDefault()
    if (!this.#currentThread || !this.autoArchiveTarget.value) return
    const contextGeneration = this.#threadContextGeneration
    const params = new URLSearchParams()
    params.set("thread[auto_archive_after_minutes]", this.autoArchiveTarget.value)
    await this.#mutateThread("PATCH", "", "Saving auto-close preference…", params)
    if (contextGeneration !== this.#threadContextGeneration) return
    this.manageTarget.open = false
  }

  async rename(event) {
    event?.preventDefault()
    if (!this.#currentThread) return
    this.#closeActionMenus()
    const currentName = this.#currentThread.name || ""
    const name = window.prompt("Thread name", currentName)
    if (name === null || !name.trim() || name.trim() === currentName) return
    const params = new URLSearchParams()
    params.set("thread[name]", name.trim())
    await this.#mutateThread("PATCH", "", "Saving thread name…", params)
  }

  async convertToWork(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    const params = new URLSearchParams()
    params.set("thread[work_status]", "planned")
    await this.#mutateThread("PATCH", "", "Starting work tracking…", params)
  }

  async removeWork(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    if (!window.confirm("Stop tracking work for this thread? Its messages and work history will remain.")) return

    const params = new URLSearchParams()
    params.set("thread[work_status]", "")
    params.set("thread[work_owner_id]", "")
    await this.#mutateThread("PATCH", "", "Removing work tracking…", params)
  }

  async changeWorkStatus(event) {
    event?.preventDefault()
    if (!this.#currentThread || !this.workStatusTarget.value) return

    const params = new URLSearchParams()
    params.set("thread[work_status]", this.workStatusTarget.value)
    await this.#mutateThread("PATCH", "", "Saving work status…", params)
    if (this.hasWorkManageTarget) this.workManageTarget.open = false
  }

  async changeWorkOwner(event) {
    event?.preventDefault()
    if (!this.#currentThread) return

    const params = new URLSearchParams()
    params.set("thread[work_owner_id]", this.workOwnerTarget.value)
    await this.#mutateThread("PATCH", "", "Saving work owner…", params)
    if (this.hasWorkManageTarget) this.workManageTarget.open = false
  }

  async completeWork(event) {
    event?.preventDefault()
    if (!this.#currentThread) return

    const params = new URLSearchParams()
    params.set("thread[work_status]", "done")
    await this.#mutateThread("PATCH", "", "Completing work…", params)
    if (this.hasWorkManageTarget) this.workManageTarget.open = false
  }

  async reopenWork(event) {
    event?.preventDefault()
    if (!this.#currentThread) return

    const params = new URLSearchParams()
    params.set("thread[work_status]", "planned")
    await this.#mutateThread("PATCH", "", "Reopening work…", params)
    if (this.hasWorkManageTarget) this.workManageTarget.open = false
  }

  async closeThread(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    await this.#updateState("closed")
  }

  async reopen(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    await this.#updateState("active")
  }

  async lock(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    await this.#updateState("locked")
  }

  async unlock(event) {
    event?.preventDefault()
    this.#closeActionMenus()
    await this.#updateState("active")
  }

  async delete(event) {
    event?.preventDefault()
    const thread = this.#currentThread
    const contextGeneration = this.#threadContextGeneration
    if (!thread || !window.confirm("Delete this thread and its messages? This can’t be undone.")) return

    this.#closeActionMenus()
    this.threadStatusTarget.textContent = "Deleting thread…"
    try {
      await this.#requestJSON(this.#threadURL(thread), { method: "DELETE" })
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return
      this.#threads = this.#threads.filter(item => String(item.id) !== String(thread.id))
      this.#currentThread = null
      this.#setView("browser")
      this.#renderThreadList()
    } catch (error) {
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return
      this.threadStatusTarget.textContent = this.#errorMessage(error, "Couldn’t delete the thread")
    }
  }

  trapFocus(event) {
    if (event.key !== "Tab" || !this.#isOpen || !this.#mobileQuery.matches) return

    const focusable = this.#focusableElements()
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  prepareForCache() {
    this.#invalidateThreadContext()
    this.#threadListGeneration += 1
    this.close(undefined, { restoreFocus: false })
    this.#threads = []
    this.#currentThread = null
  }

  // Panel lifecycle and notifications

  #openPanel({ focus = true, focusTarget = null } = {}) {
    if (this.#isOpen) return

    this.#previouslyFocusedElement = focusTarget || document.activeElement
    window.dispatchEvent(new CustomEvent("thread-panel:opening"))
    this.#isOpen = true
    this.element.classList.add("thread-panel-open")
    this.#syncAccessibility()

    if (focus) {
      window.requestAnimationFrame(() => {
        if (this.#mobileQuery.matches) this.closeTarget.focus()
      })
    }
  }

  #syncAccessibility() {
    if (!this.hasPanelTarget) return
    const open = this.#isOpen
    this.panelTarget.toggleAttribute("inert", !open)
    this.panelTarget.setAttribute("aria-hidden", String(!open))
    this.panelTarget.setAttribute("aria-busy", String(Boolean(this.#request && open)))
    this.closeTargets.forEach(target => target.setAttribute("aria-expanded", String(open)))
    this.browserToggleTargets.forEach(target => target.setAttribute("aria-expanded", String(this.hasBrowserTarget && !this.browserTarget.hidden)))
    if (this.#mobileQuery?.matches) {
      this.backdropTarget.hidden = !open
      this.panelTarget.querySelector(".thread-panel__surface")?.setAttribute("role", "dialog")
      this.panelTarget.querySelector(".thread-panel__surface")?.setAttribute("aria-modal", "true")
    } else {
      this.backdropTarget.hidden = true
      const surface = this.panelTarget.querySelector(".thread-panel__surface")
      surface?.setAttribute("role", "region")
      surface?.removeAttribute("aria-modal")
    }
  }

  #isCurrentThreadContext(thread, contextGeneration) {
    return this.#isOpen &&
      this.#threadContextGeneration === contextGeneration &&
      this.#currentThread &&
      String(this.#currentThread.id) === String(thread?.id)
  }

  #invalidateThreadContext() {
    this.#threadContextGeneration += 1
    this.#stopRefreshing()
    this.#abortRequest()
    return this.#threadContextGeneration
  }

  #setView(view) {
    if (this.hasBrowserTarget) this.browserTarget.hidden = view !== "browser"
    if (this.hasCreateTarget) this.createTarget.hidden = view !== "create"
    if (this.hasConversationTarget) this.conversationTarget.hidden = view !== "conversation"
    this.#syncAccessibility()
  }

  #showConversationLoading(thread) {
    this.#closeActionMenus()
    this.conversationTitleTarget.textContent = thread.name || "Thread"
    this.conversationMetaTarget.textContent = this.#channelLabel()
    this.threadStatusTarget.textContent = "Loading thread…"
    this.workTarget.hidden = true
    this.workManageTarget.hidden = true
    this.workHistoryTarget.hidden = true
    this.#clearWorkLinks()
    if (this.hasRetryTarget) this.retryTarget.hidden = true
    this.parentTarget.hidden = true
    this.emptyTarget.hidden = true
    this.contentTarget.replaceChildren()
    delete this.contentTarget.dataset.threadContentAtLatest
  }

  #renderThreadMetadata(thread) {
    this.conversationTitleTarget.textContent = thread.name || "Thread"
    this.channelTarget.textContent = this.#channelLabel()
    const memberCount = Number(thread.member_count || thread.memberCount || 0)
    const memberLabel = memberCount === 1 ? "1 member" : `${memberCount} members`
    this.conversationMetaTarget.textContent = `${this.#channelLabel()} · ${this.#statusLabel(thread)} · ${memberLabel}`
    this.threadStatusTarget.textContent = this.#statusMessage(thread)

    const parent = thread.parent_message || thread.parentMessage || this.#threadParent
    this.parentTarget.replaceChildren()
    if (parent) {
      this.parentTarget.hidden = false
      this.parentTarget.append(this.#messageCard(parent, { parent: true }))
    } else {
      this.parentTarget.hidden = true
    }

    this.#renderWorkMetadata(thread)
    this.#renderWorkLinks(thread)
    this.#updateThreadActions(thread)
    this.#updateThreadListItem(thread)
    this.#updateUnreadToggle()
  }

  async #loadThreadContent(thread, contextGeneration = this.#threadContextGeneration) {
    if (!this.#isCurrentThreadContext(thread, contextGeneration)) return false
    const contentURL = this.#threadContentURL(thread)
    const url = contentURL && new URL(contentURL)
    if (url && this.#threadMessageId) url.searchParams.set("message_id", this.#threadMessageId)
    if (!url) {
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return false
      this.contentTarget.replaceChildren()
      this.threadStatusTarget.textContent = "Couldn’t load thread messages. Try again."
      if (this.hasRetryTarget) this.retryTarget.hidden = false
      return false
    }

    try {
      const response = await this.#requestHTML(url.toString())
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return false
      this.contentTarget.innerHTML = response.html
      this.contentTarget.dataset.threadContentAtLatest = String(response.atLatest)
      this.#syncThreadContent(thread)
      if (response.atLatest) this.#markReadIfJoined(thread, { requireVisible: true, requireLatest: true })
      return true
    } catch (error) {
      if (!this.#isCurrentThreadContext(thread, contextGeneration)) return false
      this.contentTarget.replaceChildren()
      if (error?.name !== "AbortError") this.threadStatusTarget.textContent = "Couldn’t load thread messages. Try again."
      if (this.hasRetryTarget && error?.name !== "AbortError") this.retryTarget.hidden = false
      return false
    }
  }

  #syncThreadContent(thread) {
    const messages = this.hasMessagesTarget ? this.messagesTarget : null
    const renderedMessages = messages?.querySelectorAll?.(".message").length || 0
    const jsonMessages = Array.isArray(thread.messages) ? thread.messages.length : 0
    this.emptyTarget.hidden = renderedMessages > 0 || jsonMessages > 0
    if (this.hasRetryTarget) this.retryTarget.hidden = true
    this.#updateComposer(thread)
  }

  #updateThreadActions(thread) {
    const currentUser = this.#threadMembership(thread)
    const permissions = thread.permissions || {}
    const manageOpen = this.manageTarget.open
    const preferencesOpen = this.preferencesTarget.open
    const can = (key, fallback = false) => {
      const aliases = [ key, key.replaceAll("_", ""), key.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase()) ]
      for (const candidate of aliases) {
        if (permissions[candidate] !== undefined) return Boolean(permissions[candidate])
        if (thread[candidate] !== undefined) return Boolean(thread[candidate])
      }
      return fallback
    }
    const joined = Boolean(currentUser.joined)
    this.joinTarget.hidden = joined
    this.leaveTarget.hidden = !joined
    this.preferencesTarget.hidden = !joined
    if (!preferencesOpen) this.involvementTarget.value = currentUser.involvement || "mentions"
    this.renameTarget.hidden = !can("can_rename")
    this.convertToWorkTarget.hidden = !can("can_convert_work")
    this.removeWorkTarget.hidden = !can("can_remove_work")
    this.closeThreadTarget.hidden = thread.status !== "active" || !can("can_close")
    this.reopenTarget.hidden = thread.status !== "closed" || !can("can_reopen")
    this.lockTarget.hidden = thread.status === "locked" || !can("can_lock")
    this.unlockTarget.hidden = thread.status !== "locked" || !can("can_unlock")
    this.deleteTarget.hidden = !can("can_delete")
    this.autoArchiveControlTarget.hidden = !can("can_rename")
    if (!manageOpen) this.autoArchiveTarget.value = String(thread.auto_archive_after_minutes || 4_320)
    this.manageTarget.hidden = [
      this.renameTarget,
      this.convertToWorkTarget,
      this.removeWorkTarget,
      this.closeThreadTarget,
      this.reopenTarget,
      this.lockTarget,
      this.unlockTarget,
      this.deleteTarget,
      this.autoArchiveControlTarget,
    ].every(target => target.hidden)
    if (this.manageTarget.hidden) this.manageTarget.open = false
    if (this.preferencesTarget.hidden) this.preferencesTarget.open = false
  }

  #renderWorkMetadata(thread) {
    const isWork = Boolean(thread.work || thread.work_status)
    this.workTarget.hidden = !isWork
    if (!isWork) {
      this.workManageTarget.hidden = true
      this.workHistoryTarget.hidden = true
      this.workHistoryListTarget.replaceChildren()
      return
    }

    const permissions = thread.permissions || {}
    const canStatus = Boolean(permissions.can_update_work_status || permissions.can_manage_work)
    const canAssign = Boolean(permissions.can_assign_work)
    this.workStatusLabelTarget.textContent = this.#workStatusLabel(thread.work_status)
    this.#renderWorkOwnerLabel(thread)
    this.workStatusTarget.value = thread.work_status || "planned"
    this.workStatusTarget.disabled = !canStatus
    this.#renderWorkOwnerOptions(thread, canAssign)
    this.workManageTarget.hidden = !(canStatus || canAssign)
    this.workCompleteTarget.hidden = !canStatus || thread.work_status === "done"
    this.workReopenTarget.hidden = !canStatus || thread.work_status !== "done"
    this.#renderWorkHistory(thread)
  }

  // Work links render server-side inside a turbo frame so the Linked row
  // and the Link forms stay identical across the panel, the thread page
  // header, and the Work list. Pointing the frame at the thread loads
  // the box; link adds and removals refresh it through Turbo Streams.
  #renderWorkLinks(thread) {
    if (!this.hasWorkLinksFrameTarget) return
    const frame = this.workLinksFrameTarget
    if (!(thread.work || thread.work_status)) {
      this.#clearWorkLinks()
      return
    }

    const url = `/threads/${encodeURIComponent(thread.id)}/work/links`
    frame.hidden = false
    if (frame.getAttribute("src") !== url) frame.setAttribute("src", url)
  }

  #clearWorkLinks() {
    if (!this.hasWorkLinksFrameTarget) return
    const frame = this.workLinksFrameTarget
    frame.removeAttribute("src")
    frame.replaceChildren()
    frame.hidden = true
  }

  #renderWorkOwnerOptions(thread, canAssign) {
    const owner = thread.work_owner
    const owners = Array.isArray(thread.work_owner_options) ? thread.work_owner_options.slice() : []
    if (owner && !owners.some(option => String(option.id) === String(owner.id))) owners.push(owner)
    const people = owners.filter(option => !option.agent).sort((left, right) => String(left.name || "").localeCompare(String(right.name || "")))
    const agents = owners.filter(option => option.agent).sort((left, right) => String(left.name || "").localeCompare(String(right.name || "")))

    this.workOwnerTarget.replaceChildren()
    const unassigned = document.createElement("option")
    unassigned.value = ""
    unassigned.textContent = "Unassigned"
    this.workOwnerTarget.append(unassigned)

    people.forEach(option => this.workOwnerTarget.append(this.#workOwnerOption(option, owner, thread)))

    if (agents.length > 0) {
      const group = document.createElement("optgroup")
      group.label = "Agents"
      agents.forEach(option => group.append(this.#workOwnerOption(option, owner, thread)))
      this.workOwnerTarget.append(group)
    }
    this.workOwnerTarget.value = owner?.id ? String(owner.id) : ""
    this.workOwnerTarget.disabled = !canAssign
  }

  #workOwnerOption(option, owner, thread) {
    const element = document.createElement("option")
    element.value = String(option.id)
    const isCurrentOwnerRemoved = owner && String(option.id) === String(owner.id) && thread.work_owner_active === false
    const unavailable = option.active === false || isCurrentOwnerRemoved
    element.textContent = unavailable ? `${option.name} (unavailable)` : option.name
    element.disabled = unavailable
    const details = [ option.provider, option.description ].filter(detail => detail).join(" · ")
    if (details) element.title = details
    return element
  }

  #renderWorkHistory(thread) {
    const events = Array.isArray(thread.work_history) ? thread.work_history : []
    this.workHistoryListTarget.replaceChildren()
    this.workHistoryTarget.hidden = events.length === 0
    events.forEach(event => {
      const item = document.createElement("li")
      const actor = event.actor?.name || "Former member"
      const before = event.before || {}
      const after = event.after || {}
      const changes = []
      if (before.status !== after.status) {
        changes.push(`${this.#workStatusLabel(before.status || "ordinary")} → ${this.#workStatusLabel(after.status || "ordinary")}`)
      }
      const beforeOwner = before.owner?.name || "Unassigned"
      const afterOwner = after.owner?.name || "Unassigned"
      if (beforeOwner !== afterOwner) changes.push(`Owner: ${beforeOwner} → ${afterOwner}`)
      if (event.note) changes.push(`Note: ${event.note}`)
      const timestamp = this.#dateText(event.created_at || event.createdAt)
      item.textContent = `${actor} · ${changes.join(" · ") || "Work updated"}${timestamp ? ` · ${timestamp}` : ""}`
      this.workHistoryListTarget.append(item)
    })
  }

  #closeActionMenus() {
    if (this.hasManageTarget) this.manageTarget.open = false
    if (this.hasPreferencesTarget) this.preferencesTarget.open = false
    if (this.hasWorkManageTarget) this.workManageTarget.open = false
    if (this.hasWorkHistoryTarget) this.workHistoryTarget.open = false
  }

  #updateComposer(thread) {
    const currentUser = this.#threadMembership(thread)
    const locked = thread.status === "locked"
    const canPost = currentUser.joined || thread.status !== "locked"
    if (!this.hasComposerMountTarget) return
    this.composerMountTarget.dataset.threadId = thread.id || ""
    this.composerMountTarget.dataset.threadMessagesUrl = this.#threadMessagesURL(thread)
    this.composerMountTarget.dataset.threadRoomId = thread.room?.id || thread.room_id || this.#config().roomId
    this.composerMountTarget.dataset.threadStatus = thread.status || "active"
    if (this.hasComposerStatusTarget) {
      this.composerStatusTarget.textContent = locked ? "This thread is locked." : (canPost ? "" : "Join the thread to reply, or send a message to join automatically.")
    }
    this.composerMountTarget.toggleAttribute("data-thread-locked", locked)

    window.dispatchEvent(new CustomEvent("thread-panel:composer", {
      detail: {
        thread,
        mount: this.composerMountTarget,
        messages: this.hasMessagesTarget ? this.messagesTarget : null,
        url: this.#threadMessagesURL(thread),
        roomId: thread.room?.id || thread.room_id || this.#config().roomId,
        threadId: thread.id,
        disabled: locked,
      },
    }))
  }

  #messageCard(message, { parent = false } = {}) {
    const creator = message.creator || message.author || {}
    const card = document.createElement(parent ? "div" : "article")
    card.className = parent ? "thread-panel__parent-message" : "thread-panel__message"
    if (message.id !== undefined) card.dataset.messageId = String(message.id)
    if (message.room?.id !== undefined) card.dataset.roomId = String(message.room.id)
    if (message.thread_id !== undefined) card.dataset.threadId = String(message.thread_id)

    const avatar = document.createElement("img")
    avatar.className = parent ? "thread-panel__parent-avatar" : "thread-panel__avatar"
    avatar.alt = ""
    avatar.setAttribute("aria-hidden", "true")
    const avatarURL = creator.avatar_url || creator.avatarUrl || this.#config().defaultAvatarUrl
    avatar.src = this.#safeHTMLURL(avatarURL) ? avatarURL : this.#config().defaultAvatarUrl

    const main = document.createElement("div")
    main.className = parent ? "thread-panel__parent-main" : "thread-panel__message-main"
    const heading = document.createElement("div")
    heading.className = parent ? "thread-panel__parent-heading" : "thread-panel__message-heading"
    const author = document.createElement("span")
    author.className = parent ? "thread-panel__parent-author" : "thread-panel__message-author"
    author.textContent = creator.name || "Unknown member"
    heading.append(author)

    const timestamp = this.#dateText(message.created_at || message.createdAt || message.timestamp)
    if (timestamp) {
      const meta = document.createElement("time")
      meta.className = parent ? "thread-panel__parent-meta" : "thread-panel__message-meta"
      meta.dateTime = String(message.created_at || message.createdAt || "")
      meta.textContent = timestamp
      heading.append(meta)
    }
    main.append(heading)

    const reply = message.reply_to || message.replyTo
    if (reply) {
      const replyPreview = document.createElement("div")
      replyPreview.className = "thread-panel__reply-preview"
      const replyAuthor = reply.creator?.name || reply.author?.name || "Original message"
      replyPreview.textContent = `Replying to ${replyAuthor}: ${reply.body?.plain_text || reply.body?.plainText || ""}`
      if (reply.url && this.#safeHTMLURL(reply.url)) {
        const link = document.createElement("a")
        link.href = reply.url
        link.textContent = " View"
        link.addEventListener("click", event => this.#focusMessage(reply.id, event))
        replyPreview.append(link)
      }
      main.append(replyPreview)
    }

    const body = document.createElement("div")
    body.className = parent ? "thread-panel__parent-body" : "thread-panel__message-body"
    const html = message.body?.html || message.html || message.rendered_html || message.renderedHtml
    if (html) {
      this.#appendSafeHTML(body, html)
    } else {
      body.textContent = message.body?.plain_text || message.body?.plainText || message.plain_text || message.text || ""
    }
    if (message.forwarded || message.forwarded_at || message.forwardedAt) {
      const forwarded = document.createElement("span")
      forwarded.className = "thread-panel__forwarded-label"
      forwarded.textContent = "Forwarded"
      main.append(forwarded)
    }
    main.append(body)

    if (parent) {
      card.append(avatar, main)
    } else {
      card.append(avatar, main)
    }
    return card
  }

  #appendSafeHTML(container, html) {
    const parsed = new DOMParser().parseFromString(String(html), "text/html")
    parsed.querySelectorAll("base, script, style, iframe, object, embed, form, input, button, textarea, select, meta, link, svg, math").forEach(node => node.remove())
    parsed.querySelectorAll("*").forEach(node => {
      Array.from(node.attributes).forEach(attribute => {
        const name = attribute.name.toLowerCase()
        if (name.startsWith("on") || name === "style" || name === "srcdoc" || name === "srcset") {
          node.removeAttribute(attribute.name)
        } else if (["href", "src", "action", "formaction", "poster", "xlink:href"].includes(name) && !this.#safeHTMLURL(attribute.value)) {
          node.removeAttribute(attribute.name)
        }
      })
    })
    Array.from(parsed.body.childNodes).forEach(node => container.append(node.cloneNode(true)))
  }

  #safeHTMLURL(value) {
    const raw = String(value ?? "").trim()
    if (!raw || raw.startsWith("#")) return true

    try {
      const protocol = new URL(raw, document.baseURI).protocol.toLowerCase()
      return ["http:", "https:", "mailto:", "tel:"].includes(protocol)
    } catch {
      return false
    }
  }

  #focusMessage(messageId, event) {
    if (event) event.preventDefault()
    const target = this.messagesTarget.querySelector(`[data-message-id="${CSS.escape(String(messageId))}"]`)
    target?.scrollIntoView({ block: "center", behavior: "smooth" })
  }

  #statusMessage(thread) {
    if (thread.status === "locked") return "Locked thread · only a moderator can reopen it."
    if (thread.status === "closed") return "Closed thread · posting reopens it."
    return ""
  }

  #workStatusLabel(status) {
    return {
      planned: "Planned",
      in_progress: "In progress",
      blocked: "Blocked",
      done: "Done",
      ordinary: "Ordinary thread",
    }[status] || String(status || "Planned").replaceAll("_", " ")
  }

  #renderWorkOwnerLabel(thread) {
    const owner = thread.work_owner
    this.workOwnerLabelTarget.replaceChildren()
    if (!owner) {
      this.workOwnerLabelTarget.textContent = "Owner: Unassigned"
      return
    }
    const unavailable = thread.work_owner_active === false || owner.active === false
    this.workOwnerLabelTarget.append(unavailable ? `Owner unavailable: ${owner.name}` : `Owner: ${owner.name}`)
    if (owner.agent) {
      const badge = document.createElement("span")
      badge.className = "agent-badge"
      badge.textContent = "agent"
      this.workOwnerLabelTarget.append(badge)
    }
  }

  #statusLabel(thread) {
    return thread.status === "active" ? "Active" : (thread.status || "Closed")
  }

  #channelLabel() {
    const name = this.#config().channelName
    return name ? `#${name}` : "Parent channel"
  }

  #dateText(value) {
    if (!value) return ""
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return ""
    return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)
  }

  #emptyThreadListMessage() {
    switch (this.filterTarget.value) {
      case "work":
        return "No open work in this channel. Open a thread, then choose Manage → Track as work to give it a status and an owner."
      case "done":
        return "No completed work in this channel yet. Tracked work appears here once its status is set to Done."
      case "closed":
        return "No closed threads in this channel."
      default:
        return "No threads yet. Choose New thread to start one."
    }
  }

  #renderThreadList() {
    const list = this.browserListTarget
    list.replaceChildren()
    if (this.#threads.length === 0) {
      this.browserStatusTarget.textContent = this.#emptyThreadListMessage()
      return
    }
    this.browserStatusTarget.textContent = ""

    this.#threads.forEach(thread => {
      const item = document.createElement("button")
      item.type = "button"
      item.className = "thread-panel__thread-item"
      item.dataset.threadId = String(thread.id)
      item.dataset.threadUrl = this.#threadUrl(thread.id) || ""
      item.dataset.unread = String(Boolean(this.#threadMembership(thread).unread || this.#unreadThreadIds.has(String(thread.id))))
      item.dataset.action = "thread-panel#openThreadFromList"

      const name = document.createElement("span")
      name.className = "thread-panel__thread-name overflow-ellipsis"
      name.textContent = thread.name || "Untitled thread"
      const status = document.createElement("span")
      status.className = "thread-panel__thread-status-label"
      status.textContent = thread.status || "active"
      const preview = document.createElement("span")
      preview.className = "thread-panel__thread-preview overflow-ellipsis"
      preview.textContent = this.#threadPreview(thread)
      const count = document.createElement("span")
      count.className = "thread-panel__thread-count"
      count.textContent = `${Number(thread.message_count || thread.messageCount || thread.messages_count || 0)} messages · ${Number(thread.member_count || thread.memberCount || 0)} members`
      item.append(name, status, preview, count)
      list.append(item)
    })
    this.#updateUnreadToggle()
  }

  #threadPreview(thread) {
    const parent = thread.parent_message || thread.parentMessage
    const latest = thread.last_message || thread.lastMessage
    return latest?.body?.plain_text || latest?.body?.plainText || parent?.body?.plain_text || parent?.body?.plainText || ""
  }

  #updateThreadListItem(thread) {
    const item = this.browserListTarget.querySelector(`[data-thread-id="${CSS.escape(String(thread.id))}"]`)
    if (!item) return
    item.dataset.unread = String(Boolean(this.#threadMembership(thread).unread || this.#unreadThreadIds.has(String(thread.id))))
  }

  #updateUnreadToggle() {
    const unreadCount = this.#threads.filter(thread => {
      const current = this.#threadMembership(thread)
      return Boolean(current.unread || this.#unreadThreadIds.has(String(thread.id)))
    }).length + this.#unreadThreadIds.size - this.#threads.filter(thread => this.#unreadThreadIds.has(String(thread.id))).length
    this.browserToggleTargets.forEach(toggle => {
      toggle.dataset.unreadCount = String(unreadCount)
      toggle.setAttribute("aria-label", unreadCount > 0 ? `Browse threads, ${unreadCount} unread` : "Browse threads")
      const badge = toggle.querySelector("[data-thread-panel-unread]")
      if (badge) {
        badge.textContent = unreadCount > 0 ? String(unreadCount) : ""
        badge.hidden = unreadCount === 0
      }
    })
  }

  #markReadIfJoined(thread, { requireVisible = false, requireLatest = false } = {}) {
    const current = this.#threadMembership(thread)
    if (!current.joined || !thread.id) return
    if (requireVisible && (!this.#isOpen || this.conversationTarget.hidden || document.visibilityState !== "visible")) return
    if (requireLatest && this.contentTarget.dataset.threadContentAtLatest !== "true") return
    this.#unreadThreadIds.delete(String(thread.id))
    current.unread = false
    thread.unread = false
    const contextGeneration = this.#threadContextGeneration
    if (this.#isCurrentThreadContext(thread, contextGeneration)) {
      this.#requestJSON(`${this.#threadURL(thread)}/read`, { method: "POST" }).catch(() => {})
    }
    this.#updateThreadListItem(thread)
    this.#updateUnreadToggle()
  }

  async #mutateThread(method, suffix, status, body = undefined) {
    const currentThread = this.#currentThread
    const contextGeneration = this.#threadContextGeneration
    if (!currentThread) return
    this.threadStatusTarget.textContent = status
    try {
      const url = suffix ? `${this.#threadURL(currentThread)}/${suffix}` : this.#threadURL(currentThread)
      const payload = await this.#requestJSON(url, { method, body })
      if (!this.#isCurrentThreadContext(currentThread, contextGeneration)) return
      const responseThread = payload.thread || (Object.keys(payload).length > 0 ? payload : currentThread)
      const thread = this.#normalizeThread(responseThread)
      this.#rememberThreadParent(thread)
      thread.parent_message ||= this.#threadParent
      if (method === "DELETE" && suffix === "leave") {
        thread.joined = false
        thread.unread = false
        thread.involvement = "nothing"
        thread.current_user = { joined: false, unread: false, involvement: "nothing" }
      }
      this.#currentThread = thread
      this.#renderThreadMetadata(thread)
      this.#syncThreadContent(thread)
      if (method === "POST" && suffix === "join") this.#markReadIfJoined(thread, { requireVisible: true, requireLatest: true })
    } catch (error) {
      if (!this.#isCurrentThreadContext(currentThread, contextGeneration)) return
      this.threadStatusTarget.textContent = this.#errorMessage(error, "Couldn’t update the thread")
    }
  }

  #updateState(status) {
    const params = new URLSearchParams()
    params.set("thread[status]", status)
    return this.#mutateThread("PATCH", "", `${status === "active" ? "Reopening" : status === "locked" ? "Locking" : "Closing"} thread…`, params)
  }

  #normalizeThread(raw) {
    if (!raw || typeof raw !== "object") return {}
    return {
      ...raw,
      id: raw.id ?? raw.thread_id ?? raw.threadId,
      url: raw.url || raw.path,
      status: raw.status || (raw.locked_at || raw.lockedAt ? "locked" : (raw.closed_at || raw.closedAt ? "closed" : "active")),
      current_user: this.#threadMembership(raw),
      messages: Array.isArray(raw.messages) ? raw.messages : (raw.messages?.data || []),
      room: raw.room || (raw.room_id !== undefined ? { id: raw.room_id } : {}),
      parent_message: raw.parent_message || raw.parentMessage,
    }
  }

  #rememberThreadParent(thread) {
    const parent = thread?.parent_message || thread?.parentMessage
    if (parent) {
      this.#threadParent = parent
      return
    }

    const hasParentReference = thread && (
      Object.prototype.hasOwnProperty.call(thread, "parent_message_id") ||
      Object.prototype.hasOwnProperty.call(thread, "parentMessageId")
    )
    const parentId = thread?.parent_message_id ?? thread?.parentMessageId
    if (hasParentReference && (parentId === null || parentId === undefined || parentId === "")) {
      this.#threadParent = null
    }
  }

  #threadMembership(thread) {
    const current = thread?.current_user || thread?.currentUser
    if (current && typeof current === "object") return current

    // Thread payloads intentionally keep the member-specific state flat so the
    // same serializer can be used for message summaries and full thread views.
    return {
      joined: Boolean(thread?.joined),
      unread: Boolean(thread?.unread),
      involvement: thread?.involvement,
    }
  }

  #clientMessageId() {
    if (window.crypto?.randomUUID) return window.crypto.randomUUID()
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  }

  #threadURL(thread) {
    return this.#threadUrl(thread?.id)
  }

  #threadUrl(id) {
    const normalizedId = this.#numericThreadId(id)
    const base = this.#threadBasePath()
    return normalizedId && base ? `${window.location.origin}${base}/${normalizedId}` : null
  }

  #threadMessagesURL(thread) {
    const url = this.#threadURL(thread)
    return url ? `${url}/messages` : null
  }

  #threadContentURL(thread) {
    const url = this.#threadURL(thread)
    return url ? `${url}/content` : null
  }

  #config() {
    const data = this.panelTarget.dataset
    return {
      roomId: data.threadPanelRoomId,
      threadsUrl: data.threadPanelThreadsUrl,
      createUrl: data.threadPanelCreateUrl || data.threadPanelThreadsUrl,
      channelName: data.threadPanelChannelName,
      defaultAvatarUrl: data.threadPanelDefaultAvatarUrl,
    }
  }

  async #loadThreads() {
    const { threadsUrl } = this.#config()
    if (!threadsUrl) return
    const listGeneration = ++this.#threadListGeneration
    this.#abortRequest()
    this.browserStatusTarget.textContent = "Loading threads…"
    this.browserListTarget.replaceChildren()
    const state = this.filterTarget.value || "active"
    const url = new URL(threadsUrl, window.location.origin)
    url.searchParams.set("state", state)
    try {
      const payload = await this.#requestJSON(url.toString())
      if (listGeneration !== this.#threadListGeneration || !this.#isOpen || this.browserTarget.hidden) return
      const rawThreads = payload.threads || payload.data || payload
      this.#threads = Array.isArray(rawThreads) ? rawThreads.map(item => this.#normalizeThread(item)) : []
      this.#renderThreadList()
    } catch (error) {
      if (listGeneration !== this.#threadListGeneration || !this.#isOpen || this.browserTarget.hidden) return
      this.browserStatusTarget.textContent = this.#errorMessage(error, "Couldn’t load threads")
    }
  }

  #startRefreshing() {
    this.#stopRefreshing()
    if (!this.#isOpen || !this.#currentThread) return
    this.#refreshTimer = window.setInterval(() => this.#refreshCurrentThread(), REFRESH_INTERVAL)
  }

  #stopRefreshing() {
    window.clearInterval(this.#refreshTimer)
    this.#refreshTimer = null
  }

  async #refreshCurrentThread() {
    const currentThread = this.#currentThread
    const contextGeneration = this.#threadContextGeneration
    if (!this.#isCurrentThreadContext(currentThread, contextGeneration) || document.visibilityState !== "visible") return
    try {
      const payload = await this.#requestJSON(this.#threadURL(currentThread))
      if (!this.#isCurrentThreadContext(currentThread, contextGeneration)) return
      const thread = this.#normalizeThread(payload.thread || payload)
      thread.parent_message ||= payload.parent_message || payload.parentMessage
      this.#rememberThreadParent(thread)
      thread.parent_message ||= this.#threadParent
      thread.messages = thread.messages.length > 0 ? thread.messages : (Array.isArray(payload.messages) ? payload.messages : [])
      if (!this.#isCurrentThreadContext(currentThread, contextGeneration)) return
      this.#currentThread = thread
      this.#renderThreadMetadata(thread)
      this.#syncThreadContent(thread)
    } catch {
      // A transient refresh failure should not erase the open conversation.
    }
  }

  #abortRequest() {
    this.#request?.abort()
    this.#request = null
  }

  async #requestJSON(url, options = {}) {
    const safeURL = this.#safeThreadRequestURL(url)
    if (!safeURL) throw this.#invalidThreadURL()

    const headers = new Headers(options.headers || {})
    headers.set("Accept", "application/json")
    if (options.method && options.method !== "GET") {
      headers.set("X-CSRF-Token", document.querySelector("meta[name='csrf-token']")?.content || "")
    }
    const controller = new AbortController()
    this.#request = controller
    try {
      const response = await fetch(safeURL, { ...options, headers, signal: controller.signal })
      const contentType = response.headers.get("content-type") || ""
      let payload = {}
      if (response.status !== 204) {
        payload = contentType.includes("json") ? await response.json() : {}
      }
      if (!response.ok) {
        const error = new Error(payload.error || payload.message || response.statusText)
        error.status = response.status
        throw error
      }
      return payload
    } finally {
      if (this.#request === controller) this.#request = null
    }
  }

  async #requestHTML(url, options = {}) {
    const safeURL = this.#safeThreadRequestURL(url, { resource: "content" })
    if (!safeURL) throw this.#invalidThreadURL()

    const headers = new Headers(options.headers || {})
    headers.set("Accept", "text/html")
    const controller = new AbortController()
    this.#request = controller
    try {
      const response = await fetch(safeURL, { ...options, headers, signal: controller.signal })
      if (!response.ok) {
        const error = new Error(response.statusText)
        error.status = response.status
        throw error
      }
      return {
        html: await response.text(),
        atLatest: response.headers.get("X-Thread-Content-At-Latest") !== "false",
      }
    } finally {
      if (this.#request === controller) this.#request = null
    }
  }

  #errorMessage(error, fallback) {
    if (error?.name === "AbortError") return ""
    return error?.message || fallback
  }

  #invalidThreadURL() {
    const error = new Error("This thread link is invalid.")
    error.code = "invalid_thread_url"
    return error
  }

  #showInvalidThreadLink() {
    if (!this.#isOpen) this.#openPanel({ focus: false })
    this.#setView("conversation")
    this.#currentThread = null
    this.#threadMessageId = null
    this.#threadParent = null
    this.parentTarget.hidden = true
    this.contentTarget.replaceChildren()
    delete this.contentTarget.dataset.threadContentAtLatest
    this.emptyTarget.hidden = true
    this.threadStatusTarget.textContent = "This thread link is invalid."
    if (this.hasRetryTarget) this.retryTarget.hidden = true
  }

  #threadIdFromReference(detail) {
    const suppliedId = this.#numericThreadId(detail.thread?.id ?? detail.threadId ?? detail.id)
    const suppliedURL = detail.url || detail.thread?.url
    if (!suppliedURL) return suppliedId
    const numericReference = this.#numericThreadId(suppliedURL)
    if (numericReference) return suppliedId && suppliedId !== numericReference ? null : numericReference

    const safeURL = this.#safeThreadRequestURL(suppliedURL, { resource: "thread" })
    if (!safeURL) return null
    const parsed = new URL(safeURL)
    const match = this.#threadPathMatch(parsed.pathname)
    const pathId = match?.[1]
    if (!pathId || (suppliedId && suppliedId !== pathId)) return null
    return pathId
  }

  #numericThreadId(value) {
    const id = String(value ?? "")
    return /^\d+$/.test(id) && Number(id) > 0 ? id : null
  }

  #threadBasePath() {
    const roomId = this.#numericThreadId(this.#config().roomId)
    if (!roomId) return null

    let configured
    try {
      configured = new URL(this.#config().threadsUrl, window.location.origin)
    } catch {
      return null
    }
    if (configured.origin !== window.location.origin) return null

    const path = this.#stripFormatExtension(configured.pathname).replace(/\/$/, "")
    const expected = `/rooms/${roomId}/threads`
    return path === expected ? expected : null
  }

  #threadPathMatch(pathname) {
    const base = this.#threadBasePath()
    if (!base) return null
    const path = this.#stripFormatExtension(pathname).replace(/\/$/, "")
    const escapedBase = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return path.match(new RegExp(`^${escapedBase}/(\\d+)(?:/(messages|content|join|leave|read))?$`))
  }

  #safeThreadRequestURL(raw, { resource = "any" } = {}) {
    let parsed
    try {
      parsed = new URL(String(raw), window.location.origin)
    } catch {
      return null
    }
    if (parsed.origin !== window.location.origin) return null
    if (parsed.searchParams.has("message_id") && !this.#numericThreadId(parsed.searchParams.get("message_id"))) return null

    const path = this.#stripFormatExtension(parsed.pathname).replace(/\/$/, "")
    const base = this.#threadBasePath()
    if (!base) return null
    if (path === base && resource !== "thread" && resource !== "content") return parsed.toString()

    const match = this.#threadPathMatch(path)
    if (!match) return null
    const suffix = match[2] || "thread"
    if (resource === "thread" && suffix !== "thread") return null
    if (resource === "content" && suffix !== "content") return null
    if (resource === "collection") return null
    return parsed.toString()
  }

  #stripFormatExtension(path) {
    return String(path || "").replace(/\.(?:json|html)(?=\/|$)/g, "")
  }

  async #subscribeToUnreadThreads(subscriptionGeneration) {
    try {
      const channel = await cable.subscribeTo({ channel: "UnreadThreadsChannel" }, {
        received: this.#onUnreadThread,
      })
      if (this.#subscriptionGeneration === subscriptionGeneration && this.element.isConnected) {
        this.channel = channel
      } else {
        channel.unsubscribe()
      }
    } catch {
      if (this.#subscriptionGeneration === subscriptionGeneration) this.channel = null
    }
  }

  #handleUnreadThread(payload) {
    if (!this.element.isConnected) return
    const roomId = payload?.roomId ?? payload?.room_id
    if (String(roomId) !== String(this.#config().roomId)) return
    const threadId = payload?.threadId ?? payload?.thread_id
    if (threadId !== undefined) {
      this.#unreadThreadIds.add(String(threadId))
      if (this.#currentThread && String(this.#currentThread.id) === String(threadId)) {
        this.#currentThread.unread = true
        this.#threadMembership(this.#currentThread).unread = true
        this.#markReadIfJoined(this.#currentThread, { requireVisible: true, requireLatest: true })
      }
    }
    if (!this.#currentThread || String(this.#currentThread.id) !== String(threadId)) this.#updateUnreadToggle()
    if (this.#isOpen && this.hasBrowserTarget && !this.browserTarget.hidden) this.#loadThreads()
  }

  #handleMessageThread(event) {
    const detail = event.detail || {}
    if (detail.roomId && String(detail.roomId) !== String(this.#config().roomId)) return
    const summary = this.#normalizeThread(detail.threadSummary || detail.thread || {})
    const url = detail.threadUrl || summary.url
    if (url || summary.id) {
      this.openThread({ detail: { ...detail, thread: summary, url }, preventDefault() {} })
    } else {
      this.beginCreate(undefined, {
        parentMessageId: detail.messageId,
        parent: {
          id: detail.messageId,
          room: { id: detail.roomId || this.#config().roomId },
          creator: { name: detail.author },
          body: { plain_text: detail.previewText || detail.source || "" },
          created_at: detail.createdAt,
        },
      })
    }
  }

  #handleThreadPanelOpen(event) {
    const detail = event.detail || {}
    if (!detail.url && !detail.id) return
    const thread = detail.thread || { id: detail.id, url: detail.url }
    this.openThread({ detail: { ...detail, thread }, preventDefault() {} })
  }

  #handleVisibilityChange() {
    if (document.visibilityState !== "visible" || !this.#isOpen || !this.#currentThread) return

    this.#refreshCurrentThread()
    if (this.contentTarget.dataset.threadContentAtLatest === "true") {
      this.#markReadIfJoined(this.#currentThread, { requireVisible: true, requireLatest: true })
    }
  }

  #focusableElements() {
    return Array.from(this.panelTarget.querySelectorAll(FOCUSABLE_SELECTOR)).filter(element => {
      return !element.hidden && element.tabIndex >= 0 && element.getClientRects().length > 0
    })
  }

  #restoreFocus() {
    const target = this.#previouslyFocusedElement
    if (target?.isConnected && !target.hidden && !this.panelTarget.contains(target)) {
      target.focus({ preventScroll: true })
    }
    this.#previouslyFocusedElement = null
  }
}
