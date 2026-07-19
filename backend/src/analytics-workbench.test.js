import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-analytics-ops-"));
const adminPassword = `analytics-admin-${process.pid}-${Date.now()}`;
process.env.DB_PATH = path.join(tempDir, "analytics.sqlite");
process.env.TOKEN_SECRET = `analytics-token-${process.pid}-${Date.now()}`;
process.env.SETTINGS_ENCRYPTION_KEY = `analytics-settings-${process.pid}-${Date.now()}`;
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = adminPassword;

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { run } = await import("./db.js");

test("quality analytics keeps time, filter, and error-group contracts coherent", async () => {
  const app = await buildServer();
  try {
    insertTelemetry({
      installId: "analytics-install-a",
      sessionId: "analytics-session-a",
      eventName: "screen_view",
      screen: "novel_detail",
      durationMs: 1200,
      versionName: "5.4.0",
      versionCode: 540,
      offsetHours: 1,
    });
    insertTelemetry({
      installId: "analytics-install-a",
      sessionId: "analytics-session-a",
      eventName: "frame_metrics",
      metadata: JSON.stringify({
        frames: 120,
        slow16: 12,
        slow32: 4,
        frozen700: 1,
        maxBuildMs: 45,
        maxRasterMs: 32,
      }),
      versionName: "5.4.0",
      versionCode: 540,
      offsetHours: 1,
    });
    insertTelemetry({
      installId: "analytics-install-b",
      sessionId: "analytics-session-b",
      eventName: "app_open",
      versionName: "5.3.0",
      versionCode: 530,
      offsetHours: 2,
    });
    insertTelemetry({
      installId: "analytics-install-old",
      sessionId: "analytics-session-old",
      eventName: "screen_view",
      screen: "old_screen",
      versionName: "5.1.0",
      versionCode: 510,
      offsetHours: 72,
    });

    insertError({
      fingerprint: "analytics-fp-crash",
      errorType: "FatalError",
      message: "The fatal sample",
      stack: "FatalError: The fatal sample\n at analytics.js:10",
      screen: "novel_detail",
      fatal: 1,
      versionName: "5.4.0",
      versionCode: 540,
      installId: "analytics-install-a",
      sessionId: "analytics-session-a",
      offsetHours: 2,
    });
    insertError({
      fingerprint: "analytics-fp-crash",
      errorType: "NonFatalAfter",
      message: "A later non-fatal sample",
      screen: "novel_detail",
      fatal: 0,
      versionName: "5.4.0",
      versionCode: 540,
      installId: "analytics-install-a",
      sessionId: "analytics-session-a",
      offsetHours: 1,
    });
    insertError({
      fingerprint: "analytics-fp-warning",
      errorType: "NetworkError",
      message: "Request failed",
      screen: "home",
      fatal: 0,
      versionName: "5.3.0",
      versionCode: 530,
      installId: "analytics-install-b",
      sessionId: "analytics-session-b",
      offsetHours: 3,
    });
    insertError({
      fingerprint: "analytics-fp-error-only-day",
      errorType: "OldNetworkError",
      message: "An error without an event on its day",
      fatal: 0,
      versionName: "5.3.0",
      versionCode: 530,
      installId: "analytics-install-c",
      sessionId: "analytics-session-c",
      offsetHours: 30,
    });
    insertError({
      fingerprint: "analytics-fp-old",
      errorType: "OldError",
      fatal: 1,
      versionName: "5.1.0",
      versionCode: 510,
      installId: "analytics-install-old",
      sessionId: "analytics-session-old",
      offsetHours: 72,
    });

    const login = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: adminPassword,
    });
    const token = login.token;

    const overview = await request(
      app,
      "GET",
      "/admin/analytics/overview?days=1",
      undefined,
      token,
    );
    assert.equal(overview.days, 1);
    assert.equal(overview.dataQuality.eventCount, 3);
    assert.equal(overview.dataQuality.errorCount, 3);
    assert.equal(overview.dataQuality.reportingInstalls, 2);
    assert.ok(overview.dataQuality.lastEventAt);
    assert.ok(overview.dataQuality.lastErrorAt);
    assert.equal(overview.summary.events, 3);
    assert.equal(overview.summary.activeInstalls, 2);
    assert.equal(overview.summary.sessions, 2);
    assert.equal(overview.summary.errors, 3);
    assert.equal(overview.summary.fatalErrors, 1);
    assert.equal(overview.summary.errorGroups, 2);
    assert.equal(overview.summary.crashFreeRate, 0.5);
    assert.equal(overview.frameMetrics.frames, 120);
    assert.equal(overview.frameMetrics.slow16, 12);
    assert.equal(overview.frameMetrics.frozen700, 1);
    assert.equal(overview.topScreens[0].screen, "novel_detail");
    assert.equal(overview.versions[0].versionCode, 540);

    assert.equal(
      overview.daily.reduce((total, item) => total + item.events, 0),
      overview.summary.events,
    );
    assert.equal(
      overview.daily.reduce((total, item) => total + item.errors, 0),
      overview.summary.errors,
    );

    const twoDayOverview = await request(
      app,
      "GET",
      "/admin/analytics/overview?days=2",
      undefined,
      token,
    );
    assert.ok(twoDayOverview.daily.some((item) => item.errors > 0 && item.events === 0));

    const fatalErrors = await request(
      app,
      "GET",
      "/admin/analytics/errors?days=1&fatal=1&page=1&pageSize=20",
      undefined,
      token,
    );
    assert.equal(fatalErrors.total, 1);
    assert.equal(fatalErrors.items[0].fingerprint, "analytics-fp-crash");
    assert.equal(fatalErrors.items[0].occurrences, 1);
    assert.equal(fatalErrors.items[0].fatalCount, 1);
    assert.equal(fatalErrors.items[0].fatal, true);
    assert.equal(fatalErrors.items[0].type, "FatalError");

    const versionErrors = await request(
      app,
      "GET",
      "/admin/analytics/errors?days=1&versionCode=530&page=1&pageSize=20",
      undefined,
      token,
    );
    assert.equal(versionErrors.total, 1);
    assert.equal(versionErrors.items[0].fingerprint, "analytics-fp-warning");
    assert.equal(versionErrors.items[0].versionCode, 530);

    const searchedErrors = await request(
      app,
      "GET",
      "/admin/analytics/errors?days=1&q=FatalError&page=1&pageSize=20",
      undefined,
      token,
    );
    assert.equal(searchedErrors.total, 1);
    assert.equal(searchedErrors.items[0].fingerprint, "analytics-fp-crash");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function insertTelemetry({
  installId,
  sessionId,
  eventName,
  screen = "",
  durationMs = 0,
  success = 1,
  metadata = "{}",
  versionName = "",
  versionCode = 0,
  offsetHours,
}) {
  const offset = `-${offsetHours} hours`;
  run(
    `INSERT INTO app_telemetry_events
       (install_id, session_id, event_name, screen, duration_ms, success,
        metadata, version_name, version_code, platform, occurred_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'android', datetime('now', ?), datetime('now', ?))`,
    [
      installId,
      sessionId,
      eventName,
      screen,
      durationMs,
      success,
      metadata,
      versionName,
      versionCode,
      offset,
      offset,
    ],
  );
}

function insertError({
  fingerprint,
  errorType,
  message = "",
  stack = "",
  screen = "",
  fatal = 0,
  versionName = "",
  versionCode = 0,
  installId,
  sessionId,
  offsetHours,
}) {
  const offset = `-${offsetHours} hours`;
  run(
    `INSERT INTO app_error_reports
       (install_id, session_id, fingerprint, error_type, message, stack, screen,
        fatal, metadata, version_name, version_code, platform, occurred_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', ?, ?, 'android', datetime('now', ?), datetime('now', ?))`,
    [
      installId,
      sessionId,
      fingerprint,
      errorType,
      message,
      stack,
      screen,
      fatal,
      versionName,
      versionCode,
      offset,
      offset,
    ],
  );
}

async function request(app, method, route, body, token = "") {
  const response = await app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    payload: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}
