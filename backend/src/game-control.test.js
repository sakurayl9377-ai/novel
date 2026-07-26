import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import Fastify from "fastify";

const tempDir = fs.mkdtempSync(
  path.join(os.tmpdir(), "novel-game-control-test-"),
);
process.env.DB_PATH = path.join(tempDir, "game-control.sqlite");
process.env.TOKEN_SECRET = `game-control-token-${process.pid}`;
process.env.ADMIN_USERNAME = "game-control-admin";
process.env.ADMIN_PASSWORD = `game-control-password-${process.pid}`;

const { adminRequired, createSession } = await import("./auth.js");
const {
  ensureGameCatalogSchema,
} = await import("./game-catalog-service.js");
const {
  GAME_CONTROL_HELPER_PATH,
  runGameServiceControl,
} = await import("./game-service-control.js");
const { all, closeDb, migrate, run } = await import("./db.js");
const {
  adminGameControlRoutes,
} = await import("./routes-admin-game-control.js");
const { gameCatalogRoutes } = await import("./routes-game-catalog.js");
const { hashPassword } = await import("./security.js");

test.after(() => {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});

test("catalog visibility and service actions are admin-only and whitelisted", async () => {
  migrate();
  ensureGameCatalogSchema();
  const adminId = createUser("control-admin@example.test", "admin");
  const userId = createUser("control-user@example.test", "user");
  const adminToken = createSession(adminId);
  const userToken = createSession(userId);
  const controlCalls = [];
  let failNext = false;
  let stopGate = null;
  let statusGate = null;
  const statusFailures = new Set();
  const serviceStates = new Map([
    ["bailian", "stopped"],
    ["modao", "running"],
    ["kdjx", "running"],
  ]);

  const serviceControl = async (gameId, action, controlOptions = {}) => {
    controlCalls.push({ gameId, action, controlOptions });
    if (action === "status" && statusFailures.delete(gameId)) {
      throw controlError("game_control_timeout");
    }
    if (action === "status" && statusGate?.gameId === gameId) {
      statusGate.started.resolve();
      await statusGate.release.promise;
    }
    if (failNext) {
      failNext = false;
      throw controlError("game_control_action_failed");
    }
    if (action === "stop" && stopGate?.gameId === gameId) {
      stopGate.started.resolve();
      await stopGate.release.promise;
    }
    if (action === "stop") serviceStates.set(gameId, "stopped");
    if (action === "start" || action === "restart") {
      serviceStates.set(gameId, "running");
    }
    return fakeServiceStatus(gameId, serviceStates.get(gameId) || "stopped");
  };

  const app = Fastify({ logger: false });
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error:
        error.publicCode ||
        (status >= 500 ? "internal_error" : error.message),
    });
  });
  app.decorate("adminRequired", adminRequired);
  app.register(gameCatalogRoutes, {
    serviceControl,
    statusTimeoutMs: 1_250,
  });
  app.register(adminGameControlRoutes, { serviceControl });
  await app.ready();

  try {
    const initialCatalog = await request(app, "GET", "/games/catalog");
    assert.equal(initialCatalog.statusCode, 200);
    assert.equal(initialCatalog.headers["cache-control"], "no-store");
    assert.deepEqual(
      initialCatalog.json().games.map((game) => game.id),
      ["horse-race", "modao", "kdjx"],
    );
    assert.equal(
      initialCatalog.json().games.some((game) => "service" in game),
      false,
    );
    assert.equal(
      controlCalls.find(
        (call) => call.gameId === "modao" && call.action === "status",
      )?.controlOptions.timeoutMs,
      1_250,
    );

    serviceStates.set("modao", "stopped");
    const stoppedPublicCatalog = await request(
      app,
      "GET",
      "/games/catalog",
    );
    assert.deepEqual(
      stoppedPublicCatalog.json().games.map((game) => game.id),
      ["horse-race", "kdjx"],
    );
    assert.equal(
      stoppedPublicCatalog.json().games.some((game) => "service" in game),
      false,
    );

    serviceStates.set("modao", "unknown");
    const unknownPublicCatalog = await request(
      app,
      "GET",
      "/games/catalog",
    );
    assert.deepEqual(
      unknownPublicCatalog.json().games.map((game) => game.id),
      ["horse-race", "kdjx"],
    );

    statusFailures.add("modao");
    const unavailablePublicCatalog = await request(
      app,
      "GET",
      "/games/catalog",
    );
    assert.deepEqual(
      unavailablePublicCatalog.json().games.map((game) => game.id),
      ["horse-race", "kdjx"],
    );
    serviceStates.set("modao", "running");

    const unauthorized = await request(
      app,
      "GET",
      "/admin/games/control",
    );
    assert.equal(unauthorized.statusCode, 401);
    const forbidden = await request(
      app,
      "GET",
      "/admin/games/control",
      undefined,
      userToken,
    );
    assert.equal(forbidden.statusCode, 403);
    assert.equal(forbidden.json().error, "admin_required");

    const overview = await request(
      app,
      "GET",
      "/admin/games/control",
      undefined,
      adminToken,
    );
    assert.equal(overview.statusCode, 200);
    assert.deepEqual(
      overview.json().games.map((game) => game.id),
      ["horse-race", "bailian", "modao", "kdjx"],
    );
    const builtIn = overview
      .json()
      .games.find((game) => game.id === "horse-race");
    assert.equal(builtIn.controllable, false);
    assert.equal(builtIn.service.status, "unmanaged");
    assert.equal(
      overview.json().games.find((game) => game.id === "bailian").visible,
      false,
    );

    const showStopped = await request(
      app,
      "PATCH",
      "/admin/games/control/bailian/visibility",
      { visible: true },
      adminToken,
    );
    assert.equal(showStopped.statusCode, 409);
    assert.equal(showStopped.json().error, "game_service_not_running");

    const invalidVisibility = await request(
      app,
      "PATCH",
      "/admin/games/control/bailian/visibility",
      { visible: "yes" },
      adminToken,
    );
    assert.equal(invalidVisibility.statusCode, 400);
    assert.equal(invalidVisibility.json().error, "game_visibility_invalid");

    const startedBeforeShow = await request(
      app,
      "POST",
      "/admin/games/control/bailian/action",
      { action: "start" },
      adminToken,
    );
    assert.equal(startedBeforeShow.statusCode, 200);
    assert.equal(startedBeforeShow.json().game.visible, false);
    assert.equal(startedBeforeShow.json().game.service.status, "running");

    statusGate = {
      gameId: "bailian",
      started: deferred(),
      release: deferred(),
    };
    const showRequest = request(
      app,
      "PATCH",
      "/admin/games/control/bailian/visibility",
      { visible: true },
      adminToken,
    );
    await statusGate.started.promise;
    const restartWhileShowing = await request(
      app,
      "POST",
      "/admin/games/control/bailian/action",
      { action: "restart" },
      adminToken,
    );
    assert.equal(restartWhileShowing.statusCode, 409);
    assert.equal(restartWhileShowing.json().error, "game_control_busy");
    statusGate.release.resolve();
    const shown = await showRequest;
    statusGate = null;
    assert.equal(shown.statusCode, 200);
    assert.equal(shown.json().game.visible, true);
    const shownCatalog = await request(app, "GET", "/games/catalog");
    assert.deepEqual(
      shownCatalog.json().games.map((game) => game.id),
      ["horse-race", "bailian", "modao", "kdjx"],
    );

    const callsBeforeInjection = controlCalls.length;
    const injection = await request(
      app,
      "POST",
      "/admin/games/control/modao/action",
      { action: "restart; rm -rf /" },
      adminToken,
    );
    assert.equal(injection.statusCode, 400);
    assert.equal(injection.json().error, "game_action_invalid");
    assert.equal(controlCalls.length, callsBeforeInjection);

    const unknown = await request(
      app,
      "POST",
      "/admin/games/control/not-a-game/action",
      { action: "start" },
      adminToken,
    );
    assert.equal(unknown.statusCode, 404);
    assert.equal(unknown.json().error, "game_not_found");
    assert.equal(controlCalls.length, callsBeforeInjection);

    const unmanaged = await request(
      app,
      "POST",
      "/admin/games/control/horse-race/action",
      { action: "stop" },
      adminToken,
    );
    assert.equal(unmanaged.statusCode, 400);
    assert.equal(unmanaged.json().error, "game_not_controllable");
    assert.equal(controlCalls.length, callsBeforeInjection);

    stopGate = {
      gameId: "bailian",
      started: deferred(),
      release: deferred(),
    };
    const stopRequest = request(
      app,
      "POST",
      "/admin/games/control/bailian/action",
      { action: "stop" },
      adminToken,
    );
    await stopGate.started.promise;

    // Simulate another backend process writing a stale visible state while
    // systemd is still stopping. The completed stop must overwrite it.
    run(
      `UPDATE app_game_catalog_state
       SET visible = 1, updated_at = datetime('now')
       WHERE game_id = 'bailian'`,
    );
    const showWhileStopping = await request(
      app,
      "PATCH",
      "/admin/games/control/bailian/visibility",
      { visible: true },
      adminToken,
    );
    assert.equal(showWhileStopping.statusCode, 409);
    assert.equal(showWhileStopping.json().error, "game_control_busy");

    stopGate.release.resolve();
    const stopped = await stopRequest;
    stopGate = null;
    assert.equal(stopped.statusCode, 200);
    assert.equal(stopped.json().game.visible, false);
    assert.equal(stopped.json().game.service.status, "stopped");
    const hiddenCatalog = await request(app, "GET", "/games/catalog");
    assert.deepEqual(
      hiddenCatalog.json().games.map((game) => game.id),
      ["horse-race", "modao", "kdjx"],
    );

    const started = await request(
      app,
      "POST",
      "/admin/games/control/bailian/action",
      { action: "start" },
      adminToken,
    );
    assert.equal(started.statusCode, 200);
    assert.equal(started.json().game.visible, false);
    assert.equal(started.json().game.service.status, "running");

    failNext = true;
    const failed = await request(
      app,
      "POST",
      "/admin/games/control/modao/action",
      { action: "restart" },
      adminToken,
    );
    assert.equal(failed.statusCode, 503);
    assert.equal(failed.json().error, "game_control_action_failed");

    const events = all(
      `SELECT game_id, operation, result, error_code
       FROM game_service_control_events
       ORDER BY id ASC`,
    ).map((event) => ({ ...event }));
    assert.deepEqual(events, [
      {
        game_id: "bailian",
        operation: "start",
        result: "succeeded",
        error_code: "",
      },
      {
        game_id: "bailian",
        operation: "stop",
        result: "succeeded",
        error_code: "",
      },
      {
        game_id: "bailian",
        operation: "start",
        result: "succeeded",
        error_code: "",
      },
      {
        game_id: "modao",
        operation: "restart",
        result: "failed",
        error_code: "game_control_action_failed",
      },
    ]);
  } finally {
    await app.close();
  }
});

