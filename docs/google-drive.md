# Google Drive link previews

When a message contains a Google Drive, Docs, Sheets, Slides, Forms, or
Drive-folder link, members whose connected Google account can open that file
see the link upgraded to a compact preview chip: a file-type icon, the file
name, "Modified \<relative time\>", and the owner's name. Everyone else,
including members without a connected Google account, sees the ordinary link.

## Who sees a preview and why

Previews are resolved at **view time with the viewer's own Google
credentials**, never at post time and never with the author's account. No file
metadata is stored in the database. When the viewer opens a page, the
`drive-link` Stimulus controller finds Drive anchors in each message body and
asks `GET /google/drive/files/:id`, which calls Drive `files.get` with the
viewer's token. A private document is therefore never revealed to a channel
member who cannot open it: without access, Google answers 403 or 404 and the
link stays plain.

## Consent

Drive previews need the extra OAuth scope
`https://www.googleapis.com/auth/drive.metadata.readonly` (metadata only:
id, name, type, modified time, owners, and links; never file contents). The
[Calendar connection](google-calendar.md) stays calendar-only unless the
member opts in: the profile shows **Enable Drive previews** next to a
connected account, which re-runs the OAuth flow requesting both scopes with
`include_granted_scopes=true`. Google returns the granted scopes as a
space-separated string, stored on `google_accounts.scopes`
(`GoogleAccount#drive?` reads it; existing rows have null, treated as
calendar only). Members without Drive consent send zero preview requests:
the page omits the `google-drive-previews` meta tag and the controller does
nothing. **Disconnect** removes the whole connection, as before.

## Link shapes

`Google::DriveLink.file_id` (Ruby) and `driveFileId`
(`app/javascript/controllers/drive_link_controller.js`) recognize the same
URL shapes; keep the two lists in sync:

- `https://docs.google.com/document/d/<id>/...`
- `https://docs.google.com/spreadsheets/d/<id>/...`
- `https://docs.google.com/presentation/d/<id>/...`
- `https://docs.google.com/forms/d/<id>/...`
- `https://drive.google.com/file/d/<id>/...`
- `https://drive.google.com/open?id=<id>`
- `https://drive.google.com/drive/folders/<id>`

Each shape also matches with a `/u/<n>/` account switcher segment after the
host or after the app path (for example
`https://drive.google.com/drive/u/0/folders/<id>`). Anything else, including
other hosts, a missing id, or a `javascript:` URL, parses to nil and is left
alone. Bare file ids are `[A-Za-z0-9_-]{10,}`.

The endpoint answers 200 with
`{ id, name, kind, modified_at, owner, url }`, where `kind` is one of
`document`, `spreadsheet`, `presentation`, `form`, `folder`, `pdf`, `file`,
derived from the MIME type. The chip renders a small inline SVG per kind; it
never loads Google's `iconLink` image, which would be a third-party request
per chip.

## Finding files from the composer

Members with Drive previews enabled get a **Drive** button in the message
composer toolbar (it renders only when the page carries the
`google-drive-previews` meta tag). The button opens a small popover with a
search field and up to ten matching rows: a file-type icon, the file name,
"Modified \<relative time\>", and the owner's name. The recent list shows
immediately; typing filters by file name. Choosing a row inserts the file's
link at the caret, and the preview chip renders it once the message is
sent. Escape and outside click close the popover; arrow keys move through
results.

The popover talks to `GET /google/drive/files?q=<text>`, which calls Drive
`files.list` with the viewer's token (`pageSize=10`,
`fields=files(id,name,mimeType,modifiedTime,owners(displayName),webViewLink)`,
`orderBy=modifiedTime desc`, `spaces=drive`). A blank `q` lists recent
files (`trashed=false`); otherwise the query is `name contains '<term>'
and trashed=false`, where single quotes and backslashes in the term are
escaped per the Drive query grammar (`\'`, `\\`). `q` is trimmed and
capped at 100 characters. The response shape (`{ files: [ { id, name,
kind, modified_at, owner, url } ] }`) and the `kind` derivation match the
preview endpoint. Google failures answer 502 with
`{ error: "drive_unavailable" }`; a revoked grant answers 404 like the
preview endpoint. Results are never stored.

List calls are throttled to 30 per user per minute (a `Rails.cache`
minute-bucketed counter); past that the endpoint answers 429 with
`{ error: "rate_limited" }` and the popover shows "Try again in a moment".

