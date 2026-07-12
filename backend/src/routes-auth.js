import { createSession, loginWithPassword, serializeAuth } from './auth.js';
import { isRegistrationIpBlocked } from './chat-moderation.js';
import { config } from './config.js';
import { one, run } from './db.js';
import { sendVerificationEmail } from './mailer.js';
import { enforceRateLimits } from './rate-limit.js';
import {
  createSvgCaptcha,
  hashCode,
  hashToken,
  hashPassword,
  minutesFromNow,
  normalizeEmail,
  publicUser,
  safeEqual,
  sixDigitCode,
} from './security.js';
import {
  badRequest,
  email as parseEmail,
  optionalString,
  password as parsePassword,
  requiredString,
} from './validators.js';

const emailCooldownSeconds = 60;
const emailDailyLimit = 5;
const emailDailyWindowSeconds = 24 * 60 * 60;

export async function authRoutes(app) {
  app.get('/auth/captcha', async (request, reply) => {
    const limited = enforceRateLimits(request, reply, [
      rateRule('auth_captcha_ip', request.ip, 30, 5 * 60 * 1000),
    ]);
    if (limited) return limited;
    const captcha = createSvgCaptcha();
    const id = cryptoRandomId();
    run(
      `INSERT INTO image_captchas
       (id, answer_hash, ip, user_agent, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
      [
        id,
        hashCode(captcha.answer, `captcha:${id}`),
        request.ip,
        request.headers['user-agent'] || '',
        minutesFromNow(5),
      ],
    );

    return {
      captchaId: id,
      imageSvg: captcha.svg,
      expiresIn: 300,
      ...(config.allowDevAuthCodes ? { devAnswer: captcha.answer } : {}),
    };
  });

  app.get('/auth/email-status', async (request) => {
    const targetEmail = parseEmail(request.query?.email);
    const purpose = optionalString(request.query?.purpose, 32) || 'register';
    if (!['register', 'reset_password'].includes(purpose)) {
      throw badRequest('purpose is invalid');
    }
    const existing = one('SELECT id FROM users WHERE email = ?', [
      targetEmail,
    ]);
    if (purpose === 'register') {
      return {
        ok: true,
        available: !existing,
        registered: Boolean(existing),
        message: existing ? 'email already registered' : 'email available',
      };
    }
    return {
      ok: true,
      available: Boolean(existing),
      registered: Boolean(existing),
      message: existing ? 'email registered' : 'email not registered',
    };
  });

  app.post('/auth/email-code', async (request, reply) => {
    const body = request.body || {};
    const targetEmail = parseEmail(body.email);
    const purpose = optionalString(body.purpose, 32) || 'register';
    if (!['register', 'reset_password'].includes(purpose)) {
      throw badRequest('purpose is invalid');
    }
    const limited = enforceRateLimits(request, reply, [
      rateRule('auth_email_code_ip', request.ip, 10, 10 * 60 * 1000),
    ]);
    if (limited) return limited;
    if (purpose === 'register' && isRegistrationIpBlocked(request.ip)) {
      throw badRequest('registration ip banned');
    }

    consumeImageCaptcha({
      captchaId: requiredString(body.captchaId, 'captchaId', 80),
      captchaCode: requiredString(body.captchaCode, 'captchaCode', 16),
      ip: request.ip,
    });

    if (purpose === 'register') {
      const existing = one('SELECT id FROM users WHERE email = ?', [
        targetEmail,
      ]);
      if (existing) throw badRequest('email already registered');
    } else if (purpose === 'reset_password') {
      const existing = one('SELECT id FROM users WHERE email = ?', [
        targetEmail,
      ]);
      if (!existing) throw badRequest('email not registered');
    }

    const dailyLimit = emailDailyLimitState(targetEmail);
    if (dailyLimit.limited) {
      return reply.code(429).send({
        error: 'email_code_daily_limit',
        retryAfter: dailyLimit.retryAfter,
      });
    }

    const recentForEmail = one(
      `SELECT created_at
       FROM email_verifications
       WHERE email = ? AND purpose = ?
       ORDER BY id DESC LIMIT 1`,
      [targetEmail, purpose],
    );
    const recentForIp = one(
      `SELECT created_at
       FROM email_verifications
       WHERE ip = ? AND purpose = ?
       ORDER BY id DESC LIMIT 1`,
      [request.ip, purpose],
    );
    const wait = Math.max(
      cooldownWait(recentForEmail?.created_at),
      cooldownWait(recentForIp?.created_at),
    );
    if (wait > 0) {
      return reply.code(429).send({
        error: 'email_code_cooldown',
        retryAfter: wait,
      });
    }

    const code = sixDigitCode();
    run(
      `INSERT INTO email_verifications
       (email, code_hash, purpose, ip, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
      [
        targetEmail,
        hashCode(code, `email:${targetEmail}:${purpose}`),
        purpose,
        request.ip,
        minutesFromNow(10),
      ],
    );

    const delivery = await sendVerificationEmail(targetEmail, code);
    return {
      ok: true,
      expiresIn: 600,
      retryAfter: emailCooldownSeconds,
      devCode: delivery.devCode,
    };
  });

  app.post('/auth/register', async (request, reply) => {
    const body = request.body || {};
    const targetEmail = parseEmail(body.email);
    const password = parsePassword(body.password);
    const nickname =
      optionalString(body.nickname, 32) || targetEmail.split('@')[0];
    const emailCode = requiredString(body.emailCode, 'emailCode', 16);
    const limited = enforceRateLimits(request, reply, [
      rateRule('auth_register_ip', request.ip, 10, 15 * 60 * 1000),
      rateRule('auth_register_email', targetEmail, 5, 15 * 60 * 1000),
    ]);
    if (limited) return limited;

    if (isRegistrationIpBlocked(request.ip)) {
      throw badRequest('registration ip banned');
    }

    const existing = one('SELECT id FROM users WHERE email = ?', [
      targetEmail,
    ]);
    if (existing) throw badRequest('email already registered');

    consumeEmailCode({
      email: targetEmail,
      purpose: 'register',
      code: emailCode,
    });

    const result = run(
      `INSERT INTO users (email, nickname, password_hash, register_ip, last_login_ip)
       VALUES (?, ?, ?, ?, ?)`,
      [
        targetEmail,
        nickname,
        hashPassword(password),
        String(request.ip || '').slice(0, 80),
        String(request.ip || '').slice(0, 80),
      ],
    );
    const user = one('SELECT * FROM users WHERE id = ?', [
      result.lastInsertRowid,
    ]);
    return serializeAuth(user, createSession(user.id));
  });

  app.post('/auth/reset-password', async (request, reply) => {
    const body = request.body || {};
    const targetEmail = parseEmail(body.email);
    const password = parsePassword(body.password);
    const emailCode = requiredString(body.emailCode, 'emailCode', 16);
    const limited = enforceRateLimits(request, reply, [
      rateRule('auth_reset_ip', request.ip, 10, 15 * 60 * 1000),
      rateRule('auth_reset_email', targetEmail, 5, 15 * 60 * 1000),
    ]);
    if (limited) return limited;

    const user = one('SELECT * FROM users WHERE email = ?', [targetEmail]);
    if (!user) throw badRequest('email not registered');

    consumeEmailCode({
      email: targetEmail,
      purpose: 'reset_password',
      code: emailCode,
    });

    run(
      `UPDATE users
       SET password_hash = ?,
           updated_at = datetime('now')
       WHERE id = ?`,
      [hashPassword(password), user.id],
    );
    run(
      `UPDATE auth_tokens
       SET revoked_at = datetime('now')
       WHERE user_id = ? AND revoked_at IS NULL`,
      [user.id],
    );
    const updated = one('SELECT * FROM users WHERE id = ?', [user.id]);
    return serializeAuth(updated, createSession(user.id));
  });

  app.post('/auth/login', async (request, reply) => {
    const body = request.body || {};
    const targetEmail = normalizeEmail(body.email);
    const password = String(body.password || '');
    const limited = enforceRateLimits(request, reply, [
      rateRule('auth_login_ip', request.ip, 20, 15 * 60 * 1000),
      rateRule('auth_login_account', targetEmail || 'empty', 10, 15 * 60 * 1000),
    ]);
    if (limited) return limited;

    if (body.captchaId || body.captchaCode) {
      consumeImageCaptcha({
        captchaId: requiredString(body.captchaId, 'captchaId', 80),
        captchaCode: requiredString(body.captchaCode, 'captchaCode', 16),
        ip: request.ip,
      });
    }

    const result = loginWithPassword(targetEmail, password, request.ip);
    if (!result) return reply.code(401).send({ error: 'invalid_credentials' });
    if (result.blocked) {
      return reply.code(403).send({ error: `account_${result.blocked}` });
    }
    return serializeAuth(result.user, result.token);
  });

  app.get('/auth/me', { preHandler: app.authRequired }, async (request) => ({
    user: publicUser(request.user),
  }));

  app.post('/auth/logout', { preHandler: app.authRequired }, async (request) => {
    const header = request.headers.authorization || '';
    const token = header.replace(/^Bearer\s+/i, '').trim();
    if (token) {
      run(
        `UPDATE auth_tokens
         SET revoked_at = datetime('now')
         WHERE token_hash = ?`,
        [hashToken(token)],
      );
    }
    return { ok: true };
  });
}

function consumeImageCaptcha({ captchaId, captchaCode, ip }) {
  const row = one(
    `SELECT *
     FROM image_captchas
     WHERE id = ? AND used_at IS NULL AND expires_at > datetime('now')`,
    [captchaId],
  );
  if (!row || row.ip !== ip) throw badRequest('captcha invalid');
  const expected = hashCode(captchaCode, `captcha:${captchaId}`);
  if (!safeEqual(expected, row.answer_hash)) {
    run(
      `UPDATE image_captchas
       SET attempt_count = attempt_count + 1,
           used_at = CASE
             WHEN attempt_count + 1 >= 5 THEN datetime('now')
             ELSE used_at
           END
       WHERE id = ? AND used_at IS NULL`,
      [captchaId],
    );
    throw badRequest('captcha invalid');
  }
  run("UPDATE image_captchas SET used_at = datetime('now') WHERE id = ?", [
    captchaId,
  ]);
}

function consumeEmailCode({ email, purpose, code }) {
  const row = one(
    `SELECT *
     FROM email_verifications
     WHERE email = ?
       AND purpose = ?
       AND verified_at IS NULL
       AND expires_at > datetime('now')
     ORDER BY id DESC
     LIMIT 1`,
    [email, purpose],
  );
  if (!row) throw badRequest('email code invalid');
  const expected = hashCode(code, `email:${email}:${purpose}`);
  if (!safeEqual(expected, row.code_hash)) {
    run(
      `UPDATE email_verifications
       SET attempt_count = attempt_count + 1,
           verified_at = CASE
             WHEN attempt_count + 1 >= 5 THEN datetime('now')
             ELSE verified_at
           END
       WHERE id = ? AND verified_at IS NULL`,
      [row.id],
    );
    throw badRequest('email code invalid');
  }
  run(
    "UPDATE email_verifications SET verified_at = datetime('now') WHERE id = ?",
    [row.id],
  );
}

function cryptoRandomId() {
  return globalThis.crypto.randomUUID();
}

function cooldownWait(createdAt) {
  if (!createdAt) return 0;
  const normalized = String(createdAt).replace(' ', 'T') + 'Z';
  const elapsed = (Date.now() - Date.parse(normalized)) / 1000;
  return Math.max(0, Math.ceil(emailCooldownSeconds - elapsed));
}

function rateRule(scope, key, limit, windowMs) {
  return {
    scope,
    key: key || 'unknown',
    limit,
    windowMs,
    error: 'auth_rate_limited',
  };
}

function emailDailyLimitState(email) {
  const row = one(
    `SELECT COUNT(*) AS count, MIN(created_at) AS oldest_created_at
     FROM email_verifications
     WHERE email = ?
       AND created_at > datetime('now', '-24 hours')`,
    [email],
  );
  const count = Number(row?.count || 0);
  if (count < emailDailyLimit) {
    return { limited: false, retryAfter: 0 };
  }
  return {
    limited: true,
    retryAfter: dailyLimitRetryAfter(row?.oldest_created_at),
  };
}

function dailyLimitRetryAfter(createdAt) {
  if (!createdAt) return emailDailyWindowSeconds;
  const normalized = String(createdAt).replace(' ', 'T') + 'Z';
  const resetAt = Date.parse(normalized) + emailDailyWindowSeconds * 1000;
  return Math.max(1, Math.ceil((resetAt - Date.now()) / 1000));
}
