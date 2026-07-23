import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-modao-game-'));
process.env.DB_PATH = path.join(tempDir, 'modao-game.sqlite');
process.env.TOKEN_SECRET = 'modao-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'modao-test-settings-secret';
process.env.ADMIN_USERNAME = 'modao-test-admin';
process.env.ADMIN_PASSWORD = 'modao-test-admin-password';
process.env.MODAO_LAUNCH_URL = 'modao://launch';
process.env.MODAO_SSO_SHARED_SECRET = 'modao-test-sso-secret';
process.env.MODAO_SSO_TTL_SECONDS = '600';
process.env.MODAO_PAYMENT_CATALOG_JSON = JSON.stringify({
  schemaVersion: 2,
  conversion: '10_SAKURA_COINS_EQUAL_1_CNY',
  productCount: 1,
  products: [
    {
      productId: 'pack_6',
      productName: '6 yuan pack',
      moneyCents: 600,
      coinCost: 60,
    },
  ],
});
process.env.MODAO_PAYMENT_VERIFY_URL =
  'https://game.example.test/sakura/payment/verify';
process.env.MODAO_PAYMENT_FULFILLMENT_URL =
  'https://game.example.test/sakura/payment/fulfill';
process.env.MODAO_PAYMENT_HMAC_SECRET = 'modao-test-payment-secret';
process.env.MODAO_PAYMENT_MAX_ATTEMPTS = '2';

