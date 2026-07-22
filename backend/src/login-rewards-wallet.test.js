import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-login-rewards-"));
process.env.DB_PATH = path.join(tempDir, "login-rewards.sqlite");
process.env.TOKEN_SECRET = "login-rewards-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "login-rewards-settings-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { config } = await import("./config.js");
const { all, one, run } = await import("./db.js");
const { hashPassword } = await import("./security.js");

test("login rewards are atomic, idempotent and exposed through wallet history", async () => {
  config.rootDir = tempDir;
  const app = await buildServer();
  try {
    const admin = await login(app, "admin@admin.local", "admin123456");
    const eligible = await createUserAndSession(app, {
      email: "eligible-login@example.com",
      createdAt: "datetime('now', '-1 day')",
      versionCode: 120,
    });
    const oldVersion = await createUserAndSession(app, {
      email: "old-version-login@example.com",
      createdAt: "datetime('now', '-1 day')",
      versionCode: 80,
    });
    const wrongAudience = await createUserAndSession(app, {
      email: "old-account-login@example.com",
      createdAt: "datetime('now', '-30 days')",
      versionCode: 120,
    });
    const previousDay = await createUserAndSession(app, {
      email: "previous-day-login@example.com",
      createdAt: "datetime('now', '-1 day')",
      versionCode: 120,
    });
    run("UPDATE users SET last_login_at = datetime('now', '-1 day') WHERE id = ?", [previousDay.userId]);
    run("UPDATE user_app_installs SET last_seen_at = datetime('now', '-1 day') WHERE user_id = ?", [previousDay.userId]);

    const banner = await uploadBanner(app, admin.token, "login-reward.png");
    const campaign = await createCampaign(app, admin.token, {
      campaignKey: "daily-login-reward",
      title: "今日登录赠礼",
      description: "登录即得樱花币。",
      bannerUrl: banner.url,
      startsAt: new Date(Date.now() - 60_000).toISOString(),
      endsAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      audiencePreset: "new_users",
      minVersionCode: 100,
    });

    const invalidTarget = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/tasks`,
      {
        expectedRevision: campaign.item.revision,
        taskKey: "invalid-login-target",
        title: "Invalid login task",
        eventName: "login",
        targetCount: 2,
        rewardCoins: 1,
        status: "active",
        changeNote: "Reject a repeated login target",
      },
      admin.token,
    );
    assert.equal(invalidTarget.statusCode, 400);
    assert.equal(invalidTarget.json().error, "growth_campaign_login_task_target_invalid");

    const invalidFilter = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/tasks`,
      {
        expectedRevision: campaign.item.revision,
        taskKey: "invalid-login-filter",
        title: "Invalid filtered login task",
        eventName: "login",
        targetCount: 1,
        rewardCoins: 1,
        contentType: "novel",
        status: "active",
        changeNote: "Reject a content-scoped login task",
      },
      admin.token,
    );
    assert.equal(invalidFilter.statusCode, 400);
    assert.equal(invalidFilter.json().error, "growth_campaign_login_task_filter_invalid");

    const withTask = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/tasks`,
      {
        expectedRevision: campaign.item.revision,
        taskKey: "login-once",
        title: "登录奖励",
        description: "今日登录已获赠 25 樱花币。",
        eventName: "login",
        targetCount: 1,
        rewardPoints: 3,
        rewardCoins: 25,
        status: "active",
        changeNote: "Add the automatic login reward",
      },
      admin.token,
    );
    assert.ok(withTask.options.taskEvents.includes("login"));

    const duplicateTask = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/tasks`,
      {
        expectedRevision: withTask.item.revision,
        taskKey: "second-login",
        title: "Second login reward",
        eventName: "login",
        targetCount: 1,
        rewardCoins: 5,
        status: "active",
        changeNote: "Reject duplicate automatic rewards",
      },
      admin.token,
    );
    assert.equal(duplicateTask.statusCode, 409);
    assert.equal(duplicateTask.json().error, "growth_campaign_login_task_conflict");

    const activated = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/status`,
      {
        status: "active",
        expectedRevision: withTask.item.revision,
        acknowledgeBudget: true,
        note: "Activate the reviewed daily login reward",
      },
      admin.token,
    );
    assert.equal(activated.item.status, "active");
    assert.equal(balance(eligible.userId), 25, "activation backfills an eligible login");
    assert.equal(balance(oldVersion.userId), 0, "activation respects minimum app version");
    assert.equal(balance(wrongAudience.userId), 0, "activation respects campaign audience");
    assert.equal(balance(previousDay.userId), 0, "activation uses the Asia/Hong_Kong day window");
    assert.equal(one("SELECT COUNT(*) AS total FROM reward_claims WHERE user_id = ?", [eligible.userId]).total, 1);
    assert.equal(one("SELECT progress_count FROM user_activity_progress WHERE user_id = ?", [eligible.userId]).progress_count, 1);

    const spoofedVersionSync = await jsonRequest(
      app, "POST", "/growth/login-rewards/sync", { versionCode: 999999 }, oldVersion.token,
    );
    assert.equal(spoofedVersionSync.balance, 0);
    assert.equal(spoofedVersionSync.items.length, 0);
    assert.equal(
      one("SELECT COUNT(*) AS total FROM reward_claims WHERE user_id = ?", [oldVersion.userId]).total,
      0,
      "the reward sync ignores a client-supplied version code",
    );

    const firstSync = await jsonRequest(
      app, "POST", "/growth/login-rewards/sync", { versionCode: 120 }, eligible.token,
    );
    assert.equal(firstSync.balance, 25);
    assert.equal(firstSync.items.length, 1);
    assert.equal(firstSync.items[0].coinsAwarded, 25);
    assert.equal(firstSync.items[0].content, "今日登录已获赠 25 樱花币。");
    const duplicateSync = await jsonRequest(
      app, "POST", "/growth/login-rewards/sync", { versionCode: 120 }, eligible.token,
    );
    assert.deepEqual(duplicateSync, firstSync);
    assert.equal(balance(eligible.userId), 25);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM user_reward_events WHERE user_id = ? AND action = 'login_reward'",
      [eligible.userId],
    ).total, 1);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM login_reward_notices WHERE user_id = ?",
      [eligible.userId],
    ).total, 1);

    const forbiddenAck = await rawJsonRequest(
      app, "POST", `/growth/login-rewards/${firstSync.items[0].id}/ack`, {}, oldVersion.token,
    );
    assert.equal(forbiddenAck.statusCode, 400);
    assert.equal(forbiddenAck.json().error, "login reward notice not found");
    assert.deepEqual(await jsonRequest(
      app, "POST", `/growth/login-rewards/${firstSync.items[0].id}/ack`, {}, eligible.token,
    ), { ok: true });
    assert.deepEqual(await jsonRequest(
      app, "POST", `/growth/login-rewards/${firstSync.items[0].id}/ack`, {}, eligible.token,
    ), { ok: true }, "acknowledgement is idempotent");
    const afterAck = await jsonRequest(
      app, "POST", "/growth/login-rewards/sync", { versionCode: 120 }, eligible.token,
    );
    assert.equal(afterAck.items.length, 0);
    assert.equal(afterAck.balance, 25);

    const afterActivation = await createUserAndSession(app, {
      email: "after-activation@example.com",
      createdAt: "datetime('now')",
      versionCode: 120,
    });
    const awardedOnSync = await jsonRequest(
      app, "POST", "/growth/login-rewards/sync", { versionCode: 120 }, afterActivation.token,
    );
    assert.equal(awardedOnSync.balance, 25);
    assert.equal(awardedOnSync.items.length, 1);

    run(
      `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'test_debit', -7, '测试消费', 'test', 'debit-1')`,
      [eligible.userId],
    );
    run(
      `INSERT INTO user_reward_events
       (user_id, action, points_delta, coins_delta, description, related_type, related_id)
       VALUES (?, 'points_only', 5, 0, '仅成长值变动', 'test', 'points-only-1')`,
      [eligible.userId],
    );
    for (let index = 1; index <= 3; index += 1) {
      run(
        `INSERT INTO bailian_payment_orders
         (id, game_order_id, user_id, game_open_id, product_id, product_name,
          money_cents, coin_cost, idempotency_key, status)
         VALUES (?, ?, ?, ?, ?, ?, 100, 10, ?, 'fulfilled')`,
        [`wallet-order-${index}`, `wallet-game-order-${index}`, eligible.userId,
         `wallet-open-${eligible.userId}`, `product-${index}`, `商品 ${index}`,
         `wallet-idempotency-${index}`],
      );
      run(
        `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id)
         VALUES (?, 'bailian_payment', -10, ?, 'bailian_payment_order', ?)`,
        [eligible.userId, `游戏消费 ${index}`, `wallet-order-${index}`],
      );
    }
    const walletFirstPage = await jsonRequest(
      app, "GET", "/users/me/wallet?page=1&pageSize=2", undefined, eligible.token,
    );
    assert.equal(walletFirstPage.balance, 25);
    assert.equal(walletFirstPage.ledger.total, 5);
    assert.ok(walletFirstPage.ledger.items.every((item) => item.coinsDelta < 0));
    assert.ok(walletFirstPage.ledger.items.every((item) => item.createdAt.endsWith("Z")));
    assert.equal(walletFirstPage.orders.total, 4);
    assert.equal(walletFirstPage.orders.items.length, 2);
    assert.ok(walletFirstPage.orders.items.every((item) => item.createdAt.endsWith("Z")));
    assert.equal(walletFirstPage.ledger.snapshotMaxId, walletFirstPage.snapshotMaxId);

    const lateEventId = Number(run(
      `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'late_debit', -1, '翻页期间新增消费', 'test', 'late-debit-1')`,
      [eligible.userId],
    ).lastInsertRowid);
    const walletSecondPage = await jsonRequest(
      app, "GET",
      `/users/me/wallet?page=2&pageSize=2&snapshotMaxId=${walletFirstPage.snapshotMaxId}`,
      undefined, eligible.token,
    );
    assert.equal(walletSecondPage.orders.items.length, 2);
    assert.equal(walletSecondPage.orders.hasMore, false);
    const walletThirdPage = await jsonRequest(
      app, "GET",
      `/users/me/wallet?page=3&pageSize=2&snapshotMaxId=${walletFirstPage.snapshotMaxId}`,
      undefined, eligible.token,
    );
    const snapshotLedgerIds = [
      ...walletFirstPage.ledger.items,
      ...walletSecondPage.ledger.items,
      ...walletThirdPage.ledger.items,
    ].map((item) => Number(item.id));
    assert.equal(snapshotLedgerIds.length, 5);
    assert.equal(new Set(snapshotLedgerIds).size, 5);
    assert.ok(!snapshotLedgerIds.includes(lateEventId));
    assert.equal(walletThirdPage.ledger.hasMore, false);

    const walletBeyondLegacyLimit = await jsonRequest(
      app, "GET",
      `/users/me/wallet?page=201&pageSize=2&snapshotMaxId=${walletFirstPage.snapshotMaxId}`,
      undefined, eligible.token,
    );
    assert.equal(walletBeyondLegacyLimit.ledger.page, 201);
    assert.equal(walletBeyondLegacyLimit.ledger.items.length, 0);
    assert.equal(walletBeyondLegacyLimit.ledger.hasMore, false);

    const paused = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/status`,
      {
        status: "paused",
        expectedRevision: activated.item.revision,
        note: "Pause before replacing the login task",
      },
      admin.token,
    );
    const oldTaskId = withTask.tasks[0].id;
    const disabled = await jsonRequest(
      app,
      "DELETE",
      `/admin/growth/campaigns/${campaign.item.id}/tasks/${oldTaskId}`,
      {
        expectedRevision: paused.item.revision,
        note: "Disable the claimed historical login task",
      },
      admin.token,
    );
    const replacement = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/tasks`,
      {
        expectedRevision: disabled.item.revision,
        taskKey: "replacement-login",
        title: "Replacement login reward",
        description: "A replacement task must not repay prior recipients.",
        eventName: "login",
        targetCount: 1,
        rewardCoins: 99,
        status: "active",
        changeNote: "Replace the historical login task",
      },
      admin.token,
    );
    const resumed = await jsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${campaign.item.id}/status`,
      {
        status: "active",
        expectedRevision: replacement.item.revision,
        acknowledgeBudget: true,
        note: "Resume after replacing the login task",
      },
      admin.token,
    );
    assert.equal(resumed.item.status, "active");
    assert.equal(balance(eligible.userId), 25);
    assert.equal(balance(afterActivation.userId), 25);
    assert.equal(one(
      "SELECT COUNT(*) AS total FROM reward_claims WHERE campaign_id = ? AND user_id = ?",
      [campaign.item.id, eligible.userId],
    ).total, 1, "a replacement login task remains idempotent at campaign scope");

    const invalidBanner = await uploadBanner(app, admin.token, "invalid-login-reward.png");
    const invalidCampaign = await createCampaign(app, admin.token, {
      campaignKey: "invalid-legacy-login-reward",
      title: "Invalid legacy reward",
      description: "Activation must validate rows created outside the admin form.",
      bannerUrl: invalidBanner.url,
      startsAt: new Date(Date.now() - 60_000).toISOString(),
      endsAt: new Date(Date.now() + 86400_000).toISOString(),
      audiencePreset: "all_registered",
      minVersionCode: 0,
    });
    run(
      `INSERT INTO activity_tasks
       (campaign_id, task_key, title, event_name, target_count, reward_coins, status)
       VALUES (?, 'legacy-login', 'Legacy login', 'login', 2, 10, 'active')`,
      [invalidCampaign.item.id],
    );
    const invalidActivation = await rawJsonRequest(
      app,
      "POST",
      `/admin/growth/campaigns/${invalidCampaign.item.id}/status`,
      { status: "active", expectedRevision: invalidCampaign.item.revision,
        acknowledgeBudget: true, note: "Attempt activation of invalid legacy data" },
      admin.token,
    );
    assert.equal(invalidActivation.statusCode, 400);
    assert.equal(invalidActivation.json().error, "growth_campaign_login_task_target_invalid");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

