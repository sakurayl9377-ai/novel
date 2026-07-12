import { access, readFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { config } from './config.js';

const allowedCategories = new Set(['comic', 'short']);

let catalogCache = null;
let catalogLoadPromise = null;
const runtimeStatus = {
  lastSuccessAt: null,
  lastError: null,
};

export async function listSuibianContent({ category = 'all', page = 1, pageSize = 18 } = {}) {
  const normalizedCategory = normalizeCategory(category);
  const catalog = await loadCatalog();
  const matching = normalizedCategory === 'all'
    ? catalog.items
    : catalog.items.filter((item) => item.category === normalizedCategory);
  return paginate(matching.map(withoutEpisodes), page, pageSize);
}

export async function searchSuibianContent(query, { page = 1, pageSize = 18 } = {}) {
  const q = cleanText(query).toLocaleLowerCase();
  if (!q) return { items: [], page, pageSize, hasMore: false };
  const catalog = await loadCatalog();
  const matching = catalog.items.filter((item) => [
    item.title,
    item.summary,
    item.status,
    ...item.tags,
  ].some((value) => value.toLocaleLowerCase().includes(q)));
  return paginate(matching.map(withoutEpisodes), page, pageSize);
}

export async function getSuibianDrama(id) {
  const dramaId = cleanText(id);
  if (!dramaId) return null;
  const catalog = await loadCatalog();
  return catalog.items.find((item) => item.id === dramaId) || null;
}

export async function resolveSuibianPlayback(id, episodeIndex) {
  const drama = await getSuibianDrama(id);
  const episode = drama?.episodes?.[episodeIndex];
  return episode ? {
    index: episode.index,
    title: episode.title,
    candidates: episode.sources.map((source) => ({ ...source })),
  } : null;
}

export async function getSuibianStatus() {
  const source = await selectCatalogSource();
  return {
    configured: source.mode !== 'unconfigured',
    mode: source.mode,
    cache: {
      loaded: Boolean(catalogCache),
      itemCount: catalogCache?.value?.items?.length || 0,
      expiresAt: catalogCache ? new Date(catalogCache.expiresAt).toISOString() : null,
    },
    lastSuccessAt: runtimeStatus.lastSuccessAt,
    lastError: runtimeStatus.lastError ? { ...runtimeStatus.lastError } : null,
  };
}

async function loadCatalog() {
  const now = Date.now();
  if (catalogCache && catalogCache.expiresAt > now) return catalogCache.value;
  if (catalogLoadPromise) return catalogLoadPromise;

  catalogLoadPromise = loadFreshCatalog()
    .finally(() => {
      catalogLoadPromise = null;
    });
  return catalogLoadPromise;
}

async function loadFreshCatalog() {
  const source = await selectCatalogSource();
  if (source.mode === 'unconfigured') {
    throw rememberError(catalogError('suibian_catalog_not_configured', 503), source.mode);
  }

  try {
    const raw = source.mode === 'file'
      ? await loadFileCatalog(source.file)
      : await loadRemoteCatalog(source.url);
    const value = normalizeCatalog(raw);
    const now = Date.now();
    catalogCache = {
      value,
      expiresAt: now + positiveNumber(config.suibianCatalogCacheTtlMs, 300000),
    };
    runtimeStatus.lastSuccessAt = new Date(now).toISOString();
    return value;
  } catch (error) {
    throw rememberError(normalizeCatalogLoadError(error, source.mode), source.mode);
  }
}

async function selectCatalogSource() {
  if (config.suibianCatalogFile && await readable(config.suibianCatalogFile)) {
    return { mode: 'file', file: config.suibianCatalogFile };
  }
  if (isHttpsUrl(config.suibianCatalogUrl)) {
    return { mode: 'remote', url: config.suibianCatalogUrl };
  }
  return { mode: 'unconfigured' };
}

async function loadFileCatalog(file) {
  const maxBytes = positiveNumber(config.suibianCatalogMaxBytes, 5 * 1024 * 1024);
  const body = await readFile(file);
  if (body.byteLength > maxBytes) throw catalogError('suibian_catalog_too_large', 503);
  return parseJson(body.toString('utf8'), 503);
}

async function loadRemoteCatalog(url) {
  let response;
  try {
    const headers = { Accept: 'application/json', 'User-Agent': 'SuibianKanBackend/1.0' };
    if (config.suibianCatalogToken) {
      headers.Authorization = `Bearer ${config.suibianCatalogToken}`;
    }
    response = await fetch(url, {
      headers,
      redirect: 'error',
      signal: AbortSignal.timeout(positiveNumber(config.suibianCatalogTimeoutMs, 8000)),
    });
  } catch (error) {
    const code = error?.name === 'TimeoutError' || error?.name === 'AbortError'
      ? 'suibian_catalog_timeout'
      : 'suibian_catalog_network_error';
    throw catalogError(code, 502);
  }

  if (!response.ok) {
    throw catalogError('suibian_catalog_upstream_error', 502, response.status);
  }

  const maxBytes = positiveNumber(config.suibianCatalogMaxBytes, 5 * 1024 * 1024);
  const declaredBytes = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredBytes) && declaredBytes > maxBytes) {
    throw catalogError('suibian_catalog_too_large', 502);
  }
  const body = await readLimitedResponse(response, maxBytes);
  return parseJson(body.toString('utf8'), 502);
}

