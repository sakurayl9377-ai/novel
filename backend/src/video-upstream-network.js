import { lookup as dnsLookup } from 'node:dns/promises';
import { request as httpsRequest } from 'node:https';
import { isIP } from 'node:net';

const DEFAULT_TIMEOUT_MS = 30_000;

export class VideoUpstreamError extends Error {
  constructor(code, statusCode = 502) {
    super(code);
    this.name = 'VideoUpstreamError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

function ipv6Integer(address) {
  let value = address;
  if (value.includes('.')) {
    const split = value.lastIndexOf(':');
    const bytes = value.slice(split + 1).split('.').map(Number);
    value = `${value.slice(0, split + 1)}${((bytes[0] << 8) | bytes[1]).toString(16)}:${((bytes[2] << 8) | bytes[3]).toString(16)}`;
  }
  const [left, right] = value.split('::');
  const before = left ? left.split(':') : [];
  const after = right ? right.split(':') : [];
  const words = right === undefined
    ? before
    : [...before, ...Array(8 - before.length - after.length).fill('0'), ...after];
  return BigInt(`0x${words.map((word) => word.padStart(4, '0')).join('')}`);
}

// Conservatively exclude special-purpose and transition ranges, even where
// IANA lists an individual globally reachable anycast exception. Media CDNs
// do not require those exceptions. See the IANA IPv4/IPv6 special registries.
const ipv6SpecialRanges = [
  [ipv6Integer('2001::'), 23n],
  [ipv6Integer('2001:db8::'), 32n],
  [ipv6Integer('2002::'), 16n],
  [ipv6Integer('3fff::'), 20n],
];

function publicIpv4(address) {
  const [a, b, c] = address.split('.').map(Number);
  return !(
    a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 0 && (c === 0 || c === 2))
    || (a === 192 && b === 88 && c === 99)
    || (a === 192 && b === 168)
    || (a === 198 && (b === 18 || b === 19))
    || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113)
  );
}

export function isPublicVideoAddress(rawAddress) {
  const address = String(rawAddress || '').trim().toLowerCase();
  if (!address || address.includes('%')) return false;
  const family = isIP(address);
  if (family === 4) return publicIpv4(address);
  if (family !== 6) return false;

  const value = ipv6Integer(address);
  // Apply the IPv4 policy to both dotted and hexadecimal mapped addresses.
  if ((value >> 32n) === 0xffffn) {
    const bytes = [24n, 16n, 8n, 0n].map(
      (shift) => Number((value >> shift) & 255n),
    );
    return publicIpv4(bytes.join('.'));
  }
  // Only global unicast is a media destination. This also rejects NAT64,
  // compatible IPv4, unique-local, link-local, multicast and scoped addresses.
  if ((value >> 125n) !== 1n) return false;
  return !ipv6SpecialRanges.some(([prefix, bits]) => (
    (value >> (128n - bits)) === (prefix >> (128n - bits))
  ));
}

function normalizeHostname(rawHostname) {
  let hostname = String(rawHostname || '').trim().toLowerCase();
  if (hostname.startsWith('[') && hostname.endsWith(']')) {
    hostname = hostname.slice(1, -1);
  }
  hostname = hostname.replace(/\.$/, '');
  if (isIP(hostname)) return hostname;
  if (
    !hostname || hostname.length > 253
    || !hostname.split('.').every(
      (label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label),
    )
  ) {
    throw new VideoUpstreamError('video_upstream_hostname_invalid');
  }
  return hostname;
}

function abortedError(signal) {
  const timedOut = signal?.reason?.name === 'TimeoutError';
  return new VideoUpstreamError(
    timedOut ? 'video_upstream_timeout' : 'video_upstream_aborted',
    timedOut ? 504 : 502,
  );
}

function abortable(promise, signal) {
  if (signal.aborted) return Promise.reject(abortedError(signal));
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortedError(signal));
    signal.addEventListener('abort', onAbort, { once: true });
    Promise.resolve(promise).then(resolve, reject).finally(() => {
      signal.removeEventListener('abort', onAbort);
    });
  });
}

export async function resolveVideoAddresses(hostname, {
  lookupImpl = dnsLookup,
  signal = AbortSignal.timeout(DEFAULT_TIMEOUT_MS),
} = {}) {
  if (signal.aborted) throw abortedError(signal);
  const normalized = normalizeHostname(hostname);
  let records;
  try {
    records = isIP(normalized)
      ? [{ address: normalized, family: isIP(normalized) }]
      : await abortable(
        lookupImpl(normalized, { all: true, verbatim: true }),
        signal,
      );
  } catch (error) {
    if (error instanceof VideoUpstreamError) throw error;
    throw new VideoUpstreamError('video_upstream_dns_unavailable');
  }
  if (!Array.isArray(records) || records.length === 0) {
    throw new VideoUpstreamError('video_upstream_dns_invalid');
  }
  if (records.some((record) => (
    !isPublicVideoAddress(record?.address)
    || record.family !== isIP(record.address)
  ))) {
    throw new VideoUpstreamError('video_upstream_address_not_public');
  }
  return records.map(({ address, family }) => ({ address, family }));
}

