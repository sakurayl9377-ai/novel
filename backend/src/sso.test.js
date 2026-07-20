import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import { createSession } from './auth.js';
import { authRequired } from './auth.js';
import { all, db, migrate, one, run } from './db.js';
import { grantReward } from './rewards.js';
import { authRoutes } from './routes-auth.js';
import { hashCode, hashPassword, minutesFromNow } from './security.js';
import {
  createSsoClient,
  pkceChallenge,
  setSsoClientStatus,
} from './sso.js';

test('game SSO keeps profile and Sakura Coin state consistent', async (t) => {
  migrate();
  migrate();
  assert.deepEqual(all('PRAGMA foreign_key_check'), []);

  const userEmail = `sso-user-${process.pid}@example.com`;
  const userId = Number(
    run(
      `INSERT INTO users
       (email, nickname, avatar_url, password_hash, sakura_coins, status)
       VALUES (?, ?, ?, ?, 1000, 'active')`,
      [
        userEmail,
        'Game Reader',
        '/api/uploads/profile/avatars/game-reader.png',
        hashPassword('sso-test-password'),
      ],
    ).lastInsertRowid,
  );
  const appToken = createSession(userId);
  const secondUserId = Number(
    run(
      `INSERT INTO users
       (email, nickname, password_hash, sakura_coins, status)
       VALUES (?, 'Second Game Reader', ?, 0, 'active')`,
      [
        `sso-second-user-${process.pid}@example.com`,
        hashPassword('second-user-password'),
      ],
    ).lastInsertRowid,
  );
  const secondAppToken = createSession(secondUserId);
  const rewardIsolationUserId = Number(
    run(
      `INSERT INTO users
       (email, nickname, password_hash, sakura_coins, status)
       VALUES (?, 'Reward Isolation', ?, 300, 'active')`,
      [
        `sso-reward-isolation-${process.pid}@example.com`,
        hashPassword('reward-isolation-password'),
      ],
    ).lastInsertRowid,
  );
  run(
    `INSERT INTO user_reward_events
     (user_id, action, coins_delta, description, related_type)
     VALUES (?, 'sso_wallet_credit', 300, 'game refund', 'sso_wallet')`,
    [rewardIsolationUserId],
  );
  assert.equal(
    grantReward(rewardIsolationUserId, 'daily_signin').coins,
    500,
  );
  assert.equal(
    one('SELECT sakura_coins FROM users WHERE id = ?', [rewardIsolationUserId])
      .sakura_coins,
    800,
  );
  const hkBoundaryUserId = Number(
    run(
      `INSERT INTO users
       (email, nickname, password_hash, sakura_coins, status)
       VALUES (?, 'HK Boundary', ?, 500, 'active')`,
      [
        `sso-hk-boundary-${process.pid}@example.com`,
        hashPassword('hk-boundary-password'),
      ],
    ).lastInsertRowid,
  );
  run(
    `INSERT INTO user_reward_events
     (user_id, action, points_delta, coins_delta, description, created_at)
     VALUES (?, 'daily_signin', 20, 500, 'HK day boundary',
             datetime('now', '+8 hours', 'start of day', '-8 hours', '+1 minute'))`,
    [hkBoundaryUserId],
  );
  const hkBoundaryEvent = one(
    `SELECT created_at,
            date(created_at) AS utc_day,
            date(created_at, '+8 hours') AS hk_day
     FROM user_reward_events
     WHERE user_id = ?`,
    [hkBoundaryUserId],
  );
  assert.notEqual(hkBoundaryEvent.utc_day, hkBoundaryEvent.hk_day);
  assert.equal(grantReward(hkBoundaryUserId, 'daily_signin'), null);

  const redirectUri = 'sakura-game://sso/callback';
  const defaultClient = createSsoClient({
    clientId: 'sakura-read-only-default',
    name: 'Sakura Read Only Default',
    redirectUris: ['sakura-read-only://sso/callback'],
  });
  assert.deepEqual(defaultClient.client.scopes, [
    'profile:read',
    'wallet:read',
  ]);
  assert.equal(defaultClient.client.limits.maxDebitPerTransaction, 0);
  assert.equal(defaultClient.client.limits.dailyDebitLimit, 0);
  assert.throws(
    () =>
      createSsoClient({
        clientId: 'sakura-unsafe-debit-default',
        name: 'Unsafe Debit Default',
        scopes: ['profile:read', 'wallet:debit'],
        redirectUris: ['sakura-unsafe://sso/callback'],
      }),
    (error) => error?.publicCode === 'sso_debit_limit_required',
  );
  const provisioned = createSsoClient({
    clientId: 'sakura-game-test',
    name: 'Sakura Game Test',
    scopes: [
      'profile:read',
      'wallet:read',
      'wallet:debit',
      'wallet:credit',
    ],
    redirectUris: [redirectUri],
    maxDebitPerTransaction: 5000,
    dailyDebitLimit: 10000,
    maxCreditPerTransaction: 5000,
    dailyCreditLimit: 600,
  });
  assert.equal('secret_hash' in provisioned.client, false);
  assert.ok(provisioned.clientSecret.length >= 40);

  const app = Fastify();
  app.setErrorHandler((error, _request, reply) => {
    reply
      .code(error.statusCode || 500)
      .send({ error: error.publicCode || error.message });
  });
  app.decorate('authRequired', authRequired);
  await app.register(authRoutes);
  await app.ready();
  t.after(() => app.close());

  const verifier = 'sso-verifier-'.padEnd(43, 'v');
  const state = 'sso-state-1234567890';
  const authorization = await authorize(app, {
    appToken,
    redirectUri,
    verifier,
    state,
    scope: 'profile:read wallet:read wallet:debit wallet:credit',
  });
  assert.equal(authorization.statusCode, 200, authorization.body);
  assert.equal(authorization.json().state, state);
  assert.equal(authorization.json().redirect_uri, redirectUri);
  assert.equal(
    one('SELECT code_hash FROM sso_authorization_codes')?.code_hash ===
      authorization.json().code,
    false,
  );
  const parallelAuthorization = await authorize(app, {
    appToken,
    redirectUri,
    verifier,
    state: 'parallel-state-12345678',
    scope: 'profile:read',
  });
  assert.equal(parallelAuthorization.statusCode, 200, parallelAuthorization.body);
  assert.equal(
    one(
      `SELECT COUNT(*) AS count
       FROM sso_authorization_codes
       WHERE client_id = ? AND user_id = ? AND used_at IS NULL`,
      ['sakura-game-test', userId],
    ).count,
    2,
  );

  const wrongRedirect = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: authorization.json().code,
    verifier,
    redirectUri: 'sakura-game://sso/other',
  });
  assert.equal(wrongRedirect.statusCode, 400);
  assert.equal(wrongRedirect.json().error, 'invalid_grant');

  const exchanged = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: authorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(exchanged.statusCode, 200, exchanged.body);
  const tokens = exchanged.json();
  assert.equal(tokens.token_type, 'Bearer');
  assert.ok(tokens.access_token.length >= 40);
  assert.ok(tokens.refresh_token.length >= 40);
  assert.equal(tokens.user.nickname, 'Game Reader');
  assert.equal(tokens.user.sakuraCoins, 1000);
  assert.equal('email' in tokens.user, false);
  const subject = tokens.user.sub;

  const replayedCode = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: authorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(replayedCode.statusCode, 400);
  assert.equal(replayedCode.json().error, 'invalid_grant');

  const reward = grantReward(userId, 'daily_signin', {
    type: 'user',
    id: String(userId),
  });
  assert.equal(reward.coins, 500);
  assert.equal(grantReward(userId, 'daily_signin'), null);

  const walletAfterSignin = await bearerRequest(
    app,
    'GET',
    '/sso/wallet',
    tokens.access_token,
  );
  assert.equal(walletAfterSignin.statusCode, 200, walletAfterSignin.body);
  assert.equal(walletAfterSignin.json().wallet.balance, 1500);
  assert.ok(walletAfterSignin.json().wallet.version > 0);

  const changes = await bearerRequest(
    app,
    'GET',
    '/sso/wallet/changes?after_id=0',
    tokens.access_token,
  );
  assert.equal(changes.statusCode, 200, changes.body);
  assert.equal(changes.json().wallet.balance, 1500);
  assert.deepEqual(
    changes.json().items.map((item) => [item.direction, item.delta]),
    [['credit', 500]],
  );
  assert.equal('action' in changes.json().items[0], false);

  run(
    `UPDATE users
     SET nickname = ?, avatar_url = ?, updated_at = datetime('now')
     WHERE id = ?`,
    ['Updated Reader', 'https://cdn.example/avatar.png', userId],
  );
  const userInfo = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    tokens.access_token,
  );
  assert.equal(userInfo.statusCode, 200, userInfo.body);
  assert.equal(userInfo.json().user.nickname, 'Updated Reader');
  assert.equal(userInfo.json().user.avatarUrl, 'https://cdn.example/avatar.png');
  assert.equal(userInfo.json().user.sakuraCoins, 1500);

  const debit = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'gacha-order-0001',
    delta: -300,
    reason: 'ten pull',
    referenceId: 'gacha-0001',
  });
  assert.equal(debit.statusCode, 200, debit.body);
  assert.equal(debit.json().replayed, false);
  assert.equal(debit.json().transaction.balanceBefore, 1500);
  assert.equal(debit.json().transaction.balanceAfter, 1200);

  const debitReplay = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'gacha-order-0001',
    delta: -300,
    reason: 'ten pull',
    referenceId: 'gacha-0001',
  });
  assert.equal(debitReplay.statusCode, 200, debitReplay.body);
  assert.equal(debitReplay.json().replayed, true);
  assert.equal(one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins, 1200);
  assert.equal(
    one(
      `SELECT COUNT(*) AS count FROM sso_wallet_transactions
       WHERE client_id = ? AND idempotency_key = ?`,
      ['sakura-game-test', 'gacha-order-0001'],
    ).count,
    1,
  );

  const conflictingReplay = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'gacha-order-0001',
    delta: -301,
    reason: 'ten pull',
    referenceId: 'gacha-0001',
  });
  assert.equal(conflictingReplay.statusCode, 409);
  assert.equal(conflictingReplay.json().error, 'idempotency_conflict');

  const insufficient = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'gacha-order-0002',
    delta: -2000,
    reason: 'overspend',
  });
  assert.equal(insufficient.statusCode, 409);
  assert.equal(insufficient.json().error, 'insufficient_sakura_coins');
  assert.equal(one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins, 1200);
  assert.equal(
    one(
      `SELECT COUNT(*) AS count FROM sso_wallet_transactions
       WHERE idempotency_key = 'gacha-order-0002'`,
    ).count,
    0,
  );

  const credit = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'refund-order-0001',
    delta: 300,
    reason: 'failed gacha refund',
    referenceId: 'gacha-0001',
  });
  assert.equal(credit.statusCode, 200, credit.body);
  assert.equal(credit.json().transaction.balanceAfter, 1500);
  const receipt = one(
    `SELECT transaction_row.reward_event_id, reward.coins_delta
     FROM sso_wallet_transactions transaction_row
     JOIN user_reward_events reward ON reward.id = transaction_row.reward_event_id
     WHERE transaction_row.id = ?`,
    [credit.json().transaction.id],
  );
  assert.equal(receipt.coins_delta, 300);

  const secondAuthorization = await authorize(app, {
    appToken: secondAppToken,
    redirectUri,
    verifier,
    state: 'second-user-state-12345',
    scope: 'wallet:read wallet:credit',
  });
  const secondExchange = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: secondAuthorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(secondExchange.statusCode, 200, secondExchange.body);
  const secondCredit = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: secondExchange.json().access_token,
    idempotencyKey: 'second-user-credit-0001',
    delta: 300,
    reason: 'second user reward',
  });
  assert.equal(secondCredit.statusCode, 200, secondCredit.body);
  const globalCreditLimit = await walletChange(app, {
    clientSecret: provisioned.clientSecret,
    accessToken: tokens.access_token,
    idempotencyKey: 'global-credit-limit-0001',
    delta: 1,
    reason: 'must exceed client daily issuance limit',
  });
  assert.equal(globalCreditLimit.statusCode, 409);
  assert.equal(
    globalCreditLimit.json().error,
    'wallet_daily_limit_exceeded',
  );
  assert.equal(
    one('SELECT sakura_coins FROM users WHERE id = ?', [secondUserId])
      .sakura_coins,
    300,
  );

  const balanceBeforeRollback = one(
    'SELECT sakura_coins FROM users WHERE id = ?',
    [userId],
  ).sakura_coins;
  db.exec(`
    CREATE TEMP TRIGGER sso_test_reward_event_failure
    BEFORE INSERT ON user_reward_events
    WHEN NEW.related_id = 'sakura-game-test:rollback-order-0001'
    BEGIN
      SELECT RAISE(ABORT, 'forced_reward_event_failure');
    END;
  `);
  try {
    const rolledBack = await walletChange(app, {
      clientSecret: provisioned.clientSecret,
      accessToken: tokens.access_token,
      idempotencyKey: 'rollback-order-0001',
      delta: -100,
      reason: 'transaction rollback test',
    });
    assert.equal(rolledBack.statusCode, 500, rolledBack.body);
  } finally {
    db.exec('DROP TRIGGER IF EXISTS sso_test_reward_event_failure');
  }
  assert.equal(
    one('SELECT sakura_coins FROM users WHERE id = ?', [userId]).sakura_coins,
    balanceBeforeRollback,
  );
  assert.equal(
    one(
      `SELECT COUNT(*) AS count
       FROM user_reward_events
       WHERE related_id = 'sakura-game-test:rollback-order-0001'`,
    ).count,
    0,
  );
  assert.equal(
    one(
      `SELECT COUNT(*) AS count
       FROM sso_wallet_transactions
       WHERE idempotency_key = 'rollback-order-0001'`,
    ).count,
    0,
  );

  const originalRefreshRow = one(
    `SELECT family_id, expires_at
     FROM sso_refresh_tokens
     WHERE user_id = ? AND client_id = ? AND revoked_at IS NULL`,
    [userId, 'sakura-game-test'],
  );
  const refreshed = await refresh(app, {
    clientSecret: provisioned.clientSecret,
    refreshToken: tokens.refresh_token,
  });
  assert.equal(refreshed.statusCode, 200, refreshed.body);
  assert.notEqual(refreshed.json().refresh_token, tokens.refresh_token);
  assert.equal(refreshed.json().user.sub, subject);
  assert.ok(refreshed.json().refresh_expires_in <= tokens.refresh_expires_in);
  const rotatedRefreshRow = one(
    `SELECT family_id, expires_at
     FROM sso_refresh_tokens
     WHERE user_id = ? AND client_id = ? AND revoked_at IS NULL`,
    [userId, 'sakura-game-test'],
  );
  assert.equal(rotatedRefreshRow.family_id, originalRefreshRow.family_id);
  assert.equal(rotatedRefreshRow.expires_at, originalRefreshRow.expires_at);

  const profileOnlyAuthorization = await authorize(app, {
    appToken,
    redirectUri,
    verifier,
    state: 'profile-state-1234567',
    scope: 'profile:read',
  });
  const profileOnlyExchange = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: profileOnlyAuthorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(profileOnlyExchange.statusCode, 200, profileOnlyExchange.body);
  const profileToken = profileOnlyExchange.json().access_token;
  assert.equal('sakuraCoins' in profileOnlyExchange.json().user, false);
  assert.equal(profileOnlyExchange.json().user.sub, subject);
  const profileOnlyInfo = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    profileToken,
  );
  assert.equal(profileOnlyInfo.statusCode, 200);
  assert.equal('sakuraCoins' in profileOnlyInfo.json().user, false);
  const profileOnlyWallet = await bearerRequest(
    app,
    'GET',
    '/sso/wallet',
    profileToken,
  );
  assert.equal(profileOnlyWallet.statusCode, 403);
  assert.equal(profileOnlyWallet.json().error, 'insufficient_scope');

  const reusedRefresh = await refresh(app, {
    clientSecret: provisioned.clientSecret,
    refreshToken: tokens.refresh_token,
  });
  assert.equal(reusedRefresh.statusCode, 400);
  assert.equal(reusedRefresh.json().error, 'invalid_grant');
  const revokedAfterReuse = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    refreshed.json().access_token,
  );
  assert.equal(revokedAfterReuse.statusCode, 401);

  const independentFamilyStillActive = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    profileToken,
  );
  assert.equal(
    independentFamilyStillActive.statusCode,
    200,
    independentFamilyStillActive.body,
  );

  const revokedFamily = await revoke(app, {
    clientSecret: provisioned.clientSecret,
    token: profileOnlyExchange.json().refresh_token,
  });
  assert.equal(revokedFamily.statusCode, 200, revokedFamily.body);
  const accessAfterFamilyRevoke = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    profileToken,
  );
  assert.equal(accessAfterFamilyRevoke.statusCode, 401);
  const refreshAfterFamilyRevoke = await refresh(app, {
    clientSecret: provisioned.clientSecret,
    refreshToken: profileOnlyExchange.json().refresh_token,
  });
  assert.equal(refreshAfterFamilyRevoke.statusCode, 400);

  const resetAuthorization = await authorize(app, {
    appToken,
    redirectUri,
    verifier,
    state: 'password-reset-state-123',
    scope: 'profile:read wallet:read',
  });
  const resetFamily = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: resetAuthorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(resetFamily.statusCode, 200, resetFamily.body);
  const resetCode = '654321';
  run(
    `INSERT INTO email_verifications
     (email, code_hash, purpose, ip, expires_at)
     VALUES (?, ?, 'reset_password', '127.0.0.1', ?)`,
    [
      userEmail,
      hashCode(resetCode, `email:${userEmail}:reset_password`),
      minutesFromNow(10),
    ],
  );
  const passwordReset = await app.inject({
    method: 'POST',
    url: '/auth/reset-password',
    payload: {
      email: userEmail,
      password: 'sso-reset-password-2',
      emailCode: resetCode,
    },
  });
  assert.equal(passwordReset.statusCode, 200, passwordReset.body);
  const oldAppSession = await bearerRequest(
    app,
    'GET',
    '/auth/me',
    appToken,
  );
  assert.equal(oldAppSession.statusCode, 401);
  const accessAfterPasswordReset = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    resetFamily.json().access_token,
  );
  assert.equal(accessAfterPasswordReset.statusCode, 401);
  const refreshAfterPasswordReset = await refresh(app, {
    clientSecret: provisioned.clientSecret,
    refreshToken: resetFamily.json().refresh_token,
  });
  assert.equal(refreshAfterPasswordReset.statusCode, 400);

  const postResetAuthorization = await authorize(app, {
    appToken: passwordReset.json().token,
    redirectUri,
    verifier,
    state: 'post-reset-state-123456',
    scope: 'profile:read',
  });
  const postResetFamily = await exchange(app, {
    clientSecret: provisioned.clientSecret,
    code: postResetAuthorization.json().code,
    verifier,
    redirectUri,
  });
  assert.equal(postResetFamily.statusCode, 200, postResetFamily.body);

  setSsoClientStatus('sakura-game-test', 'disabled');
  const disabledClient = await bearerRequest(
    app,
    'GET',
    '/sso/userinfo',
    postResetFamily.json().access_token,
  );
  assert.equal(disabledClient.statusCode, 401);
});

