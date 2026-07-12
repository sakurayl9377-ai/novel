import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(
  'C:/Users/Administrator/AppData/Local/OpenAI/Codex/runtimes/cua_node/1b23c930bdf84ed6/bin/node_modules/playwright/package.json',
);
const { chromium } = require('playwright');

const root = process.cwd();
const assetDir = path.join(root, 'assets', 'images', 'profile');
const sourceDir = path.join(root, 'docs', 'profile-avatar-frames');

const tiers = [
  {
    level: 1,
    name: 'Initial Sakura',
    colors: ['#dfe8ff', '#9fb4df', '#6e84b9', '#ffffff'],
    accent: '#c9d9ff',
    petals: 2,
    leaves: 6,
    stars: 0,
  },
  {
    level: 2,
    name: 'Clear Sakura',
    colors: ['#e9fbff', '#75d5e5', '#2aa7c1', '#ffffff'],
    accent: '#8de5ef',
    petals: 3,
    leaves: 8,
    stars: 2,
  },
  {
    level: 3,
    name: 'Crimson Sakura',
    colors: ['#ffe3ed', '#ff8aa9', '#ec4e7d', '#fff7fb'],
    accent: '#ff9ab6',
    petals: 5,
    leaves: 10,
    stars: 3,
  },
  {
    level: 4,
    name: 'Flower Rain',
    colors: ['#fff2db', '#ffb16d', '#ff6f91', '#fff8ef'],
    accent: '#ff8ba8',
    petals: 6,
    leaves: 12,
    stars: 4,
    floralCrown: true,
  },
  {
    level: 5,
    name: 'Star Sakura',
    colors: ['#dff2ff', '#61bfff', '#3459d9', '#f8fdff'],
    accent: '#72d5ff',
    petals: 5,
    leaves: 12,
    stars: 9,
    crystals: true,
  },
  {
    level: 6,
    name: 'Moon Sakura',
    colors: ['#fff9df', '#e8ca73', '#b78f3d', '#ffffff'],
    accent: '#f1dca4',
    petals: 6,
    leaves: 14,
    stars: 7,
    moon: true,
  },
  {
    level: 7,
    name: 'Divine Sakura',
    colors: ['#fff0a8', '#f2b83f', '#9b6614', '#fff8d7'],
    accent: '#ff9bc7',
    petals: 7,
    leaves: 16,
    stars: 12,
    crown: true,
    dragonScales: true,
  },
];

function polar(angle, radius) {
  const rad = ((angle - 90) * Math.PI) / 180;
  return [256 + Math.cos(rad) * radius, 256 + Math.sin(rad) * radius];
}

function petal(x, y, angle, scale, fill, stroke = 'rgba(255,255,255,.72)') {
  return `<g transform="translate(${x.toFixed(2)} ${y.toFixed(2)}) rotate(${angle.toFixed(
    2,
  )}) scale(${scale})"><path d="M0,-24 C18,-20 29,-5 24,10 C18,28 -18,28 -24,10 C-29,-5 -18,-20 0,-24 Z" fill="${fill}" stroke="${stroke}" stroke-width="2"/></g>`;
}

function leaf(x, y, angle, scale, fill, stroke) {
  return `<g transform="translate(${x.toFixed(2)} ${y.toFixed(2)}) rotate(${angle.toFixed(
    2,
  )}) scale(${scale})"><path d="M0,-20 C18,-18 30,-6 34,8 C18,16 2,12 -12,0 C-6,-9 -3,-15 0,-20 Z" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/><path d="M-4,-8 C8,-5 18,0 29,8" fill="none" stroke="${stroke}" stroke-width="1" opacity=".55"/></g>`;
}

function star(x, y, size, fill) {
  return `<path d="M${x},${y - size} L${x + size * 0.28},${y - size * 0.28} L${x + size},${y} L${
    x + size * 0.28
  },${y + size * 0.28} L${x},${y + size} L${x - size * 0.28},${y + size * 0.28} L${
    x - size
  },${y} L${x - size * 0.28},${y - size * 0.28} Z" fill="${fill}"/>`;
}

