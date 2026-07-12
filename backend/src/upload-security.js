import path from "node:path";
import { readdir, stat } from "node:fs/promises";

const uploadLocks = new Map();

export function validateUploadBytes(mimeType, bytes) {
  const buffer = Buffer.from(bytes || []);
  if (!buffer.length) return false;
  switch (mimeType) {
    case "image/jpeg":
    case "image/jpg":
      return startsWith(buffer, [0xff, 0xd8, 0xff]);
    case "image/png":
      return startsWith(buffer, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case "image/gif":
      return ["GIF87a", "GIF89a"].includes(buffer.toString("ascii", 0, 6));
    case "image/webp":
      return buffer.length >= 12 &&
        buffer.toString("ascii", 0, 4) === "RIFF" &&
        buffer.toString("ascii", 8, 12) === "WEBP";
    case "audio/aac":
      return buffer.length >= 2 && buffer[0] === 0xff && (buffer[1] & 0xf6) === 0xf0;
    case "audio/mp4":
      return buffer.length >= 12 && buffer.toString("ascii", 4, 8) === "ftyp";
    case "audio/mpeg":
      return buffer.toString("ascii", 0, 3) === "ID3" ||
        (buffer.length >= 2 && buffer[0] === 0xff && (buffer[1] & 0xe0) === 0xe0);
    case "audio/ogg":
      return buffer.toString("ascii", 0, 4) === "OggS";
    case "audio/wav":
      return buffer.length >= 12 &&
        buffer.toString("ascii", 0, 4) === "RIFF" &&
        buffer.toString("ascii", 8, 12) === "WAVE";
    case "audio/webm":
      return startsWith(buffer, [0x1a, 0x45, 0xdf, 0xa3]);
    case "application/pdf":
      return buffer.toString("ascii", 0, 5) === "%PDF-";
    case "application/zip":
      return startsWith(buffer, [0x50, 0x4b, 0x03, 0x04]) ||
        startsWith(buffer, [0x50, 0x4b, 0x05, 0x06]) ||
        startsWith(buffer, [0x50, 0x4b, 0x07, 0x08]);
    case "text/plain":
      return isPlainUtf8(buffer);
    default:
      return false;
  }
}

export async function inspectUserUploadUsage({ rootDir, folders, userId }) {
  const prefix = `${Number(userId)}-`;
  let files = 0;
  let bytes = 0;
  for (const folder of folders) {
    const directory = path.join(rootDir, "data", "uploads", folder);
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.startsWith(prefix)) continue;
      const info = await stat(path.join(directory, entry.name));
      if (!info.isFile()) continue;
      files += 1;
      bytes += info.size;
    }
  }
  return { files, bytes };
}

export async function withUploadLock(userId, task) {
  const key = String(userId);
  const previous = uploadLocks.get(key) || Promise.resolve();
  let release;
  const current = new Promise((resolve) => {
    release = resolve;
  });
  uploadLocks.set(key, current);
  await previous;
  try {
    return await task();
  } finally {
    release();
    if (uploadLocks.get(key) === current) uploadLocks.delete(key);
  }
}

function startsWith(buffer, signature) {
  if (buffer.length < signature.length) return false;
  return signature.every((value, index) => buffer[index] === value);
}

function isPlainUtf8(buffer) {
  if (buffer.includes(0)) return false;
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(buffer);
    return true;
  } catch {
    return false;
  }
}
