import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-kdjx-game-'));
process.env.NODE_ENV = 'test';
process.env.DB_PATH = path.join(tempDir, 'kdjx-game.sqlite');
process.env.TOKEN_SECRET = 'kdjx-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'kdjx-test-settings-secret';
process.env.ADMIN_USERNAME = 'kdjx-test-admin';
process.env.ADMIN_PASSWORD = 'kdjx-test-admin-password';
process.env.KDJX_DEVICE_AUTHORIZATION_URL =
  'sakura-novel://game/kdjx/authorize';
process.env.KDJX_SSO_SHARED_SECRET = 'kdjx-test-sso-secret';
process.env.KDJX_SESSION_TTL_DAYS = '3650';
process.env.KDJX_SESSION_MAX_PER_USER = '3';
process.env.KDJX_PAYMENT_CATALOG_JSON = JSON.stringify({
  schemaVersion: 1,
  conversion: '10_SAKURA_COINS_EQUAL_1_CNY',
  productCount: 2,
  products: [
    {
      productId: '9',
      productName: '6 yuan recharge',
      rechargeId: 9,
      moneyCents: 600,
      coinCost: 60,
    },
    {
      productId: '100',
      productName: 'reserved product',
      rechargeId: 100,
      moneyCents: 100,
      coinCost: 10,
    },
  ],
});
process.env.KDJX_PAYMENT_VERIFY_URL =
  'https://game.example.test/internal/sakura/payments/verify';
process.env.KDJX_PAYMENT_FULFILLMENT_URL =
  'https://game.example.test/internal/sakura/payments/fulfill';
process.env.KDJX_PAYMENT_HMAC_SECRET = 'kdjx-test-payment-secret';
process.env.KDJX_PAYMENT_MAX_ATTEMPTS = '2';

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

test('KDJX uses device authorization and has no legacy ticket routes', async () => {
  const userId = seedUser({ coins: 20, nickname: 'kdjx-user' });
  const bearer = createSession(userId);
  const app = await makeApp();

  try {
    const legacyIssue = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/sso-ticket',
    );
    assert.equal(legacyIssue.statusCode, 404);
    const legacyConsume = await app.inject({
      method: 'POST',
      url: '/games/kdjx/sso-ticket/consume',
      headers: { 'x-kdjx-sso-secret': process.env.KDJX_SSO_SHARED_SECRET },
      payload: { ticket: 'kdjx_ticket_removed' },
    });
    assert.equal(legacyConsume.statusCode, 404);
    assert.equal(one(
      `SELECT name FROM sqlite_master
       WHERE type = 'table' AND name = 'kdjx_game_sso_tickets'`,
    ), undefined);

    const issued = await authorizeDevice(app, bearer);
    assert.equal(issued.credentialExpiresIn, 3650 * 86400);
    assert.match(issued.credential, /^kdjx_session_/);
    assert.match(issued.gameOpenId, /^sakura_/);
    assert.equal(Object.hasOwn(issued, 'accountPassword'), false);
    const storedSession = one(
      `SELECT token_hash FROM kdjx_game_sessions WHERE user_id = ?`,
      [userId],
    );
    assert.equal(
      storedSession.token_hash,
      hashToken(`kdjx-session:${issued.credential}`),
    );

    const unauthenticated = await app.inject({
      method: 'POST',
      url: '/games/kdjx/sessions/verify',
      payload: { credential: issued.credential },
    });
    assert.equal(unauthenticated.statusCode, 401);
    const wrongSecret = await app.inject({
      method: 'POST',
      url: '/games/kdjx/sessions/verify',
      headers: { 'x-kdjx-sso-secret': 'wrong-secret' },
      payload: { credential: issued.credential },
    });
    assert.equal(wrongSecret.statusCode, 401);

    const verified = await verifyCredential(app, issued.credential);
    assert.equal(verified.statusCode, 200);
    assert.equal(verified.json().accountName, issued.gameOpenId);
    assert.equal(verified.json().channel, 'sakura');
    assert.equal(verified.json().nickname, 'kdjx-user');
    assert.ok(verified.json().accountPassword.length >= 30);
    assert.ok(one(
      `SELECT last_used_at FROM kdjx_game_sessions WHERE user_id = ?`,
      [userId],
    ).last_used_at);

    const revoked = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/sessions/revoke',
      { credential: issued.credential },
    );
    assert.deepEqual(revoked.json(), { ok: true, revoked: 1 });
    assert.equal((await verifyCredential(app, issued.credential)).statusCode, 401);
  } finally {
    await app.close();
  }
});

