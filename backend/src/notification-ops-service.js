import { randomUUID } from "node:crypto";

import { all, db, one, run } from "./db.js";
import {
  badRequest,
  optionalInt,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

const notificationStatuses = new Set(["draft", "sent", "canceled", "failed"]);
const notificationCategories = new Set([
  "system",
  "update",
  "operation",
  "security",
  "growth",
  "race",
  "ai_novel",
]);
const audienceScopes = new Set(["all_active", "recent_active"]);
const recentDayOptions = new Set([1, 7, 30]);
const knownPlatforms = new Set(["android", "ios", "windows", "macos", "linux", "web", "unknown"]);
const maxRecipients = 50000;
const activeRecipientPredicate = `
  u.status = 'active'
  AND lower(u.email) NOT IN ('chatbot@system.local', 'chat-bot@system.local')`;

export function notificationOperationsWorkbench(query = {}) {
  const { page, pageSize, offset } = pageParams(query);
  const keyword = optionalString(query.q, 100);
  const status = normalizeStatus(query.status, true);
  const category = normalizeCategory(query.category, true);
  const filters = notificationListFilters({ keyword, status, category });
  const total = Number(one(
    `SELECT COUNT(*) AS total
     FROM admin_broadcasts b
     LEFT JOIN users u ON u.id = b.admin_user_id
     ${filters.clause}`,
    filters.params,
  )?.total || 0);
  const items = all(
    `SELECT b.*, u.email, u.nickname,
            (SELECT COUNT(*) FROM system_notifications n
             WHERE n.broadcast_id = b.id AND n.read_at = '') AS unread_count
     FROM admin_broadcasts b
     LEFT JOIN users u ON u.id = b.admin_user_id
     ${filters.clause}
     ORDER BY b.id DESC
     LIMIT ? OFFSET ?`,
    [...filters.params, pageSize, offset],
  ).map(notificationAdminJson);
  return {
    generatedAt: new Date().toISOString(),
    page,
    pageSize,
    total,
    items,
    stats: notificationStats(),
    options: notificationOptions(),
  };
}

export function notificationDetail(idValue) {
  const id = positiveId(idValue, "notificationId");
  const row = requireNotification(id);
  const audience = parseJsonObject(row.audience_json, defaultAudience());
  const isLegacy = audience.legacy === true;
  const preview = isLegacy
    ? {
        live: false,
        eligibleCount: Number(row.recipient_count || 0),
        sample: [],
        capturedAt: row.created_at || "",
      }
    : row.status === "draft"
      ? audiencePreview(audience)
      : {
          live: false,
          eligibleCount: Number(row.preview_count || row.recipient_count || 0),
          sample: [],
          capturedAt: row.sent_at || row.created_at || "",
        };
  return {
    generatedAt: new Date().toISOString(),
    item: notificationAdminJson(row),
    preview: { ...preview, audience },
    delivery: deliverySummary(id, row),
    events: notificationEvents(id),
    options: notificationOptions(),
  };
}

export function previewNotification(body = {}) {
  const values = normalizedNotificationValues(body);
  const preview = audiencePreview(values.audience);
  return {
    generatedAt: new Date().toISOString(),
    title: values.title,
    content: values.content,
    category: values.category,
    audience: values.audience,
    ...preview,
    maxRecipients,
  };
}

export function createNotificationDraft(adminUserId, body = {}) {
  const values = normalizedNotificationValues(body);
  const note = requiredChangeNote(body.changeNote ?? body.note);
  const id = inImmediateTransaction(() => {
    const result = run(
      `INSERT INTO admin_broadcasts
       (admin_user_id, title, content, category, status, audience_json,
        recipient_count, delivered_count, failed_count, preview_count,
        revision, updated_at)
       VALUES (?, ?, ?, ?, 'draft', ?, 0, 0, 0, 0, 1, datetime('now'))`,
      [
        adminUserId,
        values.title,
        values.content,
        values.category,
        JSON.stringify(values.audience),
      ],
    );
    const broadcastId = Number(result.lastInsertRowid || 0);
    recordNotificationEvent({
      broadcastId,
      adminUserId,
      action: "created",
      before: {},
      after: notificationSnapshot(requireNotification(broadcastId)),
      note,
    });
    return broadcastId;
  });
  return notificationDetail(id);
}

export function updateNotificationDraft(adminUserId, idValue, body = {}) {
  const id = positiveId(idValue, "notificationId");
  const current = requireNotification(id);
  if (!mutableStatus(current.status)) throw badRequest("notification_edit_locked");
  const values = normalizedNotificationValues(body, current);
  const note = requiredChangeNote(body.changeNote ?? body.note);
  const expectedRevision = expectedRevisionValue(body.expectedRevision);
  inImmediateTransaction(() => {
    const latest = requireNotification(id);
    requireRevision(expectedRevision, latest.revision);
    if (!mutableStatus(latest.status)) throw badRequest("notification_edit_locked");
    const before = notificationSnapshot(latest);
    const result = run(
      `UPDATE admin_broadcasts
       SET title = ?, content = ?, category = ?, audience_json = ?,
           status = 'draft', failure_reason = '', revision = revision + 1,
           updated_at = datetime('now')
       WHERE id = ? AND revision = ? AND status IN ('draft', 'failed')`,
      [
        values.title,
        values.content,
        values.category,
        JSON.stringify(values.audience),
        id,
        expectedRevision,
      ],
    );
    if (!result.changes) throw conflict("notification_revision_conflict", {
      expectedRevision,
      currentRevision: Number(requireNotification(id).revision || 0),
    });
    const after = requireNotification(id);
    recordNotificationEvent({
      broadcastId: id,
      adminUserId,
      action: "updated",
      before,
      after: notificationSnapshot(after),
      note,
    });
  });
  return notificationDetail(id);
}

export function sendNotification(adminUserId, idValue, body = {}) {
  const id = positiveId(idValue, "notificationId");
  const idempotencyKey = requiredString(body.idempotencyKey, "idempotencyKey", 120);
  const note = requiredChangeNote(body.changeNote ?? body.note);
  const current = requireNotification(id);
  if (current.idempotency_key === idempotencyKey && current.status === "sent") {
    return {
      ok: true,
      idempotent: true,
      item: notificationDetail(id).item,
      delivery: deliverySummary(id, current),
    };
  }
  if (current.status === "sent") throw badRequest("notification_already_sent");
  if (current.status === "canceled") throw badRequest("notification_send_locked");
  if (!mutableStatus(current.status)) throw badRequest("notification_send_locked");
  const expectedRevision = expectedRevisionValue(body.expectedRevision);
  const result = inImmediateTransaction(() => {
    const latest = requireNotification(id);
    const reused = one(
      "SELECT id, status FROM admin_broadcasts WHERE idempotency_key = ?",
      [idempotencyKey],
    );
    if (reused && Number(reused.id) !== id) {
      throw conflict("notification_idempotency_conflict");
    }
    if (latest.idempotency_key === idempotencyKey && latest.status === "sent") {
      return { idempotent: true, deliveredCount: Number(latest.delivered_count || latest.recipient_count || 0) };
    }
    requireRevision(expectedRevision, latest.revision);
    if (!mutableStatus(latest.status)) throw badRequest("notification_send_locked");
    const audience = parseJsonObject(latest.audience_json, defaultAudience());
    const normalizedAudience = normalizeAudience(audience);
    const eligibleCount = audienceCount(normalizedAudience);
    if (eligibleCount <= 0) throw badRequest("notification_audience_empty");
    if (eligibleCount > maxRecipients) throw badRequest("notification_recipient_limit_exceeded");
    const before = notificationSnapshot(latest);
    const recipientQuery = audienceQuery(normalizedAudience);
    run(
      `INSERT OR IGNORE INTO system_notifications
       (broadcast_id, user_id, title, content, category)
       ${recipientQuery.cte}
       SELECT ?, u.id, ?, ?, ?
       FROM users u
       LEFT JOIN latest_app
         ON latest_app.user_id = u.id AND latest_app.row_number = 1
       ${recipientQuery.where}`,
      [id, latest.title, latest.content, latest.category, ...recipientQuery.params],
    );
    const deliveredCount = Number(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE broadcast_id = ?",
      [id],
    )?.total || 0);
    if (deliveredCount <= 0) throw badRequest("notification_delivery_empty");
    run(
      `UPDATE admin_broadcasts
       SET status = 'sent', audience_json = ?, recipient_count = ?,
           delivered_count = ?, failed_count = 0, preview_count = ?,
           idempotency_key = ?, failure_reason = '', sent_at = datetime('now'),
           revision = revision + 1, updated_at = datetime('now')
       WHERE id = ? AND revision = ?`,
      [
        JSON.stringify(normalizedAudience),
        deliveredCount,
        deliveredCount,
        eligibleCount,
        idempotencyKey,
        id,
        expectedRevision,
      ],
    );
    const after = requireNotification(id);
    recordNotificationEvent({
      broadcastId: id,
      adminUserId,
      action: "sent",
      before,
      after: notificationSnapshot(after),
      note,
    });
    return { idempotent: false, deliveredCount };
  });
  const detail = notificationDetail(id);
  return {
    ok: true,
    idempotent: Boolean(result.idempotent),
    item: detail.item,
    delivery: detail.delivery,
  };
}

