import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';

const HIDDEN_CATEGORY_IDS = new Set([34, 35, 36]);
const SHORT_CATEGORY_IDS = new Set([37, 43, 44, 45, 46, 47, 48, 49]);
const HOME_CATEGORY_IDS = [1, 2, 4, 3];
const state = {
  loaded: false,
  categories: [],
  items: new Map(),
  categoryPages: new Map(),
  expiresAt: 0,
  loadPromise: null,
  refreshPromise: null,
  lastRequestAt: 0,
  requestTail: Promise.resolve(),
  lastSuccessAt: null,
  lastError: null,
};

export async function getDbzyCategories() {
  await ensureCache();
  if (!state.categories.length) {
    const payload = await requestUpstream({});
    ingestPayload(payload);
    await persistCache();
  }
  const visible = state.categories.filter((item) => !HIDDEN_CATEGORY_IDS.has(item.id));
  return {
    items: visible.filter((item) => item.parentId === 0).map((root) => ({
      ...root,
      children: visible.filter((item) => item.parentId === root.id),
    })),
    hiddenCategoryIds: [...HIDDEN_CATEGORY_IDS],
  };
}

export async function getDbzyMovieHome({ sectionSize = 12 } = {}) {
  await ensureFresh();
  const categories = await getDbzyCategories();
  const sections = [];
  for (const categoryId of HOME_CATEGORY_IDS) {
    const category = findCategory(categoryId);
    if (!category) continue;
    const result = await listDbzyMovies({ categoryId, page: 1, pageSize: sectionSize });
    sections.push({ id: `category-${categoryId}`, title: category.name, categoryId, items: result.items });
  }
  return { categories: categories.items, sections };
}

export async function listDbzyMovies({ categoryId, page = 1, pageSize = 20 } = {}) {
  await ensureCache();
  const id = safeCategoryId(categoryId);
  if (HIDDEN_CATEGORY_IDS.has(id) || SHORT_CATEGORY_IDS.has(id)) return paginate([], page, pageSize);
  await fetchCategoryPage(id, page);
  return paginate(itemsForCategory(id), page, pageSize);
}

export async function getDbzyItem(id) {
  await ensureCache();
  const numericId = parseDbzyId(id);
  if (!numericId) return null;
  let item = state.items.get(numericId);
  if (!item?.episodes?.length) {
    const payload = await requestUpstream({ ac: 'detail', ids: numericId });
    ingestPayload(payload);
    await persistCache();
    item = state.items.get(numericId);
  }
  return item && !HIDDEN_CATEGORY_IDS.has(item.categoryId) ? clone(item) : null;
}

export function withoutDbzyPlayback(item) {
  if (!item) return null;
  return {
    ...clone(item),
    episodes: item.episodes.map((episode) => ({
      index: episode.index,
      title: episode.title,
      sourceCount: episode.candidates.length,
    })),
  };
}

export async function searchDbzyCache(query, { page = 1, pageSize = 20 } = {}) {
  await ensureFresh();
  const q = cleanText(query).toLocaleLowerCase();
  if (!q) return paginate([], page, pageSize);
  const matches = [...state.items.values()].filter((item) => !HIDDEN_CATEGORY_IDS.has(item.categoryId) && [
    item.title, item.summary, item.actor, item.director, item.categoryName, ...item.tags,
  ].some((value) => cleanText(value).toLocaleLowerCase().includes(q)));
  return paginate(matches.map(withoutPlayback), page, pageSize);
}

export async function getDbzyShortFeed({ categoryId = 37, pageSize = 12 } = {}) {
  await ensureCache();
  const id = safeCategoryId(categoryId);
  if (!SHORT_CATEGORY_IDS.has(id)) throw sourceError('dbzy_short_category_invalid', 400);
  await fetchCategoryPage(id, randomPageForCategory(id));
  const pool = itemsForCategory(id).filter((item) => item.episodes.length);
  return { items: shuffle(pool).slice(0, clamp(pageSize, 1, 30)).map(withoutPlayback), hasMore: true };
}

export async function resolveDbzyPlayback(id, episodeIndex) {
  const item = await getDbzyItem(id);
  const episode = item?.episodes?.[Number(episodeIndex)];
  return episode ? clone(episode) : null;
}

