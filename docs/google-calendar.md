# Google Calendar publishing

Members can connect their Google account from their profile. Once connected,
every [native event](events.md) they are **going** or **maybe** to appears
on their primary Google Calendar as a private copy. Publishing is one way,
Campfire to Google: edits made in Google are never read back, and the app
never reads the calendar, free/busy data, or attendees.

A later time change (or title/description edit) updates that same calendar
entry; declining, cancelling, or leaving the room removes it. The event page
shows "Added to your Google Calendar" while a copy exists for the viewer.

## Setup (Google Cloud Console)

1. Create (or reuse) a project and configure an **OAuth client** of type
   **Web application**.
2. Add an authorized redirect URI: `<app root URL>/google/callback`
   (for example `https://campfire.example.com/google/callback`).
3. No extra APIs to enable beyond Google Calendar; the app requests exactly
   one scope: `https://www.googleapis.com/auth/calendar.events`.
4. Set the client credentials on the app host:
   `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.

When either variable is missing, the profile shows "Google Calendar is not
configured for this workspace" and the connect routes answer 404.

## What is published and when

Connecting is the explicit opt-in: nothing is published for members who
have not connected. Each published entry carries the event title, the
description plus a "From Campfire" link back to the event, the start/end
in the event's time zone (events without an end default to one hour), and
Google's default reminders. No Google attendees are added.

Publishing is reconciled by `Calendar::SyncEntryJob`, which recomputes the
desired state from the database on every run: an entry exists exactly when
the member is connected, is going or maybe, the event is not cancelled,
and the member is still in the room. The job is enqueued when an RSVP is
created or changes, when an event's time, title, or description changes,
when an event is cancelled, when an account is connected (all upcoming
going/maybe RSVPs), and when a membership ends.

There is no delayed-job scheduler in this deployment, so failures are not
retried on a timer: a failure is recorded on the entry and the next change
retries. A retried insert reuses the same Google event id, so it cannot
create a duplicate. If Google reports the account's grant revoked
(`invalid_grant`), the account is marked disconnected and the profile
offers a reconnect instead of publishing.

## Disconnecting

**Disconnect** on the profile removes the connection and every calendar
entry the app created for that member, best effort: entries Google refuses
to remove are logged and forgotten. Deleting a room destroys its local
entry rows; copies already in Google Calendar are left for the member to
remove.

## Token storage

Refresh and access tokens are stored encrypted (`encrypts` on
`GoogleAccount`) with keys derived from `SECRET_KEY_BASE` (see
`config/initializers/active_record_encryption.rb`), so no separate secret
is needed. Rotating `SECRET_KEY_BASE` invalidates every stored Google
token: affected members must reconnect. Tokens are never logged or
rendered.
