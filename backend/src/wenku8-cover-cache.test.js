import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { config } from './config.js';
import {
  ensureWenku8Cover,
  wenku8CoverFileName,
} from './wenku8-cover-cache.js';

test('Wenku8 covers are fetched once and persisted in backend cache', async () => {
  const originalDir = config.videoCoverDir;
  const directory = await mkdtemp(path.join(os.tmpdir(), 'wenku8-cover-'));
  config.videoCoverDir = directory;
  let requests = 0;
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x01]);
  const fetchImpl = async (url, options) => {
    requests += 1;
    assert.equal(url, 'https://img.wenku8.com/image/0/1/1s.jpg');
    assert.equal(options.headers.Referer, 'https://www.wenku8.cc/');
    return new Response(jpeg, {
      status: 200,
      headers: { 'content-type': 'image/jpeg' },
    });
  };

  try {
    const [first, concurrent] = await Promise.all([
      ensureWenku8Cover('1', { fetchImpl }),
      ensureWenku8Cover('1', { fetchImpl }),
    ]);
    const cached = await ensureWenku8Cover('1', {
      fetchImpl: async () => {
        throw new Error('cache should avoid another upstream request');
      },
    });

    assert.equal(requests, 1);
    assert.equal(first, concurrent);
    assert.equal(first, cached);
    assert.equal(path.basename(first), wenku8CoverFileName('1'));
    assert.deepEqual(await readFile(first), jpeg);
  } finally {
    config.videoCoverDir = originalDir;
    await rm(directory, { recursive: true, force: true });
  }
});

test('Wenku8 cover cache rejects invalid book ids', async () => {
  await assert.rejects(
    ensureWenku8Cover('../1'),
    /wenku8_cover_book_id_invalid/,
  );
});
