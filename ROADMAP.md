# Smart Data Campfire roadmap

Updated September 15, 2026. This is a direction and sequencing document, not a delivery-date commitment. Items under Planned are requests; items under Proposed are additional ideas to evaluate.

## Direction

Build Smart Data's shared workspace for people, AI agents, conversations, and work. Continue moving toward a Discord-like experience while connecting the Smart Apps ecosystem. Campfire is the starting point for an independently maintained product fork; staying feature-compatible with upstream is not a goal.

Keep the upstream remote and license/attribution. Review upstream security fixes and useful changes selectively. Release our own tested, pinned images; do not automatically replace the app with upstream images. The fork's default branch should become the canonical integration branch after review of the deployed work.

## Live foundation

The deployed application source is `dfebf3fbc781bf60bd4c14b3c4a2fdf9e2751f2b` on `codex/discord-message-ux`. At this update, GitHub `main` still contains upstream code; branch presence and default-branch adoption are separate milestones.

- Responsive channel workspace, light/dark themes, member presence, and Markdown composition.
- Message context menus, quick/grouped reactions, normal-composer editing, replies with notification choice, forwarding, and channel threads.
- Huddles in channels and one-to-one DMs, with audio, screen sharing, and camera video, membership enforcement, and a separate media host. Persistent voice channels with visible participants, join/leave controls, and text chat are live. Stage channels remain future work.
- Personal activity inbox and human-owned work threads with status, change history, and a workspace-wide work list.
- Open Roles feed and existing bot API. These do not yet provide the agent identity model described below.
- Documented backup, isolated migration rehearsal, pinned releases, and rollback procedure in [deploy/README.md](deploy/README.md), now automated end to end by the image-publish and deploy workflows in [deploy/gcp/README.md](deploy/gcp/README.md).

## Current implementation

The first activity inbox, human-owned work threads, one-to-one DM Huddles, and neutral gray/charcoal palette are live as of September 15, 2026. See [Activity inbox and work threads](docs/activity-workspace.md) for the initial behavior and boundaries and [the release record](docs/releases/2026-09-15-activity-workspace.md) for validation and rollback details.

The first DM Huddle slice uses a shared join control with audio, screen sharing, and camera video, and the invitation slice adds ringing through an incoming-huddle banner, push notifications, and missed-call inbox items. The inbox starts with new messaging and work events, plus native event invitations, updates, cancellations, and reminders; agent and GitHub sources follow their integrations.

The first agent identity slice is live: agents 1:1 with bot users, Bearer credentials with a management UI, and room-scoped or workspace-wide capability grants (`read_messages`, `post_messages`, and `react` enforced; the rest stored for later) with immediate cascade revocation, and event delivery with an activity ledger, polling, rate limits, and loop prevention, plus agent profiles, an agent directory, and self-reported live status. See [AI agents](docs/agents.md). Approvals follow separately.

GitHub's first read-only slice is live: messages linking a pull request URL render a PR card (repository, title, author, state, branches, review decision, checks, updated time) that refreshes via background fetch and webhook with redelivery deduplication, and subscribed rooms now receive selected PR events as GitHub bot messages with review requests in the linked reviewer's inbox. Cards use the workspace-level token and are visible to everyone in the room the link was posted in; per-user GitHub identity and write actions remain planned. See [GitHub pull request cards](docs/github.md).

## Planned

### 1. Make the fork the durable home

- Bring the deployed branch onto the fork's default branch through review; preserve the source-to-image release record.
- Branch checks and the repeatable release workflow exist. `CI` runs the server and browser suites, lint, security scan, and the workflow audit on every pull request to `main`. [Publish image to Artifact Registry](.github/workflows/publish-gcp-image.yml) builds and pins a `git-<source sha>` image on every push to `main`, and [Deploy to GCP](.github/workflows/deploy-gcp.yml) performs the write freeze, backup, boot-disk snapshot, cutover, preservation checks, and automatic rollback described in [deploy/gcp/README.md](deploy/gcp/README.md). Production deployments require a reviewed `main` ancestor, a green `CI` run for that exact revision, and an environment reviewer.
- Remaining: require those checks as branch protection rules on `main`, and settle a release-notes convention on top of the release record the deploy workflow already emits.
- Keep this roadmap in the repository and turn selected milestones into scoped issues with acceptance criteria.
- Decide product name and branding when useful; a rename is not a prerequisite for feature work.

Done when a contributor can clone the default branch, run the app and checks, and identify the code behind the live release.

### 2. Channel types and richer real-time spaces

The one-to-one DM audio/screen-sharing/camera slice is live, including invitations, ringing, and missed-call notifications. The persistent voice-channel slice is live as well: discoverable voice channels with visible participants, join/leave controls, text chat, and enforced access removal (see [voice channels](docs/voice-channels.md)).

