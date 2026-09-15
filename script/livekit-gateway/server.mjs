#!/usr/bin/env node

import { createGateway } from "./gateway.mjs";

const gateway = createGateway({
  listenHost: "127.0.0.1",
  listenPort: process.env.LIVEKIT_GATEWAY_PORT ?? 7883,
  campfireUrl: process.env.GATEWAY_CAMPFIRE_URL ?? "http://127.0.0.1:3000",
  internalUrl: process.env.LIVEKIT_INTERNAL_URL ?? "http://127.0.0.1:7880",
  gatewaySecret: process.env.LIVEKIT_GATEWAY_SECRET,
  livekitApiKey: process.env.LIVEKIT_API_KEY,
  livekitApiSecret: process.env.LIVEKIT_API_SECRET,
  onFatal: () => {
    console.error("LiveKit authorization enforcement failed; stopping supervised runtime");
    process.exitCode = 1;
    setImmediate(() => process.exit(1));
  },
});

const shutdown = async () => {
  await gateway.close();
  process.exit(0);
};

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);

try {
  const address = await gateway.start();
  console.log(`LiveKit authorization gateway listening on ${address.address}:${address.port}`);
} catch {
  console.error("LiveKit authorization gateway failed to start");
  process.exit(1);
}
