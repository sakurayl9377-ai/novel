import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import Fastify from 'fastify';
import test from 'node:test';

import { config } from './config.js';
import { createVideoUpstreamFetch } from './video-upstream-network.js';
import {
  videoPlaybackInternals,
  videoPlaybackRoutes,
} from './video-playback-proxy.js';

const masterUrl =
  'https://v9.ppqrrs.com/wjv9/202609/06/fixture/video/index.m3u8';
const variantUrl =
  'https://v9.ppqrrs.com/wjv9/202609/06/fixture/video/1000k/hls/index.m3u8';
const segmentUrl =
  'https://v9.adfg8.vip/wjv9/202609/06/fixture/video/1000k/hls/one.ts';

test('rewrites HLS playlists and relays segment range requests', async () => {
  const calls = [];
  const app = Fastify({ logger: false });
  app.register(
    async (api) => {
      videoPlaybackRoutes(api, {
        fetchImpl: async (url, options) => {
          const target = url.toString();
          calls.push({ target, options });
          if (target === masterUrl) {
            return new Response(
              '#EXTM3U\n'
                + '#EXT-X-STREAM-INF:BANDWIDTH=1000\n'
                + '1000k/hls/index.m3u8\n',
              {
                status: 200,
                headers: { 'content-type': 'application/vnd.apple.mpegurl' },
              },
            );
          }
          if (target === variantUrl) {
            return new Response(
              '#EXTM3U\n'
                + '#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\n'
                + '#EXTINF:2,\n'
                + segmentUrl
                + '\n',
              {
                status: 200,
                headers: { 'content-type': 'application/vnd.apple.mpegurl' },
              },
            );
          }
          if (target === segmentUrl) {
            return new Response(Buffer.from('segment-bytes'), {
              status: options.headers.Range ? 206 : 200,
              headers: {
                'content-type': 'video/mp2t',
                'content-range': options.headers.Range
                  ? 'bytes 0-12/13'
                  : '',
              },
            });
          }
          throw new Error(`unexpected upstream URL: ${target}`);
        },
      });
    },
    { prefix: config.apiPrefix },
  );
  await app.ready();

  try {
    const master = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-playback?url=${encodeURIComponent(masterUrl)}`,
    });
    assert.equal(master.statusCode, 200, master.body);
    assert.match(master.headers['content-type'], /mpegurl/);
    assert.equal(master.headers['content-security-policy'], "sandbox; default-src 'none'");
    assert.equal(master.headers['x-content-type-options'], 'nosniff');
    const rewrittenVariant = master.body.trim().split('\n').at(-1);
    assert.ok(rewrittenVariant.startsWith(`${config.apiPrefix}/video-playback?url=`));
    assert.equal(
      new URL(`https://proxy.test${rewrittenVariant}`).searchParams.get('url'),
      variantUrl,
    );

    const head = await app.inject({
      method: 'HEAD',
      url: `${config.apiPrefix}/video-playback?url=${encodeURIComponent(segmentUrl)}`,
    });
    assert.equal(head.statusCode, 200);
    assert.equal(head.body, '');
    assert.match(head.headers['content-type'], /video\/mp2t/);

    const variant = await app.inject({
      method: 'GET',
      url: rewrittenVariant,
    });
    assert.equal(variant.statusCode, 200, variant.body);
    assert.match(variant.body, /video-playback\?url=/);
    assert.equal(
      new URL(
        `https://proxy.test${variant.body.trim().split('\n').at(-1)}`,
      ).searchParams.get('url'),
      segmentUrl,
    );
    const rewrittenKey = variant.body.match(/URI="([^"]+)"/)?.[1];
    assert.ok(rewrittenKey);
    assert.equal(
      new URL(`https://proxy.test${rewrittenKey}`).searchParams.get('url'),
      'https://v9.ppqrrs.com/wjv9/202609/06/fixture/video/1000k/hls/keys/key.bin',
    );

    const segment = await app.inject({
      method: 'GET',
      url: variant.body.trim().split('\n').at(-1),
      headers: { range: 'bytes=0-12' },
    });
    assert.equal(segment.statusCode, 206, segment.body);
    assert.equal(segment.body, 'segment-bytes');
    assert.equal(segment.headers['content-range'], 'bytes 0-12/13');
    assert.equal(segment.headers['content-security-policy'], "sandbox; default-src 'none'");
    assert.equal(calls.at(-1).options.headers.Range, 'bytes=0-12');
  } finally {
    await app.close();
  }
});

test('validates and pins DNS again on each approved redirect target', async () => {
  const lookups = [];
  const connections = [];
  const fetchImpl = createVideoUpstreamFetch({
    lookupImpl: async (hostname) => {
      lookups.push(hostname);
      return [{ address: hostname === 'v9.ppqrrs.com' ? '8.8.8.8' : '100.64.0.1', family: 4 }];
    },
    requestImpl: (url, options, onResponse) => {
      connections.push({ url, options });
      const request = new EventEmitter();
      request.destroy = (error) => {
        if (error) queueMicrotask(() => request.emit('error', error));
      };
      request.end = () => queueMicrotask(() => {
        const response = new PassThrough();
        response.statusCode = 302;
        response.headers = { location: segmentUrl };
        onResponse(response);
        response.end();
      });
      return request;
    },
  });
  const app = Fastify({ logger: false });
  videoPlaybackRoutes(app, { fetchImpl });
  try {
    const response = await app.inject(`/video-playback?url=${encodeURIComponent(masterUrl)}`);
    assert.equal(response.statusCode, 502);
    assert.equal(response.json().error, 'video_playback_upstream_unavailable');
    assert.deepEqual(lookups, ['v9.ppqrrs.com', 'v9.adfg8.vip']);
    assert.equal(connections.length, 1, 'a private redirect must never open a second connection');
    assert.equal(connections[0].options.servername, 'v9.ppqrrs.com');
  } finally {
    await app.close();
  }
});

