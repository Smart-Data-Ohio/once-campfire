# Automated GCP release pipeline

This directory holds the on-VM half of the automated release path. It performs the
cutover documented in [deploy/README.md](../README.md); that document remains the
authority on *why* each step exists and is the procedure to follow by hand when the
pipeline is unavailable.

Two GitHub workflows drive it:

| Workflow | Trigger | What it does |
| --- | --- | --- |
| [`publish-gcp-image.yml`](../../.github/workflows/publish-gcp-image.yml) | push to `main`, push `v*` tags, manual | Builds `linux/amd64` and pushes `git-<full sha>` (plus `v<version>` on tag pushes) to Artifact Registry, then attests provenance. |
| [`deploy-gcp.yml`](../../.github/workflows/deploy-gcp.yml) | manual only | Resolves that tag to a digest and runs `campfire-release.sh` on the app VM through an IAP SSH tunnel. |

## Authentication

Neither VM has a runtime GCP service account, and no long-lived key is ever copied
onto one. GitHub Actions authenticates through Workload Identity Federation:

- `github-image-publisher@…` may write to the `campfire` Artifact Registry repository.
  Any job in this repository may impersonate it.
- `github-deployer@…` may read the repository, log in over OS Login with sudo, open an
  IAP tunnel and create boot-disk snapshots. Only jobs running in the `production` or
  `validation` GitHub environment may impersonate it, so a branch cannot deploy without
  going through an environment and its protection rules.

`deploy-gcp.yml` mints a short-lived access token on the runner and pipes it to the VM
through the SSH session's standard input. It is never written to a file or passed in
`argv`, and the `finish` (or `logout`) phase runs `docker logout` and asserts that
`/root/.docker/config.json` no longer contains any `auths` entry.

## Repository tags are immutable

Artifact Registry rejects moving an existing tag. `publish-gcp-image.yml` therefore
looks the tag up first: if `git-<sha>` already exists it skips the build entirely and
resolves the published digest, so re-running the workflow for an already-released
revision is a no-op rather than a failure.

## `campfire-release.sh`

`campfire-release.sh` runs as root on the app VM and takes one phase per invocation.
Splitting it into phases lets the runner take the boot-disk snapshot at exactly the
moment writes are frozen.

| Phase | Effect |
| --- | --- |
| `preflight` | Discovers the ONCE app, container, storage volume and current digest; checks free disk, refuses to run on top of an in-flight ONCE backup or inside the nightly backup window; authenticates to the registry from stdin; pulls the exact digest and asserts it is `linux/amd64`; records `before-settings.json` and `preflight-result.json`. A dry run stops here. |
| `freeze` | Records the Open Roles timer state, pauses the timer and waits for the current feed run to finish; snapshots the database through the SQLite backup API; stops the app; hashes every uploaded file; tags `campfire-rollback:before-<label>`; archives the ONCE application and the host feed state; writes `freeze-result.json`. |
| `cutover` | `once update <host> --image IMAGE@DIGEST --auto-update=false` (no `--env`, so ONCE keeps the whole existing environment map), starts the app if needed, waits for `/up` to return 200, then verifies the running digest, environment key names, volume identity, additive migration, uploaded file hashes and required processes. Writes `deploy-result.json`. |
| `rollback` | Stops the app, restores `before.sqlite3` into the volume the way `hooks/post-restore` would, returns to the previous digest, and deliberately leaves the feed timer paused. |
| `finish` | Restores the feed timer to its recorded enabled/active state, drops registry credentials, writes `finish-result.json` and `writes-reopened-at`. |
| `logout` | Drops registry credentials only. Used to end a dry run. |