export function cancelNotification(adminUserId, idValue, body = {}) {
  const id = positiveId(idValue, "notificationId");
  const note = requiredChangeNote(body.changeNote ?? body.note);
  const expectedRevision = expectedRevisionValue(body.expectedRevision);
  inImmediateTransaction(() => {
    const current = requireNotification(id);
    requireRevision(expectedRevision, current.revision);
    if (current.status !== "draft" && current.status !== "failed") {
      throw badRequest("notification_cancel_locked");
    }
    const before = notificationSnapshot(current);
    const result = run(
      `UPDATE admin_broadcasts
       SET status = 'canceled', revision = revision + 1,
           updated_at = datetime('now')
       WHERE id = ? AND revision = ? AND status IN ('draft', 'failed')`,
      [id, expectedRevision],
    );
    if (!result.changes) throw conflict("notification_revision_conflict");
    const after = requireNotification(id);
    recordNotificationEvent({
      broadcastId: id,
      adminUserId,
      action: "canceled",
      before,
      after: notificationSnapshot(after),
      note,
    });
  });
  return notificationDetail(id);
}

export function legacyCreateBroadcast(adminUserId, body = {}) {
  const draft = createNotificationDraft(adminUserId, {
    title: body.title,
    content: body.content,
    category: body.category,
    audience: defaultAudience(),
    changeNote: "兼容旧版后台发布站内通知",
  });
  const sent = sendNotification(adminUserId, draft.item.id, {
    expectedRevision: draft.item.revision,
    idempotencyKey: `legacy-${randomUUID()}`,
    changeNote: "兼容旧版后台立即发送",
  });
  return {
    ok: true,
    item: sent.item,
    recipientCount: Number(sent.delivery.deliveredCount || 0),
    idempotent: Boolean(sent.idempotent),
  };
}

