import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { once } from "node:events";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { createGateway } from "./gateway.mjs";

const TOKEN = "header.payload.signature";
const GRANT = Object.freeze({ grant_id: 17, room_name: "opaque-room", identity: "opaque-identity" });
const SECRET = "gateway-secret-for-tests";
const API_KEY = "livekit-api-key-for-tests";
const API_SECRET = "livekit-api-secret-for-tests-which-is-long";

function json(response, status, body) {
  const encoded = JSON.stringify(body);
  response.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(encoded) });
  response.end(encoded);
}

async function listen(server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return server.address().port;
}

async function closeServer(server) {
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(() => resolve()));
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function waitFor(predicate, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail("condition was not met before timeout");
}

async function websocketAttempt(url, options = {}) {
  return new Promise((resolve) => {
    const socket = new WebSocket(url, options);
    let settled = false;
    socket.once("open", () => {
      settled = true;
      resolve({ socket, status: 101 });
    });
    socket.once("unexpected-response", (_request, response) => {
      response.resume();
      settled = true;
      resolve({ socket, status: response.statusCode });
    });
    socket.once("error", () => {
      if (!settled) resolve({ socket, status: 0 });
    });
  });
}

async function rawRequest(port, target) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    const chunks = [];
    socket.once("connect", () => {
      socket.write(`GET ${target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`);
    });
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.once("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    socket.once("error", reject);
  });
}

async function createHarness(overrides = {}) {
  const state = {
    authorizeCalls: 0,
    authorizeStatus: 200,
    authorizeHook: null,
    active: true,
    grantCheckStatus: null,
    stallAuthorizeBody: false,
    seenAuthorization: [],
    grantChecks: 0,
    upstreamConnections: 0,
    sendFirstSignal: true,
    upstreamSockets: new Set(),
    removals: [],
    removalHook: null,
    decisions: [],
    fatals: [],
  };

  const campfire = http.createServer(async (request, response) => {
    if (request.method === "POST" && request.url === "/internal/huddle/authorize") {
      state.authorizeCalls += 1;
      state.seenAuthorization.push(request.headers.authorization);
      await readJson(request);
      if (state.authorizeHook) {
        const result = await state.authorizeHook(state.authorizeCalls);
        if (result) return json(response, result.status, result.body ?? {});
      }
      if (state.stallAuthorizeBody) {
        response.writeHead(200, { "content-type": "application/json" });
        response.flushHeaders();
        return;
      }
      return json(response, state.authorizeStatus, state.authorizeStatus === 200 ? GRANT : {});
    }

    const match = request.url?.match(/^\/internal\/huddle\/grants\/([^/?]+)$/);
    if (request.method === "GET" && match) {
      state.grantChecks += 1;
      assert.equal(request.headers["x-huddle-gateway-secret"], SECRET);
      const status = state.grantCheckStatus ?? (state.active ? 200 : 403);
      return json(response, status, status === 200 ? GRANT : {});
    }
    response.writeHead(404).end();
  });
  const campfirePort = await listen(campfire);

  const upstreamWss = new WebSocketServer({ noServer: true });
  const livekit = http.createServer(async (request, response) => {
    if (request.method === "GET" && ["/rtc/validate", "/rtc/v1/validate"].includes(new URL(request.url, "http://local").pathname)) {
      response.writeHead(200, { "content-type": "text/plain" }).end("OK");
      return;
    }
    if (request.method === "POST" && request.url === "/twirp/livekit.RoomService/RemoveParticipant") {
      const removal = { body: await readJson(request), authorization: request.headers.authorization };
      state.removals.push(removal);
      const status = state.removalHook ? await state.removalHook(state.removals.length, removal) : 200;
      return json(response, status ?? 200, {});
    }
    response.writeHead(404).end();
  });
  livekit.on("upgrade", (request, socket, head) => {
    const parsed = new URL(request.url, "http://local");
    if (!["/rtc", "/rtc/v1"].includes(parsed.pathname)) return socket.destroy();
    upstreamWss.handleUpgrade(request, socket, head, (upstream) => {
      state.upstreamConnections += 1;
      state.upstreamSockets.add(upstream);
      upstream.once("close", () => state.upstreamSockets.delete(upstream));
      if (state.sendFirstSignal) upstream.send(Buffer.from("first-signal"));
    });
  });
  const livekitPort = await listen(livekit);

  const gateway = createGateway({
    listenPort: 0,
    campfireUrl: `http://127.0.0.1:${campfirePort}`,
    internalUrl: `http://127.0.0.1:${livekitPort}`,
    gatewaySecret: SECRET,
    livekitApiKey: API_KEY,
    livekitApiSecret: API_SECRET,
    checkIntervalMs: overrides.checkIntervalMs ?? 30,
    requestTimeoutMs: overrides.requestTimeoutMs ?? 100,
    reconnectGraceMs: overrides.reconnectGraceMs ?? 80,
    removalDeadlineMs: overrides.removalDeadlineMs ?? 500,
    onDecision: (decision) => state.decisions.push(decision),
    onFatal: (fatal) => state.fatals.push(fatal),
  });
  const gatewayAddress = await gateway.start();

  return {
    state,
    gateway,
    gatewayPort: gatewayAddress.port,
    async close() {
      await gateway.close();
      for (const socket of state.upstreamSockets) socket.terminate();
      upstreamWss.close();
      await closeServer(campfire);
      await closeServer(livekit);
    },
  };
}

