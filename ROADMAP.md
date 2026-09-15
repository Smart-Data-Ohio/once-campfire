# Smart Data Campfire roadmap

Updated September 15, 2026. This is a direction and sequencing document, not a delivery-date commitment. Items under Planned are requests; items under Proposed are additional ideas to evaluate.

## Direction

Build Smart Data's shared workspace for people, AI agents, conversations, and work. Continue moving toward a Discord-like experience while connecting the Smart Apps ecosystem. Campfire is the starting point for an independently maintained product fork; staying feature-compatible with upstream is not a goal.

Keep the upstream remote and license/attribution. Review upstream security fixes and useful changes selectively. Release our own tested, pinned images; do not automatically replace the app with upstream images. The fork's default branch should become the canonical integration branch after review of the deployed work.

## Live foundation

The deployed application source is `56f6ebdf9c5f90a7252f9aec978dcb33e3154151` on `codex/discord-message-ux`. At this update, GitHub `main` still contains upstream code; branch presence and default-branch adoption are separate milestones.

- Responsive channel workspace, light/dark themes, member presence, and Markdown composition.
- Message context menus, quick/grouped reactions, normal-composer editing, replies with notification choice, forwarding, and channel threads.
- Huddles with audio and screen sharing, membership enforcement, and a separate media host. Persistent voice channels and Stage channels remain future work.
- Open Roles feed and existing bot API. These do not yet provide the agent identity model described below.
- Documented backup, isolated migration rehearsal, pinned releases, and rollback procedure in [deploy/README.md](deploy/README.md).

## Current implementation

The next change on `codex/discord-message-ux` adds the first activity inbox, human-owned work threads, one-to-one DM Huddles, and a more neutral gray/charcoal palette. These changes are undergoing integration checks and are not part of the live source revision above. See [Activity inbox and work threads](docs/activity-workspace.md) for the initial behavior and boundaries.

The first DM Huddle slice uses a shared join control with audio and screen sharing. Ringing, invitations, and missed-call notifications follow separately. The inbox starts with new messaging and work events; agent, GitHub, and event sources follow their integrations.

## Planned

### 1. Make the fork the durable home

- Bring the deployed branch onto the fork's default branch through review; preserve the source-to-image release record.
- Establish branch checks, release notes, and a repeatable release workflow with explicit deployment and rollback steps.
- Keep this roadmap in the repository and turn selected milestones into scoped issues with acceptance criteria.
- Decide product name and branding when useful; a rename is not a prerequisite for feature work.

Done when a contributor can clone the default branch, run the app and checks, and identify the code behind the live release.

### 2. Channel types and richer real-time spaces

- One-to-one Huddles directly inside a DM, with a discoverable start/join control, a way to notify the other participant, audio and screen sharing, reconnect, and leave/end behavior. Only the two DM participants can access the call or its activity; define invitation, missed-call, and notification behavior in the feature design.
- Persistent voice channels with visible participants, join/leave controls, and reconnect behavior.
- Voice-channel text chat with durable history and clear access rules for people who are not currently in the call.
- Stage channels with hosts, speakers, listeners, hand raising, and moderation.
- Streaming with explicit presenter/viewer behavior and quality controls, building on existing screen sharing where practical.
- Agent message boards/channels for ongoing work, readable results, and human participation.

Start with one-to-one DM Huddles, then one persistent voice-channel experience before Stage and streaming expansion. Reuse the existing Huddles media and access-enforcement foundation. Define channel membership, roles, notifications, and archive behavior once, then reuse those rules across channel types. Test expected concurrent participation and network conditions before setting capacity expectations.

Done for the first slice when two members can start and join a Huddle from their DM, communicate, share a screen, reconnect, and leave, while a third member cannot access the call. The next slice adds a discoverable persistent voice channel and its text chat, with access removal enforced throughout.

### 3. AI agents as first-class participants

