import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-bailian-sso-'));
process.env.DB_PATH = path.join(tempDir, 'bailian-sso.sqlite');
process.env.TOKEN_SECRET = 'bailian-sso-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'bailian-sso-test-settings-secret';
process.env.ADMIN_USERNAME = 'bailian-sso-test-admin';
process.env.ADMIN_PASSWORD = 'bailian-sso-test-admin-password';
process.env.BAILIAN_LAUNCH_URL = 'https://game.example.test/bailian/';
process.env.BAILIAN_SSO_SHARED_SECRET = 'bailian-sso-test-shared-secret';
process.env.BAILIAN_SSO_TTL_SECONDS = '600';

const Fastify = (await import('fastify')).default;
const { authRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { gameRoutes } = await import('./routes-game.js');
const { hashPassword, hashToken } = await import('./security.js');

test('Bailian SSO tickets are authenticated, bounded, and account-bound', async () => {
  migrate();
  const userId = Number(run(
    `INSERT INTO users (email, nickname, password_hash)
     VALUES (?, ?, ?)`,
    ['bailian@example.test', 'bailian-user', hashPassword('test-password')],
  ).lastInsertRowid);
  const bearer = createSession(userId);

  const app = Fastify({ logger: false });
  app.decorate('authRequired', authRequired);
  app.register(gameRoutes);
  await app.ready();

  try {
    const anonymous = await app.inject({
      method: 'POST',
      url: '/games/bailian/sso-ticket',
    });
    assert.equal(anonymous.statusCode, 401);

    const issued = await issue(app, bearer);
    assert.equal(issued.statusCode, 200);
    assert.equal(issued.headers['cache-control'], 'no-store');
    const payload = issued.json();
    assert.equal(payload.expiresIn, 600);
    assert.ok(payload.ticket.length >= 40);
    assert.equal(new URL(payload.launchUrl).searchParams.get('ticket'), payload.ticket);
    assert.equal(new URL(payload.launchUrl).searchParams.get('openId'), `novel_${userId}`);
    assert.equal(new URL(payload.launchUrl).searchParams.get('online'), '1');
    assert.equal(
      one('SELECT ticket_hash FROM game_sso_tickets').ticket_hash,
      hashToken(payload.ticket),
    );
    assert.notEqual(one('SELECT ticket_hash FROM game_sso_tickets').ticket_hash, payload.ticket);

    const wrongSecret = await consume(app, payload.ticket, 'wrong-secret');
    assert.equal(wrongSecret.statusCode, 401);
    assert.equal(one('SELECT consumed_at FROM game_sso_tickets').consumed_at, null);

    const wrongOpenId = await consume(
      app,
      payload.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
      'novel_other-user',
    );
    assert.equal(wrongOpenId.statusCode, 401);
    assert.equal(one('SELECT consumed_at FROM game_sso_tickets').consumed_at, null);

    const consumed = await consume(
      app,
      payload.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
      `novel_${userId}`,
    );
    assert.equal(consumed.statusCode, 200);
    assert.deepEqual(consumed.json(), {
      ok: true,
      userId: String(userId),
      gameOpenId: `novel_${userId}`,
      expiresAt: payload.expiresAt,
    });

    const reconnect = await consume(
      app,
      payload.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
      `novel_${userId}`,
    );
    assert.equal(reconnect.statusCode, 200);
    assert.deepEqual(reconnect.json(), consumed.json());

    const wrongReconnect = await consume(
      app,
      payload.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
      'novel_other-user',
    );
    assert.equal(wrongReconnect.statusCode, 401);
    assert.equal(wrongReconnect.json().error, 'invalid_or_expired_ticket');

    const replayWithoutOpenId = await consume(
      app,
      payload.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
    );
    assert.equal(replayWithoutOpenId.statusCode, 401);
    assert.equal(replayWithoutOpenId.json().error, 'invalid_or_expired_ticket');

    const second = (await issue(app, bearer)).json();
    assert.equal(
      one('SELECT game_open_id FROM game_account_links WHERE novel_user_id = ?', [userId])
        .game_open_id,
      `novel_${userId}`,
    );
    run(
      "UPDATE game_sso_tickets SET expires_at = datetime('now', '-1 second') WHERE ticket_hash = ?",
      [hashToken(second.ticket)],
    );
    const expired = await consume(
      app,
      second.ticket,
      process.env.BAILIAN_SSO_SHARED_SECRET,
      `novel_${userId}`,
    );
    assert.equal(expired.statusCode, 401);
  } finally {
    await app.close();
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function issue(app, bearer) {
  return app.inject({
    method: 'POST',
    url: '/games/bailian/sso-ticket',
    headers: { authorization: `Bearer ${bearer}` },
  });
}

function consume(app, ticket, secret, openId) {
  return app.inject({
    method: 'POST',
    url: '/games/bailian/sso-ticket/consume',
    headers: { 'x-bailian-sso-secret': secret },
    payload: { ticket, ...(openId ? { openId } : {}) },
  });
}
