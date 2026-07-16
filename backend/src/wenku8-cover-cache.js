import { createHash, randomUUID } from 'node:crypto';
import { access, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';
import { validateUploadBytes } from './upload-security.js';

const inflight = new Map();

export function wenku8CoverFileName(bookId) {
  const normalizedId = normalizeBookId(bookId);
  const digest = createHash('sha256')
    .update(`wenku8-cover:${normalizedId}`)
    .digest('hex');
  return `${digest}.jpg`;
}

export async function ensureWenku8Cover(bookId, { fetchImpl = fetch } = {}) {
  const normalizedId = normalizeBookId(bookId);
  const fileName = wenku8CoverFileName(normalizedId);
  const target = path.join(config.videoCoverDir, fileName);
  try {
    await access(target);
    return target;
  } catch {
    // Download and persist the cover below.
  }

  const existing = inflight.get(normalizedId);
  if (existing) return existing;
  const task = downloadWenku8Cover(normalizedId, target, fetchImpl).finally(() => {
    inflight.delete(normalizedId);
  });
  inflight.set(normalizedId, task);
  return task;
}

async function downloadWenku8Cover(bookId, target, fetchImpl) {
  const shard = Math.floor(Number(bookId) / 1000);
  const url = `https://img.wenku8.com/image/${shard}/${bookId}/${bookId}s.jpg`;
  const response = await fetchImpl(url, {
    redirect: 'error',
    signal: AbortSignal.timeout(10000),
    headers: {
      Accept: 'image/jpeg,image/*;q=0.8',
      Referer: 'https://www.wenku8.cc/',
      'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/125.0 Mobile Safari/537.36',
    },
  });
  if (!response.ok) throw new Error('wenku8_cover_download_failed');
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > config.videoCoverMaxBytes) {
    throw new Error('wenku8_cover_too_large');
  }

  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length || bytes.length > config.videoCoverMaxBytes) {
    throw new Error('wenku8_cover_too_large');
  }
  const mime = String(response.headers.get('content-type') || '')
    .split(';')[0]
    .trim()
    .toLowerCase();
  if (mime !== 'image/jpeg' || !validateUploadBytes(mime, bytes)) {
    throw new Error('wenku8_cover_invalid_image');
  }

  await mkdir(config.videoCoverDir, { recursive: true });
  const temporary = path.join(
    config.videoCoverDir,
    `.${path.basename(target)}.${randomUUID()}.downloading`,
  );
  try {
    await writeFile(temporary, bytes, { flag: 'wx' });
    await rename(temporary, target).catch(async (error) => {
      if (error?.code !== 'EEXIST') throw error;
      await rm(temporary, { force: true });
    });
  } finally {
    await rm(temporary, { force: true });
  }
  return target;
}

function normalizeBookId(value) {
  const normalized = String(value || '').trim();
  if (!/^\d{1,9}$/.test(normalized) || Number(normalized) <= 0) {
    throw new Error('wenku8_cover_book_id_invalid');
  }
  return normalized;
}
