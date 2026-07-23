import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const bridgeSource = fs.readFileSync(
  new URL("./sakura-bridge.js", import.meta.url),
  "utf8",
);
const ticket = "A".repeat(32);
const exchangeUrl =
  "https://novel.kxhub.xyz/sakura/sso/exchange";

function makeXhrClass(plan) {
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
      plan(this);
    }
  };
}

function loadBridge(plan) {
  const context = {
    XMLHttpRequest: makeXhrClass(plan),
    console: { error() {}, log() {} },
  };
  vm.createContext(context);
  vm.runInContext(bridgeSource, context);
  return context.SakuraBridge;
}

function makePlatform(extras = {}, android = true) {
  const successes = [];
  const failures = [];
  return {
    platform: {
      isAndroid() {
        return android;
      },
      toNativeCall(name, args) {
        if (name !== "takeSakuraExtra") return "";
        return extras[args[0]] || "";
      },
      sakuraLoginSuccess(payload) {
        successes.push(payload);
      },
      sakuraLoginFailure(reason) {
        failures.push(reason);
      },
    },
    successes,
    failures,
  };
}

function complete(xhr, status, payload) {
  xhr.status = status;
  xhr.responseText = JSON.stringify(payload);
  xhr.readyState = 4;
  xhr.onreadystatechange();
}

{
  const bridge = loadBridge((xhr) => {
    complete(xhr, 200, {
      ok: true,
      accountId: "42",
      token: "game-token",
      serverInfo: {
        data: {
          sid: "1",
          name: "一区",
          ip: "49.232.137.85",
          port: 3251,
          token: "server-token",
        },
      },
    });
  });
  const state = makePlatform({
    sakura_sso_ticket: ticket,
    sakura_sso_exchange_url: exchangeUrl,
  });
  assert.equal(bridge.managed(state.platform), true);
  bridge.login(state.platform);
  assert.equal(state.successes.length, 1);
  assert.equal(state.failures.length, 0);
  assert.equal(state.successes[0].accountId, "42");
}

{
  const bridge = loadBridge(() => {
    throw new Error("missing config must not issue a request");
  });
  const state = makePlatform();
  assert.equal(bridge.managed(state.platform), true);
  bridge.login(state.platform);
  assert.equal(state.successes.length, 0);
  assert.equal(state.failures.length, 1);
}

for (const scenario of [
  {
    name: "401",
    plan(xhr) {
      complete(xhr, 401, { error: "invalid_ticket" });
    },
  },
  {
    name: "timeout",
    plan(xhr) {
      xhr.ontimeout();
      complete(xhr, 500, { error: "late_response" });
    },
  },
  {
    name: "invalid payload",
    plan(xhr) {
      complete(xhr, 200, { ok: true });
    },
  },
]) {
  const bridge = loadBridge(scenario.plan);
  const state = makePlatform({
    sakura_sso_ticket: ticket,
    sakura_sso_exchange_url: exchangeUrl,
  });
  assert.equal(bridge.managed(state.platform), true, scenario.name);
  bridge.login(state.platform);
  assert.equal(state.successes.length, 0, scenario.name);
  assert.equal(state.failures.length, 1, scenario.name);
}

{
  const bridge = loadBridge(() => {});
  const state = makePlatform({}, false);
  assert.equal(bridge.managed(state.platform), false);
}

console.log("Sakura bridge runtime tests passed");