export async function getDbzyStatus() {
  await ensureCache();
  return {
    enabled: config.dbzyEnabled,
    itemCount: state.items.size,
    categoryCount: state.categories.length,
    expiresAt: state.expiresAt ? new Date(state.expiresAt).toISOString() : null,
    lastSuccessAt: state.lastSuccessAt,
    lastError: state.lastError,
  };
}

async function ensureFresh() {
  await ensureCache();
  if (Date.now() >= state.expiresAt) await refreshIncremental();
}

async function ensureCache() {
  if (state.loaded) return;
  if (state.loadPromise) return state.loadPromise;
  state.loadPromise = (async () => {
    try {
      const raw = JSON.parse(await readFile(config.dbzyCacheFile, 'utf8'));
      state.categories = normalizeCategories(raw.categories);
      for (const item of Array.isArray(raw.items) ? raw.items : []) {
        const normalized = normalizeVod(item, { normalized: true });
        if (normalized) state.items.set(parseDbzyId(normalized.id), normalized);
      }
      state.expiresAt = Number(raw.expiresAt) || 0;
    } catch {
      state.expiresAt = 0;
    } finally {
      state.loaded = true;
      state.loadPromise = null;
    }
  })();
  return state.loadPromise;
}

async function refreshIncremental() {
  if (!config.dbzyEnabled) return;
  if (state.refreshPromise) return state.refreshPromise;
  state.refreshPromise = (async () => {
    try {
      const maxPages = clamp(config.dbzyIncrementalMaxPages, 1, 100);
      for (let page = 1; page <= maxPages; page += 1) {
        const payload = await requestUpstream({ ac: 'detail', h: config.dbzyIncrementalHours, pg: page });
        ingestPayload(payload);
        if (page >= Number(payload.pagecount || 1)) break;
      }
      state.expiresAt = Date.now() + positive(config.dbzyCacheTtlMs, 600000);
      state.lastSuccessAt = new Date().toISOString();
      state.lastError = null;
      await persistCache();
    } catch (error) {
      state.lastError = { code: error.publicCode || 'dbzy_upstream_error', at: new Date().toISOString() };
      if (!state.items.size) throw error;
    } finally {
      state.refreshPromise = null;
    }
  })();
  return state.refreshPromise;
}

async function fetchCategoryPage(categoryId, page) {
  const key = `${categoryId}:${page}`;
  const cachedUntil = state.categoryPages.get(key) || 0;
  if (cachedUntil > Date.now()) return;
  const payload = await requestUpstream({ ac: 'detail', t: categoryId, pg: page });
  ingestPayload(payload);
  state.categoryPages.set(key, Date.now() + positive(config.dbzyCacheTtlMs, 600000));
  state.expiresAt = Math.max(state.expiresAt, Date.now() + positive(config.dbzyCacheTtlMs, 600000));
  await persistCache();
}

async function requestUpstream(params) {
  if (!config.dbzyEnabled) throw sourceError('dbzy_disabled', 503);
  const run = async () => {
    const waitMs = positive(config.dbzyMinRequestIntervalMs, 350) - (Date.now() - state.lastRequestAt);
    if (waitMs > 0) await new Promise((resolve) => setTimeout(resolve, waitMs));
    state.lastRequestAt = Date.now();
    const url = new URL(config.dbzyBaseUrl);
    for (const [key, value] of Object.entries(params)) if (value !== '' && value != null) url.searchParams.set(key, value);
    let response;
    try {
      response = await fetch(url, {
        headers: { Accept: 'application/json', 'User-Agent': 'SuibianKanBackend/1.0' },
        redirect: 'error',
        signal: AbortSignal.timeout(positive(config.dbzyTimeoutMs, 8000)),
      });
    } catch (error) {
      throw sourceError(error?.name === 'TimeoutError' ? 'dbzy_timeout' : 'dbzy_network_error', 502);
    }
    if (!response.ok) throw sourceError('dbzy_upstream_error', 502, response.status);
    const declared = Number(response.headers.get('content-length'));
    const maxBytes = positive(config.dbzyMaxBytes, 8 * 1024 * 1024);
    if (Number.isFinite(declared) && declared > maxBytes) throw sourceError('dbzy_response_too_large', 502);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > maxBytes) throw sourceError('dbzy_response_too_large', 502);
    try {
      const value = JSON.parse(bytes.toString('utf8'));
      if (Number(value.code) !== 1 || !Array.isArray(value.list)) throw new Error('shape');
      return value;
    } catch {
      throw sourceError('dbzy_invalid_response', 502);
    }
  };
  const result = state.requestTail.then(run, run);
  state.requestTail = result.catch(() => {});
  return result;
}