async function readLimitedResponse(response, maxBytes) {
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel();
        throw catalogError('suibian_catalog_too_large', 502);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, totalBytes);
}

function normalizeCatalog(raw) {
  const sourceItems = Array.isArray(raw) ? raw : raw?.items;
  if (!Array.isArray(sourceItems)) throw catalogError('suibian_catalog_invalid_shape', 503);

  const seen = new Set();
  const items = sourceItems.map(normalizeDrama).filter((item) => {
    if (!item || seen.has(item.id)) return false;
    seen.add(item.id);
    return true;
  });
  return {
    version: cleanText(raw?.version),
    updatedAt: cleanText(raw?.updatedAt),
    items,
  };
}

function normalizeDrama(raw) {
  const id = cleanText(raw?.id).slice(0, 100);
  const title = cleanText(raw?.title).slice(0, 200);
  const category = cleanText(raw?.category).toLowerCase();
  if (!id || !title || !allowedCategories.has(category)) return null;

  const episodes = (Array.isArray(raw?.episodes) ? raw.episodes : [])
    .map(normalizeEpisode)
    .filter(Boolean)
    .map((episode, index) => ({ ...episode, index }));
  if (episodes.length === 0) return null;

  return {
    id,
    title,
    category,
    summary: cleanText(raw?.summary).slice(0, 2000),
    status: cleanText(raw?.status).slice(0, 100),
    tags: (Array.isArray(raw?.tags) ? raw.tags : [])
      .map((tag) => cleanText(tag).slice(0, 30))
      .filter(Boolean)
      .slice(0, 8),
    // The app generates its own title-based visual cover.
    coverUrl: '',
    episodes,
  };
}

function normalizeEpisode(raw, sourceIndex) {
  const rawSources = Array.isArray(raw?.sources) ? [...raw.sources] : [];
  if (raw?.hlsUrl) {
    rawSources.push({ name: raw?.sourceName || '默认线路', hlsUrl: raw.hlsUrl });
  }
  const seen = new Set();
  const sources = rawSources
    .map(normalizeSource)
    .filter((source) => {
      if (!source || seen.has(source.hlsUrl)) return false;
      seen.add(source.hlsUrl);
      return true;
    });
  if (sources.length === 0) return null;
  return {
    title: cleanText(raw?.title).slice(0, 100) || `第 ${sourceIndex + 1} 集`,
    sources,
  };
}

function normalizeSource(raw, sourceIndex) {
  const hlsUrl = normalizeHlsUrl(raw?.hlsUrl);
  if (!hlsUrl) return null;
  return {
    name: cleanText(raw?.name).slice(0, 50) || `线路 ${sourceIndex + 1}`,
    hlsUrl,
  };
}

function normalizeHlsUrl(value) {
  try {
    const url = new URL(cleanText(value));
    return url.protocol === 'https:' && url.pathname.toLowerCase().endsWith('.m3u8')
      ? url.toString()
      : '';
  } catch {
    return '';
  }
}

function paginate(items, page, pageSize) {
  const safePage = positiveNumber(page, 1);
  const safePageSize = positiveNumber(pageSize, 18);
  const start = (safePage - 1) * safePageSize;
  return {
    items: items.slice(start, start + safePageSize),
    page: safePage,
    pageSize: safePageSize,
    hasMore: start + safePageSize < items.length,
  };
}

function withoutEpisodes(item) {
  const { episodes, ...summary } = item;
  return { ...summary, episodeCount: episodes.length };
}

function parseJson(value, statusCode) {
  try {
    return JSON.parse(value);
  } catch {
    throw catalogError('suibian_catalog_invalid_json', statusCode);
  }
}

function normalizeCatalogLoadError(error, mode) {
  if (error?.statusCode) {
    if (mode === 'remote' && error.statusCode !== 502) error.statusCode = 502;
    return error;
  }
  return catalogError(
    mode === 'remote' ? 'suibian_catalog_upstream_error' : 'suibian_catalog_file_error',
    mode === 'remote' ? 502 : 503,
  );
}

function rememberError(error, mode) {
  runtimeStatus.lastError = {
    mode,
    code: error.publicCode || 'suibian_catalog_error',
    upstreamStatus: Number.isInteger(error.upstreamStatus) ? error.upstreamStatus : null,
    at: new Date().toISOString(),
  };
  return error;
}

function catalogError(code, statusCode, upstreamStatus = null) {
  const error = new Error(code);
  error.statusCode = statusCode;
  error.publicCode = code;
  error.upstreamStatus = upstreamStatus;
  return error;
}

async function readable(file) {
  try {
    await access(file, fsConstants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function isHttpsUrl(value) {
  try {
    return new URL(value).protocol === 'https:';
  } catch {
    return false;
  }
}

function normalizeCategory(value) {
  const category = cleanText(value || 'all').toLowerCase();
  if (category === 'all') return category;
  if (!allowedCategories.has(category)) throw catalogError('suibian_category_invalid', 400);
  return category;
}

function cleanText(value) {
  return String(value ?? '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
}

function positiveNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.trunc(parsed) : fallback;
}
