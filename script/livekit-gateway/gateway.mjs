import crypto from "node:crypto";
import http from "node:http";
import { WebSocket, WebSocketServer } from "ws";

const SIGNAL_PATHS = new Set(["/rtc", "/rtc/v1"]);
const VALIDATE_PATHS = new Set(["/rtc/validate", "/rtc/v1/validate"]);
const MAX_URL_BYTES = 16_384;
const MAX_QUERY_BYTES = 8_192;
const MAX_RESPONSE_BYTES = 16_384;
const MAX_BUFFERED_SIGNAL_BYTES = 262_144;
const MAX_BUFFERED_SIGNAL_MESSAGES = 32;
const MAX_CLIENT_MESSAGE_BYTES = 1_048_576;
const MAX_BRIDGED_BUFFER_BYTES = 1_048_576;

class GatewayError extends Error {
  constructor(code, status = 503) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function parseFixedBase(value, name) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new GatewayError(`invalid_${name}`);
  }

  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new GatewayError(`invalid_${name}`);
  }

  return url;
}

function normalizeConfig(options) {
  const listenHost = options.listenHost ?? "127.0.0.1";
  const listenPort = Number(options.listenPort ?? 7883);
  const checkIntervalMs = Number(options.checkIntervalMs ?? 1_000);
  const requestTimeoutMs = Number(options.requestTimeoutMs ?? 1_500);
  const reconnectGraceMs = Number(options.reconnectGraceMs ?? 3_000);
  const removalDeadlineMs = Number(options.removalDeadlineMs ?? 10_000);

  if (listenHost !== "127.0.0.1") throw new GatewayError("invalid_listen_host");
  if (!Number.isInteger(listenPort) || listenPort < 0 || listenPort > 65_535) throw new GatewayError("invalid_listen_port");
  if (!Number.isInteger(checkIntervalMs) || checkIntervalMs < 20 || checkIntervalMs > 60_000) throw new GatewayError("invalid_check_interval");
  if (!Number.isInteger(requestTimeoutMs) || requestTimeoutMs < 20 || requestTimeoutMs > 30_000) throw new GatewayError("invalid_request_timeout");
  if (!Number.isInteger(reconnectGraceMs) || reconnectGraceMs < 20 || reconnectGraceMs > 60_000) throw new GatewayError("invalid_reconnect_grace");
  if (!Number.isInteger(removalDeadlineMs) || removalDeadlineMs < 50 || removalDeadlineMs > 120_000) throw new GatewayError("invalid_removal_deadline");

  for (const name of ["gatewaySecret", "livekitApiKey", "livekitApiSecret"]) {
    if (typeof options[name] !== "string" || options[name].length < 16) throw new GatewayError(`invalid_${name}`);
  }

  return {
    listenHost,
    listenPort,
    checkIntervalMs,
    requestTimeoutMs,
    reconnectGraceMs,
    removalDeadlineMs,
    campfireUrl: parseFixedBase(options.campfireUrl ?? "http://127.0.0.1:3000", "campfire_url"),
    internalUrl: parseFixedBase(options.internalUrl ?? "http://127.0.0.1:7880", "internal_url"),
    gatewaySecret: options.gatewaySecret,
    livekitApiKey: options.livekitApiKey,
    livekitApiSecret: options.livekitApiSecret,
    onDecision: typeof options.onDecision === "function" ? options.onDecision : () => {},
    onFatal: typeof options.onFatal === "function" ? options.onFatal : () => {},
  };
}

function emit(config, type) {
  try {
    config.onDecision(Object.freeze({ type }));
  } catch {
    // Observability must never affect authorization.
  }
}

