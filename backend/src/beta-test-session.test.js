import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import { authRequired } from './auth.js';
import { config } from './config.js';
import { migrate } from './db.js';
import { authRoutes } from './routes-auth.js';

test('beta test session is isolated behind local non-production gates', async (t) => {
  const originalEnabled = config.allowBetaTestSession;
  const originalEnvironment = config.nodeEnvironment;
  migrate();
  const app = Fastify();
  app.decorate('authRequired', authRequired);
  app.register(authRoutes);
  await app.ready();

  t.after(async () => {
    config.allowBetaTestSession = originalEnabled;
    config.nodeEnvironment = originalEnvironment;
    await app.close();
  });

  config.nodeEnvironment = 'test';
  config.allowBetaTestSession = false;
  assert.equal((await bootstrap(app)).statusCode, 404);

  config.allowBetaTestSession = true;
  assert.equal(
    (
      await app.inject({
        method: 'POST',
        url: '/auth/beta-session',
        remoteAddress: '192.168.1.22',
      })
    ).statusCode,
    404,
  );
  assert.equal(
    (
      await bootstrap(app, {
        remoteAddress: '203.0.113.22',
      })
    ).statusCode,
    404,
  );

  const first = await bootstrap(app);
  assert.equal(first.statusCode, 200, first.body);
  const firstBody = first.json();
  assert.equal(firstBody.user.email, 'reader-beta-session@local.invalid');
  assert.equal(firstBody.user.nickname, 'Sakura Beta 测试员');
  assert.equal(typeof firstBody.token, 'string');
  assert.ok(firstBody.token.length > 20);
  assert.equal('password_hash' in firstBody.user, false);

  const me = await app.inject({
    method: 'GET',
    url: '/auth/me',
    headers: { authorization: `Bearer ${firstBody.token}` },
  });
  assert.equal(me.statusCode, 200);
  assert.equal(me.json().user.id, firstBody.user.id);

  const second = await bootstrap(app, { remoteAddress: '10.0.2.15' });
  assert.equal(second.statusCode, 200);
  assert.equal(second.json().user.id, firstBody.user.id);
  assert.notEqual(second.json().token, firstBody.token);

  config.nodeEnvironment = 'production';
  assert.equal((await bootstrap(app)).statusCode, 404);
});

function bootstrap(app, { remoteAddress = '192.168.1.22' } = {}) {
  return app.inject({
    method: 'POST',
    url: '/auth/beta-session',
    remoteAddress,
    headers: { 'x-sakura-reader-beta': '1' },
  });
}
