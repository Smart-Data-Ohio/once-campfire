import { Controller } from "@hotwired/stimulus"

const MOBILE_QUERY = "(max-width: 63.999rem)"
const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",")

export default class extends Controller {
  static targets = [ "sidebar", "opener", "close", "backdrop" ]

  connect() {
    this.mobileQuery = window.matchMedia(MOBILE_QUERY)
    this.handleViewportChange = this.#handleViewportChange.bind(this)
    this.mobileQuery.addEventListener("change", this.handleViewportChange)
    this.#updateAccessibility()
    this.syncCurrentRoom()
  }

  disconnect() {
    this.mobileQuery?.removeEventListener("change", this.handleViewportChange)
    this.element.classList.remove("workspace-navigation-open")
  }

  open() {
    if (!this.mobileQuery.matches || !this.hasSidebarTarget) return

    this.previouslyFocusedElement = document.activeElement
    this.sidebarTarget.classList.add("open")
    this.element.classList.add("workspace-navigation-open")
    this.#updateAccessibility()
    requestAnimationFrame(() => {
      if (this.hasCloseTarget) {
        this.closeTarget.focus()
      } else {
        this.#focusableElements()[0]?.focus()
      }
    })
  }

  close(event) {
    if (!this.hasSidebarTarget || !this.sidebarTarget.classList.contains("open")) return

    event?.preventDefault()
    this.sidebarTarget.classList.remove("open")
    this.element.classList.remove("workspace-navigation-open")
    this.#updateAccessibility()

    const clickedCloseButton = this.hasCloseTarget && event?.currentTarget === this.closeTarget
    const clickedBackdrop = this.hasBackdropTarget && event?.currentTarget === this.backdropTarget

    if (event?.type !== "click" || clickedCloseButton || clickedBackdrop) {
      this.previouslyFocusedElement?.focus()
    }
  }

  navigate(event) {
    const link = event.target.closest("a[href]")
    const staysInSidebarFrame = link?.dataset.turboFrame && link.dataset.turboFrame !== "_top"

    if (link && !staysInSidebarFrame && this.mobileQuery.matches) {
      this.sidebarTarget.classList.remove("open")
      this.element.classList.remove("workspace-navigation-open")
      this.#updateAccessibility()
    }
  }

  trapFocus(event) {
    if (!this.mobileQuery.matches || !this.sidebarTarget.classList.contains("open")) return

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

  syncCurrentRoom() {
    if (!this.hasSidebarTarget) return

    const currentRoomId = document.querySelector('meta[name="current-room-id"]')?.content

    this.sidebarTarget.querySelectorAll("[data-room-id]").forEach((roomLink) => {
      const isCurrent = Boolean(currentRoomId) && roomLink.dataset.roomId === currentRoomId
      roomLink.classList.toggle("room--active", isCurrent)

      if (isCurrent) {
        roomLink.setAttribute("aria-current", "page")
      } else {
        roomLink.removeAttribute("aria-current")
      }
    })

    if (this.mobileQuery.matches && this.sidebarTarget.classList.contains("open") && !this.sidebarTarget.contains(document.activeElement)) {
      this.closeTarget.focus()
    }
  }

  updateUnreadStatus(event) {
    const targetId = String(event.detail.targetId)
    const roomLink = Array.from(this.sidebarTarget.querySelectorAll("[data-room-id]")).find((link) => {
      return link.id === targetId || link.dataset.roomId === targetId
    })

    if (!roomLink) return

    const isUnread = event.type === "rooms-list:unread"
    const currentStatus = roomLink.querySelector(":scope > .sidebar-item__status")

    if (isUnread && !currentStatus) {
      const status = document.createElement("span")
      status.className = "sidebar-item__status"
      status.textContent = "New"
      roomLink.append(status)
    } else if (!isUnread) {
      currentStatus?.remove()
    }
  }

  #handleViewportChange() {
    if (!this.mobileQuery.matches) {
      this.sidebarTarget.classList.remove("open")
      this.element.classList.remove("workspace-navigation-open")
    }

    this.#updateAccessibility()
  }

  #updateAccessibility() {
    if (!this.hasSidebarTarget) return

    const isMobile = this.mobileQuery.matches
    const isOpen = !isMobile || this.sidebarTarget.classList.contains("open")

    this.openerTargets.forEach((opener) => opener.setAttribute("aria-expanded", String(isMobile && isOpen)))
    this.sidebarTarget.toggleAttribute("inert", !isOpen)

    if (isMobile) {
      this.sidebarTarget.setAttribute("aria-hidden", String(!isOpen))
      if (this.hasBackdropTarget) this.backdropTarget.hidden = !isOpen
    } else {
      this.sidebarTarget.removeAttribute("aria-hidden")
      if (this.hasBackdropTarget) this.backdropTarget.hidden = true
    }
  }

  #focusableElements() {
    return Array.from(this.sidebarTarget.querySelectorAll(FOCUSABLE_SELECTOR)).filter((element) => {
      return !element.hidden && element.getClientRects().length > 0
    })
  }
}