test('cancels redirect bodies before rejecting host escapes and redirect loops', async () => {
  for (const location of ['https://outside.invalid/video.m3u8', masterUrl]) {
    let calls = 0;
    let cancellations = 0;
    const app = Fastify({ logger: false });
    videoPlaybackRoutes(app, {
      fetchImpl: async () => {
        calls += 1;
        return new Response(new ReadableStream({ cancel() { cancellations += 1; } }), {
          status: 302, headers: { location },
        });
      },
    });
    try {
      const response = await app.inject(`/video-playback?url=${encodeURIComponent(masterUrl)}`);
      assert.equal(response.statusCode, 502);
      assert.equal(response.json().error, 'video_playback_redirect_invalid');
      assert.equal(calls, location === masterUrl ? 5 : 1);
      assert.equal(cancellations, calls);
    } finally {
      await app.close();
    }
  }
});

test('limits playlist bodies while allowing streamed media and isolating returned HTML', async () => {
  for (const declaredLength of [false, true]) {
    let cancelled = false;
    const app = Fastify({ logger: false });
    videoPlaybackRoutes(app, {
      fetchImpl: async () => new Response(new ReadableStream({
        start(controller) {
          if (!declaredLength) controller.enqueue(Buffer.alloc(4 * 1024 * 1024 + 1));
        },
        cancel() { cancelled = true; },
      }), {
        headers: {
          'content-type': 'application/vnd.apple.mpegurl',
          ...(declaredLength ? { 'content-length': String(4 * 1024 * 1024 + 1) } : {}),
        },
      }),
    });
    try {
      const response = await app.inject(`/video-playback?url=${encodeURIComponent(masterUrl)}`);
      assert.equal(response.statusCode, 502);
      assert.equal(response.json().error, 'video_playback_playlist_too_large');
      assert.equal(cancelled, true);
    } finally {
      await app.close();
    }
  }
  const app = Fastify({ logger: false });
  videoPlaybackRoutes(app, {
    fetchImpl: async () => new Response('<script>fixture()</script>', {
      headers: { 'content-type': 'text/html' },
    }),
  });
  try {
    const response = await app.inject(`/video-playback?url=${encodeURIComponent(segmentUrl)}`);
    assert.equal(response.statusCode, 200);
    assert.equal(response.body, '<script>fixture()</script>');
    assert.equal(response.headers['content-security-policy'], "sandbox; default-src 'none'");
    assert.equal(response.headers['x-content-type-options'], 'nosniff');
    const preflight = await app.inject({ method: 'OPTIONS', url: '/video-playback' });
    assert.equal(preflight.statusCode, 204);
  } finally {
    await app.close();
  }
});

test('rejects unapproved upstream hosts and redirect escapes', async () => {
  for (const url of [
    'https://v.lzcdn31.com/path/index.m3u8',
    'https://v.cdnlz22.com/path/index.m3u8',
    'https://vip1.lz-cdn1.com/path/index.m3u8',
    'https://v.lfthirtytwo.com/path/index.m3u8',
  ]) {
    assert.equal(videoPlaybackInternals.parseUpstreamUrl(url).toString(), url);
  }
  assert.throws(
    () => videoPlaybackInternals.parseUpstreamUrl('http://v9.ppqrrs.com/a.m3u8'),
    /video_playback_host_not_allowed/,
  );
  assert.throws(
    () => videoPlaybackInternals.parseUpstreamUrl('https://127.0.0.1/a.m3u8'),
    /video_playback_host_not_allowed/,
  );

  const app = Fastify({ logger: false });
  app.register(
    async (api) => {
      videoPlaybackRoutes(api, {
        fetchImpl: async () =>
          new Response(null, {
            status: 302,
            headers: { location: 'https://example.invalid/video.m3u8' },
          }),
      });
    },
    { prefix: config.apiPrefix },
  );
  await app.ready();
  try {
    const response = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/video-playback?url=${encodeURIComponent(masterUrl)}`,
    });
    assert.equal(response.statusCode, 502);
    assert.equal(response.json().error, 'video_playback_redirect_invalid');
  } finally {
    await app.close();
  }
});

test('rewrites only approved absolute and relative playlist URLs', () => {
  const playlist = [
    '#EXTM3U',
    '#EXT-X-KEY:METHOD=AES-128,URI="https://v9.adfg8.vip/key.bin"',
    'chunk-01.ts',
    'https://outside.invalid/chunk-02.ts',
  ].join('\n');
  const rewritten = videoPlaybackInternals.rewritePlaylist(
    playlist,
    new URL(variantUrl),
  );
  assert.match(rewritten, /video-playback\?url=/);
  assert.match(rewritten, /https:\/\/outside\.invalid\/chunk-02\.ts/);
});
