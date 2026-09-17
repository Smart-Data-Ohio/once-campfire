import { Controller } from "@hotwired/stimulus"

// Drops live board rows that fall outside the index's active filters. Rows
// render with their status, owner, and tags as data attributes while the
// list (or columns) container carries the active filter values; a broadcast
// row for a post the viewer filtered out is removed instead of shown.
// Server renders already match, so only observed additions are checked.
export default class extends Controller {
  static values = {
    status: String,
    owner: String,
    tag: String,
    currentUserId: String
  }

  connect() {
    this.observer = new MutationObserver((mutations) => this.filterAddedRows(mutations))
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  filterAddedRows(mutations) {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue

        if (node.hasAttribute("data-board-row")) {
          this.filterRow(node)
        } else {
          node.querySelectorAll("[data-board-row]").forEach((row) => this.filterRow(row))
        }
      }
    }
  }

  filterRow(row) {
    if (!this.rowMatches(row)) row.remove()
  }

  rowMatches(row) {
    return this.statusMatches(row.dataset.status) &&
      this.ownerMatches(row) &&
      this.tagMatches(row.dataset.tags)
  }

  // The list filters by open/done/all over work statuses; the columns view
  // always carries "all".
  statusMatches(status) {
    if (this.statusValue === "done") return status === "done"
    if (this.statusValue === "open") return status !== "done"
    return true
  }

  ownerMatches(row) {
    const ownerId = row.dataset.ownerId || ""

    switch (this.ownerValue) {
      case "me":
        return ownerId !== "" && ownerId === this.currentUserIdValue
      case "agents":
        return row.dataset.ownerAgent === "true"
      case "anyone":
      case "":
        return true
      default:
        return ownerId === this.ownerValue
    }
  }

  tagMatches(tags) {
    if (!this.tagValue) return true
    return (tags || "").split(" ").includes(this.tagValue)
  }
}
