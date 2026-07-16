import crypto from 'node:crypto';
import path from 'node:path';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { config } from './config.js';

const allowedSorts = new Set([
  'allvisit',
  'allvote',
  'monthvisit',
  'monthvote',
  'weekvisit',
  'weekvote',
  'dayvisit',
  'dayvote',
  'postdate',
  'lastupdate',
  'goodnum',
  'size',
  'fullflag',
  'anime',
]);
const cache = new Map();
let sessionCookie = '';
let accountPromise;
let loginPromise;

function cleanBaseUrl(value) {
  return String(value || '').replace(/\/+$/, '');
}

function timeoutSignal(timeoutMs) {
  return AbortSignal.timeout(Math.max(1000, Number(timeoutMs) || 8000));
}

function responseCookies(response) {
  const values = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : [];
  if (values.length === 0) {
    const fallback = response.headers.get('set-cookie');
    if (fallback) values.push(fallback);
  }
  return values
    .map((value) => String(value).split(';', 1)[0])
    .filter(Boolean)
    .join('; ');
}

async function fetchText(url, options = {}, fetchImpl = fetch) {
  const response = await fetchImpl(url, {
    redirect: 'manual',
    ...options,
    signal: options.signal || timeoutSignal(config.wenku8TimeoutMs),
  });
  const text = new TextDecoder('utf-8').decode(await response.arrayBuffer());
  return { response, text };
}

function generatedAccount() {
  const stamp = Date.now().toString(36);
  const suffix = crypto.randomBytes(4).toString('hex');
  const username = `NovelReader${stamp}${suffix}`;
  return {
    username,
    password: `${crypto.randomBytes(18).toString('hex')}A7`,
    email: `${username}@example.com`,
  };
}

async function readStoredAccount() {
  try {
    const parsed = JSON.parse(await readFile(config.wenku8AccountFile, 'utf8'));
    if (/^[A-Za-z0-9]+$/.test(parsed?.username || '') && parsed?.password) {
      return {
        username: parsed.username,
        password: parsed.password,
        email: parsed.email || '',
      };
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  return null;
}

async function storeAccount(account) {
  await mkdir(path.dirname(config.wenku8AccountFile), { recursive: true });
  const tempFile = `${config.wenku8AccountFile}.${process.pid}.tmp`;
  await writeFile(tempFile, `${JSON.stringify(account)}\n`, { mode: 0o600 });
  await rename(tempFile, config.wenku8AccountFile);
}

async function registerAccount(fetchImpl) {
  const account = generatedAccount();
  const body = new URLSearchParams({
    action: 'register',
    username: account.username,
    password: account.password,
    email: account.email,
  });
  const { response, text } = await fetchText(
    `${cleanBaseUrl(config.wenku8BaseUrl)}/wap/register.php`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'NovelReaderBackend/1.0',
      },
      body,
    },
    fetchImpl,
  );
  const cookie = responseCookies(response);
  const redirectedWithSession = response.status >= 300 && response.status < 400 && cookie;
  if (
    (!redirectedWithSession && !text.includes(account.username)) ||
    text.includes('返回重新注册')
  ) {
    throw new Error('wenku8_account_registration_failed');
  }
  await storeAccount(account);
  if (cookie) sessionCookie = cookie;
  return account;
}

async function loadAccount(fetchImpl) {
  const configuredUsername = String(config.wenku8Username || '').trim();
  const configuredPassword = String(config.wenku8Password || '');
  if (configuredUsername && configuredPassword) {
    return { username: configuredUsername, password: configuredPassword };
  }
  const stored = await readStoredAccount();
  if (stored) return stored;
  if (!config.wenku8AutoRegister) {
    throw new Error('wenku8_account_not_configured');
  }
  return registerAccount(fetchImpl);
}

async function account(fetchImpl) {
  accountPromise ||= loadAccount(fetchImpl).catch((error) => {
    accountPromise = undefined;
    throw error;
  });
  return accountPromise;
}

