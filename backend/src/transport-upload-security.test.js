import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const tempDir = fs.mkdtempSync(
  path.join(os.tmpdir(), "novel-transport-upload-security-"),
);
process.env.DB_PATH = path.join(tempDir, "transport-upload-security.sqlite");
process.env.TOKEN_SECRET = "transport-upload-security-token-secret";
process.env.ADMIN_USERNAME = "transport-upload-security-admin";
process.env.ADMIN_PASSWORD = "transport-upload-security-admin-password";
process.env.DBZY_SYNC_ENABLED = "false";

const Fastify = (await import("fastify")).default;
const websocketPlugin = (await import("@fastify/websocket")).default;
const WebSocket = (await import("ws")).default;
const {
  authRequired,
  createSession,
} = await import("./auth.js");
const { config } = await import("./config.js");
const {
  closeDb,
  db,
  migrate,
  one,
  registerManagedUploadDatabaseFunctions,
  run,
} = await import("./db.js");
const {
  redactSensitiveText,
  redactSensitiveUrl,
  secureErrorSerializer,
  secureLoggerOptions,
  secureRequestSerializer,
} = await import("./log-security.js");
const { userRoutes } = await import("./routes-user.js");
const { loadAudioBytes } = await import("./speech-service.js");
const {
  isManagedUploadRetired,
  retireManagedUploadKey,
  retireManagedUploadUrls,
  retryRetiredUploadDeletes,
  startUploadOrphanSweeper,
  stopUploadOrphanSweeper,
} = await import("./upload-lifecycle.js");
const {
  pruneOrphanedUploads,
  pruneOrphanedUserUploads,
  writeUploadAtomically,
} = await import("./upload-security.js");
const {
  registerWebSockets,
  websocketSecurityInternals,
} = await import("./websocket.js");

