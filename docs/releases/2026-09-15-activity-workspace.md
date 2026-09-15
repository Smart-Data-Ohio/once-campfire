# Activity workspace release — September 15, 2026

The Activity inbox, human-owned work threads, one-to-one DM Huddles, and neutral gray/charcoal themes are live at https://chat.smartdata.net. Refresh an existing page to load the new controls. The inbox collects new activity from this release onward; existing conversations were not backfilled. See [the feature guide](../activity-workspace.md).

## Release identity

- Application source: `dfebf3fbc781bf60bd4c14b3c4a2fdf9e2751f2b`.
- Image: `us-central1-docker.pkg.dev/smart-data-campfire/campfire/app@sha256:b834373eb31d3eab7de13e2d59b546ad741ca8f483ca8ef2858e5a45dbed9144`.
- Previous application source: `56f6ebdf9c5f90a7252f9aec978dcb33e3154151`.
- The existing ONCE application and storage volume were upgraded in place. Automatic upstream updates remain disabled. The image-only update preserved the full existing environment, session-signing and web-push keys, `WEB_CONCURRENCY=1`, and all production Huddles settings.

## Validation

[CI on the application revision](https://github.com/Smart-Data-Ohio/once-campfire/actions/runs/35001201000) passed the server suite (566 tests, 2,074 assertions, two existing image-library skips), all 46 browser scenarios (723 assertions), lint, security scan, workflow audit, and gateway tests. Both architecture builds and local production asset compilation passed. Browser scenarios included two-party DM audio, decoded screen sharing, navigation, reconnect, leave, work assignment, and opening a work update from another member's inbox.

The exact published image was exported and run locally against a protected fresh production backup in an isolated network namespace. The rehearsal preserved every old typed database value and schema definition across 26 tables, plus all 19 uploaded files. The two migrations added two tables and two nullable columns. Copied production Redis jobs were excluded; app health and required worker/reconciler processes passed.

The same full data and file comparisons passed again on production storage while writes were paused, before reopening chat. The checkpoint contained seven users, 107 messages, 14 rooms, 61 memberships, and 11 sessions. No Huddles were active at cutover.

Authenticated live browser checks confirmed the Activity inbox, Work list, neutral theme, and Join huddle control in an existing two-person DM. Read-only server checks covered source access queries and existing message/thread controls. All 142 referenced local scripts and styles returned HTTP 200. Media-to-app callback authentication passed and unauthorized callbacks were rejected. No production test messages, work items, or calls were created. The Open Roles timer returned to its prior active state, and temporary registry credentials were removed.

One CodeQL diagnostic remains open on the existing LiveKit HS256 signature. It is assessed as a false positive: HMAC-SHA256 signs a short-lived JWT as required by [RFC 7518 section 3.2](https://www.rfc-editor.org/rfc/rfc7518.html#section-3.2); the code does not store passwords. No security query was disabled or alert dismissed. Media capacity has not been load-tested.

## Recovery checkpoints

- Protected coherent app and feed checkpoint on the app VM: `/var/backups/campfire-activity-workspace-20260915`.
- Boot-disk snapshot: `campfire-before-activity-workspace-20260915`, verified `READY` while writes were paused. This snapshot includes the protected checkpoint and live storage on that disk.
- Retained old image tag: `campfire-rollback:before-activity-workspace-20260915`.
- Coherent app archive SHA-256: `cbfaeda209a530b68f360c91779cb571afa534408be9cbe343e2ad55b24ae32a`.
- Coherent host/feed archive SHA-256: `b25847e64324e015f5357599bc265f582ae7c2a2648a8116fe86239fccb2ae70`.

A checksum-verified local copy of the earlier online rehearsal backup exists. Automatic approval review rejected exporting the full final checkpoint to the workstation because it contains production data and keys. That export was not retried; the final checkpoint is retained on the protected app host and in the ready Google Cloud snapshot. Do not describe the rehearsal backup as the coherent cutover backup.

Chat has reopened. Any rollback must first preserve subsequent writes and keep feed delivery state consistent with message history; restoring this checkpoint alone would discard newer activity. Follow the [deployment procedure](../../deploy/README.md).