function ingestPayload(payload) {
  if (Array.isArray(payload.class) && payload.class.length) state.categories = normalizeCategories(payload.class);
  for (const raw of payload.list || []) {
    const item = normalizeVod(raw);
    if (!item || HIDDEN_CATEGORY_IDS.has(item.categoryId)) continue;
    const numericId = parseDbzyId(item.id);
    const previous = state.items.get(numericId);
    state.items.set(numericId, item.episodes.length || !previous ? item : { ...previous, ...item, episodes: previous.episodes });
  }
}

export function normalizeVod(raw, options = {}) {
  if (!raw || typeof raw !== 'object') return null;
  if (options.normalized && String(raw.id || '').startsWith('dbzy:')) return normalizeStoredVod(raw);
  const numericId = Number(raw.vod_id);
  const categoryId = Number(raw.type_id);
  const title = cleanText(raw.vod_name).slice(0, 200);
  if (!Number.isInteger(numericId) || numericId <= 0 || !title || !Number.isInteger(categoryId)) return null;
  const episodes = parsePlaylists(raw.vod_play_from, raw.vod_play_url);
  return {
    id: `dbzy:${numericId}`,
    source: 'dbzy',
    title,
    category: SHORT_CATEGORY_IDS.has(categoryId) ? 'short' : 'movie',
    categoryId,
    categoryName: cleanText(raw.type_name),
    summary: cleanHtml(raw.vod_content || raw.vod_blurb).slice(0, 3000),
    remarks: cleanText(raw.vod_remarks).slice(0, 100),
    year: cleanText(raw.vod_year).slice(0, 10),
    area: cleanText(raw.vod_area).slice(0, 50),
    language: cleanText(raw.vod_lang).slice(0, 50),
    actor: cleanText(raw.vod_actor).slice(0, 500),
    director: cleanText(raw.vod_director).slice(0, 300),
    tags: splitTags(raw.vod_class || raw.vod_tag),
    coverUrl: normalizeImage(raw.vod_pic),
    thumbUrl: normalizeImage(raw.vod_pic_thumb || raw.vod_pic),
    slideUrl: normalizeImage(raw.vod_pic_slide),
    screenshots: String(raw.vod_pic_screenshot || '').split(/[$,]/).map(normalizeImage).filter(Boolean).slice(0, 12),
    updatedAt: cleanText(raw.vod_time),
    episodeCount: episodes.length || Math.max(0, Number(raw.vod_total) || 0),
    episodes,
  };
}

function normalizeStoredVod(raw) {
  const numericId = parseDbzyId(raw.id);
  if (!numericId) return null;
  const episodes = (Array.isArray(raw.episodes) ? raw.episodes : []).map((episode, index) => ({
    index,
    title: cleanText(episode.title) || `第${index + 1}集`,
    candidates: (Array.isArray(episode.candidates) ? episode.candidates : []).map((candidate) => ({
      name: cleanText(candidate.name).slice(0, 50) || '线路', hlsUrl: normalizeHls(candidate.hlsUrl),
    })).filter((candidate) => candidate.hlsUrl),
  })).filter((episode) => episode.candidates.length);
  return { ...raw, id: `dbzy:${numericId}`, episodes, episodeCount: episodes.length || Number(raw.episodeCount) || 0 };
}

export function parsePlaylists(playFrom, playUrl) {
  const sourceNames = String(playFrom || '').split('$$$');
  const sourceGroups = String(playUrl || '').split('$$$');
  const episodes = [];
  const episodeKeys = new Map();
  sourceGroups.forEach((group, sourceIndex) => {
    const sourceName = cleanText(sourceNames[sourceIndex]) || `线路${sourceIndex + 1}`;
    for (const entry of group.split('#')) {
      const separator = entry.indexOf('$');
      if (separator <= 0) continue;
      const title = cleanText(entry.slice(0, separator)) || `第${episodes.length + 1}集`;
      const hlsUrl = normalizeHls(entry.slice(separator + 1));
      if (!hlsUrl) continue;
      const key = title.toLocaleLowerCase();
      let episodeIndex = episodeKeys.get(key);
      if (episodeIndex == null) {
        episodeIndex = episodes.length;
        episodeKeys.set(key, episodeIndex);
        episodes.push({ index: episodeIndex, title, candidates: [] });
      }
      const candidates = episodes[episodeIndex].candidates;
      if (!candidates.some((candidate) => candidate.hlsUrl === hlsUrl)) candidates.push({ name: sourceName, hlsUrl });
    }
  });
  return episodes;
}