Results are the viewer's own Drive view: nothing is shared until the
member sends the message, and then only the link, which other viewers
resolve with their own credentials as with pasted Drive links.

## Attachments

Members with Drive previews enabled can also **attach** Drive files to a
room or thread message. Every picker row carries an **Attach** button next
to the click-to-insert row: it pins the file as a chip in a strip above the
composer (showing the same name and kind icon the row showed), and sending
the message stores the attachment with it. A message with attachments and
no text is valid. Up to 10 files per message.

Only the file id is stored (`drive_attachments`: `message_id`, `file_id`).
No name, MIME type, owner, or URL is persisted. The attachment renders as a
block under the message body carrying an `open?id=` link, in markup that is
identical for every viewer: a generic file icon, the text "Google Drive
file", and an "Open in Drive" hint. The `drive-link` controller then
upgrades the block with the viewer's own credentials, exactly like a
pasted link: viewers who can open the file see its name, kind icon,
modified time, and owner, while viewers without Drive consent or without
access keep the generic block and learn nothing else. No new endpoints are
involved, and the file name is never logged.

The message's edit form lists the current attachments as removable chips
(the author can drop all of them; only the existing edit permission
applies). Editing in the composer shows the same current attachments as
removable chips in the composer's own strip, and saving sends the edited
set with the same replace semantics, so removal and re-adding work without
leaving the room. Forwarding a message copies its attachment ids onto the
forward, whose block then behaves like any other. Attachment changes touch
the message so caches refresh.

Thread messages accept the same `message[drive_file_ids][]` set as room
messages on create and update — stored, replaced, left alone when absent,
cleared by the blank sentinel, 422 on an invalid id or a scalar — and a
thread edit rebroadcasts the attachments block over the thread stream.

The JSON message shape and the agent delivery payload carry the set as:

```json
"drive_attachments": [
  { "file_id": "1AbcDefGhIjKlMnOpQrSt", "url": "https://drive.google.com/open?id=1AbcDefGhIjKlMnOpQrSt" }
]
```

Never a name: bots receive no Drive credentials. The bot posting API does
not accept attachments.

## Sharing a file with chat members (enhanced picker)

