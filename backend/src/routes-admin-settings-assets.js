import { randomUUID } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";

import { config } from "./config.js";
import {
  isManagedUploadRetired,
  referencedUploadUrls,
  retireManagedUploadKey,
} from "./upload-lifecycle.js";
import { enforceRateLimits } from "./rate-limit.js";
import {
  inspectUserUploadUsage,
  managedUploadKeyFromAnyUrl,
  pruneOrphanedUserUploads,
  validateUploadBytes,
  withUploadLock,
  writeUploadAtomically,
} from "./upload-security.js";
import { badRequest } from "./validators.js";

const maxAvatarBytes = 3 * 1024 * 1024;
const avatarFolder = "chatbot-avatars";
const avatarFolders = new Set([avatarFolder]);
const avatarExtensions = new Map([
  ["image/jpeg", "jpg"],
  ["image/jpg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);

export async function adminSettingsAssetRoutes(app) {
  app.get("/uploads/content/chatbot-avatars/:file", async (request, reply) => {
    return serveAvatar(request.params.file, reply);
  });

  app.post(
    "/admin/settings/chat-bot/avatar",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      const limited = enforceRateLimits(request, reply, [
        {
          scope: "admin_chat_bot_avatar_upload_user",
          key: request.user.id,
          limit: 30,
          windowMs: 60 * 60 * 1000,
          error: "chat_bot_avatar_upload_rate_limited",
        },
        {
          scope: "admin_chat_bot_avatar_upload_ip",
          key: request.ip,
          limit: 60,
          windowMs: 60 * 60 * 1000,
          error: "chat_bot_avatar_upload_rate_limited",
        },
      ]);
      if (limited) return limited;
      return uploadAvatar(request);
    },
  );
}

export function requireExistingChatBotAvatar(url) {
  const value = String(url || "").trim();
  if (!value) return "";
  let parsed;
  try {
    parsed = new URL(value, "http://local.invalid");
  } catch {
    throw badRequest("chat_bot_avatar_upload_required");
  }
  if (parsed.origin !== "http://local.invalid") {
    throw badRequest("chat_bot_avatar_upload_required");
  }
  const key = managedUploadKeyFromAnyUrl({
    url: value,
    apiPrefix: config.apiPrefix,
    folders: avatarFolders,
  });
  if (!key) throw badRequest("chat_bot_avatar_upload_required");
  const [folder, file] = key.split("/");
  const filePath = path.join(config.rootDir, "data", "uploads", folder, file);
  if (isManagedUploadRetired(folder, file) || !existsSync(filePath)) {
    throw badRequest("chat_bot_avatar_not_found");
  }
  return `${config.apiPrefix}/uploads/content/${folder}/${file}`;
}

export function existingChatBotAvatarOrEmpty(url) {
  try {
    return requireExistingChatBotAvatar(url);
  } catch {
    return "";
  }
}

async function uploadAvatar(request) {
  let upload;
  try {
    upload = await request.file();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("chat_bot_avatar_file_too_large");
    }
    throw error;
  }
  if (!upload) throw badRequest("chat_bot_avatar_file_required");
  const mimeType = String(upload.mimetype || "").trim().toLowerCase();
  const extension = avatarExtensions.get(mimeType);
  if (!extension) throw badRequest("chat_bot_avatar_type_invalid");

  let bytes;
  try {
    bytes = await upload.toBuffer();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("chat_bot_avatar_file_too_large");
    }
    throw error;
  }
  if (!bytes.length) throw badRequest("chat_bot_avatar_file_required");
  if (bytes.length > maxAvatarBytes || upload.file?.truncated) {
    throw payloadTooLarge("chat_bot_avatar_file_too_large");
  }
  if (!validateUploadBytes(mimeType, bytes)) {
    throw badRequest("chat_bot_avatar_content_invalid");
  }

  const fileName = await withUploadLock(request.user.id, async () => {
    try {
      await pruneOrphanedUserUploads({
        rootDir: config.rootDir,
        apiPrefix: config.apiPrefix,
        folders: avatarFolders,
        userId: request.user.id,
        referencedUrls: referencedUploadUrls(),
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: config.uploadOrphanGraceMs,
      });
    } catch (error) {
      request.log?.warn?.(
        { uploadLifecycle: { phase: "chat_bot_avatar_orphan_prune", errorCode: error?.code || "unknown" } },
        "chat bot avatar orphan cleanup failed",
      );
    }
    const usage = await inspectUserUploadUsage({
      rootDir: config.rootDir,
      folders: avatarFolders,
      userId: request.user.id,
    });
    const maxFiles = Math.max(1, config.uploadMaxFilesPerUser);
    const maxBytes = Math.max(maxAvatarBytes, config.uploadMaxBytesPerUser);
    if (usage.files >= maxFiles) throw badRequest("upload_file_quota_exceeded");
    if (usage.bytes + bytes.length > maxBytes) {
      throw badRequest("upload_storage_quota_exceeded");
    }
    const generated = `${request.user.id}-${Date.now()}-${randomUUID()}.${extension}`;
    await writeUploadAtomically({
      directory: path.join(config.rootDir, "data", "uploads", avatarFolder),
      fileName: generated,
      bytes,
    });
    return generated;
  });

  return {
    url: `${config.apiPrefix}/uploads/content/${avatarFolder}/${fileName}`,
    mimeType,
    size: bytes.length,
  };
}

async function serveAvatar(rawFile, reply) {
  const file = String(rawFile || "");
  if (!/^[a-z0-9-]+\.(?:jpe?g|png|webp)$/i.test(file)) {
    throw badRequest("file is invalid");
  }
  if (isManagedUploadRetired(avatarFolder, file)) throw notFound("file_not_found");
  const filePath = path.join(config.rootDir, "data", "uploads", avatarFolder, file);
  try {
    const info = await stat(filePath);
    if (!info.isFile()) throw notFound("file_not_found");
  } catch (error) {
    if (error?.statusCode === 404) throw error;
    if (error?.code !== "ENOENT") throw error;
    throw notFound("file_not_found");
  }
  return reply
    .header("Cache-Control", "public, max-age=31536000, immutable")
    .header("X-Content-Type-Options", "nosniff")
    .type(contentType(file))
    .send(createReadStream(filePath));
}

function contentType(file) {
  const extension = path.extname(file).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  return "image/jpeg";
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}

function payloadTooLarge(message) {
  const error = new Error(message);
  error.statusCode = 413;
  return error;
}