function frameSvg(tier) {
  const [light, mid, deep, shine] = tier.colors;
  const leafFill = tier.level >= 6 ? '#dba94a' : tier.level >= 4 ? '#ff9a7e' : mid;
  const stroke = tier.level >= 6 ? '#fff2bd' : '#ffffff';
  const r = tier.level >= 7 ? 205 : 204;
  const strokeWidth = tier.level >= 6 ? 12 : tier.level >= 4 ? 11 : 9;
  const leaves = [];
  const count = tier.leaves;
  const perSide = Math.ceil(count / 2);
  const sideAngles = [
    ...Array.from({ length: perSide }, (_, i) => 42 + (112 * i) / Math.max(1, perSide - 1)),
    ...Array.from({ length: perSide }, (_, i) => 206 + (112 * i) / Math.max(1, perSide - 1)),
  ];
  for (let i = 0; i < count; i += 1) {
    const angle = sideAngles[i];
    const [x, y] = polar(angle, r + 13 + (i % 2) * 2);
    leaves.push(leaf(x, y, angle + 90, 0.29 + tier.level * 0.014, leafFill, stroke));
  }

  const petals = [];
  for (let i = 0; i < tier.petals; i += 1) {
    const spread = tier.floralCrown || tier.crown ? 98 : 72;
    const angle = -spread / 2 + (spread * i) / Math.max(1, tier.petals - 1);
    const [x, y] = polar(angle, r + 12 + (i % 3) * 2);
    const fill = i % 2 === 0 ? tier.accent : light;
    petals.push(petal(x, y, angle, 0.24 + tier.level * 0.012, fill, shine));
  }

  const sparkles = [];
  for (let i = 0; i < tier.stars; i += 1) {
    const angle = 38 + ((310 - 38) * ((i * 37) % 100)) / 100;
    const [x, y] = polar(angle, r + 14 + (i % 2) * 8);
    sparkles.push(star(x.toFixed(2), y.toFixed(2), 3 + (i % 3), tier.level >= 6 ? '#fff3b6' : shine));
  }

  const topOrnament = tier.crown
    ? `<g filter="url(#softGlow)">
        <path d="M202 86 L224 55 L246 82 L256 42 L266 82 L288 55 L310 86 L297 107 L215 107 Z" fill="url(#goldGrad)" stroke="#fff3b8" stroke-width="3.5" stroke-linejoin="round"/>
        <circle cx="256" cy="64" r="18" fill="url(#gemGrad)" stroke="#ffe0f0" stroke-width="3.5"/>
        <path d="M233 107 C243 120 269 120 279 107" fill="none" stroke="#9b6614" stroke-width="4" stroke-linecap="round"/>
      </g>`
    : tier.moon
      ? `<g filter="url(#softGlow)"><path d="M270 54 A34 34 0 1 1 226 99 A26 26 0 1 0 270 54 Z" fill="url(#goldGrad)" stroke="#fff8d7" stroke-width="3"/><circle cx="288" cy="92" r="9" fill="#fff8d7"/></g>`
      : tier.floralCrown
        ? `<g filter="url(#softGlow)">
            ${petal(230, 76, -28, 0.34, '#ff7f9a', shine)}
            ${petal(256, 68, 0, 0.4, '#fff0db', shine)}
            ${petal(282, 76, 28, 0.34, '#ff7f9a', shine)}
            <circle cx="256" cy="88" r="7" fill="#ffd18a" stroke="#fff7e8" stroke-width="2.4"/>
          </g>`
        : `<g filter="url(#softGlow)">${petal(256, 72, 0, 0.3, tier.accent, shine)}</g>`;

  const bottomOrnament =
    tier.level >= 4
      ? `<g filter="url(#softGlow)">
          <path d="M256 455 L274 473 L256 491 L238 473 Z" fill="url(#mainGrad)" stroke="${shine}" stroke-width="2.6"/>
          <circle cx="256" cy="473" r="5.5" fill="${tier.accent}"/>
        </g>`
      : `<g filter="url(#softGlow)"><circle cx="256" cy="468" r="9" fill="${tier.accent}" stroke="${shine}" stroke-width="3"/></g>`;

  const crystals = tier.crystals
    ? `<g filter="url(#softGlow)">
        <path d="M396 116 L428 130 L418 166 L380 150 Z" fill="#84dbff" opacity=".78" stroke="#f8fdff" stroke-width="3"/>
        <path d="M108 360 L138 342 L158 374 L118 392 Z" fill="#5aa9ff" opacity=".6" stroke="#f8fdff" stroke-width="2"/>
      </g>`
    : '';

  const dragonScales = tier.dragonScales
    ? `<g opacity=".36" stroke="#f6c24d" stroke-width="2" fill="none">
        ${Array.from({ length: 28 }, (_, i) => {
          const angle = i * (360 / 28);
          const [x, y] = polar(angle, 199);
          return `<path d="M-8 0 A8 8 0 0 0 8 0" transform="translate(${x.toFixed(2)} ${y.toFixed(
            2,
          )}) rotate(${angle})"/>`;
        }).join('')}
      </g>`
    : '';

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" fill="none">
  <defs>
    <linearGradient id="mainGrad" x1="92" y1="96" x2="418" y2="420" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${shine}"/>
      <stop offset=".28" stop-color="${light}"/>
      <stop offset=".58" stop-color="${mid}"/>
      <stop offset="1" stop-color="${deep}"/>
    </linearGradient>
    <linearGradient id="goldGrad" x1="166" y1="40" x2="344" y2="132" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff4ba"/>
      <stop offset=".42" stop-color="#f2b83f"/>
      <stop offset=".72" stop-color="#c5841f"/>
      <stop offset="1" stop-color="#fff0a8"/>
    </linearGradient>
    <radialGradient id="gemGrad" cx="50%" cy="38%" r="58%">
      <stop offset="0" stop-color="#fff6ff"/>
      <stop offset=".48" stop-color="#ff9bc7"/>
      <stop offset="1" stop-color="#c74c77"/>
    </radialGradient>
    <filter id="softGlow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="${tier.level >= 6 ? 4.4 : 3}" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="ringShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="6" stdDeviation="6" flood-color="${deep}" flood-opacity=".28"/>
      <feDropShadow dx="0" dy="0" stdDeviation="${tier.level >= 6 ? 5 : 3}" flood-color="${mid}" flood-opacity=".42"/>
    </filter>
  </defs>
  <circle cx="256" cy="256" r="${r + 14}" stroke="${deep}" stroke-opacity=".2" stroke-width="4"/>
  <circle cx="256" cy="256" r="${r}" stroke="url(#mainGrad)" stroke-width="${strokeWidth}" filter="url(#ringShadow)"/>
  <circle cx="256" cy="256" r="${r - strokeWidth / 2 - 8}" stroke="${shine}" stroke-opacity=".82" stroke-width="3"/>
  <circle cx="256" cy="256" r="${r + strokeWidth / 2 + 5}" stroke="${light}" stroke-opacity=".74" stroke-width="3"/>
  ${dragonScales}
  <g>${leaves.join('\n')}</g>
  <g>${petals.join('\n')}</g>
  <g filter="url(#softGlow)">${sparkles.join('\n')}</g>
  ${crystals}
  ${topOrnament}
  ${bottomOrnament}
</svg>`;
}

