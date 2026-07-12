import crypto from 'node:crypto';

import { db, run } from './db.js';
import { recordBehaviorFromTelemetry } from './growth-operations.js';
import { recordObservedTraffic } from './routes-admin-content.js';
import {
  badRequest,
  optionalInt,
  optionalString,
  requiredString,
} from './validators.js';

const ingestWindows = new Map();
const maxEventsPerBatch = 50;
const maxErrorsPerBatch = 20;

export async function telemetryRoutes(app) {
  app.post(
    '/app/telemetry/batch',
    { preHandler: app.authOptional },
    async (request) => ingestBatch(request),
  );
}

function ingestBatch(request) {
  const body = request.body || {};
  const installId = requiredString(body.installId, 'installId', 80);
  const sessionId = requiredString(body.sessionId, 'sessionId', 80);
  checkRateLimit(request.ip, installId);

  const runtime = {
    versionName: optionalString(body.versionName, 40),
    versionCode: clamp(optionalInt(body.versionCode, 0), 0, 100000000),
    platform: optionalString(body.platform, 30),
    osVersion: optionalString(body.osVersion, 200),
    deviceModel: optionalString(body.deviceModel, 120),
  };
  const events = Array.isArray(body.events) ? body.events : [];
  const errors = Array.isArray(body.errors) ? body.errors : [];
  if (events.length > maxEventsPerBatch) {
    throw badRequest(`events exceeds ${maxEventsPerBatch}`);
  }
  if (errors.length > maxErrorsPerBatch) {
    throw badRequest(`errors exceeds ${maxErrorsPerBatch}`);
  }

  const userId = request.user?.id || null;
  let acceptedEvents = 0;
  let acceptedErrors = 0;
  db.exec('BEGIN');
  try {
    for (const raw of events) {
      insertEvent({
        raw,
        userId,
        installId,
        sessionId,
        runtime,
      });
      acceptedEvents += 1;
    }
    for (const raw of errors) {
      insertError({
        raw,
        userId,
        installId,
        sessionId,
        runtime,
      });
      acceptedErrors += 1;
    }
    db.exec('COMMIT');
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }

  pruneExpiredRows();
  return {
    ok: true,
    acceptedEvents,
    acceptedErrors,
  };
}

function insertEvent({ raw, userId, installId, sessionId, runtime }) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw badRequest('event is invalid');
  }
  const eventName = requiredString(raw.name, 'event.name', 80).toLowerCase();
  if (!/^[a-z0-9][a-z0-9_.-]*$/.test(eventName)) {
    throw badRequest('event.name is invalid');
  }
  const success =
    raw.success === true ? 1 : raw.success === false ? 0 : null;
  const result = run(
    `INSERT INTO app_telemetry_events
     (user_id, install_id, session_id, event_name, screen, duration_ms,
      success, metadata, version_name, version_code, platform, os_version,
      device_model, occurred_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      userId,
      installId,
      sessionId,
      eventName,
      optionalString(raw.screen, 120),
      clamp(optionalInt(raw.durationMs, 0), 0, 3600000),
      success,
      safeMetadata(raw.metadata),
      runtime.versionName,
      runtime.versionCode,
      runtime.platform,
      runtime.osVersion,
      runtime.deviceModel,
      sqlDate(raw.occurredAt),
    ],
  );
  recordBehaviorFromTelemetry({
    telemetryId: Number(result.lastInsertRowid),
    userId,
    installId,
    sessionId,
    eventName,
    raw,
    versionCode: runtime.versionCode,
  });
  recordContentHealthFromTelemetry(eventName, raw);
}

function recordContentHealthFromTelemetry(eventName, raw) {
  if (raw.success !== true && raw.success !== false) return;
  const metadata = raw.metadata && typeof raw.metadata === 'object' && !Array.isArray(raw.metadata)
    ? raw.metadata
    : {};
  let contentType = '';
  let sourceKey = '';
  if (eventName === 'content_load' && metadata.contentType === 'novel' && metadata.local !== true) {
    contentType = 'novel';
    sourceKey = 'legacy';
  } else if (eventName === 'content_load' && metadata.contentType === 'manga') {
    contentType = 'manga';
    sourceKey = 'manga_baozi';
  } else if (eventName === 'video_start') {
    contentType = 'anime';
    sourceKey = 'anime_yinhua';
  }
  if (!contentType) return;
  recordObservedTraffic({
    contentType,
    sourceKey,
    success: raw.success,
    latencyMs: clamp(optionalInt(raw.durationMs, 0), 0, 600000),
    error: [metadata.reason, metadata.errorType, metadata.source]
      .filter(Boolean)
      .join(': '),
  });
}

function insertError({ raw, userId, installId, sessionId, runtime }) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw badRequest('error is invalid');
  }
  const errorType = optionalString(raw.type, 120);
  const message = optionalString(raw.message, 2000);
  const stack = optionalString(raw.stack, 12000);
  if (!errorType && !message) throw badRequest('error content is required');
  const fingerprint = crypto
    .createHash('sha256')
    .update(`${errorType}\n${normalizeErrorMessage(message)}\n${stack.split('\n')[0] || ''}`)
    .digest('hex');
  run(
    `INSERT INTO app_error_reports
     (user_id, install_id, session_id, fingerprint, error_type, message,
      stack, screen, fatal, metadata, version_name, version_code, platform,
      os_version, device_model, occurred_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      userId,
      installId,
      sessionId,
      fingerprint,
      errorType,
      message,
      stack,
      optionalString(raw.screen, 120),
      raw.fatal === true ? 1 : 0,
      safeMetadata(raw.metadata),
      runtime.versionName,
      runtime.versionCode,
      runtime.platform,
      runtime.osVersion,
      runtime.deviceModel,
      sqlDate(raw.occurredAt),
    ],
  );
}

function checkRateLimit(ip, installId) {
  const now = Date.now();
  const key = `${String(ip || '').slice(0, 80)}:${installId}`;
  const current = ingestWindows.get(key);
  if (!current || now - current.startedAt >= 60000) {
    ingestWindows.set(key, { startedAt: now, count: 1 });
  } else {
    current.count += 1;
    if (current.count > 20) {
      const error = new Error('telemetry_rate_limited');
      error.statusCode = 429;
      throw error;
    }
  }
  if (ingestWindows.size > 2000) {
    for (const [entryKey, value] of ingestWindows) {
      if (now - value.startedAt >= 60000) ingestWindows.delete(entryKey);
    }
  }
}

let lastPrunedAt = 0;
function pruneExpiredRows() {
  const now = Date.now();
  if (now - lastPrunedAt < 60 * 60 * 1000) return;
  lastPrunedAt = now;
  run("DELETE FROM app_telemetry_events WHERE created_at < datetime('now', '-90 days')");
  run("DELETE FROM app_error_reports WHERE created_at < datetime('now', '-180 days')");
}

function safeMetadata(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return '{}';
  try {
    const encoded = JSON.stringify(value);
    return encoded.length <= 4000
      ? encoded
      : JSON.stringify({ truncated: true, originalBytes: encoded.length });
  } catch {
    return '{}';
  }
}

function sqlDate(value) {
  const parsed = new Date(String(value || ''));
  const date = Number.isFinite(parsed.getTime()) ? parsed : new Date();
  return date.toISOString().slice(0, 19).replace('T', ' ');
}

function normalizeErrorMessage(value) {
  return String(value || '')
    .replace(/0x[0-9a-f]+/gi, '0x?')
    .replace(/\b\d{4,}\b/g, '#')
    .slice(0, 2000);
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}
