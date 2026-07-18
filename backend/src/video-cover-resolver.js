import { ensureManagedUploadRetirementTriggers, one, run } from './db.js';
import { mirrorVideoCover } from './video-cover-cache.js';

const SUPPORTED_PROVIDERS = new Set(['douban', 'wuhandky']);
const WUHANDKY_IMAGE_HOSTS = new Set([
  'pic.fzmmx.com',
  'pic.danzhoufdc.com',
  'pic.monidai.com',
  'img.ukuapi.com',
]);
const MISS_TTL_MS = 30 * 60 * 1000;
const inFlight = new Map();
const doubanQueue = [];
let activeDoubanRequests = 0;
let tableReady = false;

export async function resolveVideoCover({
  sourceKey = 'wuhandky',
  itemKey,
  title,
  year = '',
  candidateUrl = '',
  forceRefresh = false,
}) {
  ensureTable();
  const normalizedSource = cleanKey(sourceKey, 40) || 'wuhandky';
  const normalizedItemKey = canonicalItemKey(
    normalizedSource,
    cleanKey(itemKey, 500),
  );
  const normalizedTitle = cleanText(title).slice(0, 200);
  const normalizedYear = extractYear(year || normalizedTitle);
  if (!normalizedItemKey || !normalizedTitle) return emptyResult();

  const requestKey = `${normalizedSource}\u0000${normalizedItemKey}`;
  const pending = inFlight.get(requestKey);
  if (pending) return pending;
  const request = resolveUncached({
    sourceKey: normalizedSource,
    itemKey: normalizedItemKey,
    title: normalizedTitle,
    year: normalizedYear,
    candidateUrl,
    forceRefresh,
  });
  inFlight.set(requestKey, request);
  try {
    return await request;
  } finally {
    inFlight.delete(requestKey);
  }
}

async function resolveUncached({
  sourceKey,
  itemKey,
  title,
  year,
  candidateUrl,
  forceRefresh,
}) {
  const cached = one(
    `SELECT cover_url AS coverUrl, provider, matched_title AS matchedTitle,
            updated_at AS updatedAt
     FROM video_cover_urls WHERE source_key = ? AND item_key = ?`,
    [sourceKey, itemKey],
  );
  if (isSupportedCachedCover(cached)) {
    return {
      coverUrl: cached.coverUrl,
      provider: cleanText(cached.provider),
      matchedTitle: cached.matchedTitle || '',
      cached: true,
    };
  }
  if (isSupportedExternalCachedCover(cached)) {
    try {
      const mirrored = await mirrorCatalogCover(
        cached.coverUrl,
        cached.provider,
      );
      saveCover({
        sourceKey,
        itemKey,
        title,
        year,
        coverUrl: mirrored,
        provider: cached.provider,
        matchedTitle: cached.matchedTitle || '',
      });
      return {
        coverUrl: mirrored,
        provider: cleanText(cached.provider),
        matchedTitle: cached.matchedTitle || '',
        cached: true,
      };
    } catch {
      // Retry catalog resolution below; old external URLs are not returned.
    }
  }
  if (!forceRefresh && isFreshMiss(cached)) {
    return emptyResult({ cached: true });
  }

  const attempts = [resolveCatalogAndMirror(title, year)];
  const sourceCandidate = normalizeSourceCandidate(sourceKey, candidateUrl);
  if (sourceCandidate) {
    attempts.push(resolveSourceAndMirror(sourceCandidate, title));
  }

  let result;
  try {
    result = await Promise.any(attempts);
  } catch {
    rememberMiss({ sourceKey, itemKey, title, year });
    return emptyResult();
  }
  saveCover({ sourceKey, itemKey, title, year, ...result });
  return { ...result, cached: false };
}

export function selectBestCoverMatch(title, year, items) {
  const target = titleMetadata(title, year);
  if (!target.core) return null;
  let best = null;
  let bestScore = 0;
  for (const item of items || []) {
    const coverUrl = String(item?.coverUrl || item?.thumbUrl || '').trim();
    if (!isHttpUrl(coverUrl)) continue;
    const candidate = titleMetadata(item?.title, item?.year);
    if (!candidate.core) continue;
    let score = 0;
    if (candidate.exact === target.exact) {
      score = 120;
    } else if (candidate.core === target.core) {
      score = 100;
    } else if (
      Math.min(candidate.core.length, target.core.length) >= 4 &&
      (candidate.core.includes(target.core) || target.core.includes(candidate.core)) &&
      Math.min(candidate.core.length, target.core.length) /
        Math.max(candidate.core.length, target.core.length) >= 0.65
    ) {
      score = 82;
    }
    if (!score) continue;
    score += metadataScore(target.year, candidate.year, 12, -18);
    score += metadataScore(target.season, candidate.season, 10, -22);
    score += metadataScore(target.language, candidate.language, 8, -16);
    if (score > bestScore) {
      bestScore = score;
      best = item;
    }
  }
  return bestScore >= 92 ? best : null;
}

