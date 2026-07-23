import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const bridgeSource = fs.readFileSync(
  new URL("./sakura-bridge.js", import.meta.url),
  "utf8",
);
const ticket = "T".repeat(48);
const requestId = "R".repeat(32);
const exchangeUrl = "https://novel.kxhub.xyz/sakura/sso/exchange";
const gameToken = "G".repeat(64);
// Production's legacy server-list token is intentionally shorter than an SSO
// session token; both values have separate contracts.
const serverToken = "legacy-1";

function makeXhrClass(plan, requests) {
  return class FakeXMLHttpRequest {
    constructor() {
      this.headers = {};
      this.readyState = 0;
      this.responseText = "";
      this.status = 0;
    }

    open(method, url) {
      this.method = method;
      this.url = url;
    }

    setRequestHeader(name, value) {
      this.headers[name] = value;
    }

    send(body) {
      this.body = body;
      requests.push(this);
      plan(this);
    }
  };
}

function loadBridge(plan) {
  const requests = [];
  const context = {
    XMLHttpRequest: makeXhrClass(plan, requests),
    console: { error() {}, log() {} },
  };
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  return { bridge: context.SakuraBridge, requests };
}

function makePlatform({
  extras = {},
  stored = "",
  android = true,
  generatedRequestId = requestId,
  authorizationAvailable = true,
  paymentLaunchAvailable = true,
} = {}) {
  const values = { ...extras };
  const state = {
    stored,
    successes: [],
    pending: 0,
    required: [],
    failures: [],
    authorizationUrls: [],
    nativeUrls: [],
    paymentResults: [],
    paymentFailures: [],
  };
  const platform = {
    sid: "1",
    isAndroid() {
      return android;
    },
    toNativeCall(name, args) {
      if (name !== "takeSakuraExtra") return "";
      const key = args[0];
      const value = values[key] || "";
      delete values[key];
      return value;
    },
    callNative(name, payload) {
      if (name === "openPayUrl") state.nativeUrls.push(payload.url);
    },
    sakuraReadAuthState() {
      return state.stored;
    },
    sakuraWriteAuthState(value) {
      state.stored = value;
    },
    sakuraCreateRequestId() {
      return generatedRequestId;
    },
    sakuraOpenAuthorization(url) {
      state.authorizationUrls.push(url);
      return authorizationAvailable;
    },
    sakuraOpenPayment(url) {
      state.nativeUrls.push(url);
      return paymentLaunchAvailable;
    },
    sakuraLoginPending() {
      state.pending++;
    },
    sakuraLoginRequired(reason) {
      state.required.push(reason);
    },
    sakuraLoginFailure(reason) {
      state.failures.push(reason);
    },
    sakuraLoginSuccess(payload) {
      state.successes.push(payload);
    },
    sakuraPaymentResult(payload) {
      state.paymentResults.push(payload);
    },
    sakuraPaymentFailure(reason) {
      state.paymentFailures.push(reason);
    },
    sakuraPublishServerList() {},
    sakuraPublishServerDetail() {},
  };
  state.platform = platform;
  state.setExtras = (next) => Object.assign(values, next);
  return state;
}

function complete(xhr, status, payload) {
  xhr.status = status;
  xhr.responseText = JSON.stringify(payload);
  xhr.readyState = 4;
  xhr.onreadystatechange();
}

function successfulExchange(xhr) {
  complete(xhr, 200, {
    ok: true,
    accountId: "42",
    token: gameToken,
    tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    serverInfo: {
      code: 1,
      msg: "ok",
      data: {
        sid: "1",
        name: "\u4e00\u533a",
        ip: "49.232.137.85",
        port: 80,
        token: serverToken,
      },
    },
  });
}

function directExtras(overrides = {}) {
  return {
    sakura_sso_ticket: ticket,
    sakura_sso_exchange_url: exchangeUrl,
    sakura_sso_source: "com.novel.novel_app",
    ...overrides,
  };
}

function storedSession(expiresAt = Date.now() + 60 * 60 * 1000) {
  return JSON.stringify({
    version: 1,
    session: {
      accountId: "42",
      token: gameToken,
      tokenExpiresAt: new Date(expiresAt).toISOString(),
      exchangeUrl,
      serverInfo: {
        code: 1,
        msg: "ok",
        data: {
          sid: "1",
          name: "\u4e00\u533a",
          ip: "49.232.137.85",
          port: 80,
          token: serverToken,
        },
      },
    },
  });
}

{
  const runtime = loadBridge(() => {
    throw new Error("first standalone launch must not issue a request");
  });
  const state = makePlatform();
  assert.equal(runtime.bridge.start(state.platform), true);
  assert.deepEqual(state.required, ["missing_session"]);
  assert.equal(state.authorizationUrls.length, 0);
  assert.equal(runtime.requests.length, 0);
}