test('KDJX payments preserve the yuan price and debit Sakura coins once', async () => {
  const userId = seedUser({ coins: 200, nickname: 'payer' });
  const bearer = createSession(userId);
  const app = await makeApp();
  await authorizeDevice(app, bearer);

  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    const body = JSON.parse(options.body);
    if (url === process.env.KDJX_PAYMENT_VERIFY_URL) {
      return jsonResponse({ ok: true, order: body });
    }
    return jsonResponse({
      ok: true,
      fulfilled: true,
      rechargeFlag: true,
      gameOrderId: body.gameOrderId,
      channelOrderId: body.channelOrderId,
      gamePaymentOrderId: '64b000000000000000000001',
    });
  };

  try {
    const input = paymentInput('game-1', 'idem-1');
    const preview = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments/preview',
      { ...input, moneyCents: 1, rechargeId: 3 },
    );
    assert.equal(preview.statusCode, 200);
    assert.deepEqual(preview.json().item, {
      gameOrderId: 'game-1',
      channelOrderId: 'sakura_game-1',
      sakuraOrderId: 'sakura_game-1',
      accountId: input.accountId,
      roleId: input.roleId,
      serverKey: input.serverKey,
      yyId: 0,
      csvId: 0,
      productId: '9',
      productName: '6 yuan recharge',
      rechargeId: 9,
      moneyCents: 600,
      coinCost: 60,
      balance: 200,
      status: 'preview',
      lastError: '',
      canRetry: false,
    });

    const paid = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments',
      { ...input, moneyCents: 1, rechargeId: 3 },
    );
    assert.equal(paid.statusCode, 200);
    assert.equal(paid.headers['cache-control'], 'no-store');
    assert.equal(paid.json().item.status, 'fulfilled');
    assert.equal(paid.json().item.moneyCents, 600);
    assert.equal(paid.json().item.coinCost, 60);
    assert.equal(paid.json().item.balance, 140);
    assert.equal(paid.json().item.channelOrderId, 'sakura_game-1');
    assert.equal(paid.json().item.sakuraOrderId, 'sakura_game-1');
    assert.equal(calls.length, 3);

    const fulfillmentCall = calls.find(
      (call) => call.url === process.env.KDJX_PAYMENT_FULFILLMENT_URL,
    );
    assert.ok(fulfillmentCall);
    const fulfillment = fulfillmentCall.options;
    const fulfillmentBody = JSON.parse(fulfillment.body);
    assert.deepEqual(fulfillmentBody, {
      novelOrderId: one(
        `SELECT id FROM kdjx_payment_orders WHERE game_order_id = ?`,
        ['game-1'],
      ).id,
      gameOrderId: 'game-1',
      channelOrderId: 'sakura_game-1',
      gameOpenId: one(
        `SELECT game_open_id FROM kdjx_game_account_links
         WHERE novel_user_id = ?`,
        [userId],
      ).game_open_id,
      accountId: input.accountId,
      roleId: input.roleId,
      serverKey: input.serverKey,
      productId: '9',
      rechargeId: 9,
      yyId: 0,
      csvId: 0,
      moneyCents: 600,
      coinCost: 60,
      amountYuan: '6.00',
      channel: 'sakura',
    });
    assert.match(fulfillment.headers['x-novel-timestamp'], /^\d{13}$/);
    assert.match(
      fulfillment.headers['x-novel-nonce'],
      /^[0-9a-f-]{36}$/i,
    );
    assert.equal(fulfillment.headers['x-novel-signature-version'], 'v1');
    assert.equal(
      fulfillment.headers['x-novel-signature'],
      createHmac('sha256', process.env.KDJX_PAYMENT_HMAC_SECRET)
        .update(
          `${fulfillment.headers['x-novel-timestamp']}\n` +
          `${fulfillment.headers['x-novel-nonce']}\n${fulfillment.body}`,
        )
        .digest('hex'),
    );

    const link = one(
      `SELECT game_account_id, last_role_id, last_server_key
       FROM kdjx_game_account_links WHERE novel_user_id = ?`,
      [userId],
    );
    assert.deepEqual({ ...link }, {
      game_account_id: input.accountId,
      last_role_id: input.roleId,
      last_server_key: input.serverKey,
    });

    const replay = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments',
      input,
    );
    assert.equal(replay.statusCode, 200);
    assert.equal(replay.json().item.balance, 140);
    assert.equal(calls.length, 3);
    assert.equal(
      one(
        `SELECT COUNT(*) count FROM user_reward_events
         WHERE action = 'kdjx_payment' AND user_id = ?`,
        [userId],
      ).count,
      1,
    );

    const conflict = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments',
      paymentInput('game-2', 'idem-1'),
    );
    assert.equal(conflict.statusCode, 409);
    assert.equal(conflict.json().error, 'payment_idempotency_conflict');
    assert.equal(calls.length, 3);

    const reservedProduct = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments/preview',
      { ...paymentInput('reserved-100', 'reserved-100'), productId: '100' },
    );
    assert.equal(reservedProduct.statusCode, 404);
    assert.equal(reservedProduct.json().error, 'payment_product_not_found');
    assert.equal(calls.length, 3);
    assert.equal(userCoins(userId), 140);
  } finally {
    await app.close();
  }
});

