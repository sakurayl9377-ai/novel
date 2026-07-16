import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { config } from './config.js';
import { mirrorVideoCover, videoCoverCacheInternals } from './video-cover-cache.js';

test('mirrors a validated public image under a content hash', async (t) => {
  const originalDir = config.videoCoverDir;
  const directory = await mkdtemp(path.join(os.tmpdir(), 'video-cover-'));
  config.videoCoverDir = directory;
  t.after(async () => {
    config.videoCoverDir = originalDir;
    await rm(directory, { recursive: true, force: true });
  });
  const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);

  const localUrl = await mirrorVideoCover('https://example.com/poster.jpg', {
    fetchImpl: async () => new Response(bytes, {
      status: 200,
      headers: { 'content-type': 'image/jpeg', 'content-length': String(bytes.length) },
    }),
  });

  assert.match(localUrl, /^\/video-covers\/files\/[a-f0-9]{64}\.jpg$/);
  assert.deepEqual(await readFile(path.join(directory, path.basename(localUrl))), bytes);
});

test('rejects private and link-local cover hosts', () => {
  assert.equal(videoCoverCacheInternals.isPrivateAddress('127.0.0.1'), true);
  assert.equal(videoCoverCacheInternals.isPrivateAddress('169.254.1.1'), true);
  assert.equal(videoCoverCacheInternals.isPrivateAddress('192.168.1.2'), true);
  assert.equal(videoCoverCacheInternals.isPrivateAddress('8.8.8.8'), false);
});
