import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(
  'C:/Users/Administrator/AppData/Local/OpenAI/Codex/runtimes/cua_node/1b23c930bdf84ed6/bin/node_modules/playwright/package.json',
);
const { chromium } = require('playwright');

const root = process.cwd();
const htmlPath = path.join(root, 'docs', 'profile-avatar-frames', 'stitch-avatar-frames.html');
const assetDir = path.join(root, 'assets', 'images', 'profile');
const sourceDir = path.join(root, 'docs', 'profile-avatar-frames');

const html = await fs.readFile(htmlPath, 'utf8');

const tagFixes = new Map([
  ['lineargradient', 'linearGradient'],
  ['radialgradient', 'radialGradient'],
  ['fegaussianblur', 'feGaussianBlur'],
  ['femerge', 'feMerge'],
  ['femergenode', 'feMergeNode'],
]);

function normalizeSvg(svg) {
  let output = svg;
  for (const [from, to] of tagFixes) {
    output = output.replace(new RegExp(`<${from}\\b`, 'gi'), `<${to}`);
    output = output.replace(new RegExp(`</${from}>`, 'gi'), `</${to}>`);
  }
  output = output
    .replace(/\bviewbox=/gi, 'viewBox=')
    .replace(/\bpreserveaspectratio=/gi, 'preserveAspectRatio=')
    .replace(/\bpatternunits=/gi, 'patternUnits=')
    .replace(/\sclass="[^"]*"/i, '');

  output = output.replace(/<svg\b([^>]*)>/i, (_, attrs) => {
    let nextAttrs = attrs
      .replace(/\swidth="[^"]*"/i, '')
      .replace(/\sheight="[^"]*"/i, '')
      .replace(/\sstyle="[^"]*"/i, '')
      .trim();

    if (!/\bxmlns=/.test(nextAttrs)) {
      nextAttrs += ' xmlns="http://www.w3.org/2000/svg"';
    }
    if (!/\bviewBox=/.test(nextAttrs)) {
      nextAttrs += ' viewBox="0 0 512 512"';
    }
    if (!/\bpreserveAspectRatio=/.test(nextAttrs)) {
      nextAttrs += ' preserveAspectRatio="xMidYMid meet"';
    }
    return `<svg ${nextAttrs} width="512" height="512" style="overflow: visible">`;
  });

  return output;
}

function extractFrame(level) {
  const match = html.match(
    new RegExp(`<div class="frame-lv${level}[^"]*"[^>]*>[\\s\\S]*?(<svg[\\s\\S]*?</svg>)`, 'i'),
  );
  if (!match) {
    throw new Error(`Could not find frame-lv${level}`);
  }
  return normalizeSvg(match[1]);
}

await fs.mkdir(assetDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const page = await browser.newPage({
  viewport: { width: 512, height: 512 },
  deviceScaleFactor: 1,
});

const exported = [];

for (let level = 1; level <= 7; level += 1) {
  const svg = extractFrame(level);
  const svgName = `avatar_frame_lv${level}.svg`;
  const pngName = `avatar_frame_lv${level}.png`;
  const svgPath = path.join(assetDir, svgName);
  const pngPath = path.join(assetDir, pngName);
  const sourceSvgPath = path.join(sourceDir, svgName);

  await fs.writeFile(svgPath, svg, 'utf8');
  await fs.writeFile(sourceSvgPath, svg, 'utf8');

  await page.setContent(
    `<!doctype html><html><head><style>
      html, body { margin: 0; width: 512px; height: 512px; background: transparent; overflow: hidden; }
      svg { display: block; width: 512px; height: 512px; }
    </style></head><body>${svg}</body></html>`,
  );
  await page.screenshot({ path: pngPath, omitBackground: true });
  exported.push({ level, svg: svgPath, png: pngPath });
}

await browser.close();

console.log(JSON.stringify(exported, null, 2));
