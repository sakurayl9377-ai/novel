import { randomUUID } from "node:crypto";
import { createReadStream, statSync } from "node:fs";
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
  managedUploadKeyFromUrl,
  pruneOrphanedUserUploads,
  validateUploadBytes,
  withUploadLock,
  writeUploadAtomically,
} from "./upload-security.js";
import { badRequest } from "./validators.js";

const maxBannerBytes = 5 * 1024 * 1024;
const campaignBannerFolder = "campaign-banners";
const campaignBannerFolders = new Set([campaignBannerFolder]);
const bannerExtensions = new Map([
  ["image/jpeg", "jpg"],
  ["image/jpg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);

export async function campaignBannerRoutes(app) {
  app.get("/uploads/content/campaign-banners/:file", async (request, reply) => {
    return serveCampaignBanner(request.params.file, reply);
  });

  app.post(
    "/admin/growth/campaign-banners",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      const limited = enforceRateLimits(request, reply, [
        {
          scope: "admin_campaign_banner_upload_user",
          key: request.user.id,
          limit: 40,
          windowMs: 60 * 60 * 1000,
          error: "campaign_banner_upload_rate_limited",
        },
        {
          scope: "admin_campaign_banner_upload_ip",
          key: request.ip,
          limit: 80,
          windowMs: 60 * 60 * 1000,
          error: "campaign_banner_upload_rate_limited",
        },
      ]);
      if (limited) return limited;
      return uploadCampaignBanner(request);
    },
  );
}

export function requireOwnedCampaignBanner(url, userId) {
  const key = managedUploadKeyFromUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: campaignBannerFolders,
    userId,
  });
  if (!key) throw badRequest("campaign_banner_upload_required");
  return requireCampaignBannerKey(key);
}

export function requireExistingCampaignBanner(url) {
  const key = managedUploadKeyFromAnyUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: campaignBannerFolders,
  });
  if (!key) throw badRequest("campaign_banner_upload_required");
  return requireCampaignBannerKey(key);
}

async function uploadCampaignBanner(request) {
  let upload;
  try {
    upload = await request.file();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("campaign_banner_file_too_large");
    }
    throw error;
  }
  if (!upload) throw badRequest("campaign_banner_file_required");
  const mimeType = String(upload.mimetype || "").trim().toLowerCase();
  const extension = bannerExtensions.get(mimeType);
  if (!extension) throw badRequest("campaign_banner_type_invalid");

  let bytes;
  try {
    bytes = await upload.toBuffer();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("campaign_banner_file_too_large");
    }
    throw error;
  }
  if (!bytes.length) throw badRequest("campaign_banner_file_required");
  if (bytes.length > maxBannerBytes || upload.file?.truncated) {
    throw payloadTooLarge("campaign_banner_file_too_large");
  }
  if (!validateUploadBytes(mimeType, bytes)) {
    throw badRequest("campaign_banner_content_invalid");
  }

  const fileName = await withUploadLock(request.user.id, async () => {
    try {
      await pruneOrphanedUserUploads({
        rootDir: config.rootDir,
        apiPrefix: config.apiPrefix,
        folders: campaignBannerFolders,
        userId: request.user.id,
        referencedUrls: referencedUploadUrls(),
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: config.uploadOrphanGraceMs,
      });
    } catch (error) {
      request.log?.warn?.(
        { uploadLifecycle: { phase: "campaign_banner_orphan_prune", errorCode: error?.code || "unknown" } },
        "campaign banner orphan cleanup failed",
      );
    }
    const usage = await inspectUserUploadUsage({
      rootDir: config.rootDir,
      folders: campaignBannerFolders,
      userId: request.user.id,
    });
    const maxFiles = Math.max(1, config.uploadMaxFilesPerUser);
    const maxBytes = Math.max(maxBannerBytes, config.uploadMaxBytesPerUser);
    if (usage.files >= maxFiles) throw badRequest("upload_file_quota_exceeded");
    if (usage.bytes + bytes.length > maxBytes) {
      throw badRequest("upload_storage_quota_exceeded");
    }
    const generated = `${request.user.id}-${Date.now()}-${randomUUID()}.${extension}`;
    await writeUploadAtomically({
      directory: path.join(config.rootDir, "data", "uploads", campaignBannerFolder),
      fileName: generated,
      bytes,
    });
    return generated;
  });

  return {
    url: `${config.apiPrefix}/uploads/content/${campaignBannerFolder}/${fileName}`,
    mimeType,
    size: bytes.length,
  };
}

async function serveCampaignBanner(rawFile, reply) {
  const file = String(rawFile || "");
  if (!/^[a-z0-9-]+\.(?:jpe?g|png|webp)$/i.test(file)) {
    throw badRequest("file is invalid");
  }
  if (isManagedUploadRetired(campaignBannerFolder, file)) {
    throw notFound("file_not_found");
  }
  const filePath = path.join(
    config.rootDir,
    "data",
    "uploads",
    campaignBannerFolder,
    file,
  );
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
    .type(campaignBannerContentType(file))
    .send(createReadStream(filePath));
}

function requireCampaignBannerKey(key) {
  const [, file] = key.split("/");
  if (!file || isManagedUploadRetired(campaignBannerFolder, file)) {
    throw notFound("campaign_banner_not_found");
  }
  const filePath = path.join(
    config.rootDir,
    "data",
    "uploads",
    campaignBannerFolder,
    file,
  );
  try {
    const info = statSyncSafe(filePath);
    if (!info?.isFile()) throw notFound("campaign_banner_not_found");
  } catch (error) {
    if (error?.statusCode === 404) throw error;
    throw notFound("campaign_banner_not_found");
  }
  return `${config.apiPrefix}/uploads/content/${campaignBannerFolder}/${file}`;
}

function statSyncSafe(filePath) {
  try {
    return statSync(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function campaignBannerContentType(file) {
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