Configuration comes from the environment:

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELEASE_LABEL` | *(required)* | Names `/var/backups/campfire-<label>/` and the rollback tag. |
| `IMAGE_REF` | *(required for `preflight`/`freeze`/`cutover`)* | Must be pinned as `IMAGE@sha256:…`. |
| `EXPECTED_APP_HOST` | unset | When set, `preflight` refuses to continue if the VM serves a different host. |
| `REGISTRY_HOST` | `us-central1-docker.pkg.dev` | Registry to authenticate against. |
| `TIMER_UNIT` | `campfire-open-roles.timer` | Feed timer to pause and restore. |
| `HEALTH_TIMEOUT` | `300` | Seconds to wait for `/up` to return 200. |
| `MIN_FREE_DISK_MB` | `5120` | Refuse to start without this much room for the archive and the new image. |
| `ALLOW_BACKUP_WINDOW` | `0` | Set to `1` to override the nightly ONCE backup window guard. |
| `CAMPFIRE_RELEASE_SIMULATE_FAILURE` | `0` | Validation only. Forces the cutover to report an unhealthy app so the rollback path can be exercised. The deploy workflow refuses to set it outside the `validation` environment. |

### Release record directory

Each release leaves `/var/backups/campfire-<label>/`, matching the shape of earlier
manual releases:

```text
before.sqlite3              database snapshot taken with the SQLite backup API
after.sqlite3               the same snapshot taken from the migrated app
before.once.tar.gz          ONCE application archive (settings, keys, storage)
before-host.tar.gz          Open Roles feed state from host paths
before-settings.json        filtered ONCE settings; environment KEY NAMES only
before-timer-state.txt      the feed timer's prior enabled/active state
attachment-hashes.json      per-file SHA-256 of storage/files before and after
attachment-hashes-before.json / attachment-hashes-after.json
migration-verification.txt  output of script/admin/verify-additive-sqlite-migration
freeze-result.json          previous image, rollback tag, archive SHA-256s
deploy-result.json          running digest, env key names, check results
finish-result.json          feed timer state, registry logout proof, health
writes-reopened-at          the moment chat reopened
```

Treat `before.sqlite3`, `after.sqlite3` and both archives as secret: they contain user
data and application keys. The directory is `0700` and its files are `0600`.

### Why environment *names* and not values

The app container's `once` Docker label is a JSON blob containing `secret_key_base`,
the VAPID private key and the LiveKit secrets, and `Config.Env` carries the same
values. The script only ever extracts `.name`, `.host`, `.image`, `.autoUpdate`,
`.disableTLS`, `.backup`, `.resources` and `env | keys`. Comparing the key *names*
before and after the update is what proves ONCE preserved the configured environment;
it never needs the values to do that.

### Migration verification without a sqlite3 CLI

The app VM has no `sqlite3` binary, so both snapshots are produced by running
`script/admin/prepare-backup` inside the container (SQLite's backup API) and copied out
of the Docker volume. For the comparison both files are placed under the volume's
`backups/` directory so the container can see them, then
`script/admin/verify-additive-sqlite-migration` runs inside the new container and must
exit `0`. The copies are removed from the volume immediately afterwards.

## Running a release

1. Merge to `main`. `publish-gcp-image.yml` publishes `git-<sha>`.
2. Run **Deploy to GCP** with `environment=validation`, the sha, and `dry_run=true`.
   Read the plan in the job summary.
3. Repeat against `validation` with `dry_run=false` and confirm the app.
4. Run it against `production` with `dry_run=true`, then `dry_run=false`. A production
   deployment additionally requires the revision to be an ancestor of `origin/main` and
   a successful `CI` run for that exact sha, and waits for an environment reviewer.
5. Copy the paste-ready release record from the job summary into `docs/releases/`.

If the cutover never reaches a healthy `/up`, the workflow rolls back automatically,
leaves the feed timer paused, and fails with a loud summary. The recovery material —
the frozen checkpoint directory, the boot-disk snapshot and the
`campfire-rollback:before-<label>` image — stays on the host for review.

## ONCE 0.3.2 behaviour worth knowing

- `once update <host> --image …` **starts a stopped application**, so the freeze/cutover
  sequence does not need a separate `once start`. The script still checks and starts it
  if ONCE ever changes that.
- `once update --image` fails immediately with "Failed to download the application
  image" when Docker is not authenticated to the private registry. That is an auth
  error, not a bad reference.
- `once backup` succeeds while the application is stopped, but the in-container
  pre-backup hook cannot run, so the archive contains the raw volume rather than a
  `data/backups/production.sqlite3` snapshot. With the app cleanly stopped the raw copy
  is coherent; the separate backup-API snapshot is taken just before the stop so the
  migration verifier has a known-good `before`.
- ONCE gives the replacement container a new random name suffix on every update, so the
  container must be rediscovered after the cutover. The Docker volume name is stable.
- The volume is mounted at both `/storage` and `/rails/storage`.
- The image has no `ps`; use `docker top <container> -eo pid,args` from the host.
