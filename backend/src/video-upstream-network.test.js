import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import {
  createPinnedVideoLookup,
  createVideoUpstreamFetch,
  isPublicVideoAddress,
  resolveVideoAddresses,
} from './video-upstream-network.js';

function pinnedAddresses(lookup, options = { all: true }) {
  return new Promise((resolve, reject) => {
    lookup('original.test', options, (error, address, family) => {
      if (error) reject(error);
      else resolve(options?.all ? address : { address, family });
    });
  });
}

function nativeFixture({ status = 200, body = 'fixture', headers = {}, hold = false } = {}) {
  const calls = [];
  const requestImpl = (url, options, onResponse) => {
    const request = new EventEmitter();
    const response = new PassThrough();
    response.statusCode = status;
    response.headers = { 'content-type': 'text/plain', ...headers };
    const call = { url, options, request, response };
    calls.push(call);
    request.destroy = (error) => {
      request.destroyed = true;
      if (error) queueMicrotask(() => request.emit('error', error));
    };
    request.end = () => {
      queueMicrotask(() => {
        onResponse(response);
        if (hold) response.write(body);
        else response.end(body);
      });
    };
    return request;
  };
  return { calls, requestImpl };
}

test('video egress rejects special IPv4/IPv6 and applies IPv4 policy to mapped forms', () => {
  for (const address of [
    '0.0.0.0', '0.1.2.3', '10.1.2.3', '100.64.0.1', '100.127.255.255',
    '127.0.0.1', '169.254.169.254', '172.16.0.1', '172.31.255.255',
    '192.0.0.1', '192.0.2.1', '192.88.99.1', '192.168.1.1',
    '198.18.0.1', '198.19.255.255', '198.51.100.1', '203.0.113.1',
    '224.0.0.1', '240.0.0.1', '255.255.255.255', 'not-an-ip',
    '::', '::1', '::127.0.0.1', '::ffff:127.0.0.1', '::ffff:7f00:1',
    '::ffff:100.64.0.1', '::ffff:6440:1', '64:ff9b::7f00:1',
    '64:ff9b:1::1', '100::1', '100:0:0:1::1', '2001::1', '2001:2::1',
    '2001:db8::1', '2002:7f00:1::', '3fff::1', '5f00::1',
    'fc00::1', 'fd00::1', 'fe80::1', 'fec0::1', 'ff02::1', 'fe80::1%eth0',
  ]) {
    assert.equal(isPublicVideoAddress(address), false, address);
  }
  for (const address of [
    '8.8.8.8', '1.1.1.1', '100.63.255.255', '100.128.0.1',
    '172.15.255.255', '172.32.0.1', '198.17.255.255', '198.20.0.1',
    '2001:4860:4860::8888', '2606:4700:4700::1111',
    '::ffff:8.8.8.8', '::ffff:808:808',
  ]) {
    assert.equal(isPublicVideoAddress(address), true, address);
  }
});

test('resolves every DNS record and fails closed on mixed, empty or malformed answers', async () => {
  for (const records of [
    [],
    [{ address: '8.8.8.8', family: 4 }, { address: '::1', family: 6 }],
    [{ address: '8.8.8.8', family: 4 }, { address: '100.64.1.1', family: 4 }],
    [{ address: '8.8.8.8', family: 6 }],
    [{ address: 'not-an-ip', family: 4 }],
  ]) {
    let requested = false;
    const fetch = createVideoUpstreamFetch({
      lookupImpl: async (_hostname, options) => {
        assert.deepEqual(options, { all: true, verbatim: true });
        return records;
      },
      requestImpl: () => { requested = true; },
    });
    await assert.rejects(fetch('https://media.test/'), /video_upstream_(?:dns_invalid|address_not_public)/);
    assert.equal(requested, false);
  }
  await assert.rejects(
    resolveVideoAddresses('media.test', { lookupImpl: async () => { throw new Error('lookup failed'); } }),
    /video_upstream_dns_unavailable/,
  );
});