async function resolveCatalogAndMirror(title, year) {
  const result = await findCatalogCover(title, year);
  if (!result.coverUrl) throw new Error('video_cover_catalog_missing');
  const coverUrl = await mirrorCatalogCover(result.coverUrl, result.provider);
  return { ...result, coverUrl };
}

async function resolveSourceAndMirror(candidateUrl, title) {
  const coverUrl = await mirrorVideoCover(candidateUrl, {
    timeoutMs: 4500,
    headers: { Referer: 'https://www.wuhandky.com/' },
  });
  return { coverUrl, provider: 'wuhandky', matchedTitle: title };
}

async function mirrorCatalogCover(url, provider) {
  return mirrorVideoCover(url, {
    headers: provider === 'douban'
      ? { Referer: 'https://movie.douban.com/' }
      : {},
  });
}

async function findCatalogCover(title, year) {
  const queries = catalogQueries(title);
  for (const query of queries.slice(0, 2)) {
    try {
      const items = await withDoubanSlot(() => searchDoubanSuggestions(query));
      const match = selectBestCoverMatch(title, year, items);
      if (match) return catalogResult(match, 'douban');
    } catch {
      // Cover repair is best-effort and must not affect the source page.
    }
  }
  return emptyResult();
}

async function searchDoubanSuggestions(query) {
  const url = new URL('https://movie.douban.com/j/subject_suggest');
  url.searchParams.set('q', query);
  const response = await fetch(url, {
    signal: AbortSignal.timeout(4500),
    headers: {
      Accept: 'application/json',
      Referer: 'https://movie.douban.com/',
      'User-Agent': 'Mozilla/5.0 (compatible; NovelCoverResolver/1.0)',
    },
  });
  if (!response.ok) throw new Error('douban_cover_search_failed');
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > 256 * 1024) throw new Error('douban_cover_search_too_large');
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 256 * 1024) throw new Error('douban_cover_search_too_large');
  const payload = JSON.parse(bytes.toString('utf8'));
  if (!Array.isArray(payload)) return [];
  return payload.slice(0, 12).map((item) => ({
    title: cleanText(item?.title),
    year: cleanText(item?.year),
    coverUrl: cleanText(item?.img),
  }));
}

function withDoubanSlot(task) {
  return new Promise((resolve, reject) => {
    const runTask = () => {
      activeDoubanRequests += 1;
      Promise.resolve()
        .then(task)
        .then(resolve, reject)
        .finally(() => {
          activeDoubanRequests -= 1;
          doubanQueue.shift()?.();
        });
    };
    if (activeDoubanRequests < 6) runTask();
    else doubanQueue.push(runTask);
  });
}

function ensureTable() {
  if (tableReady) return;
  run(`CREATE TABLE IF NOT EXISTS video_cover_urls (
    source_key TEXT NOT NULL,
    item_key TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    year TEXT NOT NULL DEFAULT '',
    cover_url TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    matched_title TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (source_key, item_key)
  )`);
  ensureManagedUploadRetirementTriggers([
    ['video_cover_urls', 'cover_url'],
  ]);
  run(
    `DELETE FROM video_cover_urls
     WHERE trim(cover_url) <> ''
       AND lower(trim(provider)) NOT IN ('douban', 'wuhandky')`,
  );
  tableReady = true;
}

function saveCover({
  sourceKey,
  itemKey,
  title,
  year,
  coverUrl,
  provider,
  matchedTitle,
}) {
  if (!isManagedCoverUrl(coverUrl) || !SUPPORTED_PROVIDERS.has(provider)) {
    throw new Error('video_cover_not_mirrored');
  }
  run(
    `INSERT INTO video_cover_urls
       (source_key, item_key, title, year, cover_url, provider, matched_title, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
     ON CONFLICT(source_key, item_key) DO UPDATE SET
       title = excluded.title, year = excluded.year, cover_url = excluded.cover_url,
       provider = excluded.provider, matched_title = excluded.matched_title,
       updated_at = datetime('now')`,
    [sourceKey, itemKey, title, year, coverUrl, provider, matchedTitle],
  );
}

function rememberMiss({ sourceKey, itemKey, title, year }) {
  run(
    `INSERT INTO video_cover_urls
       (source_key, item_key, title, year, cover_url, provider, matched_title, updated_at)
     VALUES (?, ?, ?, ?, '', '', '', datetime('now'))
     ON CONFLICT(source_key, item_key) DO UPDATE SET
       title = excluded.title, year = excluded.year, cover_url = '',
       provider = '', matched_title = '', updated_at = datetime('now')`,
    [sourceKey, itemKey, title, year],
  );
}