test("transport and upload security regressions", async (t) => {
  config.rootDir = tempDir;
  config.apiPrefix = "/api";
  config.uploadMaxFilesPerUser = 100;
  config.uploadMaxBytesPerUser = 100 * 1024 * 1024;
  config.uploadOrphanGraceMs = 60_000;
  migrate();

  try {
    await t.test("websocket authentication and payload boundaries are fail closed", () => {
      const warnings = [];
      const request = {
        headers: { authorization: "Bearer header-token" },
        log: { warn: (...args) => warnings.push(args) },
      };
      assert.equal(
        websocketSecurityInternals.websocketToken(
          request,
          new URLSearchParams("token=query-token"),
          { allowLegacyWebSocketQueryToken: true },
        ),
        "header-token",
      );
      assert.equal(warnings.length, 0);

      assert.equal(
        websocketSecurityInternals.websocketToken(
          { headers: {}, log: request.log },
          new URLSearchParams("token=query-token"),
          { allowLegacyWebSocketQueryToken: false },
        ),
        "",
      );
      assert.equal(
        websocketSecurityInternals.websocketToken(
          {
            headers: { authorization: "Basic malformed" },
            log: request.log,
          },
          new URLSearchParams("token=query-token"),
          { allowLegacyWebSocketQueryToken: true },
        ),
        "",
      );
      assert.equal(
        websocketSecurityInternals.websocketToken(
          { headers: {}, log: request.log },
          new URLSearchParams("token=legacy-token"),
          { allowLegacyWebSocketQueryToken: true },
        ),
        "legacy-token",
      );
      assert.equal(warnings.length, 1);
      assert.equal(JSON.stringify(warnings).includes("legacy-token"), false);

      assert.deepEqual(
        websocketSecurityInternals.decodeSocketPayload(
          Buffer.from("binary"),
          true,
          1024,
        ),
        { ok: false, code: 1003, reason: "binary_not_supported" },
      );
      assert.equal(
        websocketSecurityInternals.decodeSocketPayload(
          Buffer.from('{"value":"too large"}'),
          false,
          4,
        ).code,
        1009,
      );
      assert.deepEqual(
        websocketSecurityInternals.decodeSocketPayload(
          Buffer.from("not-json"),
          false,
          1024,
        ),
        { ok: false, code: 1007, reason: "invalid_json" },
      );
      assert.deepEqual(
        websocketSecurityInternals.decodeSocketPayload(
          Buffer.from("[]"),
          false,
          1024,
        ),
        { ok: false, code: 1007, reason: "invalid_payload" },
      );

      const socket = new EventEmitter();
      socket.readyState = 1;
      let closed = null;
      socket.close = (code, reason) => {
        closed = { code, reason };
      };
      websocketSecurityInternals.onSocketMessage(
        socket,
        { log: { error() {} } },
        { websocketMaxPayloadBytes: 1024 },
        () => {
          throw new Error("forced_handler_failure");
        },
      );
      socket.emit("message", Buffer.from('{"type":"ping"}'), false);
      assert.deepEqual(closed, { code: 1011, reason: "internal_error" });
    });

    await t.test("request URLs, bearer credentials, and errors are redacted", () => {
      const secret = "do-not-log-this-token";
      const url = `/ws/chat?roomId=global&token=${secret}`;
      const safeUrl = redactSensitiveUrl(url);
      assert.equal(safeUrl.includes(secret), false);
      assert.match(safeUrl, /token=%5BREDACTED%5D/);

      const safeText = redactSensitiveText(
        `failed Authorization: Bearer ${secret} while opening ${url}`,
      );
      assert.equal(safeText.includes(secret), false);
      assert.match(safeText, /Bearer \[REDACTED\]/);

      const serializedRequest = secureRequestSerializer({
        method: "GET",
        url,
        headers: { host: "localhost" },
        socket: { remoteAddress: "127.0.0.1", remotePort: 1234 },
      });
      assert.equal(serializedRequest.url.includes(secret), false);

      const serializedError = secureErrorSerializer(
        new Error(`upstream rejected Bearer ${secret}`),
      );
      assert.equal(serializedError.message.includes(secret), false);
      assert.equal(serializedError.stack.includes(secret), false);

      let loggedArguments = [];
      secureLoggerOptions().hooks.logMethod.call(
        {},
        [new Error(`direct logger failure Bearer ${secret}`)],
        function (...args) {
          loggedArguments = args;
        },
      );
      assert.equal(loggedArguments[0].message.includes(secret), false);
      assert.equal(loggedArguments[0].stack.includes(secret), false);
    });

    await t.test("atomic writes and stale orphan pruning leave referenced files intact", async () => {
      const atomicDir = path.join(tempDir, "atomic-writes");
      let partialPath = "";
      await assert.rejects(
        writeUploadAtomically({
          directory: atomicDir,
          fileName: "1-write-failure.png",
          bytes: Buffer.from("png"),
          operations: {
            writeFile: async (filePath, bytes) => {
              partialPath = filePath;
              await fs.promises.writeFile(filePath, bytes);
              throw new Error("forced_write_failure");
            },
          },
        }),
        /forced_write_failure/,
      );
      assert.equal(fs.existsSync(partialPath), false);
      assert.equal(
        fs.existsSync(path.join(atomicDir, "1-write-failure.png")),
        false,
      );

      let renameTemporaryPath = "";
      const existingFinal = path.join(atomicDir, "1-rename-failure.png");
      await fs.promises.writeFile(existingFinal, "existing-content");
      await assert.rejects(
        writeUploadAtomically({
          directory: atomicDir,
          fileName: "1-rename-failure.png",
          bytes: Buffer.from("png"),
          operations: {
            rename: async (temporaryPath) => {
              renameTemporaryPath = temporaryPath;
              throw new Error("forced_rename_failure");
            },
          },
        }),
        /forced_rename_failure/,
      );
      assert.equal(fs.existsSync(renameTemporaryPath), false);
      assert.equal(fs.existsSync(existingFinal), true);
      assert.equal(
        await fs.promises.readFile(existingFinal, "utf8"),
        "existing-content",
      );

      const avatarDir = path.join(tempDir, "data", "uploads", "avatars");
      await fs.promises.mkdir(avatarDir, { recursive: true });
      const referenced = path.join(avatarDir, "987654-referenced.png");
      const orphan = path.join(avatarDir, "987654-orphan.png");
      const young = path.join(avatarDir, "987654-young.png");
      const otherUser = path.join(avatarDir, "123456-other.png");
      const lateReferenced = path.join(avatarDir, "222222-late-reference.png");
      const staleTemporary = path.join(
        avatarDir,
        ".987654-crashed.png.11111111-1111-1111-1111-111111111111.uploading",
      );
      await Promise.all(
        [
          referenced,
          orphan,
          young,
          otherUser,
          lateReferenced,
          staleTemporary,
        ].map((file) =>
          fs.promises.writeFile(file, "test"),
        ),
      );
      const oldTime = new Date(Date.now() - 5 * 60_000);
      await Promise.all(
        [referenced, orphan, otherUser, lateReferenced, staleTemporary].map((file) =>
          fs.promises.utimes(file, oldTime, oldTime),
        ),
      );

      const removed = await pruneOrphanedUserUploads({
        rootDir: tempDir,
        apiPrefix: "/api",
        folders: new Set(["avatars"]),
        userId: 987654,
        referencedUrls: [
          "https://example.test/api/uploads/profile/avatars/987654-referenced.png",
        ],
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: 60_000,
      });
      assert.equal(removed, 1);
      assert.equal(fs.existsSync(referenced), true);
      assert.equal(fs.existsSync(orphan), false);
      assert.equal(fs.existsSync(young), true);
      assert.equal(fs.existsSync(otherUser), true);

      const globallyRemoved = await pruneOrphanedUploads({
        rootDir: tempDir,
        apiPrefix: "/api",
        folders: new Set(["avatars"]),
        referencedUrls: [
          "https://example.test/api/uploads/profile/avatars/987654-referenced.png",
        ],
        refreshReferencedUrls: () => [
          "https://example.test/api/uploads/profile/avatars/987654-referenced.png",
          "https://example.test/api/uploads/profile/avatars/222222-late-reference.png",
        ],
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: 60_000,
      });
      assert.equal(globallyRemoved, 2);
      assert.equal(fs.existsSync(referenced), true);
      assert.equal(fs.existsSync(young), true);
      assert.equal(fs.existsSync(otherUser), false);
      assert.equal(fs.existsSync(lateReferenced), true);
      assert.equal(fs.existsSync(staleTemporary), false);

      const scheduledOrphan = path.join(avatarDir, "333333-scheduled.png");
      await fs.promises.writeFile(scheduledOrphan, "test");
      await fs.promises.utimes(scheduledOrphan, oldTime, oldTime);
      startUploadOrphanSweeper();
      await stopUploadOrphanSweeper();
      assert.equal(fs.existsSync(scheduledOrphan), false);
    });

    await t.test("retirement markers serialize references and survive delete failures", async () => {
      for (const [table, column] of [
        ["users", "avatar_url"],
        ["users", "profile_banner_url"],
        ["users", "dynamic_avatar_url"],
        ["profile_photos", "image_url"],
        ["chat_messages", "media_url"],
        ["chat_rooms", "avatar_url"],
        ["content_catalog", "cover_url"],
        ["home_placements", "custom_image_url"],
        ["campaigns", "banner_url"],
        ["ai_novels", "cover_url"],
        ["shop_items", "asset_value"],
        ["app_settings", "value"],
      ]) {
        for (const name of [
          `trg_retired_upload_${table}_${column}_insert`,
          `trg_retired_upload_${table}_${column}_update`,
          `trg_active_upload_${table}_${column}_retirement`,
        ]) {
          assert.equal(
            Boolean(one(
              "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = ?",
              [name],
            )),
            true,
            name,
          );
        }
      }

      const user = insertUser("retirement-race@example.test", "retirement-user");
      const avatarDir = path.join(tempDir, "data", "uploads", "avatars");
      await fs.promises.mkdir(avatarDir, { recursive: true });
      const secondConnection = new DatabaseSync(process.env.DB_PATH);
      registerManagedUploadDatabaseFunctions(secondConnection);
      secondConnection.exec("PRAGMA busy_timeout = 0");

      try {
        const referencedFileName = `${user.id}-already-referenced.png`;
        const referencedPath = path.join(avatarDir, referencedFileName);
        const referencedUrl =
          `https://example.test/api/uploads/profile/avatars/${referencedFileName}`;
        await fs.promises.writeFile(referencedPath, "referenced");
        run("UPDATE users SET avatar_url = ? WHERE id = ?", [
          referencedUrl,
          user.id,
        ]);

        assert.throws(
          () => secondConnection.prepare(
            `INSERT INTO managed_upload_retirements
               (storage_key, folder, file_name, owner_user_id)
             VALUES (?, 'avatars', ?, ?)`,
          ).run(
            `avatars/${referencedFileName}`,
            referencedFileName,
            user.id,
          ),
          /managed_upload_still_referenced/,
        );
        const skipped = retireManagedUploadUrls({
          userId: user.id,
          urls: [referencedUrl],
        });
        assert.equal(skipped.retiredCount, 0);
        assert.equal(fs.existsSync(referencedPath), true);
        run("UPDATE users SET avatar_url = '' WHERE id = ?", [user.id]);

        const fileName = `${user.id}-delete-failure.png`;
        const filePath = path.join(avatarDir, fileName);
        const url =
          `https://example.test/api/uploads/profile/avatars/${fileName}`;
        await fs.promises.writeFile(filePath, "retired-but-still-on-disk");
        let concurrentWriterError = null;
        const retired = retireManagedUploadUrls({
          userId: user.id,
          urls: [url],
          operations: {
            beforeCommit() {
              try {
                secondConnection.prepare(
                  "UPDATE users SET avatar_url = ? WHERE id = ?",
                ).run(url, user.id);
              } catch (error) {
                concurrentWriterError = error;
              }
            },
            rmSync() {
              const error = new Error("forced_delete_failure");
              error.code = "EACCES";
              throw error;
            },
          },
        });
        assert.match(concurrentWriterError?.message || "", /locked/i);
        assert.equal(retired.retiredCount, 1);
        assert.equal(retired.failedCount, 1);
        assert.equal(fs.existsSync(filePath), true);
        assert.equal(isManagedUploadRetired("avatars", fileName), true);

        const audioFileName = `${user.id}-retired-audio.wav`;
        const audioPath = path.join(
          tempDir,
          "data",
          "uploads",
          "chat-audio",
          audioFileName,
        );
        await fs.promises.mkdir(path.dirname(audioPath), { recursive: true });
        await fs.promises.writeFile(audioPath, "retired-audio");
        const audioUrl =
          `https://example.test/api/uploads/profile/chat-audio/${audioFileName}`;
        retireManagedUploadUrls({
          userId: user.id,
          urls: [audioUrl],
          operations: {
            rmSync() {
              const error = new Error("forced_audio_delete_failure");
              error.code = "EACCES";
              throw error;
            },
          },
        });
        await assert.rejects(
          loadAudioBytes(audioUrl, { userId: user.id }),
          /speech_audio_file_not_found/,
        );

        for (const retiredUrl of [
          url,
          `https://example.test/api/uploads/profile/avatars/${fileName.toUpperCase()}?cache=1`,
          `https://example.test/api/uploads/avatars/${encodeFirstCharacter(fileName)}`,
          `https://example.test/old-api/uploads/profile/avatars/${fileName}`,
        ]) {
          assert.throws(
            () => secondConnection.prepare(
              "UPDATE users SET avatar_url = ? WHERE id = ?",
            ).run(retiredUrl, user.id),
            /managed_upload_retired/,
          );
        }

        const app = await buildTestApp();
        try {
          await app.ready();
          const retiredResponse = await app.inject({
            method: "GET",
            url: localUploadRoute(url),
          });
          assert.equal(retiredResponse.statusCode, 404);
          const legacyRetiredResponse = await app.inject({
            method: "GET",
            url: `/uploads/avatars/${fileName.toUpperCase()}`,
          });
          assert.equal(legacyRetiredResponse.statusCode, 404);
        } finally {
          await app.close();
        }

        const retry = retryRetiredUploadDeletes();
        assert.ok(retry.deletedCount >= 1);
        assert.equal(fs.existsSync(filePath), false);
        assert.equal(fs.existsSync(audioPath), false);
        const retirement = one(
          `SELECT last_delete_error, delete_attempts, deleted_at
           FROM managed_upload_retirements
           WHERE storage_key = ?`,
          [`avatars/${fileName}`],
        );
        assert.equal(retirement.last_delete_error, "");
        assert.ok(retirement.delete_attempts >= 2);
        assert.ok(retirement.deleted_at);
      } finally {
        secondConnection.close();
      }
    });

    await t.test("chat history requires membership before websocket readiness", async () => {
      const user = insertUser("websocket-nonmember@example.test", "ws-nonmember");
      const token = createSession(user.id);
      const app = await buildTestApp();
      try {
        const address = await app.listen({ host: "127.0.0.1", port: 0 });
        const outcome = await connectUntilClosed(
          `${address.replace(/^http/, "ws")}/ws/security-chat?roomId=global`,
          { authorization: `Bearer ${token}` },
        );
        assert.equal(outcome.code, 1008);
        assert.equal(outcome.reason, "chat_room_join_required");
        assert.equal(
          outcome.messages.some((item) =>
            item?.type === "ready" || item?.type === "history"
          ),
          false,
        );
      } finally {
        await app.close();
      }
    });

    await t.test(
      "chat sockets lose receive access after leave, token revocation, or ban",
      async () => {
        const leavingUser = insertUser(
          "websocket-leaving@example.test",
          "ws-leaving",
        );
        const revokedUser = insertUser(
          "websocket-revoked@example.test",
          "ws-revoked",
        );
        const bannedUser = insertUser(
          "websocket-banned@example.test",
          "ws-banned",
        );
        const sender = insertUser("websocket-sender@example.test", "ws-sender");
        for (const user of [leavingUser, revokedUser, bannedUser, sender]) {
          run(
            `INSERT OR IGNORE INTO chat_room_members (room_id, user_id, role)
             VALUES ('global', ?, 'member')`,
            [user.id],
          );
        }
        const leavingToken = createSession(leavingUser.id);
        const revokedToken = createSession(revokedUser.id);
        const bannedToken = createSession(bannedUser.id);
        const senderToken = createSession(sender.id);
        const app = await buildTestApp();
        try {
          const address = await app.listen({ host: "127.0.0.1", port: 0 });
          const chatUrl = `${address.replace(
            /^http/,
            "ws",
          )}/ws/security-chat?roomId=global`;
          const leaving = await connectChatSocket(chatUrl, leavingToken);
          const revoked = await connectChatSocket(chatUrl, revokedToken);
          const banned = await connectChatSocket(chatUrl, bannedToken);
          const activeSender = await connectChatSocket(chatUrl, senderToken);

          const leaveResponse = await app.inject({
            method: "DELETE",
            url: "/chat/rooms/global/join",
            headers: { authorization: `Bearer ${leavingToken}` },
          });
          assert.equal(leaveResponse.statusCode, 200, leaveResponse.body);
          const leaveClose = await withTimeout(leaving.closed);
          assert.equal(leaveClose.code, 1008);
          assert.equal(leaveClose.reason, "chat_room_left");

          run(
            `UPDATE auth_tokens
             SET revoked_at = datetime('now')
             WHERE user_id = ?`,
            [revokedUser.id],
          );
          const revokedMarker = "message-after-token-revocation";
          const senderSawRevokedMarker = waitForSocketMessage(
            activeSender.socket,
            (item) => item?.type === "message" && item?.item?.content === revokedMarker,
          );
          activeSender.socket.send(
            JSON.stringify({ type: "text", content: revokedMarker }),
          );
          await senderSawRevokedMarker;
          const revokedClose = await withTimeout(revoked.closed);
          assert.equal(revokedClose.code, 1008);
          assert.equal(
            revoked.messages.some(
              (item) => item?.type === "message" && item?.item?.content === revokedMarker,
            ),
            false,
          );

          run("UPDATE users SET status = 'banned' WHERE id = ?", [bannedUser.id]);
          banned.socket.send(JSON.stringify({ type: "ping" }));
          const bannedClose = await withTimeout(banned.closed);
          assert.equal(bannedClose.code, 1008);

          activeSender.socket.close();
          await withTimeout(activeSender.closed);
        } finally {
          await app.close();
        }
      },
    );

    await t.test("profile replacement removes old files and rollback removes new files", async () => {
      const user = insertUser("upload-lifecycle@example.test", "upload-user");
      const token = createSession(user.id);
      const app = await buildTestApp();
      try {
        await app.ready();
        const firstUrl = await uploadPng(app, token, "avatar");
        const firstPath = managedFilePath(firstUrl);
        assert.equal(fs.existsSync(firstPath), true);
        assert.equal(
          (await saveProfile(app, token, user.nickname, firstUrl)).statusCode,
          200,
        );

        const secondUrl = await uploadPng(app, token, "avatar");
        const secondPath = managedFilePath(secondUrl);
        assert.equal(
          (await saveProfile(app, token, user.nickname, secondUrl)).statusCode,
          200,
        );
        assert.equal(fs.existsSync(firstPath), false);
        assert.equal(fs.existsSync(secondPath), true);
        const firstRetirement = one(
          `SELECT deleted_at
           FROM managed_upload_retirements
           WHERE storage_key = ?`,
          [managedStorageKey(firstUrl)],
        );
        assert.ok(firstRetirement?.deleted_at);
        const retiredResponse = await app.inject({
          method: "GET",
          url: localUploadRoute(firstUrl),
        });
        assert.equal(retiredResponse.statusCode, 404);
        const activeResponse = await app.inject({
          method: "GET",
          url: localUploadRoute(secondUrl),
        });
        assert.equal(activeResponse.statusCode, 200);
        assert.equal(activeResponse.headers["cache-control"], "no-store");
        assert.equal(activeResponse.headers["x-content-type-options"], "nosniff");
        assert.equal(
          one("SELECT avatar_url FROM users WHERE id = ?", [user.id]).avatar_url,
          secondUrl,
        );

        const failedUrl = await uploadPng(app, token, "avatar");
        const failedPath = managedFilePath(failedUrl);
        db.exec(
          `CREATE TRIGGER fail_profile_avatar_update
           BEFORE UPDATE OF avatar_url ON users
           WHEN NEW.id = ${Number(user.id)} AND NEW.avatar_url <> OLD.avatar_url
           BEGIN
             SELECT RAISE(ABORT, 'forced_profile_update_failure');
           END`,
        );
        const failedResponse = await saveProfile(
          app,
          token,
          user.nickname,
          failedUrl,
        );
        db.exec("DROP TRIGGER fail_profile_avatar_update");

        assert.equal(failedResponse.statusCode, 500);
        assert.equal(
          one("SELECT avatar_url FROM users WHERE id = ?", [user.id]).avatar_url,
          secondUrl,
        );
        assert.equal(fs.existsSync(secondPath), true);
        assert.equal(fs.existsSync(failedPath), false);
        assert.ok(
          one(
            `SELECT deleted_at
             FROM managed_upload_retirements
             WHERE storage_key = ?`,
            [managedStorageKey(failedUrl)],
          )?.deleted_at,
        );
      } finally {
        await app.close();
      }
    });
  } finally {
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

async function buildTestApp() {
  const app = Fastify({ logger: false });
  app.decorate("authRequired", authRequired);
  await app.register(websocketPlugin, {
    options: { maxPayload: 64 * 1024 },
  });
  await app.register(userRoutes);
  registerWebSockets(app, {
    ...config,
    wsChatPath: "/ws/security-chat",
    wsGamePath: "/ws/security-game",
    wsDanmakuPath: "/ws/security-danmaku",
    allowLegacyWebSocketQueryToken: false,
    websocketMaxPayloadBytes: 64 * 1024,
  });
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error: error.publicCode || (status >= 500 ? "internal_error" : error.message),
    });
  });
  return app;
}