- One-to-one Huddles directly inside a DM, with a discoverable start/join control, a way to notify the other participant, audio, screen sharing, and camera video, reconnect, and leave/end behavior. Only the two DM participants can access the call or its activity; invitation, missed-call, and notification behavior is defined in the feature design.
- Persistent voice channels with visible participants, join/leave controls, and reconnect behavior.
- Voice-channel text chat with durable history and clear access rules for people who are not currently in the call.
- Stage channels with hosts, speakers, listeners, hand raising, and moderation.
- Streaming with explicit presenter/viewer behavior and quality controls, building on existing screen sharing where practical.
- Agent message boards/channels for ongoing work, readable results, and human participation.

The live one-to-one DM Huddles slice was followed by one persistent voice-channel experience before Stage and streaming expansion. It reuses the existing Huddles media and access-enforcement foundation. Define channel membership, roles, notifications, and archive behavior once, then reuse those rules across channel types. Test expected concurrent participation and network conditions before setting capacity expectations.

Done for the first slice when two members can start and join a Huddle from their DM, communicate, share a screen, show camera video, reconnect, and leave, while a third member cannot access the call; the starter's call rings the other participant, and an unanswered call leaves a missed-call item. Done for the next slice when members find a persistent voice channel, see who is in it, join and leave with working text chat, and lose the call along with the room when removed.

### 3. AI agents as first-class participants

- Agents have distinct identities such as **Riel's GPT Agent**, **Jon's Cursor Agent**, and **Chris's Claude Agent**. An agent's messages are authored by the agent, with visible ownership; they are not attributed to the human owner.
- Support both personal agents and persistent workspace systems such as **Grok Bot** and **Muse**. Workspace systems need an accountable owner or managing group without requiring them to impersonate a person.
- Give agents profiles, channel memberships, mentions, threads, and their own boards/channels. Separate an agent's durable identity from its provider, runtime, and individual sessions.
- Provide credentials and channel/action permissions per agent, revocation, and a visible activity history.
- Support persistent operation through events and background jobs, with duplicate handling, retry limits, rate limits, and loop prevention when agents respond to one another.
- Let people see running, waiting, completed, and failed work, intervene, and approve actions that require human authority.
- Evolve the existing bot API with a compatibility path; do not silently relabel historical bot messages as a different author.

Done for the first slice when a personal agent and a workspace agent can independently join an allowed channel, receive an event, reply under their own identities, and lose access immediately when revoked. External actions use explicitly granted authority.

