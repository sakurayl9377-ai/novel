import { randomUUID } from "node:crypto";

import { appAnnouncementSettings, publicAppAnnouncement } from "./app-announcement.js";
import { all, db, one, run } from "./db.js";
import {
  badRequest,
  optionalString,
  pageParams,
  requiredString,
} from "./validators.js";

export function appAnnouncementWorkbench(query = {}) {
  const { page, pageSize, offset } = pageParams(query);
  const settings = appAnnouncementSettings();
  const total = Number(
    one("SELECT COUNT(*) AS total FROM app_announcement_revisions")?.total || 0,
  );
  const items = all(
    `SELECT revision.*, user.nickname AS admin_nickname,
            user.email AS admin_email
     FROM app_announcement_revisions revision
     LEFT JOIN users user ON user.id = revision.admin_user_id
     ORDER BY revision.id DESC
     LIMIT ? OFFSET ?`,
    [pageSize, offset],
  ).map(announcementRevisionJson);
  const counts = one(
    `SELECT COUNT(*) AS total,
            SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS published,
            SUM(CASE WHEN enabled = 0 THEN 1 ELSE 0 END) AS disabled
     FROM app_announcement_revisions`,
  ) || {};
  const latestRevisionId = Number(
    one("SELECT id FROM app_announcement_revisions ORDER BY id DESC LIMIT 1")?.id || 0,
  );
  const activeRevisionId = settings.enabled
    ? Number(
        one(
          `SELECT id FROM app_announcement_revisions
           WHERE enabled = 1 AND version = ?
           ORDER BY id DESC LIMIT 1`,
          [settings.version],
        )?.id || 0,
      )
    : 0;
  return {
    generatedAt: new Date().toISOString(),
    page,
    pageSize,
    total,
    current: {
      ...publicAppAnnouncement(),
      version: settings.version || "",
      activeRevisionId,
      latestRevisionId,
    },
    items,
    stats: {
      total: Number(counts.total || 0),
      published: Number(counts.published || 0),
      disabled: Number(counts.disabled || 0),
    },
  };
}

export function publishAppAnnouncement(adminUserId, body = {}) {
  const current = appAnnouncementSettings();
  requireExpectedVersion(body.expectedVersion, current.version);
  return publishSnapshot(adminUserId, {
    title: requiredString(body.title, "title", 80),
    content: requiredString(body.content, "content", 4000),
    note: requiredChangeNote(body.changeNote ?? body.note),
    sourceRevisionId: optionalRevisionId(body.sourceRevisionId),
  });
}

export function disableAppAnnouncement(adminUserId, body = {}) {
  const current = appAnnouncementSettings();
  requireExpectedVersion(body.expectedVersion, current.version);
  const note = requiredChangeNote(body.changeNote ?? body.note);
  if (!current.enabled) {
    return { ok: true, changed: false, current: adminCurrentAnnouncement() };
  }
  const revision = inImmediateTransaction(() => {
    saveAnnouncementSettings({ ...current, enabled: false });
    return insertAnnouncementRevision({
      adminUserId,
      enabled: false,
      version: current.version || announcementVersion(),
      title: current.title,
      content: current.content,
      note,
    });
  });
  return { ok: true, changed: true, current: adminCurrentAnnouncement(), revision };
}

export function republishAppAnnouncement(adminUserId, revisionIdValue, body = {}) {
  const revisionId = positiveId(revisionIdValue, "revisionId");
  const source = one(
    "SELECT * FROM app_announcement_revisions WHERE id = ?",
    [revisionId],
  );
  if (!source) throw notFound("app_announcement_revision_not_found");
  const current = appAnnouncementSettings();
  requireExpectedVersion(body.expectedVersion, current.version);
  return publishSnapshot(adminUserId, {
    title: source.title,
    content: source.content,
    note: requiredChangeNote(body.changeNote ?? body.note),
    sourceRevisionId: revisionId,
  });
}