test("root helper invocation uses fixed executable and exact arguments", async () => {
  let invocation;
  const status = await runGameServiceControl("modao", "status", {
    execFileImpl: (file, args, options, callback) => {
      invocation = { file, args, options };
      callback(
        null,
        JSON.stringify({
          ok: true,
          data: {
            gameId: "modao",
            units: [
              unit("modao-redis.service", "running"),
              unit("modao-static.service", "running"),
              unit("modao-account.service", "running"),
              unit("modao-game.service", "running"),
            ],
          },
        }),
        "",
      );
    },
  });
  assert.equal(invocation.file, "sudo");
  assert.deepEqual(invocation.args, [
    "-n",
    GAME_CONTROL_HELPER_PATH,
    "modao",
    "status",
  ]);
  assert.equal(invocation.options.windowsHide, true);
  assert.equal(status.status, "running");
  assert.equal(status.active, true);
  assert.equal(status.units.length, 4);

  assert.throws(
    () =>
      runGameServiceControl("modao;touch /tmp/x", "status", {
        execFileImpl: () => assert.fail("must not execute"),
      }),
    /game_not_controllable/,
  );
  assert.throws(
    () =>
      runGameServiceControl("modao", "status;id", {
        execFileImpl: () => assert.fail("must not execute"),
      }),
    /game_action_invalid/,
  );

  await assert.rejects(
    runGameServiceControl("bailian", "status", {
      execFileImpl: (_file, _args, _options, callback) => {
        callback(
          null,
          JSON.stringify({
            ok: true,
            data: {
              gameId: "bailian",
              units: [unit("unexpected.service", "running")],
            },
          }),
          "",
        );
      },
    }),
    /game_control_unavailable/,
  );
});