const Fastify = (await import('fastify')).default;
const { authRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { gameRoutes } = await import('./routes-game.js');
const { hashPassword, hashToken } = await import('./security.js');

const originalFetch = globalThis.fetch;
let userSequence = 0;

migrate();

after(() => {
  globalThis.fetch = originalFetch;
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});

test('Modao SSO tickets are isolated, short-lived, and single-use', async () => {
  const userId = seedUser({ coins: 20, nickname: 'modao-user' });
  const bearer = createSession(userId);
  const app = await makeApp();

  try {
    const anonymous = await app.inject({
      method: 'POST',
      url: '/games/modao/sso-ticket',
    });
    assert.equal(anonymous.statusCode, 401);

    const issued = await request(
      app,
      bearer,
      'POST',
      '/games/modao/sso-ticket',
    );
    assert.equal(issued.statusCode, 200);
    assert.equal(issued.headers['cache-control'], 'no-store');
    const payload = issued.json();
    assert.equal(payload.expiresIn, 600);
    assert.ok(payload.ticket.length >= 40);
    assert.equal(
      new URL(payload.launchUrl).searchParams.get('ticket'),
      payload.ticket,
    );
    const openId = new URL(payload.launchUrl).searchParams.get('openId');
    assert.match(openId, /^modao_[A-Za-z0-9_-]+$/);
    assert.notEqual(openId, `novel_${userId}`);
    const stored = one(
      'SELECT ticket_hash FROM modao_game_sso_tickets WHERE user_id = ?',
      [userId],
    );
    assert.equal(stored.ticket_hash, hashToken(payload.ticket));
    assert.notEqual(stored.ticket_hash, payload.ticket);

    const wrongSecret = await consumeTicket(app, payload.ticket, 'wrong-secret');
    assert.equal(wrongSecret.statusCode, 401);
    assert.equal(
      one(
        'SELECT consumed_at FROM modao_game_sso_tickets WHERE user_id = ?',
        [userId],
      ).consumed_at,
      null,
    );

    const consumed = await consumeTicket(
      app,
      payload.ticket,
      process.env.MODAO_SSO_SHARED_SECRET,
    );
    assert.equal(consumed.statusCode, 200);
    assert.deepEqual(consumed.json(), {
      ok: true,
      userId: String(userId),
      gameOpenId: openId,
      nickname: 'modao-user',
      avatarUrl: '',
      expiresAt: payload.expiresAt,
    });

    const replay = await consumeTicket(
      app,
      payload.ticket,
      process.env.MODAO_SSO_SHARED_SECRET,
    );
    assert.equal(replay.statusCode, 401);
    assert.equal(replay.json().error, 'invalid_or_expired_ticket');

    const second = (
      await request(app, bearer, 'POST', '/games/modao/sso-ticket')
    ).json();
    assert.equal(
      new URL(second.launchUrl).searchParams.get('openId'),
      openId,
    );
    run(
      `UPDATE modao_game_sso_tickets
       SET expires_at = datetime('now', '-1 second')
       WHERE ticket_hash = ?`,
      [hashToken(second.ticket)],
    );
    const expired = await consumeTicket(
      app,
      second.ticket,
      process.env.MODAO_SSO_SHARED_SECRET,
    );
    assert.equal(expired.statusCode, 401);
  } finally {
    await app.close();
  }
});

test('Modao payments use the server price and charge ten coins per yuan', async () => {
  const userId = seedUser({ coins: 200, nickname: 'payer', linked: true });
  const bearer = createSession(userId);
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    if (url === process.env.MODAO_PAYMENT_VERIFY_URL) {
      const body = JSON.parse(options.body);
      return new Response(JSON.stringify({ ok: true, order: body }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    const body = JSON.parse(options.body);
    return new Response(JSON.stringify({
      ok: true,
      fulfilled: true,
      gameOrderId: body.gameOrderId,
      payState: 2,
    }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };
  const app = await makeApp();

  try {
    const preview = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments/preview',
      { gameOrderId: 'game-1', productId: 'pack_6', moneyCents: 1 },
    );
    assert.equal(preview.statusCode, 200);
    assert.deepEqual(preview.json().item, {
      gameOrderId: 'game-1',
      productId: 'pack_6',
      productName: '6 yuan pack',
      moneyCents: 600,
      coinCost: 60,
      balance: 200,
    });

    const paid = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'game-1',
        productId: 'pack_6',
        idempotencyKey: 'idem-1',
        moneyCents: 1,
      },
    );
    assert.equal(paid.statusCode, 200);
    assert.equal(paid.headers['cache-control'], 'no-store');
    assert.equal(paid.json().item.status, 'fulfilled');
    assert.equal(paid.json().item.coinCost, 60);
    assert.equal(paid.json().item.balance, 140);
    assert.equal(calls.length, 3);

    const verificationCalls = calls.filter(
      (call) => call.url === process.env.MODAO_PAYMENT_VERIFY_URL,
    );
    assert.equal(verificationCalls.length, 2);
    const fulfillmentCall = calls.find(
      (call) => call.url === process.env.MODAO_PAYMENT_FULFILLMENT_URL,
    );
    assert.ok(fulfillmentCall);
    const fulfillment = fulfillmentCall.options;
    const fulfillmentBody = JSON.parse(fulfillment.body);
    assert.deepEqual(fulfillmentBody, {
      novelOrderId: one(
        'SELECT id FROM modao_payment_orders WHERE game_order_id = ?',
        ['game-1'],
      ).id,
      gameOrderId: 'game-1',
      gameOpenId: `modao_test_${userId}`,
      productId: 'pack_6',
      moneyCents: 600,
      coinCost: 60,
    });
    assert.match(fulfillment.headers['x-novel-timestamp'], /^\d{13}$/);
    assert.match(
      fulfillment.headers['x-novel-nonce'],
      /^[0-9a-f-]{36}$/i,
    );
    assert.equal(fulfillment.headers['x-novel-signature-version'], 'v1');
    assert.equal(
      fulfillment.headers['x-novel-signature'],
      createHmac('sha256', process.env.MODAO_PAYMENT_HMAC_SECRET)
        .update(
          `${fulfillment.headers['x-novel-timestamp']}\n` +
          `${fulfillment.headers['x-novel-nonce']}\n${fulfillment.body}`,
        )
        .digest('hex'),
    );

    const replay = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'game-1',
        productId: 'pack_6',
        idempotencyKey: 'idem-1',
      },
    );
    assert.equal(replay.statusCode, 200);
    assert.equal(replay.json().item.balance, 140);
    assert.equal(calls.length, 3);
    assert.equal(
      one(
        `SELECT COUNT(*) count FROM user_reward_events
         WHERE action = 'modao_payment' AND user_id = ?`,
        [userId],
      ).count,
      1,
    );

    const conflict = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'game-2',
        productId: 'pack_6',
        idempotencyKey: 'idem-1',
      },
    );
    assert.equal(conflict.statusCode, 409);
    assert.equal(conflict.json().error, 'payment_idempotency_conflict');
  } finally {
    await app.close();
  }
});

