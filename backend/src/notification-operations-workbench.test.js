import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-notification-ops-"));
const adminPassword = `notification-admin-${process.pid}-${Date.now()}`;
process.env.DB_PATH = path.join(tempDir, "notifications.sqlite");
process.env.TOKEN_SECRET = `notification-token-${process.pid}-${Date.now()}`;
process.env.SETTINGS_ENCRYPTION_KEY = `notification-settings-${process.pid}-${Date.now()}`;
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = adminPassword;

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("notification workbench previews structured audiences and sends atomically", async () => {
  const app = await buildServer();
  try {
    const normalA = createUser("notice-a@example.com", "Notice A", "active", "user");
    const normalB = createUser("notice-b@example.com", "Notice B", "active", "user");
    const adminUser = createUser("notice-admin@example.com", "Notice Admin", "active", "admin");
    createUser("notice-inactive@example.com", "Inactive", "banned", "user");
    run("UPDATE users SET last_login_at = datetime('now') WHERE id = ?", [normalA]);
    run("UPDATE users SET last_login_at = datetime('now', '-10 days') WHERE id = ?", [normalB]);
    run(
      `INSERT INTO user_app_installs
         (user_id, install_id, version_name, version_code, platform, device_model)
       VALUES (?, 'notice-a-install', '5.4.0', 540, 'android', 'Pixel')`,
      [normalA],
    );
    run(
      `INSERT INTO user_app_installs
         (user_id, install_id, version_name, version_code, platform, device_model,
          last_seen_at)
       VALUES (?, 'notice-b-install', '5.3.0', 530, 'ios', 'iPhone', datetime('now', '-10 days'))`,
      [normalB],
    );

    const login = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: adminPassword,
    });
    const token = login.token;

    const preview = await request(app, "POST", "/admin/notifications/preview", {
      title: "Android maintenance",
      content: "A short maintenance notice.",
      category: "update",
      audience: {
        scope: "recent_active",
        recentDays: 7,
        platforms: ["android"],
        minVersionCode: 500,
        maxVersionCode: 600,
      },
    }, token);
    assert.equal(preview.eligibleCount, 1);
    assert.equal(preview.sample[0].id, normalA);
    assert.equal(preview.sample[0].platform, "android");

    const draft = await request(app, "POST", "/admin/notifications", {
      title: "Android maintenance",
      content: "A short maintenance notice.",
      category: "update",
      audience: {
        scope: "recent_active",
        recentDays: 7,
        platforms: ["android"],
        minVersionCode: 500,
        maxVersionCode: 600,
      },
      changeNote: "Create reviewed notice draft",
    }, token);
    assert.equal(draft.item.status, "draft");
    assert.equal(draft.item.revision, 1);

    const stale = await rawRequest(app, "PATCH", `/admin/notifications/${draft.item.id}`, {
      title: "Stale update",
      content: "This must be rejected.",
      category: "update",
      audience: { scope: "all_active" },
      expectedRevision: 0,
      changeNote: "Stale revision test",
    }, token);
    assert.equal(stale.statusCode, 409);
    assert.equal(stale.json().error, "notification_revision_conflict");

    const updated = await request(app, "PATCH", `/admin/notifications/${draft.item.id}`, {
      title: "Android maintenance v2",
      content: "The reviewed maintenance notice.",
      category: "update",
      audience: {
        scope: "recent_active",
        recentDays: 7,
        platforms: ["android"],
        minVersionCode: 500,
        maxVersionCode: 600,
      },
      expectedRevision: 1,
      changeNote: "Clarify maintenance wording",
    }, token);
    assert.equal(updated.item.revision, 2);

    const key = `notice-send-${process.pid}-${Date.now()}`;
    const sent = await request(app, "POST", `/admin/notifications/${draft.item.id}/send`, {
      expectedRevision: 2,
      idempotencyKey: key,
      changeNote: "Send after audience review",
    }, token);
    assert.equal(sent.item.status, "sent");
    assert.equal(sent.delivery.deliveredCount, 1);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ?",
      [draft.item.id],
    ).total, 1);
    assert.equal(one(
      "SELECT user_id FROM system_notifications WHERE broadcast_id = ?",
      [draft.item.id],
    ).user_id, normalA);

    const replay = await request(app, "POST", `/admin/notifications/${draft.item.id}/send`, {
      expectedRevision: 2,
      idempotencyKey: key,
      changeNote: "Retry the same send request",
    }, token);
    assert.equal(replay.idempotent, true);
    assert.equal(replay.item.id, draft.item.id);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ?",
      [draft.item.id],
    ).total, 1);

    const duplicateSend = await rawRequest(app, "POST", `/admin/notifications/${draft.item.id}/send`, {
      expectedRevision: 3,
      idempotencyKey: `notice-other-${Date.now()}`,
      changeNote: "Reject a second send",
    }, token);
    assert.equal(duplicateSend.statusCode, 400);
    assert.equal(duplicateSend.json().error, "notification_already_sent");

    const allActive = await request(app, "POST", "/admin/notifications", {
      title: "All active users",
      content: "A general notice.",
      category: "system",
      audience: { scope: "all_active" },
      changeNote: "Create cancelable notice",
    }, token);
    const canceled = await request(app, "POST", `/admin/notifications/${allActive.item.id}/cancel`, {
      expectedRevision: allActive.item.revision,
      changeNote: "Cancel before sending",
    }, token);
    assert.equal(canceled.item.status, "canceled");
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ?",
      [allActive.item.id],
    ).total, 0);

    const legacy = await request(app, "POST", "/admin/notifications/broadcast", {
      title: "Legacy adapter",
      content: "The old page still works during cutover.",
      category: "operation",
    }, token);
    assert.equal(legacy.recipientCount, 2);
    assert.equal(legacy.item.status, "sent");
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ?",
      [legacy.item.id],
    ).total, 2);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ? AND user_id = ?",
      [legacy.item.id, adminUser],
    ).total, 0);

    const list = await request(app, "GET", "/admin/notifications?status=draft&page=1&pageSize=10", undefined, token);
    assert.equal(list.total, 0);
    assert.ok(list.stats.sent >= 2);
    const detail = await request(app, "GET", `/admin/notifications/${legacy.item.id}`, undefined, token);
    assert.equal(detail.events.length >= 2, true);
    assert.equal(detail.delivery.atomic, true);

    run(
      "UPDATE system_notifications SET read_at = datetime('now') WHERE user_id IN (?, ?)",
      [normalA, normalB],
    );
    run(
      `INSERT INTO system_notifications (user_id, title, content, category)
       VALUES (?, '审核结果', '第一条待读审核消息', 'ai_novel_review'),
              (?, '版本提醒', '第二条待读版本消息', 'update')`,
      [normalA, normalA],
    );
    run(
      `INSERT INTO system_notifications (user_id, title, content, category)
       VALUES (?, '其他用户消息', '不应被一键已读影响', 'system')`,
      [normalB],
    );
    const readerLogin = await request(app, "POST", "/auth/login", {
      email: "notice-a@example.com",
      password: "notice-user-password",
    });
    const newestNotificationPage = await request(
      app,
      "GET",
      "/messages/system?limit=1",
      undefined,
      readerLogin.token,
    );
    assert.equal(newestNotificationPage.items.length, 1);
    const olderNotificationPage = await request(
      app,
      "GET",
      `/messages/system?limit=1&beforeId=${newestNotificationPage.items[0].id}`,
      undefined,
      readerLogin.token,
    );
    assert.equal(olderNotificationPage.items.length, 1);
    assert.ok(olderNotificationPage.items[0].id < newestNotificationPage.items[0].id);
    const readerUnread = await request(app, "GET", "/messages/unread-summary", undefined, readerLogin.token);
    assert.equal(readerUnread.system, 2);

    const markedAll = await request(app, "POST", "/messages/system/read-all", {}, readerLogin.token);
    assert.equal(markedAll.ok, true);
    assert.equal(markedAll.markedCount, 2);
    assert.equal(markedAll.unread.system, 0);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE user_id = ? AND read_at = ''",
      [normalA],
    ).total, 0);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE user_id = ? AND read_at = ''",
      [normalB],
    ).total, 1);
    const repeatedMarkAll = await request(
      app,
      "POST",
      "/messages/system/read-all",
      {},
      readerLogin.token,
    );
    assert.equal(repeatedMarkAll.markedCount, 0);

    const publishedAnnouncement = await request(
      app,
      "POST",
      "/admin/app-announcements/publish",
      {
        expectedVersion: "",
        title: "二次元的世界",
        content: "欢迎来到二次元的世界。",
        changeNote: "发布启动欢迎公告",
      },
      token,
    );
    assert.equal(publishedAnnouncement.current.enabled, true);
    const publicAnnouncement = await request(
      app,
      "GET",
      "/app/announcement",
    );
    assert.equal(publicAnnouncement.item.title, "二次元的世界");
    assert.equal(publicAnnouncement.item.enabled, true);
    assert.equal(
      one(
        "SELECT COUNT(*) AS total FROM system_notifications WHERE content = ?",
        ["欢迎来到二次元的世界。"],
      ).total,
      0,
      "startup announcements must not be inserted into the message center",
    );

    const disabledAnnouncement = await request(
      app,
      "POST",
      "/admin/app-announcements/disable",
      {
        expectedVersion: publishedAnnouncement.current.version,
        changeNote: "欢迎公告展示期结束",
      },
      token,
    );
    assert.equal(disabledAnnouncement.current.enabled, false);

    const announcementHistory = await request(
      app,
      "GET",
      "/admin/app-announcements?page=1&pageSize=20",
      undefined,
      token,
    );
    assert.equal(announcementHistory.total, 2);
    assert.equal(announcementHistory.items[0].enabled, false);
    const publishedRevision = announcementHistory.items.find((item) => item.enabled);
    assert.ok(publishedRevision);

    const republishedAnnouncement = await request(
      app,
      "POST",
      `/admin/app-announcements/${publishedRevision.id}/republish`,
      {
        expectedVersion: disabledAnnouncement.current.version,
        changeNote: "重新展示欢迎公告",
      },
      token,
    );
    assert.equal(republishedAnnouncement.current.enabled, true);
    assert.notEqual(
      republishedAnnouncement.current.version,
      publishedAnnouncement.current.version,
      "republishing must create a new client-visible announcement id",
    );
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function createUser(email, nickname, status, role) {
  return Number(run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, ?, ?)`,
    [email, nickname, hashPassword("notice-user-password"), role, status],
  ).lastInsertRowid);
}

async function request(app, method, route, body, token = "") {
  const response = await rawRequest(app, method, route, body, token);
  assert.ok(
    response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`,
  );
  return response.json();
}

function rawRequest(app, method, route, body, token = "") {
  return app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    payload: body === undefined ? undefined : JSON.stringify(body),
  });
}
