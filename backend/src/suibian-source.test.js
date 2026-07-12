import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { config } from './config.js';
import {
  getSuibianDrama,
  getSuibianStatus,
  listSuibianContent,
  resolveSuibianPlayback,
  searchSuibianContent,
} from './suibian-source.js';

test('catalog upstream errors are 502 and local multi-source catalog is normalized', async (t) => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'suibian-catalog-'));
  const catalogFile = path.join(tempDir, 'catalog.json');
  const originalFetch = globalThis.fetch;
  const originalConfig = {
    file: config.suibianCatalogFile,
    url: config.suibianCatalogUrl,
    token: config.suibianCatalogToken,
  };

  t.after(async () => {
    globalThis.fetch = originalFetch;
    config.suibianCatalogFile = originalConfig.file;
    config.suibianCatalogUrl = originalConfig.url;
    config.suibianCatalogToken = originalConfig.token;
    await rm(tempDir, { recursive: true, force: true });
  });

  config.suibianCatalogFile = path.join(tempDir, 'missing.json');
  config.suibianCatalogUrl = 'https://catalog.example.invalid/private.json?secret=do-not-leak';
  config.suibianCatalogToken = 'do-not-leak-token';
  const upstreamStatuses = [403, 503];
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.headers.Authorization, 'Bearer do-not-leak-token');
    return new Response('', { status: upstreamStatuses.shift() });
  };

  await assert.rejects(
    listSuibianContent(),
    (error) => error.statusCode === 502
      && error.publicCode === 'suibian_catalog_upstream_error'
      && error.upstreamStatus === 403,
  );
  await assert.rejects(
    listSuibianContent(),
    (error) => error.statusCode === 502
      && error.publicCode === 'suibian_catalog_upstream_error'
      && error.upstreamStatus === 503,
  );
  const failedStatus = await getSuibianStatus();
  assert.equal(failedStatus.mode, 'remote');
  assert.equal(failedStatus.lastError.upstreamStatus, 503);
  assert.equal(JSON.stringify(failedStatus).includes('do-not-leak'), false);

  await writeFile(catalogFile, JSON.stringify({
    version: 'test-v1',
    items: [
      {
        id: 'comic-1',
        title: '测试漫剧',
        category: 'comic',
        tags: ['热血'],
        episodes: [
          {
            title: '第一集',
            sources: [
              { name: '线路 A', hlsUrl: 'https://a.example.com/1.m3u8' },
              { name: '线路 B', hlsUrl: 'https://b.example.com/1.m3u8' },
            ],
          },
          {
            title: '第二集',
            hlsUrl: 'https://legacy.example.com/2.m3u8',
          },
        ],
      },
      {
        id: 'short-1',
        title: '测试短剧',
        category: 'short',
        episodes: [{ hlsUrl: 'https://short.example.com/1.m3u8' }],
      },
      {
        id: 'invalid-hls',
        title: '无效内容',
        category: 'comic',
        episodes: [{ hlsUrl: 'http://insecure.example.com/1.m3u8' }],
      },
    ],
  }), 'utf8');
  config.suibianCatalogFile = catalogFile;

  const firstPage = await listSuibianContent({ category: 'all', page: 1, pageSize: 1 });
  assert.equal(firstPage.items.length, 1);
  assert.equal(firstPage.items[0].episodeCount, 2);
  assert.equal(firstPage.hasMore, true);
  const comics = await listSuibianContent({ category: 'comic' });
  assert.deepEqual(comics.items.map((item) => item.id), ['comic-1']);
  assert.equal((await searchSuibianContent('热血')).items[0].id, 'comic-1');

  const drama = await getSuibianDrama('comic-1');
  assert.equal(drama.episodes[0].sources.length, 2);
  const multiSource = await resolveSuibianPlayback('comic-1', 0);
  assert.deepEqual(multiSource.candidates.map((item) => item.name), ['线路 A', '线路 B']);
  const legacySource = await resolveSuibianPlayback('comic-1', 1);
  assert.equal(legacySource.candidates[0].name, '默认线路');
  assert.equal(legacySource.candidates[0].hlsUrl, 'https://legacy.example.com/2.m3u8');

  const healthyStatus = await getSuibianStatus();
  assert.equal(healthyStatus.mode, 'file');
  assert.equal(healthyStatus.cache.itemCount, 2);
  assert.equal(JSON.stringify(healthyStatus).includes('.m3u8'), false);
});