export function saveAppAnnouncementFromSettings(adminUserId, rawValues = {}) {
  const values = rawValues && typeof rawValues === "object" && !Array.isArray(rawValues)
    ? rawValues
    : {};
  const current = appAnnouncementSettings();
  const next = {
    enabled: Object.hasOwn(values, "enabled")
      ? values.enabled === true || values.enabled === "true"
      : current.enabled,
    title: Object.hasOwn(values, "title")
      ? optionalString(values.title, 80) || "公告"
      : current.title,
    content: Object.hasOwn(values, "content")
      ? optionalString(values.content, 4000)
      : current.content,
  };
  if (next.enabled && !next.content) {
    throw badRequest("app_announcement_content_required");
  }
  const changed = next.enabled !== current.enabled ||
    next.title !== current.title || next.content !== current.content;
  if (!changed) return adminCurrentAnnouncement();
  next.version = announcementVersion();
  inImmediateTransaction(() => {
    saveAnnouncementSettings(next);
    insertAnnouncementRevision({
      adminUserId,
      enabled: next.enabled,
      version: next.version,
      title: next.title,
      content: next.content,
      note: "从系统配置兼容入口更新启动公告",
    });
  });
  return adminCurrentAnnouncement();
}

function publishSnapshot(adminUserId, { title, content, note, sourceRevisionId = null }) {
  if (sourceRevisionId != null && !one(
    "SELECT 1 AS present FROM app_announcement_revisions WHERE id = ?",
    [sourceRevisionId],
  )) {
    throw notFound("app_announcement_revision_not_found");
  }
  const version = announcementVersion();
  const revision = inImmediateTransaction(() => {
    saveAnnouncementSettings({ enabled: true, title, content, version });
    return insertAnnouncementRevision({
      adminUserId,
      enabled: true,
      version,
      title,
      content,
      note,
      sourceRevisionId,
    });
  });
  return { ok: true, changed: true, current: adminCurrentAnnouncement(), revision };
}

function adminCurrentAnnouncement() {
  const settings = appAnnouncementSettings();
  const current = publicAppAnnouncement();
  return { ...current, version: settings.version || "" };
}

function saveAnnouncementSettings(values) {
  const statement = db.prepare(
    `INSERT INTO app_settings (key, value, is_secret, updated_at)
     VALUES (?, ?, 0, datetime('now'))
     ON CONFLICT(key) DO UPDATE SET
       value = excluded.value,
       is_secret = 0,
       updated_at = datetime('now')`,
  );
  for (const [key, value] of Object.entries({
    enabled: values.enabled ? "true" : "false",
    title: values.title || "公告",
    content: values.content || "",
    version: values.version || "",
  })) {
    statement.run(`app_announcement.${key}`, String(value));
  }
}

function insertAnnouncementRevision({
  adminUserId,
  enabled,
  version,
  title,
  content,
  note,
  sourceRevisionId = null,
}) {
  const result = run(
    `INSERT INTO app_announcement_revisions
       (version, title, content, enabled, source_revision_id,
        admin_user_id, note)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [
      version,
      title,
      content,
      enabled ? 1 : 0,
      sourceRevisionId,
      adminUserId || null,
      note,
    ],
  );
  return announcementRevisionJson(one(
    `SELECT revision.*, user.nickname AS admin_nickname,
            user.email AS admin_email
     FROM app_announcement_revisions revision
     LEFT JOIN users user ON user.id = revision.admin_user_id
     WHERE revision.id = ?`,
    [result.lastInsertRowid],
  ));
}

function announcementRevisionJson(row) {
  return {
    id: Number(row.id || 0),
    version: row.version || "",
    title: row.title || "公告",
    content: row.content || "",
    enabled: Number(row.enabled || 0) === 1,
    sourceRevisionId: row.source_revision_id == null
      ? null
      : Number(row.source_revision_id),
    note: row.note || "",
    createdAt: row.created_at || "",
    operator: row.admin_user_id
      ? {
          id: Number(row.admin_user_id),
          nickname: row.admin_nickname || "",
          email: row.admin_email || "",
        }
      : null,
  };
}

function requireExpectedVersion(value, currentVersion) {
  if (value === undefined || value === null) return;
  if (String(value) === String(currentVersion || "")) return;
  const error = conflict("app_announcement_revision_conflict");
  error.details = { expectedVersion: String(value), currentVersion: currentVersion || "" };
  throw error;
}

function requiredChangeNote(value) {
  const note = requiredString(value, "changeNote", 500);
  if (note.length < 4) throw badRequest("app_announcement_change_note_invalid");
  return note;
}

function optionalRevisionId(value) {
  if (value === undefined || value === null || value === "") return null;
  return positiveId(value, "sourceRevisionId");
}

function positiveId(value, name) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw badRequest(`${name}_invalid`);
  return id;
}

function announcementVersion() {
  return `${Date.now()}-${randomUUID().slice(0, 8)}`;
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

function conflict(message) {
  const error = new Error(message);
  error.statusCode = 409;
  return error;
}

function notFound(message) {
  const error = new Error(message);
  error.statusCode = 404;
  return error;
}
