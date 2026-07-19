import path from "node:path";
import { randomUUID } from "node:crypto";
import { mkdir, readdir, rename, rm, stat, writeFile } from "node:fs/promises";

const uploadLocks = new Map();
const managedUploadFilePattern =
  /^[a-z0-9-]+\.(?:aac|gif|jpe?g|m4a|mp3|ogg|pdf|png|txt|wav|webm|webp|zip)$/i;
const managedUploadTemporaryPattern =
  /^\.\d+-[a-z0-9-]+\.(?:aac|gif|jpe?g|m4a|mp3|ogg|pdf|png|txt|wav|webm|webp|zip)\.[a-z0-9-]+\.uploading$/i;

export const managedUploadFolders = new Set([
  "avatars",
  "banners",
  "dynamic-avatars",
  "photos",
  "chat-images",
  "chat-audio",
  "chat-files",
  "novel-covers",
  "shop-previews",
  "campaign-banners",
]);

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

export async function writeUploadAtomically({
  directory,
  fileName,
  bytes,
  operations = {},
}) {
  if (!managedUploadFilePattern.test(String(fileName || ""))) {
    throw new Error("upload_file_name_invalid");
  }
  const makeDirectory = operations.mkdir || mkdir;
  const write = operations.writeFile || writeFile;
  const move = operations.rename || rename;
  const remove = operations.rm || rm;
  await makeDirectory(directory, { recursive: true });
  const finalPath = path.join(directory, fileName);
  const temporaryPath = path.join(
    directory,
    `.${fileName}.${randomUUID()}.uploading`,
  );
  try {
    await write(temporaryPath, bytes, { flag: "wx" });
    await move(temporaryPath, finalPath);
    return finalPath;
  } catch (error) {
    await Promise.allSettled([remove(temporaryPath, { force: true })]);
    throw error;
  }
}

export function managedUploadKeyFromUrl({
  url,
  apiPrefix = "",
  folders,
  userId,
}) {
  const key = managedUploadKeyFromAnyUrl({ url, apiPrefix, folders });
  if (!key) return null;
  const [, file] = splitManagedUploadKey(key);
  const ownerPrefix = `${Number(userId)}-`;
  return file.startsWith(ownerPrefix) ? key : null;
}

export async function pruneOrphanedUserUploads({
  rootDir,
  apiPrefix,
  folders,
  userId,
  referencedUrls = [],
  retireManagedFile,
  graceMs,
  now = Date.now(),
}) {
  if (typeof retireManagedFile !== "function") {
    throw new Error("managed_upload_retirement_coordinator_required");
  }
  const allowedFolders = folders instanceof Set ? folders : new Set(folders || []);
  const referencedKeys = managedUploadKeys({
    urls: referencedUrls,
    apiPrefix,
    folders: allowedFolders,
    userId,
  });
  const ownerPrefix = `${Number(userId)}-`;
  const minimumAgeMs = Math.max(60_000, Number(graceMs) || 86_400_000);
  let removed = 0;
  let cleanupError = null;
  for (const folder of allowedFolders) {
    const directory = path.join(rootDir, "data", "uploads", folder);
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      if (
        !entry.isFile() ||
        !entry.name.startsWith(ownerPrefix) ||
        !managedUploadFilePattern.test(entry.name) ||
        referencedKeys.has(`${folder}/${entry.name}`)
      ) {
        continue;
      }
      const filePath = path.join(directory, entry.name);
      let info;
      try {
        info = await stat(filePath);
      } catch (error) {
        if (error?.code === "ENOENT") continue;
        throw error;
      }
      if (!info.isFile() || now - info.mtimeMs < minimumAgeMs) continue;
      try {
        const result = await retireManagedFile({
          key: `${folder}/${entry.name}`,
          filePath,
        });
        if (result?.retired === true || result === true) removed += 1;
      } catch (error) {
        cleanupError ||= error;
      }
    }
  }
  if (cleanupError) throw cleanupError;
  return removed;
}

