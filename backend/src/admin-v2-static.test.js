import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import { config } from './config.js';
import { buildServer } from './server.js';

test('admin publishes the Vue workbench at the primary path and preserves the legacy fallback', async () => {
  const app = await buildServer();
  try {
    const primaryRuntime = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/config.json`,
    });
    assert.equal(primaryRuntime.statusCode, 200);
    assert.equal(primaryRuntime.headers['cache-control'], 'no-store');
    assert.deepEqual(primaryRuntime.json(), {
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

    const legacyPage = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/legacy/`,
    });
    assert.equal(legacyPage.statusCode, 200);
    assert.match(legacyPage.body, /<main class="shell">/);

    const legacyConfig = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/legacy/config.js`,
    });
    assert.equal(legacyConfig.statusCode, 200);
    assert.match(legacyConfig.body, /window\.NOVEL_ADMIN_CONFIG/);

    const oldV2Path = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/v2/`,
    });
    assert.equal(oldV2Path.statusCode, 302);
    assert.equal(oldV2Path.headers.location, `${config.adminPath}/`);

    const primaryPage = await app.inject({
      method: 'GET',
      url: `${config.adminPath}/`,
    });
    assert.equal(primaryPage.statusCode, 200);
    if (built) {
      assert.match(primaryPage.body, /<div id="app"><\/div>/);
    } else {
      assert.match(primaryPage.body, /<main class="shell">/);
    }
  } finally {
    await app.close();
  }
});
