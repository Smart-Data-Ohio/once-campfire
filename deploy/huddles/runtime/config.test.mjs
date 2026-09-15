import assert from "node:assert/strict";
import test from "node:test";
import { renderLiveKitConfig } from "./start.mjs";

const valid = {
  MEDIA_INTERNAL_IP: "10.128.0.9",
  LIVEKIT_API_KEY: "api-key-which-is-long-enough",
  LIVEKIT_API_SECRET: "api-secret-which-is-more-than-thirty-two-characters",
  TURN_DOMAIN: "turn.chat.smartdata.net",
};

test("renders the private signaling and public media boundary", () => {
  const config = renderLiveKitConfig(valid);

  assert.match(config, /bind_addresses:\n  - "127\.0\.0\.1"\n  - "10\.128\.0\.9"/);
  assert.match(config, /tcp_port: 7881/);
  assert.match(config, /udp_port: 7882/);
  assert.match(config, /tls_port: 5349/);
  assert.match(config, /proxy_protocol: true/);
  assert.match(config, /relay_range_start: 30000/);
  assert.match(config, /"api-key-which-is-long-enough": "api-secret-/);
});

test("refuses to bind raw signaling to a public address", () => {
  assert.throws(
    () => renderLiveKitConfig({ ...valid, MEDIA_INTERNAL_IP: "34.133.15.79" }),
    /RFC 1918 private address/,
  );
});