Approval requests are live: an agent asks for human authority with `POST /agents/approvals`, the owner and administrators decide from the activity inbox, and the decision returns through event polling and webhooks. See [AI agents](docs/agents.md#approvals).

### 4. GitHub work inside conversations

- First-class PR cards: repository, author, summary, branch, review state, and checks.
- PR-focused conversations with linked code/diffs, review context, and agent participation.
- Repository subscriptions and selected events routed to appropriate channels, with deduplication and noise controls.
- Progress toward authorized review and PR actions from the workspace, retaining actor attribution and links back to GitHub.

T3 Code is the user's interaction reference, not a verified feature specification. Review its relevant experience when designing this milestone and write our own acceptance criteria. Begin with read-only PR context; separately scope write actions and permissions.

Done for the first slice when a linked PR renders current context, receives relevant updates once, and remains visible only to authorized viewers.

### 5. Events and Google Calendar

Native Events with organizer, time zone, description, RSVP, reminders, and inbox invitations are live; see [Native events](docs/events.md). One-way Google Calendar publishing for connected attendees is live; see [Google Calendar](docs/google-calendar.md). Recurrence and linking an event to a text, voice, or Stage channel remain follow-ups.

- Google Calendar connection so opted-in events can appear in a participant's calendar.
- Define the source of truth and attendee consent before choosing one-way publishing or two-way synchronization.
- Handle updates, cancellations, recurring events, disconnected accounts, and retries without duplicate calendar entries.

Done for the calendar slice when an opted-in attendee receives a calendar entry and a later event change or cancellation updates that same entry correctly.

### 6. Google Drive and Smart Apps

- Native Drive links, useful previews, file discovery, and attachments that retain the source document's access rules.
- Connect the Smart Apps ecosystem through a shared identity and integration model: app-owned identities, events, rich cards, deep links, and explicitly authorized actions.
- Inventory the actual Smart Apps and their owners before deciding the first integration; avoid hard-coding unconfirmed app APIs into the roadmap.
- Make connected-account state, disconnect, permission failures, and action history understandable in the UI.

Done for the first slice when one Drive workflow and one selected Smart App workflow work end to end without exposing private source content to unauthorized channel members.

**Status:** the first Drive workflow is live: Drive links in messages render as preview chips (file name, type, modified time, owner) resolved at view time with the viewer's own Google credentials, so members who cannot open the file keep seeing the plain link; see [Google Drive link previews](docs/google-drive.md). File discovery shipped as well: members with Drive previews enabled can find a file by name or from recents in the composer and insert its link without leaving Campfire. Still open: attachments and the first selected Smart App workflow.

### 7. Unified activity inbox

The first messaging and human-work slice is live, with event invitations, updates, cancellations, and reminders as inbox sources; PR review requests already land in the reviewer's inbox and agent approval requests (`agent_approval_request`) already land in each decider's inbox. Other agent and GitHub sources follow their integrations.

- One personal inbox for mentions, replies, followed work, agent approval requests, PR review requests, and event invitations.
- Clear unread/read and handled states, links to the source conversation or object, and filters that make the next useful action easy to find.
- Per-channel and per-integration notification controls; group related updates and avoid duplicate items when one action triggers several events.
- Start with existing mentions, replies, and thread activity. Add agent and GitHub sources as their respective features ship.
- Enforce source permissions when listing, opening, and acting on an item, including after access changes.

Done for the first slice when a member can find a mention or reply, open its exact context, mark it handled, and keep that state across sessions without seeing another member's private activity. Handling an inbox item must not silently resolve the underlying work or approve an external action.

### 8. Work threads

The first human-owned slice is live, including status/owner history, completion and reopening, the global work list, and activity inbox updates. Agent assignment is live; richer external integration links remain planned.

- Extend conversations into trackable work with a title, owner, status, and linked PRs, files, or events; keep the conversation and its history together.
- Show human and agent progress, blockers, and the next action so ongoing work is easy to resume.
- Build on existing channel threads, preserving ordinary discussions. Start with human-owned work; add agent assignment and richer integration links as those foundations ship.
- Record ownership and status changes, support completion and reopening, and surface relevant changes in the activity inbox.
- Reuse channel permissions for the conversation and separately respect access rules on linked external objects.

Done for the first slice when members can turn a channel thread into work, assign an eligible owner, update its status, find it again, and complete or reopen it without losing messages. Following a discussion and owning its work remain distinct choices.

**Status:** agent assignment shipped. Eligible agents can own work threads, learn about assignments through their event ledger and webhooks, and update status through the agent API with progress visible in Work history and the activity inbox; see `docs/agents.md#work-threads`. Still open: richer links to PRs, Drive files, and Events.

### 9. Custom icons and emoji shortcodes

- Ship a built-in icon set for the major technology companies and AI labs (OpenAI, Anthropic, Google, Microsoft, Apple, Meta, Amazon, NVIDIA, GitHub, xAI, Mistral, DeepSeek, Hugging Face, Cursor, and similar) that members can use in messages and reactions.
- Adopt Discord-style `:icon_name:` shortcodes as the standard way to insert custom icons and standard emoji alike, with autocomplete in the composer after typing `:`.
- Custom icons render inline at text size, work in light and dark themes, and appear in reaction chips.
- Later: administrator-uploaded workspace icons with their own names, and room or agent avatars drawn from the same set.

Done for the first slice when a member can type `:openai:` or `:thumbsup:` in a message or a reaction, pick it from the autocomplete, and every viewer sees the icon rendered correctly in both themes.

**Status:** first slice shipped and the listed companies are covered. Thirty-three brand icons from two sources (Simple Icons, CC0; LobeHub `@lobehub/icons-static-svg`, MIT) plus every gemoji alias resolve through `:name:` in Markdown messages and boosts, with `:` autocomplete in the composer and boost input; see `docs/icons.md`. Amazon (retail) has no usable icon in either source. Administrator-uploaded workspace icons shipped as well: SVG/PNG uploads from the Icons page under Account, served from `/icons/:name` and usable as `:name:` in messages, reactions, and autocomplete. Room and agent avatars shipped as well: a room carries an icon shown in the sidebar, the room header, and search results, and a bot uses an icon as its avatar when no picture is uploaded; see `docs/icons.md`. Nothing left open in this section.

## Proposed additions

- **Agent handoffs:** move a task between a person and an agent, or between agents, with explicit context and responsibility.
- **Channel onboarding and knowledge:** pinned purpose, useful documents, and permission-aware summaries of decisions and open work.
- **Integration health:** show stale connections and failed deliveries, with safe replay controls, so persistent systems need little routine maintenance.

These are suggestions, not approved implementation scope.

## Suggested sequence and open decisions

1. Adopt the deployed work on the fork's default branch and establish the release baseline.
2. Add one-to-one DM Huddles using the existing media foundation.
3. Ship the activity inbox for existing messaging events and work threads with human ownership/status.
4. Agree on channel types, membership, and human/agent/app identities; ship one persistent voice channel and one agent identity slice.
5. Add agent work boards and read-only GitHub PR context, connecting their activity and progress to the inbox and work threads.
6. Add Events with an opt-in Calendar slice, then Drive and the first selected Smart App.
7. Expand Stage channels, streaming, and authorized cross-app actions from those foundations.

User priorities can reorder the slices. Before implementation, choose the first agent runtime, the first Smart App, the desired voice concurrency, Calendar sync direction, and whether work boards should be forum-style posts or a task/status view. Each milestone should have its own design, migrations, behavioral checks, and release record; this roadmap alone does not authorize every future integration action.
