# GitHub pull request cards

First slices of [roadmap section 4](../ROADMAP.md) ("GitHub work inside
conversations"): read-only PR cards, subscriptions, and review requests, plus
per-user write actions (comments, approve, request changes, requesting
review) from PR threads, and agent write actions through human approval.

## What it does

A message containing a `https://github.com/<owner>/<repo>/pull/<number>` URL
(`/pulls/` variants match too) renders a live PR card beneath the message:
repository, number, title, author, state (open, draft, merged, closed), base
and head branch, review decision, check status, last-updated time, and a link
to GitHub. The stored message body is never changed; references live in the
`github_pull_request_references` join table and are re-synced when a message
is created or its Markdown source is edited.

- Fetching happens in `Github::FetchPullRequestJob`, never inline in a
  request: on first reference, when a card renders with `fetched_at` older
  than 10 minutes, and when a webhook arrives for a referenced PR. Stale
  renders enqueue at most one job per PR per 10 minutes, however many
  messages or viewers race. The job is idempotent, safe to enqueue
  concurrently, and records failures as `fetch_error` instead of retrying
  forever.
- `POST /github/webhooks` handles `pull_request`, `pull_request_review`,
  `issue_comment`, `check_suite`, `check_run`, and `status` events for PRs
  the workspace references and ignores everything else. `X-GitHub-Delivery`
  ids are stored (`github_webhook_deliveries`, 7-day retention) so
  redeliveries are received once.
- After a record changes, the card partial is broadcast via Turbo Stream
  replace to each room (or thread) with a referencing message, over the
  existing membership-gated room stream.

PR URLs are excluded from the generic OpenGraph unfurl
(`UnfurlLinksController` answers 204) so a PR does not render twice. Messages
composed before this shipped keep any stored unfurl embed they already have.

## Repository subscriptions

A room administrator (or the room's creator) can subscribe an open or closed
room to a GitHub repository from the room's edit page and pick which
pull-request events post into it: `opened` (opened, reopened, ready for
review), `merged`, `closed` (without merge), `review_requested`,
`review_submitted` (approved / changes requested / commented), and
`checks_failed` (a check concluding `failure`, `timed_out`, or `cancelled`,
or a commit status of `failure`/`error`). New subscriptions default to
`opened`, `merged`, `review_requested`, and `checks_failed`. Direct rooms
cannot be subscribed. Subscribing performs no GitHub API call, so a typo in
`owner/repo` simply never receives events.

Each selected event arrives once as a normal message from the workspace
**GitHub** bot (created lazily, member only of subscribed rooms), with one
line of Markdown plus the PR URL on its own line so the PR card renders
beneath it. The card fills in when the regular PR fetch runs; posting never
waits for it.

Dedupe rules (`github_notifications`, one row per subscription and key):

- `opened` posts once per PR, even across reopens and ready-for-review.
- `merged` posts once per PR; `closed` posts once per close timestamp.
- `review_requested` posts once per PR and reviewer login.
- `review_submitted` posts once per review id.
- `checks_failed` posts once per PR and head SHA, however many checks fail.

The webhook's redelivery dedup (`github_webhook_deliveries`) still applies on
top. The required webhook events are the ones already documented above; no
new environment variables were added.

## Review requests in the inbox

Link a GitHub username on the profile page to receive an inbox item ("Review
requested") when a subscribed repository requests a review from that login.
The item points at the posted message, so its visibility follows room
membership: it appears only while the reviewer is a member of the room the
event posted into. A login can be linked to only one user. No item is
recorded for reviewers who are not room members or have no linked login.

## Pull-request threads

A pull request discussed in a room gets one thread that collects its
conversation and its subscription updates (`github_pull_request_threads`,
one row per pull request and room). The PR card carries a **Discuss**
control: when the room already has a thread for that PR it links there,
otherwise it creates a thread with the card's message as its parent,
records the mapping, and redirects to it. Creation follows the normal
thread path — any room member may start one — and concurrent creations
reuse the single mapping row. Repository identity is case-insensitive:
links and webhook payloads in any case resolve to the same pull request
row, which stores its owner and repo lowercased while the card keeps the
fetched repository name's case.

When a subscription event arrives for a PR the room already discusses,
the GitHub bot posts into that thread instead of starting a new room
message, refreshing the thread's activity timestamp. Dedupe rules are
unchanged, rooms without a PR thread keep today's behaviour, and
review-request inbox items point at the thread message.

A PR thread renders the PR card above its messages — the same partial,
with the same live broadcast updates — followed by a **Files changed**
summary: file path, additions, deletions, and status per file, capped at
100 files with an "and N more on GitHub" line. The summary comes from
`GET /repos/{owner}/{repo}/pulls/{number}/files?per_page=100`, fetched
inside the regular `Github::FetchPullRequestJob` run only for PRs that
have at least one thread mapping and stored as JSON on the PR row
(`changed_files`, `changed_files_fetched_at`). Diff bodies are never
stored. A failed files fetch leaves the previous summary in place and
records the existing `fetch_error`.

Mentioning an agent in a PR thread gives it the PR context: its delivery
payload gains a `pull_request` object (`url`, `owner`, `repo`,
`number`, `title`, `state`, `head_branch`, `base_branch`,
`review_decision`, `checks_state`), null in other threads. See [AI
agents](agents.md) for the payload shape.

A PR thread is a normal thread and respects the normal thread rules:
room membership gates the thread itself, while the card in its header
follows the per-viewer rule in [Visibility](#visibility).

## Connect your GitHub account

PR write actions run as the member's own GitHub user through a per-user
fine-grained personal access token — never the workspace token, and
administrators get no special powers. Linking happens on the profile page:
paste a token, the app validates it with `GET /user`, and stores the
returned login with the encrypted token. The token is never logged or
shown again; unlinking deletes it.

Create the token at GitHub Settings → Developer settings → Personal access
tokens → Fine-grained tokens, with repository access to the repositories
you want to act on and these permissions:

- **Pull requests: Read and write** (submit reviews, request reviews)
- **Issues: Read and write** (post PR comments, which use the issues API)
- **Metadata: Read** (included automatically)

Linking also fills in the profile's GitHub username when it is blank, so
review requests land in the inbox. When the profile already has a username
it is left alone, and a mismatch with the token's login is called out in
the confirmation. If GitHub later rejects the token (401), the account is
marked disconnected with a reason and the profile offers a reconnect
instead of a first-time connect.

## Commenting and reviewing from a PR thread

A room member with a linked token sees a "Comment on GitHub" composer plus
**Approve** and **Request changes** buttons in the PR thread header.
(Requesting changes requires a note; GitHub rejects an empty
request-changes review.) Below the composer, a **Request review** row
takes one or more GitHub usernames separated by commas or whitespace (a
leading `@` is optional, up to 15). GitHub treats a request for someone
who already reviewed as a re-request, so the same control covers both.
Members without a linked token see a "Connect GitHub" prompt in place of
the controls.

Each action posts to GitHub as the member's own user and shows a brief
inline confirmation; the thread itself gets no local message. GitHub's own
authorization is the real gate: a 403 or 404 renders inline as "GitHub
refused: \<message\>" with no retry, and a 401 marks the account
disconnected and shows the reconnect prompt.

The member's own comment or review round-trips through the existing
webhook: comments refresh the card via the `issue_comment` event, reviews
flow through `pull_request_review` with the usual dedupe, and the bot's
echo post in the PR thread ("NAME approved …") stays as the confirmation.
A requested review round-trips through the `review_requested` event the
same way, including the reviewer's inbox item when the login is linked.

Out of scope for this slice: a local audit ledger for member actions —
GitHub itself shows who posted what. Agent actions are tracked through
their approval and its completion event, below.

## Agent write actions

An agent can request the same four actions — comment, approve, request
changes, request review — on a pull request the room discusses, executed
only after a human approves. Nothing reaches GitHub without a human
decision.

### Identity

An agent acts as its own linked GitHub account: the bot edit page carries
a "GitHub account" section where an administrator or the agent's owner
pastes a fine-grained token for a machine user dedicated to the agent
(validated with `GET /user`, never shown again). The token is never the
workspace `GITHUB_TOKEN` and never a person's token. Deactivating the
agent's bot disconnects the account, exactly like deactivating a human;
unlinking deletes it.

### Request

`POST /rooms/:room_id/agents/github/pull_request_actions` (agent token
only, JSON) takes `pull_request_id`, `kind` (`comment`, `approve`,
`request_changes`, `request_review`), `body` (comment text or review
note), `reviewers` (usernames separated by commas or whitespace, the same
rules as the member control), and an optional idempotency `external_id`.
The gates, in order: agent authentication (401 for a bad or revoked
token, 403 for a legacy bot key or a human session), room membership (404), a
PR-thread mapping for that pull request in that room (404), the
`external_action` capability in the room (403), a usable linked account
on the agent (422), and the same input rules as the member endpoints — a
comment needs a body, request-changes needs a note, a review request
needs 1 to 15 valid logins (422 with field errors). The endpoint never
calls GitHub: it creates an approval (`github.<kind>`) and returns 202
with its `id`, `status`, and `expires_at`; a repeated `external_id`
returns the existing row with 200. The server builds the approval's
summary and payload itself and binds them: only this endpoint may create
`github.*` approvals (`POST /agents/approvals` refuses the prefix with
422), and at execution time the payload must rebuild to exactly the
action name and summary the decider saw, so an agent cannot approve one
thing and execute another.

```sh
curl -X POST https://smartfire.example.com/rooms/1/agents/github/pull_request_actions \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pull_request_id":7,"kind":"comment","body":"Nice work","external_id":"review-123"}'
```

### Approval and execution

Deciders are the existing approval deciders — the agent's owner and
every administrator — deciding from the activity inbox; there is no new
inbox item type. When a `github.*` request is approved, the server
re-checks everything (still approved, agent active, still a member,
grant still held, thread still mapped, account still usable, and no
earlier outcome recorded for the approval, so a queue retry never posts
twice) and performs the action with the agent's token. Any failed re-check, and any
GitHub refusal, records a failed completion without posting; a 401
disconnects the agent's account exactly like the member path. The
agent's comment or review round-trips through the existing webhook, and
the bot's echo line names the agent's GitHub login. No local message is
posted.

### Result event

Every outcome appends a `github_action_completed` event to the agent's
ledger (`outcome: delivered`, room-scoped, always readable by its own
agent), polled through `GET /agents/events` with a `github_action` key
(`approval_id`, `action`, `status`, plus the GitHub `url` when completed
or a `message` when failed), posted to the webhook the same way, and
listed on the ledger page with its status. See [AI
agents](agents.md#github-write-actions).

### Disconnected or revoked agents

Without a usable linked account the request endpoint answers 422; with
the grant revoked it answers 403. Revocation between request and
decision — or between decision and execution — stops the action, and the
agent learns why through the failed completion event.

## Configuration

### API token (optional, workspace-level)

Set `GITHUB_TOKEN` to a token the app uses for all GitHub REST API reads.
Without it, public repositories still work under GitHub's unauthenticated
rate limit; private repositories show a card saying the PR could not be
loaded. The token is never logged.

Least-privilege scopes, read-only:

- Fine-grained personal access token: **Pull requests: Read-only**,
  **Checks: Read-only**, **Commit statuses: Read-only** (repository access
  limited to the repositories you want cards for). Account metadata access
  is included automatically.
- Classic token (not recommended): `public_repo` for public repositories
  only; `repo` is required for private ones but grants write access, so
  prefer a fine-grained token.

The pull-request threads files call uses the same Pull requests read
scope, so no additional scopes are needed.

### Webhook (optional, for live updates)

Without a webhook, cards still load via the API and refresh when rendered
stale; the webhook only makes updates arrive live.

1. Set `GITHUB_WEBHOOK_SECRET` to a random secret. Until it is set, the
   endpoint answers 503.
2. On each repository (or organization), add a webhook with:
   - Payload URL: `https://<your-host>/github/webhooks`
   - Content type: `application/json`
   - Secret: the value of `GITHUB_WEBHOOK_SECRET`
   - Events: **Pull requests**, **Pull request reviews**, **Issue
     comments**, **Check suites**, **Check runs**, **Commit statuses**
     ("Let me select individual events"). The `ping` event is
     acknowledged. Issue comments are what refresh the card after a
     comment posted from a PR thread.
3. The endpoint verifies `X-Hub-Signature-256` with constant-time
   comparison and answers 401 when the signature is missing or mismatched.

## Visibility

Cards for **public** repositories render inline for every room member,
exactly like any other message content.

Cards for **private** repositories render only for viewers whose own
linked GitHub account can read the repository: when the card loads, the
app asks GitHub (`GET /repos/{owner}/{repo}`) with the viewer's linked
token and shows the card on a 200. Everyone else — members without a
linked account, or whose token GitHub refuses — sees only the plain link
the author typed, and nothing else. A repository whose privacy is still
unknown (no fetch has recorded it yet) is treated as private until one
does. PR thread headers follow the same rule: the card and its Files
changed summary load per viewer behind the same gate. Work thread links
to a private pull request show `owner/repo#number` and its state but
never the title.

The per-viewer decision is cached for ten minutes per repository, grants
and denials alike, so a page of cards from one repository costs at most
one GitHub request per viewer per window. Linking, relinking, or repairing
the connected account retires that member's cached decisions at once,
because the cache key carries the account's `updated_at`. The card content itself still
comes from the stored record fetched with the workspace token; only the
gate is per viewer. Likewise, subscribing a room to a private repository
makes its PR titles visible to the whole room through the posted
messages: subscription messages carry the PR title as text, which room
membership alone gates.