export async function pruneOrphanedUploads({
  rootDir,
  apiPrefix,
  folders,
  referencedUrls = [],
  refreshReferencedUrls,
  retireManagedFile,
  graceMs,
  now = Date.now(),
}) {
  const allowedFolders = folders instanceof Set ? folders : new Set(folders || []);
  const referencedKeys = managedUploadKeysForAnyUser({
    urls: referencedUrls,
    apiPrefix,
    folders: allowedFolders,
  });
  const minimumAgeMs = Math.max(60_000, Number(graceMs) || 86_400_000);
  const candidatesByOwner = new Map();
  for (const folder of allowedFolders) {
    const directory = path.join(rootDir, "data", "uploads", folder);
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const isTemporary = managedUploadTemporaryPattern.test(entry.name);
      const isManagedFinal =
        /^\d+-/.test(entry.name) && managedUploadFilePattern.test(entry.name);
      if (
        (!isTemporary && !isManagedFinal) ||
        (isManagedFinal && referencedKeys.has(`${folder}/${entry.name}`))
      ) {
        continue;
      }
      const filePath = path.join(directory, entry.name);
      let info;
      try {
        info = await stat(filePath);
      } catch (error) {
        if (error?.code === "ENOENT") continue;
        throw error;
      }
      if (!info.isFile() || now - info.mtimeMs < minimumAgeMs) continue;
      const owner = /^\.?([0-9]+)-/.exec(entry.name)?.[1];
      if (!owner) continue;
      if (!candidatesByOwner.has(owner)) candidatesByOwner.set(owner, []);
      candidatesByOwner.get(owner).push({
        filePath,
        key: `${folder}/${entry.name}`,
        isManagedFinal,
      });
    }
  }

  let removed = 0;
  let cleanupError = null;
  for (const [owner, candidates] of candidatesByOwner) {
    try {
      await withUploadLock(owner, async () => {
        const currentReferences = typeof refreshReferencedUrls === "function"
          ? managedUploadKeysForAnyUser({
              urls: await refreshReferencedUrls(),
              apiPrefix,
              folders: allowedFolders,
            })
          : referencedKeys;
        for (const candidate of candidates) {
          if (
            candidate.isManagedFinal &&
            currentReferences.has(candidate.key)
          ) {
            continue;
          }
          try {
            if (candidate.isManagedFinal) {
              if (typeof retireManagedFile !== "function") {
                throw new Error(
                  "managed_upload_retirement_coordinator_required",
                );
              }
              const result = await retireManagedFile({
                key: candidate.key,
                filePath: candidate.filePath,
              });
              if (result?.retired === true || result === true) removed += 1;
            } else {
              await rm(candidate.filePath, { force: true });
              removed += 1;
            }
          } catch (error) {
            cleanupError ||= error;
          }
        }
      });
    } catch (error) {
      cleanupError ||= error;
    }
  }
  if (cleanupError) throw cleanupError;
  return removed;
}

function managedUploadKeys({ urls, apiPrefix, folders, userId }) {
  const keys = new Set();
  for (const url of urls || []) {
    const key = managedUploadKeyFromUrl({ url, apiPrefix, folders, userId });
    if (key) keys.add(key);
  }
  return keys;
}

function managedUploadKeysForAnyUser({ urls, apiPrefix, folders }) {
  const keys = new Set();
  for (const url of urls || []) {
    const key = managedUploadKeyFromAnyUrl({ url, apiPrefix, folders });
    if (key) keys.add(key);
  }
  return keys;
}

function splitManagedUploadKey(key) {
  const separator = String(key || "").indexOf("/");
  if (separator <= 0) return ["", ""];
  return [key.slice(0, separator), key.slice(separator + 1)];
}

export function managedUploadKeyFromAnyUrl({ url, apiPrefix, folders }) {
  const allowedFolders = folders instanceof Set ? folders : new Set(folders || []);
  const normalizedPrefix = normalizeUrlPrefix(apiPrefix);
  let pathname;
  try {
    pathname = new URL(String(url || ""), "http://local.invalid").pathname;
  } catch {
    return null;
  }
  const profilePrefix = `${normalizedPrefix}/uploads/profile/`;
  const contentPrefix = `${normalizedPrefix}/uploads/content/`;
  const legacyAvatarPrefix = `${normalizedPrefix}/uploads/avatars/`;
  let folder = "";
  let file = "";
  const profileMarker = "/uploads/profile/";
  const contentMarker = "/uploads/content/";
  const legacyAvatarMarker = "/uploads/avatars/";
  const profileStart = pathname.startsWith(profilePrefix)
    ? profilePrefix.length
    : pathname.lastIndexOf(profileMarker) >= 0
      ? pathname.lastIndexOf(profileMarker) + profileMarker.length
      : -1;
  const legacyStart = pathname.startsWith(legacyAvatarPrefix)
    ? legacyAvatarPrefix.length
    : pathname.lastIndexOf(legacyAvatarMarker) >= 0
      ? pathname.lastIndexOf(legacyAvatarMarker) + legacyAvatarMarker.length
      : -1;
  const contentStart = pathname.startsWith(contentPrefix)
    ? contentPrefix.length
    : pathname.lastIndexOf(contentMarker) >= 0
      ? pathname.lastIndexOf(contentMarker) + contentMarker.length
      : -1;
  const structuredStart = profileStart >= 0 ? profileStart : contentStart;
  if (structuredStart >= 0) {
    const remainder = pathname.slice(structuredStart);
    const separator = remainder.indexOf("/");
    if (separator <= 0 || remainder.indexOf("/", separator + 1) >= 0) return null;
    folder = decodeUrlSegment(remainder.slice(0, separator));
    file = decodeUrlSegment(remainder.slice(separator + 1));
  } else if (legacyStart >= 0) {
    folder = "avatars";
    file = decodeUrlSegment(pathname.slice(legacyStart));
  } else {
    return null;
  }
  if (folder == null || file == null) return null;
  folder = folder.toLowerCase();
  file = file.toLowerCase();
  if (!allowedFolders.has(folder) || !managedUploadFilePattern.test(file)) {
    return null;
  }
  return `${folder}/${file}`;
}

function decodeUrlSegment(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

function normalizeUrlPrefix(value) {
  const text = String(value || "").trim();
  if (!text || text === "/") return "";
  return `/${text.replace(/^\/+|\/+$/g, "")}`;
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
