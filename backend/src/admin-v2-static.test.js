import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import { config } from './config.js';
import { buildServer } from './server.js';

test('admin v2 publishes runtime config and serves a built bundle when present', async () => {
  const app = await buildServer();
  try {
    const runtime = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/v2/config.json`,
    });
    assert.equal(runtime.statusCode, 200);
    assert.equal(runtime.headers['cache-control'], 'no-store');
    assert.deepEqual(runtime.json(), {
      apiPrefix: config.apiPrefix,
      adminPath: config.adminPath,
      wsChatPath: config.wsChatPath,
      wsGamePath: config.wsGamePath,
      wsDanmakuPath: config.wsDanmakuPath,
    });

    const built = fs.existsSync(path.join(config.rootDir, 'admin-dist', 'index.html'));
    const health = await app.inject({ method: 'GET', url: '/health' });
    assert.equal(health.statusCode, 200);
    assert.equal(health.json().adminV2Available, built);

    if (built) {
      const page = await app.inject({
        method: 'GET',
        url: `${config.adminPath}/v2/`,
      });
      assert.equal(page.statusCode, 200);
      assert.match(page.body, /<div id="app"><\/div>/);
    }
  } finally {
    await app.close();
  }
});
