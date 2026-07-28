import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-kdjx-server-'));
process.env.DB_PATH = path.join(tempDir, 'server.sqlite');
process.env.TOKEN_SECRET = 'kdjx-server-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'kdjx-server-test-settings-secret';
process.env.ADMIN_USERNAME = 'kdjx-server-test-admin';
process.env.ADMIN_PASSWORD = 'kdjx-server-test-admin-password';
process.env.API_PREFIX = '/api';
process.env.KDJX_DEVICE_AUTHORIZATION_URL =
  'sakura-novel://game/kdjx/authorize';
process.env.KDJX_SSO_SHARED_SECRET = 'kdjx-server-test-sso-secret';

const { buildServer } = await import('./server.js');

test('KDJX routes are mounted through the shared server API prefix', async () => {
  const app = await buildServer();
  try {
    const mounted = await app.inject({
      method: 'POST',
      url: '/api/games/kdjx/device-authorizations',
    });
    assert.equal(mounted.statusCode, 200);
    assert.match(mounted.json().deviceCode, /^kdjx_device_/);

    const outsidePrefix = await app.inject({
      method: 'POST',
      url: '/games/kdjx/device-authorizations',
    });
    assert.equal(outsidePrefix.statusCode, 404);
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
