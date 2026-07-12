import { config } from './config.js';

const cache = new Map();
const cacheTtlMs = 5 * 60 * 1000;
const allowedCategories = new Set(['comic', 'short']);

export async function listSuibianContent({ category = 'all', page = 1, pageSize = 18 } = {}) {
  const normalizedCategory = normalizeCategory(category);
  const cacheKey = `list:${normalizedCategory}:${page}:${pageSize}`;
  return cached(cacheKey, async () => {
    const response = await sourceApi({ ac: 'detail', pg: page });
    const sourceItems = Array.isArray(response?.list) ? response.list : [];
    const items = sourceItems
      .map(normalizeDrama)
      .filter(Boolean)
      .filter((item) => normalizedCategory === 'all' || item.category === normalizedCategory)
      .slice(0, pageSize);
    return {
      items,
      page: number(response?.page, page),
      pageSize,
      hasMore: number(response?.pagecount, page) > page,
    };
  });
}

export async function searchSuibianContent(query, { page = 1, pageSize = 18 } = {}) {
  const q = String(query || '').trim();
  if (!q) return { items: [], page, pageSize, hasMore: false };
  const response = await sourceApi({ ac: 'detail', wd: q, pg: page });
  const sourceItems = Array.isArray(response?.list) ? response.list : [];
  return {
    items: sourceItems.map(normalizeDrama).filter(Boolean).slice(0, pageSize),
    page: number(response?.page, page),
    pageSize,
    hasMore: number(response?.pagecount, page) > page,
  };
}

export async function getSuibianDrama(id) {
  const dramaId = String(id || '').trim();
  if (!dramaId) return null;
  return cached(`detail:${dramaId}`, async () => {
    const response = await sourceApi({ ac: 'detail', ids: dramaId });
    const raw = Array.isArray(response?.list) ? response.list[0] : null;
    const drama = normalizeDrama(raw);
    if (!drama) return null;
    return { ...drama, episodes: blueRay2Episodes(raw) };
  });
}

export async function resolveSuibianPlayback(id, episodeIndex) {
  const drama = await getSuibianDrama(id);
  const episode = drama?.episodes?.[episodeIndex];
  if (!episode) return null;
  const direct = hlsFromUrl(episode.sourceUrl);
  if (direct) return { ...episode, hlsUrl: direct };

  const pageUrl = safeSameOriginUrl(episode.sourceUrl);
  if (!pageUrl) return null;
  const html = await fetchText(pageUrl);
  const iframe = /<iframe[^>]+src=["']([^"']+)["']/i.exec(html)?.[1] || '';
  const hlsUrl = hlsFromUrl(new URL(iframe, pageUrl).toString());
  return hlsUrl ? { ...episode, hlsUrl } : null;
}

function normalizeDrama(raw) {
  const id = text(raw?.vod_id);
  const title = cleanText(raw?.vod_name);
  const category = categoryFrom(raw);
  if (!id || !title || !category) return null;
  return {
    id,
    title,
    category,
    summary: cleanText(raw?.vod_blurb || raw?.vod_content),
    status: cleanText(raw?.vod_remarks),
    tags: cleanText(raw?.vod_class).split(/[\s,，/]+/).filter(Boolean).slice(0, 3),
    // The visual cover belongs to the product and is generated from title in the app.
    coverUrl: '',
  };
}

function blueRay2Episodes(raw) {
  const names = text(raw?.vod_play_from).split('$$$');
  const blocks = text(raw?.vod_play_url).split('$$$');
  const sourceIndex = names.findIndex((name) => name.trim() === '蓝光-2');
  if (sourceIndex < 0) return [];
  return text(blocks[sourceIndex]).split('#').map((part, index) => {
    const separator = part.indexOf('$');
    if (separator <= 0 || separator === part.length - 1) return null;
    return { index, title: part.slice(0, separator).trim() || `第 ${index + 1} 集`, sourceUrl: part.slice(separator + 1).trim() };
  }).filter(Boolean);
}

function categoryFrom(raw) {
  const value = `${text(raw?.vod_class)} ${text(raw?.type_name)} ${text(raw?.vod_type_id_name)}`;
  if (value.includes('漫剧')) return 'comic';
  if (value.includes('短剧')) return 'short';
  return '';
}

function normalizeCategory(value) {
  const category = String(value || 'all').trim().toLowerCase();
  if (category === 'all') return category;
  if (!allowedCategories.has(category)) throw new Error('suibian_category_invalid');
  return category;
}

async function sourceApi(params) {
  const url = new URL('/api.php/provide/vod/', config.suibianSourceOrigin);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, String(value));
  const response = await fetch(url, { headers: { Accept: 'application/json', 'User-Agent': 'SuibianKan/1.0' }, signal: AbortSignal.timeout(config.suibianSourceTimeoutMs) });
  if (!response.ok) throw new Error(`suibian_source_failed:${response.status}`);
  return response.json();
}

async function fetchText(url) {
  const response = await fetch(url, { headers: { Accept: 'text/html', 'User-Agent': 'SuibianKan/1.0' }, signal: AbortSignal.timeout(config.suibianSourceTimeoutMs) });
  if (!response.ok) throw new Error(`suibian_player_page_failed:${response.status}`);
  return response.text();
}

function hlsFromUrl(value) {
  try {
    const url = new URL(value);
    const nested = url.searchParams.get('url');
    const candidate = nested ? decodeURIComponent(nested) : url.toString();
    const parsed = new URL(candidate);
    return parsed.protocol === 'https:' && parsed.pathname.toLowerCase().endsWith('.m3u8') ? parsed.toString() : '';
  } catch { return ''; }
}

function safeSameOriginUrl(value) {
  try {
    const url = new URL(value, config.suibianSourceOrigin);
    const source = new URL(config.suibianSourceOrigin);
    return url.origin === source.origin && url.protocol === 'https:' ? url.toString() : '';
  } catch { return ''; }
}

function cached(key, loader) {
  const current = cache.get(key);
  const now = Date.now();
  if (current && current.expiresAt > now) return current.value;
  const value = Promise.resolve(loader());
  cache.set(key, { value, expiresAt: now + cacheTtlMs });
  value.catch(() => cache.delete(key));
  return value;
}

function text(value) { return String(value ?? '').trim(); }
function cleanText(value) { return text(value).replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim(); }
function number(value, fallback) { const parsed = Number(value); return Number.isFinite(parsed) && parsed > 0 ? Math.trunc(parsed) : fallback; }
