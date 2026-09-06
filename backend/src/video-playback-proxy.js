import { Readable } from 'node:stream';

import { config } from './config.js';
import { enforceRateLimits } from './rate-limit.js';

const MAX_URL_LENGTH = 4096;
const MAX_REDIRECTS = 4;
const MAX_PLAYLIST_BYTES = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 30 * 1000;
const SOURCE_USER_AGENT =
  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
const SOURCE_REFERER = 'https://www.xinyegdchina.com/';
const REQUIRED_HOST_SUFFIXES = [
  'ppqrrs.com',
  'adfg8.vip',
  'lfthirtytwo.com',
];
const NUMBERED_CDN_HOST = /^(?:[a-z0-9-]+\.)*(?:lzcdn\d+|cdnlz\d+|lz-cdn\d+)\.com$/;
const HLS_CONTENT_TYPES = [
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
];

class VideoPlaybackError extends Error {
  constructor(code, statusCode = 400) {
    super(code);
    this.name = 'VideoPlaybackError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

function allowedHostSuffixes() {
  const configured = Array.isArray(config.videoPlaybackAllowedHosts)
    ? config.videoPlaybackAllowedHosts
    : [];
  return [...REQUIRED_HOST_SUFFIXES, ...configured]
    .map((item) => String(item || '').trim().toLowerCase())
    .map((item) => item.replace(/^\*\./, '').replace(/\.$/, ''))
    .filter((item, index, items) => item && items.indexOf(item) === index);
}

function isAllowedHost(hostname) {
  const host = String(hostname || '').trim().toLowerCase().replace(/\.$/, '');
  if (!host) return false;
  if (NUMBERED_CDN_HOST.test(host)) return true;
  return allowedHostSuffixes().some(
    (suffix) => host === suffix || host.endsWith(`.${suffix}`),
  );
}

function parseUpstreamUrl(rawValue) {
  const raw = String(rawValue ?? '').trim();
  if (!raw || raw.length > MAX_URL_LENGTH) {
    throw new VideoPlaybackError('video_playback_url_invalid');
  }

  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new VideoPlaybackError('video_playback_url_invalid');
  }

  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    (url.port && url.port !== '443') ||
    !isAllowedHost(url.hostname)
  ) {
    throw new VideoPlaybackError('video_playback_host_not_allowed');
  }
  url.hash = '';
  return url;
}

function proxyUrlFor(upstreamUrl) {
  const prefix = config.apiPrefix || '';
  const endpoint = new URL(
    `${prefix}/video-playback`.replace(/\/\/+/g, '/'),
    'https://video-proxy.invalid',
  );
  endpoint.searchParams.set('url', upstreamUrl.toString());
  return `${endpoint.pathname}${endpoint.search}`;
}

function resolveAllowedUri(rawValue, baseUrl) {
  const value = String(rawValue || '').trim();
  if (!value || value.startsWith('data:') || value.startsWith('skd:')) {
    return null;
  }
  let resolved;
  try {
    resolved = new URL(value, baseUrl);
  } catch {
    return null;
  }
  if (resolved.protocol !== 'https:' || !isAllowedHost(resolved.hostname)) {
    return null;
  }
  resolved.hash = '';
  return resolved;
}

function rewritePlaylist(playlist, baseUrl) {
  return String(playlist)
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;

      if (trimmed.startsWith('#')) {
        return line.replace(
          /URI=(['"])([^'"]+)\1/g,
          (match, quote, value) => {
            const resolved = resolveAllowedUri(value, baseUrl);
            return resolved
              ? `URI=${quote}${proxyUrlFor(resolved)}${quote}`
              : match;
          },
        );
      }

      const resolved = resolveAllowedUri(trimmed, baseUrl);
      if (!resolved) return line;
      const leading = line.slice(0, line.indexOf(trimmed));
      return `${leading}${proxyUrlFor(resolved)}`;
    })
    .join('\n');
}

async function readLimitedBody(response, maxBytes) {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new VideoPlaybackError('video_playback_playlist_too_large', 502);
  }

  if (!response.body) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body) {
    const bytes = Buffer.from(chunk);
    total += bytes.length;
    if (total > maxBytes) {
      throw new VideoPlaybackError('video_playback_playlist_too_large', 502);
    }
    chunks.push(bytes);
  }
  return Buffer.concat(chunks, total);
}

function timeoutSignal(timeoutMs) {
  if (typeof AbortSignal?.timeout === 'function') {
    return AbortSignal.timeout(timeoutMs);
  }
  const controller = new AbortController();
  setTimeout(() => controller.abort(), timeoutMs).unref?.();
  return controller.signal;
}

function isRedirect(statusCode) {
  return statusCode >= 300 && statusCode < 400;
}

