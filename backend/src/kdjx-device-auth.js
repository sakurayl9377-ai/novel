import { randomInt } from 'node:crypto';
import {
  kdjxConfig,
  kdjxDeviceAuthorizationUrlAllowed,
} from './kdjx-config.js';
import { db, one, run } from './db.js';
import { ensureKdjxGameSchema } from './kdjx-schema.js';
import { createKdjxSessionGrantInTransaction } from './kdjx-sso.js';
import { hashToken, randomToken } from './security.js';

const userCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const deviceCodeHash = (value) => hashToken(`kdjx-device:${value}`);
const userCodeHash = (value) => hashToken(`kdjx-user-code:${value}`);

export function kdjxDeviceAuthorizationAvailable() {
  if (!kdjxConfig.ssoSharedSecret.trim()) return false;
  return kdjxDeviceAuthorizationUrlAllowed();
}

export function createKdjxDeviceAuthorization(now = new Date()) {
  ensureKdjxGameSchema();
  const expiresAt = new Date(
    now.getTime() + kdjxConfig.deviceCodeTtlSeconds * 1000,
  ).toISOString();
  run(
    `DELETE FROM kdjx_device_authorizations
     WHERE datetime(expires_at) < datetime('now', '-1 day')`,
  );
  let deviceCode;
  let normalizedUserCode;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    deviceCode = `kdjx_device_${randomToken(32)}`;
    normalizedUserCode = generateUserCode();
    try {
      run(
        `INSERT INTO kdjx_device_authorizations
          (device_code_hash, user_code_hash, poll_interval_seconds, expires_at)
         VALUES (?, ?, ?, ?)`,
        [
          deviceCodeHash(deviceCode),
          userCodeHash(normalizedUserCode),
          kdjxConfig.devicePollIntervalSeconds,
          expiresAt,
        ],
      );
      break;
    } catch (error) {
      if (!String(error?.code || '').startsWith('SQLITE_CONSTRAINT')) {
        throw error;
      }
      deviceCode = undefined;
    }
  }
  if (!deviceCode || !normalizedUserCode) {
    throw deviceError('device_authorization_capacity_exhausted', 503);
  }
  const userCode = formatUserCode(normalizedUserCode);

  const verificationUri = new URL(kdjxConfig.deviceAuthorizationUrl);
  const verificationUriComplete = new URL(verificationUri);
  verificationUriComplete.searchParams.set('device_code', deviceCode);
  verificationUriComplete.searchParams.set('user_code', userCode);
  return {
    deviceCode,
    userCode,
    verificationUri: verificationUri.toString(),
    verificationUriComplete: verificationUriComplete.toString(),
    expiresAt,
    expiresIn: kdjxConfig.deviceCodeTtlSeconds,
    interval: kdjxConfig.devicePollIntervalSeconds,
  };
}

export function decideKdjxDeviceAuthorization({
  userId,
  deviceCode,
  userCode,
  approve,
  now = new Date(),
}) {
  ensureKdjxGameSchema();
  const selector = authorizationSelector({ deviceCode, userCode });
  const status = approve ? 'approved' : 'denied';
  const timestampColumn = approve ? 'approved_at' : 'denied_at';
  const decided = one(
    `UPDATE kdjx_device_authorizations
     SET status = ?, user_id = ?, ${timestampColumn} = ?
     WHERE ${selector.where} AND status = 'pending'
       AND datetime(expires_at) > datetime(?)
     RETURNING expires_at`,
    [status, userId, now.toISOString(), ...selector.params, now.toISOString()],
  );
  if (decided) {
    return { status, expiresAt: decided.expires_at };
  }

  const existing = one(
    `SELECT status, user_id, expires_at
     FROM kdjx_device_authorizations WHERE ${selector.where}`,
    selector.params,
  );
  if (!existing) throw deviceError(selector.invalidCode, 400);
  if (Date.parse(existing.expires_at) <= now.getTime()) {
    throw deviceError('expired_device_code', 410);
  }
  if (
    existing.status === status &&
    Number(existing.user_id) === Number(userId)
  ) {
    return { status, expiresAt: existing.expires_at };
  }
  throw deviceError('device_authorization_already_decided', 409);
}

