# Huddles with local LiveKit

Campfire huddles use a project-local LiveKit Server for development. The setup is pinned to LiveKit Server v1.13.7 for Linux amd64 and does not need root, Docker, or a global install.

## Start it

From the Campfire checkout:

```sh
bin/livekit-local setup
bin/livekit-local start
```

`start` runs LiveKit in the foreground. It is safe to use `start` directly because it repeats the setup checks without replacing existing credentials. In another terminal, verify readiness with:

```sh
bin/livekit-local status
```

Setup stores the binary, archive, config, and credentials under the git-ignored `.bundle/livekit/` directory. Source the generated mode-600 environment file before starting Campfire or running integration tests:

```sh
source .bundle/livekit/env
```

It exports `LIVEKIT_URL=ws://127.0.0.1:7880` and locally generated `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` values. Do not copy these development credentials to a deployed environment.

Keep LiveKit running in the first terminal. In a second terminal, load its environment and start Campfire:

```sh
source .bundle/livekit/env
bin/dev
```

This prepared checkout also provides `.bundle/dev` as a native Redis and Campfire launcher, so it can replace `bin/dev` in that second terminal. To run the real huddle system test against local LiveKit with synthetic browser media:

```sh
source .bundle/livekit/env
LIVEKIT_SYSTEM_TESTS=1 PARALLEL_WORKERS=1 bin/rails test test/system/huddles_test.rb
```

Campfire serves a checked-in LiveKit browser bundle. See the [browser SDK rebuild guide](../script/livekit-client/README.md) when updating its pinned version.

## Behavior and access control

Channel members can join voice huddles, mute, see participants and speaking state, and share a screen. The panel stays connected when following Campfire's channel links. Leaving stops local media and removes remote media elements. Denied microphone access leaves no connected participant and can be retried. Direct-message rooms have no huddle button.

Campfire issues room-scoped tokens only to active, signed-in human members. Tokens allow microphone and screen publishing, with no camera, data, or administration grants. Join tokens expire after two minutes; participant identities are scoped to individual sign-in sessions and room names are opaque. The API response is not cacheable and the browser bundle is served locally.

Membership removal, sign-out, account ban/deactivation, and room deletion enqueue server cleanup after the database commits. The normal job worker must be running: participant cleanup removes the corresponding sessions, and room cleanup ends the deleted room. Failed server requests retry up to ten times. The browser also checks access every 45 seconds and when its tab becomes visible.

**Self-hosted token limitation:** removing an active participant does not invalidate an already-issued JWT. A modified client holding a valid token can rejoin directly even though Campfire refuses to issue another token after access is revoked. LiveKit also refreshes tokens during a connection, so the two-minute initial TTL is not a hard upper bound on this risk. This implementation does not promise immediate, permanent exclusion of a hostile client. A public rollout requiring that guarantee needs additional server enforcement. See LiveKit's [self-hosted token lifecycle documentation](https://docs.livekit.io/frontends/reference/tokens-grants/#self-hosted-deployments).

The system suite runs two headless browsers against the real server with synthetic microphone and screen content. It checks received audio/video bytes, decoded screen video, channel navigation without a new connection, mute state, media cleanup, permission-denial retry, and server-initiated participant removal. It does not capture the operator's desktop or use their physical microphone.

The local server listens only on loopback: signaling/API on TCP 7880 and WebRTC UDP mux on UDP 7882. Embedded TURN is disabled. This is suitable for one-machine development and browser tests, but another computer cannot join it.

ICE/TCP 7881 is disabled locally because LiveKit Server v1.13.7 always opens that listener on every host interface, even when `bind_addresses` contains only `127.0.0.1`. The loopback UDP path is sufficient for same-machine development. A deployed pilot should enable TCP 7881 behind a host or cloud firewall as part of its public network configuration.

## Pinned release

The installer downloads the [official LiveKit Server v1.13.7 release](https://github.com/livekit/livekit/releases/tag/v1.13.7) and verifies `livekit_1.13.7_linux_amd64.tar.gz` against the release's [official checksum manifest](https://github.com/livekit/livekit/releases/download/v1.13.7/checksums.txt):

```text
6634aeeb2fb1366b6723708ae4320b9d5408106a4c63457c5e845ae3979c90e2
```

If a cached archive fails verification, setup stops instead of executing it. Remove only the named bad archive and rerun setup to download a clean copy.

## Moving to a two-machine pilot

The existing deployment target is GCP project `smart-data-campfire`, VM `campfire`, zone `us-central1-a`; this local setup does not change it. A pilot that allows people on separate computers needs a public `wss://` endpoint with a trusted TLS certificate, direct UDP reachability, the configured ICE/TCP and UDP ports opened in the cloud firewall, and a public IP that LiveKit can advertise. If LiveKit later runs in a container, use host networking, as recommended by LiveKit.

Corporate and restrictive networks may also require TURN/TLS, normally with its own domain and certificate. The loopback setup deliberately provides no HTTPS, public ICE candidates, firewall rules, or TURN relay, so it does not prove that two-machine connectivity will work.

See LiveKit's official [ports and firewall reference](https://docs.livekit.io/transport/self-hosting/ports-firewall/) and [deployment guide](https://docs.livekit.io/transport/self-hosting/deployment/) before exposing a server.
