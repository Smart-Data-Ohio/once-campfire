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

## Follow-ups (not in this slice)

Events a member is going or maybe to can appear in their Google Calendar; see [Google Calendar](google-calendar.md).

- Recurring events.
- Linking an event to a voice or Stage channel.