function stripTitleSuffix(value) {
  return cleanText(value)
    .replace(/<[^>]+>/g, ' ')
    .replace(/[（(](?:国语|粤语|普通话|英语|日语|韩语|上|下|前篇|后篇|完结)[）)]/gu, ' ')
    .replace(/(?:国语版?|粤语版?|普通话版?|完整版|电影版)$/u, '')
    .replace(/第[一二三四五六七八九十百0-9]+季(?:上|下)?$/u, '')
    .replace(/(?:19|20)\d{2}$/u, '')
    .replace(/[\s:：·•_-]+$/g, '')
    .trim();
}

function normalizeTitle(value) {
  return normalizeExactTitle(stripTitleSuffix(value));
}

function normalizeExactTitle(value) {
  return cleanText(value)
    .toLocaleLowerCase()
    .replace(/[\s·•:：,，.。!！?？《》<>【】\[\]"'“”‘’_-]+/g, '');
}

function titleMetadata(title, explicitYear = '') {
  const text = cleanText(title);
  return {
    exact: normalizeExactTitle(text),
    core: normalizeTitle(text),
    year: extractYear(explicitYear || text),
    season: extractSeason(text),
    language: /粤语/u.test(text)
      ? 'yue'
      : /国语|普通话/u.test(text)
        ? 'mandarin'
        : '',
  };
}

function metadataScore(target, candidate, match, mismatch) {
  if (!target || !candidate) return 0;
  return target === candidate ? match : mismatch;
}

function extractYear(value) {
  return String(value || '').match(/(?:19|20)\d{2}/)?.[0] || '';
}

function extractSeason(value) {
  const match = /第([一二三四五六七八九十百0-9]+)季/u.exec(String(value || ''));
  if (!match) return '';
  return String(chineseNumber(match[1]));
}

function chineseNumber(value) {
  const numeric = Number(value);
  if (Number.isInteger(numeric)) return numeric;
  const digits = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (value === '十') return 10;
  if (value.startsWith('十')) return 10 + (digits[value.slice(1)] || 0);
  if (value.endsWith('十')) return (digits[value[0]] || 1) * 10;
  if (value.includes('十')) {
    const [tens, ones] = value.split('十');
    return (digits[tens] || 1) * 10 + (digits[ones] || 0);
  }
  return digits[value] || 0;
}

function catalogQueries(title) {
  return [...new Set([cleanText(title), stripTitleSuffix(title)].filter(Boolean))];
}

function catalogResult(match, provider) {
  return {
    coverUrl: String(match.coverUrl || match.thumbUrl).trim(),
    provider,
    matchedTitle: String(match.title || '').trim(),
  };
}

function normalizeSourceCandidate(sourceKey, value) {
  if (sourceKey !== 'wuhandky') return '';
  try {
    const url = new URL(String(value || '').trim());
    if (!WUHANDKY_IMAGE_HOSTS.has(url.hostname.toLowerCase())) return '';
    if (!url.pathname.startsWith('/uploads/')) return '';
    url.protocol = 'https:';
    url.username = '';
    url.password = '';
    return url.toString();
  } catch {
    return '';
  }
}

function canonicalItemKey(sourceKey, value) {
  if (sourceKey !== 'wuhandky') return value;
  try {
    const url = new URL(value, 'https://www.wuhandky.com/');
    return `${url.pathname}${url.search}`.slice(0, 500);
  } catch {
    return value;
  }
}

function cleanText(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function cleanKey(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function isHttpUrl(value) {
  try {
    const url = new URL(String(value || ''));
    return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname);
  } catch {
    return false;
  }
}

function isManagedCoverUrl(value) {
  return /^\/video-covers\/files\/[a-f0-9]{64}\.(?:gif|jpe?g|png|webp)$/i.test(
    String(value || ''),
  );
}

function isSupportedCachedCover(row) {
  return SUPPORTED_PROVIDERS.has(cleanText(row?.provider).toLowerCase())
    && isManagedCoverUrl(row?.coverUrl);
}

function isSupportedExternalCachedCover(row) {
  return SUPPORTED_PROVIDERS.has(cleanText(row?.provider).toLowerCase())
    && isHttpUrl(row?.coverUrl);
}

function isFreshMiss(row) {
  if (cleanText(row?.coverUrl)) return false;
  const timestamp = Date.parse(`${cleanText(row?.updatedAt).replace(' ', 'T')}Z`);
  return Number.isFinite(timestamp) && Date.now() - timestamp < MISS_TTL_MS;
}

function emptyResult({ cached = false } = {}) {
  return { coverUrl: '', provider: '', matchedTitle: '', cached };
}

export const videoCoverResolverInternals = {
  normalizeTitle,
  normalizeExactTitle,
  stripTitleSuffix,
  canonicalItemKey,
  normalizeSourceCandidate,
  isHttpUrl,
  isManagedCoverUrl,
  isSupportedCachedCover,
  isFreshMiss,
};
