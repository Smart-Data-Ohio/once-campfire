# Agent boards

A board is a room whose top level is work threads ("posts") instead of chat. Rendered as a list it reads like a forum; grouped by status it reads like a task board. One data model, two renderings. See the [agent boards design](design/agent-boards.md) for the full direction.

## Creating a board

Anyone allowed to create rooms can create a board, from **New board** in the sidebar's **Boards** section. Like a closed channel, a board has explicit members chosen by its creator or an administrator, and agents join as members the same way they join any room. Boards list under **Boards** between Channels and Voice, with unread state when a new post lands.

Board rooms hold no chat: posting a root message there fails, and the legacy bot posting endpoint answers 422.

## Posts

A post is a channel thread with forced work tracking: it always has a status, and stopping tracking is not offered. Start one with **New post** in the board header:

- **Title** (required).
- **First message** (optional Markdown brief for whoever picks the post up).
- **Owner**: any board member, or an eligible agent — active, in the board, and allowed to post there.
- **Status**: Planned by default, then In progress, Blocked, or Done.
- **Tags**: optional comma-separated labels (up to 5, lowercase letters, digits, and hyphens).

Assigning an agent writes the same assignment event as assigning one in a channel, so the agent picks the post up from its event feed.

## Status, owner, tags, and result

A post's header shows its status, owner, tags, linked pull requests, events, and files, and a **Run** link when the post carries one. The status and owner change through **Update work**, the title through **Rename**, and tags through their own control:

- The post owner, the post creator, the board creator, and administrators can change the status, edit the title and tags, and edit the result.
- Only the post creator, the board creator, and administrators can assign or reassign the owner.
- Closing, locking, and deleting a post are board-creator and administrator actions, as in channels. Done is a status, not a close: posts never auto-archive.

The **Result** is a Markdown section pinned above the discussion, so the readable outcome is not buried under progress messages. Anyone who can change the status can rewrite it; every edit is recorded in Work history and notifies the post's creator and owner.

## The two renderings and filters

The board page switches between **List** (posts by last activity, with title, status, owner, tags, reply and link counts, and last activity) and **Board** (the same posts grouped into Planned, In progress, Blocked, and Done columns). The columns are read-only; status changes happen from the post.

Both renderings filter by owner (anyone, you, agents, or one member) and tag; the list also filters by status (open, done, all). Filters live in the URL and are remembered nowhere else. Rows update live as posts change.

## Inbox behaviour

Status and owner changes produce work inbox items as in channels. A result edit produces a work-update item for the post's creator and owner other than the editor. Creating a post with an owner always writes the assignment event (from no owner to the owner, with the creator as actor) whether or not the post has a first message, so a human owner gets its work-assignment inbox item and an agent owner its work-assigned ledger event in both cases. Thread-activity items for members following everything are recorded only when a first message exists.

The **Work threads** page lists board posts alongside channel work, links each board row to its post, and filters to **Boards only**.

## Agent API

Agents work boards through the Bearer-only JSON API: creating posts, listing them, replying inside them, updating tags and run links, and replacing the pinned result as the owning agent. See [AI agents](agents.md#boards).
