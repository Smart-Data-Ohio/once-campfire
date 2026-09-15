# Smart Data Campfire release procedure

The existing app remains an ONCE deployment on `campfire` in GCP project `smart-data-campfire`, zone `us-central1-a`. Its hostname is `chat.smartdata.net`. Update that deployment in place so its storage volume, account, users, messages, uploaded files, session signing key, and web-push keys remain attached.

The separate [Huddles media package](huddles/README.md) runs on `campfire-huddles` in the same zone. It is independent of the app's database. This separates resource usage and maintenance; it does not provide zone redundancy. The anticipated workspace size is about 135 users. Concurrent call participants and screen-share traffic need separate capacity testing; the initial two-CPU/eight-GiB media host is a pilot size, not a demonstrated 135-participant capacity.

## Automated path

The steps below are now automated by two GitHub Actions workflows that authenticate to GCP through Workload Identity Federation, with no long-lived key on either VM:

- **Publish image to Artifact Registry** (`.github/workflows/publish-gcp-image.yml`) builds the committed source for `linux/amd64` on every push to `main` and every `v*` tag, pushes it as `git-<full source sha>`, and attests its provenance.
- **Deploy to GCP** (`.github/workflows/deploy-gcp.yml`) is run by hand for a chosen source revision and environment. It resolves that tag to a digest and runs [`deploy/gcp/campfire-release.sh`](gcp/README.md) on the app VM over an IAP SSH tunnel, in phases: preflight, write freeze and backup, boot-disk snapshot, cutover with full preservation checks, and finish. A failed cutover rolls back automatically and leaves the feed timer paused. Its job summary contains a paste-ready release record for `docs/releases/`.

Deploying to `production` requires the revision to be an ancestor of `origin/main`, a successful `CI` run for that exact sha, and an environment reviewer's approval. Start with `dry_run=true`, which stops after preflight and prints the plan.

Read [deploy/gcp/README.md](gcp/README.md) for the phase-by-phase contract and the release record layout. **The manual procedure below remains the authority on why each step exists, and is the procedure to follow by hand whenever the pipeline is unavailable.** Keep the two in step: a change to the cutover here is a change to the script.

## Candidate image

Build the committed source with Docker BuildKit. The app Dockerfile uses `COPY --chmod`, so Docker's legacy builder cannot complete it. Store verified images in the private Artifact Registry repository:

```text
us-central1-docker.pkg.dev/smart-data-campfire/campfire/app
```

Repository tags are immutable. Use a unique tag containing the full source revision, and deploy its resolved `sha256` digest. Record the source revision, image digest, and validation results together. The GCP registry is the delivery route; GHCR is not. Because tags cannot be moved, re-publishing an already-released revision resolves the existing digest instead of rebuilding over it.

The VMs have no runtime GCP service account. An authorized operator supplies a short-lived registry credential for a pull or push through protected standard input. Do not copy a long-lived service-account key onto either VM. Docker can restart an already-pulled container without renewing that credential. Future releases require fresh registry authentication.

## Backup and rehearsal

1. Run `once backup chat.smartdata.net <protected-backup-path>` on the app VM. ONCE stores application settings and keys alongside storage. Its Campfire pre-backup hook uses SQLite's backup API to write the consistent database snapshot at `data/backups/production.sqlite3` in the archive.
2. Keep a verified off-machine copy. Treat the entire archive as secret because it contains user data and application keys.
3. Separately preserve `/opt/campfire-open-roles`, `/etc/campfire-open-roles`, its systemd service and timer, and a SQLite backup of `/var/lib/campfire-open-roles/state.sqlite3`. The ONCE application archive does not include these host paths.
4. Extract an isolated copy and retain an untouched `before.sqlite3` snapshot. Execute the candidate image's `/hooks/post-restore`, then `bin/rails db:migrate` against only the copy, with network access disabled.
5. Run `bundle exec script/admin/verify-additive-sqlite-migration BEFORE.sqlite3 AFTER.sqlite3`. Require exit zero and every preexisting table's schema and row data to match. This checks all old typed values, rather than counts alone. Separately compare every uploaded file's contents.
6. Boot the candidate against the copy with a fresh empty Redis queue and no external network. Verify app health, the configured huddle reconciler, and memory usage. Never execute copied production background jobs during the rehearsal.

The feature migrations add huddle grants and cleanup records, a nullable Markdown source column, workspace presence leases, channel threads, thread memberships, and nullable message conversation references. They do not rewrite existing message bodies. SQLite may renumber foreign-key IDs when adding a constraint; the verifier compares complete constraint definitions while preserving their column order and referential actions.

## Public media acceptance

Wait for both Huddles DNS records and valid certificates. Check public WSS, direct media, forced TURN/TLS relay, and revocation with isolated test accounts. The optional browser test topology is documented in [the Huddles guide](../docs/huddles.md). Do not point the fixture test runner at the live app database.

Before cutover, replace all rehearsal media credentials with the separately generated production values, point the gateway callback to `https://chat.smartdata.net`, and close the temporary SSH forwards. The app receives the same production API/gateway secrets and uses the private API URL `http://10.128.0.3:7880`.

## Cutover and rollback

1. Authenticate Docker for the private registry and pull the exact candidate digest before interrupting chat.
2. Pause the Open Roles timer, wait for any current feed run to finish, and stop the existing ONCE app for a short write freeze. Take a fresh coherent backup of app storage, settings/keys, and feed delivery state. Retain the old image locally and take a fresh boot-disk snapshot while writes are stopped.
3. Update the **existing** `chat.smartdata.net` ONCE application with the pinned image and `--auto-update=false`. For an image-only upgrade, omit `--env` to preserve its configured environment, including the five production LiveKit values and web-worker limit. ONCE 0.3.2 replaces the entire environment map when `--env` is supplied; any intentional environment change must therefore include all existing settings. Keep the same application identity and volume. Do not deploy a fresh application or restore over the live volume as an upgrade method.
4. Check schema migration success, preserved business records and uploaded files, signing/web-push key equality, health, assets, gateway authorization, and the running huddle reconciler. Set and test an explicit web-worker count suited to the chat VM's memory; do not assume a build VM's capacity is available on the app VM.
5. Resume the Open Roles timer only after validation. Record the exact image digest and backup paths.

ONCE starts a replacement container before retiring the prior one. The explicit write freeze prevents two app versions from writing the same SQLite database during migrations. Disable automatic upstream image updates because this is a maintained fork.

If rollback is needed before accepting new writes, stop the app and restore the coherent checkpoint with its original image and keys. After new writes have been accepted, first preserve them: restoring an older checkpoint by itself would discard those messages and could make the feed repost alerts. Keep the feed's delivery state consistent with the restored message history.
