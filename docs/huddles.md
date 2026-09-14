# Huddles with local LiveKit

Campfire huddles use a project-local LiveKit Server for development. The setup is pinned to LiveKit Server v1.13.7 for Linux amd64 and does not need root, Docker, or a global install.

## Start it

From the Campfire checkout:

```sh
bin/livekit-local setup
bin/livekit-local serve
```

`serve` is the normal way to run the huddle infrastructure. It keeps the private LiveKit server, the authorization gateway, and durable cleanup reconciliation in one foreground process. If any one of them exits, it stops the others. This prevents media from continuing after the gateway can no longer enforce access.

In another terminal, verify both endpoints:

```sh
bin/livekit-local status
bin/livekit-local gateway-status
```

Setup stores the binary, archive, config, and credentials under the git-ignored `.bundle/livekit/` directory. Source the generated mode-600 environment file before starting Campfire or running integration tests:

```sh
source .bundle/livekit/env
```

It exports the public `LIVEKIT_URL=ws://127.0.0.1:7883`, the private `LIVEKIT_INTERNAL_URL=http://127.0.0.1:7880`, and locally generated API and gateway secrets. Running setup again migrates an older local environment to this layout while preserving its existing LiveKit API key and secret. Setup never prints secret values. Do not copy these development credentials to a deployed environment.

Keep `serve` running in the first terminal. In a second terminal, load its environment and start Campfire:

```sh
source .bundle/livekit/env
bin/dev
```

This prepared checkout also provides `.bundle/dev` as a native Redis and Campfire launcher, so it can replace `bin/dev` in that second terminal. To run the real huddle system test against local LiveKit with synthetic browser media:

```sh
source .bundle/livekit/env
LIVEKIT_SYSTEM_TESTS=1 PARALLEL_WORKERS=1 bin/rails test test/system/huddles_test.rb
```

The test suite starts its own gateway on port 7884. The `start` and `gateway` commands run the private server or gateway separately for that kind of controlled test and for diagnosis. They are not safe substitutes for `serve` in normal operation because a separately launched LiveKit process can outlive gateway enforcement.

Campfire serves a checked-in LiveKit browser bundle. See the [browser SDK rebuild guide](../script/livekit-client/README.md) when updating its pinned version.

## Behavior and access control

Channel members can join voice huddles, mute, see participants and speaking state, and share a screen. The panel stays connected when following Campfire's channel links. Leaving stops local media and removes remote media elements. Denied microphone access leaves no connected participant and can be retried. Direct-message rooms have no huddle button.

Campfire issues room-scoped tokens only to active, signed-in human members. Tokens allow microphone and screen publishing, with no camera, data, or administration grants. Join tokens expire after two minutes; participant identities are scoped to individual sign-in sessions and room names are opaque. The API response is not cacheable and the browser bundle is served locally.

Membership removal, sign-out, account ban or deactivation, and room deletion persist revocation and cleanup work in the same database transaction. Queue delivery starts after commit. The normal job worker handles prompt cleanup, while the reconciler recovers work after enqueue failures, worker restarts, and temporary LiveKit outages.

All original joins and LiveKit reconnects pass through the gateway. It checks the current database grant before contacting LiveKit, holds the first upstream signal, checks again, and then checks once per second while the grant has a signaling connection or is in its reconnect window. A saved original or server-refreshed token cannot bypass a revoked database grant.

When signaling closes normally, the gateway retains the grant for a three-second reconnect window. A valid reconnect cancels the pending cleanup. Grant checks continue during those three seconds, so a revocation or Campfire outage still starts removal immediately. If no reconnect arrives, the gateway removes the participant because WebRTC media can outlive the signaling socket.

Participant removal retries after a temporary LiveKit administration failure. If removal still cannot be confirmed after ten seconds, the gateway exits unsuccessfully. `serve` then stops LiveKit, interrupting every call on that local server rather than allowing media whose authorization cannot be enforced. See the [authorization boundary and acceptance checks](huddle-enforcement.md) for the full failure model.

The system suite runs two headless browsers against the real server with synthetic microphone and screen content. It checks received audio/video bytes, decoded screen video, channel navigation without a new connection, mute state, media cleanup, permission-denial retry, and server-initiated participant removal. It also checks actual SDK reconnects with server-refreshed tokens and rejection of saved tokens after membership or session revocation. It does not capture the operator's desktop or use their physical microphone.

The local gateway listens on loopback TCP 7883. LiveKit's raw signaling and administration API listens on loopback TCP 7880, and the WebRTC UDP mux uses UDP 7882. The raw endpoint must remain private because reaching it directly bypasses admission checks. Embedded TURN is disabled. This is suitable for one-machine development and browser tests, but another computer cannot join it.

ICE/TCP 7881 is disabled locally because LiveKit Server v1.13.7 always opens that listener on every host interface, even when `bind_addresses` contains only `127.0.0.1`. The loopback UDP path is sufficient for same-machine development. A deployed pilot should enable TCP 7881 behind a host or cloud firewall as part of its public network configuration.

## Pinned release

The installer downloads the [official LiveKit Server v1.13.7 release](https://github.com/livekit/livekit/releases/tag/v1.13.7) and verifies `livekit_1.13.7_linux_amd64.tar.gz` against the release's [official checksum manifest](https://github.com/livekit/livekit/releases/download/v1.13.7/checksums.txt):

```text
6634aeeb2fb1366b6723708ae4320b9d5408106a4c63457c5e845ae3979c90e2
```

If a cached archive fails verification, setup stops instead of executing it. Remove only the named bad archive and rerun setup to download a clean copy.

## Moving to a two-machine pilot

The existing deployment target is GCP project `smart-data-campfire`, VM `campfire`, zone `us-central1-a`; this local setup does not change it. A pilot that allows people on separate computers needs the authorization gateway at the public `wss://` endpoint with a trusted TLS certificate. Raw LiveKit signaling and administration must remain private, and LiveKit and the gateway must run under one supervisor. The pilot also needs direct UDP reachability, the configured ICE/TCP and UDP ports opened in the cloud firewall, and a public IP that LiveKit can advertise. If LiveKit later runs in a container, use host networking, as recommended by LiveKit.

Corporate and restrictive networks may also require TURN/TLS, normally with its own domain and certificate. The loopback setup deliberately provides no HTTPS, public ICE candidates, firewall rules, or TURN relay, so it does not prove that two-machine connectivity will work.

See LiveKit's official [ports and firewall reference](https://docs.livekit.io/transport/self-hosting/ports-firewall/) and [deployment guide](https://docs.livekit.io/transport/self-hosting/deployment/) before exposing a server.

The [audio and video quality assessment](huddle-quality.md) records the next pilot and product decisions.
