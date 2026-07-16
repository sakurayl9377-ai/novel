import { all, one, run } from "./db.js";
import { grantReward } from "./rewards.js";
import { enforceRateLimits } from "./rate-limit.js";
import { resolveVideoCover } from "./video-cover-resolver.js";
import { ensureWenku8Cover } from "./wenku8-cover-cache.js";
import { createReadStream } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import { config } from "./config.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  rating as parseRating,
  reportTargetType,
  requiredString,
  targetType as parseTargetType,
} from "./validators.js";

const autoBilibiliCache = new Map();
const autoBilibiliCacheTtlMs = 10 * 60 * 1000;
const autoBilibiliCacheMaxEntries = 16;

export async function contentRoutes(app) {
  app.get("/video-covers/resolve", async (request, reply) => {
    const limited = enforceRateLimits(request, reply, [
      {
        scope: "video_cover_resolve",
        key: request.ip,
        limit: 120,
        windowMs: 5 * 60 * 1000,
        error: "video_cover_rate_limited",
      },
    ]);
    if (limited) return limited;
    const query = request.query || {};
    const result = await resolveVideoCover({
      sourceKey: optionalString(query.source, 40) || "wuhandky",
      itemKey: requiredString(query.itemKey, "itemKey", 500),
      title: requiredString(query.title, "title", 200),
      year: optionalString(query.year, 10),
      candidateUrl: optionalString(query.candidateUrl, 1000),
    });
    if (result.coverUrl.startsWith('/')) {
      const host = String(request.headers.host || request.hostname || '').replace(/[^a-zA-Z0-9.:[\]-]/g, '');
      result.coverUrl = `${request.protocol}://${host}${config.apiPrefix}${result.coverUrl}`;
    }
    return result;
  });

  app.get('/video-covers/files/:file', async (request, reply) => {
    const file = String(request.params?.file || '');
    if (!/^[a-f0-9]{64}\.(?:gif|jpe?g|png|webp)$/i.test(file)) {
      return reply.code(404).send({ error: 'not_found' });
    }
    const extension = path.extname(file).toLowerCase();
    const mime = extension === '.png' ? 'image/png' : extension === '.webp' ? 'image/webp' : extension === '.gif' ? 'image/gif' : 'image/jpeg';
    const filePath = path.join(config.videoCoverDir, file);
    try {
      await access(filePath);
    } catch {
      return reply.code(404).send({ error: 'not_found' });
    }
    return reply.type(mime).header('Cache-Control', 'public, max-age=31536000, immutable').send(
      createReadStream(filePath),
    );
  });

  app.get('/novel-covers/wenku8/:bookId', async (request, reply) => {
    const limited = enforceRateLimits(request, reply, [
      {
        scope: 'wenku8_cover_ip',
        key: request.ip || 'unknown',
        limit: 180,
        windowMs: 5 * 60 * 1000,
        error: 'wenku8_cover_rate_limited',
      },
    ]);
    if (limited) return limited;

    try {
      const filePath = await ensureWenku8Cover(request.params?.bookId);
      return reply
        .type('image/jpeg')
        .header('Cache-Control', 'public, max-age=31536000, immutable')
        .send(createReadStream(filePath));
    } catch (error) {
      if (error?.message === 'wenku8_cover_book_id_invalid') {
        return reply.code(404).send({ error: 'not_found' });
      }
      request.log?.warn?.({ error }, 'wenku8 cover mirror failed');
      return reply.code(502).send({ error: 'wenku8_cover_unavailable' });
    }
  });

  app.get("/comments", async (request) => {
    const query = request.query || {};
    const targetType = parseTargetType(query.targetType || query.type);
    const targetId = requiredString(query.targetId, "targetId", 200);
    const chapterId = optionalString(query.chapterId, 200);
    const episodeId = optionalString(query.episodeId, 200);
    const sort = optionalString(query.sort, 20) || "latest";
    const { page, pageSize, offset } = pageParams(query);
    const orderBy =
      sort === "hot"
        ? "c.like_count DESC, c.reply_count DESC, c.created_at DESC"
        : "c.created_at DESC";

    const params = [
      targetType,
      targetId,
      chapterId,
      episodeId,
      pageSize,
      offset,
    ];
    const items = all(
      `SELECT c.*, u.nickname, u.avatar_url
       FROM comments c
       JOIN users u ON u.id = c.user_id
       WHERE c.parent_id IS NULL
         AND c.target_type = ?
         AND c.target_id = ?
         AND c.chapter_id = ?
         AND c.episode_id = ?
         AND c.status = 'visible'
       ORDER BY ${orderBy}
       LIMIT ? OFFSET ?`,
      params,
    ).map(commentJson);

    return { page, pageSize, items };
  });

  app.get("/comments/summary", async (request) => {
    const query = request.query || {};
    const targetType = parseTargetType(query.targetType || query.type);
    const targetId = requiredString(query.targetId, "targetId", 200);
    const chapterId = optionalString(query.chapterId, 200);
    const episodeId = optionalString(query.episodeId, 200);
    const sort = optionalString(query.sort, 20) || "hot";
    const previewSize = Math.max(
      1,
      Math.min(5, optionalInt(query.previewSize, 2)),
    );
    const orderBy =
      sort === "latest"
        ? "c.created_at DESC"
        : "c.like_count DESC, c.reply_count DESC, c.created_at DESC";

    const summary = one(
      `SELECT
         COUNT(*) AS comment_count,
         COUNT(DISTINCT user_id) AS user_count,
         COALESCE(SUM(reply_count), 0) AS reply_count,
         ROUND(AVG(rating), 1) AS rating_avg,
         MAX(created_at) AS last_created_at
       FROM comments
       WHERE parent_id IS NULL
         AND target_type = ?
         AND target_id = ?
         AND chapter_id = ?
         AND episode_id = ?
         AND status = 'visible'`,
      [targetType, targetId, chapterId, episodeId],
    );
    const items = all(
      `SELECT c.*, u.nickname, u.avatar_url
       FROM comments c
       JOIN users u ON u.id = c.user_id
       WHERE c.parent_id IS NULL
         AND c.target_type = ?
         AND c.target_id = ?
         AND c.chapter_id = ?
         AND c.episode_id = ?
         AND c.status = 'visible'
       ORDER BY ${orderBy}
       LIMIT ?`,
      [targetType, targetId, chapterId, episodeId, previewSize],
    ).map(commentJson);

    return {
      summary: {
        targetType,
        targetId,
        chapterId,
        episodeId,
        commentCount: summary?.comment_count || 0,
        userCount: summary?.user_count || 0,
        replyCount: summary?.reply_count || 0,
        ratingAvg: summary?.rating_avg ?? null,
        lastCreatedAt: summary?.last_created_at || "",
      },
      items,
    };
  });

  app.get("/comments/:id/replies", async (request) => {
    const id = optionalInt(request.params.id);
    if (!id) throw badRequest("comment id is invalid");
    const { page, pageSize, offset } = pageParams(request.query || {});
    const items = all(
      `SELECT c.*, u.nickname, u.avatar_url
       FROM comments c
       JOIN users u ON u.id = c.user_id
       WHERE c.parent_id = ? AND c.status = 'visible'
       ORDER BY c.created_at ASC
       LIMIT ? OFFSET ?`,
      [id, pageSize, offset],
    ).map(commentJson);
    return { page, pageSize, items };
  });

  app.post("/comments", { preHandler: app.authRequired }, async (request) => {
    const body = request.body || {};
    const targetType = parseTargetType(body.targetType || body.type);
    const targetId = requiredString(body.targetId, "targetId", 200);
    const chapterId = optionalString(body.chapterId, 200);
    const episodeId = optionalString(body.episodeId, 200);
    const targetTitle = optionalString(body.targetTitle, 200);
    const chapterTitle = optionalString(body.chapterTitle, 200) || chapterId;
    const episodeTitle = optionalString(body.episodeTitle, 200) || episodeId;
    const parentId = optionalInt(body.parentId, 0) || null;
    const content = requiredString(body.content, "content", 2000);
    const rating = parseRating(body.rating);

    if (parentId) {
      const parent = one(
        `SELECT id, parent_id, target_type, target_id, chapter_id, episode_id
         FROM comments
         WHERE id = ? AND status = 'visible'`,
        [parentId],
      );
      if (!parent) throw badRequest("parent comment not found");
      if (parent.parent_id != null) {
        throw badRequest("nested_comment_reply_not_allowed");
      }
      if (
        parent.target_type !== targetType ||
        parent.target_id !== targetId ||
        parent.chapter_id !== chapterId ||
        parent.episode_id !== episodeId
      ) {
        throw badRequest("parent_comment_target_mismatch");
      }
    }

    const result = run(
      `INSERT INTO comments
       (user_id, parent_id, target_type, target_id, chapter_id, episode_id, rating, content)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        request.user.id,
        parentId,
        targetType,
        targetId,
        chapterId,
        episodeId,
        rating,
        content,
      ],
    );
    upsertCommentTargetMeta({
      targetType,
      targetId,
      targetTitle,
      chapterId,
      chapterTitle,
      episodeId,
      episodeTitle,
    });
    if (parentId) {
      run(
        `UPDATE comments
         SET reply_count = reply_count + 1, updated_at = datetime('now')
         WHERE id = ?`,
        [parentId],
      );
    }

    const comment = one(
      `SELECT c.*, u.nickname, u.avatar_url
       FROM comments c
       JOIN users u ON u.id = c.user_id
       WHERE c.id = ?`,
      [Number(result.lastInsertRowid)],
    );
    grantReward(request.user.id, "comment_post", {
      type: "comment",
      id: String(result.lastInsertRowid),
    });
    return { item: commentJson(comment) };
  });

  app.post(
    "/comments/:id/like",
    { preHandler: app.authRequired },
    async (request) => {
      const id = optionalInt(request.params.id);
      if (!id) throw badRequest("comment id is invalid");
      const existing = one(
        `SELECT id FROM likes
         WHERE user_id = ? AND target_type = 'comment' AND target_id = ?`,
        [request.user.id, String(id)],
      );
      if (existing) return { ok: true, liked: true };
      run(
        `INSERT INTO likes (user_id, target_type, target_id)
         VALUES (?, 'comment', ?)`,
        [request.user.id, String(id)],
      );
      run("UPDATE comments SET like_count = like_count + 1 WHERE id = ?", [id]);
      return { ok: true, liked: true };
    },
  );

  app.get("/danmaku", async (request, reply) => {
    const limited = enforceRateLimits(request, reply, [
      {
        scope: "public_danmaku_ip",
        key: request.ip || "unknown",
        limit: 30,
        windowMs: 60 * 1000,
        error: "danmaku_rate_limited",
      },
    ]);
    if (limited) return limited;
    const videoId = requiredString(request.query?.videoId, "videoId", 300);
    const animeId = optionalString(request.query?.animeId, 120);
    const episodeId = optionalString(request.query?.episodeId, 200);
    const animeTitle = optionalString(request.query?.animeTitle, 200);
    const episodeTitle = optionalString(request.query?.episodeTitle, 200);
    const canonicalVideoId = resolveDanmakuVideoId({
      videoId,
      animeId,
      episodeId,
    });
    const fromMs = optionalInt(request.query?.fromMs, 0);
    const toMs = optionalInt(request.query?.toMs, 24 * 60 * 60 * 1000);
    const items = all(
      `SELECT d.*, u.nickname, u.avatar_url
       FROM danmaku d
       JOIN users u ON u.id = d.user_id
       WHERE d.video_id = ?
         AND d.time_ms BETWEEN ? AND ?
         AND d.status = 'visible'
       ORDER BY d.time_ms ASC, d.created_at ASC
       LIMIT 5000`,
      [canonicalVideoId, fromMs, toMs],
    ).map(danmakuJson);
    const bilibiliItems = await fetchAutoBilibiliDanmaku({
      videoId: canonicalVideoId,
      animeId,
      animeTitle,
      episodeId,
      episodeTitle,
      fromMs,
      toMs,
    });
    const mergedItems = [...items, ...bilibiliItems].sort(
      (a, b) => (a.timeMs || 0) - (b.timeMs || 0),
    );
    return {
      videoId: canonicalVideoId,
      requestedVideoId: videoId,
      items: mergedItems,
    };
  });

  app.post("/danmaku", { preHandler: app.authRequired }, async (request) => {
    const body = request.body || {};
    const videoId = requiredString(body.videoId, "videoId", 300);
    const timeMs = optionalInt(body.timeMs, -1);
    if (timeMs < 0) throw badRequest("timeMs is invalid");
    const animeId = optionalString(body.animeId, 120);
    const episodeId = optionalString(body.episodeId, 200);
    const animeTitle = optionalString(body.animeTitle, 200);
    const episodeTitle = optionalString(body.episodeTitle, 200) || episodeId;
    const canonicalVideoId = resolveDanmakuVideoId({
      videoId,
      animeId,
      episodeId,
    });
    upsertDanmakuMeta({
      canonicalVideoId,
      animeId,
      animeTitle,
      episodeId,
      episodeTitle,
    });
    const content = requiredString(body.content, "content", 120);
    const color = optionalString(body.color, 20) || "#FFFFFF";
    const mode = optionalString(body.mode, 20) || "scroll";

    const result = run(
      `INSERT INTO danmaku
       (user_id, video_id, anime_id, episode_id, time_ms, content, color, mode)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        request.user.id,
        canonicalVideoId,
        animeId,
        episodeId,
        timeMs,
        content,
        color,
        mode,
      ],
    );
    const row = one(
      `SELECT d.*, u.nickname, u.avatar_url
       FROM danmaku d
       JOIN users u ON u.id = d.user_id
       WHERE d.id = ?`,
      [Number(result.lastInsertRowid)],
    );
    const item = danmakuJson(row);
    grantReward(request.user.id, "danmaku_post", {
      type: "danmaku",
      id: String(result.lastInsertRowid),
    });
    app.broadcastDanmaku?.(canonicalVideoId, item);
    if (canonicalVideoId !== videoId) app.broadcastDanmaku?.(videoId, item);
    return { item };
  });

  app.post("/reports", { preHandler: app.authRequired }, async (request) => {
    const body = request.body || {};
    const targetType = reportTargetType(body.targetType);
    const targetId = requiredString(body.targetId, "targetId", 100);
    const reason = requiredString(body.reason, "reason", 500);
    const result = run(
      `INSERT INTO reports (reporter_id, target_type, target_id, reason)
       VALUES (?, ?, ?, ?)`,
      [request.user.id, targetType, targetId, reason],
    );
    return { ok: true, id: Number(result.lastInsertRowid) };
  });
}

