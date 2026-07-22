import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-bailian-payments-'));
process.env.DB_PATH = path.join(tempDir, 'payments.sqlite');
process.env.TOKEN_SECRET = 'payment-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'payment-test-settings-secret';
process.env.ADMIN_USERNAME = 'payment-test-admin';
process.env.ADMIN_PASSWORD = 'payment-test-admin-password';
process.env.BAILIAN_PAYMENT_CATALOG_JSON = JSON.stringify([
  { productId: 'pack_6', productName: '6元礼包', moneyCents: 600 },
]);
process.env.BAILIAN_PAYMENT_FULFILLMENT_URL = 'https://game.example.test/internal/payment';
process.env.BAILIAN_PAYMENT_HMAC_SECRET = 'payment-hmac-secret';
process.env.BAILIAN_PAYMENT_MAX_ATTEMPTS = '2';

const Fastify = (await import('fastify')).default;
const { authRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { gameRoutes } = await import('./routes-game.js');
const { hashPassword } = await import('./security.js');

test('Bailian payments trust catalog price and are idempotent', async () => {
  migrate();
  const userId = seedUser(200);
  const bearer = createSession(userId);
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return new Response('{}', { status: 200 });
  };
  const app = await makeApp();
  try {
    const preview = await request(app, bearer, 'POST', '/games/bailian/payments/preview', {
      gameOrderId: 'game-1', productId: 'pack_6', moneyCents: 1,
    });
    assert.equal(preview.statusCode, 200);
    assert.deepEqual(preview.json().item, {
      gameOrderId: 'game-1', productId: 'pack_6', productName: '6元礼包', moneyCents: 600, coinCost: 60, balance: 200,
    });

    const paid = await request(app, bearer, 'POST', '/games/bailian/payments', {
      gameOrderId: 'game-1', productId: 'pack_6', idempotencyKey: 'idem-1', moneyCents: 1,
    });
    assert.equal(paid.statusCode, 200);
    assert.equal(paid.json().item.status, 'fulfilled');
    assert.equal(paid.json().item.balance, 140);
    assert.equal(calls.length, 1);
    const fulfillment = calls[0].options;
    const fulfillmentBody = JSON.parse(fulfillment.body);
    assert.deepEqual(fulfillmentBody, {
      novelOrderId: one('SELECT id FROM bailian_payment_orders WHERE game_order_id = ?', ['game-1']).id,
      gameOrderId: 'game-1',
      gameOpenId: `novel_${userId}`,
      productId: 'pack_6',
      moneyCents: 600,
    });
    assert.match(fulfillment.headers['x-novel-timestamp'], /^\d{13}$/);
    assert.match(fulfillment.headers['x-novel-nonce'], /^[0-9a-f-]{36}$/i);
    assert.equal(
      fulfillment.headers['x-novel-signature'],
      createHmac('sha256', process.env.BAILIAN_PAYMENT_HMAC_SECRET)
        .update(`${fulfillment.headers['x-novel-timestamp']}\n${fulfillment.body}`)
        .digest('hex'),
    );
    assert.equal(fulfillment.headers['x-bailian-signature'], undefined);

    const replay = await request(app, bearer, 'POST', '/games/bailian/payments', {
      gameOrderId: 'game-1', productId: 'pack_6', idempotencyKey: 'idem-1',
    });
    assert.equal(replay.statusCode, 200);
    assert.equal(replay.json().item.balance, 140);
    assert.equal(calls.length, 1);
    assert.equal(one("SELECT COUNT(*) count FROM user_reward_events WHERE action = 'bailian_payment'").count, 1);

    const conflict = await request(app, bearer, 'POST', '/games/bailian/payments', {
      gameOrderId: 'game-2', productId: 'pack_6', idempotencyKey: 'idem-1',
    });
    assert.equal(conflict.statusCode, 409);
  } finally { await app.close(); }
});

test('Bailian payments reject insufficient funds and refund after delivery exhaustion', async () => {
  const poorId = seedUser(20, 'poor');
  const poorBearer = createSession(poorId);
  const app = await makeApp();
  globalThis.fetch = async () => new Response('{}', { status: 503 });
  try {
    const insufficient = await request(app, poorBearer, 'POST', '/games/bailian/payments', {
      gameOrderId: 'poor-1', productId: 'pack_6', idempotencyKey: 'poor-1',
    });
    assert.equal(insufficient.statusCode, 409);
    assert.equal(insufficient.json().error, 'coins_not_enough');
    assert.equal(one('SELECT sakura_coins FROM users WHERE id = ?', [poorId]).sakura_coins, 20);

    const userId = seedUser(100, 'refund');
    const bearer = createSession(userId);
    const first = await request(app, bearer, 'POST', '/games/bailian/payments', {
      gameOrderId: 'refund-1', productId: 'pack_6', idempotencyKey: 'refund-1',
    });
    assert.equal(first.json().item.status, 'delivery_failed');
    assert.equal(first.json().item.balance, 40);
    const retry = await request(app, bearer, 'POST', '/games/bailian/payments/refund-1/retry');
    assert.equal(retry.json().item.status, 'refunded');
    assert.equal(retry.json().item.balance, 100);
    assert.equal(one("SELECT COUNT(*) count FROM user_reward_events WHERE action = 'bailian_payment_refund' AND user_id = ?", [userId]).count, 1);
    const retryAgain = await request(app, bearer, 'POST', '/games/bailian/payments/refund-1/retry');
    assert.equal(retryAgain.json().item.status, 'refunded');
    assert.equal(one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins, 100);
  } finally {
    await app.close(); closeDb(); fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function seedUser(coins, suffix = 'main') {
  const id = Number(run(
    `INSERT INTO users (email, nickname, password_hash, sakura_coins)
     VALUES (?, ?, ?, ?)`,
    [`payment-${suffix}-${Date.now()}@example.test`, suffix, hashPassword('password'), coins],
  ).lastInsertRowid);
  run('INSERT INTO game_account_links (novel_user_id, game_open_id) VALUES (?, ?)', [id, `novel_${id}`]);
  return id;
}

async function makeApp() {
  const app = Fastify({ logger: false }); app.decorate('authRequired', authRequired); app.register(gameRoutes); await app.ready(); return app;
}

function request(app, bearer, method, url, payload) {
  return app.inject({ method, url, headers: { authorization: `Bearer ${bearer}` }, ...(payload ? { payload } : {}) });
}
