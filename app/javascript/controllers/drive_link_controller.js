import { Controller } from "@hotwired/stimulus"

// Upgrades Drive links in a message body to compact preview chips using the
// viewer's own Google credentials. Mirrors Google::DriveLink; keep the two
// pattern lists and docs/google-drive.md in sync when either changes.
//
// Runs only when the layout carries the google-drive-previews meta tag, so
// members without Drive consent send zero requests. One request per file id
// per page load is shared across all message instances; any non-200 answer
// leaves the anchor untouched.
const FILE_ID = "[A-Za-z0-9_-]{10,}"
const ACCOUNT_PREFIX = "(?:u/\\d+/)?"
const PATTERNS = [
  new RegExp(`^https://docs\\.google\\.com/${ACCOUNT_PREFIX}(?:document|spreadsheets|presentation|forms)/${ACCOUNT_PREFIX}d/(${FILE_ID})`, "i"),
  new RegExp(`^https://drive\\.google\\.com/${ACCOUNT_PREFIX}file/${ACCOUNT_PREFIX}d/(${FILE_ID})`, "i"),
  new RegExp(`^https://drive\\.google\\.com/${ACCOUNT_PREFIX}drive/${ACCOUNT_PREFIX}folders/(${FILE_ID})`, "i"),
  new RegExp(`^https://drive\\.google\\.com/${ACCOUNT_PREFIX}open\\?(?:[^#]*&)?id=(${FILE_ID})(?:&|#|$)`, "i")
]

// fileId -> Promise resolving to the preview JSON, or null when the link
// must stay plain. Module-level so every message on the page shares it.
const previews = new Map()

const ICONS = {
  document: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13"/><path d="M6 8h4M6 10.5h4"/></svg>',
  spreadsheet: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="2.5" width="10" height="11" rx="1"/><path d="M3 6.5h10M3 10h10M8 6.5V13.5"/></svg>',
  presentation: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="3" width="12" height="8.5" rx="1"/><path d="M6 13.5h4M8 11.5v2"/></svg>',
  form: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="2.5" width="10" height="11" rx="1"/><path d="M5.5 8l1.8 1.8 3.2-3.6"/></svg>',
  folder: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M2 5.5A1.5 1.5 0 0 1 3.5 4h3l1.5 2h4.5A1.5 1.5 0 0 1 14 7.5v3a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 10.5z"/></svg>',
  pdf: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13"/><path d="M6 11.5c.5-.8 1.2-1 2-.5l1 1c.8.5 1.5.3 2-.5"/></svg>',
  file: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13"/></svg>'
}

// Shared with the composer drive-picker so its rows reuse the chip artwork.
export const DRIVE_KIND_ICONS = ICONS

export function driveFileId(url) {
  for (const pattern of PATTERNS) {
    const match = String(url).match(pattern)
    if (match) return match[1]
  }
  return null
}

export function relativeModifiedTime(isoString) {
  const then = new Date(isoString).getTime()
  if (Number.isNaN(then)) return null

  const seconds = Math.max(0, Math.floor((Date.now() - then) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? "" : "s"} ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`
  const days = Math.floor(hours / 24)
  if (days < 30) return `${days} day${days === 1 ? "" : "s"} ago`
  return new Date(then).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })
}

function fetchPreview(fileId) {
  let pending = previews.get(fileId)
  if (!pending) {
    pending = fetch(`/google/drive/files/${encodeURIComponent(fileId)}`, {
      headers: { "Accept": "application/json" }
    }).then((response) => {
      if (!response.ok) return null
      return response.json()
    }).then((data) => {
      if (!data || !data.name) return null
      return data
    }).catch(() => null)
    previews.set(fileId, pending)
  }
  return pending
}

function chipElement(data) {
  const chip = document.createElement("span")
  chip.className = `drive-chip drive-chip--${data.kind || "file"}`

  const icon = document.createElement("span")
  icon.className = "drive-chip__icon"
  icon.setAttribute("aria-hidden", "true")
  icon.innerHTML = ICONS[data.kind] || ICONS.file

  const text = document.createElement("span")
  text.className = "drive-chip__text"

  const name = document.createElement("span")
  name.className = "drive-chip__name"
  name.textContent = data.name

  const meta = document.createElement("span")
  meta.className = "drive-chip__meta"
  const modified = data.modified_at ? relativeModifiedTime(data.modified_at) : null
  const parts = []
  if (modified) parts.push(`Modified ${modified}`)
  if (data.owner) parts.push(data.owner)
  meta.textContent = parts.join(" · ")

  text.append(name, meta)
  chip.append(icon, text)
  return chip
}

export default class extends Controller {
  connect() {
    if (!document.querySelector('meta[name="google-drive-previews"][content="enabled"]')) return

    for (const anchor of this.element.querySelectorAll("a[href]")) {
      const fileId = driveFileId(anchor.href)
      if (!fileId || anchor.querySelector(".drive-chip")) continue

      fetchPreview(fileId).then((data) => {
        if (!data || !anchor.isConnected) return
        anchor.textContent = ""
        anchor.appendChild(chipElement(data))
        anchor.classList.add("drive-chip-link")
      })
    }
  }
}
