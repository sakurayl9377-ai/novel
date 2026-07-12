import { one, run } from "./db.js";
import {
  canonicalDanmakuVideoId,
  upsertDanmakuAlias,
  upsertDanmakuMeta,
} from "./routes-content.js";
import { hashPassword } from "./security.js";

const importEmail = "bilibili-danmaku@import.local";
const importNickname = "B站弹幕";
const headers = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
  Accept: "application/json, text/plain, */*",
  "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
  Referer: "https://www.bilibili.com/",
};
const searchCache = new Map();
const searchCacheTtlMs = 10 * 60 * 1000;
const searchCacheMaxEntries = 100;

export async function searchBilibiliBangumi(keyword) {
  const q = String(keyword || "").trim();
  if (!q) return { items: [] };
  const url =
    "https://api.bilibili.com/x/web-interface/search/type?" +
    new URLSearchParams({
      search_type: "media_bangumi",
      keyword: q,
    });
  const cacheKey = q.toLowerCase();
  const cached = searchCache.get(cacheKey);
  if (cached && Date.now() - cached.time < searchCacheTtlMs) {
    searchCache.delete(cacheKey);
    searchCache.set(cacheKey, cached);
    return { items: cached.items, cached: true };
  }
  if (cached) searchCache.delete(cacheKey);
  let json = null;
  let lastStatus = 0;
  for (const requestHeaders of bilibiliSearchHeaderVariants(q)) {
    const response = await fetch(url, { headers: requestHeaders });
    lastStatus = response.status;
    if (!response.ok) continue;
    json = await response.json();
    if (json?.code === 0) break;
    json = null;
  }
  if (!json) {
    if (cached?.items?.length) return { items: cached.items, cached: true, stale: true };
    const error = new Error(
      lastStatus === 412
        ? "B站搜索接口临时拒绝请求，请稍后再试"
        : `B站搜索失败：${lastStatus || "network"}`,
    );
    error.statusCode = 400;
    throw error;
  }
  const items = Array.isArray(json?.data?.result) ? json.data.result : [];
  const normalizedItems = items
    .map((item) => ({
      seasonId: Number(item.season_id || item.pgc_season_id || 0),
      mediaId: Number(item.media_id || 0),
      title: stripHtml(item.title || item.org_title || ""),
      subtitle: stripHtml(item.desc || item.index_show || ""),
      cover: item.cover || "",
      seasonType: item.season_type_name || "",
      areas: item.areas || "",
      styles: item.styles || "",
      pubtime: item.pubtime || "",
    }))
    .filter((item) => item.seasonId && item.title);
  setTimedCache(
    searchCache,
    cacheKey,
    { time: Date.now(), items: normalizedItems },
    searchCacheTtlMs,
    searchCacheMaxEntries,
  );
  return { items: normalizedItems };
}

function setTimedCache(cache, key, value, ttlMs, maxEntries) {
  const now = Date.now();
  for (const [entryKey, entry] of cache) {
    if (now - entry.time >= ttlMs) cache.delete(entryKey);
  }
  cache.delete(key);
  cache.set(key, value);
  while (cache.size > maxEntries) {
    cache.delete(cache.keys().next().value);
  }
}

function bilibiliSearchHeaderVariants(keyword) {
  const encoded = encodeURIComponent(keyword);
  const cookie =
    "buvid3=8D3B8A9A-69B9-4E4B-A712-9F733A71983618540infoc; " +
    "b_nut=1783519000; " +
    "b_lsid=843A10BB_197EABCDE12; " +
    "_uuid=165D9E7A-F275-71034-88A2-F9327773DFCC18540infoc";
  return [
    {
      ...headers,
      Referer: `https://search.bilibili.com/bangumi?keyword=${encoded}`,
      Origin: "https://search.bilibili.com",
      Cookie: cookie,
    },
    {
      ...headers,
      Referer: `https://m.bilibili.com/search?keyword=${encoded}`,
      Cookie: cookie,
      "User-Agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
    },
    headers,
  ];
}

export async function fetchBilibiliSeason(seasonId) {
  const id = Number(seasonId);
  if (!Number.isFinite(id) || id <= 0) {
    throw new Error("bilibili season id is invalid");
  }
  const url = `https://api.bilibili.com/pgc/view/web/season?season_id=${encodeURIComponent(
    String(id),
  )}`;
  const response = await fetch(url, { headers });
  if (!response.ok) {
    throw new Error(`bilibili_season_failed:${response.status}`);
  }
  const json = await response.json();
  const result = json?.result;
  const episodes = Array.isArray(result?.episodes) ? result.episodes : [];
  return {
    seasonId: id,
    title: result?.title || "",
    cover: result?.cover || "",
    evaluate: result?.evaluate || "",
    episodes: episodes
      .map((item, index) => ({
        index: index + 1,
        id: Number(item.id || 0),
        cid: Number(item.cid || 0),
        title: String(item.title || index + 1),
        longTitle: String(item.long_title || item.show_title || ""),
        displayTitle: [item.title, item.long_title || item.show_title]
          .filter(Boolean)
          .join(" "),
      }))
      .filter((item) => item.cid),
  };
}

export async function fetchBilibiliDanmaku(cid) {
  const numericCid = Number(cid);
  if (!Number.isFinite(numericCid) || numericCid <= 0) {
    throw new Error("bilibili cid is invalid");
  }
  const url = `https://comment.bilibili.com/${numericCid}.xml`;
  const response = await fetch(url, { headers });
  if (!response.ok) {
    throw new Error(`bilibili_danmaku_failed:${response.status}`);
  }
  const xml = await response.text();
  const items = [];
  const pattern = /<d\s+p="([^"]+)">([\s\S]*?)<\/d>/g;
  for (const match of xml.matchAll(pattern)) {
    const fields = match[1].split(",");
    const seconds = Number(fields[0]);
    if (!Number.isFinite(seconds) || seconds < 0) continue;
    const content = decodeHtml(match[2]).replace(/\s+/g, " ").trim();
    if (!content) continue;
    items.push({
      timeMs: Math.round(seconds * 1000),
      content: content.slice(0, 120),
      color: colorFromBili(fields[3]),
      mode: "scroll",
    });
  }
  items.sort((a, b) => a.timeMs - b.timeMs);
  return items;
}