test('Modao payments keep ambiguous delivery failures for safe retry', async () => {
  let fulfillmentAttempts = 0;
  globalThis.fetch = async (url, options) => {
    if (url === process.env.MODAO_PAYMENT_VERIFY_URL) {
      const body = JSON.parse(options.body);
      return new Response(JSON.stringify({ ok: true, order: body }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    fulfillmentAttempts += 1;
    return fulfillmentAttempts === 1
      ? new Response('{}', { status: 503 })
      : new Response(JSON.stringify({ ok: false }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
  };
  const app = await makeApp();

  try {
    const poorId = seedUser({ coins: 50, nickname: 'poor', linked: true });
    const insufficient = await request(
      app,
      createSession(poorId),
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'poor-1',
        productId: 'pack_6',
        idempotencyKey: 'poor-1',
      },
    );
    assert.equal(insufficient.statusCode, 409);
    assert.equal(insufficient.json().error, 'coins_not_enough');
    assert.equal(userCoins(poorId), 50);

    const userId = seedUser({ coins: 100, nickname: 'refund', linked: true });
    const bearer = createSession(userId);
    const first = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'refund-1',
        productId: 'pack_6',
        idempotencyKey: 'refund-1',
      },
    );
    assert.equal(first.statusCode, 200);
    assert.equal(first.json().item.status, 'delivery_failed');
    assert.equal(first.json().item.balance, 40);

    const retry = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments/refund-1/retry',
    );
    assert.equal(retry.json().item.status, 'delivery_failed');
    assert.equal(retry.json().item.balance, 40);
    assert.equal(retry.json().item.attempts, 2);
    assert.equal(
      one(
        `SELECT COUNT(*) count FROM user_reward_events
         WHERE action = 'modao_payment_refund' AND user_id = ?`,
        [userId],
      ).count,
      0,
    );

    const retryAgain = await request(
      app,
      bearer,
      'POST',
      '/games/modao/payments/refund-1/retry',
    );
    assert.equal(retryAgain.json().item.status, 'delivery_failed');
    assert.equal(retryAgain.json().item.attempts, 3);
    assert.equal(userCoins(userId), 40);
  } finally {
    await app.close();
  }
});

test('Modao payments verify the game order before deducting coins', async () => {
  globalThis.fetch = async () => new Response(
    JSON.stringify({ ok: false, error: 'game_order_not_found' }),
    {
      status: 404,
      headers: { 'content-type': 'application/json' },
    },
  );
  const app = await makeApp();

  try {
    const userId = seedUser({ coins: 100, nickname: 'verify', linked: true });
    const rejected = await request(
      app,
      createSession(userId),
      'POST',
      '/games/modao/payments',
      {
        gameOrderId: 'missing-order',
        productId: 'pack_6',
        idempotencyKey: 'missing-order',
      },
    );
    assert.equal(rejected.statusCode, 409);
    assert.equal(rejected.json().error, 'game_order_not_payable');
    assert.equal(userCoins(userId), 100);
    assert.equal(
      one(
        'SELECT COUNT(*) count FROM modao_payment_orders WHERE user_id = ?',
        [userId],
      ).count,
      0,
    );
  } finally {
    await app.close();
  }
});

function seedUser({ coins, nickname, linked = false }) {
  userSequence += 1;
  const id = Number(run(
    `INSERT INTO users (email, nickname, password_hash, sakura_coins)
     VALUES (?, ?, ?, ?)`,
    [
      `modao-${userSequence}@example.test`,
      nickname,
      hashPassword('test-password'),
      coins,
    ],
  ).lastInsertRowid);
  if (linked) {
    run(
      `INSERT INTO modao_game_account_links (novel_user_id, game_open_id)
       VALUES (?, ?)`,
      [id, `modao_test_${id}`],
    );
  }
  return id;
}

function userCoins(userId) {
  return Number(
    one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins,
  );
}

async function makeApp() {
  const app = Fastify({ logger: false });
  app.decorate('authRequired', authRequired);
  app.register(gameRoutes);
  await app.ready();
  return app;
}

function request(app, bearer, method, url, payload) {
  return app.inject({
    method,
    url,
    headers: { authorization: `Bearer ${bearer}` },
    ...(payload ? { payload } : {}),
  });
}

function consumeTicket(app, ticket, secret) {
  return app.inject({
    method: 'POST',
    url: '/games/modao/sso-ticket/consume',
    headers: { 'x-modao-sso-secret': secret },
    payload: { ticket },
  });
}
