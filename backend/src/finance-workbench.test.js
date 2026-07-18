import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-finance-workbench-"));
process.env.DB_PATH = path.join(tempDir, "finance.sqlite");
process.env.TOKEN_SECRET = "finance-workbench-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "finance-settings-test-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const { buildServer } = await import("./server.js");
const { run } = await import("./db.js");

test("finance workbench filters an immutable, source-aware ledger", async () => {
  const app = await buildServer();
  try {
    const userId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, status, points, sakura_coins)
         VALUES ('ledger-user@example.com', '账本用户', 'unused', 'active', 100, 40)`,
      ).lastInsertRowid,
    );
    const secondUserId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, status, points, sakura_coins)
         VALUES ('ledger-second@example.com', '第二用户', 'unused', 'active', 20, 20)`,
      ).lastInsertRowid,
    );
    const boundaryUserId = Number(
      run(
        `INSERT INTO users
           (email, nickname, password_hash, status, points, sakura_coins)
         VALUES ('ledger-boundary@example.com', '跨日账本用户', 'unused', 'active', 0, 0)`,
      ).lastInsertRowid,
    );
    const localNow = new Date(Date.now() + 8 * 60 * 60 * 1000);
    const localMidnightUtc = Date.UTC(
      localNow.getUTCFullYear(),
      localNow.getUTCMonth(),
      localNow.getUTCDate(),
    ) - 8 * 60 * 60 * 1000;
    const localDay = new Date(localMidnightUtc + 8 * 60 * 60 * 1000)
      .toISOString()
      .slice(0, 10);
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id, created_at)
       VALUES (?, 'boundary_before', 1, '本地午夜前', 'daily', 'before', ?)`,
      [boundaryUserId, sqliteTimestamp(new Date(localMidnightUtc - 60_000))],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id, created_at)
       VALUES (?, 'boundary_after', 1, '本地午夜后', 'daily', 'after', ?)`,
      [boundaryUserId, sqliteTimestamp(new Date(localMidnightUtc + 60_000))],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, points_delta, coins_delta, description, related_type, related_id)
       VALUES (?, 'daily_signin', 10, 5, '每日签到', 'daily', '2026-07-19')`,
      [userId],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'shop_redeem', -15, '兑换商品', 'shop_item', 'skin-sakura-card')`,
      [userId],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id, created_at)
       VALUES (?, 'campaign_reward', 100, '旧活动奖励', 'campaign', 'old', datetime('now', '-40 days'))`,
      [userId],
    );
    run(
      `INSERT INTO user_reward_events
         (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, 'admin_adjust_coins', 20, '客服补偿', 'admin', '1')`,
      [secondUserId],
    );

    const login = await request(app, "POST", "/auth/login", {
      email: "admin@admin.local",
      password: "admin123456",
    });
    const token = login.token;
    const debit = await request(
      app,
      "GET",
      "/admin/finance/workbench?period=30d&currency=coins&direction=debit&action=shop_redeem&q=ledger-user&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(debit.total, 1);
    assert.equal(debit.summary.affectedUsers, 1);
    assert.equal(debit.summary.coinsDelta, -15);
    assert.equal(debit.summary.coinsSpent, 15);
    assert.equal(debit.items[0].action, "shop_redeem");
    assert.equal(debit.items[0].user.id, userId);
    assert.equal(debit.items[0].user.currentCoins, 40);
    assert.equal(debit.items[0].relatedId, "skin-sakura-card");
    assert.equal(debit.actions[0].action, "shop_redeem");
    assert.equal(debit.daily.length, 1);
    assert.equal(debit.balances.negativeBalances, 0);

    const allTime = await request(
      app,
      "GET",
      "/admin/finance/workbench?period=all&q=ledger-user&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(allTime.total, 3);
    assert.equal(allTime.summary.pointsDelta, 10);
    assert.equal(allTime.summary.coinsDelta, 90);

    const adjustment = await request(
      app,
      "GET",
      "/admin/finance/workbench?period=30d&action=admin_adjust_coins&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(adjustment.total, 1);
    assert.equal(adjustment.items[0].operator.id, 1);

    const today = await request(
      app,
      "GET",
      "/admin/finance/workbench?period=today&q=ledger-boundary&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(today.total, 1);
    assert.equal(today.items[0].action, "boundary_after");
    assert.equal(today.daily[0].day, localDay);

    const boundaryAllTime = await request(
      app,
      "GET",
      "/admin/finance/workbench?period=all&q=ledger-boundary&page=1&pageSize=10",
      undefined,
      token,
    );
    assert.equal(boundaryAllTime.total, 2);
    assert.equal(boundaryAllTime.daily.length, 2);

    const invalid = await app.inject({
      method: "GET",
      url: "/novel-api/admin/finance/workbench?period=quarter",
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(invalid.statusCode, 400);
    assert.equal(invalid.json().error, "finance_period_invalid");
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function sqliteTimestamp(date) {
  return date.toISOString().slice(0, 19).replace("T", " ");
}

async function request(app, method, route, body, token = "") {
  const response = await app.inject({
    method,
    url: `/novel-api${route}`,
    headers: token ? { authorization: `Bearer ${token}` } : undefined,
    payload: body,
  });
  assert.ok(response.statusCode < 400, `${method} ${route}: ${response.body}`);
  return response.json();
}
