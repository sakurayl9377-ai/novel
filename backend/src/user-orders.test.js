import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-user-orders-"));
process.env.DB_PATH = path.join(tempDir, "orders.sqlite");
process.env.TOKEN_SECRET = "orders-test-token-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "orders-test-settings-secret";
process.env.ADMIN_USERNAME = "orders-test-admin";
process.env.ADMIN_PASSWORD = "orders-test-admin-password";

const { closeDb, migrate, run } = await import("./db.js");
const { listUserOrders } = await import("./user-orders.js");

test("lists every coin debit and enriches Bailian purchases", () => {
  migrate();
  const userId = Number(run(
    "INSERT INTO users (email, nickname, password_hash, sakura_coins) VALUES (?, ?, ?, ?)",
    ["orders@example.test", "订单用户", "unused", 100],
  ).lastInsertRowid);
  run(
    `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description, related_type, related_id)
     VALUES (?, 'shop_redeem', -12, '兑换商品：头像框', 'shop_item', '7')`,
    [userId],
  );
  run(
    `INSERT INTO bailian_payment_orders
       (id, game_order_id, user_id, game_open_id, product_id, product_name,
        money_cents, coin_cost, idempotency_key, status)
     VALUES ('pay-1', 'game-1', ?, 'novel_1', 'pack-6', '仙玉礼包', 600, 60,
             'idem-1', 'fulfilled')`,
    [userId],
  );
  run(
    `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description, related_type, related_id)
     VALUES (?, 'bailian_payment', -60, '百练英雄充值：仙玉礼包',
             'bailian_payment_order', 'pay-1')`,
    [userId],
  );
  run(
    `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description)
     VALUES (?, 'daily_signin', 3, '签到奖励')`,
    [userId],
  );

  const page = listUserOrders(userId, { limit: 1 });
  assert.equal(page.hasMore, true);
  assert.equal(page.items[0].createdAt.endsWith("Z"), true);
  assert.equal(page.snapshotMaxId, 2);
  assert.deepEqual(page.items[0], {
    id: "2", action: "bailian_payment", title: "仙玉礼包", coinCost: 60,
    source: "bailian", status: "fulfilled", createdAt: page.items[0].createdAt,
    relatedType: "bailian_payment_order", relatedId: "pay-1",
    productId: "pack-6", productName: "仙玉礼包", moneyCents: 600,
  });
  const second = listUserOrders(userId, {
    offset: 1,
    limit: 20,
    snapshotMaxId: page.snapshotMaxId,
  });
  assert.equal(second.items.length, 1);
  assert.equal(second.items[0].title, "兑换商品：头像框");
  assert.equal(second.items[0].source, "shop");
  assert.equal(second.items[0].status, "completed");
});

test.after(() => {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});
