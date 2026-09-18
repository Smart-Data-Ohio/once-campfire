import { DRIVE_KIND_ICONS } from "controllers/drive_link_controller"

// Shared Drive-attachment helpers for the enhanced share picker. The
// legacy picker keeps its own private chip builder untouched; this module
// produces identical markup (hidden message[drive_file_ids][] input,
// kind icon, name, element-removal button) so chips from either picker
// submit, edit, and clear exactly the same way.
export const MAX_DRIVE_ATTACHMENTS_PER_MESSAGE = 10

const FILE_ID_PATTERN = /^[A-Za-z0-9_-]{10,}$/

const KINDS_BY_MIME_TYPE = {
  "application/vnd.google-apps.document": "document",
  "application/vnd.google-apps.spreadsheet": "spreadsheet",
  "application/vnd.google-apps.presentation": "presentation",
  "application/vnd.google-apps.form": "form",
  "application/vnd.google-apps.folder": "folder",
  "application/pdf": "pdf"
}

// True for a bare Drive file id (letters, digits, _ and -, 10+ chars).
// Mirrors Google::DriveLink.valid_id?.
export function validDriveFileId(id) {
  return FILE_ID_PATTERN.test(String(id || ""))
}

// The one Drive URL shape attachments use. Built only from a validated
// id; Picker-supplied URLs are never trusted.
export function canonicalDriveFileUrl(fileId) {
  return `https://drive.google.com/open?id=${fileId}`
}

// Mirrors the kind derivation in Google::DriveFilesController.
export function driveKindFromMimeType(mimeType) {
  return KINDS_BY_MIME_TYPE[String(mimeType || "")] || "file"
}

export function pinnedDriveFileIds(strip) {
  if (!strip) return []
  return Array.from(strip.querySelectorAll('input[name="message[drive_file_ids][]"]'))
    .map((input) => input.value)
    .filter((value) => value.trim() !== "")
}

// Pins the file as a pending chip in the composer's strip. Returns
// "pinned", "duplicate" (already pinned: a silent no-op like the legacy
// picker), "full" (10 already pinned), or "no-strip".
export function pinDriveAttachment(strip, file) {
  if (!strip || !validDriveFileId(file?.id)) return "no-strip"

  if (strip.querySelector(`input[name="message[drive_file_ids][]"][value="${CSS.escape(file.id)}"]`)) {
    return "duplicate"
  }

  if (pinnedDriveFileIds(strip).length >= MAX_DRIVE_ATTACHMENTS_PER_MESSAGE) {
    return "full"
  }

  strip.append(driveAttachmentChip(file))
  return "pinned"
}

export function driveAttachmentChip(file) {
  const chip = document.createElement("span")
  chip.className = "drive-attachment-chip"
  chip.dataset.controller = "element-removal"

  const input = document.createElement("input")
  input.type = "hidden"
  input.name = "message[drive_file_ids][]"
  input.value = file.id

  const icon = document.createElement("span")
  icon.className = "drive-attachment-chip__icon"
  icon.setAttribute("aria-hidden", "true")
  icon.innerHTML = DRIVE_KIND_ICONS[file.kind] || DRIVE_KIND_ICONS.file

  const name = document.createElement("span")
  name.className = "drive-attachment-chip__name"
  name.textContent = file.name || "Untitled"

  const remove = document.createElement("button")
  remove.type = "button"
  remove.className = "drive-attachment-chip__remove"
  remove.setAttribute("aria-label", `Remove ${file.name || "Untitled"}`)
  remove.dataset.action = "element-removal#remove"
  remove.textContent = "×"

  chip.append(input, icon, name, remove)
  return chip
}
