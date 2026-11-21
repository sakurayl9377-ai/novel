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
    '/album/../new.html',
    '/album/%2e%2e/new.html',
    '/album/demo\n.html',
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
    assert.equal(response.headers['content-security-policy'], "sandbox; default-src 'none'");
    assert.equal(response.headers['x-content-type-options'], 'nosniff');
    assert.equal(response.body, '<html><title>fixture</title></html>');
    assert.deepEqual(calls, ['/dongman/']);
  } finally {
    await app.close();
  }
});

test('fetches source paths against server configuration and cancels oversized HTML', async () => {
  const previousOrigin = config.videoSourceOrigin;
  const previousConnectHost = config.videoSourceConnectHost;
  config.videoSourceOrigin = 'https://source.fixture.test';
  config.videoSourceConnectHost = 'connect.fixture.test';
  try {
    let calls = 0;
    const html = await videoSourceInternals.fetchSourceHtml('/new.html', {
      fetchImpl: async (url, options) => {
        calls += 1;
        assert.equal(url.toString(), 'https://source.fixture.test/new.html');
        assert.equal(options.connectHost, 'connect.fixture.test');
        assert.equal(options.timeoutMs, 20_000);
        assert.equal(options.headers.Referer, 'https://source.fixture.test/');
        return new Response('<html>fixture</html>', { headers: { 'content-type': 'text/html' } });
      },
    });
    assert.equal(html.body.toString(), '<html>fixture</html>');
    assert.equal(calls, 1);

    for (const declaredLength of [false, true]) {
      let cancelled = false;
      const body = new ReadableStream({
        start(controller) {
          if (!declaredLength) controller.enqueue(Buffer.alloc(2 * 1024 * 1024 + 1));
        },
        cancel() { cancelled = true; },
      });
      await assert.rejects(
        videoSourceInternals.fetchSourceHtml('/new.html', {
          fetchImpl: async () => new Response(body, {
            headers: {
              'content-type': 'text/html',
              ...(declaredLength ? { 'content-length': String(2 * 1024 * 1024 + 1) } : {}),
            },
          }),
        }),
        /video_source_body_too_large/,
      );
      assert.equal(cancelled, true, 'both declared and streamed limits must cancel the upstream');
    }
  } finally {
    config.videoSourceOrigin = previousOrigin;
    config.videoSourceConnectHost = previousConnectHost;
  }
});

test('rejects non-HTML and empty source responses and handles OPTIONS without fetching', async () => {
  let calls = 0;
  let upstream = { statusCode: 200, contentType: 'application/json', body: Buffer.from('{}') };
  const app = Fastify({ logger: false });
  videoSourceRoutes(app, { fetchSourceImpl: async () => { calls += 1; return upstream; } });
  try {
    const preflight = await app.inject({ method: 'OPTIONS', url: '/video-source' });
    assert.equal(preflight.statusCode, 204);
    assert.equal(calls, 0);
    const nonHtml = await app.inject('/video-source?path=%2Fnew.html');
    assert.equal(nonHtml.statusCode, 502);
    assert.equal(nonHtml.json().error, 'video_source_content_invalid');
    upstream = { statusCode: 200, contentType: 'text/html', body: Buffer.alloc(0) };
    const empty = await app.inject('/video-source?path=%2Fnew.html');
    assert.equal(empty.statusCode, 502);
    assert.equal(empty.json().error, 'video_source_body_missing');
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