function normalizeCategories(raw) {
  return (Array.isArray(raw) ? raw : []).map((item) => ({
    id: Number(item.id ?? item.type_id),
    parentId: Number(item.parentId ?? item.type_pid) || 0,
    name: cleanText(item.name ?? item.type_name).slice(0, 50),
  })).filter((item) => Number.isInteger(item.id) && item.id > 0 && item.name);
}

function withoutPlayback(item) {
  const { episodes, actor, director, screenshots, ...summary } = item;
  return { ...summary, episodeCount: episodes.length || item.episodeCount || 0 };
}

function itemsForCategory(categoryId) {
  const childIds = new Set([categoryId, ...state.categories.filter((item) => item.parentId === categoryId).map((item) => item.id)]);
  return [...state.items.values()].filter((item) => childIds.has(item.categoryId) && !HIDDEN_CATEGORY_IDS.has(item.categoryId))
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
}

function randomPageForCategory(categoryId) {
  const known = itemsForCategory(categoryId).length;
  return 1 + Math.floor(Math.random() * Math.max(1, Math.min(20, Math.ceil(known / 20) + 3)));
}

async function persistCache() {
  const file = config.dbzyCacheFile;
  const temp = `${file}.${process.pid}.tmp`;
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(temp, JSON.stringify({ version: 1, expiresAt: state.expiresAt, categories: state.categories, items: [...state.items.values()] }), 'utf8');
  await rename(temp, file);
}

function findCategory(id) { return state.categories.find((item) => item.id === id); }
function parseDbzyId(value) { const match = String(value || '').match(/^(?:dbzy:)?(\d+)$/); return match ? Number(match[1]) : 0; }
function safeCategoryId(value) { const id = Number(value); if (!Number.isInteger(id) || id <= 0) throw sourceError('dbzy_category_invalid', 400); return id; }
function normalizeHls(value) { try { const url = new URL(String(value || '').trim()); return url.protocol === 'https:' && url.pathname.toLowerCase().endsWith('.m3u8') ? url.toString() : ''; } catch { return ''; } }
function normalizeImage(value) { try { const url = new URL(String(value || '').trim()); if (url.protocol === 'http:') url.protocol = 'https:'; return url.protocol === 'https:' ? url.toString() : ''; } catch { return ''; } }
function splitTags(value) { return String(value || '').split(/[,，/|]/).map(cleanText).filter(Boolean).slice(0, 12); }
function cleanHtml(value) { return cleanText(String(value || '').replace(/<br\s*\/?\s*>/gi, '\n').replace(/<[^>]+>/g, ' ')); }
function cleanText(value) { return String(value ?? '').replace(/\s+/g, ' ').trim(); }
function positive(value, fallback) { const n = Number(value); return Number.isFinite(n) && n > 0 ? Math.trunc(n) : fallback; }
function clamp(value, min, max) { return Math.min(max, Math.max(min, positive(value, min))); }
function paginate(items, page, pageSize) { const p = positive(page, 1); const size = clamp(pageSize, 1, 50); const start = (p - 1) * size; return { items: items.slice(start, start + size), page: p, pageSize: size, hasMore: start + size < items.length }; }
function shuffle(items) { const result = [...items]; for (let i = result.length - 1; i > 0; i -= 1) { const j = Math.floor(Math.random() * (i + 1)); [result[i], result[j]] = [result[j], result[i]]; } return result; }
function clone(value) { return structuredClone(value); }
function sourceError(code, statusCode, upstreamStatus = null) { const error = new Error(code); error.publicCode = code; error.statusCode = statusCode; error.upstreamStatus = upstreamStatus; return error; }

export const dbzyInternals = { HIDDEN_CATEGORY_IDS, SHORT_CATEGORY_IDS };
