import assert from 'node:assert/strict';
import test from 'node:test';

import { config } from './config.js';
import { buildServer } from './server.js';

test('production server registers both video endpoints under the API prefix', async () => {
  const app = await buildServer();
  try {
    for (const endpoint of ['video-source', 'video-playback']) {
      const response = await app.inject({
        method: 'GET',
        url: `${config.apiPrefix}/${endpoint}`,
      });
      assert.equal(response.statusCode, 400, response.body);
    }
    const source = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-source?path=${encodeURIComponent('https://example.invalid/')}`,
    });
    assert.equal(source.statusCode, 400);
    const playback = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-playback?url=${encodeURIComponent('https://example.invalid/video.m3u8')}`,
    });
    assert.equal(playback.statusCode, 400);
  } finally {
    await app.close();
  }
});
