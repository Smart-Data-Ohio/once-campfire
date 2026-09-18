// Browser-side Google Drive REST client for the enhanced share picker.
// Calls Drive directly with the ephemeral Identity Services token held in
// JS memory; the token is never written to the DOM, storage, or logs, and
// this module emits no console output at all.
//
// Reads the selected file's sharing capability and permission list, and
// grants individual reader access. Only "reader" is ever granted, with
// email notifications off. Concurrent permission writes on one file are
// not supported by Google, so callers must create permissions
// sequentially.
const DRIVE_API_BASE = "https://www.googleapis.com/drive/v3"

export class DriveShareError extends Error {
  // kind: "unauthorized" (401: token expired or revoked, needs a fresh
  // explicit Google auth gesture), "denied" (Google refused: 403 or an
  // unexpected failure), "not_found", "rate_limited", "unavailable"
  // (Google 5xx: transient service failure), "network" (transport
  // failure), or "aborted" (caller cancelled).
  constructor(kind, { status = null, reason = null } = {}) {
    super(`Drive request ${kind}`)
    this.name = "DriveShareError"
    this.kind = kind
    this.status = status
    this.reason = reason
  }
}

export class DriveShareClient {
  constructor({ token, fetchFn = null } = {}) {
    this.token = token
    // Resolved lazily so test doubles installed on window.fetch apply.
    this.fetchFn = fetchFn || ((...args) => fetch(...args))
  }

  // Authoritative metadata for a picked file: id, name, MIME type, and
  // whether the current user may share it.
  async getFile(fileId, { signal = null } = {}) {
    const params = new URLSearchParams({
      fields: "id,name,mimeType,capabilities(canShare)",
      supportsAllDrives: "true"
    })
    return this.#parse(await this.#send(
      `${DRIVE_API_BASE}/files/${encodeURIComponent(fileId)}?${params}`, { signal }
    ))
  }

  // Every direct permission on the file, across all pages, so grant
  // decisions never downgrade or duplicate an existing grant.
  async listPermissions(fileId, { signal = null } = {}) {
    const permissions = []
    let pageToken = null

    do {
      const params = new URLSearchParams({
        fields: "permissions(id,type,role,emailAddress,deleted),nextPageToken",
        pageSize: "100",
        supportsAllDrives: "true"
      })
      if (pageToken) params.set("pageToken", pageToken)

      const data = await this.#parse(await this.#send(
        `${DRIVE_API_BASE}/files/${encodeURIComponent(fileId)}/permissions?${params}`, { signal }
      ))
      permissions.push(...(data.permissions || []))
      pageToken = data.nextPageToken || null
    } while (pageToken)

    return permissions
  }

  // Grants one user reader access. Never notifies by email.
  async createReaderPermission(fileId, email, { signal = null } = {}) {
    const params = new URLSearchParams({
      supportsAllDrives: "true",
      sendNotificationEmail: "false"
    })
    return this.#parse(await this.#send(
      `${DRIVE_API_BASE}/files/${encodeURIComponent(fileId)}/permissions?${params}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ role: "reader", type: "user", emailAddress: email }),
        signal
      }
    ))
  }

  // True when the address already holds any direct, non-deleted user
  // permission. Every direct role (reader, commenter, writer, owner,
  // organizer, ...) counts as sufficient, so existing writers and owners
  // are never touched and duplicate grants are never issued.
  static alreadyHasAccess(permissions, email) {
    const wanted = String(email || "").toLowerCase()
    if (!wanted) return false

    return (permissions || []).some((permission) =>
      permission?.type === "user" &&
      !permission.deleted &&
      String(permission.emailAddress || "").toLowerCase() === wanted
    )
  }

  async #send(url, options) {
    let response
    try {
      response = await this.fetchFn(url, {
        ...options,
        headers: { ...options.headers, "Authorization": `Bearer ${this.token}` }
      })
    } catch (error) {
      if (error?.name === "AbortError") throw new DriveShareError("aborted")
      throw new DriveShareError("network")
    }

    if (response.ok) return response
    if (response.status === 401) throw new DriveShareError("unauthorized", { status: 401 })
    if (response.status === 404) throw new DriveShareError("not_found", { status: 404 })
    if (response.status === 429) throw new DriveShareError("rate_limited", { status: 429 })
    if (response.status >= 500) {
      throw new DriveShareError("unavailable", { status: response.status, reason: await readErrorReason(response) })
    }
    if (response.status === 403) {
      throw new DriveShareError("denied", { status: 403, reason: await readErrorReason(response) })
    }
    throw new DriveShareError("denied", { status: response.status, reason: await readErrorReason(response) })
  }

  async #parse(response) {
    try {
      return await response.json()
    } catch {
      throw new DriveShareError("network")
    }
  }
}

// Best-effort first error reason (for example a domain-policy refusal).
// Never throws; callers use it only to pick a help message.
async function readErrorReason(response) {
  try {
    const data = await response.clone().json()
    return data?.error?.errors?.[0]?.reason || null
  } catch {
    return null
  }
}