function safePath(rawUrl) {
  if (typeof rawUrl !== "string" || Buffer.byteLength(rawUrl) > MAX_URL_BYTES) throw new GatewayError("invalid_url", 400);
  if (!rawUrl.startsWith("/") || rawUrl.startsWith("//") || rawUrl.includes("\\")) throw new GatewayError("invalid_url", 400);
  const queryOffset = rawUrl.indexOf("?");
  if (queryOffset !== -1 && Buffer.byteLength(rawUrl.slice(queryOffset + 1)) > MAX_QUERY_BYTES) {
    throw new GatewayError("query_too_large", 414);
  }

  let parsed;
  try {
    parsed = new URL(rawUrl, "http://gateway.invalid");
  } catch {
    throw new GatewayError("invalid_url", 400);
  }
  if (parsed.origin !== "http://gateway.invalid" || parsed.hash) throw new GatewayError("invalid_url", 400);
  return parsed;
}

function getDistinctHeaders(request, name) {
  const values = request.headersDistinct?.[name];
  if (values) return values;
  const value = request.headers[name];
  return value === undefined ? [] : [String(value)];
}

function extractToken(request, parsed) {
  const queryTokens = parsed.searchParams.getAll("access_token");
  const tokenHeaders = [
    ...getDistinctHeaders(request, "access_token"),
    ...getDistinctHeaders(request, "x-livekit-token"),
    ...getDistinctHeaders(request, "authorization"),
  ];

  if (tokenHeaders.length > 0 || queryTokens.length !== 1) throw new GatewayError("ambiguous_token", 401);
  const token = queryTokens[0];
  if (token.length < 16 || token.length > MAX_QUERY_BYTES || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) {
    throw new GatewayError("invalid_token", 401);
  }
  return token;
}

async function readBounded(response, limit = MAX_RESPONSE_BYTES) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) throw new GatewayError("response_too_large");
  if (!response.body) return Buffer.alloc(0);

  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > limit) {
      await response.body.cancel().catch(() => {});
      throw new GatewayError("response_too_large");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

async function boundedFetch(url, options, timeoutMs, externalSignal, consume) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  externalSignal?.addEventListener("abort", abort, { once: true });
  const timer = setTimeout(abort, timeoutMs);

  try {
    const response = await fetch(url, { ...options, redirect: "manual", signal: controller.signal });
    return await consume(response);
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    throw new GatewayError("request_failed");
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener("abort", abort);
  }
}

function validateGrant(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("invalid_grant");
  const keys = Object.keys(value).sort();
  if (keys.join(",") !== "grant_id,identity,room_name") throw new GatewayError("invalid_grant");

  const { grant_id: rawGrantId, room_name: roomName, identity } = value;
  const grantId = typeof rawGrantId === "string" ? rawGrantId :
    (Number.isSafeInteger(rawGrantId) && rawGrantId > 0 ? String(rawGrantId) : "");
  if (!/^[A-Za-z0-9_-]{1,256}$/.test(grantId)) throw new GatewayError("invalid_grant");
  for (const item of [roomName, identity]) {
    if (typeof item !== "string" || item.length < 1 || Buffer.byteLength(item) > 512 || /[\u0000-\u001f\u007f]/.test(item)) {
      throw new GatewayError("invalid_grant");
    }
  }
  return Object.freeze({ grantId, roomName, identity });
}

function sameGrant(left, right) {
  return left.grantId === right.grantId && left.roomName === right.roomName && left.identity === right.identity;
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function adminToken(config, grant) {
  const now = Math.floor(Date.now() / 1_000);
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    exp: now + 60,
    iat: now,
    iss: config.livekitApiKey,
    jti: crypto.randomUUID(),
    nbf: now - 5,
    video: { roomAdmin: true, room: grant.roomName },
  }));
  const signature = crypto.createHmac("sha256", config.livekitApiSecret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function genericBody(status) {
  if (status === 401) return "Unauthorized\n";
  if (status === 403) return "Forbidden\n";
  if (status === 404) return "Not Found\n";
  if (status === 405) return "Method Not Allowed\n";
  if (status === 414) return "URI Too Long\n";
  if (status === 426) return "Upgrade Required\n";
  return "Service Unavailable\n";
}

function sendHttp(response, status, body = genericBody(status), contentType = "text/plain; charset=utf-8") {
  if (response.headersSent) return;
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
    "content-type": contentType,
    "x-content-type-options": "nosniff",
  });
  response.end(body);
}

