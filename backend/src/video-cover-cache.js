import { createHash, randomUUID } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import path from 'node:path';
import { config } from './config.js';
import { validateUploadBytes } from './upload-security.js';

const allowedTypes = new Map([
  ['image/jpeg', 'jpg'],
  ['image/jpg', 'jpg'],
  ['image/png', 'png'],
  ['image/webp', 'webp'],
  ['image/gif', 'gif'],
]);

export async function mirrorVideoCover(rawUrl, { fetchImpl = fetch } = {}) {
  let url = new URL(String(rawUrl || ''));
  for (let redirect = 0; redirect <= 2; redirect += 1) {
    await assertPublicHttpsUrl(url);
    const response = await fetchImpl(url, {
      redirect: 'manual',
      signal: AbortSignal.timeout(8000),
      headers: { Accept: 'image/avif,image/webp,image/png,image/jpeg,image/gif' },
    });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get('location');
      if (!location || redirect === 2) throw new Error('video_cover_redirect_invalid');
      url = new URL(location, url);
      continue;
    }
    if (!response.ok) throw new Error('video_cover_download_failed');
    const declared = Number(response.headers.get('content-length') || 0);
    if (declared > config.videoCoverMaxBytes) throw new Error('video_cover_too_large');
    const bytes = Buffer.from(await response.arrayBuffer());
    if (!bytes.length || bytes.length > config.videoCoverMaxBytes) {
      throw new Error('video_cover_too_large');
    }
    const mime = String(response.headers.get('content-type') || '')
      .split(';')[0]
      .trim()
      .toLowerCase();
    const extension = allowedTypes.get(mime);
    if (!extension || !validateUploadBytes(mime, bytes)) {
      throw new Error('video_cover_invalid_image');
    }
    const digest = createHash('sha256').update(bytes).digest('hex');
    const fileName = `${digest}.${extension}`;
    await mkdir(config.videoCoverDir, { recursive: true });
    const target = path.join(config.videoCoverDir, fileName);
    const temporary = path.join(config.videoCoverDir, `.${fileName}.${randomUUID()}.uploading`);
    try {
      await writeFile(temporary, bytes, { flag: 'wx' });
      await rename(temporary, target).catch(async (error) => {
        if (error?.code !== 'EEXIST') throw error;
        await rm(temporary, { force: true });
      });
    } finally {
      await rm(temporary, { force: true });
    }
    return `/video-covers/files/${fileName}`;
  }
  throw new Error('video_cover_redirect_invalid');
}

async function assertPublicHttpsUrl(url) {
  if (url.protocol !== 'https:' || url.username || url.password || !url.hostname) {
    throw new Error('video_cover_url_invalid');
  }
  const addresses = isIP(url.hostname)
    ? [{ address: url.hostname }]
    : await lookup(url.hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new Error('video_cover_host_private');
  }
}

function isPrivateAddress(value) {
  const address = String(value || '').toLowerCase();
  if (address.includes(':')) {
    return address === '::1' || address.startsWith('fc') || address.startsWith('fd') || address.startsWith('fe8') || address.startsWith('fe9') || address.startsWith('fea') || address.startsWith('feb');
  }
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) return true;
  return parts[0] === 10 || parts[0] === 127 ||
    (parts[0] === 169 && parts[1] === 254) ||
    (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168) ||
    parts[0] === 0 || parts[0] >= 224;
}

export const videoCoverCacheInternals = { isPrivateAddress };
