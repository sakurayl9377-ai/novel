import { isIP } from 'node:net';

import { config } from './config.js';
import { enforceRateLimits } from './rate-limit.js';
import {
  createVideoUpstreamFetch,
  isPublicVideoAddress,
} from './video-upstream-network.js';

const MAX_PATH_LENGTH = 2048;
const MAX_HTML_BYTES = 2 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 20 * 1000;
const SOURCE_USER_AGENT =
  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
const ALLOWED_SOURCE_PATHS = [
  /^\/$/,
  /^\/new\.html$/,
  /^\/(?:dianying|dianshiju|dongman|zongyi)\/$/,
  /^\/search\/[^/]{1,600}-[1-9]\d{0,3}\.html$/u,
  /^\/album\/[a-zA-Z0-9_-]{1,400}\.html$/,
];

class VideoSourceError extends Error {
  constructor(code, statusCode = 400) {
    super(code);
    this.name = 'VideoSourceError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

function parseSourcePath(rawValue) {
  const raw = String(rawValue ?? '').trim();
  if (
    !raw
    || raw.length > MAX_PATH_LENGTH
    || !raw.startsWith('/')
    || raw.startsWith('//')
    || raw.includes('\\')
    || /[\u0000-\u001f\u007f]/u.test(raw)
  ) {
    throw new VideoSourceError('video_source_path_invalid');
  }

  let url;
  try {
    const decoded = decodeURIComponent(raw);
    if (decoded.split('/').some((part) => part === '.' || part === '..')) {
      throw new Error('non-canonical source path');
    }
    url = new URL(raw, 'https://video-source.invalid');
  } catch {
    throw new VideoSourceError('video_source_path_invalid');
  }
  if (
    url.origin !== 'https://video-source.invalid'
    || url.search
    || url.hash
  ) {
    throw new VideoSourceError('video_source_path_invalid');
  }

  let decodedPath;
  try {
    decodedPath = decodeURIComponent(url.pathname);
  } catch {
    throw new VideoSourceError('video_source_path_invalid');
  }
  if (
    decodedPath.includes('\\')
    || /[\u0000-\u001f\u007f]/u.test(decodedPath)
    || decodedPath.split('/').some((part) => part === '.' || part === '..')
    || !ALLOWED_SOURCE_PATHS.some((pattern) => pattern.test(decodedPath))
  ) {
    throw new VideoSourceError('video_source_path_invalid');
  }
  return url.pathname;
}

function sourceOrigin() {
  let origin;
  try {
    origin = new URL(String(config.videoSourceOrigin || ''));
  } catch {
    throw new VideoSourceError('video_source_config_invalid', 500);
  }
  if (
    origin.protocol !== 'https:'
    || origin.username
    || origin.password
    || (origin.port && origin.port !== '443')
    || origin.pathname !== '/'
    || origin.search
    || origin.hash
  ) {
    throw new VideoSourceError('video_source_config_invalid', 500);
  }
  return origin;
}

function normalizeConnectHost() {
  const host = String(config.videoSourceConnectHost || '').trim().toLowerCase();
  if (
    !host
    || host.length > 253
    || (!isIP(host) && !/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host))
  ) {
    throw new VideoSourceError('video_source_config_invalid', 500);
  }
  return host;
}

async function fetchSourceHtml(
  rawPath,
  { requestImpl, lookupImpl, fetchImpl } = {},
) {
  const sourcePath = parseSourcePath(rawPath);
  const origin = sourceOrigin();
  const connectHost = normalizeConnectHost();
  const url = new URL(sourcePath, origin);

  const requestSource = fetchImpl || createVideoUpstreamFetch({ requestImpl, lookupImpl });
  const response = await requestSource(url, {
    method: 'GET',
    timeoutMs: REQUEST_TIMEOUT_MS,
    connectHost,
    headers: {
      Accept: 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
      'Accept-Encoding': 'identity',
      'User-Agent': SOURCE_USER_AGENT,
      Referer: `${origin.origin}/`,
    },
  });
  const contentType = response.headers.get('content-type') || '';
  if (response.status !== 200) {
    await response.body?.cancel?.();
    return { statusCode: response.status, contentType, body: Buffer.alloc(0) };
  }
  if (Number(response.headers.get('content-length')) > MAX_HTML_BYTES) {
    await response.body?.cancel?.();
    throw new VideoSourceError('video_source_body_too_large', 502);
  }
  const chunks = [];
  let total = 0;
  if (response.body) {
    for await (const chunk of response.body) {
      const bytes = Buffer.from(chunk);
      total += bytes.length;
      if (total > MAX_HTML_BYTES) {
        throw new VideoSourceError('video_source_body_too_large', 502);
      }
      chunks.push(bytes);
    }
  }
  return {
    statusCode: response.status,
    contentType,
    body: Buffer.concat(chunks, total),
    sourceUrl: url.toString(),
  };
}

async function handleVideoSource(request, reply, fetchSourceImpl) {
  reply
    .header('Content-Security-Policy', "sandbox; default-src 'none'")
    .header('X-Content-Type-Options', 'nosniff');
  if (request.method === 'OPTIONS') {
    return reply
      .code(204)
      .header('Access-Control-Allow-Origin', '*')
      .header('Access-Control-Allow-Methods', 'GET, OPTIONS')
      .send();
  }

  const limited = enforceRateLimits(request, reply, [
    {
      scope: 'video_source_ip',
      key: request.ip || 'unknown',
      limit: 600,
      windowMs: 5 * 60 * 1000,
      error: 'video_source_rate_limited',
    },
  ]);
  if (limited) return limited;

  let sourcePath;
  try {
    sourcePath = parseSourcePath(request.query?.path);
  } catch (error) {
    return reply.code(error.statusCode || 400).send({
      error: error.code || 'video_source_path_invalid',
    });
  }

  let upstream;
  try {
    upstream = await fetchSourceImpl(sourcePath);
  } catch (error) {
    request.log?.warn?.(
      { code: error.code || 'video_source_upstream_unavailable' },
      'video source request failed',
    );
    return reply.code(error.statusCode || 502).send({
      error: error.code || 'video_source_upstream_unavailable',
    });
  }

  if (upstream.statusCode !== 200) {
    request.log?.warn?.(
      { statusCode: upstream.statusCode },
      'video source returned an error',
    );
    return reply.code(502).send({ error: 'video_source_upstream_rejected' });
  }
  if (!String(upstream.contentType || '').toLowerCase().includes('text/html')) {
    return reply.code(502).send({ error: 'video_source_content_invalid' });
  }
  if (!Buffer.isBuffer(upstream.body) || upstream.body.length === 0) {
    return reply.code(502).send({ error: 'video_source_body_missing' });
  }

  return reply
    .code(200)
    .type('text/html; charset=utf-8')
    .header('Access-Control-Allow-Origin', '*')
    .header('X-Content-Type-Options', 'nosniff')
    .header('Content-Security-Policy', "sandbox; default-src 'none'")
    .header('Cache-Control', 'no-store')
    .send(upstream.body);
}

export function videoSourceRoutes(app, options = {}) {
  const fetchSourceImpl = options.fetchSourceImpl || fetchSourceHtml;
  app.route({
    method: ['GET', 'OPTIONS'],
    url: '/video-source',
    logLevel: 'warn',
    handler: (request, reply) =>
      handleVideoSource(request, reply, fetchSourceImpl),
  });
}

export const videoSourceInternals = {
  fetchSourceHtml,
  isPrivateAddress: (address) => !isPublicVideoAddress(address),
  parseSourcePath,
};
