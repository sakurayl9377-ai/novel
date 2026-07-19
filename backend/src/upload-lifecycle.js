import { rmSync } from "node:fs";
import path from "node:path";

import { config } from "./config.js";
import { all, db, one, run } from "./db.js";
import {
  managedUploadKeyFromUrl,
  managedUploadFolders,
  pruneOrphanedUploads,
} from "./upload-security.js";

let sweepTimer = null;
let activeSweep = null;
let retryTimer = null;
let activeRetry = null;
let retirementRetryTimer = null;
const pendingRetirements = new Map();
const managedUploadReferenceColumns = [
  ["users", "avatar_url"],
  ["users", "profile_banner_url"],
  ["users", "dynamic_avatar_url"],
  ["profile_photos", "image_url"],
  ["chat_messages", "media_url"],
  ["chat_rooms", "avatar_url"],
  ["content_catalog", "cover_url"],
  ["home_placements", "custom_image_url"],
  ["campaigns", "banner_url"],
  ["ai_novels", "cover_url"],
  ["shop_items", "asset_value"],
  ["shop_items", "preview_url"],
  ["app_settings", "value"],
];

export function referencedUploadUrls() {
  const references = all(
    `SELECT avatar_url AS url FROM users WHERE avatar_url <> ''
     UNION ALL
     SELECT profile_banner_url AS url FROM users WHERE profile_banner_url <> ''
     UNION ALL
     SELECT dynamic_avatar_url AS url FROM users WHERE dynamic_avatar_url <> ''
     UNION ALL
     SELECT image_url AS url FROM profile_photos WHERE image_url <> ''
     UNION ALL
     SELECT media_url AS url FROM chat_messages WHERE media_url <> ''
     UNION ALL
     SELECT avatar_url AS url FROM chat_rooms WHERE avatar_url <> ''
     UNION ALL
     SELECT cover_url AS url FROM content_catalog WHERE cover_url <> ''
     UNION ALL
     SELECT custom_image_url AS url FROM home_placements WHERE custom_image_url <> ''
     UNION ALL
     SELECT banner_url AS url FROM campaigns WHERE banner_url <> ''
     UNION ALL
     SELECT cover_url AS url FROM ai_novels WHERE cover_url <> ''
     UNION ALL
     SELECT asset_value AS url FROM shop_items WHERE asset_value <> ''
     UNION ALL
     SELECT preview_url AS url FROM shop_items WHERE preview_url <> ''
     UNION ALL
     SELECT value AS url FROM app_settings WHERE value <> ''`,
  ).map((row) => row.url);

  const hasVideoCoverTable = one(
    `SELECT 1 AS present
     FROM sqlite_master
     WHERE type = 'table' AND name = 'video_cover_urls'`,
  );
  if (hasVideoCoverTable) {
    references.push(
      ...all(
        `SELECT cover_url AS url
         FROM video_cover_urls
         WHERE cover_url <> ''`,
      ).map((row) => row.url),
    );
  }
  return references;
}

export function isManagedUploadRetired(folder, fileName) {
  const key = `${String(folder || "").toLowerCase()}/${String(fileName || "").toLowerCase()}`;
  return Boolean(
    one(
      `SELECT 1
       FROM managed_upload_retirements
       WHERE storage_key = ?`,
      [key],
    ),
  );
}

export function retireManagedUploadUrls({ userId, urls, operations = {} }) {
  return retireManagedUploadKeys(
    managedUploadKeysForUser({ userId, urls }),
    operations,
  );
}

export function retireManagedUploadKey({ key, operations = {} }) {
  const managed = managedUploadKeyDetails(key);
  if (!managed) return { retired: false, retiredCount: 0, failedCount: 0 };
  return retireManagedUploadKeys([managed.key], operations);
}

export function markManagedUploadUrlsRetired({ userId, urls }) {
  return markManagedUploadKeys(
    managedUploadKeysForUser({ userId, urls }),
  ).map((managed) => managed.key);
}

export function deleteRetiredManagedUploadKeys(keys, { operations = {} } = {}) {
  const removeFile = operations.rmSync || rmSync;
  let deletedCount = 0;
  let failedCount = 0;
  let retiredCount = 0;
  for (const key of new Set(keys || [])) {
    const managed = managedUploadKeyDetails(key);
    if (
      !managed ||
      !one(
        `SELECT 1
         FROM managed_upload_retirements
         WHERE storage_key = ?`,
        [managed.key],
      )
    ) {
      continue;
    }
    retiredCount += 1;
    const errorCode = removeRetiredUploadFile(managed, removeFile);
    recordRetiredDeleteAttempt(managed, errorCode);
    if (errorCode) failedCount += 1;
    else deletedCount += 1;
  }
  return {
    retired: retiredCount > 0,
    retiredCount,
    deletedCount,
    failedCount,
  };
}