export function createPinnedVideoLookup(records) {
  const pinned = records.map(({ address, family }) => ({ address, family }));
  return (_hostname, options, callback) => {
    if (typeof options === 'function') {
      callback = options;
      options = {};
    }
    const family = typeof options === 'number' ? options : options?.family;
    const matches = family === 4 || family === 6
      ? pinned.filter((record) => record.family === family)
      : pinned;
    queueMicrotask(() => {
      if (!matches.length) {
        callback(new VideoUpstreamError('video_upstream_dns_family_unavailable'));
      } else if (options?.all) {
        callback(null, matches.map((record) => ({ ...record })));
      } else {
        callback(null, matches[0].address, matches[0].family);
      }
    });
  };
}

function upstreamBody(response) {
  const iterator = response[Symbol.asyncIterator]();
  let cancelled = false;
  return new ReadableStream({
    async pull(controller) {
      try {
        const { value, done } = await iterator.next();
        // Cancellation can finish while a native read is still pending.
        if (cancelled) return;
        if (done) controller.close();
        else controller.enqueue(Buffer.from(value));
      } catch (error) {
        if (!cancelled) controller.error(error);
      }
    },
    async cancel() {
      cancelled = true;
      response.destroy();
      try { await iterator.return?.(); } catch { /* The socket was cancelled. */ }
    },
  });
}

export function createVideoUpstreamFetch({
  requestImpl = httpsRequest,
  lookupImpl = dnsLookup,
} = {}) {
  return async (input, options = {}) => {
    const url = new URL(input);
    const hostname = normalizeHostname(url.hostname);
    const connectHost = normalizeHostname(options.connectHost || hostname);
    if (
      url.protocol !== 'https:' || url.username || url.password
      || (url.port && url.port !== '443')
      || (isIP(hostname) && (
        !isPublicVideoAddress(hostname) || connectHost !== hostname
      ))
    ) {
      throw new VideoUpstreamError('video_upstream_url_invalid');
    }
    const method = String(options.method || 'GET').toUpperCase();
    if (method !== 'GET' && method !== 'HEAD') {
      throw new VideoUpstreamError('video_upstream_method_invalid');
    }
    const timeoutMs = Math.max(
      1, Math.min(60_000, Number(options.timeoutMs) || DEFAULT_TIMEOUT_MS),
    );
    const deadline = AbortSignal.timeout(timeoutMs);
    const signal = options.signal
      ? AbortSignal.any([options.signal, deadline])
      : deadline;
    if (signal.aborted) throw abortedError(signal);
    const records = await resolveVideoAddresses(connectHost, { lookupImpl, signal });
    if (signal.aborted) throw abortedError(signal);

    return new Promise((resolve, reject) => {
      let request;
      let incoming;
      const onAbort = () => {
        const error = abortedError(signal);
        incoming?.destroy(error);
        request?.destroy(error);
        reject(error);
      };
      const cleanup = () => signal.removeEventListener('abort', onAbort);
      signal.addEventListener('abort', onAbort, { once: true });
      try {
        request = requestImpl(url, {
          method,
          headers: { 'Accept-Encoding': 'identity', ...options.headers },
          // A new socket must use this request's validated DNS snapshot. Never
          // let a shared Agent or a second resolver choose the destination.
          agent: false,
          lookup: createPinnedVideoLookup(records),
          servername: isIP(hostname) ? '' : hostname,
          rejectUnauthorized: true,
        }, (response) => {
          incoming = response;
          response.once('end', cleanup);
          response.once('close', cleanup);
          response.once('aborted', () => {
            response.destroy(new VideoUpstreamError('video_upstream_aborted'));
          });
          try {
            const headers = new Headers();
            for (const [name, values] of Object.entries(response.headers)) {
              if (values === undefined) continue;
              for (const value of Array.isArray(values) ? values : [values]) {
                headers.append(name, String(value));
              }
            }
            const status = Number(response.statusCode);
            const empty = method === 'HEAD' || [204, 205, 304].includes(status);
            const body = empty ? null : upstreamBody(response);
            if (empty) response.resume();
            resolve(new Response(body, { status, headers }));
          } catch {
            response.destroy();
            cleanup();
            reject(new VideoUpstreamError('video_upstream_response_invalid'));
          }
        });
        request.once('error', (error) => {
          cleanup();
          incoming?.destroy(error);
          reject(signal.aborted ? abortedError(signal) : error);
        });
        request.end();
      } catch (error) {
        cleanup();
        incoming?.destroy();
        request?.destroy();
        reject(error);
      }
      if (signal.aborted) onAbort();
    });
  };
}

export const fetchVideoUpstream = createVideoUpstreamFetch();