await fs.mkdir(assetDir, { recursive: true });
await fs.mkdir(sourceDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const page = await browser.newPage({ viewport: { width: 512, height: 512 }, deviceScaleFactor: 1 });

let previewItems = '';
for (const tier of tiers) {
  const svg = frameSvg(tier);
  const svgName = `avatar_frame_lv${tier.level}.svg`;
  const pngName = `avatar_frame_lv${tier.level}.png`;
  await fs.writeFile(path.join(assetDir, svgName), svg, 'utf8');
  await fs.writeFile(path.join(sourceDir, svgName), svg, 'utf8');
  await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${svg}</body></html>`);
  await page.screenshot({ path: path.join(assetDir, pngName), omitBackground: true });
  previewItems += `<figure><div>${svg}</div><figcaption>LV${tier.level} ${tier.name}</figcaption></figure>`;
}

await browser.close();

const previewHtml = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<title>Refined Avatar Frames</title>
<style>
body{margin:0;background:#eef5ff;font-family:Arial,"Microsoft YaHei",sans-serif;color:#202a3a}
.wrap{width:1180px;margin:0 auto;padding:38px 32px 54px}
h1{font-size:28px;margin:0 0 8px}
p{margin:0 0 24px;color:#667085}
.grid{display:grid;grid-template-columns:repeat(7,1fr);gap:18px;align-items:start}
figure{margin:0;text-align:center}
figure>div{height:148px;display:flex;align-items:center;justify-content:center}
svg{width:132px;height:132px;overflow:visible}
figcaption{font-weight:800;font-size:12px;color:#5d6a7b}
</style>
</head>
<body><main class="wrap"><h1>Refined Membership Avatar Frames</h1><p>Reference-aligned compact floral frames, LV1-LV7.</p><section class="grid">${previewItems}</section></main></body>
</html>`;

await fs.writeFile(path.join(sourceDir, 'refined-avatar-frames.html'), previewHtml, 'utf8');
console.log('Generated refined avatar frames.');