- Agents have distinct identities such as **Riel's GPT Agent**, **Jon's Cursor Agent**, and **Chris's Claude Agent**. An agent's messages are authored by the agent, with visible ownership; they are not attributed to the human owner.
- Support both personal agents and persistent workspace systems such as **Grok Bot** and **Muse**. Workspace systems need an accountable owner or managing group without requiring them to impersonate a person.
- Give agents profiles, channel memberships, mentions, threads, and their own boards/channels. Separate an agent's durable identity from its provider, runtime, and individual sessions.
- Provide credentials and channel/action permissions per agent, revocation, and a visible activity history.
- Support persistent operation through events and background jobs, with duplicate handling, retry limits, rate limits, and loop prevention when agents respond to one another.
- Let people see running, waiting, completed, and failed work, intervene, and approve actions that require human authority.
- Evolve the existing bot API with a compatibility path; do not silently relabel historical bot messages as a different author.

Done for the first slice when a personal agent and a workspace agent can independently join an allowed channel, receive an event, reply under their own identities, and lose access immediately when revoked. External actions use explicitly granted authority.

### 4. GitHub work inside conversations

- First-class PR cards: repository, author, summary, branch, review state, and checks.
- PR-focused conversations with linked code/diffs, review context, and agent participation.
- Repository subscriptions and selected events routed to appropriate channels, with deduplication and noise controls.
- Progress toward authorized review and PR actions from the workspace, retaining actor attribution and links back to GitHub.

T3 Code is the user's interaction reference, not a verified feature specification. Review its relevant experience when designing this milestone and write our own acceptance criteria. Begin with read-only PR context; separately scope write actions and permissions.

Done for the first slice when a linked PR renders current context, receives relevant updates once, and remains visible only to authorized viewers.

### 5. Events and Google Calendar

- Native Events with organizer, time zone, description, RSVP, reminders, and a linked text, voice, or Stage channel.
- Google Calendar connection so opted-in events can appear in a participant's calendar.
- Define the source of truth and attendee consent before choosing one-way publishing or two-way synchronization.
- Handle updates, cancellations, recurring events, disconnected accounts, and retries without duplicate calendar entries.

Done for the first slice when an opted-in attendee receives a calendar entry and a later event change or cancellation updates that same entry correctly.

### 6. Google Drive and Smart Apps

- Native Drive links, useful previews, file discovery, and attachments that retain the source document's access rules.
- Connect the Smart Apps ecosystem through a shared identity and integration model: app-owned identities, events, rich cards, deep links, and explicitly authorized actions.
- Inventory the actual Smart Apps and their owners before deciding the first integration; avoid hard-coding unconfirmed app APIs into the roadmap.
- Make connected-account state, disconnect, permission failures, and action history understandable in the UI.

Done for the first slice when one Drive workflow and one selected Smart App workflow work end to end without exposing private source content to unauthorized channel members.

### 7. Unified activity inbox

- One personal inbox for mentions, replies, followed work, agent approval requests, PR review requests, and event invitations.
- Clear unread/read and handled states, links to the source conversation or object, and filters that make the next useful action easy to find.
- Per-channel and per-integration notification controls; group related updates and avoid duplicate items when one action triggers several events.
- Start with existing mentions, replies, and thread activity. Add agent, GitHub, and Events sources as their respective features ship.
- Enforce source permissions when listing, opening, and acting on an item, including after access changes.

Done for the first slice when a member can find a mention or reply, open its exact context, mark it handled, and keep that state across sessions without seeing another member's private activity. Handling an inbox item must not silently resolve the underlying work or approve an external action.

### 8. Work threads

- Extend conversations into trackable work with a title, owner, status, and linked PRs, files, or events; keep the conversation and its history together.
- Show human and agent progress, blockers, and the next action so ongoing work is easy to resume.
- Build on existing channel threads, preserving ordinary discussions. Start with human-owned work; add agent assignment and richer integration links as those foundations ship.
- Record ownership and status changes, support completion and reopening, and surface relevant changes in the activity inbox.
- Reuse channel permissions for the conversation and separately respect access rules on linked external objects.

Done for the first slice when members can turn a channel thread into work, assign an eligible owner, update its status, find it again, and complete or reopen it without losing messages. Following a discussion and owning its work remain distinct choices.

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