test('KDJX device authorization lets the game poll after Sakura app approval', async () => {
  const userId = seedUser({ coins: 20, nickname: 'device-user' });
  const bearer = createSession(userId);
  const app = await makeApp();

  try {
    const created = await app.inject({
      method: 'POST',
      url: '/games/kdjx/device-authorizations',
    });
    assert.equal(created.statusCode, 200);
    assert.equal(created.headers['cache-control'], 'no-store');
    const authorization = created.json();
    assert.match(authorization.deviceCode, /^kdjx_device_/);
    assert.match(authorization.userCode, /^[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$/);
    assert.equal(authorization.expiresIn, 600);
    assert.equal(authorization.interval, 5);
    assert.equal(
      new URL(authorization.verificationUriComplete).searchParams.get(
        'device_code',
      ),
      authorization.deviceCode,
    );
    assert.equal(
      new URL(authorization.verificationUriComplete).searchParams.get(
        'user_code',
      ),
      authorization.userCode,
    );
    assert.equal(Object.hasOwn(authorization, 'launchUrl'), false);
    assert.equal(Object.hasOwn(authorization, 'credential'), false);

    const stored = one(
      `SELECT device_code_hash, user_code_hash, status
       FROM kdjx_device_authorizations
       WHERE device_code_hash = ?`,
      [hashToken(`kdjx-device:${authorization.deviceCode}`)],
    );
    assert.equal(
      stored.device_code_hash,
      hashToken(`kdjx-device:${authorization.deviceCode}`),
    );
    assert.equal(
      stored.user_code_hash,
      hashToken(
        `kdjx-user-code:${authorization.userCode.replace('-', '')}`,
      ),
    );
    assert.equal(stored.status, 'pending');
    assert.notEqual(stored.device_code_hash, authorization.deviceCode);
    assert.notEqual(stored.user_code_hash, authorization.userCode);

    const pending = await pollDeviceCode(app, authorization.deviceCode);
    assert.equal(pending.statusCode, 202);
    assert.deepEqual(pending.json(), {
      status: 'pending',
      error: 'authorization_pending',
      retryAfter: 5,
    });
    assert.equal(pending.headers['retry-after'], '5');

    const tooFast = await pollDeviceCode(app, authorization.deviceCode);
    assert.equal(tooFast.statusCode, 429);
    assert.equal(tooFast.json().error, 'slow_down');

    const anonymousApproval = await app.inject({
      method: 'POST',
      url: '/games/kdjx/device-authorizations/approve',
      payload: { deviceCode: authorization.deviceCode },
    });
    assert.equal(anonymousApproval.statusCode, 401);

    const mismatchedCodes = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/approve',
      {
        deviceCode: authorization.deviceCode,
        userCode: '2222-2222',
      },
    );
    assert.equal(mismatchedCodes.statusCode, 400);
    assert.equal(mismatchedCodes.json().error, 'invalid_device_code');

    const approved = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/approve',
      { deviceCode: authorization.deviceCode },
    );
    assert.equal(approved.statusCode, 200);
    assert.equal(approved.json().status, 'approved');
    assert.equal(Object.hasOwn(approved.json(), 'credential'), false);

    const approvedAgain = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/approve',
      {
        deviceCode: authorization.deviceCode,
        userCode: authorization.userCode.toLowerCase(),
      },
    );
    assert.equal(approvedAgain.statusCode, 200);
    assert.equal(approvedAgain.json().status, 'approved');

    run(
      `UPDATE kdjx_device_authorizations
       SET last_polled_at = datetime('now', '-6 seconds')
       WHERE device_code_hash = ?`,
      [hashToken(`kdjx-device:${authorization.deviceCode}`)],
    );
    const exchanged = await pollDeviceCode(app, authorization.deviceCode);
    assert.equal(exchanged.statusCode, 200);
    const credential = exchanged.json();
    assert.equal(credential.ok, true);
    assert.equal(credential.status, 'authorized');
    assert.equal(credential.tokenType, 'Bearer');
    assert.match(credential.credential, /^kdjx_session_/);
    assert.equal(credential.credentialExpiresIn, 3650 * 86400);
    assert.match(credential.gameOpenId, /^sakura_/);
    assert.equal(
      one(
        `SELECT token_hash FROM kdjx_game_sessions
         WHERE user_id = ? ORDER BY rowid DESC LIMIT 1`,
        [userId],
      ).token_hash,
      hashToken(`kdjx-session:${credential.credential}`),
    );
    assert.equal((await verifyCredential(app, credential.credential)).statusCode, 200);

    run(
      `UPDATE kdjx_device_authorizations
       SET last_polled_at = datetime('now', '-6 seconds')
       WHERE device_code_hash = ?`,
      [hashToken(`kdjx-device:${authorization.deviceCode}`)],
    );
    const replay = await pollDeviceCode(app, authorization.deviceCode);
    assert.equal(replay.statusCode, 409);
    assert.equal(replay.json().error, 'device_code_already_used');
  } finally {
    await app.close();
  }
});

