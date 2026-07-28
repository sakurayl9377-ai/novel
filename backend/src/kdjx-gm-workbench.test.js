import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-kdjx-gm-'));
process.env.NODE_ENV = 'test';
process.env.DB_PATH = path.join(tempDir, 'kdjx-gm.sqlite');
process.env.TOKEN_SECRET = 'kdjx-gm-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'kdjx-gm-test-settings-secret';
process.env.ADMIN_USERNAME = 'kdjx-gm-test-admin';
process.env.ADMIN_PASSWORD = 'kdjx-gm-test-admin-password';

const Fastify = (await import('fastify')).default;
const { recordAdminAudit } = await import('./admin-audit.js');
const { adminRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { adminKdjxGmRoutes } = await import('./routes-admin-kdjx-gm.js');
const { hashPassword } = await import('./security.js');

migrate();

after(() => {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});

test('KDJX GM workbench protects, redacts, audits, and safely mutates data', async () => {
  let retryCalls = 0;
  const app = await makeApp(async (userId, gameOrderId) => {
    retryCalls += 1;
    run(
      `UPDATE kdjx_payment_orders
       SET status = 'fulfilled', fulfillment_attempts = fulfillment_attempts + 1,
           fulfillment_reference = '64a000000000000000000099',
           fulfilled_at = datetime('now'), last_error = '',
           updated_at = datetime('now')
       WHERE user_id = ? AND game_order_id = ?`,
      [userId, gameOrderId],
    );
  });

  try {
    const adminId = seedUser({
      email: 'gm-admin@example.test',
      nickname: 'GM Admin',
      role: 'admin',
    });
    const playerOneId = seedUser({
      email: 'player-one@example.test',
      nickname: 'Literal%_Player',
      coins: 880,
    });
    const playerTwoId = seedUser({
      email: 'player-two@example.test',
      nickname: 'Banned Player',
      status: 'banned',
      coins: 40,
    });
    const unlinkedId = seedUser({
      email: 'unlinked@example.test',
      nickname: 'Unlinked User',
    });
    const adminToken = createSession(adminId);
    const playerToken = createSession(playerOneId);

    seedLink(playerOneId, {
      openId: 'sakura_player_one',
      accountId: '64a000000000000000000001',
      roleId: '64a000000000000000000002',
      serverKey: 'game.cn_qd.1',
      cipher: 'never-return-account-password-cipher',
    });
    seedLink(playerTwoId, {
      openId: 'sakura_player_two',
      accountId: '64a000000000000000000011',
      roleId: '64a000000000000000000012',
      serverKey: 'game.cn_qd.2',
      cipher: 'second-never-return-cipher',
    });
    seedSession(playerOneId, 'session-one-active', 'token-hash-one', 'active');
    seedSession(playerOneId, 'session-one-revoked', 'token-hash-revoked', 'revoked');
    seedSession(playerOneId, 'session-one-expired', 'token-hash-expired', 'expired');
    seedSession(playerTwoId, 'session-two-active', 'token-hash-two', 'active');
    seedPayment(playerOneId, {
      id: 'payment-retry-id',
      gameOrderId: 'order-retry',
      status: 'delivery_failed',
      lastError: 'game delivery timeout',
    });
    seedPayment(playerTwoId, {
      id: 'payment-done-id',
      gameOrderId: 'order-done',
      status: 'fulfilled',
      lastError: '',
    });

    const anonymous = await app.inject({
      method: 'GET',
      url: '/admin/games/kdjx/gm/workbench',
    });
    assert.equal(anonymous.statusCode, 401);
    assert.equal(anonymous.json().error, 'unauthorized');

    const ordinaryUser = await adminRequest(
      app,
      playerToken,
      'GET',
      '/admin/games/kdjx/gm/workbench',
    );
    assert.equal(ordinaryUser.statusCode, 403);
    assert.equal(ordinaryUser.json().error, 'admin_required');

    const listed = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/workbench?page=1&pageSize=1',
    );
    assert.equal(listed.statusCode, 200);
    assert.equal(listed.headers['cache-control'], 'no-store');
    assert.equal(listed.json().total, 2);
    assert.equal(listed.json().players.length, 1);
    assert.deepEqual(listed.json().summary, {
      linkedPlayers: 2,
      activeGameSessions: 2,
      paymentOrders: 2,
      deliveryFailed: 1,
      fulfilled: 1,
      totalCoinSpend: 120,
    });
    assertRedacted(listed.body);

    const escapedSearch = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/workbench?q=%25_',
    );
    assert.equal(escapedSearch.statusCode, 200);
    assert.equal(escapedSearch.json().total, 1);
    assert.equal(escapedSearch.json().players[0].userId, playerOneId);

    const bannedOnly = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/workbench?status=banned',
    );
    assert.equal(bannedOnly.statusCode, 200);
    assert.deepEqual(
      bannedOnly.json().players.map((player) => player.userId),
      [playerTwoId],
    );

    const detail = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/players/${playerOneId}`,
    );
    assert.equal(detail.statusCode, 200);
    assert.equal(detail.json().player.gameOpenId, 'sakura_player_one');
    assert.equal(detail.json().player.gameAccountId, '64a000000000000000000001');
    assert.deepEqual(
      new Set(detail.json().sessions.map((session) => session.status)),
      new Set(['active', 'revoked', 'expired']),
    );
    assert.equal(detail.json().payments[0].gameOrderId, 'order-retry');
    assertRedacted(detail.body);

    const payments = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/payments?status=delivery_failed&userId=${playerOneId}`,
    );
    assert.equal(payments.statusCode, 200);
    assert.equal(payments.json().total, 1);
    assert.equal(payments.json().payments[0].canRetry, true);
    assert.equal(payments.json().payments[0].lastError, 'game delivery timeout');
    assertRedacted(payments.body);

    const invalidReason = await adminRequest(
      app,
      adminToken,
      'POST',
      `/admin/games/kdjx/gm/players/${playerOneId}/revoke-sessions`,
      { reason: 'no', expectedActiveSessions: 1 },
    );
    assert.equal(invalidReason.statusCode, 400);
    assert.equal(invalidReason.json().error, 'reason_invalid');

    const staleSessionState = await adminRequest(
      app,
      adminToken,
      'POST',
      `/admin/games/kdjx/gm/players/${playerOneId}/revoke-sessions`,
      { reason: '处理玩家登录异常', expectedActiveSessions: 0 },
    );
    assert.equal(staleSessionState.statusCode, 409);
    assert.equal(staleSessionState.json().error, 'kdjx_session_status_changed');
    assert.equal(activeSessionCount(playerOneId), 1);

    const unlinked = await adminRequest(
      app,
      adminToken,
      'POST',
      `/admin/games/kdjx/gm/players/${unlinkedId}/revoke-sessions`,
      { reason: '确认未关联玩家保护', expectedActiveSessions: 0 },
    );
    assert.equal(unlinked.statusCode, 404);
    assert.equal(unlinked.json().error, 'kdjx_player_not_found');

    const revoked = await adminRequest(
      app,
      adminToken,
      'POST',
      `/admin/games/kdjx/gm/players/${playerOneId}/revoke-sessions`,
      { reason: '处理玩家登录异常', expectedActiveSessions: 1 },
    );
    assert.equal(revoked.statusCode, 200);
    assert.deepEqual(revoked.json(), {
      ok: true,
      userId: playerOneId,
      revokedSessions: 2,
      activeGameSessions: 0,
    });
    assert.equal(activeSessionCount(playerOneId), 0);
    assert.equal(activeSessionCount(playerTwoId), 1);
    assert.ok(one(
      `SELECT id FROM auth_tokens
       WHERE user_id = ? AND revoked_at IS NULL`,
      [playerOneId],
    ));

    const stalePayment = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-retry/retry',
      {
        reason: '重新投递失败订单',
        expectedStatus: 'paid',
        expectedAttempts: 0,
      },
    );
    assert.equal(stalePayment.statusCode, 409);
    assert.equal(stalePayment.json().error, 'kdjx_payment_status_changed');
    assert.equal(retryCalls, 0);

    const completedPayment = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-done/retry',
      {
        reason: '验证已完成订单保护',
        expectedStatus: 'paid',
        expectedAttempts: 0,
      },
    );
    assert.equal(completedPayment.statusCode, 409);
    assert.equal(completedPayment.json().error, 'kdjx_payment_not_retryable');
    assert.equal(retryCalls, 0);

    run(
      `UPDATE kdjx_payment_orders
       SET fulfillment_attempts = 1
       WHERE game_order_id = 'order-retry'`,
    );
    const stalePaymentVersion = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-retry/retry',
      {
        reason: '验证旧页面投递次数保护',
        expectedStatus: 'delivery_failed',
        expectedAttempts: 0,
      },
    );
    assert.equal(stalePaymentVersion.statusCode, 409);
    assert.equal(
      stalePaymentVersion.json().error,
      'kdjx_payment_version_changed',
    );
    assert.equal(retryCalls, 0);

    const retried = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-retry/retry',
      {
        reason: '重新投递失败订单',
        expectedStatus: 'delivery_failed',
        expectedAttempts: 1,
      },
    );
    assert.equal(retried.statusCode, 200);
    assert.equal(retried.json().ok, true);
    assert.equal(retried.json().payment.status, 'fulfilled');
    assert.equal(retried.json().payment.canRetry, false);
    assert.equal(retryCalls, 1);
    assertRedacted(retried.body);

    const actions = await adminRequest(
      app,
      adminToken,
      'GET',
      '/admin/games/kdjx/gm/workbench',
    );
    assert.equal(actions.statusCode, 200);
    assert.ok(actions.json().recentActions.length >= 6);
    assert.ok(actions.json().recentActions.some((action) =>
      action.action === 'revoke_sessions' &&
      action.targetId === String(playerOneId) &&
      action.result === 'success'));
    assert.ok(actions.json().recentActions.some((action) =>
      action.action === 'retry_payment' &&
      action.targetId === 'order-retry' &&
      action.result === 'success'));
    assert.ok(actions.json().recentActions.some((action) =>
      action.errorCode === 'kdjx_payment_status_changed'));
    assert.ok(actions.json().recentActions.some((action) =>
      action.errorCode === 'kdjx_payment_version_changed'));
    assert.ok(actions.json().recentActions.some((action) =>
      action.errorCode === 'reason_invalid'));
    assertRedacted(actions.body);

    assert.ok(Number(one(
      `SELECT COUNT(*) AS count FROM admin_audit_logs
       WHERE admin_user_id = ?
         AND path LIKE '%/admin/games/kdjx/gm/%'`,
      [adminId],
    ).count) >= 7);
    assert.equal(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE result = 'pending'`,
    ).count), 0);
  } finally {
    await app.close();
  }
});

test('KDJX GM releases stale delivery claims without retrying active claims', async () => {
  let retryCalls = 0;
  const app = await makeApp(async (userId, gameOrderId) => {
    retryCalls += 1;
    run(
      `UPDATE kdjx_payment_orders
       SET status = 'fulfilled', fulfillment_attempts = fulfillment_attempts + 1,
           fulfilled_at = datetime('now'), last_error = '',
           updated_at = datetime('now')
       WHERE user_id = ? AND game_order_id = ?`,
      [userId, gameOrderId],
    );
  });

  try {
    const adminId = seedUser({
      email: 'claim-admin@example.test',
      nickname: 'Claim Admin',
      role: 'admin',
    });
    const playerId = seedUser({
      email: 'claim-player@example.test',
      nickname: 'Claim Player',
    });
    const adminToken = createSession(adminId);
    seedLink(playerId, {
      openId: 'sakura_claim_player',
      accountId: '64a000000000000000000021',
      roleId: '64a000000000000000000022',
      serverKey: 'game.cn_qd.3',
      cipher: 'claim-test-password-cipher',
    });
    seedPayment(playerId, {
      id: 'payment-stale-claim-id',
      gameOrderId: 'order-stale-claim',
      status: 'fulfilling',
      lastError: '',
    });
    seedPayment(playerId, {
      id: 'payment-fresh-claim-id',
      gameOrderId: 'order-fresh-claim',
      status: 'fulfilling',
      lastError: '',
    });
    run(
      `UPDATE kdjx_payment_orders
       SET updated_at = datetime('now', '-10 minutes')
       WHERE game_order_id = 'order-stale-claim'`,
      [],
    );

    const listed = await adminRequest(
      app,
      adminToken,
      'GET',
      `/admin/games/kdjx/gm/payments?userId=${playerId}`,
    );
    assert.equal(listed.statusCode, 200);
    const byOrderId = new Map(
      listed.json().payments.map((payment) => [payment.gameOrderId, payment]),
    );
    assert.equal(byOrderId.get('order-stale-claim').status, 'delivery_failed');
    assert.equal(byOrderId.get('order-stale-claim').canRetry, true);
    assert.equal(
      byOrderId.get('order-stale-claim').lastError,
      'stale_delivery_claim',
    );
    assert.equal(byOrderId.get('order-fresh-claim').status, 'fulfilling');
    assert.equal(byOrderId.get('order-fresh-claim').canRetry, false);

    const activeClaim = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-fresh-claim/retry',
      {
        reason: '验证活跃投递占用保护',
        expectedStatus: 'fulfilling',
        expectedAttempts: 0,
      },
    );
    assert.equal(activeClaim.statusCode, 400);
    assert.equal(activeClaim.json().error, 'status_invalid');
    assert.equal(retryCalls, 0);

    const recovered = await adminRequest(
      app,
      adminToken,
      'POST',
      '/admin/games/kdjx/gm/payments/order-stale-claim/retry',
      {
        reason: '恢复超时投递占用',
        expectedStatus: 'delivery_failed',
        expectedAttempts: 0,
      },
    );
    assert.equal(recovered.statusCode, 200);
    assert.equal(recovered.json().payment.status, 'fulfilled');
    assert.equal(retryCalls, 1);
    assert.equal(Number(one(
      `SELECT COUNT(*) AS count FROM kdjx_gm_action_logs
       WHERE result = 'pending'`,
    ).count), 0);
  } finally {
    await app.close();
  }
});

async function makeApp(retryPayment) {
  const app = Fastify({ logger: false });
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error: error.publicCode || (status >= 500 ? 'internal_error' : error.message),
    });
  });
  app.addHook('onResponse', async (request, reply) => {
    recordAdminAudit(request, reply);
  });
  app.decorate('adminRequired', adminRequired);
  app.register(adminKdjxGmRoutes, { retryPayment });
  await app.ready();
  return app;
}

function seedUser({
  email,
  nickname,
  role = 'user',
  status = 'active',
  coins = 0,
}) {
  return Number(run(
    `INSERT INTO users
      (email, nickname, password_hash, role, status, sakura_coins)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      email,
      nickname,
      hashPassword('test-password'),
      role,
      status,
      coins,
    ],
  ).lastInsertRowid);
}

