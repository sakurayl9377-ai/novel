import assert from 'node:assert/strict';
import Fastify from 'fastify';
import test from 'node:test';

import { config } from './config.js';
import {
  videoSourceInternals,
  videoSourceRoutes,
} from './video-source-proxy.js';

test('accepts only the source paths used by the video client', () => {
  for (const path of [
    '/',
    '/new.html',
    '/dongman/',
    '/album/demo-1-2.html',
    '/search/%E7%89%A7%E7%A5%9E%E8%AE%B0-1.html',
  ]) {
    assert.equal(videoSourceInternals.parseSourcePath(path), path);
  }

  for (const path of [
    'https://example.invalid/dongman/',
    '//example.invalid/dongman/',
    '/album/../admin.html',
    '/search/demo%0Aheader-1.html',
    '/index.php?target=admin',
    '/unknown/path',
  ]) {
    assert.throws(
      () => videoSourceInternals.parseSourcePath(path),
      /video_source_path_invalid/,
    );
  }
});

test('rejects private addresses returned for the source connect host', () => {
  assert.equal(videoSourceInternals.isPrivateAddress('127.0.0.1'), true);
  assert.equal(videoSourceInternals.isPrivateAddress('169.254.1.2'), true);
  assert.equal(videoSourceInternals.isPrivateAddress('192.168.1.2'), true);
  assert.equal(videoSourceInternals.isPrivateAddress('::1'), true);
  assert.equal(videoSourceInternals.isPrivateAddress('8.153.168.47'), false);
});

test('relays source HTML through the constrained endpoint', async () => {
  const calls = [];
  const app = Fastify({ logger: false });
  app.register(
    async (api) => {
      videoSourceRoutes(api, {
        fetchSourceImpl: async (path) => {
          calls.push(path);
          return {
            statusCode: 200,
            contentType: 'text/html; charset=utf-8',
            body: Buffer.from('<html><title>fixture</title></html>'),
          };
        },
      });
    },
    { prefix: config.apiPrefix },
  );
  await app.ready();

  try {
    const response = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-source?path=${encodeURIComponent('/dongman/')}`,
    });
    assert.equal(response.statusCode, 200, response.body);
    assert.match(response.headers['content-type'], /text\/html/);
    assert.equal(response.headers['cache-control'], 'no-store');
    assert.equal(response.body, '<html><title>fixture</title></html>');
    assert.deepEqual(calls, ['/dongman/']);
  } finally {
    await app.close();
  }
});

test('maps invalid paths and rejected upstream responses', async () => {
  const app = Fastify({ logger: false });
  app.register(
    async (api) => {
      videoSourceRoutes(api, {
        fetchSourceImpl: async () => ({
          statusCode: 403,
          contentType: 'text/html',
          body: Buffer.from('forbidden'),
        }),
      });
    },
    { prefix: config.apiPrefix },
  );
  await app.ready();

  try {
    const invalid = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-source?path=${encodeURIComponent('https://example.invalid/')}`,
    });
    assert.equal(invalid.statusCode, 400);
    assert.equal(invalid.json().error, 'video_source_path_invalid');

    const rejected = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-source?path=${encodeURIComponent('/new.html')}`,
    });
    assert.equal(rejected.statusCode, 502);
    assert.equal(rejected.json().error, 'video_source_upstream_rejected');
  } finally {
    await app.close();
  }
});