export function retryRetiredUploadDeletes({ operations = {} } = {}) {
  const removeFile = operations.rmSync || rmSync;
  let deletedCount = 0;
  let failedCount = 0;
  for (const row of all(
    `SELECT storage_key
     FROM managed_upload_retirements
     WHERE deleted_at = ''
     ORDER BY retired_at, storage_key`,
  )) {
    const managed = managedUploadKeyDetails(row.storage_key);
    if (!managed) {
      failedCount += 1;
      continue;
    }
    const errorCode = removeRetiredUploadFile(managed, removeFile);
    recordRetiredDeleteAttempt(managed, errorCode);
    if (errorCode) failedCount += 1;
    else deletedCount += 1;
  }
  return { deletedCount, failedCount };
}

function retireManagedUploadKeys(keys, operations) {
  const managedKeys = keys.map(managedUploadKeyDetails).filter(Boolean);
  if (!managedKeys.length) {
    return {
      retired: false,
      retiredCount: 0,
      deletedCount: 0,
      failedCount: 0,
    };
  }

  let marked = [];
  let transactionStarted = false;
  try {
    db.exec("BEGIN IMMEDIATE");
    transactionStarted = true;
    marked = markManagedUploadKeys(managedKeys.map((managed) => managed.key));
    operations.beforeCommit?.();
    db.exec("COMMIT");
    transactionStarted = false;
  } catch (error) {
    if (transactionStarted) {
      try {
        db.exec("ROLLBACK");
      } catch {
        // Preserve the retirement transaction error.
      }
    }
    throw error;
  }
  return deleteRetiredManagedUploadKeys(
    marked.map((managed) => managed.key),
    { operations },
  );
}

function markManagedUploadKeys(keys) {
  const managedKeys = keys.map(managedUploadKeyDetails).filter(Boolean);
  const marked = [];
  for (const managed of managedKeys) {
    if (isManagedUploadStorageKeyReferenced(managed.key)) continue;
    run(
      `INSERT OR IGNORE INTO managed_upload_retirements
         (storage_key, folder, file_name, owner_user_id)
       VALUES (?, ?, ?, ?)`,
      [
        managed.key,
        managed.folder,
        managed.fileName,
        managed.ownerUserId,
      ],
    );
    marked.push(managed);
  }
  return marked;
}

function isManagedUploadStorageKeyReferenced(storageKey) {
  for (const [table, column] of managedUploadReferenceColumns) {
    if (one(
      `SELECT 1
       FROM ${table}
       WHERE managed_upload_key(${column}) = ?
       LIMIT 1`,
      [storageKey],
    )) {
      return true;
    }
  }
  if (
    one(
      `SELECT 1
       FROM sqlite_master
       WHERE type = 'table' AND name = 'video_cover_urls'`,
    ) &&
    one(
      `SELECT 1
       FROM video_cover_urls
       WHERE managed_upload_key(cover_url) = ?
       LIMIT 1`,
      [storageKey],
    )
  ) {
    return true;
  }
  return false;
}

function managedUploadKeysForUser({ userId, urls }) {
  const keys = new Set();
  for (const url of urls || []) {
    const key = managedUploadKeyFromUrl({
      url,
      apiPrefix: config.apiPrefix,
      folders: managedUploadFolders,
      userId,
    });
    if (key) keys.add(key);
  }
  return [...keys];
}

function managedUploadKeyDetails(key) {
  const separator = String(key || "").indexOf("/");
  if (separator <= 0) return null;
  const folder = key.slice(0, separator);
  const fileName = key.slice(separator + 1);
  const ownerUserId = Number(/^(\d+)-/.exec(fileName)?.[1]);
  if (!Number.isSafeInteger(ownerUserId) || ownerUserId <= 0) return null;
  const normalized = managedUploadKeyFromUrl({
    url: `${config.apiPrefix}/uploads/profile/${folder}/${fileName}`,
    apiPrefix: config.apiPrefix,
    folders: managedUploadFolders,
    userId: ownerUserId,
  });
  if (normalized !== key) return null;
  return { key, folder, fileName, ownerUserId };
}

function removeRetiredUploadFile(managed, removeFile) {
  try {
    removeFile(
      path.join(
        config.rootDir,
        "data",
        "uploads",
        managed.folder,
        managed.fileName,
      ),
      { force: true },
    );
    return "";
  } catch (error) {
    return String(error?.code || "upload_delete_failed").slice(0, 80);
  }
}

function recordRetiredDeleteAttempt(managed, errorCode) {
  run(
    `UPDATE managed_upload_retirements
     SET delete_attempts = delete_attempts + 1,
         last_attempt_at = datetime('now'),
         deleted_at = CASE
           WHEN ? = '' THEN datetime('now')
           ELSE deleted_at
         END,
         last_delete_error = ?
     WHERE storage_key = ?`,
    [errorCode, errorCode, managed.key],
  );
}

