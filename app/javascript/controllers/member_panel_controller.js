import { Controller } from "@hotwired/stimulus"

const DESKTOP_QUERY = "(min-width: 80rem)"
const REFRESH_INTERVAL = 12 * 1000
const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "summary",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",")

export default class extends Controller {
  static targets = [ "panel", "backdrop", "close", "content", "status", "summary", "toggle", "toggleCount" ]

  connect() {
    this.desktopQuery = window.matchMedia(DESKTOP_QUERY)
    this.handleViewportChange = this.#handleViewportChange.bind(this)
    this.handleVisibilityChange = this.#handleVisibilityChange.bind(this)
    this.desktopQuery.addEventListener("change", this.handleViewportChange)
    document.addEventListener("visibilitychange", this.handleVisibilityChange)
    this.desktopClosed = false
    this.isOpen = false

    if (this.hasPanelTarget && this.desktopQuery.matches) {
      this.#open({ focusPanel: false, announce: false })
    } else {
      this.#syncAccessibility()
    }
  }

  disconnect() {
    this.desktopQuery?.removeEventListener("change", this.handleViewportChange)
    document.removeEventListener("visibilitychange", this.handleVisibilityChange)
    this.#stopRefreshing()
    this.#abortRequest()
    this.element.classList.remove("member-panel-open")
  }

  toggle(event) {
    event.preventDefault()

    if (this.isOpen) {
      if (this.desktopQuery.matches) this.desktopClosed = true
      this.#close({ restoreFocus: false })
    } else {
      if (this.desktopQuery.matches) this.desktopClosed = false
      this.#open({ focusPanel: !this.desktopQuery.matches })
    }
  }

  close(event) {
    if (!this.isOpen) return
    if (event?.type === "keydown" && this.desktopQuery.matches) return

    event?.preventDefault()
    this.#close({ restoreFocus: true })
  }

  prepareForCache() {
    this.#stopRefreshing()
    this.#abortRequest()
    this.#close({ restoreFocus: false })
    this.#clearMembers("Open the member list to load members.")
  }

  roomChanged() {
    if (!this.hasPanelTarget) return

    const nextUrl = this.panelTarget.dataset.membersUrl
    if (nextUrl === this.loadedUrl && this.contentTarget.childElementCount > 0) return

    this.#abortRequest()
    this.loadedUrl = null
    this.#clearMembers("Loading members…")
    if (this.isOpen) this.#fetchMembers()
  }

  refreshPresence() {
    if (!this.isOpen) return

    this.#abortRequest()
    this.#fetchMembers()
  }

  trapFocus(event) {
    if (event.key !== "Tab") return
    if (!this.isOpen || this.desktopQuery.matches || !this.hasPanelTarget) return

    const focusable = this.#focusableElements()
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (!this.panelTarget.contains(document.activeElement)) {
      event.preventDefault()
      const focusTarget = event.shiftKey ? last : first
      focusTarget.focus()
      return
    }

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  #open({ focusPanel = false, announce = true } = {}) {
    if (!this.hasPanelTarget) return

    if (announce) window.dispatchEvent(new CustomEvent("member-panel:opening"))
    this.previouslyFocusedElement = document.activeElement
    this.isOpen = true
    this.element.classList.add("member-panel-open")
    this.#syncAccessibility()
    this.#fetchMembers()
    this.#startRefreshing()

    if (focusPanel) requestAnimationFrame(() => this.closeTarget?.focus())
  }

  #close({ restoreFocus }) {
    this.isOpen = false
    this.element.classList.remove("member-panel-open")
    this.#stopRefreshing()
    this.#abortRequest()
    this.#syncAccessibility()