function insertUser(email, nickname) {
  const result = run(
    `INSERT INTO users (email, nickname, password_hash, status)
     VALUES (?, ?, 'unused-test-password-hash', 'active')`,
    [email, nickname],
  );
  return one("SELECT * FROM users WHERE id = ?", [result.lastInsertRowid]);
}

function connectUntilClosed(url, headers) {
  return new Promise((resolve, reject) => {
    const messages = [];
    const socket = new WebSocket(url, { headers });
    const timeout = setTimeout(() => {
      socket.terminate();
      reject(new Error("websocket_close_timeout"));
    }, 5000);
    socket.on("message", (raw) => {
      try {
        messages.push(JSON.parse(raw.toString()));
      } catch {
        messages.push({ type: "invalid_json" });
      }
    });
    socket.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    socket.once("close", (code, reason) => {
      clearTimeout(timeout);
      resolve({ code, reason: reason.toString(), messages });
    });
  });
}

function connectChatSocket(url, token) {
  return new Promise((resolve, reject) => {
    const messages = [];
    const socket = new WebSocket(url, {
      headers: { authorization: `Bearer ${token}` },
    });
    let closeResolve;
    const closed = new Promise((resolveClose) => {
      closeResolve = resolveClose;
    });
    const timeout = setTimeout(() => {
      socket.terminate();
      reject(new Error("websocket_ready_timeout"));
    }, 5000);
    socket.on("message", (raw) => {
      let item;
      try {
        item = JSON.parse(raw.toString());
      } catch {
        item = { type: "invalid_json" };
      }
      messages.push(item);
      if (item?.type === "ready") {
        clearTimeout(timeout);
        resolve({ socket, messages, closed });
      }
    });
    socket.on("error", (error) => {
      if (socket.readyState !== WebSocket.OPEN) {
        clearTimeout(timeout);
        reject(error);
      }
    });
    socket.once("close", (code, reason) => {
      clearTimeout(timeout);
      closeResolve({ code, reason: reason.toString() });
    });
  });
}

