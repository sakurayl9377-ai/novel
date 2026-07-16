import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-progress-sync-'));
process.env.DB_PATH = path.join(tempDir, 'progress-sync.sqlite');
process.env.TOKEN_SECRET = ['progress', 'sync', 'test', 'placeholder'].join('-');
process.env.SMTP_HOST = '';
process.env.SMTP_USER = '';
process.env.SMTP_PASS = '';

const Fastify = (await import('fastify')).default;
const { authRequired, createSession } = await import('./auth.js');
const { closeDb, migrate, one, run } = await import('./db.js');
const { userRoutes } = await import('./routes-user.js');

test('progress sync returns authoritative write results', async () => {
  migrate();
  const app = Fastify({ logger: false });
  app.decorate('authRequired', authRequired);
  app.register(userRoutes);
  app.setErrorHandler((error, _request, reply) => {
    reply.code(error.statusCode || 500).send({ error: error.message });
  });

  try {
    await app.ready();
    const inserted = run(
      `INSERT INTO users
         (email, nickname, password_hash, status)
       VALUES ('progress-sync@example.test', 'progress-sync', 'unused', 'active')`,
    );
    const user = one('SELECT * FROM users WHERE id = ?', [
      inserted.lastInsertRowid,
    ]);
    const token = createSession(user.id);
    const headers = { authorization: `Bearer ${token}` };
    const baseTime = Date.now() - 10_000;
    const contentKey = 'reader_settings:v1';

    const initial = await app.inject({
      method: 'POST',
      url: '/users/me/progress/sync',
      headers,
      payload: {
        deviceId: 'device-a',
        cursor: 0,
        items: [
          {
            contentType: 'novel',
            contentKey,
            sourceKey: 'reader_settings',
            itemId: 'v1',
            subItemId: 'settings',
            payload: { fontSize: 20 },
            metadata: { namespace: 'reader_settings', version: 1 },
            clientUpdatedAtMs: baseTime,
            deleted: false,
          },
        ],
      },
    });
    assert.equal(initial.statusCode, 200);
    const initialBody = initial.json();
    assert.equal(initialBody.writeResults.length, 1);
    assert.equal(initialBody.writeResults[0].contentKey, contentKey);
    assert.equal(initialBody.writeResults[0].accepted, true);
    assert.equal(initialBody.writeResults[0].winner.payload.fontSize, 20);
    assert.equal(initialBody.writeResults[0].winner.deviceId, 'device-a');

    const stale = await app.inject({
      method: 'POST',
      url: '/users/me/progress/sync',
      headers,
      payload: {
        deviceId: 'device-b',
        cursor: initialBody.cursor,
        items: [
          {
            contentType: 'novel',
            contentKey,
            sourceKey: 'reader_settings',
            itemId: 'v1',
            subItemId: 'settings',
            payload: { fontSize: 14 },
            clientUpdatedAtMs: baseTime - 1,
            deleted: false,
          },
        ],
      },
    });
    assert.equal(stale.statusCode, 200);
    const staleBody = stale.json();
    assert.equal(staleBody.items.length, 0);
    assert.equal(staleBody.writeResults.length, 1);
    assert.equal(staleBody.writeResults[0].accepted, false);
    assert.equal(staleBody.writeResults[0].winner.payload.fontSize, 20);
    assert.equal(staleBody.writeResults[0].winner.deviceId, 'device-a');
    assert.equal(staleBody.writeResults[0].winner.clientUpdatedAtMs, baseTime);

    const pull = await app.inject({
      method: 'GET',
      url: '/users/me/progress?cursor=0&limit=10',
      headers,
    });
    assert.equal(pull.statusCode, 200);
    assert.equal(
      Object.hasOwn(pull.json(), 'writeResults'),
      false,
      'pull responses remain compatible with the existing wire shape',
    );
  } finally {
    await app.close();
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