function notificationStats() {
  const counts = Object.fromEntries(
    all("SELECT status, COUNT(*) AS total FROM admin_broadcasts GROUP BY status")
      .map((row) => [String(row.status || "unknown"), Number(row.total || 0)]),
  );
  const delivery = one(
    `SELECT COUNT(*) AS messages,
            COALESCE(SUM(delivered_count), 0) AS delivered
     FROM admin_broadcasts WHERE status = 'sent'`,
  ) || {};
  return {
    total: Object.values(counts).reduce((sum, value) => sum + Number(value || 0), 0),
    drafts: Number(counts.draft || 0),
    sent: Number(counts.sent || 0),
    canceled: Number(counts.canceled || 0),
    failed: Number(counts.failed || 0),
    sent24h: Number(one(
      "SELECT COUNT(*) AS total FROM admin_broadcasts WHERE status = 'sent' AND sent_at >= datetime('now', '-24 hours')",
    )?.total || 0),
    delivered: Number(delivery.delivered || 0),
    unread: Number(one(
      "SELECT COUNT(*) AS total FROM system_notifications WHERE read_at = ''",
    )?.total || 0),
    sentRecords: Number(delivery.messages || 0),
  };
}

function notificationOptions() {
  const dbPlatforms = all(
    `SELECT DISTINCT lower(trim(platform)) AS platform
     FROM user_app_installs WHERE trim(platform) <> '' ORDER BY platform LIMIT 50`,
  ).map((row) => String(row.platform || "").toLowerCase()).filter(Boolean);
  return {
    statuses: [...notificationStatuses],
    categories: [...notificationCategories],
    scopes: [...audienceScopes],
    recentDays: [...recentDayOptions],
    platforms: [...new Set([...knownPlatforms, ...dbPlatforms])].sort(),
    maxRecipients,
  };
}

