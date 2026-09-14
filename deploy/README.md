# Smart Data Campfire release procedure

The existing app remains an ONCE deployment on `campfire` in GCP project `smart-data-campfire`, zone `us-central1-a`. Its hostname is `chat.smartdata.net`. Update that deployment in place so its storage volume, account, users, messages, uploaded files, session signing key, and web-push keys remain attached.

The separate [Huddles media package](huddles/README.md) runs on `campfire-huddles` in the same zone. It is independent of the app's database. This separates resource usage and maintenance; it does not provide zone redundancy. The anticipated workspace size is about 135 users. Concurrent call participants and screen-share traffic need separate capacity testing; the initial two-CPU/eight-GiB media host is a pilot size, not a demonstrated 135-participant capacity.

## Candidate image

Build the committed source with Docker BuildKit. The app Dockerfile uses `COPY --chmod`, so Docker's legacy builder cannot complete it. Store verified images in the private Artifact Registry repository:

```text
us-central1-docker.pkg.dev/smart-data-campfire/campfire/app
```

Repository tags are immutable. Use a unique tag containing the full source revision, and deploy its resolved `sha256` digest. Record the source revision, image digest, and validation results together. The repository's GitHub image workflow was not registered on its default branch at the initial rollout; the GCP registry is the delivery route.

The VMs have no runtime GCP service account. An authorized operator supplies a short-lived registry credential for a pull or push through protected standard input. Do not copy a long-lived service-account key onto either VM. Docker can restart an already-pulled container without renewing that credential. Future releases require fresh registry authentication.

## Backup and rehearsal

1. Run `once backup chat.smartdata.net <protected-backup-path>` on the app VM. ONCE stores application settings and keys alongside storage. Its Campfire pre-backup hook uses SQLite's backup API to write the consistent database snapshot at `data/backups/production.sqlite3` in the archive.
2. Keep a verified off-machine copy. Treat the entire archive as secret because it contains user data and application keys.
3. Separately preserve `/opt/campfire-open-roles`, `/etc/campfire-open-roles`, its systemd service and timer, and a SQLite backup of `/var/lib/campfire-open-roles/state.sqlite3`. The ONCE application archive does not include these host paths.
4. Extract an isolated copy and retain an untouched `before.sqlite3` snapshot. Execute the candidate image's `/hooks/post-restore`, then `bin/rails db:migrate` against only the copy, with network access disabled.
5. Run `bundle exec script/admin/verify-additive-sqlite-migration BEFORE.sqlite3 AFTER.sqlite3`. Require exit zero and every preexisting table's schema and row data to match. This checks all old typed values, rather than counts alone. Separately compare every uploaded file's contents.
6. Boot the candidate against the copy with a fresh empty Redis queue and no external network. Verify app health, the configured huddle reconciler, and memory usage. Never execute copied production background jobs during the rehearsal.

The feature migrations add huddle grants and cleanup records, a nullable Markdown source column, and workspace presence leases. They do not rewrite existing message bodies.

## Public media acceptance

Wait for both Huddles DNS records and valid certificates. Check public WSS, direct media, forced TURN/TLS relay, and revocation with isolated test accounts. The optional browser test topology is documented in [the Huddles guide](../docs/huddles.md). Do not point the fixture test runner at the live app database.

Before cutover, replace all rehearsal media credentials with the separately generated production values, point the gateway callback to `https://chat.smartdata.net`, and close the temporary SSH forwards. The app receives the same production API/gateway secrets and uses the private API URL `http://10.128.0.3:7880`.

## Cutover and rollback

1. Authenticate Docker for the private registry and pull the exact candidate digest before interrupting chat.
2. Pause the Open Roles timer, wait for any current feed run to finish, and stop the existing ONCE app for a short write freeze. Take a fresh coherent backup of app storage, settings/keys, and feed delivery state. Retain the old image locally and take a fresh boot-disk snapshot while writes are stopped.
3. Update the **existing** `chat.smartdata.net` ONCE application with the pinned image, the five production LiveKit environment values, and `--auto-update=false`. Keep the same application identity and volume. Do not deploy a fresh application or restore over the live volume as an upgrade method.
4. Check schema migration success, preserved business records and uploaded files, signing/web-push key equality, health, assets, gateway authorization, and the running huddle reconciler. Set and test an explicit web-worker count suited to the chat VM's memory; do not assume a build VM's capacity is available on the app VM.
5. Resume the Open Roles timer only after validation. Record the exact image digest and backup paths.

ONCE starts a replacement container before retiring the prior one. The explicit write freeze prevents two app versions from writing the same SQLite database during migrations. Disable automatic upstream image updates because this is a maintained fork.

If rollback is needed before accepting new writes, stop the app and restore the coherent checkpoint with its original image and keys. After new writes have been accepted, first preserve them: restoring an older checkpoint by itself would discard those messages and could make the feed repost alerts. Keep the feed's delivery state consistent with the restored message history.
