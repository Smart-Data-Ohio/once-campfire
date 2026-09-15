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

## The ordering rule

**Everything that could discover a migration problem happens before the live
application is touched.** While writes are frozen, the candidate image migrates a
*copy* of the frozen database inside a throwaway container with `--network none`, and
`script/admin/verify-additive-sqlite-migration` must exit `0`. Only then does the
cutover run.

Once the new image is serving traffic it may have accepted writes, so the checks that
run after the cutover are **read-only**. They can fail the release loudly, but nothing
they find justifies restoring a database over writes that users may already have made.

That rule is the reason the recovery phase behaves the way it does:

- If the live database is **byte-for-byte what it was at the freeze**, nothing was
  accepted. The previous image is restored automatically and nothing is lost.
- If the live database has **changed at all** — a migration, a message, anything — the
  recovery phase stops the application, **refuses to restore the database**, changes
  nothing else, and exits with an operator-action message and exit code `30`. Restoring
  the frozen copy there would silently discard whatever came after it.

The comparison uses `frozen_live_database_sha256` in `freeze-result.json`: a digest of
the live `db/production.sqlite3` *and its write-ahead log* as they sat in the volume
with the application stopped. It is deliberately not the digest of `before.sqlite3`,
which is a logically equivalent but physically different file produced by SQLite's
backup API.

## Authentication

Neither VM has a runtime GCP service account, and no long-lived key is ever copied
onto one. GitHub Actions authenticates through Workload Identity Federation:

- `github-image-publisher@…` may write to the `campfire` Artifact Registry repository.
  Any job in this repository may impersonate it.
- `github-deployer@…` may read the repository, log in over OS Login with sudo, open an
  IAP tunnel and create boot-disk snapshots. Only jobs running in the `production` or
  `validation` GitHub environment may impersonate it, so a branch cannot deploy without
  going through an environment and its protection rules.
- `campfire-image-puller@…` holds `artifactregistry.reader` and nothing else.
  `github-deployer` holds `roles/iam.serviceAccountTokenCreator` on it.

Where this organization has GitHub's ID-qualified OIDC subjects enabled, the
per-environment `principal://…/subject/…` bindings on `github-deployer` must spell the
subject the way GitHub now mints it —
`repo:Smart-Data-Ohio@262436228/once-campfire@1370426325:environment:<name>` — and not
the older `repo:Smart-Data-Ohio/once-campfire:environment:<name>`. Attribute-based
`principalSet` bindings (`repository`, `repository_owner`) are unaffected. A subject
that does not match presents as `iam.serviceAccounts.getAccessToken` denied on the
deployer service account, which the deploy workflow now surfaces in its own words
rather than as a missing image.

**The VM never receives the deployer's own credential.** The runner mints a token for
the read-only puller with
`gcloud auth print-access-token --impersonate-service-account="$GCP_IMAGE_PULLER_SA"`
and pipes only that into the SSH session's standard input. It is never written to a
file, an environment variable or `argv`. The `finish` (or `logout`) phase runs
`docker logout` and asserts that `/root/.docker/config.json` no longer contains any
`auths` entry. So the worst a compromised app VM can do with what it was handed is
read images it can already run.

## Repository tags are immutable

Artifact Registry rejects moving an existing tag. `publish-gcp-image.yml` therefore
looks the tag up first: if `git-<sha>` already exists it skips the build and resolves
the published digest, so re-running the workflow for an already-released revision is a
no-op rather than a failure. A lookup that fails for any reason *other* than "not
found" — auth, network, permissions — fails the run instead of rebuilding blindly into
a tag collision.

## `campfire-release.sh`

`campfire-release.sh` runs as root on the app VM and takes one phase per invocation.
Splitting it into phases lets the runner take the boot-disk snapshot at exactly the
moment writes are frozen. Every invocation takes `flock` on
`/var/lock/campfire-release.lock`, so two releases can never interleave on one host.