export function exchangeKdjxDeviceCode(rawDeviceCode, now = new Date()) {
  ensureKdjxGameSchema();
  if (!validDeviceCode(rawDeviceCode)) {
    throw deviceError('invalid_device_code', 400);
  }
  const codeHash = deviceCodeHash(rawDeviceCode);
  let request = one(
    `SELECT status, user_id, poll_interval_seconds, expires_at,
            last_polled_at
     FROM kdjx_device_authorizations WHERE device_code_hash = ?`,
    [codeHash],
  );
  if (!request) throw deviceError('invalid_device_code', 400);
  if (Date.parse(request.expires_at) <= now.getTime()) {
    throw deviceError('expired_device_code', 410);
  }

  const interval = Number(request.poll_interval_seconds);
  const lastPoll = Date.parse(request.last_polled_at || '');
  if (Number.isFinite(lastPoll)) {
    const nextPoll = lastPoll + interval * 1000;
    if (nextPoll > now.getTime()) {
      throw deviceError(
        'slow_down',
        429,
        Math.max(1, Math.ceil((nextPoll - now.getTime()) / 1000)),
      );
    }
  }
  run(
    `UPDATE kdjx_device_authorizations SET last_polled_at = ?
     WHERE device_code_hash = ?`,
    [now.toISOString(), codeHash],
  );

  if (request.status === 'pending') {
    return { status: 'pending', retryAfter: interval };
  }
  if (request.status === 'denied') {
    throw deviceError('access_denied', 403);
  }
  if (request.status === 'consumed') {
    throw deviceError('device_code_already_used', 409);
  }

  let grant;
  db.exec('BEGIN IMMEDIATE');
  try {
    request = one(
      `UPDATE kdjx_device_authorizations
       SET status = 'consumed', consumed_at = ?
       WHERE device_code_hash = ? AND status = 'approved'
         AND datetime(expires_at) > datetime(?)
       RETURNING user_id`,
      [now.toISOString(), codeHash, now.toISOString()],
    );
    if (!request) throw deviceError('device_code_already_used', 409);
    grant = createKdjxSessionGrantInTransaction(request.user_id, now);
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
  return { status: 'authorized', ...grant };
}

function generateUserCode() {
  return Array.from(
    { length: 8 },
    () => userCodeAlphabet[randomInt(userCodeAlphabet.length)],
  ).join('');
}

function normalizeUserCode(value) {
  const normalized = String(value || '')
    .trim()
    .toUpperCase()
    .replace(/[\s-]/g, '');
  if (
    normalized.length !== 8 ||
    [...normalized].some((character) => !userCodeAlphabet.includes(character))
  ) {
    throw deviceError('invalid_user_code', 400);
  }
  return normalized;
}

function formatUserCode(value) {
  return `${value.slice(0, 4)}-${value.slice(4)}`;
}

function authorizationSelector({ deviceCode, userCode }) {
  const hasDeviceCode = deviceCode !== undefined && deviceCode !== null &&
    String(deviceCode).trim() !== '';
  const hasUserCode = userCode !== undefined && userCode !== null &&
    String(userCode).trim() !== '';
  if (!hasDeviceCode && !hasUserCode) {
    throw deviceError('invalid_device_code', 400);
  }

  const clauses = [];
  const params = [];
  if (hasDeviceCode) {
    if (!validDeviceCode(deviceCode)) {
      throw deviceError('invalid_device_code', 400);
    }
    clauses.push('device_code_hash = ?');
    params.push(deviceCodeHash(deviceCode));
  }
  if (hasUserCode) {
    clauses.push('user_code_hash = ?');
    params.push(userCodeHash(normalizeUserCode(userCode)));
  }
  return {
    where: clauses.join(' AND '),
    params,
    invalidCode: hasDeviceCode ? 'invalid_device_code' : 'invalid_user_code',
  };
}

function validDeviceCode(value) {
  return typeof value === 'string' &&
    value.startsWith('kdjx_device_') &&
    value.length >= 52 &&
    value.length <= 140;
}

function deviceError(code, statusCode, retryAfter) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  error.retryAfter = retryAfter;
  return error;
}
