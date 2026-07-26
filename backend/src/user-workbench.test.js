import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-user-workbench-"));
process.env.DB_PATH = path.join(tempDir, "users.sqlite");
process.env.TOKEN_SECRET = "user-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "user-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("user workbench separates profile, security, role and audited economy actions", async () => {
  const app = await buildServer();
  try {
    const userId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, role, status, points, sakura_coins,
            register_ip, last_login_ip, chat_violation_total)
         VALUES (?, ?, ?, 'user', 'active', 120, 40, ?, ?, 2)`,
        [
          "user-workbench@example.com",
          "用户工作台",
          hashPassword("user12345"),
          "203.0.113.30",
          "203.0.113.31",
        ],
      ).lastInsertRowid,
    );
    const reporterId = Number(
      run(
        `INSERT INTO users (email, nickname, password_hash, role, status)
         VALUES (?, ?, ?, 'user', 'active')`,
        ["user-reporter@example.com", "用户举报人", hashPassword("user12345")],
      ).lastInsertRowid,
    );
    const expiredBanUserId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, role, status, banned_until, ban_reason)
         VALUES (?, ?, ?, 'user', 'banned', datetime('now', '-1 hour'), 'spam')`,
        ["expired-ban@example.com", "封禁已到期", hashPassword("user12345")],
      ).lastInsertRowid,
    );
    run(
      `INSERT INTO user_app_installs
         (user_id, install_id, version_name, version_code, platform,
          device_model, os_version, last_ip)
       VALUES (?, 'install-a', '5.2.0', 520, 'android', 'Pixel 9', 'Android 16', '203.0.113.31')`,
      [userId],
    );
    run(
      `INSERT INTO user_app_installs
         (user_id, install_id, version_name, version_code, platform,
          device_model, os_version, last_ip)
       VALUES (?, 'install-b', '5.1.0', 510, 'android', 'Tablet', 'Android 15', '203.0.113.32')`,
      [userId],
    );
    run(
      `UPDATE user_app_installs
       SET last_seen_at = datetime('now', '-1 day')
       WHERE user_id = ? AND install_id = 'install-b'`,
      [userId],
    );
    run(
      `INSERT INTO chat_violations
         (user_id, room_id, content, keyword, action, ip)
       VALUES (?, 'global', '违规测试消息', '测试词', 'blocked', '203.0.113.31')`,
      [userId],
    );
    run(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason)
       VALUES (?, 'user', ?, '疑似批量广告账号')`,
      [reporterId, String(userId)],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, points_delta, description)
       VALUES (?, 'daily_signin', 10, '每日签到')`,
      [userId],
    );

    const admin = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = admin.token;
    await request(app, "POST", "/auth/login", {
      email: "user-workbench@example.com",
      password: "user12345",
    });
    await request(app, "POST", "/auth/login", {
      email: "user-workbench@example.com",
      password: "user12345",
    });

    const list = await request(
      app,
      "GET",
      `/admin/users?q=${userId}&risk=chat_violations&appVersionCode=520&page=1&pageSize=10`,
      undefined,
      token,
    );
    assert.equal(list.total, 1);
    assert.equal(list.items[0].id, userId);
    assert.equal(list.items[0].deviceCount, 2);
    assert.equal(list.items[0].activeSessionCount, 2);
    assert.ok(list.statusCounts.active >= 2);
    assert.ok(list.stats.riskUsers >= 1);
    assert.equal(list.stats.chatViolationUsers, 1);
    assert.equal(list.stats.reportedUsers, 1);
    assert.ok(list.stats.noVersionUsers >= 1);
    assert.equal(list.versionOptions[0].versionCode, 520);

    const expiredBan = await request(
      app,
      "GET",
      `/admin/users?q=${expiredBanUserId}&page=1&pageSize=10`,
      undefined,
      token,
    );
    assert.equal(expiredBan.total, 1);
    assert.equal(expiredBan.items[0].status, "active");
    assert.equal(expiredBan.items[0].bannedUntil, "");
    assert.equal(expiredBan.items[0].banReason, "");

    const detail = await request(
      app,
      "GET",
      `/admin/users/${userId}/activity`,
      undefined,
      token,
    );
    assert.equal(detail.devices.length, 2);
    assert.equal(detail.sessions.activeCount, 2);
    assert.equal(detail.rewardEvents[0].action, "daily_signin");
    assert.equal(detail.violations.length, 1);
    assert.equal(detail.reportsAgainst.length, 1);

    const profile = await request(
      app,
      "PATCH",
      `/admin/users/${userId}/profile`,
      { nickname: "新昵称", gender: "private", signature: "", bio: "" },
      token,
    );
    assert.equal(profile.item.nickname, "新昵称");
    assert.equal(profile.item.bio, "");

    const credit = await request(
      app,
      "POST",
      `/admin/users/${userId}/economy-adjustment`,
      {
        currency: "coins",
        direction: "credit",
        amount: 100,
        reasonCode: "customer_support",
        note: "工单 #100",
      },
      token,
    );
    assert.equal(credit.previousBalance, 40);
    assert.equal(credit.nextBalance, 140);
    const debit = await request(
      app,
      "POST",
      `/admin/users/${userId}/economy-adjustment`,
      {
        currency: "coins",
        direction: "debit",
        amount: 30,
        reasonCode: "fraud_correction",
      },
      token,
    );
    assert.equal(debit.delta, -30);
    assert.equal(debit.nextBalance, 110);
    const insufficient = await rawRequest(
      app,
      "POST",
      `/admin/users/${userId}/economy-adjustment`,
      {
        currency: "coins",
        direction: "debit",
        amount: 1000,
        reasonCode: "data_correction",
      },
      token,
    );
    assert.equal(insufficient.statusCode, 400);
    assert.equal(insufficient.json().error, "insufficient_user_balance");
    assert.equal(one("SELECT sakura_coins FROM users WHERE id = ?", [userId]).sakura_coins, 110);
    const coinEvents = one(
      `SELECT COUNT(*) AS count
       FROM user_reward_events
       WHERE user_id = ? AND action = 'admin_adjust_coins'`,
      [userId],
    ).count;
    assert.equal(coinEvents, 2);

    const promoted = await request(
      app,
      "POST",
      `/admin/users/${userId}/role`,
      { role: "admin" },
      token,
    );
    assert.equal(promoted.item.role, "admin");
    assert.equal(promoted.revokedSessions, 2);
    assert.equal(activeSessions(userId), 0);
    await request(
      app,
      "POST",
      `/admin/users/${userId}/role`,
      { role: "user" },
      token,
    );

    await request(app, "POST", "/auth/login", {
      email: "user-workbench@example.com",
      password: "user12345",
    });
    seedKdjxSession(userId, "ban");
    assert.equal(activeKdjxSessions(userId), 1);
    const banned = await request(
      app,
      "POST",
      `/admin/users/${userId}/ban`,
      {
        mode: "temporary",
        durationHours: 24,
        reasonCode: "spam",
        note: "批量广告",
        blockKnownIps: true,
      },
      token,
    );
    assert.equal(banned.item.status, "banned");
    assert.ok(banned.item.bannedUntil);
    assert.equal(banned.revokedSessions, 1);
    assert.equal(activeSessions(userId), 0);
    assert.equal(activeKdjxSessions(userId), 0);
    assert.equal(
      one("SELECT COUNT(*) AS count FROM banned_registration_ips WHERE user_id = ?", [userId]).count,
      2,
    );

    const unbanned = await request(
      app,
      "POST",
      `/admin/users/${userId}/unban`,
      { removeKnownIps: true },
      token,
    );
    assert.equal(unbanned.item.status, "active");
    assert.equal(unbanned.removedIps, 2);
    assert.equal(activeSessions(userId), 0, "unban must not reactivate old sessions");
    assert.equal(
      activeKdjxSessions(userId),
      0,
      "unban must not reactivate old KDJX sessions",
    );

    await request(app, "POST", "/auth/login", {
      email: "user-workbench@example.com",
      password: "user12345",
    });
    seedKdjxSession(userId, "manual-revoke");
    assert.equal(activeKdjxSessions(userId), 1);
    const revoked = await request(
      app,
      "POST",
      `/admin/users/${userId}/revoke-sessions`,
      {},
      token,
    );
    assert.equal(revoked.revokedSessions, 1);
    assert.equal(activeSessions(userId), 0);
    assert.equal(activeKdjxSessions(userId), 0);

    const ownRole = await rawRequest(
      app,
      "POST",
      `/admin/users/${admin.user.id}/role`,
      { role: "user" },
      token,
    );
    assert.equal(ownRole.statusCode, 400);
    assert.equal(ownRole.json().error, "cannot_change_own_role");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function activeSessions(userId) {
  return one(
    `SELECT COUNT(*) AS count
     FROM auth_tokens
     WHERE user_id = ?
       AND revoked_at IS NULL
       AND datetime(expires_at) > datetime('now')`,
    [userId],
  ).count;
}

function seedKdjxSession(userId, suffix) {
  run(
    `INSERT INTO kdjx_game_sessions
      (id, token_hash, user_id, game_open_id, expires_at)
     VALUES (?, ?, ?, ?, datetime('now', '+3650 days'))`,
    [
      `user-workbench-${suffix}`,
      `user-workbench-token-${suffix}`,
      userId,
      `user-workbench-open-${userId}`,
    ],
  );
}

function activeKdjxSessions(userId) {
  return one(
    `SELECT COUNT(*) AS count
     FROM kdjx_game_sessions
     WHERE user_id = ?
       AND revoked_at IS NULL
       AND datetime(expires_at) > datetime('now')`,
    [userId],
  ).count;
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
