const defaultAnimeSourceBaseUrl = "https://www.yinhuadm.xyz";

const headers = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
  Accept: "application/json,text/plain,*/*",
  Referer: `${defaultAnimeSourceBaseUrl}/`,
};

export async function searchAnimeSource(keyword, { limit = 20 } = {}) {
  const q = String(keyword || "").trim();
  if (!q) return [];
  const json = await fetchAnimeSourceApi({ ac: "detail", wd: q });
  const items = Array.isArray(json?.list) ? json.list : [];
  return items.slice(0, limit).map(sourceAnimeSummary).filter(Boolean);
}

export async function fetchAnimeSourceDetail(animeId) {
  const id = String(animeId || "").trim();
  if (!id) return null;
  const json = await fetchAnimeSourceApi({ ac: "detail", ids: id });
  const item = Array.isArray(json?.list) ? json.list[0] : null;
  if (!item) return null;
  return {
    ...sourceAnimeSummary(item),
    episodes: parseAnimeSourceEpisodes(item),
  };
}

async function fetchAnimeSourceApi(params) {
  const url = new URL("/api.php/provide/vod/", defaultAnimeSourceBaseUrl);
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, String(value));
    }
  });
  const response = await fetch(url, { headers });
  if (!response.ok) {
    throw new Error(`anime_source_failed:${response.status}`);
  }
  return response.json();
}

function sourceAnimeSummary(item) {
  const animeId = String(item?.vod_id || "").trim();
  const animeTitle = cleanText(item?.vod_name);
  if (!animeId || !animeTitle) return null;
  const episodes = parseAnimeSourceEpisodes(item);
  return {
    animeId,
    animeTitle,
    titleMissing: false,
    episodeCount: episodes.length,
    danmakuCount: 0,
    userCount: 0,
    aliasCount: countSourceNames(item?.vod_play_from),
    lastCreatedAt: "",
    source: "anime_source",
    sourceLabel: "本地动漫源",
    remarks: cleanText(item?.vod_remarks),
  };
}

function parseAnimeSourceEpisodes(item) {
  const sourceNames = String(item?.vod_play_from || "").split("$$$");
  const sourceBlocks = String(item?.vod_play_url || "").split("$$$");
  const byEpisode = new Map();

  for (let sourceIndex = 0; sourceIndex < sourceBlocks.length; sourceIndex++) {
    const sourceName = friendlySourceName(sourceNames[sourceIndex] || `source${sourceIndex + 1}`);
    const parts = sourceBlocks[sourceIndex].split("#");
    for (let episodeIndex = 0; episodeIndex < parts.length; episodeIndex++) {
      const parsed = parseEpisodePart(parts[episodeIndex]);
      if (!parsed) continue;
      const episodeTitle = parsed.title || `第${episodeIndex + 1}集`;
      const episodeId = episodeTitle;
      const current =
        byEpisode.get(episodeId) ||
        {
          videoId: canonicalAnimeVideoId(item.vod_id, episodeId),
          animeId: String(item.vod_id || ""),
          animeTitle: cleanText(item.vod_name),
          episodeId,
          episodeTitle,
          danmakuCount: 0,
          userCount: 0,
          aliasCount: 0,
          bilibiliImportedCount: 0,
          bilibiliSyncStatus: "unsynced",
          minTimeMs: 0,
          maxTimeMs: 0,
          lastCreatedAt: "",
          latestContent: "",
          source: "anime_source",
          targetAliases: [],
        };
      current.aliasCount += 1;
      current.targetAliases.push({
        sourceName,
        url: parsed.url,
      });
      byEpisode.set(episodeId, current);
    }
  }

  return [...byEpisode.values()];
}

function parseEpisodePart(value) {
  const text = String(value || "").trim();
  if (!text) return null;
  const separator = text.indexOf("$");
  if (separator <= 0 || separator >= text.length - 1) return null;
  const title = text.slice(0, separator).trim();
  const url = text.slice(separator + 1).trim();
  if (!title || !url) return null;
  return { title, url };
}

function canonicalAnimeVideoId(animeId, episodeId) {
  return `anime:${String(animeId || "")}:episode:${String(episodeId || "")}`;
}

function countSourceNames(value) {
  return String(value || "")
    .split("$$$")
    .map((item) => item.trim())
    .filter(Boolean).length;
}

function friendlySourceName(value) {
  const text = String(value || "").trim();
  const lower = text.toLowerCase();
  if (lower.includes("lz")) return "Laoz";
  if (lower.includes("bf")) return "Bfeng";
  if (lower.includes("ff")) return "Diff";
  return text || "播放源";
}

function cleanText(value) {
  return String(value || "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}