| Phase | Effect |
| --- | --- |
| `preflight` | Discovers the ONCE app, container, storage volume and current digest; **records the feed timer state once** (a retry never overwrites it); checks free disk against the real volume and image sizes; refuses to run on top of an in-flight ONCE backup or inside the nightly backup window; authenticates to the registry from stdin; pulls the exact digest and asserts it is `linux/amd64`. A dry run stops here. |
| `freeze` | **Refuses a release directory that already has `freeze-result.json` unless `RESUME=1`.** Pauses the feed timer and waits for the current feed run to finish; snapshots the database through the SQLite backup API; stops the app and **asserts no application container is still running**; fingerprints the live database; hashes every uploaded file; tags `campfire-rollback:before-<label>`; archives the ONCE application and the host feed state; then **rehearses the migration** on a copy. Any failure here restores the feed timer through a trap. |
| `cutover` | `once update <host> --image IMAGE@DIGEST --auto-update=false` (no `--env`, so ONCE keeps the whole existing environment map), waits for `/up` to return 200, then runs read-only checks: running digest, environment key names, volume identity, pre-existing uploaded file hashes, and required processes. Exits `10` if it never became healthy and `20` if it became healthy but a check failed. |
| `rollback` | Refuses outright when the cutover already reported healthy and `/up` still returns 200: an interruption after a successful cutover must not downgrade a working deployment, so it records `refused-application-healthy` and exits `30` with the outstanding bookkeeping. Otherwise it stops the app, asserts it is stopped, then compares the live database fingerprint to the freeze. **It never writes to the database.** In both cases it returns ONCE to the previous image and gets it serving again — trying a plain `once start` first when the container left on the host still carries the previous image, then **checking what actually came up** and falling through to `once update --image <previous registry reference>` unless the previous image is really what is running. The label is a hint, not proof: ONCE keeps no state on disk, so an `once update` that failed after rewriting it can make a local start boot the candidate instead. What differs is the verdict: an unchanged database means nothing was lost and the phase exits `0`; a changed database means the candidate already migrated or accepted writes, so the frozen copy is **not** restored over it, the run is recorded as `refused-database-changed`, and it exits `30` to page an operator. Leaves the feed timer paused either way. |
| `finish` | Restores the feed timer to its recorded state, drops registry credentials, writes `finish-result.json` and `writes-reopened-at`, then prunes old release directories. |
| `logout` | Drops registry credentials only. Used to end a dry run. |
| `timer-state` | Prints the recorded and current feed timer state as JSON. Read-only. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `1` | A precondition or a phase failed. Nothing was cut over. |
| `10` | The cutover never reached a healthy `/up`. If it aborted before `once update` the database is untouched and the rollback completes cleanly; otherwise the candidate has usually already migrated it on boot, so the run exits `30` and restores the previous image without touching the database. |
| `20` | The application became healthy but a read-only check failed. It may have accepted writes, so it is **left running** and the workflow does not attempt recovery. The job fails; an operator decides. |
| `30` | The rollback refused to change something. Either the database changed after the freeze — the previous image was still restored and the app is serving, the database was left as it was — or the application is healthy on the new image and was left running untouched. **An operator must act** in both cases. |

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `RELEASE_LABEL` | *(required)* | Names `/var/backups/campfire-<label>/` and the rollback tag. `[A-Za-z0-9._-]` only. |
| `IMAGE_REF` | *(required for `preflight`/`freeze`/`cutover`)* | Must be pinned as `IMAGE@sha256:<64 hex>`. |
| `RESUME` | `0` | `1` lets `freeze` reuse a release directory that already completed, deliberately pairing a new cutover with an older backup. |
| `EXPECTED_APP_HOST` | unset | When set, `preflight` refuses to continue if the VM serves a different host. |
| `REGISTRY_HOST` | `us-central1-docker.pkg.dev` | Registry to authenticate against. |
| `TIMER_UNIT` | `campfire-open-roles.timer` | Feed timer to pause and restore. |
| `SERVICE_UNIT` | `${TIMER_UNIT%.timer}.service` | The oneshot service the timer activates. `freeze` waits for it to go inactive before stopping the app. |
| `FEED_DRAIN_TIMEOUT` | `300` | Seconds to wait for a feed run already in flight. |
| `HEALTH_TIMEOUT` | `300` | Seconds to wait for `/up` to return 200. |
| `STATE_ROOT` | `/var/backups` | Parent of the release directories. Its filesystem is the one checked for capacity, and pruning happens inside it. |
| `OPEN_ROLES_PATHS` | the five feed paths | Space-separated host paths archived into `before-host.tar.gz`. The ONCE application archive does not include them. |
| `MIN_FREE_DISK_MB` | `3072` | Floor checked before the image is pulled. |
| `RELEASE_KEEP` | `3` | Release directories kept when pruning. |
| `ALLOW_BACKUP_WINDOW` | `0` | `1` overrides the nightly ONCE backup window guard. |
| `LOCK_FILE` | `/var/lock/campfire-release.lock` | The per-host release lock. |
| `CAMPFIRE_RELEASE_SIMULATE_FAILURE` | `0` | Validation only. `1` aborts the cutover before `once update`, so the database is provably untouched and the rollback completes. `2` lets the app go healthy and then forces a read-only check to fail, which is the case where the rollback must refuse. The deploy workflow rejects either outside the `validation` environment. |

