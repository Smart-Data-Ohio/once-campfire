import { Controller } from "@hotwired/stimulus"

const FOCUSABLE_SELECTOR = "button:not([disabled]), a[href]:not([aria-disabled='true'])"
const LONG_PRESS_DELAY = 550
const MOVE_THRESHOLD = 10
const VIEWPORT_PADDING = 8

export default class extends Controller {
  static targets = [
    "menu", "item", "threadLabel", "status", "forwardDialog", "forwardPreview", "forwardNote",
    "forwardDestinations", "forwardStatus", "forwardSubmit"
  ]
  static values = {
    messageUrl: String,
    metadataUrl: String,
    permalinkUrl: String,
  }

  #message
  #longPressTimer
  #longPressPointer
  #longPressTriggered = false
  #metadata
  #metadataRequest
  #forwardDestinationsRequest
  #forwardDestinationsController
  #previouslyFocusedElement
  #menuPoint
  #menuId
  #announceTimer
  #forwardPreviouslyFocusedElement
  #open = false
  #connected = false

  connect() {
    this.#message = this.element.closest(".message")
    if (!this.#message || !this.hasMenuTarget) return
    this.#connected = true

    this.#menuId = this.menuTarget.id || `message-actions-${this.#message.dataset.messageId || Math.random().toString(36).slice(2)}`
    this.menuTarget.id = this.#menuId
    this.#message.tabIndex = this.#message.tabIndex < 0 ? 0 : this.#message.tabIndex
    this.#message.setAttribute("aria-haspopup", "menu")
    this.#message.setAttribute("aria-controls", this.#menuId)
    this.#message.setAttribute("aria-expanded", "false")

    this.onContextMenu = this.#onContextMenu.bind(this)
    this.onPointerDown = this.#onPointerDown.bind(this)
    this.onPointerMove = this.#onPointerMove.bind(this)
    this.onPointerUp = this.#onPointerUp.bind(this)
    this.onKeydown = this.#onKeydown.bind(this)
    this.onMenuKeydown = this.#onMenuKeydown.bind(this)
    this.onMenuClick = this.#onMenuClick.bind(this)
    this.onDocumentPointerDown = this.#onDocumentPointerDown.bind(this)
    this.onWindowKeydown = this.#onWindowKeydown.bind(this)
    this.onOtherMenuOpened = this.#onOtherMenuOpened.bind(this)
    this.onEditLast = this.#onEditLast.bind(this)
    this.onCancelLongPress = this.#cancelLongPress.bind(this)
    this.onReposition = this.#reposition.bind(this)
    this.onForwardClose = this.#onForwardClose.bind(this)

    this.#message.addEventListener("contextmenu", this.onContextMenu)
    this.#message.addEventListener("pointerdown", this.onPointerDown)
    this.#message.addEventListener("pointermove", this.onPointerMove)
    this.#message.addEventListener("pointerup", this.onPointerUp)
    this.#message.addEventListener("pointercancel", this.onPointerUp)
    this.#message.addEventListener("keydown", this.onKeydown)
    this.menuTarget.addEventListener("keydown", this.onMenuKeydown)
    this.menuTarget.addEventListener("click", this.onMenuClick)
    this.forwardDialogTarget?.addEventListener("close", this.onForwardClose)
    document.addEventListener("pointerdown", this.onDocumentPointerDown)
    window.addEventListener("keydown", this.onWindowKeydown)
    window.addEventListener("scroll", this.onCancelLongPress, true)
    window.addEventListener("resize", this.onReposition)
    window.visualViewport?.addEventListener("resize", this.onReposition)
    window.visualViewport?.addEventListener("scroll", this.onReposition)
    window.addEventListener("message-actions:opening", this.onOtherMenuOpened)
    window.addEventListener("message-actions:edit-last", this.onEditLast)
  }

  disconnect() {
    this.#connected = false
    this.#cancelLongPress()
    this.#metadataRequest?.abort()
    this.#forwardDestinationsController?.abort()

    this.#message?.removeEventListener("contextmenu", this.onContextMenu)
    this.#message?.removeEventListener("pointerdown", this.onPointerDown)
    this.#message?.removeEventListener("pointermove", this.onPointerMove)
    this.#message?.removeEventListener("pointerup", this.onPointerUp)
    this.#message?.removeEventListener("pointercancel", this.onPointerUp)
    this.#message?.removeEventListener("keydown", this.onKeydown)
    this.menuTarget?.removeEventListener("keydown", this.onMenuKeydown)
    this.menuTarget?.removeEventListener("click", this.onMenuClick)
    this.forwardDialogTarget?.removeEventListener("close", this.onForwardClose)
    document.removeEventListener("pointerdown", this.onDocumentPointerDown)
    window.removeEventListener("keydown", this.onWindowKeydown)
    window.removeEventListener("scroll", this.onCancelLongPress, true)
    window.removeEventListener("resize", this.onReposition)
    window.visualViewport?.removeEventListener("resize", this.onReposition)
    window.visualViewport?.removeEventListener("scroll", this.onReposition)
    window.removeEventListener("message-actions:opening", this.onOtherMenuOpened)
    window.removeEventListener("message-actions:edit-last", this.onEditLast)
  }

  openFromContext(event) {
    event.preventDefault()
    this.#openMenu({ x: event.clientX, y: event.clientY })
  }

  close(event) {
    this.#closeMenu()
  }

  reply(event) {
    event.preventDefault()
    this.#dispatchMessageEvent("message:reply")
    this.#closeMenu({ restoreFocus: false })
  }

  edit(event) {
    event.preventDefault()
    this.#dispatchMessageEvent("message:edit")
    this.#closeMenu({ restoreFocus: false })
  }

  copyText(event) {
    event.preventDefault()
    const content = this.#copyTextContent()
    this.#copy(content, "Message copied")
  }

  copyLink(event) {
    event.preventDefault()
    this.#copy(this.permalinkUrlValue || this.messageUrlValue, "Message link copied")
  }

  forward(event) {
    event.preventDefault()
    const detail = {
      forwardUrl: this.#stringFromMetadata("forward_url", "forwardUrl"),
      sourceUrl: this.permalinkUrlValue || this.messageUrlValue,
    }
    this.#dispatchMessageEvent("message:forward", detail)
    this.#openForwardDialog(detail)
    this.#closeMenu({ restoreFocus: false })
  }

  closeForward(event) {
    event?.preventDefault()
    this.#closeForwardDialog()
  }

  async submitForward(event) {
    event.preventDefault()
    if (!this.hasForwardDialogTarget || this.forwardSubmitTarget.disabled) return

    const selected = this.forwardDestinationsTarget.querySelectorAll("input[type='checkbox']:checked")
    if (selected.length === 0) {
      this.#setForwardStatus("Choose at least one destination.")
      return
    }
    if (selected.length > 5) {
      this.#setForwardStatus("Choose up to 5 destinations.")
      return
    }

    const url = this.#stringFromMetadata("forward_url", "forwardUrl") || `${this.messageUrlValue}/forwards`
    const destinations = Array.from(selected, input => {
      const destination = { room_id: input.dataset.roomId || input.value }
      if (input.dataset.threadId) destination.thread_id = input.dataset.threadId
      return destination
    })
    const note = this.hasForwardNoteTarget ? this.forwardNoteTarget.value.trim() : ""
    this.forwardSubmitTarget.disabled = true
    this.#setForwardStatus("Forwarding…")

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
        },
        body: JSON.stringify({ forward: { note: note || null, destinations } }),
      })

      if (!response.ok) throw new Error(await this.#responseError(response))

      this.#setForwardStatus(`Forwarded to ${destinations.length} ${destinations.length === 1 ? "destination" : "destinations"}.`)
      setTimeout(() => this.#closeForwardDialog(), 650)
    } catch (error) {
      this.#setForwardStatus(error.message || "Couldn’t forward message.")
    } finally {
      this.forwardSubmitTarget.disabled = false
    }
  }

  thread(event) {
    event.preventDefault()
    this.#dispatchMessageEvent("message:thread", {
      threadUrl: this.#stringFromMetadata("thread_url", "threadUrl"),
      threadSummary: this.#metadata?.thread_summary || this.#metadata?.threadSummary || null,
    })
    this.#closeMenu({ restoreFocus: false })
  }

  async delete(event) {
    event.preventDefault()
    if (!window.confirm("Are you sure you want to delete this message?")) return

    const message = this.#message
    const response = await fetch(this.messageUrlValue, {
      method: "DELETE",
      headers: {
        Accept: "text/vnd.turbo-stream.html, application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
      },
    }).catch(() => null)

    if (!response?.ok) {
      this.#announce("Couldn’t delete message")
      return
    }

    const contentType = response.headers.get("content-type") || ""
    if (contentType.includes("turbo-stream")) {
      Turbo.renderStreamMessage(await response.text())
    } else if (message?.isConnected) {
      message.remove()
    }

    this.#closeMenu({ restoreFocus: false })
  }

  // Internal event handlers

  #onContextMenu(event) {
    if (this.#isInteractive(event.target)) return
    event.preventDefault()
    if (this.#longPressPointer) return
    this.#openMenu({ x: event.clientX, y: event.clientY })
  }

  #onPointerDown(event) {
    if (event.pointerType !== "touch" || event.button !== 0 || this.#isInteractive(event.target)) return

    this.#cancelLongPress()
    this.#longPressPointer = { id: event.pointerId, x: event.clientX, y: event.clientY }
    this.#longPressTimer = setTimeout(() => {
      if (!this.#longPressPointer) return
      this.#longPressTriggered = true
    }, LONG_PRESS_DELAY)
  }

  #onPointerMove(event) {
    if (!this.#longPressPointer || event.pointerId !== this.#longPressPointer.id) return

    const distance = Math.hypot(event.clientX - this.#longPressPointer.x, event.clientY - this.#longPressPointer.y)
    if (distance > MOVE_THRESHOLD) this.#cancelLongPress()
  }

  #onPointerUp(event) {
    if (event.type === "pointercancel") {
      this.#cancelLongPress()
      return
    }
    if (this.#longPressPointer && event.pointerId === this.#longPressPointer.id && this.#longPressTriggered) {
      const { x, y } = this.#longPressPointer
      this.#cancelLongPress()
      setTimeout(() => this.#openMenu({ x, y }), 0)
      return
    }
    if (!this.#longPressPointer || event.pointerId === this.#longPressPointer.id) this.#cancelLongPress()
  }

  #onKeydown(event) {
    const contextMenuKey = event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)
    if (!contextMenuKey || this.#isInteractive(event.target)) return

    event.preventDefault()
    const rect = this.#message.getBoundingClientRect()
    this.#openMenu({ x: rect.left + Math.min(rect.width / 2, 240), y: rect.bottom })
  }

  #onMenuKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.#closeMenu()
      return
    }

    const items = this.#menuItems()
    if (items.length === 0) return

    const currentIndex = Math.max(0, items.indexOf(document.activeElement))
    let nextIndex

    switch (event.key) {
      case "ArrowDown":
        nextIndex = (currentIndex + 1) % items.length
        break
      case "ArrowUp":
        nextIndex = (currentIndex - 1 + items.length) % items.length
        break
      case "Home":
        nextIndex = 0
        break
      case "End":
        nextIndex = items.length - 1
        break
      case "Tab":
        event.preventDefault()
        this.#closeMenu()
        return
      default:
        return
    }

    event.preventDefault()
    this.#focusMenuItem(items[nextIndex])
  }

  #onMenuClick(event) {
    const item = event.target.closest(FOCUSABLE_SELECTOR)
    if (!item || !this.menuTarget.contains(item)) return

    // Actions that open another UI or submit a form close themselves. The delayed
    // close also lets the browser finish a normal link/form activation first.
    if (!item.matches("[data-action*='message-actions#delete']")) {
      setTimeout(() => this.#closeMenu({ restoreFocus: false }), 0)
    }
  }

  #onDocumentPointerDown(event) {
    if (this.#open && !this.#message.contains(event.target)) this.#closeMenu()
  }

  #onWindowKeydown(event) {
    if (this.#open && event.key === "Escape" && !this.menuTarget.contains(event.target)) {
      event.preventDefault()
      this.#closeMenu()
    }
  }

  #onOtherMenuOpened(event) {
    if (event.detail?.controller !== this) this.#closeMenu()
  }

  #onForwardClose() {
    this.#forwardDestinationsController?.abort()
    this.#forwardDestinationsController = null
    this.#forwardDestinationsRequest = null
    this.forwardDialogTarget?.querySelectorAll("input[type='checkbox']").forEach(input => {
      input.checked = false
      input.disabled = false
    })
    if (this.hasForwardNoteTarget) this.forwardNoteTarget.value = ""
    this.#setForwardStatus("")
    const focusTarget = this.#forwardPreviouslyFocusedElement?.isConnected ? this.#forwardPreviouslyFocusedElement : this.#message
    this.#forwardPreviouslyFocusedElement = null
    focusTarget?.focus?.({ preventScroll: true })
  }

  async #onEditLast(event) {
    if (event.detail?.message !== this.#message) return
    await this.#loadMetadata()
    if (this.#boolean(this.#metadata || {}, "can_edit", "canEdit", "editable") !== true) return
    this.#dispatchMessageEvent("message:edit")
  }

  // Menu lifecycle

  #openMenu(point) {
    if (!this.#message?.isConnected) return

    window.dispatchEvent(new CustomEvent("message-actions:opening", { detail: { controller: this } }))
    this.#previouslyFocusedElement = document.activeElement
    this.#menuPoint = point
    this.#open = true
    this.#message.setAttribute("data-message-actions-open", "")
    this.#message.setAttribute("aria-expanded", "true")
    this.menuTarget.hidden = false
    this.menuTarget.setAttribute("aria-hidden", "false")
    this.#showMenuPopover()
    this.#positionMenu()
    this.#loadMetadata()

    const focus = () => {
      this.#positionMenu()
      this.#focusMenuItem(this.#menuItems()[0])
    }
    if (window.requestAnimationFrame) window.requestAnimationFrame(focus)
    else setTimeout(focus, 0)
  }

  #closeMenu({ restoreFocus = true } = {}) {
    this.#cancelLongPress()
    if (!this.#open && this.menuTarget?.hidden) return

    this.#open = false
    this.#message?.removeAttribute("data-message-actions-open")
    this.#message?.setAttribute("aria-expanded", "false")
    if (this.menuTarget) {
      this.#hideMenuPopover()
      this.menuTarget.hidden = true
      this.menuTarget.setAttribute("aria-hidden", "true")
    }

    if (restoreFocus) {
      const focusTarget = this.#previouslyFocusedElement?.isConnected ? this.#previouslyFocusedElement : this.#message
      focusTarget?.focus?.({ preventScroll: true })
    }
    this.#previouslyFocusedElement = null
  }

  #openForwardDialog(detail) {
    if (!this.hasForwardDialogTarget) return

    this.#forwardPreviouslyFocusedElement = this.#previouslyFocusedElement?.isConnected
      ? this.#previouslyFocusedElement
      : this.#message
    this.#showForwardDestinationsLoading()
    if (this.hasForwardPreviewTarget) this.forwardPreviewTarget.textContent = this.#messageDetails().previewText
    if (this.forwardDialogTarget.showModal) {
      if (!this.forwardDialogTarget.open) this.forwardDialogTarget.showModal()
    } else {
      this.forwardDialogTarget.setAttribute("open", "")
    }
    void this.#loadForwardDestinations()
  }

  #closeForwardDialog() {
    if (!this.hasForwardDialogTarget) return
    if (this.forwardDialogTarget.open && this.forwardDialogTarget.close) {
      this.forwardDialogTarget.close()
    } else {
      this.forwardDialogTarget.removeAttribute("open")
      this.#onForwardClose()
    }
  }

  #showForwardDestinationsLoading() {
    if (!this.hasForwardDestinationsTarget) return

    const loading = document.createElement("p")
    loading.className = "message-forward-dialog__empty"
    loading.textContent = "Loading destinations…"
    this.forwardDestinationsTarget.replaceChildren(loading)
  }

  async #loadForwardDestinations() {
    if (!this.hasForwardDestinationsTarget || !this.#connected) return

    this.#forwardDestinationsController?.abort()
    const controller = new AbortController()
    this.#forwardDestinationsController = controller
    const request = this.#forwardDestinationsRequest = (async () => {
      const url = this.#stringFromMetadata("forward_destinations_url", "forwardDestinationsUrl") || this.#fallbackForwardDestinationsUrl()
      if (!url) {
        this.#populateForwardDestinations([])
        return
      }

      try {
        const response = await fetch(url, {
          headers: { Accept: "application/json" },
          cache: "no-store",
          signal: controller.signal,
        })

        if (!response.ok) throw new Error(await this.#responseError(response))

        const payload = await response.json()
        if (!this.#connected || controller.signal.aborted) return
        this.#populateForwardDestinations(payload.destinations || [])
      } catch (error) {
        if (error.name === "AbortError") return
        this.#populateForwardDestinations([])
        this.#setForwardStatus(error.message || "Couldn’t load destinations.")
      }
    })()

    try {
      await request
    } finally {
      if (this.#forwardDestinationsRequest === request) {
        this.#forwardDestinationsRequest = null
        this.#forwardDestinationsController = null
      }
    }
  }

  #fallbackForwardDestinationsUrl() {
    if (!this.messageUrlValue) return null
    return `${this.messageUrlValue.replace(/\/$/, "")}/forwards/destinations`
  }

  #populateForwardDestinations(destinations) {
    if (!this.hasForwardDestinationsTarget) return

    const nodes = []
    for (const destination of Array.isArray(destinations) ? destinations : []) {
      const roomId = destination.room_id ?? destination.id
      if (!roomId) continue

      const room = document.createElement("div")
      room.className = "message-forward-dialog__room"

      const heading = document.createElement("p")
      heading.className = "message-forward-dialog__room-name"
      heading.textContent = destination.name || `Room ${roomId}`
      room.append(heading)

      room.append(this.#forwardDestinationOption({
        roomId,
        label: destination.name || `Room ${roomId}`,
      }))

      for (const thread of Array.isArray(destination.threads) ? destination.threads : []) {
        if (!thread?.id) continue
        room.append(this.#forwardDestinationOption({
          roomId,
          threadId: thread.id,
          label: thread.name || `Thread ${thread.id}`,
          status: thread.status,
        }))
      }

      nodes.push(room)
    }

    this.forwardDestinationsTarget.replaceChildren(...nodes)
    if (nodes.length === 0) {
      const empty = document.createElement("p")
      empty.className = "message-forward-dialog__empty"
      empty.textContent = "No available destinations."
      this.forwardDestinationsTarget.append(empty)
      return
    }

    this.#enforceForwardLimit()
    this.forwardDestinationsTarget.querySelector("input")?.focus({ preventScroll: true })
  }

  #forwardDestinationOption({ roomId, threadId, label, status }) {
    const wrapper = document.createElement("label")
    wrapper.className = [
      "message-forward-dialog__destination",
      threadId ? "message-forward-dialog__destination--thread" : null,
    ].filter(Boolean).join(" ")

    const input = document.createElement("input")
    input.type = "checkbox"
    input.value = roomId
    input.dataset.roomId = roomId
    if (threadId) input.dataset.threadId = threadId
    input.addEventListener("change", () => this.#enforceForwardLimit())

    const text = document.createElement("span")
    text.textContent = threadId ? `↳ ${label}` : label
    if (status) text.title = status
    wrapper.append(input, text)
    return wrapper
  }

  #enforceForwardLimit() {
    if (!this.hasForwardDestinationsTarget) return
    const checkboxes = Array.from(this.forwardDestinationsTarget.querySelectorAll("input[type='checkbox']"))
    const selected = checkboxes.filter(input => input.checked)
    checkboxes.forEach(input => {
      input.disabled = !input.checked && selected.length >= 5
    })
    this.#setForwardStatus(selected.length >= 5 ? "Up to 5 destinations selected." : "")
  }

  #setForwardStatus(message) {
    if (this.hasForwardStatusTarget) this.forwardStatusTarget.textContent = message
  }

  async #responseError(response) {
    const fallback = `Couldn’t forward message (${response.status})`
    try {
      const payload = await response.clone().json()
      const value = payload.error || payload.errors
      if (typeof value === "string") return value
      if (value && typeof value === "object") {
        const message = Object.values(value).flat().find(Boolean)
        if (message) return String(message)
      }
    } catch {}
    return fallback
  }

  #positionMenu() {
    if (!this.#open || !this.menuTarget || this.menuTarget.hidden) return

    const point = this.#menuPoint || { x: 0, y: 0 }
    const rect = this.menuTarget.getBoundingClientRect()
    const viewportHeight = window.visualViewport?.height || window.innerHeight
    const maxX = Math.max(VIEWPORT_PADDING, window.innerWidth - rect.width - VIEWPORT_PADDING)
    const maxY = Math.max(VIEWPORT_PADDING, viewportHeight - rect.height - VIEWPORT_PADDING - this.#safeAreaBottom())

    this.menuTarget.style.left = `${Math.min(Math.max(VIEWPORT_PADDING, point.x), maxX)}px`
    this.menuTarget.style.top = `${Math.min(Math.max(VIEWPORT_PADDING, point.y), maxY)}px`
  }

  // Keep the menu above the home indicator on phones with a bottom inset.
  #safeAreaBottom() {
    return parseFloat(getComputedStyle(this.menuTarget).getPropertyValue("--safe-area-bottom")) || 0
  }

  #showMenuPopover() {
    if (this.menuTarget.getAttribute("popover") === null || typeof this.menuTarget.showPopover !== "function") return

    try {
      this.menuTarget.showPopover()
    } catch {
      // The fixed-position fallback remains usable in browsers without a
      // working manual popover implementation.
    }
  }

  #hideMenuPopover() {
    if (typeof this.menuTarget.hidePopover !== "function") return

    try {
      if (this.menuTarget.matches(":popover-open")) this.menuTarget.hidePopover()
    } catch {
      // The hidden attribute below still closes the fixed-position fallback.
    }
  }

  #reposition() {
    this.#positionMenu()
  }

  #focusMenuItem(item) {
    if (!item) return
    this.#menuItems().forEach(menuItem => menuItem.tabIndex = menuItem === item ? 0 : -1)
    item.focus({ preventScroll: true })
  }

  #menuItems() {
    return Array.from(this.menuTarget.querySelectorAll(FOCUSABLE_SELECTOR)).filter(item => {
      return !item.hidden && item.getAttribute("aria-disabled") !== "true" && this.#isVisible(item)
    })
  }

  #isVisible(item) {
    if (item.getClientRects().length > 0) return true
    return window.getComputedStyle(item).display !== "none"
  }

  // Metadata and actions

  async #loadMetadata() {
    if (!this.metadataUrlValue || this.#metadataRequest) return

    this.#metadataRequest = new AbortController()
    try {
      const response = await fetch(this.metadataUrlValue, {
        headers: { Accept: "application/json" },
        cache: "no-store",
        signal: this.#metadataRequest.signal,
      })
      if (!response.ok || !this.#connected) return

      const payload = await response.json()
      if (this.#connected) this.#applyMetadata(payload)
    } catch (error) {
      if (error.name !== "AbortError") this.#announce("Message actions are temporarily unavailable")
    } finally {
      this.#metadataRequest = null
    }
  }

  #applyMetadata(payload) {
    this.#metadata = payload.actions || payload.message || payload
    const metadata = this.#metadata || {}

    this.#setActionAvailability(".message__edit-action", this.#boolean(metadata, "can_edit", "canEdit", "editable"))
    this.#setActionAvailability(".message__delete-action", this.#boolean(metadata, "can_delete", "canDelete", "deletable"))

    const source = this.#stringFromMetadata("edit_source", "editable_markdown_source", "editableMarkdownSource", "markdown_source")
    if (source !== null) this.#message.dataset.editSource = source

    const editFormat = this.#stringFromMetadata("edit_format", "editable_format", "editableFormat")
    if (editFormat !== null) this.#message.dataset.editFormat = editFormat

    const threadSummary = metadata.thread_summary || metadata.threadSummary
    if (threadSummary && this.hasThreadLabelTarget) {
      this.threadLabelTarget.textContent = this.#threadCount(threadSummary) > 0 ? "View thread" : "Create thread"
    }

    const reactions = metadata.reactions
    if (reactions && typeof reactions === "object") {
      this.itemTargets.filter(item => item.dataset.reaction).forEach(item => {
        const state = reactions[item.dataset.reaction]
        const active = typeof state === "object" ? state.active : state
        if (active === undefined) return
        item.setAttribute("aria-pressed", String(Boolean(active)))
        item.toggleAttribute("data-reaction-active", Boolean(active))
      })
    }

    this.#positionMenu()
  }

  #setActionAvailability(selector, allowed) {
    const action = this.menuTarget.querySelector(selector)
    if (!action || allowed === undefined) return
    action.hidden = !allowed
    action.setAttribute("aria-hidden", String(!allowed))
  }

  #boolean(metadata, ...keys) {
    for (const key of keys) {
      if (metadata[key] !== undefined && metadata[key] !== null) return Boolean(metadata[key])
    }
    return undefined
  }

  #stringFromMetadata(...keys) {
    const metadata = this.#metadata || {}
    for (const key of keys) {
      if (metadata[key] !== undefined && metadata[key] !== null) return String(metadata[key])
    }
    return null
  }

  #threadCount(summary) {
    if (typeof summary === "number") return summary
    return Number(summary.count || summary.message_count || summary.messageCount || 0)
  }

  #dispatchMessageEvent(name, extra = {}) {
    window.dispatchEvent(new CustomEvent(name, {
      detail: {
        ...this.#messageDetails(),
        ...extra,
      },
    }))
  }

  #messageDetails() {
    const body = this.#message.querySelector("[data-reply-target='body']")
    const author = this.#message.querySelector("[data-reply-target='author']")?.textContent.trim() || ""
    const source = this.#stringFromMetadata("edit_source", "editable_markdown_source", "editableMarkdownSource", "markdown_source")

    return {
      message: this.#message,
      messageId: this.#message.dataset.messageId,
      roomId: this.#message.dataset.roomId || document.querySelector("meta[name='current-room-id']")?.content,
      threadId: this.#message.dataset.threadId || "",
      author,
      url: this.permalinkUrlValue || this.messageUrlValue,
      messageUrl: this.messageUrlValue,
      source: source || this.#message.dataset.editSource || body?.dataset.messageEditSource || null,
      sourceFormat: this.#stringFromMetadata("edit_format", "editable_format", "editableFormat") || this.#message.dataset.editFormat || body?.dataset.messageEditFormat || "markdown",
      previewText: this.#fallbackText(body),
    }
  }

  #fallbackText(body) {
    if (!body) return ""
    const clone = body.cloneNode(true)
    clone.querySelectorAll(".markdown-code-copy, .message__reply-preview, .boosts").forEach(node => node.remove())
    return (clone.innerText || clone.textContent || "").trim()
  }

  #copyTextContent() {
    const metadataText = this.#stringFromMetadata("copy_text", "copyText")
    return metadataText ?? this.#messageDetails().previewText
  }

  async #copy(text, successMessage) {
    try {
      await navigator.clipboard.writeText(text)
      this.#announce(successMessage)
    } catch {
      this.#announce("Copy failed")
    }
    this.#closeMenu({ restoreFocus: false })
  }

  #announce(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    clearTimeout(this.#announceTimer)
    this.#announceTimer = setTimeout(() => this.statusTarget.textContent = "", 2_000)
  }

  #isInteractive(target) {
    return Boolean(target?.closest("a, button, input, textarea, select, option, [contenteditable='true'], [data-no-message-menu]") || this.menuTarget.contains(target))
  }

  #cancelLongPress() {
    clearTimeout(this.#longPressTimer)
    this.#longPressTimer = null
    this.#longPressPointer = null
    this.#longPressTriggered = false
  }
}
