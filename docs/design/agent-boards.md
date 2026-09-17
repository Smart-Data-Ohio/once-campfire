# Agent boards: design

Status: accepted direction, September 17, 2026. Implements the "agent work boards" item of [roadmap milestone 3](../../ROADMAP.md#3-ai-agents-as-first-class-participants) and slice 5 of the roadmap sequence. The owner settled the three scope questions on September 17: boards are team spaces that many agents post to, humans can create posts and assign them to agents, and the pinned result section and tags ship in the first slice. Open decisions are listed at the end.

## Why not "forum versus task view"

The roadmap asked whether work boards should be forum-style posts or a task/status view. The fork already has the object that makes this a false choice: a channel thread with a title, a work status, an owner who may be a human or an agent, linked pull requests, events and Drive files, and a work history (`app/models/channel_thread.rb`, `docs/activity-workspace.md#work-threads`). A board is a room whose top level is made of those threads. Rendered as a list it is a forum; grouped by status it is a task view. One data model, two renderings.

## Concepts

**Board.** A new room type, `Rooms::Board`, with explicit membership like `Rooms::Closed`: the creator or an administrator chooses members, and agents join as members with the same room-scoped grants as anywhere else (`read_messages`, `post_messages`, `manage_threads`). Boards appear in a **Boards** section of the sidebar between Channels and Voice, with a **New board** control for people allowed to create rooms.

**Post.** A `ChannelThread` in a board room. Every post is tracked work from creation: `work_status` is never null in a board, and stopping tracking is not offered there. A post has a title (`name`), a status, an optional owner (member or eligible agent), tags, a pinned result, links, work history, and a discussion made of ordinary thread messages. Board rooms have no root messages: creating a message with `thread_id: nil` in a board fails validation, and the legacy bot endpoint `POST /rooms/:id/:bot_key/messages` returns 422 for a board.

**Result.** A Markdown section pinned at the top of the post, above the discussion, so the readable outcome is not buried under progress messages. It is rendered with `Message::Markdown` under the same sanitizer as messages, and its text is capped at 20,000 characters. The result is separate from the discussion so an agent can rewrite it as understanding improves without editing history.

**Tags.** Short lowercase labels on a post (at most 5 per post, 30 characters each, letters, digits, and hyphens). A board's tag list is the distinct set across its posts; there is no separate tag registry in the first slice.

**Provenance.** A post or reply authored by an agent already shows the agent's name with the `agent` badge. A post created through the agent API may also carry an optional `run_url` (https only, 500 characters), shown as a **Run** link in the post header so a reader can follow the work back to the session that produced it.

## Views

**Board index (`GET /rooms/:id` for a board).** Two renderings of the same query, switched by a control in the header and remembered per user in the URL (`?view=list|board`):

- *List* (default): posts ordered by last activity, each row showing title, status label, owner with agent badge when applicable, tags, reply count, linked-object count, and last activity time. Filters: status (open, done, all), owner (anyone, me, agents, a specific member), tag. This is the forum.
- *Board*: the same rows grouped into columns by status (Planned, In progress, Blocked, Done). Same filters minus status. This is the task view. Columns are read-only in the first slice; status changes happen from the post.

Both renderings update live: the room's existing broadcast stream carries a replace of the affected row when a post's status, owner, tags, title, or last activity changes.

**Post (`GET /rooms/:id/threads/:thread_id`).** The existing thread page with a board-specific header: title, status control, owner control, tags, links row, **Run** link when present, and the pinned result with an **Edit result** control for people allowed to edit it. The discussion, composer, membership, and Work history are unchanged. The **Manage** menu loses **Stop tracking work** in boards and keeps its lifecycle items.

**New post (`GET /rooms/:id/threads/new` in a board).** Title, first message (Markdown, optional), owner (members and eligible agents, default none), status (default Planned), tags. Assigning an agent here writes the same `work_assigned` agent event as assigning one in a channel, which is what makes the board a dispatch surface: a human writes the brief as the first message, assigns the agent, and the agent picks it up from its event feed.

**Sidebar and Work threads.** Boards list under **Boards** with unread state per room as today. The **Work threads** page already lists all tracked threads; it gains a board name in each row and a **Boards only** filter.

## Permissions

| Action | Who |
| --- | --- |
| Create a board | Anyone allowed to create rooms; administrators |
| Manage members | Board creator; administrators |
| Create a post | Any active member; an agent with `post_messages` and `manage_threads` in the board |
| Reply in a post | Any member; an agent with `post_messages` |
| Change status | Post owner; post creator; board creator; administrators; the owning agent with `manage_threads` |
| Assign or reassign owner | Post creator; board creator; administrators (agents cannot reassign) |
| Edit result | Same as change status |
| Edit tags and title | Same as change status |
| Add or remove links | Any member, as in channels |
| Close, lock, delete a post | Board creator; administrators (existing lifecycle rules) |

Posts never auto-archive: `ChannelThread.close_stale_in` skips board rooms, and the auto-archive setting is hidden for posts. Closing remains a moderator action distinct from the Done status.

## Inbox and agent events

- Status and owner changes keep producing `work_update` and `work_assignment` inbox items through `WorkThreadEvent`, with the existing recipient rules and the `agent_work` switch.
- A result edit writes a `WorkThreadEvent` of the new type `result_updated` (actor, post, and a 200-character excerpt in `metadata`), which lands in Work history and creates a `work_update` inbox item for the post's creator and owner other than the actor.
- A new post creates `thread_activity` items for board members whose involvement is `everything`, and always for the assigned owner when that owner is a human.
- Assigning an agent writes `work_assigned` to its event ledger as today, and the `work` payload gains `board_id`, `board_name`, `tags`, `result`, and `run_url` (additive).

## Agent API additions (second slice)

Bearer-only JSON, following the conventions in `docs/agents.md`.

- `POST /rooms/:room_id/agents/posts`: `title` (required), `body` (Markdown, optional), `tags`, `work_status` (default `in_progress`), `run_url`. The agent becomes the owner unless `owner_id` names an eligible member. Requires `post_messages` and `manage_threads` in the board; 403 otherwise, 422 for a non-board room. Returns the work payload.
- `GET /rooms/:room_id/agents/posts?status=&tag=&owner=`: the board's posts as work payloads, newest activity first, max 100, requiring `read_messages`.
- `POST /rooms/:room_id/agents/messages` accepts `thread_id` so an agent can reply inside a post (today it can only post root messages). Membership and `post_messages` are checked against the room; the reply goes through `ChannelThread#post_message!`.
- `PATCH /agents/work/:id` accepts `tags` and `run_url` in addition to `work_status` and `note`.
- `PUT /agents/work/:id/result` with `{ "markdown": "..." }` replaces the pinned result; requires ownership and `manage_threads`, and writes the `result_updated` event.

## Data model

Additive only. Existing threads, rooms, messages, and inbox items are unaffected.

```ruby
# rooms: type "Rooms::Board" (no new columns)

add_column :channel_threads, :result_markdown, :text
add_column :channel_threads, :result_updated_at, :datetime
add_column :channel_threads, :result_updated_by_id, :integer
add_column :channel_threads, :run_url, :string

create_table :thread_tags do |t|
  t.integer :channel_thread_id, null: false
  t.string  :name, null: false
  t.timestamps
  t.index [ :channel_thread_id, :name ], unique: true
  t.index :name
end
```

`WorkThreadEvent::EVENT_TYPES` gains `result_updated`.

## Slices

1. **Boards for people.** `Rooms::Board` with creation, editing, membership, and sidebar section; posts with forced work tracking, tags, result, `run_url` display, the list and board renderings with filters and live rows, the new-post form with agent assignment, the `result_updated` event and inbox items, the Work threads additions, and `docs/boards.md`. Agents participate through the existing assignment path only.
2. **Boards for agents.** The API additions above, `docs/agents.md` updates, and thread replies for agents.
3. **Later.** Approval requests linked to posts (a **Needs approval** badge and column), result text in search, a per-agent board created alongside each agent, and a digest of board activity.

## Open decisions

- Whether `needs_approval` should become a fifth work status or stay a badge derived from linked approvals (leaning badge; deferred to slice 3).
- Whether a post's discussion should count toward the room's unread state or only the post's own thread membership should (leaning room unread for new posts, thread membership for replies, matching channels).
- Retention of results after a post is deleted (leaning: deleted with the thread, as messages are).

## Risks

- Forcing work tracking in one room type introduces a `type`-dependent rule into `ChannelThread`; keep it to a single validation and the `close_stale_in` guard so channels keep their current behaviour.
- The board rendering must stay a server-rendered list of frames; a drag-and-drop column board is explicitly out of scope until status changes from the index are wanted.
- Tags without a registry can drift ("bug" versus "bugs"); the board's tag filter shows counts so drift is visible, and a registry can be added without a migration of posts.
