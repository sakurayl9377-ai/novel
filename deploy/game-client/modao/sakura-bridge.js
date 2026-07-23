(function (root) {
  "use strict";

  var AUTH_STATE_VERSION = 1;
  var AUTH_REQUEST_MAX_AGE_MS = 10 * 60 * 1000;
  var SESSION_EXPIRY_SKEW_MS = 30 * 1000;
  var NOVEL_APP_SOURCE = "com.novel.novel_app";
  var AUTH_REQUEST_PREFIX = "sakura-novel://modao-auth/request?requestId=";

  var state = {
    storageLoaded: false,
    configured: false,
    configError: "",
    loginPending: false,
    ticket: "",
    callbackRequestId: "",
    exchangeUrl: "",
    paymentUrl: "",
    source: "",
    session: null,
    pendingRequest: null,
    lastPayment: null,
    failureNotified: false,
    expiredLocalSession: false,
  };

  function text(value) {
    return value === null || value === undefined ? "" : String(value).trim();
  }

  function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
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

  function platformCall(platform, name, args) {
    try {
      if (platform && typeof platform[name] === "function") {
        return platform[name].apply(platform, args || []);
      }
    } catch (error) {
      console.error("[sakura] platform call failed", name, error);
    }
    return "";
  }

  function readExtra(platform, name) {
    return text(nativeCall(platform, "takeSakuraExtra", [name], true));
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

  function requestId(value) {
    var result = text(value);
    return /^[A-Za-z0-9._:-]{32,128}$/.test(result) ? result : "";
  }

  function token(value) {
    var result = text(value);
    return /^[A-Za-z0-9._:-]{16,256}$/.test(result) ? result : "";
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

  function normalizeServerInfo(value) {
    if (!isPlainObject(value) || !isPlainObject(value.data)) return null;
    var data = value.data;
    var sid = text(data.sid);
    var name = text(data.name);
    var ip = text(data.ip);
    var serverToken = token(data.token);
    var port = Number(data.port);
    if (
      !/^\d{1,4}$/.test(sid) ||
      !name ||
      !ip ||
      !Number.isInteger(port) ||
      port < 1 ||
      port > 65535 ||
      !serverToken
    ) {
      return null;
    }
    return {
      code: Number(value.code || 1),
      msg: text(value.msg || "ok"),
      data: {
        sid: sid,
        name: name,
        ip: ip,
        port: port,
        token: serverToken,
      },
    };
  }

  function normalizeSession(value, requireFresh) {
    if (!isPlainObject(value)) return null;
    var accountId = text(value.accountId);
    var gameToken = token(value.token);
    var tokenExpiresAt = Date.parse(text(value.tokenExpiresAt));
    var exchange = endpoint(value.exchangeUrl, "/sakura/sso/exchange");
    var serverInfo = normalizeServerInfo(value.serverInfo);
    if (
      !/^[A-Za-z0-9._:-]{1,64}$/.test(accountId) ||
      !gameToken ||
      !Number.isFinite(tokenExpiresAt) ||
      !exchange ||
      !serverInfo
    ) {
      return null;
    }
    if (requireFresh && tokenExpiresAt <= Date.now() + SESSION_EXPIRY_SKEW_MS) {
      return null;
    }
    return {
      accountId: accountId,
      token: gameToken,
      tokenExpiresAt: new Date(tokenExpiresAt).toISOString(),
      exchangeUrl: exchange,
      serverInfo: serverInfo,
    };
  }

  function normalizePendingRequest(value) {
    if (!isPlainObject(value)) return null;
    var id = requestId(value.requestId);
    var createdAt = Number(value.createdAt);
    if (
      !id ||
      !Number.isFinite(createdAt) ||
      createdAt <= 0 ||
      Date.now() - createdAt > AUTH_REQUEST_MAX_AGE_MS ||
      createdAt - Date.now() > 60 * 1000
    ) {
      return null;
    }
    return { requestId: id, createdAt: createdAt };
  }

  function loadPersistentState(platform) {
    if (state.storageLoaded) return;
    var raw = text(platformCall(platform, "sakuraReadAuthState"));
    state.storageLoaded = true;
    if (!raw) return;
    var parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      platformCall(platform, "sakuraWriteAuthState", [""]);
      return;
    }
    if (!isPlainObject(parsed) || parsed.version !== AUTH_STATE_VERSION) {
      platformCall(platform, "sakuraWriteAuthState", [""]);
      return;
    }
    state.pendingRequest = normalizePendingRequest(parsed.pendingRequest);
    if (parsed.session) {
      state.session = normalizeSession(parsed.session, true);
      state.expiredLocalSession = !state.session &&
        !!normalizeSession(parsed.session, false);
    }
    if (!state.pendingRequest && !state.session) {
      platformCall(platform, "sakuraWriteAuthState", [""]);
    }
  }

  function persistState(platform) {
    var payload = { version: AUTH_STATE_VERSION };
    if (state.pendingRequest) payload.pendingRequest = state.pendingRequest;
    if (state.session) payload.session = state.session;
    if (!state.pendingRequest && !state.session) {
      platformCall(platform, "sakuraWriteAuthState", [""]);
      return;
    }
    platformCall(platform, "sakuraWriteAuthState", [JSON.stringify(payload)]);
  }

  function clearTicket() {
    state.configured = false;
    state.configError = "";
    state.ticket = "";
    state.callbackRequestId = "";
  }

  function clearSession(platform) {
    state.session = null;
    state.expiredLocalSession = false;
    state.pendingRequest = null;
    state.exchangeUrl = "";
    state.paymentUrl = "";
    clearTicket();
    persistState(platform);
  }

  function notifyRequired(platform, reason) {
    platformCall(platform, "sakuraLoginRequired", [text(reason) || "missing_session"]);
  }

  function notifyFailure(platform, reason) {
    if (state.failureNotified) return;
    state.failureNotified = true;
    platformCall(platform, "sakuraLoginFailure", [text(reason) || "sso_failed"]);
  }

  function notifyPaymentFailure(platform, reason) {
    platformCall(platform, "sakuraPaymentFailure", [
      text(reason) || "payment_unavailable",
    ]);
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
          finish(
            new Error(payload && payload.error ? payload.error : "http_" + xhr.status),
            payload,
            xhr.status
          );
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

  function applySession(platform, session) {
    state.session = session;
    state.expiredLocalSession = false;
    state.exchangeUrl = session.exchangeUrl;
    state.paymentUrl = session.exchangeUrl.slice(
      0,
      -"/sakura/sso/exchange".length
    ) + "/sakura/payment/order";
    platform.sakuraLoginSuccess({
      accountId: session.accountId,
      token: session.token,
      tokenExpiresAt: session.tokenExpiresAt,
      serverInfo: session.serverInfo,
    });
  }

  var bridge = {
    configure: function (platform, nativeConfig) {
      loadPersistentState(platform);
      var config = nativeConfig || {};
      var receivedTicket = text(config.sakura_sso_ticket) ||
        readExtra(platform, "sakura_sso_ticket");
      var receivedExchange = text(config.sakura_sso_exchange_url) ||
        text(config.sakura_sso_api) ||
        readExtra(platform, "sakura_sso_exchange_url") ||
        readExtra(platform, "sakura_sso_api");
      var receivedSource = text(config.sakura_sso_source) ||
        readExtra(platform, "sakura_sso_source");
      var receivedRequestId = text(config.sakura_sso_request_id) ||
        readExtra(platform, "sakura_sso_request_id");

      if (receivedTicket) state.ticket = receivedTicket;
      if (receivedExchange) state.exchangeUrl = endpoint(
        receivedExchange,
        "/sakura/sso/exchange"
      );
      if (receivedSource) state.source = receivedSource;
      if (receivedRequestId) state.callbackRequestId = receivedRequestId;

      state.configError = "";
      if (state.ticket) {
        if (!/^[A-Za-z0-9_-]{32,256}$/.test(state.ticket)) {
          state.configError = "invalid_ticket";
        } else if (!state.exchangeUrl) {
          state.configError = "invalid_exchange_url";
        } else if (state.source !== NOVEL_APP_SOURCE) {
          state.configError = "invalid_callback_source";
        } else if (
          state.pendingRequest &&
          state.callbackRequestId &&
          requestId(state.callbackRequestId) !== state.pendingRequest.requestId
        ) {
          state.configError = "callback_request_mismatch";
        } else if (
          !state.pendingRequest &&
          state.callbackRequestId &&
          !requestId(state.callbackRequestId)
        ) {
          state.configError = "invalid_callback_request";
        }
      }
      state.configured = !!(state.ticket && !state.configError);
      return state.configured;
    },

    available: function () {
      return state.configured || !!state.session;
    },

    managed: function (platform) {
      bridge.configure(platform, {});
      return !!(
        platform &&
        typeof platform.isAndroid === "function" &&
        platform.isAndroid()
      );
    },

    start: function (platform) {
      if (!bridge.managed(platform)) return false;
      state.failureNotified = false;
      if (state.configError) {
        var startError = state.configError;
        clearSession(platform);
        notifyFailure(platform, startError);
        return true;
      }
      if (state.configured) {
        bridge.login(platform);
        return true;
      }
      if (state.session) {
        applySession(platform, state.session);
        return true;
      }
      notifyRequired(
        platform,
        state.expiredLocalSession ? "session_expired" : "missing_session"
      );
      return true;
    },

    authorize: function (platform) {
      if (!bridge.managed(platform)) return false;
      state.failureNotified = false;
      var id = requestId(platformCall(platform, "sakuraCreateRequestId"));
      if (!id) {
        notifyFailure(platform, "request_id_unavailable");
        return false;
      }
      state.pendingRequest = { requestId: id, createdAt: Date.now() };
      state.configError = "";
      persistState(platform);
      var opened = platformCall(platform, "sakuraOpenAuthorization", [
        AUTH_REQUEST_PREFIX + encodeURIComponent(id),
      ]);
      if (opened === false) {
        state.pendingRequest = null;
        persistState(platform);
        notifyFailure(platform, "authorization_app_unavailable");
        return false;
      }
      return true;
    },

    login: function (platform) {
      if (!state.configured && !bridge.configure(platform, {})) {
        if (state.configError) {
          var loginError = state.configError;
          clearSession(platform);
          notifyFailure(platform, loginError);
        } else {
          notifyRequired(platform, "missing_session");
        }
        return;
      }
      if (state.loginPending) return;
      state.failureNotified = false;
      state.loginPending = true;
      platformCall(platform, "sakuraLoginPending");
      requestJson(
        "POST",
        state.exchangeUrl,
        { ticket: state.ticket },
        {},
        function (error, payload) {
          state.loginPending = false;
          if (error) {
            clearSession(platform);
            notifyFailure(platform, error.message || "sso_exchange_failed");
            return;
          }
          var session = normalizeSession({
            accountId: payload && payload.accountId,
            token: payload && payload.token,
            tokenExpiresAt: payload && payload.tokenExpiresAt,
            exchangeUrl: state.exchangeUrl,
            serverInfo: payload && payload.serverInfo,
          }, true);
          if (!payload || payload.ok !== true || !session) {
            clearSession(platform);
            notifyFailure(platform, "invalid_exchange_payload");
            return;
          }
          state.pendingRequest = null;
          clearTicket();
          state.session = session;
          persistState(platform);
          applySession(platform, session);
        }
      );
    },

    invalidate: function (platform, reason) {
      clearSession(platform);
      notifyRequired(platform, text(reason) || "session_rejected");
    },

    publishServerList: function (platform) {
      platform.sakuraPublishServerList();
    },

    publishServerDetail: function (platform, sid) {
      platform.sakuraPublishServerDetail(sid);
    },

    openPayment: function (platform, oldUrl, cfgid) {
      var session = normalizeSession(state.session, true);
      if (!session || !state.paymentUrl) {
        bridge.invalidate(platform, "session_expired");
        return;
      }
      var productId = text(cfgid) || queryValue(oldUrl, "cfgid");
      var sid = text(platform.sid) ||
        text(session.serverInfo && session.serverInfo.data.sid) ||
        queryValue(oldUrl, "sid");
      if (!/^\d+$/.test(productId) || !/^\d+$/.test(sid)) {
        console.error("[sakura] payment product/server id is invalid", productId, sid);
        notifyPaymentFailure(platform, "invalid_payment_request");
        return;
      }
      requestJson(
        "POST",
        state.paymentUrl,
        {
          sid: Number(sid),
          cfgid: Number(productId),
          channel: "sakura",
        },
        {
          "x-game-account-id": session.accountId,
          "x-game-token": session.token,
        },
        function (error, payload, status) {
          if (status === 401) {
            bridge.invalidate(platform, "session_rejected");
            return;
          }
          var launchUrl = payload && paymentLaunchUrl(payload.launchUrl);
          if (error || !payload || payload.ok !== true || !launchUrl) {
            console.error("[sakura] payment order failed", error || payload);
            notifyPaymentFailure(platform, "payment_order_failed");
            return;
          }
          if (platformCall(platform, "sakuraOpenPayment", [launchUrl]) === false) {
            notifyPaymentFailure(platform, "payment_app_unavailable");
          }
        }
      );
    },

    onResume: function (platform) {
      var configured = bridge.configure(platform, {});
      if (state.configError) {
        var resumeError = state.configError;
        clearSession(platform);
        notifyFailure(platform, resumeError);
      } else if (configured) {
        bridge.login(platform);
      }

      var orderId = readExtra(platform, "sakura_payment_order_id");
      var status = readExtra(platform, "sakura_payment_status");
      var balance = readExtra(platform, "sakura_payment_balance");
      var source = readExtra(platform, "sakura_payment_source") ||
        readExtra(platform, "sakura_sso_source");
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