async function login(fetchImpl) {
  const credentials = await account(fetchImpl);
  const body = new URLSearchParams({
    action: 'login',
    jumpurl: `${cleanBaseUrl(config.wenku8BaseUrl)}/wap/`,
    username: credentials.username,
    password: credentials.password,
  });
  const { response, text } = await fetchText(
    `${cleanBaseUrl(config.wenku8BaseUrl)}/wap/login.php`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'NovelReaderBackend/1.0',
      },
      body,
    },
    fetchImpl,
  );
  const cookie = responseCookies(response);
  if (cookie) sessionCookie = cookie;
  if (!sessionCookie || text.includes('该用户不存在') || text.includes('密码错误')) {
    throw new Error('wenku8_login_failed');
  }
  return sessionCookie;
}

async function ensureLogin(fetchImpl) {
  if (sessionCookie) return sessionCookie;
  loginPromise ||= login(fetchImpl).finally(() => {
    loginPromise = undefined;
  });
  return loginPromise;
}

function decodeEntities(value) {
  return String(value || '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&nbsp;/g, ' ');
}

export function parseWenku8Toplist(wml) {
  const items = [];
  const seen = new Set();
  const pattern = /<a\b[^>]*href=["'][^"']*articleinfo\.php\?id=(\d+)[^"']*["'][^>]*>([\s\S]*?)<\/a>/gi;
  let match;
  while ((match = pattern.exec(String(wml || ''))) != null) {
    const bookId = match[1];
    if (seen.has(bookId)) continue;
    const title = decodeEntities(match[2].replace(/<[^>]+>/g, ''))
      .replace(/^《|》$/g, '')
      .trim();
    if (!title) continue;
    seen.add(bookId);
    items.push({ bookId, title });
  }
  const pageMatch = String(wml || '').match(/\[(\d+)\/(\d+)\]/);
  return {
    items,
    page: Number(pageMatch?.[1] || 1),
    totalPages: Number(pageMatch?.[2] || 1),
  };
}

async function fetchToplistPage(sort, page, fetchImpl, retry = true) {
  const cookie = await ensureLogin(fetchImpl);
  const url = new URL(`${cleanBaseUrl(config.wenku8BaseUrl)}/wap/article/toplist.php`);
  url.searchParams.set('sort', sort);
  url.searchParams.set('page', String(page));
  const { response, text } = await fetchText(
    url,
    {
      headers: {
        Cookie: cookie,
        Referer: `${cleanBaseUrl(config.wenku8BaseUrl)}/wap/`,
        'User-Agent': 'NovelReaderBackend/1.0',
      },
    },
    fetchImpl,
  );
  const refreshedCookie = responseCookies(response);
  if (refreshedCookie) sessionCookie = refreshedCookie;
  if (text.includes('card id="login.php"') || text.includes('帐号：')) {
    if (!retry) throw new Error('wenku8_session_expired');
    sessionCookie = '';
    await ensureLogin(fetchImpl);
    return fetchToplistPage(sort, page, fetchImpl, false);
  }
  const parsed = parseWenku8Toplist(text);
  if (parsed.items.length === 0) throw new Error('wenku8_toplist_empty');
  return parsed;
}

export async function fetchWenku8Toplist(
  { sort, pages = 3 },
  { fetchImpl = fetch } = {},
) {
  const normalizedSort = String(sort || '').toLowerCase();
  if (!allowedSorts.has(normalizedSort)) {
    throw new Error('wenku8_sort_invalid');
  }
  const requestedPages = Math.max(1, Math.min(5, Number(pages) || 1));
  const cacheKey = `${normalizedSort}:${requestedPages}`;
  const cached = cache.get(cacheKey);
  if (cached && Date.now() - cached.savedAt < config.wenku8CacheTtlMs) {
    return cached.value;
  }

  const first = await fetchToplistPage(normalizedSort, 1, fetchImpl);
  const pageCount = Math.min(requestedPages, first.totalPages);
  const remaining = await Promise.all(
    Array.from({ length: pageCount - 1 }, (_, index) =>
      fetchToplistPage(normalizedSort, index + 2, fetchImpl),
    ),
  );
  const seen = new Set();
  const items = [];
  for (const item of [first, ...remaining].flatMap((page) => page.items)) {
    if (seen.add(item.bookId)) items.push(item);
  }
  const value = {
    sort: normalizedSort,
    pagesFetched: pageCount,
    totalPages: first.totalPages,
    items,
  };
  cache.set(cacheKey, { savedAt: Date.now(), value });
  return value;
}

export function resetWenku8CatalogStateForTest() {
  cache.clear();
  sessionCookie = '';
  accountPromise = undefined;
  loginPromise = undefined;
}