test('KDJX device authorization supports denial and expiration', async () => {
  const userId = seedUser({ coins: 20, nickname: 'device-deny' });
  const bearer = createSession(userId);
  const app = await makeApp();

  try {
    const deniedAuthorization = (
      await app.inject({
        method: 'POST',
        url: '/games/kdjx/device-authorizations',
      })
    ).json();
    const denied = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/deny',
      { deviceCode: deniedAuthorization.deviceCode },
    );
    assert.equal(denied.statusCode, 200);
    assert.equal(denied.json().status, 'denied');
    const deniedPoll = await pollDeviceCode(
      app,
      deniedAuthorization.deviceCode,
    );
    assert.equal(deniedPoll.statusCode, 403);
    assert.equal(deniedPoll.json().error, 'access_denied');
    const approveDenied = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/approve',
      { userCode: deniedAuthorization.userCode },
    );
    assert.equal(approveDenied.statusCode, 409);

    const expiredAuthorization = (
      await app.inject({
        method: 'POST',
        url: '/games/kdjx/device-authorizations',
      })
    ).json();
    run(
      `UPDATE kdjx_device_authorizations
       SET expires_at = datetime('now', '-1 second')
       WHERE device_code_hash = ?`,
      [hashToken(`kdjx-device:${expiredAuthorization.deviceCode}`)],
    );
    const expiredPoll = await pollDeviceCode(
      app,
      expiredAuthorization.deviceCode,
    );
    assert.equal(expiredPoll.statusCode, 410);
    assert.equal(expiredPoll.json().error, 'expired_device_code');
    const approveExpired = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/device-authorizations/approve',
      { deviceCode: expiredAuthorization.deviceCode },
    );
    assert.equal(approveExpired.statusCode, 410);
  } finally {
    await app.close();
  }
});

