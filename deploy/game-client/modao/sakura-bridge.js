(function (root) {
  "use strict";

  var state = {
    configured: false,
    loginPending: false,
    ticket: "",
    exchangeUrl: "",
    paymentUrl: "",
    source: "",
    accountId: "",
    token: "",
    server: null,
    lastPayment: null,
    failureNotified: false,
  };

  function text(value) {
    return value === null || value === undefined ? "" : String(value).trim();
  }

  function nativeCall(platform, name, args, returnsValue) {
    try {
      if (platform && typeof platform.toNativeCall === "function") {
        return platform.toNativeCall(name, args || [], !!returnsValue);
      }
    } catch (error) {
      console.error("[sakura] native call failed", name, error);
    }
    return "";
  }

  function readExtra(platform, name) {
    return text(nativeCall(platform, "takeSakuraExtra", [name], true));
  }

  function fail(platform, reason) {
    state.loginPending = false;
    state.ticket = "";
    state.configured = false;
    if (state.failureNotified) return;
    state.failureNotified = true;
    if (platform && typeof platform.sakuraLoginFailure === "function") {
      platform.sakuraLoginFailure(text(reason) || "sso_failed");
    }
  }

  function endpoint(value, expectedPath) {
    var result = text(value);
    if (!/^https:\/\/[^\s/]+(?:[:][0-9]+)?\//i.test(result)) return "";
    var hash = result.indexOf("#");
    if (hash >= 0) result = result.slice(0, hash);
    var query = result.indexOf("?");
    if (query >= 0) result = result.slice(0, query);
    if (result.slice(-expectedPath.length) !== expectedPath) return "";
    return result;
  }

  function paymentLaunchUrl(value) {
    var result = text(value);
    if (!/^sakura-novel:\/\/modao-payment\/pay\?/i.test(result)) return "";
    if (!queryValue(result, "gameOrderId") || !queryValue(result, "productId")) return "";
    return result;
  }

  function queryValue(url, name) {
    var match = text(url).match(new RegExp("[?&]" + name + "=([^&]*)", "i"));
    if (!match) return "";
    try {
      return decodeURIComponent(match[1].replace(/\+/g, " "));
    } catch (error) {
      return "";
    }
  }

  function requestJson(method, url, body, headers, callback) {
    var xhr;
    var completed = false;
    function finish(error, payload, status) {
      if (completed) return;
      completed = true;
      callback(error, payload, status);
    }
    try {
      xhr = new XMLHttpRequest();
      xhr.open(method, url, true);
      xhr.timeout = 15000;
      xhr.setRequestHeader("Content-Type", "application/json");
      xhr.setRequestHeader("Accept", "application/json");
      Object.keys(headers || {}).forEach(function (key) {
        xhr.setRequestHeader(key, headers[key]);
      });
      xhr.onreadystatechange = function () {
        if (xhr.readyState !== 4) return;
        var payload = null;
        try {
          payload = xhr.responseText ? JSON.parse(xhr.responseText) : null;
        } catch (error) {
          finish(new Error("invalid_json_response"), null, xhr.status);
          return;
        }
        if (xhr.status < 200 || xhr.status >= 300) {
          finish(new Error(payload && payload.error ? payload.error : "http_" + xhr.status), payload, xhr.status);
          return;
        }
        finish(null, payload, xhr.status);
      };
      xhr.onerror = function () { finish(new Error("network_error"), null, 0); };
      xhr.ontimeout = function () { finish(new Error("request_timeout"), null, 0); };
      xhr.send(JSON.stringify(body || {}));
    } catch (error) {
      finish(error, null, 0);
    }
  }

  function serverItem() {
    var server = state.server || {};
    return {
      sid: text(server.sid || "1"),
      name: text(server.name || "\u4e3b\u670d\u52a1\u5668"),
      hot: "1",
      open_time: "0",
      wait_open: 0,
      open_date: "",
      status: 1,
      ip: text(server.ip),
      token: text(server.token),
      port: Number(server.port || 0),
    };
  }

  var bridge = {
    configure: function (platform, nativeConfig) {
      var config = nativeConfig || {};
      var ticket = text(config.sakura_sso_ticket) || readExtra(platform, "sakura_sso_ticket") || state.ticket;
      var exchange = text(config.sakura_sso_exchange_url) ||
        text(config.sakura_sso_api) ||
        readExtra(platform, "sakura_sso_exchange_url") ||
        readExtra(platform, "sakura_sso_api") ||
        state.exchangeUrl;
      if (!ticket) ticket = queryValue(exchange, "ticket");
      state.ticket = ticket;
      state.exchangeUrl = endpoint(exchange, "/sakura/sso/exchange");
      state.paymentUrl = state.exchangeUrl
        ? state.exchangeUrl.slice(0, -"/sakura/sso/exchange".length) + "/sakura/payment/order"
        : "";
      state.source = text(config.sakura_sso_source) || readExtra(platform, "sakura_sso_source") || state.source;
      state.configured = !!(state.ticket && /^[A-Za-z0-9_-]{32,256}$/.test(state.ticket) && state.exchangeUrl);
      return state.configured;
    },

    available: function () {
      return state.configured;
    },

    managed: function (platform) {
      bridge.configure(platform, {});
      return !!(platform && typeof platform.isAndroid === "function" && platform.isAndroid());
    },

    login: function (platform) {
      if (!state.configured && !bridge.configure(platform, {})) {
        console.error("[sakura] SSO launch parameters are missing or invalid");
        fail(platform, "missing_or_invalid_launch");
        return;
      }
      if (state.loginPending) return;
      state.failureNotified = false;
      state.loginPending = true;
      requestJson("POST", state.exchangeUrl, { ticket: state.ticket }, {}, function (error, payload) {
        state.loginPending = false;
        if (error || !payload || payload.ok !== true || !payload.accountId || !payload.token ||
            !payload.serverInfo || !payload.serverInfo.data) {
          console.error("[sakura] SSO exchange failed", error || payload);
          fail(platform, error && error.message ? error.message : "invalid_exchange_payload");
          return;
        }
        state.accountId = text(payload.accountId);
        state.token = text(payload.token);
        state.server = payload.serverInfo && payload.serverInfo.data ? payload.serverInfo.data : null;
        state.ticket = "";
        state.configured = false;
        platform.sakuraLoginSuccess({
          accountId: state.accountId,
          token: state.token,
          serverInfo: payload.serverInfo,
        });
      });
    },

    publishServerList: function (platform) {
      platform.sakuraPublishServerList();
    },

    publishServerDetail: function (platform, sid) {
      platform.sakuraPublishServerDetail(sid);
    },

    openPayment: function (platform, oldUrl, cfgid) {
      if (!state.accountId || !state.token || !state.paymentUrl) {
        console.error("[sakura] payment requested before SSO login");
        return;
      }
      var productId = text(cfgid) || queryValue(oldUrl, "cfgid");
      var sid = text(platform.sid) || text(state.server && state.server.sid) || queryValue(oldUrl, "sid");
      if (!/^\d+$/.test(productId) || !/^\d+$/.test(sid)) {
        console.error("[sakura] payment product/server id is invalid", productId, sid);
        return;
      }
      requestJson("POST", state.paymentUrl, {
        sid: Number(sid),
        cfgid: Number(productId),
        channel: "sakura",
      }, {
        "x-game-account-id": state.accountId,
        "x-game-token": state.token,
      }, function (error, payload) {
        var launchUrl = payload && paymentLaunchUrl(payload.launchUrl);
        if (error || !payload || payload.ok !== true || !launchUrl) {
          console.error("[sakura] payment order failed", error || payload);
          return;
        }
        platform.callNative("openPayUrl", { url: launchUrl });
      });
    },

    onResume: function (platform) {
      var orderId = readExtra(platform, "sakura_payment_order_id");
      var status = readExtra(platform, "sakura_payment_status");
      var balance = readExtra(platform, "sakura_payment_balance");
      var source = readExtra(platform, "sakura_payment_source") || readExtra(platform, "sakura_sso_source");
      if (!orderId) return;
      var payment = {
        gameOrderId: orderId,
        status: status,
        balance: balance,
        source: source,
      };
      state.lastPayment = payment;
      platform.sakuraPaymentResult(payment);
    },
  };

  root.SakuraBridge = bridge;
}(typeof globalThis !== "undefined" ? globalThis : (typeof window !== "undefined" ? window : this)));