export async function fetchBilibiliDanmakuSummary(cid) {
  const items = await fetchBilibiliDanmaku(cid);
  const maxTimeMs = items.length
    ? Math.max(...items.map((item) => item.timeMs))
    : 0;
  return {
    cid: Number(cid),
    total: items.length,
    maxTimeMs,
  };
}

export function uniformSampleDanmaku(items, limit) {
  const sorted = [...items].sort((a, b) => a.timeMs - b.timeMs);
  const count = Math.max(1, Math.trunc(Number(limit) || 0));
  if (sorted.length <= count) return sorted;
  const maxTime = Math.max(...sorted.map((item) => item.timeMs), 1);
  const selected = new Map();
  for (let bucket = 0; bucket < count; bucket += 1) {
    const start = Math.floor((bucket * maxTime) / count);
    const end = Math.floor(((bucket + 1) * maxTime) / count);
    const candidates = sorted.filter(
      (item) => item.timeMs >= start && item.timeMs < end,
    );
    if (!candidates.length) continue;
    const target = start + (end - start) / 2;
    candidates.sort(
      (a, b) => Math.abs(a.timeMs - target) - Math.abs(b.timeMs - target),
    );
    selected.set(candidates[0].timeMs + ":" + candidates[0].content, candidates[0]);
  }

  if (selected.size < count) {
    const remaining = count - selected.size;
    const step = (sorted.length - 1) / Math.max(remaining + 1, 1);
    for (let index = 1; selected.size < count && index <= remaining + 1; index += 1) {
      const item = sorted[Math.min(sorted.length - 1, Math.round(index * step))];
      selected.set(item.timeMs + ":" + item.content, item);
    }
  }

  if (selected.size < count) {
    for (const item of sorted) {
      selected.set(item.timeMs + ":" + item.content, item);
      if (selected.size >= count) break;
    }
  }

  return [...selected.values()]
    .sort((a, b) => a.timeMs - b.timeMs)
    .slice(0, count);
}

export async function syncBilibiliDanmakuToTarget({
  cid,
  limit = 800,
  replace = true,
  targetVideoId,
  targetAliases = [],
  animeId = "",
  animeTitle = "",
  episodeId = "",
  episodeTitle = "",
  sourceName = "Bilibili",
}) {
  const danmakuItems = await fetchBilibiliDanmaku(cid);
  const sampled = uniformSampleDanmaku(danmakuItems, limit);
  const importUserId = ensureImportUser();
  const canonicalVideoId = canonicalDanmakuVideoId({
    animeId: String(animeId || ""),
    episodeId: String(episodeId || episodeTitle || ""),
    fallback: String(targetVideoId || ""),
  });
  if (!canonicalVideoId) throw new Error("target video id is required");

  let deleted = 0;
  let inserted = 0;
  const aliases = [
    String(targetVideoId || canonicalVideoId),
    ...targetAliases.map((item) => String(item || "")),
  ].filter(Boolean);

  run("BEGIN IMMEDIATE");
  try {
    if (replace) {
      const result = run(
        `UPDATE danmaku
         SET status = 'deleted', deleted_at = datetime('now')
         WHERE video_id = ? AND user_id = ? AND status = 'visible'`,
        [canonicalVideoId, importUserId],
      );
      deleted = result.changes ?? 0;
    }

    for (const alias of aliases) {
      upsertDanmakuAlias({
        aliasVideoId: alias,
        canonicalVideoId,
        animeId,
        episodeId: episodeId || episodeTitle,
        sourceName,
      });
    }
    upsertDanmakuMeta({
      canonicalVideoId,
      animeId,
      animeTitle,
      episodeId: episodeId || episodeTitle,
      episodeTitle: episodeTitle || episodeId,
    });

    for (const item of sampled) {
      run(
        `INSERT INTO danmaku
         (user_id, video_id, anime_id, episode_id, time_ms, content, color, mode)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          importUserId,
          canonicalVideoId,
          animeId,
          episodeId || episodeTitle,
          item.timeMs,
          item.content,
          item.color,
          item.mode || "scroll",
        ],
      );
      inserted += 1;
    }
    run("COMMIT");
  } catch (error) {
    run("ROLLBACK");
    throw error;
  }

  return {
    ok: true,
    canonicalVideoId,
    sourceDanmakuCount: danmakuItems.length,
    sampledCount: sampled.length,
    inserted,
    deleted,
    aliases: aliases.length,
  };
}

function ensureImportUser() {
  const existing = one("SELECT id FROM users WHERE email = ?", [importEmail]);
  if (existing) return existing.id;
  const result = run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, 'user', 'active')`,
    [importEmail, importNickname, hashPassword(`${Date.now()}-${Math.random()}`)],
  );
  return Number(result.lastInsertRowid);
}

function colorFromBili(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return "#FFFFFF";
  return `#${Math.trunc(numeric).toString(16).padStart(6, "0").slice(-6).toUpperCase()}`;
}

function decodeHtml(value) {
  return String(value)
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) =>
      String.fromCodePoint(Number.parseInt(code, 16)),
    )
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function stripHtml(value) {
  return decodeHtml(String(value || "").replace(/<[^>]*>/g, "")).trim();
}
