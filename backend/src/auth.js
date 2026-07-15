import { one, run } from './db.js';
import { refreshExpiredBan } from './chat-moderation.js';
import {
  hashToken,
  privateUser,
  randomToken,
  tokenExpiry,
  verifyPassword,
} from './security.js';

export function createSession(userId) {
  const token = randomToken();
  run(
    `INSERT INTO auth_tokens (user_id, token_hash, expires_at)
     VALUES (?, ?, ?)`,
    [userId, hashToken(token), tokenExpiry()],
  );
  return token;
}

export function findUserByBearer(request) {
  const header = request.headers.authorization || '';
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) return null;
  return findUserByToken(match[1].trim());
}

export function findUserByToken(token) {
  if (!token) return null;
  const tokenHash = hashToken(token);
  const user = one(
    `SELECT u.*
     FROM auth_tokens t
     JOIN users u ON u.id = t.user_id
     WHERE t.token_hash = ?
       AND t.revoked_at IS NULL
       AND datetime(t.expires_at) > datetime('now')
       AND u.status != 'deleted'`,
    [tokenHash],
  );
  return refreshExpiredBan(user);
}

export async function authOptional(request) {
  request.user = findUserByBearer(request);
}

export async function authRequired(request, reply) {
  const user = findUserByBearer(request);
  if (!user) {
    return reply.code(401).send({ error: 'unauthorized' });
  }
  if (user.status === 'banned') {
    return reply.code(403).send({ error: 'account_banned' });
  }
  request.user = user;
}

export async function adminRequired(request, reply) {
  const user = findUserByBearer(request);
  if (!user) {
    return reply.code(401).send({ error: 'unauthorized' });
  }
  if (user.status !== 'active') {
    return reply.code(403).send({ error: `account_${user.status}` });
  }
  if (user.role !== 'admin') {
    return reply.code(403).send({ error: 'admin_required' });
  }
  request.user = user;
}

export function loginWithPassword(email, password, ip = '') {
  const user = refreshExpiredBan(
    one('SELECT * FROM users WHERE email = ?', [email]),
  );
  if (!user || !verifyPassword(password, user.password_hash)) return null;
  if (user.status !== 'active') return { blocked: user.status };
  run(
    "UPDATE users SET last_login_at = datetime('now'), last_login_ip = ? WHERE id = ?",
    [String(ip || '').slice(0, 80), user.id],
  );
  return { user, token: createSession(user.id) };
}

export function serializeAuth(user, token) {
  return { token, user: privateUser(user) };
}