export function scheduleRetiredUploadDeleteRetry(logger, { delayMs = 1000 } = {}) {
  if (retryTimer || activeRetry) return;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    activeRetry = Promise.resolve()
      .then(() => retryRetiredUploadDeletes())
      .then((result) => {
        if (result.failedCount > 0) {
          logger?.warn?.(
            {
              uploadLifecycle: {
                phase: "retired_delete_retry",
                failed: result.failedCount,
              },
            },
            "retired upload deletion will be retried by the orphan sweep",
          );
        }
      })
      .catch((error) => {
        logger?.warn?.(
          {
            uploadLifecycle: {
              phase: "retired_delete_retry",
              errorCode: error?.code || "retired_upload_retry_failed",
            },
          },
          "retired upload deletion retry failed",
        );
      })
      .finally(() => {
        activeRetry = null;
      });
  }, Math.max(100, Number(delayMs) || 1000));
  retryTimer.unref?.();
}

export function scheduleManagedUploadRetirement({
  userId,
  urls,
  logger,
  delayMs = 1000,
}) {
  const normalizedUserId = Number(userId);
  const normalizedUrls = [...new Set((urls || []).filter(Boolean))];
  if (!Number.isSafeInteger(normalizedUserId) || !normalizedUrls.length) return;
  const key = `${normalizedUserId}:${normalizedUrls.sort().join("\n")}`;
  const previous = pendingRetirements.get(key);
  pendingRetirements.set(key, {
    userId: normalizedUserId,
    urls: normalizedUrls,
    logger,
    attempts: previous?.attempts || 0,
  });
  armManagedUploadRetirementRetry(delayMs);
}

function armManagedUploadRetirementRetry(delayMs) {
  if (retirementRetryTimer || !pendingRetirements.size) return;
  retirementRetryTimer = setTimeout(() => {
    retirementRetryTimer = null;
    const pending = [...pendingRetirements.entries()];
    pendingRetirements.clear();
    for (const [key, item] of pending) {
      try {
        const result = retireManagedUploadUrls({
          userId: item.userId,
          urls: item.urls,
        });
        if (result.failedCount > 0) {
          scheduleRetiredUploadDeleteRetry(item.logger);
        }
      } catch (error) {
        if (item.attempts < 2) {
          pendingRetirements.set(key, {
            ...item,
            attempts: item.attempts + 1,
          });
        }
        item.logger?.warn?.(
          {
            uploadLifecycle: {
              phase: "retirement_retry",
              errorCode: error?.code || "upload_retirement_retry_failed",
            },
          },
          "managed upload retirement retry failed",
        );
      }
    }
    if (pendingRetirements.size) armManagedUploadRetirementRetry(5000);
  }, Math.max(100, Number(delayMs) || 1000));
  retirementRetryTimer.unref?.();
}

export function startUploadOrphanSweeper(logger) {
  if (sweepTimer) return;
  const intervalMs = Math.max(
    60_000,
    Number(config.uploadOrphanSweepIntervalMs) || 60 * 60 * 1000,
  );
  const sweep = () => {
    if (activeSweep) return activeSweep;
    activeSweep = Promise.resolve()
      .then(async () => {
        const retry = retryRetiredUploadDeletes();
        const retired = await pruneOrphanedUploads({
          rootDir: config.rootDir,
          apiPrefix: config.apiPrefix,
          folders: managedUploadFolders,
          referencedUrls: referencedUploadUrls(),
          refreshReferencedUrls: referencedUploadUrls,
          retireManagedFile: ({ key }) => {
            const result = retireManagedUploadKey({ key });
            if (result.failedCount > 0) {
              scheduleRetiredUploadDeleteRetry(logger);
            }
            return result;
          },
          graceMs: config.uploadOrphanGraceMs,
        });
        return { retired, retry };
      })
      .then(({ retired, retry }) => {
        if (retired > 0 || retry.deletedCount > 0) {
          logger?.info?.(
            {
              uploadLifecycle: {
                phase: "orphan_sweep",
                retired,
                retried: retry.deletedCount,
              },
            },
            "stale upload orphans removed",
          );
        }
        if (retry.failedCount > 0) {
          logger?.warn?.(
            {
              uploadLifecycle: {
                phase: "retired_delete_retry",
                failed: retry.failedCount,
              },
            },
            "retired upload deletion will be retried",
          );
        }
      })
      .catch((error) => {
        logger?.warn?.(
          {
            uploadLifecycle: {
              phase: "orphan_sweep",
              errorCode: error?.code || "upload_orphan_sweep_failed",
            },
          },
          "stale upload orphan sweep failed",
        );
      })
      .finally(() => {
        activeSweep = null;
      });
    return activeSweep;
  };

  void sweep();
  sweepTimer = setInterval(() => {
    void sweep();
  }, intervalMs);
  sweepTimer.unref?.();
}

export async function stopUploadOrphanSweeper() {
  if (sweepTimer) clearInterval(sweepTimer);
  sweepTimer = null;
  if (retryTimer) clearTimeout(retryTimer);
  retryTimer = null;
  if (retirementRetryTimer) clearTimeout(retirementRetryTimer);
  retirementRetryTimer = null;
  for (const item of pendingRetirements.values()) {
    try {
      retireManagedUploadUrls({ userId: item.userId, urls: item.urls });
    } catch {
      // A later orphan sweep will retry after the process restarts.
    }
  }
  pendingRetirements.clear();
  if (activeSweep) await activeSweep;
  if (activeRetry) await activeRetry;
}