function seedLink(userId, {
  openId,
  accountId,
  roleId,
  serverKey,
  cipher,
}) {
  run(
    `INSERT INTO kdjx_game_account_links
      (novel_user_id, game_open_id, account_password_cipher,
       game_account_id, last_role_id, last_server_key)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [userId, openId, cipher, accountId, roleId, serverKey],
  );
}

function seedSession(userId, id, tokenHash, status) {
  const expiresAt = status === 'expired'
    ? '2020-01-01T00:00:00.000Z'
    : '2099-01-01T00:00:00.000Z';
  run(
    `INSERT INTO kdjx_game_sessions
      (id, token_hash, user_id, game_open_id, expires_at, revoked_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      id,
      tokenHash,
      userId,
      `sakura_test_${userId}`,
      expiresAt,
      status === 'revoked' ? '2025-01-01T00:00:00.000Z' : null,
    ],
  );
}

function seedPayment(userId, {
  id,
  gameOrderId,
  status,
  lastError,
}) {
  const suffix = String(userId).padStart(2, '0');
  run(
    `INSERT INTO kdjx_payment_orders
      (id, game_order_id, channel_order_id, user_id, game_open_id,
       account_id, role_id, server_key, product_id, product_name,
       recharge_id, money_cents, coin_cost, idempotency_key, status,
       fulfillment_reference, last_error, fulfilled_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, '9', '6 yuan recharge',
             9, 600, 60, ?, ?, ?, ?, ?)`,
    [
      id,
      gameOrderId,
      `sakura_${gameOrderId}`,
      userId,
      `sakura_test_${userId}`,
      `64a0000000000000000000${suffix}`,
      `64b0000000000000000000${suffix}`,
      `game.cn_qd.${userId}`,
      `idempotency-${gameOrderId}`,
      status,
      status === 'fulfilled' ? '64a000000000000000000088' : '',
      lastError,
      status === 'fulfilled' ? '2026-07-01T00:00:00.000Z' : null,
    ],
  );
}

function activeSessionCount(userId) {
  return Number(one(
    `SELECT COUNT(*) AS count FROM kdjx_game_sessions
     WHERE user_id = ? AND revoked_at IS NULL
       AND datetime(expires_at) > datetime('now')`,
    [userId],
  ).count);
}

function adminRequest(app, token, method, url, payload) {
  return app.inject({
    method,
    url,
    headers: { authorization: `Bearer ${token}` },
    ...(payload ? { payload } : {}),
  });
}

function assertRedacted(body) {
  for (const marker of [
    'never-return-account-password-cipher',
    'second-never-return-cipher',
    'token-hash-one',
    'token-hash-two',
    'token-hash-revoked',
    'token-hash-expired',
  ]) {
    assert.equal(body.includes(marker), false, `response leaked ${marker}`);
  }
  assert.doesNotMatch(body, /accountPassword|tokenHash|passwordCipher|sharedSecret/i);
}