function createUser(email, role) {
  return Number(
    run(
      `INSERT INTO users
         (email, nickname, password_hash, role, status)
       VALUES (?, ?, ?, ?, 'active')`,
      [email, email, hashPassword("password"), role],
    ).lastInsertRowid,
  );
}

function fakeServiceStatus(gameId, status) {
  const active = status === "running";
  const names =
    gameId === "bailian"
      ? ["bailian-game.service", "bailian-backstage.service"]
      : [
          "modao-redis.service",
          "modao-static.service",
          "modao-account.service",
          "modao-game.service",
        ];
  return {
    unit: gameId,
    status,
    active,
    enabled: true,
    checkedAt: new Date().toISOString(),
    units: names.map((name) => ({
      unit: name,
      status,
      active,
      enabled: true,
      unitFileState: "enabled",
    })),
  };
}

function unit(name, status) {
  return {
    unit: name,
    status,
    active: status === "running",
    enabled: true,
    unitFileState: "enabled",
  };
}

function controlError(code) {
  const error = new Error(code);
  error.code = code;
  error.publicCode = code;
  error.statusCode = 503;
  return error;
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function request(app, method, url, payload, token = "") {
  return app.inject({
    method,
    url,
    headers: token ? { authorization: `Bearer ${token}` } : {},
    ...(payload === undefined ? {} : { payload }),
  });
}
