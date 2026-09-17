# Activity inbox and work threads

The sidebar has two workspace views: **Activity inbox** for your notifications and **Work threads** for trackable conversations.

## Activity inbox

New mentions, opted-in replies, followed-thread activity, and relevant work changes appear here. Existing channel and thread notification preferences still apply. Activity starts when this feature is installed; older conversations are not automatically turned into an unread backlog.

- **Unread**, **Read**, and **Handled** separate new items from things you have opened or finished attending to.
- **Open** marks an item read and takes you to its message or thread.
- **Mark handled** clears an item from the active inbox. **Clear handled** brings it back to the read view.
- The sidebar badge shows the unread count. An open inbox updates when new activity arrives.

Handling an inbox item does not complete a work thread or approve an external action. Access follows the source conversation: removing a member's access also removes that conversation's items from their inbox. Deleted sources are not shown.

Event invitations, updates, cancellations, and reminders are additional sources; see [Native events](events.md). Agent approval requests land in each decider's inbox with Approve and Deny actions; see [AI agents](agents.md#approvals). GitHub review requests will follow as that integration is implemented.

## Notification controls

Three layers decide what lands in your inbox: per-channel involvement, per-integration switches, and grouping. The inbox lists the newest activity first.

### Per-channel involvement

The inbox honours each channel's notification setting. Suppression happens when an item would be created; changing the setting never rewrites or deletes items you already have.

| Inbox item | everything | mentions | nothing | invisible |
| --- | --- | --- | --- | --- |
| Direct mentions, and PR review requests addressed to you | Yes | Yes | Yes | No |
| Replies to you | Yes | Yes | No | No |
| Followed-thread activity | Yes | Yes | No | No |
| Work updates and assignments | Yes | Yes | No | No |
| Event invitations, updates, cancellations, reminders | Yes | Yes | No | No |
| Huddle invitations and missed calls | Yes | Yes | No | No |
| Agent approval requests | Yes | Yes | Yes | Yes |

Agent approval requests are workspace-scoped rather than room-scoped, so channel involvement never suppresses them; only the profile's agent-approvals switch does.

Push notifications already follow the same setting for messages, thread activity, and huddle invitations: members with notifications off or invisible get no push from that room. One difference: a direct mention still creates an inbox item when notifications are off, but sends no push. Event reminder pushes still go to every going or maybe attendee.

### Per-integration switches

Your profile's **Notifications** section holds five switches, all on by default. Turning one off stops only its inbox items; the underlying work stays where it is.

- **GitHub review requests**: pull request review request items. The PR card in the channel is unaffected.
- **Agent approval requests**: approval items. Every request stays on the approvals page, where you can still decide it.
- **Agent work assignments**: work assigned by an agent. Human-driven assignments and status updates always record.
- **Event reminders**: inbox reminders before events you are attending. Push reminders still go out.
- **Huddle invitations**: incoming and missed huddle items. The incoming-call banner still rings.

### Grouping

Bursts of related updates collapse into one item instead of many:

- A new thread-activity or work-update item refreshes your existing unhandled item of the same kind for that thread — unread again, back at the top, and now describing the latest change — instead of adding a second row. Items of other kinds for the thread (a mention, a work assignment) are left alone. Handling the item starts fresh: the next update creates a new one.
- One message produces at most one item per person, with the most specific type: a mention beats a reply, and a reply beats thread activity.

### Filters

The state filter (**Unread**, **Read**, **Handled**) sits next to a type filter: **All**, **Mentions and replies**, **Threads and work**, **Events**, **Agents**, **GitHub**, **Huddles**. Both filters survive pagination and state changes, and the JSON index accepts the type as `?type=events`.

## Work threads

A work thread is a channel thread with a status and an optional owner. Turn on work tracking when a conversation has become something someone needs to finish, so it stays findable after the discussion quiets down. Ordinary threads continue to work as discussions.

### Starting a work thread

1. Open a channel and choose **Threads** in the channel header.
2. Open an existing thread, or choose **New thread** to start one from scratch or from a message.
3. In the thread, open **Manage** and choose **Track as work**. The thread starts as **Planned** and unassigned.
4. Choose **Update work** to assign an owner from the channel's members and to change the status.

The person who started the thread, the channel's creator, or an administrator can turn tracking on, turn it off, and assign an owner. **Manage** only appears for those people. The assigned owner can update the status but cannot reassign the work.

### Tracking progress

Work can be **Planned**, **In progress**, **Blocked**, or **Done**. **Complete work** sets the status to Done and **Reopen work** returns it to Planned. Ownership and status changes are recorded in the thread's **Work history**.

Inside a channel, the thread browser's **Show** filter lists that channel's **Open work** and **Completed work**. **Stop tracking work** in **Manage** turns the thread back into an ordinary discussion and keeps its messages and history.

Use **Work threads** in the sidebar to find open, completed, or all work across your accessible channels. Completing or reopening work preserves its messages. Discussion archival and work completion are separate: unfinished work remains discoverable even if the conversation is archived.

This first version supports human ownership and progress. Agent assignment and richer links to PRs, Drive files, and Events are planned integrations.

## Huddles in direct messages

Open a one-to-one DM and choose **Join huddle**. The other person joins from the same DM. Audio, screen sharing, camera video, mute, reconnect, and leaving use the existing Huddles controls; moving to another channel keeps the call connected.

Group DMs do not expose this one-to-one control.

## Huddle invitations

When someone starts a huddle in a one-to-one DM, the other participant gets an incoming-huddle banner naming the caller, with **Join** and **Dismiss**. Join opens the DM first when needed and then joins the call; Dismiss marks the invitation read. Someone away from the app gets a "<name> started a huddle" push notification that opens the DM instead, following their existing notification settings.

Every invitation also lands in the activity inbox. Answering the call marks it handled automatically. An invitation left unanswered for 45 seconds, or one whose starter left first, becomes a missed-huddle item that stays unread until opened or handled. Starting the call again rings again unless an invitation or missed-huddle item from the last two minutes already exists, so reconnects and rejoins do not ring twice.

There is no audible ringtone in this version. The invitation honours the recipient's `involvement` setting for the DM: with notifications off or invisible, no inbox item is created and no push goes out. The profile's huddle switch suppresses only the item — the banner still rings. As with other inbox sources, losing access to the DM removes its huddle items.

## Appearance

Workspace surfaces and selected controls use neutral gray and charcoal in light and dark mode, with restrained blue for links and focus. Status labels accompany semantic colors.