function waitForSocketMessage(socket, predicate) {
  return withTimeout(
    new Promise((resolve) => {
      const onMessage = (raw) => {
        let item;
        try {
          item = JSON.parse(raw.toString());
        } catch {
          return;
        }
        if (!predicate(item)) return;
        socket.off("message", onMessage);
        resolve(item);
      };
      socket.on("message", onMessage);
    }),
  );
}

function withTimeout(promise, timeoutMs = 5000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("websocket_event_timeout")), timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function uploadPng(app, token, kind) {
  const response = await app.inject({
    method: "POST",
    url: "/users/me/profile-image",
    headers: { authorization: `Bearer ${token}` },
    payload: {
      kind,
      mimeType: "image/png",
      dataBase64: Buffer.from([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ]).toString("base64"),
    },
  });
  assert.equal(response.statusCode, 200, response.body);
  return response.json().url;
}

function saveProfile(app, token, nickname, avatarUrl) {
  return app.inject({
    method: "PATCH",
    url: "/users/me/profile",
    headers: { authorization: `Bearer ${token}` },
    payload: {
      nickname,
      avatarUrl,
      gender: "private",
      bio: "profile bio",
      signature: "profile signature",
      profileTheme: "sakura",
      photoWall: [],
    },
  });
}

function managedFilePath(url) {
  const pathname = new URL(url).pathname;
  const marker = `${config.apiPrefix}/uploads/profile/`;
  assert.equal(pathname.startsWith(marker), true);
  const [folder, file] = pathname.slice(marker.length).split("/");
  assert.ok(folder);
  assert.ok(file);
  return path.join(tempDir, "data", "uploads", folder, file);
}

function managedStorageKey(url) {
  const pathname = new URL(url).pathname;
  const marker = `${config.apiPrefix}/uploads/profile/`;
  assert.equal(pathname.startsWith(marker), true);
  return decodeURIComponent(pathname.slice(marker.length)).toLowerCase();
}

function localUploadRoute(url) {
  const pathname = new URL(url).pathname;
  assert.equal(pathname.startsWith(config.apiPrefix), true);
  return pathname.slice(config.apiPrefix.length) || "/";
}

function encodeFirstCharacter(value) {
  const text = String(value || "");
  if (!text) return "";
  return `%${text.charCodeAt(0).toString(16).padStart(2, "0")}${text.slice(1)}`;
}