    if (restoreFocus) this.#restoreFocus()
  }

  #syncAccessibility() {
    const open = this.hasPanelTarget && this.isOpen

    this.toggleTargets.forEach((toggle) => {
      toggle.setAttribute("aria-expanded", String(open))
      toggle.setAttribute("aria-label", open ? "Hide members" : "Show members")
      toggle.title = open ? "Hide members" : "Show members"
    })

    if (!this.hasPanelTarget) return

    this.panelTarget.toggleAttribute("inert", !open)
    this.panelTarget.setAttribute("aria-hidden", String(!open))
    this.panelTarget.setAttribute("aria-busy", String(Boolean(this.loading && open)))

    const modal = open && !this.desktopQuery.matches
    if (modal) {
      this.panelTarget.setAttribute("role", "dialog")
      this.panelTarget.setAttribute("aria-modal", "true")
    } else {
      this.panelTarget.removeAttribute("role")
      this.panelTarget.removeAttribute("aria-modal")
    }

    if (this.hasBackdropTarget) this.backdropTarget.hidden = !modal
  }

  async #fetchMembers() {
    if (!this.isOpen || !this.hasPanelTarget || this.loading || document.visibilityState !== "visible") return

    const url = this.panelTarget.dataset.membersUrl
    if (!url) {
      this.#clearMembers("Members unavailable.")
      return
    }

    if (this.contentTarget.childElementCount === 0) this.#clearMembers("Loading members…")
    this.#abortRequest()
    const request = new AbortController()
    this.request = request
    this.loading = true
    this.#syncAccessibility()

    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: request.signal
      })

      if (!response.ok) throw new Error(`Unable to load members (${response.status})`)
      const payload = await response.json()
      if (!Array.isArray(payload.members)) throw new Error("Invalid member response")
      if (request !== this.request || url !== this.panelTarget.dataset.membersUrl) return

      const members = payload.members.filter((member) => {
        return (typeof member.id === "number" || typeof member.id === "string") &&
          typeof member.name === "string" && member.name.trim().length > 0
      })

      this.loadedUrl = url
      this.#renderMembers(members)
    } catch (error) {
      if (error.name !== "AbortError" && request === this.request) {
        this.loadedUrl = null
        this.#clearMembers("Members unavailable.")
      }
    } finally {
      if (request === this.request) {
        this.request = null
        this.loading = false
        this.#syncAccessibility()
      }
    }
  }

  #renderMembers(members) {
    const online = members.filter((member) => member.online === true)
    const offline = members.filter((member) => member.online !== true)
    const currentOfflineGroup = this.contentTarget.querySelector(".member-panel__offline")
    const offlineWasOpen = currentOfflineGroup?.open ?? true
    const offlineSummaryHadFocus = currentOfflineGroup?.querySelector("summary") === document.activeElement
    const fragment = document.createDocumentFragment()

    fragment.append(this.#memberGroup("Online", online, false))

    const offlineGroup = this.#memberGroup("Offline", offline, true)
    offlineGroup.open = offlineWasOpen
    fragment.append(offlineGroup)

    this.contentTarget.replaceChildren(fragment)
    if (offlineSummaryHadFocus) offlineGroup.querySelector("summary")?.focus()
    this.statusTarget.textContent = members.length === 0 ? "No members in this channel." : ""
    this.summaryTarget.textContent = `${members.length} ${members.length === 1 ? "member" : "members"}`
    this.toggleCountTargets.forEach((target) => { target.textContent = String(members.length) })
  }

  #memberGroup(label, members, collapsible) {
    const group = document.createElement(collapsible ? "details" : "section")
    group.className = `member-panel__group${collapsible ? " member-panel__offline" : ""}`

    const heading = document.createElement(collapsible ? "summary" : "h3")
    heading.className = "member-panel__group-heading"
    heading.textContent = `${label} — ${members.length}`
    group.append(heading)

    const list = document.createElement("ul")
    list.className = "member-panel__list"
    list.setAttribute("aria-label", `${label} members`)
    members.forEach((member) => list.append(this.#memberRow(member)))
    group.append(list)
    return group
  }

  #memberRow(member) {
    const online = member.online === true
    const item = document.createElement("li")
    item.className = "member-panel__member"
    item.dataset.memberId = String(member.id)
    item.dataset.online = String(online)

    const avatar = document.createElement("span")
    avatar.className = "avatar member-panel__avatar"
    const image = document.createElement("img")
    image.src = member.avatar_url || this.panelTarget.dataset.defaultAvatarUrl
    image.alt = ""
    image.setAttribute("aria-hidden", "true")
    avatar.append(image)

    const dot = document.createElement("span")
    dot.className = "member-panel__presence"
    dot.setAttribute("aria-label", online ? "Online" : "Offline")
    avatar.append(dot)

    const identity = document.createElement("span")
    identity.className = "member-panel__identity"
    const name = document.createElement("strong")
    name.className = "overflow-ellipsis"
    name.textContent = member.name
    const status = document.createElement("span")
    status.className = "member-panel__status-label"
    status.textContent = online ? "Online" : "Offline"
    identity.append(name, status)

    item.append(avatar, identity)
    return item
  }

  #clearMembers(message) {
    if (this.hasContentTarget) this.contentTarget.replaceChildren()
    if (this.hasStatusTarget) this.statusTarget.textContent = message
    if (this.hasSummaryTarget) this.summaryTarget.textContent = message === "Loading members…" ? "Loading…" : "No member data"
    this.toggleCountTargets.forEach((target) => { target.textContent = "" })
  }

  #startRefreshing() {
    if (!this.isOpen || document.visibilityState !== "visible") return
    this.refreshTimer ??= window.setInterval(() => this.#fetchMembers(), REFRESH_INTERVAL)
  }

  #stopRefreshing() {
    window.clearInterval(this.refreshTimer)
    this.refreshTimer = null
  }

  #abortRequest() {
    this.request?.abort()
    this.request = null
    this.loading = false
  }

  #handleVisibilityChange() {
    if (document.visibilityState === "visible" && this.isOpen) {
      this.#fetchMembers()
      this.#startRefreshing()
    } else {
      this.#stopRefreshing()
      this.#abortRequest()
    }
  }

  #handleViewportChange() {
    if (!this.hasPanelTarget) return

    if (this.desktopQuery.matches && !this.desktopClosed) {
      this.#open({ focusPanel: false, announce: false })
    } else if (!this.desktopQuery.matches) {
      this.#close({ restoreFocus: false })
    } else {
      this.#syncAccessibility()
    }
  }

  #focusableElements() {
    return Array.from(this.panelTarget.querySelectorAll(FOCUSABLE_SELECTOR)).filter((element) => {
      return !element.hidden && element.tabIndex >= 0 && element.getClientRects().length > 0
    })
  }

  #restoreFocus() {
    const previous = this.previouslyFocusedElement
    const previousIsUsable = previous?.isConnected && previous !== document.body && !this.panelTarget.contains(previous)
    const target = previousIsUsable ? previous : this.toggleTargets[0]
    target?.focus()
  }
}
