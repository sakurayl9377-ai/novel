import { randomUUID, timingSafeEqual } from 'node:crypto';
import { kdjxConfig } from './kdjx-config.js';
import { db, one, run } from './db.js';
import { ensureKdjxGameSchema } from './kdjx-schema.js';
import {
  decryptSettingSecret,
  encryptSettingSecret,
} from './settings-secrets.js';
import { hashToken, randomToken } from './security.js';

const sessionHash = (credential) => hashToken(`kdjx-session:${credential}`);

export function createKdjxSessionGrantInTransaction(userId, now = new Date()) {
  const user = one('SELECT status FROM users WHERE id = ?', [userId]);
  if (!user || user.status !== 'active') {
    throw ssoError('account_not_active', 403);
  }
  const link = ensureAccountLink(userId);
  const credential = `kdjx_session_${randomToken(32)}`;
  const sessionId = randomUUID();
  const credentialExpiresAt = new Date(
    now.getTime() + kdjxConfig.sessionTtlDays * 86400 * 1000,
  ).toISOString();
  run(
    `INSERT INTO kdjx_game_sessions
      (id, token_hash, user_id, game_open_id, expires_at)
     VALUES (?, ?, ?, ?, ?)`,
    [
      sessionId,
      sessionHash(credential),
      userId,
      link.game_open_id,
      credentialExpiresAt,
    ],
  );
  run(
    `UPDATE kdjx_game_sessions
     SET revoked_at = datetime('now')
     WHERE id IN (
       SELECT id FROM kdjx_game_sessions
       WHERE user_id = ? AND revoked_at IS NULL
         AND datetime(expires_at) > datetime('now')
       ORDER BY datetime(created_at) DESC, rowid DESC
       LIMIT -1 OFFSET ?
     )`,
    [userId, kdjxConfig.sessionMaxPerUser],
  );
  return {
    sessionId,
    credential,
    credentialExpiresAt,
    credentialExpiresIn: kdjxConfig.sessionTtlDays * 86400,
    gameOpenId: link.game_open_id,
  };
}

export function verifyKdjxCredential(rawCredential) {
  ensureKdjxGameSchema();
  if (!validOpaqueToken(rawCredential, 'kdjx_session_')) return null;
  const session = one(
    `UPDATE kdjx_game_sessions AS session
     SET last_used_at = datetime('now')
     WHERE token_hash = ?
       AND revoked_at IS NULL
       AND datetime(expires_at) > datetime('now')
       AND EXISTS (
         SELECT 1 FROM users user
         WHERE user.id = session.user_id AND user.status = 'active'
       )
     RETURNING id`,
    [sessionHash(rawCredential)],
  );
  return session ? sessionIdentity(session.id) : null;
}

export function revokeKdjxCredentials(userId, rawCredential) {
  ensureKdjxGameSchema();
  if (rawCredential !== undefined && rawCredential !== null) {
    if (!validOpaqueToken(rawCredential, 'kdjx_session_')) {
      throw ssoError('invalid_credential', 400);
    }
    return Number(run(
      `UPDATE kdjx_game_sessions
       SET revoked_at = datetime('now')
       WHERE user_id = ? AND token_hash = ? AND revoked_at IS NULL`,
      [userId, sessionHash(rawCredential)],
    ).changes || 0);
  }
  return Number(run(
    `UPDATE kdjx_game_sessions
     SET revoked_at = datetime('now')
     WHERE user_id = ? AND revoked_at IS NULL`,
    [userId],
  ).changes || 0);
}

export function recordKdjxGameIdentity({
  userId,
  gameOpenId,
  accountId,
  roleId,
  serverKey,
}) {
  ensureKdjxGameSchema();
  const updated = run(
    `UPDATE kdjx_game_account_links
     SET game_account_id = ?, last_role_id = ?, last_server_key = ?,
         updated_at = datetime('now')
     WHERE novel_user_id = ? AND game_open_id = ?`,
    [accountId, roleId, serverKey, userId, gameOpenId],
  );
  if ((updated.changes || 0) !== 1) {
    throw ssoError('game_account_not_linked', 409);
  }
}

export function verifyKdjxSharedSecret(candidate) {
  const expected = Buffer.from(kdjxConfig.ssoSharedSecret);
  const actual = Buffer.from(String(candidate || ''));
  return expected.length > 0 &&
    expected.length === actual.length &&
    timingSafeEqual(expected, actual);
}

function ensureAccountLink(userId) {
  let link = one(
    `SELECT * FROM kdjx_game_account_links WHERE novel_user_id = ?`,
    [userId],
  );
  if (link) return link;
  run(
    `INSERT INTO kdjx_game_account_links
      (novel_user_id, game_open_id, account_password_cipher)
     VALUES (?, ?, ?)
     ON CONFLICT(novel_user_id) DO NOTHING`,
    [
      userId,
      `sakura_${randomToken(18)}`,
      encryptSettingSecret(randomToken(24)),
    ],
  );
  link = one(
    `SELECT * FROM kdjx_game_account_links WHERE novel_user_id = ?`,
    [userId],
  );
  if (!link) throw ssoError('game_account_link_failed', 500);
  return link;
}

function sessionIdentity(sessionId) {
  const row = one(
    `SELECT session.id, session.user_id, session.game_open_id,
            session.expires_at, user.nickname, user.avatar_url,
            link.account_password_cipher
     FROM kdjx_game_sessions session
     JOIN users user ON user.id = session.user_id
     JOIN kdjx_game_account_links link
       ON link.novel_user_id = session.user_id
      AND link.game_open_id = session.game_open_id
     WHERE session.id = ? AND session.revoked_at IS NULL
       AND datetime(session.expires_at) > datetime('now')
       AND user.status = 'active'`,
    [sessionId],
  );
  if (!row) return null;
  return {
    sessionId: row.id,
    userId: Number(row.user_id),
    gameOpenId: row.game_open_id,
    accountName: row.game_open_id,
    accountPassword: decryptSettingSecret(row.account_password_cipher),
    channel: 'sakura',
    nickname: row.nickname,
    avatarUrl: row.avatar_url || '',
    credentialExpiresAt: row.expires_at,
  };
}

function validOpaqueToken(value, prefix) {
  return typeof value === 'string' &&
    value.startsWith(prefix) &&
    value.length >= prefix.length + 40 &&
    value.length <= prefix.length + 128;
}

function ssoError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}
