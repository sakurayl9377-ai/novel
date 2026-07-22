import { timingSafeEqual } from 'node:crypto';
import { config } from './config.js';
import { one, run } from './db.js';
import { hashToken, randomToken } from './security.js';

export function bailianSsoAvailable() {
  return Boolean(
    config.bailianLaunchUrl?.trim() && config.bailianSsoSharedSecret?.trim(),
  );
}

export function issueBailianTicket(userId, now = new Date()) {
  const rawTicket = randomToken(32);
  const expiresAt = new Date(
    now.getTime() + config.bailianSsoTtlSeconds * 1000,
  ).toISOString();

  run(
    `INSERT INTO game_account_links (novel_user_id, game_open_id)
     VALUES (?, ?)
     ON CONFLICT(novel_user_id) DO NOTHING`,
    [userId, `novel_${userId}`],
  );
  const openId = one(
    'SELECT game_open_id FROM game_account_links WHERE novel_user_id = ?',
    [userId],
  ).game_open_id;
  run(
    `DELETE FROM game_sso_tickets
     WHERE datetime(expires_at) <= datetime('now')`,
  );
  run(
    `INSERT INTO game_sso_tickets
       (ticket_hash, user_id, game_open_id, expires_at)
     VALUES (?, ?, ?, ?)`,
    [hashToken(rawTicket), userId, openId, expiresAt],
  );

  const launchUrl = new URL(config.bailianLaunchUrl);
  launchUrl.searchParams.set('ticket', rawTicket);
  launchUrl.searchParams.set('openId', openId);
  launchUrl.searchParams.set('online', '1');
  return {
    ticket: rawTicket,
    launchUrl: launchUrl.toString(),
    expiresAt,
    expiresIn: config.bailianSsoTtlSeconds,
  };
}

export function consumeBailianTicket(rawTicket, expectedGameOpenId = null) {
  if (!rawTicket || typeof rawTicket !== 'string') return null;
  const ticketHash = hashToken(rawTicket);
  const openId = trimToNull(expectedGameOpenId);
  const consumed = openId
    ? one(
      `UPDATE game_sso_tickets
       SET consumed_at = datetime('now')
       WHERE ticket_hash = ?
         AND game_open_id = ?
         AND consumed_at IS NULL
         AND datetime(expires_at) > datetime('now')
       RETURNING user_id, game_open_id, expires_at`,
      [ticketHash, openId],
    )
    : one(
      `UPDATE game_sso_tickets
       SET consumed_at = datetime('now')
       WHERE ticket_hash = ?
         AND consumed_at IS NULL
         AND datetime(expires_at) > datetime('now')
       RETURNING user_id, game_open_id, expires_at`,
      [ticketHash],
    );
  if (consumed) return consumed;

  // A game socket can reconnect while the WebView still holds the original
  // launch URL. Allow that bounded replay only for the same account and only
  // while the ticket's original expiry window is still open.
  if (!openId) return null;
  return one(
    `SELECT user_id, game_open_id, expires_at
     FROM game_sso_tickets
     WHERE ticket_hash = ?
       AND game_open_id = ?
       AND consumed_at IS NOT NULL
       AND datetime(expires_at) > datetime('now')`,
    [ticketHash, openId],
  );
}

function trimToNull(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed || null;
}

export function verifyBailianSharedSecret(candidate) {
  const expected = Buffer.from(config.bailianSsoSharedSecret || '');
  const actual = Buffer.from(String(candidate || ''));
  return expected.length > 0 &&
    expected.length === actual.length &&
    timingSafeEqual(expected, actual);
}