function notificationListFilters({ keyword, status, category }) {
  const where = [];
  const params = [];
  if (keyword) {
    where.push("(b.title LIKE ? OR b.content LIKE ? OR u.email LIKE ? OR u.nickname LIKE ?)");
    const like = `%${keyword}%`;
    params.push(like, like, like, like);
  }
  if (status) {
    where.push("b.status = ?");
    params.push(status);
  }
  if (category) {
    where.push("b.category = ?");
    params.push(category);
  }
  return { clause: where.length ? `WHERE ${where.join(" AND ")}` : "", params };
}

function notificationAdminJson(row) {
  const rawCategory = String(row.category || "system").toLowerCase();
  return {
    id: Number(row.id || 0),
    title: row.title || "",
    content: row.content || "",
    category: notificationCategories.has(rawCategory) ? rawCategory : "system",
    status: notificationStatuses.has(String(row.status || "")) ? row.status : "sent",
    audience: parseJsonObject(row.audience_json, defaultAudience()),
    recipientCount: Number(row.recipient_count || 0),
    deliveredCount: Number(row.delivered_count || row.recipient_count || 0),
    failedCount: Number(row.failed_count || 0),
    previewCount: Number(row.preview_count || 0),
    unreadCount: Number(row.unread_count || 0),
    revision: Number(row.revision || 1),
    failureReason: row.failure_reason || "",
    sentAt: row.sent_at || "",
    createdAt: row.created_at || "",
    updatedAt: row.updated_at || row.created_at || "",
    operator: row.admin_user_id
      ? {
          id: Number(row.admin_user_id),
          email: row.email || "",
          nickname: row.nickname || "",
        }
      : null,
    // Keep the legacy page readable until the V2 route fully replaces it.
    nickname: row.nickname || "",
    email: row.email || "",
    recipient_count: Number(row.recipient_count || 0),
    created_at: row.created_at || "",
  };
}

function deliverySummary(id, row = requireNotification(id)) {
  const counts = one(
    `SELECT COUNT(*) AS delivered,
            SUM(CASE WHEN read_at = '' THEN 1 ELSE 0 END) AS unread,
            MIN(created_at) AS first_created_at,
            MAX(created_at) AS last_created_at
     FROM system_notifications WHERE broadcast_id = ?`,
    [id],
  ) || {};
  return {
    attemptedCount: Number(row.recipient_count || 0),
    deliveredCount: Number(counts.delivered || row.delivered_count || 0),
    failedCount: Number(row.failed_count || 0),
    unreadCount: Number(counts.unread || 0),
    firstCreatedAt: counts.first_created_at || "",
    lastCreatedAt: counts.last_created_at || "",
    atomic: true,
  };
}

function notificationEvents(id) {
  return all(
    `SELECT e.*, u.nickname AS admin_nickname, u.email AS admin_email
     FROM admin_notification_events e
     LEFT JOIN users u ON u.id = e.admin_user_id
     WHERE e.broadcast_id = ?
     ORDER BY e.id DESC LIMIT 100`,
    [id],
  ).map((row) => ({
    id: Number(row.id || 0),
    action: row.action || "",
    before: parseJsonObject(row.before_json, {}),
    after: parseJsonObject(row.after_json, {}),
    note: row.note || "",
    createdAt: row.created_at || "",
    operator: row.admin_user_id
      ? {
          id: Number(row.admin_user_id),
          nickname: row.admin_nickname || "",
          email: row.admin_email || "",
        }
      : null,
  }));
}

function normalizedNotificationValues(body, fallback = null) {
  const source = body && typeof body === "object" ? body : {};
  const title = requiredString(
    Object.hasOwn(source, "title") ? source.title : fallback?.title,
    "title",
    80,
  );
  const content = requiredString(
    Object.hasOwn(source, "content") ? source.content : fallback?.content,
    "content",
    2000,
  );
  const category = normalizeCategory(
    Object.hasOwn(source, "category") ? source.category : (fallback?.category ?? "system"),
    false,
  );
  const audienceValue = Object.hasOwn(source, "audience")
    ? source.audience
    : fallback?.audience_json
      ? parseJsonObject(fallback.audience_json, defaultAudience())
      : fallback?.audience;
  return { title, content, category, audience: normalizeAudience(audienceValue) };
}

