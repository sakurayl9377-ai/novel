import { migrate, one, run } from "./db.js";
import {
  canonicalDanmakuVideoId,
  upsertDanmakuAlias,
  upsertDanmakuMeta,
} from "./routes-content.js";
import { hashPassword } from "./security.js";

const biliSeasonId = arg("season", "33802");
const biliEpisodeNumber = Number(arg("episode", "1"));
const animeId = arg("anime-id", "18388");
const sourceBaseUrl = arg("source-base", "https://www.yinhuadm.xyz");
const importEmail = "bilibili-danmaku@import.local";
const importNickname = "B站弹幕";

const headers = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
  Referer: `https://www.bilibili.com/bangumi/play/ss${biliSeasonId}`,
};

migrate();

const biliEpisode = await fetchBiliEpisode(biliSeasonId, biliEpisodeNumber);
const danmakuItems = await fetchBiliDanmaku(biliEpisode.cid);
const target = await fetchTargetEpisodes(
  sourceBaseUrl,
  animeId,
  biliEpisodeNumber,
);
const importUserId = ensureImportUser();

if (target.episodeUrls.length === 0) {
  throw new Error(`No target episode URLs found for anime ${animeId}`);
}

const insert = dbInsertDanmaku();
const canonicalVideoId = canonicalDanmakuVideoId({
  animeId: String(animeId),
  episodeId: target.episodeTitle,
  fallback: target.episodeUrls[0],
});
let inserted = 0;
let deleted = 0;
let aliases = 0;

run("BEGIN IMMEDIATE");
try {
  const cleanupIds = [canonicalVideoId, ...target.episodeUrls];
  for (const videoId of cleanupIds) {
    const result = run(
      `DELETE FROM danmaku
       WHERE user_id = ? AND video_id = ?`,
      [importUserId, videoId],
    );
    deleted += result.changes ?? 0;
  }

  for (const source of target.sources) {
    upsertDanmakuAlias({
      aliasVideoId: source.url,
      canonicalVideoId,
      animeId: String(animeId),
      episodeId: target.episodeTitle,
      sourceName: source.name,
    });
    aliases++;
  }

  upsertDanmakuMeta({
    canonicalVideoId,
    animeId: String(animeId),
    animeTitle: target.animeTitle,
    episodeId: target.episodeTitle,
    episodeTitle: target.episodeTitle,
  });

  for (const item of danmakuItems) {
    insert.run(
      importUserId,
      canonicalVideoId,
      String(animeId),
      target.episodeTitle,
      item.timeMs,
      item.content,
      item.color,
      "scroll",
    );
    inserted++;
  }
  run("COMMIT");
} catch (error) {
  run("ROLLBACK");
  throw error;
}

console.log(
  JSON.stringify(
    {
      ok: true,
      biliSeasonId,
      biliEpisodeNumber,
      biliCid: biliEpisode.cid,
      biliTitle: biliEpisode.title,
      targetAnimeId: animeId,
      targetAnimeTitle: target.animeTitle,
      targetEpisodeTitle: target.episodeTitle,
      canonicalVideoId,
      targetVideoIds: target.episodeUrls,
      sourceDanmakuCount: danmakuItems.length,
      deleted,
      inserted,
      aliases,
      importUserId,
    },
    null,
    2,
  ),
);

function arg(name, fallback) {
  const prefix = `--${name}=`;
  const found = process.argv.find((item) => item.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
}

async function fetchBiliEpisode(seasonId, episodeNumber) {
  const url = `https://api.bilibili.com/pgc/view/web/season?season_id=${encodeURIComponent(
    seasonId,
  )}`;
  const response = await fetch(url, { headers });
  if (!response.ok)
    throw new Error(`Bilibili season API failed: ${response.status}`);
  const json = await response.json();
  const episodes = json?.result?.episodes;
  if (!Array.isArray(episodes))
    throw new Error("Bilibili season has no episodes");
  const episode =
    episodes.find((item) => String(item.title) === String(episodeNumber)) ??
    episodes[episodeNumber - 1];
  if (!episode?.cid)
    throw new Error(`Bilibili episode ${episodeNumber} has no cid`);
  return {
    cid: Number(episode.cid),
    title: [episode.show_title, episode.long_title].filter(Boolean).join(" "),
  };
}

async function fetchBiliDanmaku(cid) {
  const url = `https://comment.bilibili.com/${cid}.xml`;
  const response = await fetch(url, { headers });
  if (!response.ok)
    throw new Error(`Bilibili danmaku XML failed: ${response.status}`);
  const xml = await response.text();
  const items = [];
  const pattern = /<d\s+p="([^"]+)">([\s\S]*?)<\/d>/g;
  for (const match of xml.matchAll(pattern)) {
    const fields = match[1].split(",");
    const seconds = Number(fields[0]);
    if (!Number.isFinite(seconds) || seconds < 0) continue;
    const rawContent = decodeHtml(match[2]).replace(/\s+/g, " ").trim();
    if (!rawContent) continue;
    items.push({
      timeMs: Math.round(seconds * 1000),
      content: rawContent.slice(0, 120),
      color: colorFromBili(fields[3]),
    });
  }
  items.sort((a, b) => a.timeMs - b.timeMs);
  return items;
}

async function fetchTargetEpisodes(baseUrl, id, episodeNumber) {
  const url = `${baseUrl.replace(/\/+$/g, "")}/api.php/provide/vod/?ac=detail&ids=${encodeURIComponent(
    id,
  )}`;
  const response = await fetch(url, {
    headers: { ...headers, Accept: "application/json,text/plain,*/*" },
  });
  if (!response.ok)
    throw new Error(`Target anime API failed: ${response.status}`);
  const json = await response.json();
  const item = json?.list?.[0];
  if (!item) throw new Error(`Target anime ${id} not found`);

  const sourceBlocks = String(item.vod_play_url || "").split("$$$");
  const sourceNames = String(item.vod_play_from || "").split("$$$");
  const episodeUrls = [];
  const sources = [];
  let episodeTitle = `第${String(episodeNumber).padStart(2, "0")}集`;
  for (let index = 0; index < sourceBlocks.length; index++) {
    const block = sourceBlocks[index];
    const episodes = block.split("#");
    const part = episodes[episodeNumber - 1];
    if (!part) continue;
    const separator = part.indexOf("$");
    if (separator <= 0) continue;
    episodeTitle = part.slice(0, separator).trim() || episodeTitle;
    const videoId = part.slice(separator + 1).trim();
    if (videoId && !episodeUrls.includes(videoId)) {
      episodeUrls.push(videoId);
      sources.push({
        name: sourceNames[index] || `source${index + 1}`,
        url: videoId,
      });
    }
  }

  return {
    animeTitle: String(item.vod_name || ""),
    episodeTitle,
    episodeUrls,
    sources,
  };
}

function ensureImportUser() {
  const existing = one("SELECT id FROM users WHERE email = ?", [importEmail]);
  if (existing) return existing.id;
  const result = run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, 'user', 'active')`,
    [importEmail, importNickname, hashPassword(cryptoRandomPassword())],
  );
  return Number(result.lastInsertRowid);
}

function dbInsertDanmaku() {
  return {
    run: (...params) =>
      run(
        `INSERT INTO danmaku
         (user_id, video_id, anime_id, episode_id, time_ms, content, color, mode)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        params,
      ),
  };
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

function cryptoRandomPassword() {
  return `${Date.now()}-${Math.random()}`;
}