async function fetchUpstream(startUrl, {
  fetchImpl,
  method,
  range,
}) {
  let current = parseUpstreamUrl(startUrl);
  for (let redirect = 0; redirect <= MAX_REDIRECTS; redirect += 1) {
    const headers = {
      Accept: '*/*',
      'User-Agent': SOURCE_USER_AGENT,
      Referer: SOURCE_REFERER,
    };
    if (range) headers.Range = range;

    let response;
    try {
      response = await fetchImpl(current, {
        method,
        headers,
        redirect: 'manual',
        signal: timeoutSignal(REQUEST_TIMEOUT_MS),
      });
    } catch {
      throw new VideoPlaybackError('video_playback_upstream_unavailable', 502);
    }

    if (!isRedirect(response.status)) return { response, url: current };
    const location = response.headers.get('location');
    if (!location || redirect === MAX_REDIRECTS) {
      throw new VideoPlaybackError('video_playback_redirect_invalid', 502);
    }
    try {
      current = parseUpstreamUrl(new URL(location, current).toString());
    } catch (error) {
      if (error instanceof VideoPlaybackError) {
        throw new VideoPlaybackError('video_playback_redirect_invalid', 502);
      }
      throw error;
    }
    await response.body?.cancel?.();
  }
  throw new VideoPlaybackError('video_playback_redirect_invalid', 502);
}

function copyMediaHeaders(response, reply) {
  for (const name of [
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
    'etag',
    'last-modified',
  ]) {
    const value = response.headers.get(name);
    if (value) reply.header(name, value);
  }
  reply
    .header('Access-Control-Allow-Origin', '*')
    .header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
    .header('Access-Control-Allow-Headers', 'Range, Accept, Origin, User-Agent')
    .header('Cache-Control', 'no-store');
}

function isPlaylistResponse(url, response) {
  const contentType = String(response.headers.get('content-type') || '')
    .toLowerCase()
    .split(';', 1)[0]
    .trim();
  return (
    url.pathname.toLowerCase().endsWith('.m3u8') ||
    HLS_CONTENT_TYPES.includes(contentType)
  );
}

function safeRangeHeader(value) {
  const range = String(value || '').trim();
  return /^bytes=\d*-\d*(?:,\d*-\d*)?$/.test(range) && range.length <= 200
    ? range
    : '';
}

async function handleVideoPlayback(request, reply, fetchImpl) {
  if (request.method === 'OPTIONS') {
    return reply
      .code(204)
      .header('Access-Control-Allow-Origin', '*')
      .header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      .header('Access-Control-Allow-Headers', 'Range, Accept, Origin, User-Agent')
      .send();
  }

  const limited = enforceRateLimits(request, reply, [
    {
      scope: 'video_playback_ip',
      key: request.ip || 'unknown',
      limit: 12000,
      windowMs: 60 * 60 * 1000,
      error: 'video_playback_rate_limited',
    },
  ]);
  if (limited) return limited;

  let upstreamUrl;
  try {
    upstreamUrl = parseUpstreamUrl(request.query?.url);
  } catch (error) {
    return reply.code(error.statusCode || 400).send({
      error: error.code || 'video_playback_url_invalid',
    });
  }

  let upstream;
  try {
    upstream = await fetchUpstream(upstreamUrl, {
      fetchImpl,
      method: request.method,
      range: safeRangeHeader(request.headers.range),
    });
  } catch (error) {
    request.log?.warn?.(
      { code: error.code || 'video_playback_upstream_unavailable' },
      'video playback upstream request failed',
    );
    return reply.code(error.statusCode || 502).send({
      error: error.code || 'video_playback_upstream_unavailable',
    });
  }

  const { response, url } = upstream;
  if (!response.ok) {
    request.log?.warn?.(
      { host: url.hostname, statusCode: response.status },
      'video playback upstream returned an error',
    );
    await response.body?.cancel?.();
    return reply.code(502).send({ error: 'video_playback_upstream_rejected' });
  }

  const playlistResponse = isPlaylistResponse(url, response);
  if (request.method === 'HEAD') {
    copyMediaHeaders(response, reply);
    return reply.code(response.status).send();
  }

  if (playlistResponse) {
    let playlist;
    try {
      playlist = (await readLimitedBody(response, MAX_PLAYLIST_BYTES)).toString(
        'utf8',
      );
    } catch (error) {
      request.log?.warn?.(
        { code: error.code || 'video_playback_playlist_invalid' },
        'video playback playlist could not be read',
      );
      return reply.code(error.statusCode || 502).send({
        error: error.code || 'video_playback_playlist_invalid',
      });
    }
    if (!playlist.trimStart().startsWith('#EXTM3U')) {
      return reply.code(502).send({ error: 'video_playback_playlist_invalid' });
    }
    return reply
      .code(response.status)
      .type('application/vnd.apple.mpegurl')
      .header('Access-Control-Allow-Origin', '*')
      .header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      .header('Access-Control-Allow-Headers', 'Range, Accept, Origin, User-Agent')
      .header('Cache-Control', 'no-store')
      .send(rewritePlaylist(playlist, url));
  }

  copyMediaHeaders(response, reply);
  if (!response.body) {
    return reply.code(502).send({ error: 'video_playback_body_missing' });
  }
  return reply.code(response.status).send(Readable.fromWeb(response.body));
}

export function videoPlaybackRoutes(app, options = {}) {
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  if (typeof fetchImpl !== 'function') {
    throw new Error('video playback proxy requires fetch');
  }
  app.route({
    method: ['GET', 'HEAD', 'OPTIONS'],
    url: '/video-playback',
    handler: (request, reply) =>
      handleVideoPlayback(request, reply, fetchImpl),
  });
}

export const videoPlaybackInternals = {
  isAllowedHost,
  parseUpstreamUrl,
  proxyUrlFor,
  rewritePlaylist,
  safeRangeHeader,
};
