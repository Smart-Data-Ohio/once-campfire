# Native events

Members can schedule an event inside a channel or DM. The other members are invited through the activity inbox, respond going, maybe, or declined, and get a reminder shortly before the event starts. Cancellation and time changes reach attendees without duplicate inbox items.

## Scheduling an event

1. Open a channel or DM and choose **Events** in the header.
2. Choose **New event** and fill in a title, an optional description, and a start and optional end time.
3. Choose **Schedule event**.

The start and end times are interpreted in the organizer's browser time zone and stored with that zone. Attendees see the times converted to their own zone; the event page also shows the zone abbreviation. Any active human room member can schedule an event. Bots cannot create events.

The organizer is recorded as **going**. Every other active human room member receives an **Event invitation** inbox item linking to the event page.

## Responding

On the event page, choose **Going**, **Maybe**, or **Declined**. The current response and the attendee list are visible to every room member. Only current room members can respond: a member who is removed from the room can no longer see or respond to the event, and the event's inbox items disappear from their inbox.

## In the channel

Scheduling an event posts an announcement message in the room ("Scheduled an event: \<title\>" plus a link to the event page), so the conversation itself shows what was scheduled. Edits and cancellations post nothing further; the card below carries them, and the announcement creates no inbox items of its own.

Any message linking to an event — the announcement or a pasted event URL — renders an event card beneath it: the kind ("Event" or "Repeating event"), the title linking to the event page, the start and end times, the venue name when set, and the organizer. Cancelled events show a Cancelled state. The card refreshes live when the event changes.

The card carries a response section with your current response and the going/maybe counts, plus **Going**, **Maybe**, and **Declined** buttons that answer in place without leaving the room. On a repeating event the card also offers **Apply to all future occurrences**.

Cards respect room membership. A member of the room the link was posted in who is not a member of the event's room sees the plain link and no card — the event's title and details never reach them through the room.

A repeating series announces once, for its first event; the later occurrences post nothing.

## Editing and cancelling

Only the organizer or an administrator can edit or cancel an event, from the **Edit** and **Cancel event** controls on the event page.

- Editing the title or description is silent.
- Changing the start, end, or time zone sends an **Event update** inbox item to every going or maybe attendee except the person who made the change, replacing their earlier unhandled item for the event. The reminder is re-armed.
- Cancelling sends an **Event cancelled** item to every going or maybe attendee except the person who cancelled, and clears every other unhandled item for the event. Cancelling twice changes nothing.
- Cancelled events cannot be edited and no longer accept responses.

## Reminders

Fifteen minutes before the start, every going or maybe attendee (the organizer included) receives an **Event reminder** inbox item and a Web Push notification. Events starting more than an hour ago are never reminded. Because this deployment has no delayed-job scheduler, a small loop process polls for due reminders:

- `Event::ReminderDispatcher.dispatch_due!` finds unreminded, uncancelled events starting within the next 15 minutes (and no more than 60 minutes in the past), records one reminder item per going or maybe attendee, stamps `reminded_at`, and enqueues `Event::ReminderPushJob`, which delivers the push notification through `Event::ReminderPusher`.
- `bin/event-reminders` runs the dispatcher every 30 seconds (`EVENT_REMINDERS_INTERVAL` overrides the interval) and is started by the `event_reminders` Procfile entry. Per-event failures are logged and do not stop the run.

Deleting a room removes its events, attendances, and their inbox items.

## Recurring events

An organizer can make an event repeat **daily**, **weekly**, **every two weeks**, or **monthly** until a chosen end date. Every occurrence is its own event, so RSVP, reminders, inbox items, and Google Calendar entries behave exactly as they do for single events.

- Scheduling a repeating event creates the first event plus one event per repeat, up to and including the end date, capped at 52 events. Above that the form asks for an earlier end date. The end date must be after the start date and at most one year after it.
- Times repeat on the local wall clock in the event's time zone, so a 10:00 meeting stays at 10:00 across daylight-saving changes. Monthly repeats on the same day of month, falling back to the month's last day when it is short (the 31st becomes February 28th, then March 31st again). Each occurrence keeps the same duration.
- Members get one **Event invitation** for the whole series, attached to the first event and worded "repeats weekly until \<date\>". Later occurrences send no invitation.
- Responding on the first event copies the response to every future occurrence. Responding on a later occurrence changes only that occurrence unless **Apply to all future occurrences** is checked, which copies the response to that occurrence and every later one. Cancelled occurrences are skipped.
- The organizer or an administrator can apply an edit on a series occurrence to **This event** (default) or **This and following**. This and following applies the changed title, description, and times to the occurrence and every later one, shifting their starts and ends by the same offset when the time changed, and sends one **Event update** per attendee for the series, attached to the edited occurrence and replacing earlier unhandled update items for any occurrence. Title-only edits stay silent, as with single events. A re-time keeps its place in the series: it must stay strictly after the previous uncancelled occurrence, and a This event re-time must also stay strictly before the next uncancelled one. The first event's start time anchors the whole series, so changing it alone with This event is rejected — move it with This and following instead.
- Only the organizer or an administrator can change when a series repeats, and only on the first event with This and following. It rebuilds the future occurrences: occurrences where anyone responded differently from the first event keep their responses and move onto the new pattern's slots, and any that do not fit are cancelled with the usual cancellation notice; cancelled occurrences are left alone; the rest are reused in place, moved onto the new pattern, or removed when the series shrank, and added slots start with the first event's responses. Removed occurrences leave their Google Calendar copies behind for the member to delete, as with room deletion.
- The organizer or an administrator can cancel **This event** or **This and following**; cancelling from the first event cancels every occurrence. One **Event cancelled** item per attendee covers the whole scope, attached to the earliest cancelled occurrence, and each occurrence's calendar entry is removed through the usual sync.
- Each occurrence is reminded 15 minutes before its own start, as with single events.
- The event list shows a series once, as its next uncancelled occurrence, with a "Repeats weekly" label and the count of remaining occurrences. Past occurrences appear individually in the past-events view. The event page shows "Part of a series: repeats weekly until \<date\>" with previous/next occurrence links.

## Venue

An event can name a **venue**: the voice or Stage channel where it takes place. The event form's **Where** select lists "No channel" plus the voice and Stage channels the scheduler belongs to. The organizer must belong to the venue when it is set or changed; an event scheduled inside a voice or Stage channel may use that room as its venue.

- The event page and the event list show a "Where" line with the venue name. Members of the venue get a link to the channel, and the event page adds a **Join** button; anyone else sees the name without a link.
- When the venue is a Stage channel with a live stream, members of the venue see the sidebar's live dot next to the venue name on the event page and in the event list; on the event page the dot appears and disappears without a reload. Anyone else sees the venue name alone, so a private Stage channel's live status and presenter stay within its membership.
- Reminders name the venue: the push notification and the reminder inbox item read "… in \<venue\>".
- The Google Calendar entry uses the venue name as its `location` and appends a "Join: \<room URL\>" line to its description. Setting or clearing the venue resyncs the entry, like a title change.
- A venue change alone sends no inbox items, like a title-only edit. When the same update also changes the time, the usual **Event update** item covers it.
- A repeating event copies its venue to every occurrence. A **This and following** edit propagates a venue change or clearing to the occurrence and every later one; a **This event** edit changes only that occurrence.
- Deleting the venue channel clears the link; the event itself is kept.

## Follow-ups (not in this slice)

Events a member is going or maybe to can appear in their Google Calendar; see [Google Calendar](google-calendar.md).