async function createUserAndSession(app, { email, createdAt, versionCode }) {
  const userId = Number(run(
    `INSERT INTO users
       (email, nickname, password_hash, role, status, created_at)
     VALUES (?, ?, ?, 'user', 'active', ${createdAt})`,
    [email, email.split("@")[0], hashPassword("reader123456")],
  ).lastInsertRowid);
  const session = await login(app, email, "reader123456");
  await jsonRequest(
    app, "POST", "/users/me/app-install",
    { installId: `install-${userId}`, versionName: "4.1.42", versionCode, platform: "android" },
    session.token,
  );
  return { userId, token: session.token };
}

async function createCampaign(app, token, values) {
  return jsonRequest(
    app, "POST", "/admin/growth/campaigns",
    { ...values, maxVersionCode: 0, changeNote: "Create a login reward campaign" }, token,
  );
}

function balance(userId) {
  return Number(one("SELECT sakura_coins FROM users WHERE id = ?", [userId])?.sakura_coins || 0);
}

const pngBytes = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

async function uploadBanner(app, token, fileName) {
  const boundary = `----login-reward-banner-${Date.now()}-${Math.random()}`;
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: image/png\r\n\r\n`,
    ),
    pngBytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const response = await app.inject({
    method: "POST",
    url: `${config.apiPrefix}/admin/growth/campaign-banners`,
    headers: { authorization: `Bearer ${token}`, "content-type": `multipart/form-data; boundary=${boundary}` },
    payload,
  });
  assert.equal(response.statusCode, 200, response.body);
  return response.json();
}

async function login(app, email, password) {
  return jsonRequest(app, "POST", "/auth/login", { email, password });
}

async function jsonRequest(app, method, route, body, token = "") {
  const response = await rawJsonRequest(app, method, route, body, token);
  assert.ok(response.statusCode >= 200 && response.statusCode < 300,
    `${method} ${route} failed: ${response.statusCode} ${response.body}`);
  return response.json();
}

function rawJsonRequest(app, method, route, body, token = "") {
  return app.inject({
    method,
    url: `${config.apiPrefix}${route}`,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { payload: JSON.stringify(body) }),
  });
}
