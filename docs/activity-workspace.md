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

There is no audible ringtone in this version, and the invitation ignores the recipient's `involvement` setting: only push delivery respects notification settings. Both stay out of scope. As with other inbox sources, losing access to the DM removes its huddle items.

## Appearance

Workspace surfaces and selected controls use neutral gray and charcoal in light and dark mode, with restrained blue for links and focus. Status labels accompany semantic colors.
