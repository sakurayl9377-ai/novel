import { migrate } from '../src/db.js';
import { resolveVideoCover } from '../src/video-cover-resolver.js';

migrate();

const origin = String(
  process.env.VIDEO_HOME_ORIGIN || 'https://www.wuhandky.com',
).replace(/\/+$/, '');
const sections = [
  ['latest', '/new.html'],
  ['movies', '/dianying/'],
  ['series', '/dianshiju/'],
  ['anime', '/dongman/'],
  ['variety', '/zongyi/'],
];
const limitPerSection = Math.max(
  1,
  Math.min(30, Number(process.env.VIDEO_HOME_COVER_LIMIT || 18)),
);
const concurrency = Math.max(
  1,
  Math.min(8, Number(process.env.VIDEO_HOME_COVER_CONCURRENCY || 4)),
);
const forceRefresh = process.env.VIDEO_HOME_COVER_FORCE_REFRESH !== 'false';
const stats = {
  sections: {},
  discovered: 0,
  unique: 0,
  resolved: 0,
  cached: 0,
  missing: 0,
  errors: 0,
  providers: {},
};
const uniqueItems = new Map();

for (const [sectionName, sectionPath] of sections) {
  const response = await fetch(new URL(sectionPath, `${origin}/`), {
    signal: AbortSignal.timeout(12000),
    headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'text/html' },
  });
  if (!response.ok) throw new Error(`video_home_http_${response.status}`);
  const html = await response.text();
  const items = parseHomeItems(html, new URL(sectionPath, `${origin}/`))
    .slice(0, limitPerSection);
  stats.sections[sectionName] = {
    path: sectionPath,
    discovered: items.length,
    resolved: 0,
    missing: 0,
    errors: 0,
  };
  stats.discovered += items.length;
  for (const item of items) {
    const existing = uniqueItems.get(item.itemKey);
    if (existing) existing.sections.push(sectionName);
    else uniqueItems.set(item.itemKey, { ...item, sections: [sectionName] });
  }
}

stats.unique = uniqueItems.size;
await runPool([...uniqueItems.values()], concurrency, async (item) => {
  try {
    const result = await resolveVideoCover({
      sourceKey: 'wuhandky',
      itemKey: item.itemKey,
      title: item.title,
      candidateUrl: item.coverUrl,
      forceRefresh,
    });
    if (result.coverUrl) {
      if (!isManagedCover(result.coverUrl)) {
        throw new Error('video_cover_prewarm_not_mirrored');
      }
      stats.resolved += 1;
      if (result.cached) stats.cached += 1;
      stats.providers[result.provider] = (stats.providers[result.provider] || 0) + 1;
      for (const section of item.sections) stats.sections[section].resolved += 1;
    } else {
      stats.missing += 1;
      for (const section of item.sections) stats.sections[section].missing += 1;
    }
  } catch (error) {
    stats.errors += 1;
    for (const section of item.sections) stats.sections[section].errors += 1;
    process.stderr.write(
      `video_cover_prewarm_error=${JSON.stringify({
        title: item.title,
        itemKey: item.itemKey,
        error: error?.message || String(error),
      })}\n`,
    );
  }
});

for (const [name, section] of Object.entries(stats.sections)) {
  console.log(`video_cover_prewarm_section=${JSON.stringify({ name, ...section })}`);
}
console.log(`video_cover_prewarm_summary=${JSON.stringify(stats)}`);
if (stats.errors > 0) process.exitCode = 1;

function parseHomeItems(html, pageUrl) {
  const results = [];
  const seen = new Set();
  const pattern = /<a\b(?=[^>]*\bclass=["'][^"']*video-pic[^"']*["'])(?=[^>]*\bhref=["']([^"']+)["'])(?=[^>]*\btitle=["']([^"']+)["'])[^>]*>/gi;
  for (const match of html.matchAll(pattern)) {
    const href = decode(match[1]);
    const title = decode(match[2]).trim();
    if (!href.includes('/album/') || !title || !seen.add(href)) continue;
    const tag = match[0];
    const rawCover = /\bdata-original=["']([^"']+)["']/i.exec(tag)?.[1]
      || /\bstyle=["'][^"']*url\(([^)]+)\)/i.exec(tag)?.[1]
      || '';
    const detailUrl = new URL(href, pageUrl);
    results.push({
      itemKey: `${detailUrl.pathname}${detailUrl.search}`,
      title,
      coverUrl: normalizeCoverUrl(rawCover, pageUrl),
    });
  }
  return results;
}

function normalizeCoverUrl(value, pageUrl) {
  const cleaned = decode(value).replace(/["']/g, '').trim();
  if (!cleaned) return '';
  return new URL(cleaned.startsWith('//') ? `https:${cleaned}` : cleaned, pageUrl)
    .toString();
}

async function runPool(items, size, worker) {
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (cursor < items.length) {
        const item = items[cursor];
        cursor += 1;
        await worker(item);
      }
    }),
  );
}

function isManagedCover(value) {
  return /^\/video-covers\/files\/[a-f0-9]{64}\.(?:gif|jpe?g|png|webp)$/i.test(
    String(value || ''),
  );
}

function decode(value) {
  return String(value || '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');
}