When browser sharing is configured (see [Setup](#setup-google-cloud-console)
and the [Workspace setup runbook](google-workspace-setup.md)), the composer
carries a single **Drive** button for every signed-in human member — no
Calendar or metadata consent required — driven by the `drive-share`
Stimulus controller. Choosing a file opens the official Google Picker; a
review dialog then offers two explicit actions: **Attach only**, which pins
the file id exactly like the legacy picker and changes nothing in Drive, or
**Grant view access and attach**, which grants the checked chat recipients
reader access before pinning. When sharing is not configured, the composer
falls back to the legacy metadata picker above, unchanged.

Authorization uses Google Identity Services with **only** the
`https://www.googleapis.com/auth/drive.file` scope and
`include_granted_scopes=false`: the app can touch only files the user opens
or creates with it, never the whole Drive, and it never requests or uses
the separate `drive.metadata.readonly` grant. The access token lives in JS
memory alone.
It is never written to the DOM, hidden fields, Turbo snapshots, storage,
logs, or the server, and it is dropped on Turbo cache, navigation, and
controller disconnect. The official GIS and Picker scripts load lazily,
only after the member presses the Drive button. The server-side
Calendar/metadata connection is separate and untouched: stored refresh and
access tokens are never rendered into the browser.

The browser calls Drive REST directly with the token in an `Authorization`
header:

- `files.get` reads `id,name,mimeType,capabilities(canShare)` with
  `supportsAllDrives=true`. Folders and shortcuts can be attached but are
  never offered for sharing, and a file without `canShare` keeps
  attach-only with an explanation of the manual Drive steps.
- `permissions.list` reads **all** pages before granting. Any direct,
  non-deleted user permission — reader, commenter, writer, owner, or
  organizer — already counts as sufficient, so existing writers and owners
  are preserved and duplicate grants are never issued.
- `permissions.create` grants missing recipients one at a time (Google does
  not support concurrent permission writes on one file) with
  `{ role: "reader", type: "user", emailAddress }`,
  `sendNotificationEmail=false`, and `supportsAllDrives=true`. Reader
  access only: never editor, public, domain, `anyone`, ownership transfer,
  or revocation of existing access.

The attached URL is always rebuilt from the validated file id
(`https://drive.google.com/open?id=<id>`); Picker-supplied URLs are never
trusted, and file metadata is inserted via `textContent`. One file per
selection, repeatable to the usual 10 attachments, with the same
dedup/limit/clear semantics as the legacy picker. Selection, cancellation,
attach-only, and message forwarding never mutate permissions.

The dialog lists eligible **current** chat recipients by name and email,
unchecked by default with a select-all, served by two room-scoped JSON
endpoints that both require an active membership (the same audience that
can post):

- `GET /rooms/:room_id/drive_recipients` previews the snapshot: active
  human members other than the requester, with a usable email address,
  across every login method and domain. Bots, agent-backed users,
  deactivated/banned members, and blank or malformed emails are excluded.
- `POST /rooms/:room_id/drive_recipients/validate` re-checks the explicit
  user-id selection immediately before any Google call. Any stale,
  removed, or unauthorized id rejects the whole selection with 422, and
  the dialog refreshes its list. Approval covers both the member id and
  the displayed email: if a canonical email changed since the review, or
  membership changed while a retry or reconnect was pending, the dialog
  returns to a fresh explicit review and nothing is auto-granted. Only
  user ids from member records are accepted — never arbitrary emails —
  bounded at 100, throttled at 60 requests per user per minute, and the
  POST carries the usual CSRF token.
  Responses are `no-store`; nonmembers learn nothing (404), and signed-out
  JSON callers get 401.

Grants are a deliberately approved snapshot, stated in the dialog: access
grants happen immediately and remain even if the message is never sent or
a recipient later leaves; future members are not added. Partial failures
report per-recipient success and failure honestly, never claiming success
when Google denied, and retry covers only the outstanding recipients after
re-reading the permission list. If the Google session expires mid-grant, a
fresh explicit Reconnect gesture continues the already-approved set; if an
organization blocks cross-org sharing, the dialog explains the manual
Drive steps. Thread composers grant against the parent room's membership.

Local tests stub Google throughout and cannot establish live OAuth or
organization-policy readiness. Rollout checks — one user per Workspace
organization, a password-login member, cancelled consent, rejected
cross-domain sharing, attach-only, explicit grant, preserved editor,
partial failure, and mobile recovery — are listed in the
[Workspace setup runbook](google-workspace-setup.md).

## The 404 policy

The endpoint answers **404 with an empty body** in every denial case: the
viewer has no Google account, the account is disconnected, the account lacks
the Drive scope, Google answers 403 or 404, or the file id is malformed. One
response shape for all denials, so the endpoint never reveals that a file
exists. Google transport failures answer 503. The file name is never logged.

## Caching

The only persistence is a short `Rails.cache` entry (5 minutes) keyed by the
viewer's user id and the file id, so one member's cached metadata is never
served to another. The browser additionally shares one in-memory request per
file id per page load, so twenty messages linking the same document make one
request.

## Setup (Google Cloud Console)

On the same OAuth client used for Calendar (see
[Google Calendar publishing](google-calendar.md)):

1. Enable the **Google Drive API** on the project.
2. No redirect or credential change is needed; the Drive scope is requested
   through the existing connect flow.

When `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET` is missing, the profile
shows nothing new and the endpoint answers 404.

The enhanced share picker additionally needs, on the same project and OAuth
web client (full checklist in the
[Workspace setup runbook](google-workspace-setup.md)):

1. Enable the **Google Picker API** (`picker.googleapis.com`).
2. Register the app's **authorized JavaScript origin** (scheme + host, no
   path) on the OAuth client.
3. Create a browser API key restricted to the Picker API and the
   app's HTTPS referrer (plus `https://docs.google.com/*`, which hosts the
   Picker iframe), and configure the host with `GOOGLE_PICKER_API_KEY` and
   `GOOGLE_CLOUD_PROJECT_NUMBER` alongside the existing `GOOGLE_CLIENT_ID`.
   The key authorizes Picker loading only; Drive REST calls authenticate
   with the OAuth Bearer token, not the key.

All three values must be present for the enhanced button; otherwise the
composer keeps the legacy metadata picker for members with Drive consent,
and the recipients endpoints answer 404.
