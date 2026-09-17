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