test('pins one validated DNS snapshot to the socket while preserving original TLS identity', async () => {
  let lookups = 0;
  const fixture = nativeFixture();
  const fetch = createVideoUpstreamFetch({
    ...fixture,
    lookupImpl: async (hostname) => {
      assert.equal(hostname, 'connect.test');
      lookups += 1;
      return [{ address: lookups === 1 ? '8.8.8.8' : '127.0.0.1', family: 4 }];
    },
  });
  const response = await fetch('https://source.test/new.html', { connectHost: 'connect.test' });
  assert.equal(await response.text(), 'fixture');
  const { url, options } = fixture.calls[0];
  assert.equal(url.hostname, 'source.test');
  assert.equal(url.pathname, '/new.html');
  assert.equal(options.servername, 'source.test');
  assert.equal(options.rejectUnauthorized, true);
  assert.equal(options.agent, false);
  assert.equal(options.headers['Accept-Encoding'], 'identity');
  assert.deepEqual(await pinnedAddresses(options.lookup), [{ address: '8.8.8.8', family: 4 }]);
  assert.deepEqual(await pinnedAddresses(options.lookup), [{ address: '8.8.8.8', family: 4 }]);
  assert.equal(lookups, 1, 'socket lookup must not perform another DNS query');

  await assert.rejects(
    fetch('https://source.test/new.html', { connectHost: 'connect.test' }),
    /video_upstream_address_not_public/,
  );
  assert.equal(lookups, 2, 'a new request must revalidate DNS');
  assert.equal(fixture.calls.length, 1, 'the second DNS result must never reach a socket');
});

test('pinned lookup handles address families without consulting DNS again', async () => {
  const records = [
    { address: '8.8.8.8', family: 4 },
    { address: '2606:4700:4700::1111', family: 6 },
  ];
  const lookup = createPinnedVideoLookup(records);
  records[0].address = '127.0.0.1';
  assert.deepEqual(await pinnedAddresses(lookup, { family: 4 }), { address: '8.8.8.8', family: 4 });
  assert.deepEqual(await pinnedAddresses(lookup, { all: true, family: 6 }), [
    { address: '2606:4700:4700::1111', family: 6 },
  ]);
  await assert.rejects(pinnedAddresses(createPinnedVideoLookup([])), /dns_family_unavailable/);
});

test('rejects unsafe URLs and literal connect hosts before opening a request', async () => {
  let requests = 0;
  const fetch = createVideoUpstreamFetch({ requestImpl: () => { requests += 1; } });
  for (const [url, options] of [
    ['http://media.test/', {}],
    ['https://user:password@media.test/', {}],
    ['https://media.test:8443/', {}],
    ['https://127.0.0.1/', { connectHost: '8.8.8.8' }],
    ['https://8.8.8.8/', { connectHost: '1.1.1.1' }],
    ['https://media.test/', { connectHost: '100.64.0.1' }],
    ['https://media.test/', { connectHost: '[::ffff:7f00:1]' }],
    ['https://media.test/', { method: 'POST' }],
  ]) {
    await assert.rejects(fetch(url, options), /video_upstream_/);
  }
  assert.equal(requests, 0);
});

test('aborting during DNS prevents a late connection and preserves timeout status', async () => {
  const controller = new AbortController();
  let resolveDns;
  let requested = false;
  const fetch = createVideoUpstreamFetch({
    lookupImpl: () => new Promise((resolve) => { resolveDns = resolve; }),
    requestImpl: () => { requested = true; },
  });
  const pending = fetch('https://media.test/', { signal: controller.signal });
  controller.abort(new DOMException('deadline', 'TimeoutError'));
  await assert.rejects(pending, { code: 'video_upstream_timeout', statusCode: 504 });
  resolveDns([{ address: '8.8.8.8', family: 4 }]);
  await Promise.resolve();
  assert.equal(requested, false);
});

test('keeps stream cancellation connected to the upstream and gives HEAD a null body', async () => {
  const fixture = nativeFixture({ hold: true });
  const fetch = createVideoUpstreamFetch({
    ...fixture, lookupImpl: async () => [{ address: '8.8.8.8', family: 4 }],
  });
  const response = await fetch('https://media.test/segment.ts');
  await response.body.cancel();
  assert.equal(fixture.calls[0].response.destroyed, true);

  const headFixture = nativeFixture({ body: '' });
  const headFetch = createVideoUpstreamFetch({
    ...headFixture, lookupImpl: async () => [{ address: '8.8.8.8', family: 4 }],
  });
  const head = await headFetch('https://media.test/segment.ts', { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.body, null);
});

test('a streaming response stays subject to the request deadline after its headers arrive', async () => {
  const controller = new AbortController();
  const fixture = nativeFixture({ hold: true });
  const fetch = createVideoUpstreamFetch({
    ...fixture, lookupImpl: async () => [{ address: '8.8.8.8', family: 4 }],
  });
  const response = await fetch('https://media.test/segment.ts', { signal: controller.signal });
  const reading = response.text();
  controller.abort(new DOMException('deadline', 'TimeoutError'));
  await assert.rejects(reading, /video_upstream_timeout/);
  assert.equal(fixture.calls[0].request.destroyed, true);
  assert.equal(fixture.calls[0].response.destroyed, true);
});
