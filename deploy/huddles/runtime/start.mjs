#!/usr/bin/env node

import { writeFile } from "node:fs/promises";
import net from "node:net";
import { supervise } from "./supervisor.mjs";

const CONFIG_PATH = "/run/campfire-huddles/livekit.yaml";

function required(name, minimum = 1, environment = process.env) {
  const value = environment[name];
  if (!value || value.length < minimum || /[\r\n\0]/.test(value)) {
    throw new Error(`${name} is missing or invalid`);
  }
  return value;
}

function privateIPv4(name, environment = process.env) {
  const value = required(name, 1, environment);
  if (net.isIP(value) !== 4) throw new Error(`${name} must be an IPv4 address`);
  const octets = value.split(".").map(Number);
  const isPrivate = octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
  if (!isPrivate) throw new Error(`${name} must be an RFC 1918 private address`);
  return value;
}

function domain(name, environment = process.env) {
  const value = required(name, 1, environment);
  if (value.length > 253 || !/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(value)) {
    throw new Error(`${name} must be a lowercase DNS hostname`);
  }
  return value;
}

export function renderLiveKitConfig(environment = process.env) {
  const mediaInternalIp = privateIPv4("MEDIA_INTERNAL_IP", environment);
  const apiKey = required("LIVEKIT_API_KEY", 16, environment);
  const apiSecret = required("LIVEKIT_API_SECRET", 32, environment);
  const turnDomain = domain("TURN_DOMAIN", environment);

  return [
    "port: 7880",
    "bind_addresses:",
    '  - "127.0.0.1"',
    `  - ${JSON.stringify(mediaInternalIp)}`,
    "rtc:",
    "  tcp_port: 7881",
    "  udp_port: 7882",
    "  use_external_ip: true",
    "turn:",
    "  enabled: true",
    `  domain: ${JSON.stringify(turnDomain)}`,
    "  external_tls: true",
    "  tls_port: 5349",
    "  udp_port: 0",
    "  relay_range_start: 30000",
    "  relay_range_end: 30100",
    "  bind_addresses:",
    '    - "0.0.0.0"',
    "  proxy_protocol: true",
    "  proxy_protocol_trusted_cidrs:",
    '    - "127.0.0.0/8"',
    '    - "::1/128"',
    "keys:",
    `  ${JSON.stringify(apiKey)}: ${JSON.stringify(apiSecret)}`,
    "logging:",
    "  level: info",
    "  pion_level: error",
    "  json: true",
    "",
  ].join("\n");
}

async function main() {
  required("LIVEKIT_GATEWAY_SECRET", 16);
  required("GATEWAY_CAMPFIRE_URL");
  required("LIVEKIT_INTERNAL_URL");
  required("LIVEKIT_GATEWAY_PORT");
  domain("HUDDLES_DOMAIN");

  const config = renderLiveKitConfig();
  await writeFile(CONFIG_PATH, config, { encoding: "utf8", mode: 0o600, flag: "wx" });

  const code = await supervise([
    {
      name: "LiveKit",
      command: "/usr/local/bin/livekit-server",
      args: ["--config", CONFIG_PATH],
      env: process.env,
    },
    {
      name: "authorization gateway",
      command: process.execPath,
      args: ["/opt/campfire-huddles/gateway/server.mjs"],
      cwd: "/opt/campfire-huddles/gateway",
      env: process.env,
    },
  ]);
  process.exitCode = code;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch((error) => {
    console.error(`Media runtime failed to start: ${error.message}`);
    process.exitCode = 1;
  });
}