### Capacity

`preflight` checks the filesystem that actually holds `STATE_ROOT`, not
`/var/lib/docker`, and sizes the requirement from measurements rather than a guess:
`du -sm` of the storage volume × 2 (one archive plus one rehearsal copy) + 512 MB on
the `STATE_ROOT` filesystem, and the image size + 512 MB on `/var/lib/docker`. When
both paths are on the same filesystem the two are summed and checked once.

### Retention

Release directories hold a full copy of the database and the application archive, so
they are not free. `finish` keeps the newest `RELEASE_KEEP` (default 3) directories
matching `campfire-*` under `STATE_ROOT` and deletes the rest — **only after a
successful release**, so a failed one never deletes a checkpoint an operator still
needs. Nothing else prunes them; a long run of failures will accumulate directories
until someone intervenes, which is the intended bias.

### Release record directory

Each release leaves `/var/backups/campfire-<label>/`, matching the shape of earlier
manual releases:

```text
before.sqlite3              database snapshot taken with the SQLite backup API
after.sqlite3               the same database after the rehearsal migration
before.once.tar.gz          ONCE application archive (settings, keys, storage)
before-host.tar.gz          Open Roles feed state from host paths
before-settings.json        filtered ONCE settings; environment KEY NAMES only
before-timer-state.txt      the feed timer's prior enabled/active state (write-once)
attachment-hashes.json      per-file SHA-256 of storage/files before and after
attachment-hashes-before.json / attachment-hashes-after.json
migration-verification.txt  full output of the isolated rehearsal
rehearsal-result.json       rehearsal pass/fail and its preserved/additive counts
preflight-result.json       app, volume, current and target image and revision
freeze-result.json          previous image and revision, rollback tag, archive
                            SHA-256s, and the live database fingerprint
deploy-result.json          running digest, env key names, check results
cutover-healthy-at          when /up first returned 200 on the new image; its
                            presence is what stops a later recovery from
                            downgrading a deployment that is still working
rollback-result.json        written only when the recovery phase ran
finish-result.json          feed timer state, registry logout proof, health
writes-reopened-at          the moment chat reopened
```

Treat `before.sqlite3`, `after.sqlite3` and both archives as secret: they contain user
data and application keys. The directory is `0700` and its files are `0600`. Nothing
this script creates is left inside the live storage volume; a trap clears any stray
copies on every path.

### Why environment *names* and not values

The app container's `once` Docker label is a JSON blob containing `secret_key_base`,
the VAPID private key and the LiveKit secrets, and `Config.Env` carries the same
values. The script only ever extracts `.name`, `.host`, `.image`, `.autoUpdate`,
`.disableTLS`, `.backup`, `.resources` and `env | keys`, plus the single `GIT_REVISION`
entry from an image's environment for the release record. Comparing the key *names*
before and after the update is what proves ONCE preserved the configured environment;
it never needs the values to do that.

### Migration verification without a sqlite3 CLI

