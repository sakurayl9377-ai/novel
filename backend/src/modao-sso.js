import { timingSafeEqual } from 'node:crypto';
import { config } from './config.js';
import { one, run } from './db.js';
import { ensureModaoGameSchema } from './modao-schema.js';
import { hashToken, randomToken } from './security.js';

export function modaoSsoAvailable() {
  return Boolean(
    config.modaoLaunchUrl?.trim() && config.modaoSsoSharedSecret?.trim(),
  );
}

export function issueModaoTicket(userId, now = new Date()) {
  ensureModaoGameSchema();
  const openIdCandidate = `modao_${randomToken(18)}`;
  run(
    `INSERT INTO modao_game_account_links (novel_user_id, game_open_id)
     VALUES (?, ?)
     ON CONFLICT(novel_user_id) DO NOTHING`,
    [userId, openIdCandidate],
  );
  const link = one(
    'SELECT game_open_id FROM modao_game_account_links WHERE novel_user_id = ?',
    [userId],
  );
  if (!link) throw new Error('modao_account_link_failed');

  const rawTicket = randomToken(32);
  const expiresAt = new Date(
    now.getTime() + config.modaoSsoTtlSeconds * 1000,
  ).toISOString();
  run(
    `DELETE FROM modao_game_sso_tickets
     WHERE datetime(expires_at) <= datetime('now')`,
  );
  run(
    `INSERT INTO modao_game_sso_tickets
       (ticket_hash, user_id, game_open_id, expires_at)
     VALUES (?, ?, ?, ?)`,
    [hashToken(rawTicket), userId, link.game_open_id, expiresAt],
  );

  const launchUrl = new URL(config.modaoLaunchUrl);
  launchUrl.searchParams.set('ticket', rawTicket);
  launchUrl.searchParams.set('openId', link.game_open_id);
  return {
    ticket: rawTicket,
    launchUrl: launchUrl.toString(),
    expiresAt,
    expiresIn: config.modaoSsoTtlSeconds,
  };
}

export function consumeModaoTicket(rawTicket) {
  ensureModaoGameSchema();
  if (!rawTicket || typeof rawTicket !== 'string') return null;
  const consumed = one(
    `UPDATE modao_game_sso_tickets
     SET consumed_at = datetime('now')
     WHERE ticket_hash = ?
       AND consumed_at IS NULL
       AND datetime(expires_at) > datetime('now')
     RETURNING user_id, game_open_id, expires_at`,
    [hashToken(rawTicket)],
  );
  if (!consumed) return null;
  const user = one(
    'SELECT nickname, avatar_url, status FROM users WHERE id = ?',
    [consumed.user_id],
  );
  if (!user || user.status !== 'active') return null;
  return {
    ...consumed,
    nickname: user.nickname,
    avatar_url: user.avatar_url,
  };
}

export function verifyModaoSharedSecret(candidate) {
  const expected = Buffer.from(config.modaoSsoSharedSecret || '');
  const actual = Buffer.from(String(candidate || ''));
  return expected.length > 0 &&
    expected.length === actual.length &&
    timingSafeEqual(expected, actual);
}
