import { ensureManagedUploadRetirementTriggers, one, run } from './db.js';
import { searchDbzyCache } from './dbzy-source.js';
import { mirrorVideoCover } from './video-cover-cache.js';

const COVER_PROVIDER = 'dbzy';
let tableReady = false;

export async function resolveVideoCover({
  sourceKey = 'wuhandky',
  itemKey,
  title,
  year = '',
}) {
  ensureTable();
  const normalizedSource = cleanKey(sourceKey, 40) || 'wuhandky';
  const normalizedItemKey = cleanKey(itemKey, 500);
  const normalizedTitle = cleanText(title).slice(0, 200);
  const normalizedYear = String(year || '').match(/(?:19|20)\d{2}/)?.[0] || '';
  if (!normalizedItemKey || !normalizedTitle) return emptyResult();

  const cached = one(
    `SELECT cover_url AS coverUrl, provider, matched_title AS matchedTitle
     FROM video_cover_urls WHERE source_key = ? AND item_key = ?`,
    [normalizedSource, normalizedItemKey],
  );
  if (isSupportedCachedCover(cached)) {
    return { coverUrl: cached.coverUrl, provider: COVER_PROVIDER, matchedTitle: cached.matchedTitle || '', cached: true };
  }

  const result = await findCatalogCover(normalizedTitle, normalizedYear);
  if (!result.coverUrl) return emptyResult();
  let coverUrl;
  try {
    coverUrl = await mirrorVideoCover(result.coverUrl);
  } catch {
    return emptyResult();
  }
  run(
    `INSERT INTO video_cover_urls
       (source_key, item_key, title, year, cover_url, provider, matched_title, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
     ON CONFLICT(source_key, item_key) DO UPDATE SET
       title = excluded.title, year = excluded.year, cover_url = excluded.cover_url,
       provider = excluded.provider, matched_title = excluded.matched_title,
       updated_at = datetime('now')`,
    [normalizedSource, normalizedItemKey, normalizedTitle, normalizedYear, coverUrl, result.provider, result.matchedTitle],
  );
  return { ...result, coverUrl, cached: false };
}

export function selectBestCoverMatch(title, year, items) {
  const target = normalizeTitle(title);
  if (!target) return null;
  let best = null;
  let bestScore = 0;
  for (const item of items || []) {
    const coverUrl = String(item?.coverUrl || item?.thumbUrl || '').trim();
    if (!isHttpUrl(coverUrl)) continue;
    const candidate = normalizeTitle(item?.title);
    if (!candidate) continue;
    let score = 0;
    if (candidate === target) score = 100;
    else if (candidate.includes(target) || target.includes(candidate)) score = 72;
    if (year && String(item?.year || '') === String(year)) score += 12;
    if (score > bestScore) {
      bestScore = score;
      best = item;
    }
  }
  return bestScore >= 90 ? best : null;
}

async function findCatalogCover(title, year) {
  const queries = [...new Set([title, stripTitleSuffix(title)].filter(Boolean))];
  for (const query of queries) {
    try {
      const result = await searchDbzyCache(query, { page: 1, pageSize: 20 });
      const match = selectBestCoverMatch(title, year, result.items);
      if (match) {
        return {
          coverUrl: String(match.coverUrl || match.thumbUrl).trim(),
          provider: COVER_PROVIDER,
          matchedTitle: String(match.title || '').trim(),
        };
      }
    } catch {
      // Cover repair is best-effort and must not affect the source page.
    }
  }
  return emptyResult();
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
    ["video_cover_urls", "cover_url"],
  ]);
  run(
    `DELETE FROM video_cover_urls
     WHERE lower(trim(provider)) <> ?`,
    [COVER_PROVIDER],
  );
  tableReady = true;
}

function stripTitleSuffix(value) {
  return cleanText(value)
    .replace(/[（(].*?[）)]/g, ' ')
    .replace(/(?:国语版?|粤语版?|普通话版?|完整版|电影版|第[一二三四五六七八九十0-9]+季)$/u, '')
    .trim();
}

function normalizeTitle(value) {
  return stripTitleSuffix(value)
    .toLocaleLowerCase()
    .replace(/[\s·•:：,，.。!！?？《》<>【】\[\]"'“”‘’_-]+/g, '');
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

function isSupportedCachedCover(row) {
  return String(row?.provider || '').trim().toLowerCase() === COVER_PROVIDER
    && (isHttpUrl(row?.coverUrl) || /^\/video-covers\/files\/[a-f0-9]{64}\.(?:gif|jpe?g|png|webp)$/i.test(String(row?.coverUrl || '')));
}

function emptyResult() {
  return { coverUrl: '', provider: '', matchedTitle: '', cached: false };
}

export const videoCoverResolverInternals = {
  normalizeTitle,
  stripTitleSuffix,
  isHttpUrl,
  isSupportedCachedCover,
};