The app VM has no `sqlite3` binary. The frozen database is snapshotted by running
`script/admin/prepare-backup` inside the container (SQLite's backup API). The rehearsal
then runs entirely inside a throwaway container built from the candidate image:

```text
docker run --rm --network none -v <scratch>:/rails/storage -e SECRET_KEY_BASE_DUMMY=1 <image>
  /hooks/post-restore                       # deploy/README.md step 4
  cp backups/production.sqlite3 rehearsal-before.sqlite3
  bin/rails db:migrate
  script/admin/prepare-backup               # consistent post-migration snapshot
  cp backups/production.sqlite3 rehearsal-after.sqlite3
  verify-additive-sqlite-migration before after   # deploy/README.md step 5
```

`--network none` keeps it isolated, `SECRET_KEY_BASE_DUMMY=1` means no production key
is needed, and the scratch directory is a copy, so the live volume is never mounted.
Only a pass/fail line and the preserved/additive counts reach the job log; the full
verifier output stays in `migration-verification.txt` on the host.

## Snapshot scope

The workflow snapshots the instance's **boot disk only**. On the current VMs the ONCE
storage volume lives under `/var/lib/docker` on that same disk, so the snapshot covers
it. If a data disk is ever attached, the workflow warns that it is not included and the
snapshot stops being a complete checkpoint.

## Running a release

1. Merge to `main`. `publish-gcp-image.yml` publishes `git-<sha>`.
2. Run **Deploy to GCP** with `environment=validation`, the sha, and `dry_run=true`.
   Read the plan in the job summary.
3. Repeat against `validation` with `dry_run=false` and confirm the app.
4. Run it against `production` with `dry_run=true`, then `dry_run=false`. A production
   deployment additionally requires the revision to be an ancestor of `origin/main` and
   a successful `CI` run for that exact sha, and waits for an environment reviewer.
5. Copy the paste-ready release record from the job summary into `docs/releases/`.

The default release label includes the workflow run id, so a retry always gets a fresh
directory and a fresh backup. Reusing an earlier label requires passing both
`release_label` and `resume=true`, which says in as many words that you intend to pair
this cutover with that older backup.

### How long writes are frozen

The freeze window is not just the database snapshot: it spans the ONCE and host
archives, the migration rehearsal, the boot-disk snapshot wait, and the cutover
itself. Measured end to end on the validation VM, with a ~400 KB database and no
uploaded files:

| Step | Wall time |
| --- | --- |
| `freeze` (snapshot, stop, hashes, archives, rehearsal) | ~25 s, of which the rehearsal is ~9 s |
| Boot-disk snapshot to `READY` | ~47 s |
| `cutover` (`once update`, health wait, checks) | ~18 s |
| `finish` | < 1 s |

So roughly **90 seconds** of frozen writes on a small database. The rehearsal and
the archives both scale with database size, and the snapshot wait scales with how
much of the boot disk has changed since the previous snapshot. Budget more for a
production-sized database, and use `skip_snapshot` only when a recent snapshot
already exists.

### When it does not complete

The recovery step runs on failure, cancellation and timeout alike, with one
deliberate exception: exit `20` — healthy, but a read-only check failed — leaves
the running application alone, because recovery begins by stopping it and a
reporting failure should not become an outage.

Recovery never writes to the database, and never downgrades an application that is
still healthy on the new image. Otherwise it restores the previous image and gets it
serving; the job summary then says plainly whether the database was left as it was
and an operator has to decide. The frozen checkpoint, the boot-disk snapshot and
the `campfire-rollback:before-<label>` image all stay on the host.

## ONCE 0.3.2 behaviour worth knowing

- `once update <host> --image …` **starts a stopped application**, so the freeze/cutover
  sequence does not need a separate `once start`. The script still checks and starts it
  if ONCE ever changes that.
- `once update --image` fails immediately with "Failed to download the application
  image" when Docker is not authenticated to the private registry. That is an auth
  error, not a bad reference.
- **`once update --image` always resolves the reference through a registry**, so it
  cannot use a local-only tag: passing `campfire-rollback:before-<label>` fails with
  the same "Failed to download the application image" message even though the image is
  present in the local Docker cache. The rollback therefore uses the previous image's
  own registry reference, and tries a plain `once start` first when the container left
  on the host still carries it. `campfire-rollback:before-<label>` is retained as an
  operator artifact — the exact bits survive locally even if the registry is
  unavailable — not as something ONCE can be pointed at directly.
- **ONCE keeps no state on disk.** Its configuration *is* the `once` label on the
  application container; there is no `/var/lib/once` or equivalent. That is why the
  rollback cannot simply trust the label it finds: an `once update` that failed after
  rewriting it leaves a host whose only container claims the previous image while ONCE
  itself points at the candidate, so a local `once start` would boot the broken image.
  The script starts it and then verifies what actually came up.
- `once backup` succeeds while the application is stopped, but the in-container
  pre-backup hook cannot run, so the archive contains the raw volume rather than a
  `data/backups/production.sqlite3` snapshot. With the app cleanly stopped the raw copy
  is coherent; the separate backup-API snapshot is taken just before the stop so the
  rehearsal has a known-good `before`.
- ONCE gives the replacement container a new random name suffix on every update, so the
  container must be rediscovered after the cutover. The script selects it by matching
  the ONCE label's `.image` against the exact reference it deployed rather than taking
  whichever container is listed first. The Docker volume name is stable.
- The volume is mounted at both `/storage` and `/rails/storage`.
- The image has no `ps`; use `docker top <container> -eo pid,args` from the host.
- `once list` writes ANSI colour and OSC-8 hyperlink escapes around the host name, so
  discovery reads the container label instead of parsing that output.
