import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { config } from './config.js';
import {
  fetchWenku8Toplist,
  parseWenku8Toplist,
  resetWenku8CatalogStateForTest,
} from './wenku8-catalog.js';

test('Wenku8 toplist parser extracts books and pagination', () => {
  const parsed = parseWenku8Toplist(`
    <a href="articleinfo.php?id=3057">《败北女角太多了！》</a><br/>
    <a href="articleinfo.php?id=2542">《我想成为影之强者》</a><br/>
    <a href="articleinfo.php?id=3057">重复</a>[1/207]
  `);
  assert.deepEqual(parsed, {
    page: 1,
    totalPages: 207,
    items: [
      { bookId: '3057', title: '败北女角太多了！' },
      { bookId: '2542', title: '我想成为影之强者' },
    ],
  });
});

test('Wenku8 server account is created once and ranking pages are combined', async () => {
  const original = {
    accountFile: config.wenku8AccountFile,
    username: config.wenku8Username,
    password: config.wenku8Password,
    autoRegister: config.wenku8AutoRegister,
    cacheTtl: config.wenku8CacheTtlMs,
  };
  const directory = await mkdtemp(path.join(os.tmpdir(), 'wenku8-catalog-'));
  config.wenku8AccountFile = path.join(directory, 'account.json');
  config.wenku8Username = '';
  config.wenku8Password = '';
  config.wenku8AutoRegister = true;
  config.wenku8CacheTtlMs = 600000;
  resetWenku8CatalogStateForTest();
  let registerRequests = 0;
  let loginRequests = 0;
  let toplistRequests = 0;
  const fetchImpl = async (url, options = {}) => {
    const target = String(url);
    if (target.endsWith('/wap/register.php')) {
      registerRequests += 1;
      const username = new URLSearchParams(options.body).get('username');
      return new Response(`您好!${username}`, {
        status: 200,
        headers: { 'set-cookie': 'PHPSESSID=registered; Path=/' },
      });
    }
    if (target.endsWith('/wap/login.php')) {
      loginRequests += 1;
      return new Response('登录成功', {
        status: 200,
        headers: { 'set-cookie': 'PHPSESSID=loggedin; Path=/' },
      });
    }
    toplistRequests += 1;
    assert.match(options.headers.Cookie, /PHPSESSID=/);
    const page = Number(new URL(target).searchParams.get('page'));
    return new Response(`
      <a href="articleinfo.php?id=${page}01">《第${page}页第一本》</a>
      <a href="articleinfo.php?id=${page}02">《第${page}页第二本》</a>
      [${page}/3]
    `);
  };

  try {
    const first = await fetchWenku8Toplist(
      { sort: 'dayvisit', pages: 3 },
      { fetchImpl },
    );
    const cached = await fetchWenku8Toplist(
      { sort: 'dayvisit', pages: 3 },
      { fetchImpl },
    );
    assert.equal(first.items.length, 6);
    assert.deepEqual(cached, first);
    assert.equal(registerRequests, 1);
    assert.equal(loginRequests, 1);
    assert.equal(toplistRequests, 3);
  } finally {
    config.wenku8AccountFile = original.accountFile;
    config.wenku8Username = original.username;
    config.wenku8Password = original.password;
    config.wenku8AutoRegister = original.autoRegister;
    config.wenku8CacheTtlMs = original.cacheTtl;
    resetWenku8CatalogStateForTest();
    await rm(directory, { recursive: true, force: true });
  }
});