function rejectUpgrade(socket, status) {
  if (socket.destroyed) return;
  const body = genericBody(status);
  socket.end(
    `HTTP/1.1 ${status} ${http.STATUS_CODES[status] ?? "Error"}\r\n` +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n" +
      "Content-Type: text/plain; charset=utf-8\r\n" +
      `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`,
  );
}

export function createGateway(options) {
  const config = normalizeConfig(options);
  const downstreamServer = new WebSocketServer({ noServer: true, maxPayload: MAX_CLIENT_MESSAGE_BYTES, perMessageDeflate: false });
  const activeConnections = new Set();
  const pendingUpgrades = new Set();
  const removalRetries = new Map();
  const leases = new Map();
  let closing = false;
  let fatalTriggered = false;

  function campfireEndpoint(path) {
    return new URL(path, config.campfireUrl.origin);
  }

  function livekitEndpoint(pathAndQuery) {
    return new URL(pathAndQuery, config.internalUrl.origin);
  }

  function livekitRequestTarget(parsed) {
    // Client input may select an allowed signaling path and query, never the
    // upstream authority. Assign them separately on the configured origin.
    const target = new URL(config.internalUrl.origin);
    target.pathname = parsed.pathname;
    target.search = parsed.search;
    return target;
  }

  async function authorize(token, signal) {
    return boundedFetch(campfireEndpoint("/internal/huddle/authorize"), {
      method: "POST",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "x-huddle-gateway-secret": config.gatewaySecret,
      },
      body: "{}",
    }, config.requestTimeoutMs, signal, async (response) => {
      if (response.status !== 200) {
        await response.body?.cancel().catch(() => {});
        const status = response.status === 401 || response.status === 403 ? response.status : 503;
        throw new GatewayError("authorization_denied", status);
      }

      const body = await readBounded(response);
      try {
        return validateGrant(JSON.parse(body.toString("utf8")));
      } catch (error) {
        if (error instanceof GatewayError) throw error;
        throw new GatewayError("invalid_authorization_response");
      }
    });
  }

  async function checkGrant(grant, signal) {
    const path = `/internal/huddle/grants/${encodeURIComponent(grant.grantId)}`;
    return boundedFetch(campfireEndpoint(path), {
      method: "GET",
      headers: {
        accept: "application/json",
        "x-huddle-gateway-secret": config.gatewaySecret,
      },
    }, config.requestTimeoutMs, signal, async (response) => {
      if (response.status !== 200) {
        await response.body?.cancel().catch(() => {});
        throw new GatewayError("grant_denied", response.status === 401 || response.status === 403 ? response.status : 503);
      }
      const body = await readBounded(response);
      let current;
      try {
        current = validateGrant(JSON.parse(body.toString("utf8")));
      } catch {
        throw new GatewayError("invalid_grant_response");
      }
      if (!sameGrant(grant, current)) throw new GatewayError("grant_changed", 403);
      return current;
    });
  }

  async function removeParticipant(grant) {
    const endpoint = livekitEndpoint("/twirp/livekit.RoomService/RemoveParticipant");
    return boundedFetch(endpoint, {
      method: "POST",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${adminToken(config, grant)}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ room: grant.roomName, identity: grant.identity }),
    }, config.requestTimeoutMs, undefined, async (response) => {
      await response.body?.cancel().catch(() => {});
      if ((response.status < 200 || response.status >= 300) && response.status !== 404) throw new GatewayError("removal_failed");
    });
  }

  function removalKey(grant) {
    return crypto.createHash("sha256").update(grant.roomName).update("\0").update(grant.identity).digest("hex");
  }

  function triggerFatal() {
    if (closing || fatalTriggered) return;
    fatalTriggered = true;
    emit(config, "enforcement_failure");
    try {
      config.onFatal(Object.freeze({ type: "enforcement_failure" }));
    } catch {
      // Fatal handling must not restore admission.
    }
  }

  function enforceRemoval(grant) {
    const key = removalKey(grant);
    if (removalRetries.has(key)) return removalRetries.get(key);

    let settleFirst;
    let settleCompletion;
    const firstAttempt = new Promise((resolve) => { settleFirst = resolve; });
    const completion = new Promise((resolve) => { settleCompletion = resolve; });
    const state = {
      firstAttempt,
      completion,
      retryTimer: null,
      deadlineTimer: null,
      firstSettled: false,
      done: false,
      delay: 100,
    };
    removalRetries.set(key, state);

    const finish = (removed) => {
      if (state.done) return;
      state.done = true;
      clearTimeout(state.retryTimer);
      clearTimeout(state.deadlineTimer);
      if (!state.firstSettled) {
        state.firstSettled = true;
        settleFirst(removed);
      }
      settleCompletion(removed);
      if (removed || closing) removalRetries.delete(key);
    };

    const attempt = async () => {
      if (state.done) return;
      try {
        await removeParticipant(grant);
        if (state.done) return;
        emit(config, "participant_removed");
        finish(true);
      } catch {
        if (state.done) return;
        emit(config, "participant_removal_failed");
        if (!state.firstSettled) {
          state.firstSettled = true;
          settleFirst(false);
        }
        if (closing) {
          finish(false);
          return;
        }
        state.retryTimer = setTimeout(attempt, state.delay);
        state.retryTimer.unref();
        state.delay = Math.min(state.delay * 2, 5_000);
      }
    };

    state.deadlineTimer = setTimeout(() => {
      if (state.done) return;
      finish(false);
      triggerFatal();
    }, config.removalDeadlineMs);
    state.deadlineTimer.unref();
    void attempt();
    return state;
  }

  async function waitForRemoval(grant) {
    const removal = removalRetries.get(removalKey(grant));
    if (!removal) return;
    const timeout = new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), config.requestTimeoutMs);
      timer.unref();
    });
    const removed = await Promise.race([removal.completion, timeout]);
    if (!removed || fatalTriggered || closing) throw new GatewayError("cleanup_incomplete");
  }

  function stopLeaseTimers(lease) {
    clearInterval(lease.interval);
    clearTimeout(lease.graceTimer);
    lease.interval = null;
    lease.graceTimer = null;
  }

  function terminateConnection(state, decision) {
    if (state.terminated) return;
    state.terminated = true;
    activeConnections.delete(state);
    state.lease.owners.delete(state);
    if (decision) emit(config, decision);
    if (state.downstream.readyState !== WebSocket.CLOSED) state.downstream.terminate();
    if (state.upstream.readyState !== WebSocket.CLOSED) state.upstream.terminate();
  }

  function beginLeaseCleanup(lease) {
    if (lease.cleanupStarted) return lease.removal;
    lease.cleanupStarted = true;
    lease.denied = true;
    stopLeaseTimers(lease);
    for (const pending of [...lease.reservations]) pending.abortController.abort();
    lease.reservations.clear();
    for (const state of [...lease.owners]) terminateConnection(state, null);
    const removal = enforceRemoval(lease.grant);
    lease.removal = removal;
    void removal.completion.then((removed) => {
      if (removed && leases.get(lease.key) === lease) leases.delete(lease.key);
    });
    return removal;
  }

  function denyLease(lease, decision) {
    if (lease.denied) return beginLeaseCleanup(lease);
    emit(config, decision);
    return beginLeaseCleanup(lease);
  }

  function scheduleLeaseCleanup(lease) {
    if (closing || lease.denied || lease.cleanupStarted || lease.owners.size > 0 || lease.reservations.size > 0 || lease.graceTimer) return;
    const generation = lease.generation;
    lease.graceTimer = setTimeout(() => {
      lease.graceTimer = null;
      if (lease.generation === generation && lease.owners.size === 0 && lease.reservations.size === 0) {
        emit(config, "reconnect_grace_expired");
        beginLeaseCleanup(lease);
      }
    }, config.reconnectGraceMs);
    lease.graceTimer.unref();
  }

  function startLeaseChecks(lease) {
    if (lease.interval) return;
    lease.interval = setInterval(async () => {
      if (lease.denied || lease.checking || closing) return;
      lease.checking = true;
      try {
        await checkGrant(lease.grant);
        emit(config, "active_grant_allowed");
      } catch {
        denyLease(lease, "active_grant_denied");
      } finally {
        lease.checking = false;
      }
    }, config.checkIntervalMs);
    lease.interval.unref();
  }

  async function reserveLease(grant, pending) {
    if (fatalTriggered || closing) throw new GatewayError("unavailable");
    const key = removalKey(grant);
    await waitForRemoval(grant);

    let lease = leases.get(key);
    if (lease && !sameGrant(lease.grant, grant)) {
      const removal = denyLease(lease, "grant_replaced");
      const removed = await Promise.race([
        removal.completion,
        new Promise((resolve) => {
          const timer = setTimeout(() => resolve(false), config.requestTimeoutMs);
          timer.unref();
        }),
      ]);
      if (!removed) throw new GatewayError("cleanup_incomplete");
      lease = leases.get(key);
    }

    if (!lease) {
      lease = {
        key,
        grant,
        generation: 0,
        reservations: new Set(),
        owners: new Set(),
        interval: null,
        graceTimer: null,
        checking: false,
        denied: false,
        cleanupStarted: false,
        removal: null,
      };
      leases.set(key, lease);
      startLeaseChecks(lease);
    }
    if (lease.denied || lease.cleanupStarted || fatalTriggered || closing) throw new GatewayError("cleanup_incomplete");
    clearTimeout(lease.graceTimer);
    lease.graceTimer = null;
    lease.generation += 1;
    lease.reservations.add(pending);
    pending.lease = lease;
    return lease;
  }

  function releaseReservation(pending) {
    const lease = pending.lease;
    if (!lease) return;
    lease.reservations.delete(pending);
    pending.lease = null;
    scheduleLeaseCleanup(lease);
  }

  function bridge(upstream, downstream, buffered, grant, pending) {
    const lease = pending.lease;
    if (!lease || lease.denied || lease.cleanupStarted || !sameGrant(lease.grant, grant)) {
      downstream.terminate();
      upstream.terminate();
      releaseReservation(pending);
      return;
    }
    lease.reservations.delete(pending);
    pending.lease = null;
    const state = { upstream, downstream, grant, lease, terminated: false };
    lease.owners.add(state);
    activeConnections.add(state);

    const ordinaryClose = () => {
      if (state.terminated) return;
      terminateConnection(state, null);
      scheduleLeaseCleanup(lease);
    };

    const guardedSend = (target, data, isBinary) => {
      if (target.readyState !== WebSocket.OPEN) return;
      if (target.bufferedAmount + data.length > MAX_BRIDGED_BUFFER_BYTES) {
        emit(config, "connection_backpressure_closed");
        ordinaryClose();
        return;
      }
      try {
        target.send(data, { binary: isBinary }, (error) => { if (error) ordinaryClose(); });
      } catch {
        ordinaryClose();
      }
    };

    upstream.on("message", (data, isBinary) => {
      if (!state.terminated) guardedSend(downstream, data, isBinary);
    });
    downstream.on("message", (data, isBinary) => {
      if (!state.terminated) guardedSend(upstream, data, isBinary);
    });
    upstream.once("close", ordinaryClose);
    downstream.once("close", ordinaryClose);
    upstream.once("error", ordinaryClose);
    downstream.once("error", ordinaryClose);

    for (const message of buffered) guardedSend(downstream, message.data, message.isBinary);
    emit(config, "connection_authorized");
  }

  async function proxyValidation(request, response, parsed, token) {
    const abortController = new AbortController();
    request.once("close", () => abortController.abort());
    try {
      await authorize(token, abortController.signal);
      const upstreamResult = await boundedFetch(livekitRequestTarget(parsed), {
        method: "GET",
        headers: { accept: "text/plain, application/json" },
      }, config.requestTimeoutMs, abortController.signal, async (upstream) => {
        if (upstream.status >= 300 && upstream.status < 400) throw new GatewayError("upstream_redirect");
        return {
          status: upstream.status,
          body: await readBounded(upstream),
          contentType: upstream.headers.get("content-type") ?? "text/plain; charset=utf-8",
        };
      });
      sendHttp(response, upstreamResult.status, upstreamResult.body, upstreamResult.contentType);
      emit(config, "validation_authorized");
    } catch (error) {
      const status = error instanceof GatewayError ? error.status : 503;
      sendHttp(response, status);
      emit(config, "validation_denied");
    }
  }

  const server = http.createServer({ maxHeaderSize: 16_384 }, (request, response) => {
    if (closing || fatalTriggered) return sendHttp(response, 503);
    let parsed;
    try {
      parsed = safePath(request.url);
      if (request.method !== "GET") throw new GatewayError("method_not_allowed", 405);
      if (!VALIDATE_PATHS.has(parsed.pathname)) {
        if (SIGNAL_PATHS.has(parsed.pathname)) throw new GatewayError("upgrade_required", 426);
        throw new GatewayError("not_found", 404);
      }
      const token = extractToken(request, parsed);
      void proxyValidation(request, response, parsed, token);
    } catch (error) {
      sendHttp(response, error instanceof GatewayError ? error.status : 503);
      emit(config, "http_rejected");
    }
  });
  server.requestTimeout = 5_000;
  server.headersTimeout = 5_000;

  server.on("upgrade", (request, socket, head) => {
    socket.pause();
    const abortController = new AbortController();
    const pending = { socket, abortController, upstream: null, lease: null };
    pendingUpgrades.add(pending);
    const abort = () => abortController.abort();
    socket.once("close", abort);
    socket.once("error", abort);

    void (async () => {
      let upstream;
      let initialGrant;
      let participantCreated = false;
      let postAuthorizationStarted = false;
      try {
        if (closing || fatalTriggered) throw new GatewayError("closing");
        const parsed = safePath(request.url);
        if (request.method !== "GET" || !SIGNAL_PATHS.has(parsed.pathname)) throw new GatewayError("not_found", 404);
        const token = extractToken(request, parsed);
        initialGrant = await authorize(token, abortController.signal);
        emit(config, "preauthorization_allowed");
        if (abortController.signal.aborted || socket.destroyed) throw new GatewayError("client_gone");
        await reserveLease(initialGrant, pending);
        if (abortController.signal.aborted || socket.destroyed) throw new GatewayError("client_gone");

        const upstreamUrl = livekitRequestTarget(parsed);
        upstreamUrl.protocol = upstreamUrl.protocol === "https:" ? "wss:" : "ws:";
        upstream = new WebSocket(upstreamUrl, {
          followRedirects: false,
          handshakeTimeout: config.requestTimeoutMs,
          maxPayload: MAX_CLIENT_MESSAGE_BYTES,
          perMessageDeflate: false,
        });
        pending.upstream = upstream;

        const buffered = [];
        let bufferedBytes = 0;
        let firstResolve;
        let firstReject;
        const firstSignal = new Promise((resolve, reject) => { firstResolve = resolve; firstReject = reject; });
        const bufferMessage = (data, isBinary) => {
          bufferedBytes += data.length;
          if (buffered.length >= MAX_BUFFERED_SIGNAL_MESSAGES || bufferedBytes > MAX_BUFFERED_SIGNAL_BYTES) {
            firstReject(new GatewayError("signal_buffer_exceeded"));
            upstream.terminate();
            return;
          }
          buffered.push({ data: Buffer.from(data), isBinary });
          if (buffered.length === 1) firstResolve();
        };
        upstream.on("message", bufferMessage);
        upstream.once("close", () => firstReject(new GatewayError("upstream_closed")));
        upstream.once("error", () => firstReject(new GatewayError("upstream_failed")));
        abortController.signal.addEventListener("abort", () => {
          firstReject(new GatewayError("client_gone"));
          upstream.terminate();
        }, { once: true });

        const firstSignalTimer = setTimeout(() => {
          firstReject(new GatewayError("first_signal_timeout"));
          upstream.terminate();
        }, config.requestTimeoutMs);
        try {
          await firstSignal;
        } finally {
          clearTimeout(firstSignalTimer);
        }
        participantCreated = true;
        postAuthorizationStarted = true;
        const confirmedGrant = await authorize(token, abortController.signal);
        if (!sameGrant(initialGrant, confirmedGrant)) throw new GatewayError("grant_changed", 403);
        if (pending.lease?.denied || pending.lease?.cleanupStarted) throw new GatewayError("grant_denied", 403);
        emit(config, "postauthorization_allowed");
        if (abortController.signal.aborted || socket.destroyed || upstream.readyState !== WebSocket.OPEN) {
          throw new GatewayError("connection_lost");
        }

        upstream.removeListener("message", bufferMessage);
        socket.removeListener("close", abort);
        socket.removeListener("error", abort);
        pendingUpgrades.delete(pending);
        downstreamServer.handleUpgrade(request, socket, head, (downstream) => {
          socket.resume();
          bridge(upstream, downstream, buffered, confirmedGrant, pending);
        });
      } catch (error) {
        if (upstream) upstream.terminate();
        if (participantCreated && postAuthorizationStarted && initialGrant && !abortController.signal.aborted) {
          const lease = pending.lease ?? leases.get(removalKey(initialGrant));
          const removal = lease ? denyLease(lease, "postauthorization_denied") : enforceRemoval(initialGrant);
          await removal.firstAttempt;
        }
        rejectUpgrade(socket, error instanceof GatewayError ? error.status : 503);
        emit(config, "upgrade_rejected");
      } finally {
        releaseReservation(pending);
        pendingUpgrades.delete(pending);
      }
    })();
  });

  async function start() {
    if (closing) throw new GatewayError("closing");
    await new Promise((resolve, reject) => {
      const onError = (error) => { server.off("listening", onListen); reject(error); };
      const onListen = () => { server.off("error", onError); resolve(); };
      server.once("error", onError);
      server.once("listening", onListen);
      server.listen(config.listenPort, config.listenHost);
    });
    emit(config, "gateway_started");
    return server.address();
  }

  async function close() {
    if (closing) return;
    closing = true;
    for (const pending of pendingUpgrades) {
      pending.abortController.abort();
      pending.upstream?.terminate();
      pending.socket.destroy();
    }
    pendingUpgrades.clear();
    const removals = new Set();
    for (const lease of [...leases.values()]) {
      const removal = beginLeaseCleanup(lease);
      removals.add(removal.firstAttempt);
      for (const state of [...lease.owners]) terminateConnection(state, "gateway_shutdown");
    }
    for (const removal of removalRetries.values()) removals.add(removal.firstAttempt);
    await Promise.allSettled([...removals]);
    for (const removal of removalRetries.values()) {
      clearTimeout(removal.retryTimer);
      clearTimeout(removal.deadlineTimer);
    }
    server.closeAllConnections?.();
    if (server.listening) await new Promise((resolve) => server.close(() => resolve()));
    downstreamServer.close();
    emit(config, "gateway_stopped");
  }

  return { start, close, server };
}

export { GatewayError };
