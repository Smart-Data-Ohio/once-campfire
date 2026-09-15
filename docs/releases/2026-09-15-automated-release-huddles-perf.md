# Automated release — September 15, 2026

Huddle theater mode, screen-share cycling, microphone noise suppression, and the message rendering and caching improvements are live at https://chat.smartdata.net. Refresh an existing page to load the new controls. This was the first production release performed end to end by the automated path; every earlier release, including [the Activity workspace release](2026-09-15-activity-workspace.md), was carried out by hand.

## Release identity

- Application source: `ba6a3b3eca9385bdc2e51649ecf020fd3ecf4f9c` (the merge of PR #3 on `main`).
- Image: `us-central1-docker.pkg.dev/smart-data-campfire/campfire/app@sha256:cdb8ba0b2383d45fdbe6bd02124994f4822488e3124ce380af5af1a93f072204`, published as tag `git-ba6a3b3eca9385bdc2e51649ecf020fd3ecf4f9c` by [Publish image to Artifact Registry](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35026153923).
- Previous image: `us-central1-docker.pkg.dev/smart-data-campfire/campfire/app@sha256:b834373eb31d3eab7de13e2d59b546ad741ca8f483ca8ef2858e5a45dbed9144`.
- Released by the [Deploy to GCP](../../.github/workflows/deploy-gcp.yml) workflow, [run 35028923137](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35028923137), in the `production` environment and approved in that environment's gate. Release label `20260915-ba6a3b3-35028923137`.
- The existing ONCE application and storage volume were upgraded in place with `once update chat.smartdata.net --image …@sha256:cdb8… --auto-update=false`. `--env` was omitted, so ONCE kept the whole existing environment map. Automatic upstream updates remain disabled.

## What shipped

Relative to the previous production image:

- PR #4 — huddle theater/fullscreen mode, screen-share cycling, RNNoise noise suppression, and screen-share audio and encoding fixes.
- PR #5 — message rendering preloads, `fresh_when` before the rendering work, immutable asset cache headers, and YJIT for the web process.
- PR #3 — the CI/CD pipeline and release automation used to perform this release.
- PR #2 — the design document for the first agent-identity slice.

## Validation

[CI for this revision](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35026153901) passed. A production deployment additionally requires the revision to be an ancestor of `origin/main` and a green `CI` run for that exact revision.

The same revision and image were first released to a throwaway validation VM ([run 35027600258](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35027600258)), and a production dry run ([run 35028275312](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35028275312)) preceded the real release. The validation VM was deleted afterwards.

While writes were frozen, the candidate image migrated a copy of the frozen database in an isolated container. The rehearsal recorded `PASSED: 28 preexisting tables preserved; 0 tables, 0 columns`: this release changes no schema.

The read-only checks after the cutover passed: the running digest, the storage volume `once-app-once-campfire.b18a37` unchanged, the environment keys `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_GATEWAY_SECRET`, `LIVEKIT_INTERNAL_URL`, `LIVEKIT_URL` and `WEB_CONCURRENCY` preserved (names only), all 19 pre-existing uploaded files unchanged, and puma, resque-pool and the huddle reconciler present. The Open Roles feed timer `campfire-open-roles.timer` was restored to enabled and active, and the temporary registry credentials were removed from the VM.

## Timeline

All times UTC.

| Time | Step |
| --- | --- |
| 22:07:58 | Application stopped; writes frozen. |
| 22:08:01–22:08:11 | Migration rehearsal on a database copy inside the candidate image. |
| before 22:09:05 | Boot-disk snapshot reached `READY`. |
| 22:09:05 | `once update` to the pinned digest. |
| 22:09:22 | New container `once-app-once-campfire.b18a37-6b2957` returned health 200. |
| 22:09:26 | Writes reopened. |

Writes were frozen for 88 seconds; user-facing unavailability was about 84 seconds.

## Recovery checkpoints

- Release state directory on the app VM: `/var/backups/campfire-20260915-ba6a3b3-35028923137`, holding `before.sqlite3`, `after.sqlite3`, `before.once.tar.gz`, `before-host.tar.gz`, the attachment hashes, the filtered settings, the recorded feed timer state, the per-phase result JSON files, and `migration-verification.txt`. Treat its contents as secret: they contain user data and application keys.
- Boot-disk snapshot taken while writes were frozen: `campfire-before-20260915-ba6a3b3-35028923137-r35028923137`, verified `READY` before the cutover.
- Retained previous image tag: `campfire-rollback:before-20260915-ba6a3b3-35028923137`.

## Memory after the release

On the 2 GB app VM, which has no swap: the application container used 497 MiB. The puma master held 165 MB RSS, its worker 161 MB, the huddle reconciler 154 MB, the resque-pool master 151 MB, and the resque worker 121 MB, with 868 MB available. YJIT is now enabled for the web process only. Adding swap on this VM is recommended as insurance and remains a follow-up.

Chat has reopened. A rollback restores the frozen checkpoint only when the live database still hashes to the fingerprint taken at the freeze; if anything has been written since, the previous image is restored and the newer writes are preserved rather than discarded, and an operator decides what happens next. See [the automated release pipeline](../../deploy/gcp/README.md) and [the deployment procedure](../../deploy/README.md).
