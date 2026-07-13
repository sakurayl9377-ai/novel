import { all, one } from './db.js';
import { config } from './config.js';

export const VIDEO_POLICY_MODES = new Set(['always', 'hidden', 'scheduled']);

export function categoryPolicy(sourceKey, categoryId) {
  const row = one(
    `SELECT source_key, category_id, mode, daily_start, daily_end, timezone,
            age_restricted, updated_at
     FROM video_category_policies WHERE source_key = ? AND category_id = ?`,
    [String(sourceKey), Number(categoryId)],
  );
  return normalizePolicy(row || {
    source_key: sourceKey,
    category_id: categoryId,
    mode: 'always',
    daily_start: '00:00',
    daily_end: '23:59',
    timezone: config.videoPolicyTimezone,
    age_restricted: 0,
  });
}

export function listCategoryPolicies(sourceKey) {
  return all(
    `SELECT source_key, category_id, mode, daily_start, daily_end, timezone,
            age_restricted, updated_at
     FROM video_category_policies WHERE source_key = ? ORDER BY category_id`,
    [String(sourceKey)],
  ).map(normalizePolicy);
}

export function evaluateCategoryPolicy(policy, now = new Date()) {
  const normalized = normalizePolicy(policy);
  if (normalized.mode === 'hidden') return { available: false, reason: 'hidden', policy: normalized };
  if (normalized.mode === 'always') return { available: true, reason: 'always', policy: normalized };
  const minute = minuteInTimezone(now, normalized.timezone);
  const start = parseMinute(normalized.dailyStart);
  const end = parseMinute(normalized.dailyEnd);
  const available = start === end
    ? true
    : start < end
      ? minute >= start && minute < end
      : minute >= start || minute < end;
  return { available, reason: available ? 'scheduled_open' : 'scheduled_closed', policy: normalized };
}

export function categoryAvailability(sourceKey, categoryId, now = new Date()) {
  return evaluateCategoryPolicy(categoryPolicy(sourceKey, categoryId), now);
}

export function normalizePolicy(row) {
  return {
    sourceKey: String(row?.source_key ?? row?.sourceKey ?? 'dbzy'),
    categoryId: Number(row?.category_id ?? row?.categoryId),
    mode: VIDEO_POLICY_MODES.has(row?.mode) ? row.mode : 'always',
    dailyStart: validTime(row?.daily_start ?? row?.dailyStart, '00:00'),
    dailyEnd: validTime(row?.daily_end ?? row?.dailyEnd, '23:59'),
    timezone: validTimezone(row?.timezone) ? row.timezone : config.videoPolicyTimezone,
    ageRestricted: Boolean(row?.age_restricted ?? row?.ageRestricted),
    updatedAt: row?.updated_at ?? row?.updatedAt ?? null,
  };
}

function minuteInTimezone(date, timezone) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return Number(values.hour) * 60 + Number(values.minute);
}

function parseMinute(value) {
  const [hour, minute] = validTime(value, '00:00').split(':').map(Number);
  return hour * 60 + minute;
}

function validTime(value, fallback) {
  const text = String(value || '');
  return /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(text) ? text : fallback;
}

function validTimezone(value) {
  try {
    new Intl.DateTimeFormat('en', { timeZone: String(value || '') }).format();
    return Boolean(value);
  } catch {
    return false;
  }
}