test("rejects a saved token before opening an upstream socket", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  harness.state.authorizeStatus = 403;

  const result = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);

  assert.equal(result.status, 403);
  assert.equal(harness.state.upstreamConnections, 0);
  assert.deepEqual(harness.state.seenAuthorization, [`Bearer ${TOKEN}`]);
});

test("reauthorizes after the first upstream signal and removes a revoked participant before upgrade", async (t) => {
  const harness = await createHarness({ requestTimeoutMs: 500 });
  t.after(() => harness.close());
  let releaseSecond;
  let secondStarted;
  const secondStartedPromise = new Promise((resolve) => { secondStarted = resolve; });
  const releaseSecondPromise = new Promise((resolve) => { releaseSecond = resolve; });
  harness.state.authorizeHook = async (call) => {
    if (call !== 2) return null;
    secondStarted();
    await releaseSecondPromise;
    return { status: 403 };
  };

  const attempt = websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc/v1?access_token=${TOKEN}&reconnect=1`);
  await secondStartedPromise;
  releaseSecond();
  const result = await attempt;

  assert.equal(result.status, 403);
  assert.equal(harness.state.authorizeCalls, 2);
  await waitFor(() => harness.state.removals.length === 1);
  assert.deepEqual(harness.state.removals[0].body, { room: GRANT.room_name, identity: GRANT.identity });
  assert.match(harness.state.removals[0].authorization, /^Bearer [^.]+\.[^.]+\.[^.]+$/);
});

test("periodic denial closes both sockets and triggers participant removal", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const result = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(result.status, 101);
  harness.state.active = false;
  await once(result.socket, "close");

  await waitFor(() => harness.state.removals.length === 1);
  assert.ok(harness.state.grantChecks >= 1);
  assert.equal(harness.state.upstreamSockets.size, 0);
  assert.ok(harness.state.decisions.some(({ type }) => type === "active_grant_denied"));
});

for (const [name, status] of [["revocation", 403], ["backend outage", 503]]) {
  test(`continues grant checks after signaling closes and removes on ${name}`, async (t) => {
    const harness = await createHarness({ reconnectGraceMs: 250 });
    t.after(() => harness.close());
    const result = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
    assert.equal(result.status, 101);
    result.socket.close();
    await once(result.socket, "close");

    harness.state.grantCheckStatus = status;
    await waitFor(() => harness.state.removals.length === 1);

    assert.ok(harness.state.grantChecks >= 1);
    assert.ok(harness.state.decisions.some(({ type }) => type === "active_grant_denied"));
  });
}

test("a reconnect inside the grace period cancels stale participant removal", async (t) => {
  const harness = await createHarness({ reconnectGraceMs: 120 });
  t.after(() => harness.close());
  const first = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(first.status, 101);
  first.socket.close();
  await once(first.socket, "close");

  const second = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}&reconnect=1`);
  assert.equal(second.status, 101);
  await new Promise((resolve) => setTimeout(resolve, 180));

  assert.equal(harness.state.removals.length, 0);
  assert.equal(second.socket.readyState, WebSocket.OPEN);
});