function normalizeAudience(value) {
  const source = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const scope = String(source.scope || "all_active").trim().toLowerCase();
  if (!audienceScopes.has(scope)) throw badRequest("notification_audience_invalid");
  const rawRecentDays = optionalInt(source.recentDays, scope === "recent_active" ? 7 : 0);
  const recentDays = scope === "recent_active" ? rawRecentDays : 0;
  if (scope === "recent_active" && !recentDayOptions.has(recentDays)) {
    throw badRequest("notification_recent_days_invalid");
  }
  const rawPlatforms = source.platforms === undefined ? [] : source.platforms;
  if (!Array.isArray(rawPlatforms) || rawPlatforms.length > 8) {
    throw badRequest("notification_platforms_invalid");
  }
  const platforms = [...new Set(rawPlatforms.map((item) => {
    const platform = requiredString(item, "platform", 32).toLowerCase();
    if (!/^[a-z0-9_-]+$/.test(platform)) throw badRequest("notification_platforms_invalid");
    return platform;
  }))];
  const minVersionCode = boundedInteger(source.minVersionCode ?? 0, "minVersionCode", 0, 1000000000);
  const maxVersionCode = boundedInteger(source.maxVersionCode ?? 0, "maxVersionCode", 0, 1000000000);
  if (maxVersionCode > 0 && minVersionCode > maxVersionCode) {
    throw badRequest("notification_version_range_invalid");
  }
  if (source.includeAdmins !== undefined && typeof source.includeAdmins !== "boolean") {
    throw badRequest("notification_include_admins_invalid");
  }
  return {
    scope,
    recentDays,
    platforms,
    minVersionCode,
    maxVersionCode,
    includeAdmins: source.includeAdmins === true,
  };
}

function defaultAudience() {
  return {
    scope: "all_active",
    recentDays: 0,
    platforms: [],
    minVersionCode: 0,
    maxVersionCode: 0,
    includeAdmins: false,
  };
}

function audiencePreview(audience) {
  const normalized = normalizeAudience(audience);
  const query = audienceQuery(normalized);
  const eligibleCount = audienceCount(normalized);
  const sample = all(
    `${query.cte}
     SELECT u.id, u.nickname, u.created_at, u.last_login_at,
            latest_app.version_code AS app_version_code,
            latest_app.platform AS app_platform,
            latest_app.last_seen_at AS app_last_seen_at,
            COALESCE(NULLIF(latest_app.last_seen_at, ''), NULLIF(u.last_login_at, ''), u.created_at)
              AS last_active_at
     FROM users u
     LEFT JOIN latest_app
       ON latest_app.user_id = u.id AND latest_app.row_number = 1
     ${query.where}
     ORDER BY datetime(last_active_at) DESC, u.id DESC
     LIMIT ?`,
    [...query.params, 8],
  ).map((row) => ({
    id: Number(row.id || 0),
    nickname: row.nickname || "",
    createdAt: row.created_at || "",
    lastActiveAt: row.last_active_at || "",
    platform: row.app_platform || "unknown",
    versionCode: Number(row.app_version_code || 0),
  }));
  return {
    live: true,
    eligibleCount,
    sample,
    truncated: eligibleCount > sample.length,
    maxRecipients,
  };
}

function audienceCount(audience) {
  const query = audienceQuery(audience);
  return Number(one(
    `${query.cte}
     SELECT COUNT(*) AS total
     FROM users u
     LEFT JOIN latest_app
       ON latest_app.user_id = u.id AND latest_app.row_number = 1
     ${query.where}`,
    query.params,
  )?.total || 0);
}

