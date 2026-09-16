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
  than 10 minutes, and when a webhook arrives for a referenced PR. The job
  is idempotent, safe to enqueue concurrently, and records failures as
  `fetch_error` instead of retrying forever.
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
Per-user GitHub identity and per-user visibility are a later slice.
