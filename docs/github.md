# GitHub pull request cards

Read-only first slice of [roadmap section 4](../ROADMAP.md) ("GitHub work inside
conversations"). No write actions, no per-user GitHub login.

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
  `check_suite`, `check_run`, and `status` events for PRs the workspace
  references and ignores everything else. `X-GitHub-Delivery` ids are
  stored (`github_webhook_deliveries`, 7-day retention) so redeliveries are
  received once.
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
reuse the single mapping row.

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

Visibility follows the same boundary as cards: room membership. A PR
thread is a normal thread and respects the normal thread rules.

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
   - Events: **Pull requests**, **Pull request reviews**, **Check suites**,
     **Check runs**, **Commit statuses** ("Let me select individual
     events"). The `ping` event is acknowledged.
3. The endpoint verifies `X-Hub-Signature-256` with constant-time
   comparison and answers 401 when the signature is missing or mismatched.

## Visibility caveat

**A PR from a private repository is shown to everyone in the room the link
was posted in.** Cards are fetched with the single workspace-level token and
render inside the message, so the room's membership is the visibility
boundary for this slice. Posting a private-repo link to a room shares its
card (title, author, branches, review and check state) with the whole room.
Likewise, subscribing a room to a private repository makes its PR titles
visible to the whole room through the posted messages. Per-user GitHub
identity and per-user visibility are a later slice.
