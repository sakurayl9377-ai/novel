import { randomUUID } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";

import { config } from "./config.js";
import { all, db, one, run } from "./db.js";
import { levelFromPoints } from "./growth.js";
import {
  isManagedUploadRetired,
  referencedUploadUrls,
  retireManagedUploadKey,
  scheduleManagedUploadRetirement,
  scheduleRetiredUploadDeleteRetry,
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
import {
  badRequest,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const maxPreviewBytes = 3 * 1024 * 1024;
const shopPreviewFolder = "shop-previews";
const shopPreviewFolders = new Set([shopPreviewFolder]);
const shopStatuses = new Set(["inactive", "active", "archived"]);
const previewExtensions = new Map([
  ["image/jpeg", "jpg"],
  ["image/jpg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);

const shopCatalog = [
  {
    type: "profile_skin",
    label: "个人主页皮肤",
    equipSlot: "profile_skin",
    presets: [{ value: "sakura", label: "樱花资料卡" }],
  },
  {
    type: "chat_bubble",
    label: "聊天气泡",
    equipSlot: "chat_bubble",
    presets: [
      { value: "night_sakura", label: "夜樱" },
      { value: "sakura_pink", label: "樱粉" },
      { value: "moon_blue", label: "月蓝" },
      { value: "mint_leaf", label: "薄荷叶" },
      { value: "gold_aurora", label: "鎏金极光" },
    ],
  },
  {
    type: "sticker_pack",
    label: "表情包",
    equipSlot: "sticker_pack",
    presets: [
      { value: "sakura_pack", label: "樱花小剧场" },
      { value: "moon_pack", label: "月光读者" },
    ],
  },
  {
    type: "avatar_frame",
    label: "头像框",
    equipSlot: "avatar_frame",
    presets: [{ value: "lv5_crystal", label: "Lv5 蓝晶" }],
  },
  {
    type: "chat_room_theme",
    label: "聊天室主题",
    equipSlot: "chat_room_theme",
    presets: [{ value: "sakura_glass", label: "樱花玻璃" }],
  },
  {
    type: "avatar_privilege",
    label: "头像权益",
    equipSlot: null,
    presets: [{ value: "dynamic_avatar", label: "动态头像体验券" }],
  },
];
const shopCatalogByType = new Map(shopCatalog.map((item) => [item.type, item]));

export async function adminShopRoutes(app) {
  app.get("/uploads/content/shop-previews/:file", async (request, reply) => {
    return serveShopPreview(request.params.file, reply);
  });

  app.post(
    "/admin/shop/previews",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      const limited = enforceRateLimits(request, reply, [
        {
          scope: "admin_shop_preview_upload_user",
          key: request.user.id,
          limit: 60,
          windowMs: 60 * 60 * 1000,
          error: "shop_preview_upload_rate_limited",
        },
        {
          scope: "admin_shop_preview_upload_ip",
          key: request.ip,
          limit: 120,
          windowMs: 60 * 60 * 1000,
          error: "shop_preview_upload_rate_limited",
        },
      ]);
      if (limited) return limited;
      return uploadShopPreview(request);
    },
  );

  app.get(
    "/admin/shop/workbench",
    { preHandler: app.adminRequired },
    async (request) => shopWorkbench(request.query || {}),
  );

  app.get(
    "/admin/shop/items/:id",
    { preHandler: app.adminRequired },
    async (request) => shopItemDetail(request.params.id, request.query || {}),
  );

  app.post(
    "/admin/shop/items",
    { preHandler: app.adminRequired },
    async (request, reply) => {
      const payload = shopItemPayload(request.body || {});
      if (payload.previewUrl) {
        payload.previewUrl = requireOwnedShopPreview(
          payload.previewUrl,
          request.user.id,
        );
      }
      const id = `shop-${payload.itemType}-${randomUUID()}`;
      inImmediateTransaction(() => {
        validateShopUniqueness(payload);
        run(
          `INSERT INTO shop_items
             (id, name, description, price_coins, item_type, min_level,
              asset_value, preview_url, sort_order, status, revision, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'inactive', 1, datetime('now'))`,
          [
            id,
            payload.name,
            payload.description,
            payload.priceCoins,
            payload.itemType,
            payload.minLevel,
            payload.assetValue,
            payload.previewUrl,
            payload.sortOrder,
          ],
        );
        const created = requireShopItemRow(id);
        recordShopItemEvent({
          itemId: id,
          action: "create",
          before: {},
          after: shopItemSnapshot(created),
          note: payload.changeNote || "创建商品草稿",
          adminUserId: request.user.id,
        });
      });
      return reply.code(201).send({ item: requireAdminShopItem(id) });
    },
  );

  app.patch(
    "/admin/shop/items/:id",
    { preHandler: app.adminRequired },
    async (request) => updateShopItem(request),
  );

  app.post(
    "/admin/shop/items/:id/status",
    { preHandler: app.adminRequired },
    async (request) => changeShopItemStatus(request),
  );
}

function shopWorkbench(query) {
  const { page, pageSize, offset } = pageParams(query);
  const q = optionalString(query.q, 80);
  const status = optionalString(query.status, 20);
  const itemType = optionalString(query.itemType, 40);
  if (status && !shopStatuses.has(status)) {
    throw badRequest("shop_status_invalid");
  }
  if (itemType && !shopCatalogByType.has(itemType)) {
    throw badRequest("shop_item_type_invalid");
  }

  const where = [];
  const params = [];
  if (q) {
    where.push(
      "(s.id LIKE ? OR s.name LIKE ? OR s.description LIKE ? OR s.asset_value LIKE ?)",
    );
    params.push(...Array(4).fill(`%${q}%`));
  }
  if (status) {
    where.push("s.status = ?");
    params.push(status);
  }
  if (itemType) {
    where.push("s.item_type = ?");
    params.push(itemType);
  }
  const clause = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const items = all(
    `${adminShopItemSelect()}
     ${clause}
     ORDER BY CASE s.status
                WHEN 'active' THEN 0
                WHEN 'inactive' THEN 1
                ELSE 2
              END,
              s.sort_order ASC, s.min_level ASC, s.price_coins ASC, s.id ASC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map(adminShopItemJson);
  const total = Number(
    one(`SELECT COUNT(*) AS count FROM shop_items s ${clause}`, params)?.count || 0,
  );

  const statsRow = one(
    `SELECT COUNT(*) AS total_items,
            SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active_items,
            SUM(CASE WHEN status = 'inactive' THEN 1 ELSE 0 END) AS inactive_items,
            SUM(CASE WHEN status = 'archived' THEN 1 ELSE 0 END) AS archived_items
     FROM shop_items`,
  );
  const ownershipRow = one(
    `SELECT COUNT(*) AS inventory_units,
            COUNT(DISTINCT user_id) AS unique_holders
     FROM user_inventory`,
  );
  const equipmentRow = one(
    `SELECT COUNT(*) AS equipment_assignments,
            COUNT(DISTINCT user_id) AS equipped_users
     FROM user_equipment`,
  );
  const revenueRow = one(
    `SELECT COUNT(*) AS redemption_count,
            COALESCE(SUM(CASE WHEN coins_delta < 0 THEN -coins_delta ELSE 0 END), 0)
              AS recorded_revenue
     FROM user_reward_events
     WHERE action = 'shop_redeem' AND related_type = 'shop_item'`,
  );

  return {
    page,
    pageSize,
    total,
    filters: { q, status, itemType },
    stats: {
      totalItems: Number(statsRow?.total_items || 0),
      activeItems: Number(statsRow?.active_items || 0),
      inactiveItems: Number(statsRow?.inactive_items || 0),
      archivedItems: Number(statsRow?.archived_items || 0),
      inventoryUnits: Number(ownershipRow?.inventory_units || 0),
      uniqueHolders: Number(ownershipRow?.unique_holders || 0),
      equipmentAssignments: Number(equipmentRow?.equipment_assignments || 0),
      equippedUsers: Number(equipmentRow?.equipped_users || 0),
      redemptionCount: Number(revenueRow?.redemption_count || 0),
      recordedRevenue: Number(revenueRow?.recorded_revenue || 0),
    },
    integrity: shopIntegrity(),
    statusCounts: shopStatusCounts(),
    typeCounts: shopTypeCounts(),
    catalog: shopCatalog,
    recentRedemptions: recentShopRedemptions(),
    items,
  };
}

function shopItemDetail(rawId, query) {
  const id = requiredString(rawId, "shop item id", 120);
  const item = requireAdminShopItem(id);
  const { page, pageSize, offset } = pageParams({
    page: query.holderPage,
    pageSize: query.holderPageSize,
  });
  const q = optionalString(query.holderQ, 80);
  const where = ["i.item_id = ?"];
  const params = [id];
  if (q) {
    where.push("(CAST(u.id AS TEXT) LIKE ? OR u.nickname LIKE ? OR u.email LIKE ?)");
    params.push(...Array(3).fill(`%${q}%`));
  }
  const clause = where.join(" AND ");
  const holders = all(
    `SELECT u.id, u.nickname, u.email, u.avatar_url, u.status, u.points,
            i.acquired_at,
            COALESCE(GROUP_CONCAT(e.slot, ','), '') AS equipment_slots
     FROM user_inventory i
     JOIN users u ON u.id = i.user_id
     LEFT JOIN user_equipment e
       ON e.user_id = i.user_id AND e.item_id = i.item_id
     WHERE ${clause}
     GROUP BY u.id, i.acquired_at
     ORDER BY i.acquired_at DESC, u.id DESC
     LIMIT ? OFFSET ?`,
    [...params, pageSize, offset],
  ).map((row) => ({
    userId: Number(row.id),
    nickname: row.nickname || "",
    email: row.email || "",
    avatarUrl: row.avatar_url || "",
    status: row.status || "active",
    level: levelFromPoints(row.points || 0),
    acquiredAt: row.acquired_at || "",
    equipmentSlots: String(row.equipment_slots || "")
      .split(",")
      .filter(Boolean),
  }));
  const holderTotal = Number(
    one(
      `SELECT COUNT(*) AS count
       FROM user_inventory i
       JOIN users u ON u.id = i.user_id
       WHERE ${clause}`,
      params,
    )?.count || 0,
  );
  const events = all(
    `SELECT e.*, u.nickname AS admin_nickname, u.email AS admin_email
     FROM shop_item_events e
     JOIN users u ON u.id = e.admin_user_id
     WHERE e.item_id = ?
     ORDER BY e.created_at DESC, e.id DESC
     LIMIT 100`,
    [id],
  ).map(shopItemEventJson);

  return {
    item,
    holders: {
      page,
      pageSize,
      total: holderTotal,
      items: holders,
    },
    events,
  };
}

function updateShopItem(request) {
  const id = requiredString(request.params.id, "shop item id", 120);
  const body = request.body || {};
  let previousPreview = "";
  let nextPreview = "";
  inImmediateTransaction(() => {
    const current = requireShopItemRow(id);
    requireExpectedRevision(body.expectedRevision, current.revision);
    if (current.status === "archived") throw conflict("shop_item_archived");
    const payload = shopItemPayload(body, current);
    if (payload.previewUrl !== current.preview_url && payload.previewUrl) {
      payload.previewUrl = requireOwnedShopPreview(
        payload.previewUrl,
        request.user.id,
      );
    }
    const changedFields = shopChangedFields(current, payload);
    if (!changedFields.length) return;
    const note = requiredString(body.changeNote, "changeNote", 300);
    const identityChanged = changedFields.some((field) =>
      ["itemType", "assetValue"].includes(field),
    );
    if (identityChanged) {
      const impact = shopItemImpact(id);
      if (
        current.status !== "inactive" ||
        impact.holderCount > 0 ||
        impact.equipmentCount > 0
      ) {
        throw conflict("shop_item_identity_locked");
      }
    }
    if (current.status === "active") validateShopActivation(payload);
    validateShopUniqueness(payload, id);
    const before = shopItemSnapshot(current);
    const result = run(
      `UPDATE shop_items
       SET name = ?, description = ?, price_coins = ?, item_type = ?,
           min_level = ?, asset_value = ?, preview_url = ?, sort_order = ?,
           revision = revision + 1, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [
        payload.name,
        payload.description,
        payload.priceCoins,
        payload.itemType,
        payload.minLevel,
        payload.assetValue,
        payload.previewUrl,
        payload.sortOrder,
        id,
        Number(current.revision || 1),
      ],
    );
    if (!result.changes) throw conflict("shop_item_revision_conflict");
    const updated = requireShopItemRow(id);
    recordShopItemEvent({
      itemId: id,
      action: "update",
      before,
      after: shopItemSnapshot(updated),
      note,
      adminUserId: request.user.id,
    });
    previousPreview = current.preview_url || "";
    nextPreview = updated.preview_url || "";
  });
  if (previousPreview && previousPreview !== nextPreview) {
    cleanupReplacedShopPreview(request, previousPreview);
  }
  return { item: requireAdminShopItem(id) };
}

function changeShopItemStatus(request) {
  const id = requiredString(request.params.id, "shop item id", 120);
  const body = request.body || {};
  const targetStatus = requiredString(body.status, "status", 20);
  const note = requiredString(body.note, "note", 300);
  if (!shopStatuses.has(targetStatus)) throw badRequest("shop_status_invalid");

  inImmediateTransaction(() => {
    const current = requireShopItemRow(id);
    requireExpectedRevision(body.expectedRevision, current.revision);
    if (current.status === targetStatus) throw badRequest("shop_status_unchanged");
    const allowed = {
      inactive: new Set(["active", "archived"]),
      active: new Set(["inactive"]),
      archived: new Set(["inactive"]),
    }[current.status];
    if (!allowed?.has(targetStatus)) {
      throw badRequest("shop_status_transition_invalid");
    }
    if (targetStatus === "active") validateShopActivation(shopItemPayload({}, current));
    if (current.status === "archived" && targetStatus === "inactive") {
      validateShopUniqueness(shopItemPayload({}, current), id);
    }
    const before = shopItemSnapshot(current);
    const result = run(
      `UPDATE shop_items
       SET status = ?, revision = revision + 1, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [targetStatus, id, Number(current.revision || 1)],
    );
    if (!result.changes) throw conflict("shop_item_revision_conflict");
    recordShopItemEvent({
      itemId: id,
      action: shopStatusAction(current.status, targetStatus),
      before,
      after: shopItemSnapshot(requireShopItemRow(id)),
      note,
      adminUserId: request.user.id,
    });
  });
  return { item: requireAdminShopItem(id) };
}

async function uploadShopPreview(request) {
  let upload;
  try {
    upload = await request.file();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("shop_preview_file_too_large");
    }
    throw error;
  }
  if (!upload) throw badRequest("shop_preview_file_required");
  const mimeType = String(upload.mimetype || "").trim().toLowerCase();
  const extension = previewExtensions.get(mimeType);
  if (!extension) throw badRequest("shop_preview_type_invalid");

  let bytes;
  try {
    bytes = await upload.toBuffer();
  } catch (error) {
    if (error?.code === "FST_REQ_FILE_TOO_LARGE") {
      throw payloadTooLarge("shop_preview_file_too_large");
    }
    throw error;
  }
  if (!bytes.length) throw badRequest("shop_preview_file_required");
  if (bytes.length > maxPreviewBytes || upload.file?.truncated) {
    throw payloadTooLarge("shop_preview_file_too_large");
  }
  if (!validateUploadBytes(mimeType, bytes)) {
    throw badRequest("shop_preview_content_invalid");
  }

  const fileName = await withUploadLock(request.user.id, async () => {
    try {
      await pruneOrphanedUserUploads({
        rootDir: config.rootDir,
        apiPrefix: config.apiPrefix,
        folders: shopPreviewFolders,
        userId: request.user.id,
        referencedUrls: referencedUploadUrls(),
        retireManagedFile: ({ key }) => retireManagedUploadKey({ key }),
        graceMs: config.uploadOrphanGraceMs,
      });
    } catch (error) {
      warnShopUploadFailure(request, "stale_orphan_prune", error);
    }
    const usage = await inspectUserUploadUsage({
      rootDir: config.rootDir,
      folders: shopPreviewFolders,
      userId: request.user.id,
    });
    const maxFiles = Math.max(1, config.uploadMaxFilesPerUser);
    const maxBytes = Math.max(maxPreviewBytes, config.uploadMaxBytesPerUser);
    if (usage.files >= maxFiles) throw badRequest("upload_file_quota_exceeded");
    if (usage.bytes + bytes.length > maxBytes) {
      throw badRequest("upload_storage_quota_exceeded");
    }
    const generated = `${request.user.id}-${Date.now()}-${randomUUID()}.${extension}`;
    await writeUploadAtomically({
      directory: path.join(config.rootDir, "data", "uploads", shopPreviewFolder),
      fileName: generated,
      bytes,
    });
    return generated;
  });

  return {
    url: `${config.apiPrefix}/uploads/content/${shopPreviewFolder}/${fileName}`,
    mimeType,
    size: bytes.length,
  };
}

async function serveShopPreview(rawFile, reply) {
  const file = String(rawFile || "");
  if (!/^[a-z0-9-]+\.(?:jpe?g|png|webp)$/i.test(file)) {
    throw badRequest("file is invalid");
  }
  if (isManagedUploadRetired(shopPreviewFolder, file)) {
    throw notFound("file_not_found");
  }
  const filePath = path.join(
    config.rootDir,
    "data",
    "uploads",
    shopPreviewFolder,
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
    .type(shopPreviewContentType(file))
    .send(createReadStream(filePath));
}

function shopItemPayload(body, current = null) {
  const from = (key, column) =>
    Object.hasOwn(body, key) ? body[key] : current?.[column];
  const itemType = requiredString(from("itemType", "item_type"), "itemType", 40);
  const catalogItem = shopCatalogByType.get(itemType);
  if (!catalogItem) throw badRequest("shop_item_type_invalid");
  const assetValue = requiredString(
    from("assetValue", "asset_value"),
    "assetValue",
    80,
  );
  if (!catalogItem.presets.some((preset) => preset.value === assetValue)) {
    throw badRequest("shop_asset_preset_invalid");
  }
  return {
    name: requiredString(from("name", "name"), "name", 80),
    description: optionalString(from("description", "description"), 500),
    priceCoins: boundedInteger(
      from("priceCoins", "price_coins"),
      "priceCoins",
      0,
      1_000_000,
    ),
    itemType,
    minLevel: boundedInteger(
      from("minLevel", "min_level"),
      "minLevel",
      1,
      7,
    ),
    assetValue,
    previewUrl: optionalString(from("previewUrl", "preview_url"), 1000),
    sortOrder: boundedInteger(
      from("sortOrder", "sort_order") ?? 0,
      "sortOrder",
      0,
      100_000,
    ),
    changeNote: optionalString(body.changeNote, 300),
  };
}

function validateShopActivation(payload) {
  if (!payload.previewUrl) throw badRequest("shop_preview_required_for_activation");
  requireExistingShopPreview(payload.previewUrl);
}

function validateShopUniqueness(payload, excludeId = "") {
  const nameConflict = one(
    `SELECT id FROM shop_items
     WHERE status <> 'archived' AND lower(name) = lower(?) AND id <> ?
     LIMIT 1`,
    [payload.name, excludeId],
  );
  if (nameConflict) throw conflict("shop_item_name_conflict");
  const presetConflict = one(
    `SELECT id FROM shop_items
     WHERE status <> 'archived' AND item_type = ? AND asset_value = ? AND id <> ?
     LIMIT 1`,
    [payload.itemType, payload.assetValue, excludeId],
  );
  if (presetConflict) throw conflict("shop_item_preset_conflict");
}

function requireOwnedShopPreview(url, userId) {
  const key = managedUploadKeyFromUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: shopPreviewFolders,
    userId,
  });
  if (!key) throw badRequest("shop_preview_upload_required");
  requireExistingShopPreview(`${config.apiPrefix}/uploads/content/${key}`);
  return `${config.apiPrefix}/uploads/content/${key}`;
}

function requireExistingShopPreview(url) {
  const key = managedUploadKeyFromAnyUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: shopPreviewFolders,
  });
  if (!key) throw badRequest("shop_preview_upload_required");
  const [folder, file] = key.split("/");
  const filePath = path.join(config.rootDir, "data", "uploads", folder, file);
  if (isManagedUploadRetired(folder, file) || !existsSync(filePath)) {
    throw badRequest("shop_preview_not_found");
  }
  return key;
}

function cleanupReplacedShopPreview(request, url) {
  const key = managedUploadKeyFromAnyUrl({
    url,
    apiPrefix: config.apiPrefix,
    folders: shopPreviewFolders,
  });
  if (!key) return;
  try {
    const result = retireManagedUploadKey({ key });
    if (result.failedCount > 0) scheduleRetiredUploadDeleteRetry(request.log);
  } catch (error) {
    warnShopUploadFailure(request, "replaced_preview_retirement", error);
    const ownerUserId = Number(/^(\d+)-/.exec(key.split("/")[1] || "")?.[1]);
    if (Number.isSafeInteger(ownerUserId) && ownerUserId > 0) {
      scheduleManagedUploadRetirement({
        userId: ownerUserId,
        urls: [url],
        logger: request.log,
      });
    }
  }
}

function adminShopItemSelect() {
  return `SELECT s.*,
            (SELECT COUNT(*) FROM user_inventory i WHERE i.item_id = s.id)
              AS holder_count,
            (SELECT COUNT(*) FROM user_equipment e WHERE e.item_id = s.id)
              AS equipment_count,
            (SELECT COUNT(*)
             FROM user_reward_events r
             WHERE r.action = 'shop_redeem'
               AND r.related_type = 'shop_item'
               AND r.related_id = s.id) AS redemption_count,
            (SELECT COALESCE(SUM(CASE WHEN r.coins_delta < 0 THEN -r.coins_delta ELSE 0 END), 0)
             FROM user_reward_events r
             WHERE r.action = 'shop_redeem'
               AND r.related_type = 'shop_item'
               AND r.related_id = s.id) AS recorded_revenue,
            (SELECT COUNT(*)
             FROM user_inventory i
             WHERE i.item_id = s.id
               AND NOT EXISTS (
                 SELECT 1 FROM user_reward_events r
                 WHERE r.user_id = i.user_id
                   AND r.action = 'shop_redeem'
                   AND r.related_type = 'shop_item'
                   AND r.related_id = i.item_id
               )) AS untracked_holder_count
          FROM shop_items s`;
}

function requireAdminShopItem(id) {
  const row = one(`${adminShopItemSelect()} WHERE s.id = ?`, [id]);
  if (!row) throw notFound("shop_item_not_found");
  return adminShopItemJson(row);
}

function requireShopItemRow(id) {
  const row = one("SELECT * FROM shop_items WHERE id = ?", [id]);
  if (!row) throw notFound("shop_item_not_found");
  return row;
}

function adminShopItemJson(row) {
  return {
    ...shopItemSnapshot(row),
    holderCount: Number(row.holder_count || 0),
    equipmentCount: Number(row.equipment_count || 0),
    redemptionCount: Number(row.redemption_count || 0),
    recordedRevenue: Number(row.recorded_revenue || 0),
    untrackedHolderCount: Number(row.untracked_holder_count || 0),
  };
}

function shopItemSnapshot(row) {
  return {
    id: row.id,
    name: row.name,
    description: row.description || "",
    priceCoins: Number(row.price_coins || 0),
    itemType: row.item_type || "",
    minLevel: Number(row.min_level || 1),
    assetValue: row.asset_value || "",
    previewUrl: row.preview_url || "",
    sortOrder: Number(row.sort_order || 0),
    status: row.status || "inactive",
    revision: Number(row.revision || 1),
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || row.created_at || "",
  };
}

function shopChangedFields(current, payload) {
  const fields = [
    ["name", current.name, payload.name],
    ["description", current.description || "", payload.description],
    ["priceCoins", Number(current.price_coins || 0), payload.priceCoins],
    ["itemType", current.item_type, payload.itemType],
    ["minLevel", Number(current.min_level || 0), payload.minLevel],
    ["assetValue", current.asset_value || "", payload.assetValue],
    ["previewUrl", current.preview_url || "", payload.previewUrl],
    ["sortOrder", Number(current.sort_order || 0), payload.sortOrder],
  ];
  return fields.filter(([, before, after]) => before !== after).map(([name]) => name);
}

function shopItemImpact(id) {
  const row = one(
    `SELECT (SELECT COUNT(*) FROM user_inventory WHERE item_id = ?) AS holder_count,
            (SELECT COUNT(*) FROM user_equipment WHERE item_id = ?) AS equipment_count`,
    [id, id],
  );
  return {
    holderCount: Number(row?.holder_count || 0),
    equipmentCount: Number(row?.equipment_count || 0),
  };
}

function shopIntegrity() {
  const untrackedHoldings = Number(
    one(
      `SELECT COUNT(*) AS count
       FROM user_inventory i
       WHERE NOT EXISTS (
         SELECT 1 FROM user_reward_events r
         WHERE r.user_id = i.user_id
           AND r.action = 'shop_redeem'
           AND r.related_type = 'shop_item'
           AND r.related_id = i.item_id
       )`,
    )?.count || 0,
  );
  const debitsWithoutInventory = Number(
    one(
      `SELECT COUNT(*) AS count
       FROM user_reward_events r
       WHERE r.action = 'shop_redeem'
         AND r.related_type = 'shop_item'
         AND NOT EXISTS (
           SELECT 1 FROM user_inventory i
           WHERE i.user_id = r.user_id AND i.item_id = r.related_id
         )`,
    )?.count || 0,
  );
  return {
    healthy: untrackedHoldings === 0 && debitsWithoutInventory === 0,
    untrackedHoldings,
    debitsWithoutInventory,
  };
}

function shopStatusCounts() {
  const counts = Object.fromEntries([...shopStatuses].map((status) => [status, 0]));
  for (const row of all("SELECT status, COUNT(*) AS count FROM shop_items GROUP BY status")) {
    counts[row.status] = Number(row.count || 0);
  }
  return counts;
}

function shopTypeCounts() {
  const counts = new Map(
    all(
      `SELECT item_type, COUNT(*) AS count
       FROM shop_items
       GROUP BY item_type`,
    ).map((row) => [row.item_type, Number(row.count || 0)]),
  );
  return shopCatalog.map((item) => ({
    itemType: item.type,
    label: item.label,
    count: counts.get(item.type) || 0,
  }));
}

function recentShopRedemptions() {
  return all(
    `SELECT r.id, r.user_id, r.related_id AS item_id, r.coins_delta,
            r.created_at, u.nickname, u.email, s.name AS item_name
     FROM user_reward_events r
     JOIN users u ON u.id = r.user_id
     LEFT JOIN shop_items s ON s.id = r.related_id
     WHERE r.action = 'shop_redeem' AND r.related_type = 'shop_item'
     ORDER BY r.created_at DESC, r.id DESC
     LIMIT 8`,
  ).map((row) => ({
    id: Number(row.id),
    userId: Number(row.user_id),
    nickname: row.nickname || "",
    email: row.email || "",
    itemId: row.item_id || "",
    itemName: row.item_name || "",
    coins: Math.max(0, -Number(row.coins_delta || 0)),
    createdAt: row.created_at || "",
  }));
}

function recordShopItemEvent({
  itemId,
  action,
  before,
  after,
  note,
  adminUserId,
}) {
  run(
    `INSERT INTO shop_item_events
       (item_id, action, before_json, after_json, note, admin_user_id)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      itemId,
      action,
      JSON.stringify(before || {}),
      JSON.stringify(after || {}),
      note || "",
      adminUserId,
    ],
  );
}

function shopItemEventJson(row) {
  return {
    id: Number(row.id),
    itemId: row.item_id,
    action: row.action,
    before: parseJsonObject(row.before_json),
    after: parseJsonObject(row.after_json),
    note: row.note || "",
    admin: {
      id: Number(row.admin_user_id),
      nickname: row.admin_nickname || "",
      email: row.admin_email || "",
    },
    createdAt: row.created_at || "",
  };
}

function shopStatusAction(from, to) {
  if (from === "inactive" && to === "active") return "activate";
  if (from === "active" && to === "inactive") return "deactivate";
  if (from === "inactive" && to === "archived") return "archive";
  return "restore";
}

function requireExpectedRevision(value, currentRevision) {
  const revision = boundedInteger(value, "expectedRevision", 1, 1_000_000_000);
  if (revision !== Number(currentRevision || 1)) {
    const error = conflict("shop_item_revision_conflict");
    error.details = {
      expectedRevision: revision,
      currentRevision: Number(currentRevision || 1),
    };
    throw error;
  }
}

function boundedInteger(value, name, minimum, maximum) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw badRequest(`${name}_invalid`);
  }
  return number;
}

function inImmediateTransaction(task) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const result = task();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original transaction error.
    }
    throw error;
  }
}

function parseJsonObject(value) {
  try {
    const parsed = JSON.parse(String(value || "{}"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function shopPreviewContentType(file) {
  const extension = path.extname(file).toLowerCase();
  if (extension === ".png") return "image/png";
  if (extension === ".webp") return "image/webp";
  return "image/jpeg";
}

function warnShopUploadFailure(request, phase, error) {
  request.log?.warn?.(
    {
      uploadLifecycle: {
        phase,
        errorCode: error?.code || "shop_preview_cleanup_failed",
      },
    },
    "shop preview lifecycle cleanup failed",
  );
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}

function conflict(message) {
  const error = new Error(message);
  error.statusCode = 409;
  return error;
}

function payloadTooLarge(message) {
  const error = new Error(message);
  error.statusCode = 413;
  return error;
}