test("a replacement admission waits for an already-started removal", async (t) => {
  const harness = await createHarness({ reconnectGraceMs: 50, requestTimeoutMs: 500 });
  t.after(() => harness.close());
  let releaseRemoval;
  const removalReleased = new Promise((resolve) => { releaseRemoval = resolve; });
  harness.state.removalHook = async () => {
    await removalReleased;
    return 200;
  };

  const first = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(first.status, 101);
  first.socket.close();
  await once(first.socket, "close");
  await waitFor(() => harness.state.removals.length === 1);

  const replacement = websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}&reconnect=1`);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(harness.state.upstreamConnections, 1);
  releaseRemoval();
  const second = await replacement;

  assert.equal(second.status, 101);
  assert.equal(harness.state.upstreamConnections, 2);
});

test("signals a fatal enforcement failure when removal cannot finish by the deadline", async (t) => {
  const harness = await createHarness({ removalDeadlineMs: 120, requestTimeoutMs: 60 });
  t.after(() => harness.close());
  harness.state.removalHook = async () => 503;
  const result = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(result.status, 101);
  harness.state.active = false;
  await waitFor(() => harness.state.fatals.length === 1);

  assert.deepEqual(harness.state.fatals, [{ type: "enforcement_failure" }]);
  assert.ok(harness.state.removals.length >= 1);
  assert.ok(harness.state.decisions.some(({ type }) => type === "enforcement_failure"));
  const upstreamCount = harness.state.upstreamConnections;
  const validation = await fetch(`http://127.0.0.1:${harness.gatewayPort}/rtc/validate?access_token=${TOKEN}`);
  assert.equal(validation.status, 503);
  const admission = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(admission.status, 503);
  assert.equal(harness.state.upstreamConnections, upstreamCount);
});

test("fails closed on backend outage and unexpected authorization payloads", async (t) => {
  const outage = await createHarness();
  t.after(() => outage.close());
  outage.state.authorizeStatus = 503;
  const unavailable = await websocketAttempt(`ws://127.0.0.1:${outage.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(unavailable.status, 503);
  assert.equal(outage.state.upstreamConnections, 0);

  const malformed = await createHarness();
  t.after(() => malformed.close());
  malformed.state.authorizeHook = async () => ({ status: 200, body: { grant_id: 17, room_name: "opaque-room" } });
  const invalid = await websocketAttempt(`ws://127.0.0.1:${malformed.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(invalid.status, 503);
  assert.equal(malformed.state.upstreamConnections, 0);
});

test("times out stalled backend bodies and upstreams that never signal", async (t) => {
  const stalledBackend = await createHarness({ requestTimeoutMs: 60 });
  t.after(() => stalledBackend.close());
  stalledBackend.state.stallAuthorizeBody = true;
  const bodyTimeout = await websocketAttempt(`ws://127.0.0.1:${stalledBackend.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(bodyTimeout.status, 503);

  const stalledUpstream = await createHarness({ requestTimeoutMs: 60 });
  t.after(() => stalledUpstream.close());
  stalledUpstream.state.sendFirstSignal = false;
  const signalTimeout = await websocketAttempt(`ws://127.0.0.1:${stalledUpstream.gatewayPort}/rtc?access_token=${TOKEN}`);
  assert.equal(signalTimeout.status, 503);
  await waitFor(() => stalledUpstream.state.upstreamSockets.size === 0);
});

test("shutdown cancels a pending upgrade without waiting for its timeout", async (t) => {
  const harness = await createHarness({ requestTimeoutMs: 2_000 });
  t.after(() => harness.close());
  harness.state.sendFirstSignal = false;
  const pending = websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`);
  await waitFor(() => harness.state.upstreamConnections === 1);

  await Promise.race([
    harness.gateway.close(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("gateway close timed out")), 300)),
  ]);
  const result = await pending;
  assert.notEqual(result.status, 101);
});

test("rejects unsupported and ambiguous request targets without exposing tokens", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());

  const absolute = await rawRequest(harness.gatewayPort, `http://gateway.invalid/rtc?access_token=${TOKEN}`);
  assert.match(absolute, /^HTTP\/1\.1 400 /);
  const unsupported = await fetch(`http://127.0.0.1:${harness.gatewayPort}/admin?access_token=${TOKEN}`);
  assert.equal(unsupported.status, 404);
  assert.doesNotMatch(await unsupported.text(), new RegExp(TOKEN.replaceAll(".", "\\.")));
  const duplicate = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}&access_token=${TOKEN}`);
  assert.equal(duplicate.status, 401);
  const headerToken = await websocketAttempt(`ws://127.0.0.1:${harness.gatewayPort}/rtc?access_token=${TOKEN}`, {
    headers: { access_token: TOKEN },
  });
  assert.equal(headerToken.status, 401);
  assert.ok(harness.state.decisions.every((decision) => Object.keys(decision).join(",") === "type"));
  assert.doesNotMatch(JSON.stringify(harness.state.decisions), new RegExp(TOKEN.replaceAll(".", "\\.")));
});

test("proxies validation only after forwarding the exact token to Campfire", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());

  const response = await fetch(`http://127.0.0.1:${harness.gatewayPort}/rtc/v1/validate?access_token=${TOKEN}`);

  assert.equal(response.status, 200);
  assert.equal(await response.text(), "OK");
  assert.deepEqual(harness.state.seenAuthorization, [`Bearer ${TOKEN}`]);
});