let persistedSession;
{
  const runtime = loadBridge(successfulExchange);
  const state = makePlatform();
  runtime.bridge.start(state.platform);
  assert.equal(runtime.bridge.authorize(state.platform), true);
  assert.deepEqual(
    state.authorizationUrls,
    [`sakura-novel://modao-auth/request?requestId=${requestId}`],
  );
  assert.doesNotMatch(state.authorizationUrls[0], /ticket/i);
  const pending = JSON.parse(state.stored);
  assert.equal(pending.version, 1);
  assert.equal(pending.pendingRequest.requestId, requestId);

  state.setExtras(directExtras({
    sakura_sso_request_id: requestId,
  }));
  runtime.bridge.onResume(state.platform);
  assert.equal(runtime.requests.length, 1);
  assert.deepEqual(JSON.parse(runtime.requests[0].body), { ticket });
  assert.equal(state.pending, 1);
  assert.equal(state.successes.length, 1);
  assert.equal(state.failures.length, 0);
  const saved = JSON.parse(state.stored);
  assert.equal(saved.pendingRequest, undefined);
  assert.equal(saved.session.accountId, "42");
  assert.equal(saved.session.token, gameToken);
  assert.equal(saved.session.serverInfo.data.token, serverToken);
  persistedSession = state.stored;
}

{
  const runtime = loadBridge(() => {
    throw new Error("a fresh local session must not exchange another ticket");
  });
  const state = makePlatform({ stored: persistedSession });
  runtime.bridge.start(state.platform);
  assert.equal(runtime.requests.length, 0);
  assert.equal(state.successes.length, 1);
  assert.equal(state.successes[0].accountId, "42");
  assert.deepEqual(state.required, []);
}

{
  const runtime = loadBridge(() => {
    throw new Error("an expired local session must not use the network");
  });
  const state = makePlatform({
    stored: storedSession(Date.now() - 1000),
  });
  runtime.bridge.start(state.platform);
  assert.deepEqual(state.required, ["session_expired"]);
  assert.equal(state.successes.length, 0);
  assert.equal(state.stored, "");
}

{
  const runtime = loadBridge(successfulExchange);
  const state = makePlatform({
    stored: JSON.stringify({
      version: 1,
      pendingRequest: {
        requestId,
        createdAt: Date.now(),
      },
    }),
    extras: directExtras(),
  });
  runtime.bridge.start(state.platform);
  assert.equal(runtime.requests.length, 1);
  assert.equal(state.successes.length, 1);
  assert.equal(state.failures.length, 0);
  assert.equal(JSON.parse(state.stored).pendingRequest, undefined);
}

{
  const runtime = loadBridge(() => {
    throw new Error("a mismatched callback must not exchange its ticket");
  });
  const state = makePlatform({
    stored: JSON.stringify({
      version: 1,
      pendingRequest: {
        requestId,
        createdAt: Date.now(),
      },
    }),
    extras: directExtras({
      sakura_sso_request_id: "X".repeat(32),
    }),
  });
  runtime.bridge.start(state.platform);
  assert.deepEqual(state.failures, ["callback_request_mismatch"]);
  assert.equal(runtime.requests.length, 0);
  assert.equal(state.stored, "");
}

{
  const runtime = loadBridge(successfulExchange);
  const state = makePlatform({
    extras: directExtras(),
  });
  runtime.bridge.start(state.platform);
  assert.equal(runtime.requests.length, 1);
  assert.equal(state.successes.length, 1);
}

{
  const runtime = loadBridge((xhr) => {
    assert.match(xhr.url, /\/sakura\/payment\/order$/);
    complete(xhr, 401, { ok: false, error: "game_sso_session_expired" });
  });
  const state = makePlatform({ stored: storedSession() });
  runtime.bridge.start(state.platform);
  runtime.bridge.openPayment(state.platform, "?cfgid=401&sid=1", "401");
  assert.deepEqual(state.required, ["session_rejected"]);
  assert.equal(state.stored, "");
}

{
  const runtime = loadBridge(() => {
    throw new Error("a missing novel app must not issue a request");
  });
  const state = makePlatform({ authorizationAvailable: false });
  runtime.bridge.start(state.platform);
  assert.equal(runtime.bridge.authorize(state.platform), false);
  assert.deepEqual(state.failures, ["authorization_app_unavailable"]);
  assert.equal(state.stored, "");
  assert.equal(runtime.requests.length, 0);
}

{
  const runtime = loadBridge((xhr) => {
    assert.match(xhr.url, /\/sakura\/payment\/order$/);
    complete(xhr, 503, { ok: false, error: "temporarily_unavailable" });
  });
  const state = makePlatform({ stored: storedSession() });
  runtime.bridge.start(state.platform);
  runtime.bridge.openPayment(state.platform, "?cfgid=500&sid=1", "500");
  assert.deepEqual(state.paymentFailures, ["payment_order_failed"]);
}

{
  const runtime = loadBridge((xhr) => {
    complete(xhr, 200, {
      ok: true,
      launchUrl:
        "sakura-novel://modao-payment/pay?gameOrderId=order-1&productId=501",
    });
  });
  const state = makePlatform({
    stored: storedSession(),
    paymentLaunchAvailable: false,
  });
  runtime.bridge.start(state.platform);
  runtime.bridge.openPayment(state.platform, "?cfgid=501&sid=1", "501");
  assert.deepEqual(state.paymentFailures, ["payment_app_unavailable"]);
}

{
  const runtime = loadBridge(() => {
    throw new Error("an invalid request id must not issue a request");
  });
  const state = makePlatform({ generatedRequestId: "short" });
  runtime.bridge.start(state.platform);
  assert.equal(runtime.bridge.authorize(state.platform), false);
  assert.deepEqual(state.failures, ["request_id_unavailable"]);
  assert.equal(state.authorizationUrls.length, 0);
}

console.log("Sakura bridge standalone authorization tests passed");