function audienceQuery(audience) {
  const normalized = normalizeAudience(audience);
  const where = [
    activeRecipientPredicate,
    normalized.includeAdmins ? "u.role IN ('user', 'admin')" : "u.role = 'user'",
  ];
  const params = [];
  if (normalized.scope === "recent_active") {
    where.push(
      `datetime(COALESCE(NULLIF(latest_app.last_seen_at, ''), NULLIF(u.last_login_at, ''), u.created_at))
       >= datetime('now', ?)`,
    );
    params.push(`-${normalized.recentDays} days`);
  }
  if (normalized.platforms.length) {
    where.push(
      `COALESCE(NULLIF(lower(latest_app.platform), ''), 'unknown') IN (${normalized.platforms.map(() => "?").join(", ")})`,
    );
    params.push(...normalized.platforms);
  }
  if (normalized.minVersionCode > 0) {
    where.push("latest_app.id IS NOT NULL AND latest_app.version_code >= ?");
    params.push(normalized.minVersionCode);
  }
  if (normalized.maxVersionCode > 0) {
    where.push("latest_app.id IS NOT NULL AND latest_app.version_code <= ?");
    params.push(normalized.maxVersionCode);
  }
  return {
    cte: `WITH latest_app AS (
      SELECT i.*,
             ROW_NUMBER() OVER (
               PARTITION BY i.user_id
               ORDER BY i.last_seen_at DESC, i.id DESC
             ) AS row_number
      FROM user_app_installs i
    )`,
    where: `WHERE ${where.join(" AND ")}`,
    params,
  };
}

function requireNotification(id) {
  const row = one(
    `SELECT b.*, u.email, u.nickname,
            (SELECT COUNT(*) FROM system_notifications n
             WHERE n.broadcast_id = b.id AND n.read_at = '') AS unread_count
     FROM admin_broadcasts b
     LEFT JOIN users u ON u.id = b.admin_user_id
     WHERE b.id = ?`,
    [id],
  );
  if (!row) throw notFound("notification_not_found");
  return row;
}

function notificationSnapshot(row) {
  const json = notificationAdminJson(row);
  return {
    id: json.id,
    title: json.title,
    content: json.content,
    category: json.category,
    status: json.status,
    audience: json.audience,
    recipientCount: json.recipientCount,
    deliveredCount: json.deliveredCount,
    failedCount: json.failedCount,
    previewCount: json.previewCount,
    revision: json.revision,
    sentAt: json.sentAt,
    updatedAt: json.updatedAt,
  };
}

function recordNotificationEvent({ broadcastId, adminUserId, action, before, after, note }) {
  run(
    `INSERT INTO admin_notification_events
       (broadcast_id, admin_user_id, action, before_json, after_json, note)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      broadcastId,
      adminUserId,
      action,
      JSON.stringify(before || {}),
      JSON.stringify(after || {}),
      note,
    ],
  );
}

function mutableStatus(status) {
  return status === "draft" || status === "failed";
}

function normalizeStatus(value, allowEmpty) {
  const status = optionalString(value, 30).toLowerCase();
  if (!status && allowEmpty) return "";
  if (!notificationStatuses.has(status)) throw badRequest("notification_status_invalid");
  return status;
}

function normalizeCategory(value, allowEmpty) {
  const category = optionalString(value, 40).toLowerCase();
  if (!category && allowEmpty) return "";
  if (!notificationCategories.has(category)) throw badRequest("notification_category_invalid");
  return category;
}

function requiredChangeNote(value) {
  const note = requiredString(value, "note", 500);
  if (note.length < 4) throw badRequest("notification_change_note_invalid");
  return note;
}

function expectedRevisionValue(value) {
  return boundedInteger(value, "expectedRevision", 0, 1000000000);
}

function requireRevision(expected, current) {
  if (Number(expected) === Number(current)) return;
  throw conflict("notification_revision_conflict", {
    expectedRevision: Number(expected),
    currentRevision: Number(current || 0),
  });
}

function boundedInteger(value, name, minimum, maximum) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw badRequest(`${name}_invalid`);
  }
  return number;
}

function positiveId(value, name) {
  return boundedInteger(value, name, 1, 1000000000);
}

function parseJsonObject(value, fallback = {}) {
  try {
    const parsed = typeof value === "string" ? JSON.parse(value || "{}") : value;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : fallback;
  } catch {
    return fallback;
  }
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

function conflict(message, details) {
  const error = new Error(message);
  error.statusCode = 409;
  if (details) error.details = details;
  return error;
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}