export function canonicalDanmakuVideoId({ animeId, episodeId, fallback }) {
  if (animeId && episodeId) return `anime:${animeId}:episode:${episodeId}`;
  return fallback;
}

async function fetchAutoBilibiliDanmaku({
  videoId,
  animeId,
  animeTitle,
  episodeId,
  episodeTitle,
  fromMs,
  toMs,
}) {
  const sourceContext = await resolveDanmakuSourceContext({
    animeId,
    animeTitle,
    episodeId,
    episodeTitle,
  });
  animeTitle = sourceContext.animeTitle;
  episodeTitle = sourceContext.episodeTitle;
  const normalizedAnimeTitle = normalizeStrictTitle(animeTitle);
  if (!normalizedAnimeTitle) return [];
  const episodeNumber =
    extractEpisodeNumber(episodeTitle) || extractEpisodeNumber(episodeId);
  const normalizedEpisodeTitle = normalizeStrictTitle(episodeTitle || episodeId);
  if (!episodeNumber && !normalizedEpisodeTitle) return [];

  const cacheKey = [
    normalizedAnimeTitle,
    episodeNumber || normalizedEpisodeTitle,
    fromMs,
    toMs,
  ].join("|");
  const cached = autoBilibiliCache.get(cacheKey);
  if (cached && Date.now() - cached.time < autoBilibiliCacheTtlMs) {
    autoBilibiliCache.delete(cacheKey);
    autoBilibiliCache.set(cacheKey, cached);
    return cached.items;
  }
  if (cached) autoBilibiliCache.delete(cacheKey);

  try {
    const {
      fetchBilibiliDanmaku,
      fetchBilibiliSeason,
      searchBilibiliBangumi,
    } = await import("./bilibili-danmaku.js");
    const search = await searchBilibiliBangumi(animeTitle);
    const match = await resolveStrictBilibiliEpisode({
      searchItems: search.items || [],
      fetchBilibiliSeason,
      normalizedAnimeTitle,
      normalizedEpisodeTitle,
      episodeNumber,
    });
    if (!match?.episode?.cid) return [];

    const rawItems = await fetchBilibiliDanmaku(match.episode.cid);
    const filtered = rawItems
      .filter((item) => item.timeMs >= fromMs && item.timeMs <= toMs)
      .slice(0, 3000)
      .map((item, index) =>
        bilibiliDanmakuJson({
          item,
          index,
          videoId,
          animeId,
          animeTitle,
          episodeId,
          episodeTitle,
        }),
      );
    setTimedCache(
      autoBilibiliCache,
      cacheKey,
      { time: Date.now(), items: filtered },
      autoBilibiliCacheTtlMs,
      autoBilibiliCacheMaxEntries,
    );
    return filtered;
  } catch {
    return [];
  }
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

async function resolveDanmakuSourceContext({
  animeId,
  animeTitle,
  episodeId,
  episodeTitle,
}) {
  if (animeTitle && episodeTitle) return { animeTitle, episodeTitle };
  if (!animeId) return { animeTitle, episodeTitle };
  try {
    const { fetchAnimeSourceDetail } = await import("./anime-source.js");
    const detail = await fetchAnimeSourceDetail(animeId);
    const episode =
      (detail?.episodes || []).find(
        (item) =>
          item.episodeId === episodeId ||
          item.episodeTitle === episodeTitle ||
          item.episodeTitle === episodeId,
      ) || null;
    return {
      animeTitle: animeTitle || detail?.animeTitle || "",
      episodeTitle: episodeTitle || episode?.episodeTitle || episodeId,
    };
  } catch {
    return { animeTitle, episodeTitle };
  }
}

function matchStrictBilibiliEpisode({ episodes, episodeNumber, episodeTitle }) {
  if (episodeNumber) {
    return episodes.find((item) => Number(item.index) === episodeNumber) || null;
  }
  return (
    episodes.find((item) =>
      [item.displayTitle, item.longTitle, item.title]
        .map(normalizeStrictTitle)
        .filter(Boolean)
        .includes(episodeTitle),
    ) || null
  );
}

async function resolveStrictBilibiliEpisode({
  searchItems,
  fetchBilibiliSeason,
  normalizedAnimeTitle,
  normalizedEpisodeTitle,
  episodeNumber,
}) {
  const exactSources = (searchItems || []).filter(
    (item) => isStrictTitleMatch(item.title, normalizedAnimeTitle),
  );
  for (const source of exactSources) {
    if (!source?.seasonId) continue;
    const season = await fetchBilibiliSeason(source.seasonId);
    if (!isStrictTitleMatch(season.title, normalizedAnimeTitle)) continue;
    const episode = matchStrictBilibiliEpisode({
      episodes: season.episodes || [],
      episodeNumber,
      episodeTitle: normalizedEpisodeTitle,
    });
    if (episode) return { season, episode };
  }

  if (!episodeNumber) return null;
  const normalizedSeriesTitle = normalizeSeriesTitle(normalizedAnimeTitle);
  if (!normalizedSeriesTitle) return null;
  const seriesSources = (searchItems || []).filter(
    (item) => normalizeSeriesTitle(item.title) === normalizedSeriesTitle,
  );
  const seasons = [];
  for (const source of seriesSources) {
    if (!source?.seasonId) continue;
    const season = await fetchBilibiliSeason(source.seasonId);
    if (normalizeSeriesTitle(season.title) !== normalizedSeriesTitle) continue;
    seasons.push(season);
  }
  seasons.sort((a, b) => seasonOrder(a.title) - seasonOrder(b.title));

  let offset = 0;
  for (const season of seasons) {
    const episodes = season.episodes || [];
    if (episodeNumber > offset && episodeNumber <= offset + episodes.length) {
      const localIndex = episodeNumber - offset;
      const episode =
        episodes.find((item) => Number(item.index) === localIndex) || null;
      if (episode) return { season, episode };
    }
    offset += episodes.length;
  }
  return null;
}

function bilibiliDanmakuJson({
  item,
  index,
  videoId,
  animeId,
  animeTitle,
  episodeId,
  episodeTitle,
}) {
  return {
    id: -100000000 - index,
    videoId,
    animeId,
    animeTitle,
    episodeId,
    episodeTitle,
    timeMs: item.timeMs,
    content: item.content,
    color: item.color || "#FFFFFF",
    mode: item.mode || "scroll",
    createdAt: "",
    user: {
      id: 0,
      nickname: "B站弹幕",
      avatarUrl: "",
      level: 0,
    },
  };
}

function normalizeStrictTitle(value) {
  return String(value || "")
    .replace(/<[^>]+>/g, "")
    .replace(/[【】\[\]（）()《》「」『』]/g, "")
    .replace(/\s+/g, "")
    .trim()
    .toLowerCase();
}

function isStrictTitleMatch(candidateTitle, normalizedTargetTitle) {
  const candidate = normalizeStrictTitle(candidateTitle);
  if (candidate === normalizedTargetTitle) return true;
  const withoutDashSubtitle = normalizeStrictTitle(
    stripDashSubtitle(candidateTitle),
  );
  return withoutDashSubtitle === normalizedTargetTitle;
}

function stripDashSubtitle(value) {
  return String(value || "")
    .replace(/[-–—－][^-–—－]+[-–—－]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeSeriesTitle(value) {
  return normalizeStrictTitle(stripDashSubtitle(value))
    .replace(/第[一二三四五六七八九十\d]+季/g, "")
    .replace(/第[一二三四五六七八九十\d]+期/g, "")
    .replace(/第[一二三四五六七八九十\d]+部/g, "")
    .replace(/season\d+/g, "")
    .replace(/s\d+/g, "")
    .replace(/part\d+/g, "")
    .replace(/前半|后半|後半|上半|下半/g, "")
    .trim();
}

function seasonOrder(value) {
  const text = normalizeStrictTitle(value);
  if (/前半|上半|part1/.test(text)) return 1;
  if (/后半|後半|下半|part2/.test(text)) return 2;
  const match = /第([一二三四五六七八九十\d]+)季/.exec(String(value || ""));
  if (match) return chineseNumber(match[1]);
  const season = /season(\d+)|s(\d+)/.exec(text);
  if (season) return Number(season[1] || season[2] || 1);
  return 1;
}

function chineseNumber(value) {
  const text = String(value || "");
  const numeric = Number(text);
  if (Number.isFinite(numeric) && numeric > 0) return numeric;
  const map = {
    一: 1,
    二: 2,
    三: 3,
    四: 4,
    五: 5,
    六: 6,
    七: 7,
    八: 8,
    九: 9,
    十: 10,
  };
  if (text === "十") return 10;
  if (text.startsWith("十")) return 10 + (map[text.slice(1)] || 0);
  if (text.endsWith("十")) return (map[text[0]] || 1) * 10;
  if (text.includes("十")) {
    const [ten, one] = text.split("十");
    return (map[ten] || 1) * 10 + (map[one] || 0);
  }
  return map[text] || 1;
}

function extractEpisodeNumber(value) {
  const text = String(value || "");
  const patterns = [
    /第\s*0*(\d{1,4})\s*[集话話]/,
    /^0*(\d{1,4})(?:\D|$)/,
  ];
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    if (!match) continue;
    const number = Number(match[1]);
    if (Number.isInteger(number) && number > 0) return number;
  }
  return 0;
}

export function resolveDanmakuVideoId({
  videoId,
  animeId = "",
  episodeId = "",
}) {
  const alias = one(
    `SELECT canonical_video_id
     FROM danmaku_video_aliases
     WHERE alias_video_id = ?
       AND TRIM(source_name) != ''`,
    [videoId],
  );
  if (alias?.canonical_video_id) return alias.canonical_video_id;
  return canonicalDanmakuVideoId({
    animeId,
    episodeId,
    fallback: videoId,
  });
}

export function upsertDanmakuAlias({
  aliasVideoId,
  canonicalVideoId,
  animeId = "",
  episodeId = "",
  sourceName = "",
}) {
  run(
    `INSERT INTO danmaku_video_aliases
       (alias_video_id, canonical_video_id, anime_id, episode_id, source_name)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(alias_video_id) DO UPDATE SET
       canonical_video_id = excluded.canonical_video_id,
       anime_id = excluded.anime_id,
       episode_id = excluded.episode_id,
       source_name = excluded.source_name,
       updated_at = datetime('now')`,
    [aliasVideoId, canonicalVideoId, animeId, episodeId, sourceName],
  );
}

export function upsertDanmakuMeta({
  canonicalVideoId,
  animeId = "",
  animeTitle = "",
  episodeId = "",
  episodeTitle = "",
}) {
  if (!canonicalVideoId) return;
  run(
    `INSERT INTO danmaku_episode_meta
       (canonical_video_id, anime_id, anime_title, episode_id, episode_title)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(canonical_video_id) DO UPDATE SET
       anime_id = CASE
         WHEN excluded.anime_id != '' THEN excluded.anime_id
         ELSE danmaku_episode_meta.anime_id
       END,
       anime_title = CASE
         WHEN excluded.anime_title != '' THEN excluded.anime_title
         ELSE danmaku_episode_meta.anime_title
       END,
       episode_id = CASE
         WHEN excluded.episode_id != '' THEN excluded.episode_id
         ELSE danmaku_episode_meta.episode_id
       END,
       episode_title = CASE
         WHEN excluded.episode_title != '' THEN excluded.episode_title
         ELSE danmaku_episode_meta.episode_title
       END,
       updated_at = datetime('now')`,
    [canonicalVideoId, animeId, animeTitle, episodeId, episodeTitle],
  );
}

export function upsertCommentTargetMeta({
  targetType,
  targetId,
  targetTitle = "",
  chapterId = "",
  chapterTitle = "",
  episodeId = "",
  episodeTitle = "",
}) {
  run(
    `INSERT INTO comment_target_meta
       (target_type, target_id, target_title, chapter_id, chapter_title, episode_id, episode_title)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(target_type, target_id, chapter_id, episode_id) DO UPDATE SET
       target_title = CASE
         WHEN excluded.target_title != '' THEN excluded.target_title
         ELSE comment_target_meta.target_title
       END,
       chapter_title = CASE
         WHEN excluded.chapter_title != '' THEN excluded.chapter_title
         ELSE comment_target_meta.chapter_title
       END,
       episode_title = CASE
         WHEN excluded.episode_title != '' THEN excluded.episode_title
         ELSE comment_target_meta.episode_title
       END,
       updated_at = datetime('now')`,
    [
      targetType,
      targetId,
      targetTitle,
      chapterId,
      chapterTitle,
      episodeId,
      episodeTitle,
    ],
  );
}

export function commentJson(row) {
  return {
    id: row.id,
    parentId: row.parent_id,
    targetType: row.target_type,
    targetId: row.target_id,
    chapterId: row.chapter_id,
    episodeId: row.episode_id,
    rating: row.rating,
    content: row.content,
    likeCount: row.like_count,
    replyCount: row.reply_count,
    status: row.status,
    createdAt: row.created_at,
    user: {
      id: row.user_id,
      nickname: row.nickname,
      avatarUrl: row.avatar_url || "",
    },
  };
}

export function danmakuJson(row) {
  return {
    id: row.id,
    videoId: row.video_id,
    animeId: row.anime_id,
    episodeId: row.episode_id,
    timeMs: row.time_ms,
    content: row.content,
    color: row.color,
    mode: row.mode,
    status: row.status,
    createdAt: row.created_at,
    user: {
      id: row.user_id,
      nickname: row.nickname,
      avatarUrl: row.avatar_url || "",
    },
  };
}
