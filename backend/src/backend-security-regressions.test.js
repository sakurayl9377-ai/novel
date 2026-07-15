import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-backend-security-'));
process.env.DB_PATH = path.join(tempDir, 'security-regressions.sqlite');
process.env.TOKEN_SECRET = 'security-regressions-token-secret';
process.env.ADMIN_USERNAME = 'security-regressions-admin';
process.env.ADMIN_PASSWORD = 'security-regressions-admin-password';
process.env.ALLOW_DEV_AUTH_CODES = 'true';
process.env.SMTP_HOST = '';
process.env.SMTP_USER = '';
process.env.SMTP_PASS = '';

const Fastify = (await import('fastify')).default;
const {
  adminRequired,
  authOptional,
  authRequired,
  createSession,
  findUserByToken,
} = await import('./auth.js');
const { config } = await import('./config.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { ingestContentBehavior } = await import('./growth-operations.js');
const {
  clearRateLimitsForTests,
  consumeRateLimit,
  rateLimitBucketCountForTests,
} = await import('./rate-limit.js');
const { authRoutes } = await import('./routes-auth.js');
const { telemetryRoutes } = await import('./routes-telemetry.js');
const { userRoutes } = await import('./routes-user.js');
const {
  hashCode,
  hashToken,
  privateUser,
  publicUser,
} = await import('./security.js');

test('backend security regressions', async (t) => {
  config.rootDir = tempDir;
  migrate();

  const activeUser = insertUser({
    email: 'active@example.test',
    nickname: 'active-user',
  });
  const bannedAdmin = insertUser({
    email: 'banned-admin@example.test',
    nickname: 'banned-admin',
    role: 'admin',
    status: 'banned',
  });

  const app = Fastify({ logger: false });
  app.decorate('authOptional', authOptional);
  app.decorate('authRequired', authRequired);
  app.decorate('adminRequired', adminRequired);
  app.register(authRoutes);
  app.register(telemetryRoutes);
  app.register(userRoutes);
  app.get(
    '/admin-security-probe',
    { preHandler: app.adminRequired },
    async () => ({ ok: true }),
  );
  app.setErrorHandler((error, _request, reply) => {
    const status = error.statusCode || 500;
    reply.code(status).send({
      error:
        error.publicCode ||
        (status >= 500 ? 'internal_error' : error.message),
    });
  });

  try {
    await app.ready();

    await t.test('public users omit email while authenticated users retain it', async () => {
      const publicPayload = publicUser(activeUser);
      assert.equal(Object.hasOwn(publicPayload, 'email'), false);
      assert.equal(privateUser(activeUser).email, activeUser.email);

      const token = createSession(activeUser.id);
      const response = await app.inject({
        method: 'GET',
        url: '/auth/me',
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(response.statusCode, 200);
      assert.equal(response.json().user.email, activeUser.email);
    });

    await t.test('self profile keeps private account fields while public profile omits them', async () => {
      run('UPDATE users SET points = 1234, sakura_coins = 567 WHERE id = ?', [activeUser.id]);
      const token = createSession(activeUser.id);
      const selfResponse = await app.inject({
        method: 'GET',
        url: '/users/me/profile',
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(selfResponse.statusCode, 200);
      const selfProfile = selfResponse.json();
      assert.equal(selfProfile.user.email, activeUser.email);
      assert.equal(selfProfile.user.growth.sakuraCoins, 567);
      assert.equal(Object.hasOwn(selfProfile, 'inventory'), true);
      assert.equal(Object.hasOwn(selfProfile, 'recentRewards'), true);

      const publicResponse = await app.inject({
        method: 'GET',
        url: `/users/${activeUser.id}/profile`,
      });
      assert.equal(publicResponse.statusCode, 200);
      const publicProfile = publicResponse.json();
      assert.equal(Object.hasOwn(publicProfile.user, 'email'), false);
      assert.equal(Object.hasOwn(publicProfile.user.growth, 'sakuraCoins'), false);
      for (const field of ['inventory', 'recentRewards', 'dailyRewards', 'dailyCaps']) {
        assert.equal(Object.hasOwn(publicProfile, field), false);
      }
    });

    await t.test('expired ISO bearer tokens are rejected', async () => {
      const token = 'expired-iso-token';
      run(
        `INSERT INTO auth_tokens (user_id, token_hash, expires_at)
         VALUES (?, ?, ?)`,
        [activeUser.id, hashToken(token), expiredIsoTimestamp()],
      );

      assert.equal(findUserByToken(token), null);
      const response = await app.inject({
        method: 'GET',
        url: '/auth/me',
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(response.statusCode, 401);
      assert.equal(response.json().error, 'unauthorized');
    });

    await t.test('banned administrators cannot use admin routes', async () => {
      const token = createSession(bannedAdmin.id);
      const response = await app.inject({
        method: 'GET',
        url: '/admin-security-probe',
        headers: { authorization: `Bearer ${token}` },
      });
      assert.equal(response.statusCode, 403);
      assert.equal(response.json().error, 'account_banned');
    });

    await t.test('expired ISO image captchas are rejected', async () => {
      clearRateLimitsForTests();
      const captchaResponse = await app.inject({
        method: 'GET',
        url: '/auth/captcha',
      });
      assert.equal(captchaResponse.statusCode, 200);
      const captcha = captchaResponse.json();
      assert.ok(captcha.captchaId);
      assert.ok(captcha.devAnswer);
      run('UPDATE image_captchas SET expires_at = ? WHERE id = ?', [
        expiredIsoTimestamp(),
        captcha.captchaId,
      ]);

      const response = await app.inject({
        method: 'POST',
        url: '/auth/email-code',
        payload: {
          email: 'captcha-expiry@example.test',
          purpose: 'register',
          captchaId: captcha.captchaId,
          captchaCode: captcha.devAnswer,
        },
      });
      assert.equal(response.statusCode, 400);
      assert.equal(response.json().error, 'captcha invalid');
    });

    await t.test('expired ISO email verification codes are rejected', async () => {
      clearRateLimitsForTests();
      const email = 'email-code-expiry@example.test';
      const code = '123456';
      run(
        `INSERT INTO email_verifications
         (email, code_hash, purpose, ip, expires_at)
         VALUES (?, ?, 'register', '127.0.0.1', ?)`,
        [email, hashCode(code, `email:${email}:register`), expiredIsoTimestamp()],
      );

      const response = await app.inject({
        method: 'POST',
        url: '/auth/register',
        payload: {
          email,
          password: 'valid-test-password',
          nickname: 'expired-code-user',
          emailCode: code,
        },
      });
      assert.equal(response.statusCode, 400);
      assert.equal(response.json().error, 'email code invalid');
      assert.equal(Boolean(one('SELECT id FROM users WHERE email = ?', [email])), false);
    });

    await t.test('anonymous behavior events cannot impersonate body.userId', () => {
      run(
        `INSERT INTO content_catalog
         (content_type, stable_key, source_key, source_item_id, title)
         VALUES ('novel', 'security:behavior', 'security-test', 'behavior', 'Security Test')`,
      );
      const result = ingestContentBehavior({
        request: { user: null, ip: '127.0.0.1' },
        skipRateLimit: true,
        body: {
          eventId: 'security-behavior-impersonation',
          event: 'start',
          source: 'reader',
          contentKey: 'security:behavior',
          installId: 'security-test-install',
          userId: activeUser.id,
        },
      });
      assert.equal(result.accepted, true);
      const stored = one(
        'SELECT user_id, actor_key FROM content_behavior_events WHERE event_id = ?',
        ['security-behavior-impersonation'],
      );
      assert.equal(stored.user_id, null);
      assert.match(stored.actor_key, /^install:/);
    });

    await t.test('one install is limited without penalizing other devices immediately', async () => {
      clearRateLimitsForTests();
      for (let index = 0; index < 20; index += 1) {
        const response = await telemetryRequest(app, 'fixed-install', index);
        assert.equal(response.statusCode, 200);
      }
      const limited = await telemetryRequest(app, 'fixed-install', 20);
      assert.equal(limited.statusCode, 429);
      assert.equal(limited.json().error, 'telemetry_rate_limited');

      const otherDevice = await telemetryRequest(app, 'other-install', 21);
      assert.equal(otherDevice.statusCode, 200);
    });

    await t.test('rotating installId cannot bypass the higher telemetry IP limit', async () => {
      clearRateLimitsForTests();
      for (let index = 0; index < 300; index += 1) {
        const response = await telemetryRequest(app, `rotating-install-${index}`, index);
        assert.equal(response.statusCode, 200);
      }
      const limited = await telemetryRequest(app, 'rotating-install-limited', 300);
      assert.equal(limited.statusCode, 429);
      assert.equal(limited.json().error, 'telemetry_rate_limited');

      const bucketCountAtLimit = rateLimitBucketCountForTests();
      for (let index = 301; index < 1301; index += 1) {
        const rejected = await telemetryRequest(app, `post-limit-${index}`, index);
        assert.equal(rejected.statusCode, 429);
      }
      assert.equal(
        rateLimitBucketCountForTests(),
        bucketCountAtLimit,
        'IP rejection must happen before a rotated install can allocate a bucket',
      );
    });

    await t.test('shared rate-limit storage stays bounded under key rotation', () => {
      clearRateLimitsForTests();
      assert.equal(
        consumeRateLimit({
          scope: 'bounded-regression',
          key: 'oldest',
          limit: 1,
          windowMs: 60000,
          now: 1000,
        }).limited,
        false,
      );
      for (let index = 0; index < 20000; index += 1) {
        consumeRateLimit({
          scope: 'bounded-regression',
          key: `rotated-${index}`,
          limit: 1,
          windowMs: 60000,
          now: 1000,
        });
      }
      assert.equal(
        consumeRateLimit({
          scope: 'bounded-regression',
          key: 'oldest',
          limit: 1,
          windowMs: 60000,
          now: 1000,
        }).limited,
        false,
        'the oldest bucket should have been evicted at the fixed capacity',
      );
    });
  } finally {
    await app.close();
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function insertUser({ email, nickname, role = 'user', status = 'active' }) {
  const result = run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, 'unused-test-password-hash', ?, ?)`,
    [email, nickname, role, status],
  );
  return one('SELECT * FROM users WHERE id = ?', [result.lastInsertRowid]);
}

function expiredIsoTimestamp() {
  return new Date(Date.now() - 60 * 1000).toISOString();
}

function telemetryRequest(app, installId, index) {
  return app.inject({
    method: 'POST',
    url: '/app/telemetry/batch',
    payload: {
      installId,
      sessionId: `rotating-session-${index}`,
      events: [],
      errors: [],
    },
  });
}
