# AI agents

First slice of [roadmap milestone 3](../ROADMAP.md#3-ai-agents-as-first-class-participants).
See the [first-slice design](design/agent-identity-slice-1.md) for the full plan.

## Identity

An agent is a row in `agents`, 1:1 with a bot `User`. `kind` is `personal`
(requires an `owner_id`) or `workspace` (requires an owner or managing group on
create; backfilled rows may have no owner, rendered as "no owner recorded").
`Agent#active?` is false while `suspended_at` is set or the bot user is not
active. Suspending an agent revokes all of its capability grants in the same
transaction.

## Credentials

`agent_credentials` holds Bearer agent tokens. Credentials store only a SHA256 digest
plus a display identifier; the secret is shown once at creation. Revoked or
expired credentials return 401 on the next request. The legacy `bot_key` URL
path is frozen and unchanged.

## Capability grants

`agent_grants` rows scope what an agent may do: `agent_id`, nullable `room_id`
(`NULL` means workspace-wide), `capability`, `granted_by_id`, `revoked_at`, and
a partial unique index over active rows. Capabilities are `read_messages`,
`post_messages`, `react`, `manage_threads`, and `external_action`.

`read_messages`, `post_messages`, and `react` are enforced through
the `AgentAuthorization` concern (`require_agent_capability`) on the bot
message endpoints, the bot boost endpoints,
`POST /rooms/:room_id/agents/messages` (JSON, Bearer-only), and the event
polling endpoints below; `external_action` is enforced on the approval
endpoints (see Approvals), and `manage_threads` is enforced on the agent
work endpoints (see Work threads). Enforcement reads the database on every
request; nothing is cached.

Room membership still applies on top of grants: every endpoint returns 404 for
rooms the agent's user is not a member of, so a workspace-wide grant never
bypasses membership. Missing capabilities deny with 403 and a JSON error body;
401 stays reserved for authentication failures (bad, revoked, or expired
credential; suspended agent; deactivated user).

### Legacy fallback

`Agent#legacy_capabilities?` is true when **no `agent_grants` rows exist for
the agent at all, revoked or not**. A legacy agent keeps `read_messages`,
`post_messages`, and `react` in rooms it belongs to. Once any grant has ever
been created, only active grants count: revoking the last grant removes access
rather than restoring the fallback.

### Cascade revocation

Revocation persists in the same transaction as the triggering change:

- Destroying a membership revokes that agent's grants in that room.
  Workspace-wide grants survive; the membership check itself still forbids the
  next post with a 404.
- Destroying a room revokes its room-scoped grants.
- Suspending an agent revokes all of its grants.
- Deactivating, banning, or destroying the agent's user revokes all of its
  grants.

Removing an agent from a closed room or revoking its grant therefore forbids
its next post immediately.

## Event delivery and activity ledger

`agent_events` is an append-only ledger (never backfilled from historical
messages) with `agent_id`, `event_type`, optional `room_id`, `message_id`,
`agent_credential_id`, `actor_id`, `outcome`, `detail`, JSON `metadata`, and
`created_at`, indexed on `[agent_id, created_at]`. Deliverable types are
`mention`, `direct_message`, `reply`, `approval_decided`,
`github_action_completed`, `work_assigned`, and `work_unassigned`;
ledger-only types are `posted`
(written whenever the agent posts through any endpoint) and the suppression
rows `delivery_suppressed_rate_limit`, `delivery_suppressed_hop_limit`, and
`delivery_suppressed_revoked`. Outcomes are `pending`, `delivered`,
`acknowledged`, and `suppressed`.

A message creates one pending event per recipient agent: mentions of the
agent's user, replies to the agent's messages (a reply wins over a mention
when both apply), and any message in a direct room with the agent. The
agent never receives its own messages, and bots without an agent row keep
the legacy webhook path only.

`Agent::DeliveryJob` re-checks room membership and the `read_messages`
grant at perform time, then marks the row `delivered` and posts the
agent's webhook when one is configured. Polling is the primary path, so a
missing webhook still delivers. Revocation between enqueue and perform
writes `delivery_suppressed_revoked`; a message deleted before delivery
marks the row suppressed without a new row.

### Polling

`GET /agents/events?since=<id>&limit=<n>` (Bearer-only, JSON, ordered by
id, max 100) returns the agent's own deliverable rows with the message
payload resolved at query time. Rows for messages the agent can no longer
read (membership or grant revoked, message deleted) are omitted.
`POST /agents/events/:id/ack` marks a row `acknowledged` and is idempotent.
Both require `read_messages` (`Agent#has_capability_anywhere?` at the
endpoint, per-room `Agent#can?` per row and per ack).

Message event rows carry a `pull_request` key: the PR context object when
the message lives in a pull-request discussion thread, explicit null
otherwise. The object is `url`, `owner`, `repo`, `number`, `title`,
`state`, `head_branch`, `base_branch`, `review_decision`, and
`checks_state` (`checks_state` mirrors the card's check status). See
[GitHub pull request cards](github.md#pull-request-threads).

An agent with the `post_messages` capability may also attach Drive files
when it posts through the agent message API by sending
`message[drive_file_ids][]`; only the ids are stored, exactly as for a
member's post. The `message` object itself carries `drive_attachments`: the message's
Drive attachments as `[{ file_id, url }]` (`url` is the
`https://drive.google.com/open?id=...` link), `[]` when there are none.
Never names: bots receive no Drive credentials. See
[Google Drive attachments](google-drive.md#attachments).

### Rate limit and loop guard

At most 20 deliveries per agent per room per minute, counted from
`agent_events`; excess writes `delivery_suppressed_rate_limit` and is
dropped, not queued. Agent-to-agent chains carry `metadata.hop`: human
messages start at 0, and an agent's message carries its trigger's hop plus
one, where the trigger is the most recent mention, direct message, or
reply `delivered` to or `acknowledged` by the agent in that room within the
last five minutes. The agent's own `posted` rows, suppression rows, and
pending rows are never triggers, and neither the request body nor the reply
target influences the hop; a message with no recent trigger is a new root
at 0. A chain reaching hop 3 writes
`delivery_suppressed_hop_limit` instead of delivering, so two agents
mentioning each other stop with both suppressions in the ledger.

### Webhooks

The webhook payload gains an additive
`agent: { id, name, owner, delivery_id }` key (`owner` is the owner's name
or null) when posted through event delivery. The legacy bot webhook path
sends the unchanged payload without that key. Agent deliveries also carry
the same additive `pull_request` key as polling: the PR context object in
a pull-request discussion thread, null otherwise. The agent webhook's
`message` object also carries the same `drive_attachments` array as
polling (`[{ file_id, url }]`, never names); the legacy path omits it.

## Management

Admins and the agent's owner manage grants from the bot edit page ("Manage
capability grants"): grant a capability in one of the agent's rooms or
workspace-wide, and revoke. Anyone else gets 403. The same audience reads
the ledger at `GET /agents/:id/events` (HTML, paginated, filterable by
outcome), linked from the bot edit page and the bot profile. There is no
public exposure.

## Profiles, directory, and status

Every agent has a profile at its bot user's page, and the workspace has an
agent directory at `GET /agents` (HTML, linked from the sidebar). The
directory lists every agent — active first, then suspended, each group
name-sorted; deactivated users are excluded. Bots without an agent row keep
their minimal profile and are not listed.

### Fields

`provider` (e.g. "OpenAI"), `runtime` (e.g. "Codex CLI 0.9"), and
`description` (plain text, max 500 characters) say what the agent is.
`status` is the agent's self-reported state, one of `idle`, `working`,
`waiting` (waiting on a human), or `failed`; `status_note` (max 200
characters) is a free-text companion, `status_changed_at` records the last
status change, and `last_seen_at` records the last authenticated Bearer
request. Suspension is separate and still comes from `suspended_at`.

### Who can change them

Admins and the agent's owner edit provider, runtime, and description on the
bot edit page; anyone else gets 403. Status and note are set only by the
agent itself through `PATCH /agents/me` (see below). `last_seen_at` is
touched automatically on every successfully authenticated Bearer request, at
most once per minute per agent, without callbacks or broadcasts.

### `PATCH /agents/me`

Bearer-only JSON, with the same authentication as `GET /agents/me` (bad,
revoked, or expired credentials, a suspended agent, or a deactivated user
return 401). Only `status` and `status_note` are assignable; anything else
in the body is ignored. An unknown status returns 422 with a JSON error.

```sh
curl -X PATCH https://smartfire.example.com/agents/me \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"working","status_note":"reviewing the thread"}'
```

### Visibility

Any active human member sees an agent's identity (kind, owner or managing
group, provider, runtime), description, status badge with note and "since"
time, last-seen time, the rooms the agent belongs to (only rooms the viewer
is also a member of, as links; the rest counted as "and N more"), and a
summary of its active grants ("post_messages in 3 rooms, read_messages
workspace-wide"; legacy agents show "legacy access (no grants recorded)").
Only admins and the owner also see the compact 24-hour activity line
(delivered, acknowledged, posted, and suppressed counts from the ledger);
the full ledger stays linked from the profile for the same audience.

Status changes broadcast a Turbo Stream replace of the profile status badge
and the directory row over the `agents:all` stream (`AgentsChannel`), which
every signed-in human may subscribe to and bots may not. The badge and row
carry no credentials or grants. `last_seen_at` changes never broadcast.

## Approvals

An agent asks for human authority before an external action by creating an
`AgentApproval` (`agent_approvals`). The accountable people decide from
their activity inbox, and the agent learns the decision through the same
polling and webhook path it already uses for events.

### Request fields

`action` (1 to 60 chars, `[a-z0-9_.-]`), `summary` (plain text, max 500),
optional `room_id` (the room the action concerns), optional opaque `payload`
(JSON text, max 4 KB, never rendered as HTML), and optional `external_id`
(an idempotency key, unique per agent when present). `expires_at` defaults
to 24 hours after creation; the agent may request 5 minutes to 7 days via
`expires_at` or `expires_in` seconds.

### Agent API (Bearer-only, JSON)

Every endpoint requires the `external_action` capability: in the request's
room when a room is given, workspace-wide when none is. A missing grant is
403 with the same error shape as event polling. Polling and acking
decisions additionally require `read_messages`, like other event rows.

- `POST /agents/approvals` creates a request (201 with `id`, `status`,
  `expires_at`). A repeated `external_id` returns the existing row with
  200 instead of a duplicate. Accepts a nested `approval` object or
  top-level fields (`approval_action` aliases `action` at the top level,
  where `action` collides with routing).
- `GET /agents/approvals/:id` returns the row with its effective status,
  decision, note, and decider name. 404 for another agent's rows.
- `GET /agents/approvals?status=pending` lists the agent's own rows,
  newest first, max 100.
- `DELETE /agents/approvals/:id` cancels a pending request (200); 422
  once decided or expired.

```sh
curl -X POST https://smartfire.example.com/agents/approvals \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"approval":{"action":"deploy","summary":"Ship the release","room_id":1,"external_id":"deploy-123"}}'
```

### Statuses and expiry

`pending`, `approved`, `denied`, `cancelled`, `expired`. There is no
scheduler: expiry is lazy. `AgentApproval#effective_status` reads `expired`
when a pending row is past `expires_at`, every read path uses it, and a
decision or cancellation on an expired request is rejected with 422. A
read path that notices an overdue pending row may persist `expired` in the
same request.

### Deciders

The agent's owner and every administrator; a workspace agent with no owner
is decided by administrators only. Nobody else may see or decide a
request: other members get 404 on `GET /agents/:id/approvals` (HTML,
paginated, filterable by status, linked from the bot edit page and the bot
profile next to the ledger link) and on `PATCH /agent_approvals/:id`, and
the inbox never shows them the item.

Each decider gets one `agent_approval_request` activity item on create.
The card shows the agent's name and avatar, the room name when present,
the summary as escaped text, the time left, and Approve and Deny buttons
(deny takes an optional note). Deciding marks every decider's item
handled. Marking an inbox item read or handled never decides the request.

### Delivery of decisions

A human decision appends an `agent_events` row of deliverable type
`approval_decided` with `metadata: { approval_id, status, decided_by,
note }`, `outcome: delivered`, and no `message_id`. `GET /agents/events`
returns it with an `approval` payload instead of `message`, and `ack`
works on it. The webhook posts when configured with the same additive
`agent` key plus an `approval` key carrying the same fields. Agent
cancellation appends no event. Rate limits and the hop guard do not apply
to these rows.

### GitHub write actions

An agent requests a pull-request write action — comment, approve, request
changes, or request review — through
`POST /rooms/:room_id/agents/github/pull_request_actions`, which creates
a `github.*` approval for the usual deciders instead of calling GitHub.
See [GitHub pull request cards](github.md#agent-write-actions) for the
identity, endpoint, gates, and execution rules.

When a `github.*` request is approved, the server performs the action
with the agent's own linked GitHub account and appends a
`github_action_completed` event to the agent's ledger: non-message,
room-scoped, `outcome: delivered`, always readable by its own agent,
with `metadata` carrying `approval_id`, `action`, `status` (`completed`
or `failed`), the GitHub `url` when completed, or a `message` when
failed. `GET /agents/events` returns it with a `github_action` key
instead of `message`, `ack` works on it, the webhook posts it with the
same additive `agent` key plus `github_action`, and the ledger page
lists it with its status. Rate limits and the hop guard do not apply,
like approval rows.

## Work threads

A work thread can be owned by an agent. The thread's starter, the
channel's creator, or an administrator assigns an agent from the
**Agents** group in **Update work**; the agent's progress then appears
in Work history and the activity inbox like any owner's. See [Activity
inbox and work threads](activity-workspace.md#work-threads) for the
human side.

### Eligibility

A bot user is an eligible work owner when it has an `Agent` row that is
active, belongs to the thread's room, and holds `post_messages` there
(`Agent#can?(:post_messages, room)`). Suspending the agent or revoking
its membership leaves the assignment visible as unavailable, exactly
like an inactive human owner; there is no separate unassign path.

### Assignment events

Assigning an agent writes a `work_assigned` row to its event ledger in
the same transaction as the work change, with `room_id` set, `actor_id`
the human who assigned it, and `metadata: { thread_id, title,
work_status, assigned_by }`. Unassigning it — clearing the owner,
reassigning to a human, or stopping work tracking — writes
`work_unassigned` the same way. Both are deliverable types, but neither
is a message type, so rate limits and the hop guard ignore them.

`GET /agents/events` returns these rows with a `work` payload instead
of `message`:

```json
{ "thread_id": 7, "room_id": 2, "title": "Ship the fix", "status": "planned", "url": "/rooms/2?thread=7", "assigned_by": "David" }
```

`url` is the workspace permalink path for the thread. Rows for threads
the agent can no longer read (membership or `read_messages` revoked)
are omitted, like message rows. The webhook posts after the assigning
transaction commits, when configured, with the same additive `agent` key
plus `event_type` and the `work` key, gated on current room membership
and `read_messages` like message delivery. `ack` works on these rows.

### Agent API (Bearer-only, JSON)

- `GET /agents/work` lists the threads the agent currently owns (`id`,
  `room_id`, `title`, `work_status`, `url`, `updated_at`), newest
  first, max 100, filtered to rooms where the agent holds
  `read_messages`.
- `GET /agents/work/:id` returns one owned thread, or 404 for anything
  the agent does not own or whose room the agent's user no longer belongs
  to.
- `PATCH /agents/work/:id` updates the status of an owned thread. It
  takes `work_status` (one of `planned`, `in_progress`, `blocked`,
  `done`) and an optional plain-text `note` (max 500 characters),
  stored in the work event and shown in Work history. Anything the
  agent does not own is 404; a missing `manage_threads` grant in the
  thread's room is 403. Agents cannot reassign, convert, or stop
  tracking.

```sh
curl -X PATCH https://smartfire.example.com/agents/work/7 \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"work_status":"in_progress","note":"Reproducing the bug"}'
```

This is the first enforcement of `manage_threads`: the status update
requires it in the thread's room, with the standard 403 error shape.

### Link payloads

Every work payload — `GET /agents/work`, `GET /agents/work/:id`,
`PATCH /agents/work/:id`, and the `work` key in assignment event
polling and webhooks — carries a `links` array, in link order:

```json
[
  { "kind": "pull_request", "url": "https://github.com/rails/rails/pull/7", "title": "Fix login",
    "pull_request": { "url": "https://github.com/rails/rails/pull/7", "owner": "rails", "repo": "rails", "number": 7, "title": "Fix login", "state": "open", "head_branch": "shiny", "base_branch": "main", "review_decision": "approved", "checks_state": "passing" },
    "event": null },
  { "kind": "event", "url": "/rooms/2/events/3", "title": "Watercooler sync",
    "pull_request": null,
    "event": { "id": 3, "title": "Watercooler sync", "starts_at": "2026-09-20T14:00:00.000Z", "ends_at": null, "cancelled": false, "url": "/rooms/2/events/3" } },
  { "kind": "drive_file", "url": "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view", "title": "Q3 Planning",
    "pull_request": null, "event": null }
]
```

The `pull_request` object reuses the PR context shape from message
delivery; the `event` object gives the linked event's scheduling
fields. Drive entries carry only the stored URL and the display name
cached when the link was added: bots receive no Drive credentials, so
agents cannot resolve Drive metadata themselves.
