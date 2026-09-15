# Agents as first-class participants: first slice design

Status: proposal, September 15, 2026. Implements the first slice of [roadmap milestone 3](../../ROADMAP.md#3-ai-agents-as-first-class-participants). Open decisions are listed at the end; nothing here is approved scope until they are settled.

## Assessment of the current bot model

**What exists.** A bot is a `User` with `role: :bot` (`app/models/user/role.rb`), a single `bot_token` column, and a key of the form `"#{id}-#{token}"` (`app/models/user/bot.rb`) passed in the URL path (`config/routes.rb`). Authentication happens in `Authentication#bot_authentication` (`app/controllers/concerns/authentication.rb`); `deny_bots` blocks bots on every controller except those declaring `allow_bot_access` (`app/controllers/messages/by_bots_controller.rb`, `app/controllers/messages/boosts/by_bots_controller.rb`). Inbound events exist only as `Webhook#deliver` (`app/models/webhook.rb`) via `Bot::WebhookJob`, fired from `MessagesController#deliver_webhooks_to_bots`: only root-message mentions, or any message in a direct room. The HTTP response body becomes the reply, with a 7 second timeout that posts "Failed to respond…" as the bot.

**What is already right.** Bot messages are authored by the bot (`messages.creator_id`), so distinct identity and correct attribution already hold. The Open Roles feed is a pure outbound poster; it never needs a webhook, so its compatibility surface is just `POST /rooms/:id/:bot_key/messages` with a raw body.

**Gaps against the milestone.**

1. No owner link. Nothing records that an agent belongs to a person; only admins can create bots (`Accounts::BotsController`).
2. No provider, runtime, or session separation. One column, one meaning.
3. One long-lived credential in the URL, with no expiry, scope, or last-used record, rotated wholesale (`Accounts::Bots::KeysController#update`).
4. Permission equals room membership only; there is no action scope, and `deny_bots` is all or nothing.
5. No activity history. `work_thread_events` is thread-scoped and excludes bots (`app/models/work_thread_event.rb`).
6. No loop prevention or rate limits, only self-exclusion via `.excluding(@message.creator)`.
7. No approvals. `ActivityItem.active_human?` (`app/models/activity_item.rb`) hard-excludes bots.
8. Bots are deliberately second-class in many places (`activity_item.rb`, `channel_thread.rb`, `huddle_grant.rb`). Each needs its own decision later, not a blanket flip.

## Proposed data model

Additive only. `User` remains the identity; nothing on `users`, `messages`, or `webhooks` changes, and `users.bot_token` stays live.

```ruby
create_table :agents do |t|                    # 1:1 with a bot User
  t.integer :user_id, null: false
  t.integer :owner_id
  t.string  :kind, null: false, default: "personal"   # personal | workspace
  t.string  :managing_group, :provider, :runtime, :description
  t.datetime :suspended_at
  t.timestamps
  t.index :user_id, unique: true
  t.index [ :owner_id, :kind ]
end

create_table :agent_credentials do |t|
  t.integer :agent_id, null: false
  t.string  :name, null: false
  t.string  :token_digest, null: false         # SHA256; secret shown once
  t.string  :token_last_four, null: false
  t.datetime :last_used_at, :expires_at, :revoked_at
  t.string  :last_used_ip
  t.integer :created_by_id, null: false
  t.timestamps
  t.index :token_digest, unique: true
  t.index [ :agent_id, :revoked_at ]
end

create_table :agent_grants do |t|              # modeled on HuddleGrant
  t.integer :agent_id, null: false
  t.integer :room_id                            # null = workspace-wide
  t.string  :capability, null: false  # read_messages | post_messages | react | manage_threads | external_action
  t.integer :granted_by_id, null: false
  t.datetime :revoked_at
  t.timestamps
  t.index [ :agent_id, :room_id, :capability ], unique: true, where: "revoked_at IS NULL"
end

create_table :agent_events do |t|              # visible activity ledger
  t.integer :agent_id, null: false
  t.string  :event_type, null: false
  t.integer :room_id, :message_id, :agent_credential_id, :actor_id
  t.string  :outcome, :detail
  t.json    :metadata
  t.datetime :created_at, null: false
  t.index [ :agent_id, :created_at ]
end
```

Model validation: `personal` requires `owner_id`; `workspace` requires `owner_id` or `managing_group`, which gives an accountable owner without impersonating a person. An `agent_sessions` table (provider run id, status) is reserved for the next slice.

## API surface

Keep the existing bot routes byte-identical. Add:

- **Bearer authentication.** `Authentication#agent_authentication` alongside `bot_authentication` reads `Authorization: Bearer cmpf_agent_<secret>`, digests it, finds an unrevoked `AgentCredential`, sets `Current.user = credential.agent.user` and `Current.agent`, and calls `set_authenticated_by(:agent_token)`. The `protect_from_forgery … unless authenticated_by.bot_key?` guard must also except `agent_token?`.
- `GET /agents/me`
- `GET /agents/events?since=<cursor>` for mentions, DMs, and replies addressed to the agent
- `POST /agents/events/:id/ack`
- `POST /rooms/:room_id/agents/messages` (JSON, replies under the agent's own identity)
- Webhooks keep working. Extend `Webhook#payload` additively with an `agent: { id, name, owner, delivery_id }` key.
- Open Roles: unchanged path, unchanged raw-body handling including `markdown_source: nil`. Give it a `workspace` Agent row with a `managing_group`; migrate it to a credential on its own schedule.

## Permission and revocation semantics

| Check | Where |
| --- | --- |
| Credential revoked or expired returns 401 on the next request, no caching | `Authentication#agent_authentication` |
| Agent suspended or user deactivated | `Agent#active?`, same concern |
| Channel access | existing `Current.user.rooms.find_by` in `Messages::ByBotsController#set_room` |
| Capability | new `AgentAuthorization` concern: `require_agent_capability :post_messages` |
| Cascade revocation | `Membership#before_destroy`, `Room#before_destroy`, `User` status change, mirroring `HuddleGrant.revoke_for_membership!` |
| Re-check at perform time, not enqueue time | `Agent::DeliveryJob` |
| Loop and rate guard | `Agent::Delivery` service: hop limit on agent-to-agent chains, per-agent-per-room per-minute cap; every suppression writes `agent_events` |
| External actions | `external_action` capability plus an `agent_approval` `ActivityItem` to the owner; deny by default |

Critical fallback: an agent with zero grants keeps `read_messages` and `post_messages` in rooms it belongs to. Make this an explicit, tested `Agent#legacy_capabilities?`. Forgetting it breaks every existing bot.

## UI touchpoints

- `app/views/accounts/bots/index.html.erb` and `_bot.html.erb`: owner column, personal/workspace badge.
- New agent profile `app/views/agents/show.html.erb`: name, avatar, "Riel's GPT Agent · owned by Riel", provider/runtime, channels, recent activity, revoke controls. Link from the `@user.bot?` branch in `app/views/users/show.html.erb`.
- Credentials panel: create, rotate, revoke; the secret is revealed once.
- Activity history list from `agent_events`, filterable by outcome, visible to the owner and admins.
- Message chip showing the owner, via a helper on `user.agent&.owner` in `app/views/messages/_message.html.erb`.

## PR sequence

1. **Agent identity.** `agents` migration and model, `User#agent`; backfill one `workspace` Agent per existing bot user with `owner_id: nil, managing_group: "Unassigned"`; admin UI shows the owner. Done when every bot user has an Agent and bot-key posting is unchanged. Tests: `test/models/agent_test.rb`, updated `test/controllers/accounts/bots_controller_test.rb`, backfill test.
2. **Credentials.** `agent_credentials`, Bearer auth, CSRF exception, `GET /agents/me`, credentials UI. Done when a revoked credential returns 401 on the next request and the legacy `bot_key` still returns 201. Tests: `test/controllers/concerns/agent_authentication_test.rb`, `test/models/agent_credential_test.rb`, and `test/controllers/messages/by_bots_controller_test.rb` passing unmodified.
3. **Grants and revocation.** `agent_grants`, `AgentAuthorization` applied to both message endpoints, cascade revocation. Done when removing an agent from a closed room forbids its next post immediately. Tests: revocation tests mirroring the huddle-grant tests; forbidden-capability controller tests.
4. **Event delivery and ledger.** `agent_events`, `Agents::EventsController` polling, `agent` key in the webhook payload, rate limit and loop guard, `Agent::DeliveryJob`. Done when two agents mentioning each other stop at the hop limit and both suppressions appear in the ledger. Tests: job tests, two-bot loop test, rate-limit test.
5. **Profile, history, revoke UI, `docs/agents.md`.** Done when an owner who is not an admin can view activity and revoke.
6. **Optional in slice:** `agent_approval` ActivityItem for `external_action`.

## Open decisions

- First runtime: webhook-response (no new infrastructure, 7 second ceiling) versus polling `/agents/events` (survives long runs). Recommendation: polling as the new path, with webhooks kept.
- Boards versus channels only in slice 1. Recommendation: channels only; boards with milestone 5.
- Who may create a personal agent.
- Whether a workspace agent's accountable owner is a User or a free-text group.
- Whether agents may receive `ActivityItem`s or stay in `agent_events` only. Recommendation: the latter for now.
- Hop limit and rate-limit numbers.

## Risks

- **Silent relabeling.** Never touch `messages.creator_id`. Adding `agents.user_id` leaves historical authorship identical. The backfill sets no owner rather than guessing; the UI must render "no owner recorded". Do not backfill `agent_events` from old messages.
- **Open Roles breakage.** Route, raw-body semantics, and `bot_key` auth are frozen, guarded by the untouched existing test file plus a new "legacy bot with no grants can still post" test.
- **Secret in URL.** The legacy path stays but is never extended; new endpoints are header-only.
- **Forgotten capability fallback.** See `Agent#legacy_capabilities?` above.
- **SQLite contention.** `agent_events` is append-only, written from jobs, with a single index.
- **Scattered bot exclusions** must stay untouched in slice 1, so agents cannot silently become work owners or huddle participants.