function authorize(
  app,
  { appToken, redirectUri, verifier, state, scope },
) {
  return app.inject({
    method: 'POST',
    url: '/sso/authorize',
    headers: { authorization: `Bearer ${appToken}` },
    payload: {
      client_id: 'sakura-game-test',
      redirect_uri: redirectUri,
      code_challenge: pkceChallenge(verifier),
      code_challenge_method: 'S256',
      state,
      scope,
    },
  });
}

function exchange(app, { clientSecret, code, verifier, redirectUri }) {
  return app.inject({
    method: 'POST',
    url: '/sso/token',
    headers: { authorization: basicAuthorization(clientSecret) },
    payload: {
      grant_type: 'authorization_code',
      code,
      code_verifier: verifier,
      redirect_uri: redirectUri,
    },
  });
}

function refresh(app, { clientSecret, refreshToken }) {
  return app.inject({
    method: 'POST',
    url: '/sso/token',
    headers: { authorization: basicAuthorization(clientSecret) },
    payload: {
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
    },
  });
}

function revoke(app, { clientSecret, token }) {
  return app.inject({
    method: 'POST',
    url: '/sso/revoke',
    headers: { authorization: basicAuthorization(clientSecret) },
    payload: { token },
  });
}

function walletChange(
  app,
  {
    clientSecret,
    accessToken,
    idempotencyKey,
    delta,
    reason,
    referenceId = '',
  },
) {
  return app.inject({
    method: 'POST',
    url: '/sso/wallet/transactions',
    headers: {
      authorization: basicAuthorization(clientSecret),
      'x-sakura-user-token': accessToken,
      'idempotency-key': idempotencyKey,
    },
    payload: {
      delta,
      reason,
      reference_id: referenceId,
      metadata: { test: true },
    },
  });
}

function bearerRequest(app, method, url, token) {
  return app.inject({
    method,
    url,
    headers: { authorization: `Bearer ${token}` },
  });
}

function basicAuthorization(clientSecret) {
  return `Basic ${Buffer.from(`sakura-game-test:${clientSecret}`).toString('base64')}`;
}
