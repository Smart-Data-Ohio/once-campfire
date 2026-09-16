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

`agent_credentials` holds Bearer [REDACTED] Credentials store only a SHA256 digest
plus a display identifier; the secret is shown once at creation. Revoked or
expired credentials return 401 on the next request. The legacy `bot_key` URL
path is frozen and unchanged.

## Capability grants

`agent_grants` rows scope what an agent may do: `agent_id`, nullable `room_id`
(`NULL` means workspace-wide), `capability`, `granted_by_id`, `revoked_at`, and
a partial unique index over active rows. Capabilities are `read_messages`,
`post_messages`, `react`, `manage_threads`, and `external_action`.

Only `post_messages` and `react` are enforced so far, through the
`AgentAuthorization` concern (`require_agent_capability`) on the bot message
endpoints, the bot boost endpoints, and `POST /rooms/:room_id/agents/messages`
(JSON, Bearer-only). The other capabilities are storable and shown in the UI
marked "not yet enforced". Enforcement reads the database on every request;
nothing is cached.

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

## Management

Admins and the agent's owner manage grants from the bot edit page ("Manage
capability grants"): grant a capability in one of the agent's rooms or
workspace-wide, and revoke. Anyone else gets 403.
