import { all, one, run } from "./db.js";

const dailyViolationLimit = 5;
const permanentBanLimit = 3;

export function refreshExpiredBan(userOrId) {
  if (!userOrId) return null;
  const user =
    typeof userOrId === "object"
      ? userOrId
      : one("SELECT * FROM users WHERE id = ?", [userOrId]);
  if (!user) return null;
  if (user.status !== "banned" || !user.banned_until) return user;
  if (new Date(user.banned_until).getTime() > Date.now()) return user;

  run(
    `UPDATE users
     SET status = 'active',
         banned_until = '',
         ban_reason = '',
         updated_at = datetime('now')
     WHERE id = ? AND status = 'banned'`,
    [user.id],
  );
  return one("SELECT * FROM users WHERE id = ?", [user.id]);
}

export function isRegistrationIpBlocked(ip) {
  const normalizedIp = normalizeIp(ip);
  if (!normalizedIp) return false;
  return Boolean(
    one("SELECT ip FROM banned_registration_ips WHERE ip = ?", [normalizedIp]),
  );
}

export function recordBannedRegistrationIp({ userId, ip, reason = "" }) {
  const normalizedIp = normalizeIp(ip);
  if (!normalizedIp) return;
  run(
    `INSERT INTO banned_registration_ips (ip, user_id, reason)
     VALUES (?, ?, ?)
     ON CONFLICT(ip) DO UPDATE SET
       user_id = excluded.user_id,
       reason = excluded.reason`,
    [normalizedIp, userId || null, String(reason || "").slice(0, 120)],
  );
}

export function recordKnownUserBanIps(userId, reason = "") {
  const user = one(
    `SELECT id, register_ip, last_login_ip
     FROM users
     WHERE id = ?`,
    [userId],
  );
  if (!user) return;
  recordBannedRegistrationIp({
    userId,
    ip: user.register_ip,
    reason,
  });
  recordBannedRegistrationIp({
    userId,
    ip: user.last_login_ip,
    reason,
  });
}

export function findActiveChatKeyword(content) {
  const normalized = normalizeForKeyword(content);
  if (!normalized) return null;
  const rows = all(
    `SELECT id, keyword, match_type, severity, status
     FROM chat_block_keywords
     WHERE status = 'active'
     ORDER BY LENGTH(keyword) DESC, id ASC`,
  );
  for (const row of rows) {
    const keyword = normalizeForKeyword(row.keyword);
    if (!keyword) continue;
    if (row.match_type === "exact" && normalized === keyword) return row;
    if (row.match_type !== "exact" && normalized.includes(keyword)) return row;
  }
  return null;
}

export function recordChatViolation({ userId, roomId, content, keyword, ip }) {
  const keywordText = String(keyword?.keyword || "").trim();
  const keywordId = keyword?.id || null;
  const violation = run(
    `INSERT INTO chat_violations
      (user_id, room_id, content, keyword_id, keyword, action, ip)
     VALUES (?, ?, ?, ?, ?, 'blocked', ?)`,
    [
      userId,
      String(roomId || "global").slice(0, 120),
      String(content || "").slice(0, 800),
      keywordId,
      keywordText,
      normalizeIp(ip),
    ],
  );
  run(
    `UPDATE users
     SET chat_violation_total = chat_violation_total + 1,
         updated_at = datetime('now')
     WHERE id = ?`,
    [userId],
  );

  const dayCount = one(
    `SELECT COUNT(*) AS count
     FROM chat_violations
     WHERE user_id = ?
       AND created_at >= datetime('now', 'start of day')`,
    [userId],
  ).count;
  if (dayCount <= dailyViolationLimit) {
    return {
      action: "blocked",
      dayCount,
      violationId: Number(violation.lastInsertRowid),
    };
  }

  const user = one(
    `SELECT id, chat_temp_ban_count
     FROM users
     WHERE id = ?`,
    [userId],
  );
  const nextTempBanCount = (user?.chat_temp_ban_count || 0) + 1;
  if (nextTempBanCount >= permanentBanLimit) {
    run(
      `UPDATE users
       SET status = 'banned',
           banned_until = '',
           ban_reason = 'chat_keyword_permanent',
           chat_temp_ban_count = ?,
           updated_at = datetime('now')
       WHERE id = ?`,
      [nextTempBanCount, userId],
    );
    recordKnownUserBanIps(userId, "chat_keyword_permanent");
    recordBannedRegistrationIp({
      userId,
      ip,
      reason: "chat_keyword_permanent",
    });
    run("UPDATE chat_violations SET action = 'permanent_ban' WHERE id = ?", [
      Number(violation.lastInsertRowid),
    ]);
    return {
      action: "permanent_ban",
      dayCount,
      tempBanCount: nextTempBanCount,
      violationId: Number(violation.lastInsertRowid),
    };
  }

  run(
    `UPDATE users
     SET status = 'banned',
         banned_until = datetime('now', '+1 day'),
         ban_reason = 'chat_keyword_temp',
         chat_temp_ban_count = ?,
         updated_at = datetime('now')
     WHERE id = ?`,
    [nextTempBanCount, userId],
  );
  recordKnownUserBanIps(userId, "chat_keyword_temp");
  recordBannedRegistrationIp({
    userId,
    ip,
    reason: "chat_keyword_temp",
  });
  run("UPDATE chat_violations SET action = 'temp_ban' WHERE id = ?", [
    Number(violation.lastInsertRowid),
  ]);
  return {
    action: "temp_ban",
    dayCount,
    tempBanCount: nextTempBanCount,
    violationId: Number(violation.lastInsertRowid),
  };
}

function normalizeForKeyword(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/\s+/g, "")
    .replace(/[._\-~·,，。!！?？:：;；'"“”‘’()[\]{}【】<>《》]/g, "")
    .trim();
}

function normalizeIp(value) {
  return String(value || "").trim().slice(0, 80);
}