test('KDJX payment delivery failures remain idempotently retryable', async () => {
  const userId = seedUser({ coins: 100, nickname: 'retry' });
  const bearer = createSession(userId);
  const app = await makeApp();
  await authorizeDevice(app, bearer);
  let fulfillmentAttempts = 0;
  globalThis.fetch = async (url, options) => {
    const body = JSON.parse(options.body);
    if (url === process.env.KDJX_PAYMENT_VERIFY_URL) {
      return jsonResponse({ ok: true, order: body });
    }
    fulfillmentAttempts += 1;
    if (fulfillmentAttempts === 1) return new Response('{}', { status: 503 });
    return jsonResponse({
      ok: true,
      fulfilled: true,
      rechargeFlag: true,
      gameOrderId: body.gameOrderId,
      channelOrderId: body.channelOrderId,
      gamePaymentOrderId: '64b000000000000000000002',
    });
  };

  try {
    const paid = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments',
      paymentInput('retry-1', 'retry-1'),
    );
    assert.equal(paid.statusCode, 200);
    assert.equal(paid.json().item.status, 'delivery_failed');
    assert.equal(paid.json().item.balance, 40);

    const retry = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments/retry-1/retry',
    );
    assert.equal(retry.statusCode, 200);
    assert.equal(retry.json().item.status, 'fulfilled');
    assert.equal(retry.json().item.balance, 40);
    assert.equal(retry.json().item.attempts, 2);
    assert.equal(fulfillmentAttempts, 2);
    assert.equal(
      one(
        `SELECT COUNT(*) count FROM user_reward_events
         WHERE action = 'kdjx_payment' AND user_id = ?`,
        [userId],
      ).count,
      1,
    );
  } finally {
    await app.close();
  }
});

test('KDJX payments do not debit when the game identity check mismatches', async () => {
  const userId = seedUser({ coins: 100, nickname: 'mismatch' });
  const bearer = createSession(userId);
  const app = await makeApp();
  await authorizeDevice(app, bearer);
  globalThis.fetch = async (_url, options) => {
    const body = JSON.parse(options.body);
    return jsonResponse({
      ok: true,
      order: { ...body, roleId: 'ffffffffffffffffffffffff' },
    });
  };

  try {
    const rejected = await request(
      app,
      bearer,
      'POST',
      '/games/kdjx/payments',
      paymentInput('mismatch-1', 'mismatch-1'),
    );
    assert.equal(rejected.statusCode, 502);
    assert.equal(rejected.json().error, 'game_order_verification_mismatch');
    assert.equal(userCoins(userId), 100);
    assert.equal(
      one(
        `SELECT COUNT(*) count FROM kdjx_payment_orders WHERE user_id = ?`,
        [userId],
      ).count,
      0,
    );
  } finally {
    await app.close();
  }
});

function seedUser({ coins, nickname }) {
  userSequence += 1;
  return Number(run(
    `INSERT INTO users (email, nickname, password_hash, sakura_coins)
     VALUES (?, ?, ?, ?)`,
    [
      `kdjx-${userSequence}@example.test`,
      nickname,
      hashPassword('test-password'),
      coins,
    ],
  ).lastInsertRowid);
}

function paymentInput(gameOrderId, idempotencyKey) {
  return {
    gameOrderId,
    idempotencyKey,
    productId: '9',
    accountId: '64a000000000000000000001',
    roleId: '64a000000000000000000002',
    serverKey: 'game.cn_qd.1',
    yyId: 0,
    csvId: 0,
  };
}

function userCoins(userId) {
  return Number(
    one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins,
  );
}

async function authorizeDevice(app, bearer) {
  const created = await app.inject({
    method: 'POST',
    url: '/games/kdjx/device-authorizations',
  });
  assert.equal(created.statusCode, 200);
  const deviceCode = created.json().deviceCode;
  const approval = await request(
    app,
    bearer,
    'POST',
    '/games/kdjx/device-authorizations/approve',
    { deviceCode },
  );
  assert.equal(approval.statusCode, 200);
  const exchanged = await pollDeviceCode(app, deviceCode);
  assert.equal(exchanged.statusCode, 200);
  return exchanged.json();
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

function verifyCredential(app, credential) {
  return app.inject({
    method: 'POST',
    url: '/games/kdjx/sessions/verify',
    headers: {
      'x-kdjx-sso-secret': process.env.KDJX_SSO_SHARED_SECRET,
    },
    payload: { credential },
  });
}

function pollDeviceCode(app, deviceCode) {
  return app.inject({
    method: 'POST',
    url: '/games/kdjx/device-authorizations/token',
    payload: { deviceCode },
  });
}

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
