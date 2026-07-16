import { resolveVideoCover } from '../src/video-cover-resolver.js';

const origin = String(process.env.VIDEO_HOME_ORIGIN || 'https://www.wuhandky.com').replace(/\/+$/, '');
const paths = ['/new.html', '/dianying/', '/dianshiju/', '/dongman/', '/zongyi/'];
const limitPerSection = Math.max(1, Math.min(30, Number(process.env.VIDEO_HOME_COVER_LIMIT || 18)));
let resolved = 0;
let missing = 0;

for (const sectionPath of paths) {
  const response = await fetch(new URL(sectionPath, `${origin}/`), {
    signal: AbortSignal.timeout(12000),
    headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'text/html' },
  });
  if (!response.ok) throw new Error(`video_home_http_${response.status}`);
  const html = await response.text();
  const items = parseHomeItems(html).slice(0, limitPerSection);
  for (const item of items) {
    const result = await resolveVideoCover({
      sourceKey: 'wuhandky',
      itemKey: new URL(item.href, `${origin}/`).toString(),
      title: item.title,
    });
    if (result.coverUrl) resolved += 1;
    else missing += 1;
  }
}

console.log(`video_cover_prewarm_resolved=${resolved}`);
console.log(`video_cover_prewarm_missing=${missing}`);

function parseHomeItems(html) {
  const results = [];
  const seen = new Set();
  const pattern = /<a\b(?=[^>]*\bclass=["'][^"']*video-pic[^"']*["'])(?=[^>]*\bhref=["']([^"']+)["'])(?=[^>]*\btitle=["']([^"']+)["'])[^>]*>/gi;
  for (const match of html.matchAll(pattern)) {
    const href = decode(match[1]);
    const title = decode(match[2]).trim();
    if (!href.includes('/album/') || !title || !seen.add(href)) continue;
    results.push({ href, title });
  }
  return results;
}

function decode(value) {
  return String(value || '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');
}
