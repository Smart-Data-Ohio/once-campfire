# Production huddle media host

This package runs the Campfire authorization gateway and LiveKit Server v1.13.7 in one fail-closed media container. If either process exits, the supervisor terminates the other within five seconds and exits unsuccessfully. A separate Caddy L4 container obtains trusted certificates and routes TLS by hostname:

- `huddles.chat.smartdata.net:443` to the authorization gateway on loopback port 7883
- `turn.chat.smartdata.net:443` to embedded TURN/TLS by dialing `127.0.0.1:5349`

The media container uses host networking, as recommended for LiveKit. Raw LiveKit signaling and administration bind only to loopback and the media VM's RFC 1918 address. The public hostname never reaches raw LiveKit.

## Network contract

The current production addresses are:

- Campfire app VM: `10.128.0.2`
- Huddle media VM: `10.128.0.3`
- Huddle media public IP: `34.133.15.79`

Point both public hostnames at `34.133.15.79` before starting Caddy. Apply these ingress rules to the media VM:

| Protocol and port | Allowed source | Purpose |
| --- | --- | --- |
| TCP 80, 443 | Public | Certificate issuance, WSS, and TURN/TLS |
| TCP 7881 | Public | Direct ICE/TCP media fallback |
| UDP 7882 | Public | Direct ICE/UDP mux, the preferred media path |
| UDP 30000-30100 | Public | Bounded embedded TURN relay allocations |
| TCP 7880 | `10.128.0.2/32` and local host | Private LiveKit administration from Campfire |

Do not allow public ingress to TCP 7880, 7883, or 5349. Allow TCP 7880 only from the app VM, and deny TCP 5349 from every remote source, including other VPC hosts; Caddy reaches it locally. Port 7883 bypasses TLS, while direct access to 7880 bypasses current-membership enforcement. TURN/UDP 3478 is disabled; restrictive clients use TURN/TLS on public TCP 443. The relay UDP range is still required because the TURN/TLS connection carries allocation traffic over TCP while the embedded relay sends and receives media on its allocated UDP port.

LiveKit uses one `turn.bind_addresses` setting for both its TCP listener and its UDP relay sockets, so the generated configuration binds those TURN sockets to `0.0.0.0`. The cloud and host firewalls provide the TCP 5349 boundary; only UDP 30000-30100 is allowed remotely for relay media.

## Secrets

Create fresh production values on the media VM without printing them:

```sh
sudo install -d -m 0700 /etc/campfire-huddles
sudo sh -c 'umask 077
cat > /etc/campfire-huddles/env <<EOF
MEDIA_INTERNAL_IP=10.128.0.3
LIVEKIT_API_KEY=$(openssl rand -hex 16)
LIVEKIT_API_SECRET=$(openssl rand -hex 32)
LIVEKIT_GATEWAY_SECRET=$(openssl rand -hex 32)
EOF'
sudo chmod 0600 /etc/campfire-huddles/env
```

Copy the three generated secret values through a protected administrator channel to the Campfire app VM. Configure the app with exactly these settings:

```text
LIVEKIT_URL=wss://huddles.chat.smartdata.net
LIVEKIT_INTERNAL_URL=http://10.128.0.3:7880
LIVEKIT_API_KEY=<same value as media host>
LIVEKIT_API_SECRET=<same value as media host>
LIVEKIT_GATEWAY_SECRET=<same value as media host>
```

The gateway callback is fixed inside the deployment package as `https://chat.smartdata.net`. Never copy credentials from `.bundle/livekit`; those belong only to local development.

## Start and update

From the Campfire repository on the media VM:

```sh
sudo docker compose -f deploy/huddles/compose.yaml config --quiet
sudo docker compose -f deploy/huddles/compose.yaml build --pull media
sudo docker compose -f deploy/huddles/compose.yaml pull caddy
sudo docker compose -f deploy/huddles/compose.yaml up -d
sudo docker compose -f deploy/huddles/compose.yaml ps
```

The image references are pinned to the inspected multi-architecture digests. Reinspect and deliberately update those digests when upgrading Node, LiveKit, or Caddy.

## Verify the boundary

Wait for both DNS records and trusted certificates, then check:

```sh
sudo docker compose -f deploy/huddles/compose.yaml ps
sudo docker compose -f deploy/huddles/compose.yaml logs --tail=100 media caddy
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://huddles.chat.smartdata.net/rtc/validate
openssl s_client -connect turn.chat.smartdata.net:443 -servername turn.chat.smartdata.net </dev/null
```

The tokenless validation request should return HTTP 401 from the gateway; that status is expected and confirms unauthorized validation is rejected. The TLS check must show a trusted certificate for the TURN hostname.

From the app VM, private TCP 7880 must connect. From an unrelated external host, TCP 7880 and 7883 must time out or be rejected. Complete the acceptance check with two browsers on separate networks: verify normal audio over direct UDP, then force relay-only ICE and verify audio over TURN/TLS. Finally, revoke one participant while the other remains connected and confirm the removed participant loses media.

LiveKit's [deployment guide](https://docs.livekit.io/transport/self-hosting/deployment/) describes the trusted-domain, separate TURN certificate, host-networking, and public media-port requirements. Its [port reference](https://docs.livekit.io/transport/self-hosting/ports-firewall/) identifies raw 7880 as private, 7881 and 7882 as public ICE transports, and the TURN listeners. The pinned [v1.13.7 configuration](https://github.com/livekit/livekit/blob/v1.13.7/config-sample.yaml) documents external TLS and PROXY protocol; [Caddy L4's proxy handler](https://github.com/mholt/caddy-l4/blob/master/docs/handlers/proxy.md) documents the emitted PROXY v2 header used here.

## Package checks

Run these before publishing a deployment change:

```sh
node --test deploy/huddles/runtime/*.test.mjs
HUDDLES_ENV_FILE="$PWD/deploy/huddles/env.example" docker compose -f deploy/huddles/compose.yaml config --quiet
docker build -f deploy/huddles/Dockerfile -t campfire-huddles-media:test .
```

For an exact LiveKit parse and port check, start a temporary media container with the example file replaced by syntactically valid nonproduction test secrets and run `livekit-server ports --config` against its generated mode-0600 configuration.
