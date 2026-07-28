import { all, one, run } from './db.js';
import {
  releaseStaleKdjxPaymentClaims,
  retryKdjxPayment,
} from './kdjx-payments.js';
import { ensureKdjxGameSchema } from './kdjx-schema.js';
import { revokeKdjxCredentials } from './kdjx-sso.js';

const paymentStatuses = new Set([
  'paid',
  'fulfilling',
  'delivery_failed',
  'fulfilled',
]);
const userStatuses = new Set(['active', 'banned']);
const retryablePaymentStatuses = new Set(['paid', 'delivery_failed']);

export async function adminKdjxGmRoutes(app, options = {}) {
  ensureKdjxGameSchema();
  const retryPayment = options.retryPayment || retryKdjxPayment;

  app.get(
    '/admin/games/kdjx/gm/workbench',
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      releaseStaleKdjxPaymentClaims();
      const page = pageNumber(request.query?.page);
      const pageSize = pageSizeNumber(request.query?.pageSize);
      const status = optionalStatus(request.query?.status, userStatuses);
      const q = optionalQuery(request.query?.q);
      const { clause, params } = playerFilters({ q, status });
      const total = Number(one(
        `SELECT COUNT(*) AS count
         FROM kdjx_game_account_links link
         JOIN users user ON user.id = link.novel_user_id
         ${clause}`,
        params,
      )?.count || 0);
      const players = all(
        `SELECT user.id AS user_id, user.email, user.nickname,
                user.status AS user_status, user.role AS user_role,
                user.sakura_coins, user.created_at AS user_created_at,
                user.last_login_at,
                link.game_open_id, link.game_account_id,
                link.last_role_id, link.last_server_key,
                link.created_at AS linked_at, link.updated_at AS linked_updated_at,
                (SELECT COUNT(*) FROM kdjx_game_sessions session
                 WHERE session.user_id = user.id
                   AND session.revoked_at IS NULL
                   AND datetime(session.expires_at) > datetime('now'))
                  AS active_game_sessions,
                (SELECT COUNT(*) FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id) AS payment_count,
                (SELECT payment.status FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id
                 ORDER BY datetime(payment.created_at) DESC, payment.rowid DESC
                 LIMIT 1) AS last_payment_status,
                (SELECT payment.created_at FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id
                 ORDER BY datetime(payment.created_at) DESC, payment.rowid DESC
                 LIMIT 1) AS last_payment_at
         FROM kdjx_game_account_links link
         JOIN users user ON user.id = link.novel_user_id
         ${clause}
         ORDER BY datetime(link.updated_at) DESC, user.id DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, (page - 1) * pageSize],
      ).map(playerJson);
      return {
        generatedAt: new Date().toISOString(),
        page,
        pageSize,
        total,
        summary: workbenchSummary(),
        players,
        recentActions: recentGmActions(),
      };
    },
  );

  app.get(
    '/admin/games/kdjx/gm/players/:userId',
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      releaseStaleKdjxPaymentClaims();
      const userId = positiveId(request.params?.userId, 'user_id');
      const row = one(
        `SELECT user.id AS user_id, user.email, user.nickname,
                user.status AS user_status, user.role AS user_role,
                user.sakura_coins, user.created_at AS user_created_at,
                user.last_login_at,
                link.game_open_id, link.game_account_id,
                link.last_role_id, link.last_server_key,
                link.created_at AS linked_at, link.updated_at AS linked_updated_at,
                (SELECT COUNT(*) FROM kdjx_game_sessions session
                 WHERE session.user_id = user.id
                   AND session.revoked_at IS NULL
                   AND datetime(session.expires_at) > datetime('now'))
                  AS active_game_sessions,
                (SELECT COUNT(*) FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id) AS payment_count,
                (SELECT payment.status FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id
                 ORDER BY datetime(payment.created_at) DESC, payment.rowid DESC
                 LIMIT 1) AS last_payment_status,
                (SELECT payment.created_at FROM kdjx_payment_orders payment
                 WHERE payment.user_id = user.id
                 ORDER BY datetime(payment.created_at) DESC, payment.rowid DESC
                 LIMIT 1) AS last_payment_at
         FROM kdjx_game_account_links link
         JOIN users user ON user.id = link.novel_user_id
         WHERE user.id = ?`,
        [userId],
      );
      if (!row) throw routeError('kdjx_player_not_found', 404);
      return {
        player: playerJson(row),
        sessions: all(
          `SELECT id, expires_at, last_used_at, revoked_at, created_at
           FROM kdjx_game_sessions
           WHERE user_id = ?
           ORDER BY datetime(created_at) DESC, rowid DESC
           LIMIT 50`,
          [userId],
        ).map(sessionJson),
        payments: all(
          `SELECT * FROM kdjx_payment_orders
           WHERE user_id = ?
           ORDER BY datetime(created_at) DESC, rowid DESC
           LIMIT 100`,
          [userId],
        ).map(paymentJson),
      };
    },
  );

  app.get(
    '/admin/games/kdjx/gm/payments',
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      releaseStaleKdjxPaymentClaims();
      const page = pageNumber(request.query?.page);
      const pageSize = pageSizeNumber(request.query?.pageSize);
      const status = optionalStatus(request.query?.status, paymentStatuses);
      const q = optionalQuery(request.query?.q);
      const userId = optionalPositiveId(request.query?.userId, 'user_id');
      const { clause, params } = paymentFilters({ q, status, userId });
      const total = Number(one(
        `SELECT COUNT(*) AS count
         FROM kdjx_payment_orders payment
         JOIN users user ON user.id = payment.user_id
         ${clause}`,
        params,
      )?.count || 0);
      const payments = all(
        `SELECT payment.*, user.email, user.nickname, user.status AS user_status
         FROM kdjx_payment_orders payment
         JOIN users user ON user.id = payment.user_id
         ${clause}
         ORDER BY datetime(payment.created_at) DESC, payment.rowid DESC
         LIMIT ? OFFSET ?`,
        [...params, pageSize, (page - 1) * pageSize],
      ).map(paymentJson);
      return {
        generatedAt: new Date().toISOString(),
        page,
        pageSize,
        total,
        payments,
      };
    },
  );

  app.post(
    '/admin/games/kdjx/gm/players/:userId/revoke-sessions',
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      const audit = gmAudit(request, {
        action: 'revoke_sessions',
        targetType: 'player',
        targetId: auditTarget(request.params?.userId),
        reason: auditReason(request.body?.reason),
      });
      try {
        const userId = positiveId(request.params?.userId, 'user_id');
        const reason = requiredReason(request.body?.reason);
        const expectedActiveSessions = requiredNonNegativeInteger(
          request.body?.expectedActiveSessions,
          'expected_active_sessions',
        );
        audit.setContext({ targetId: String(userId), reason });
        requirePlayer(userId);
        const currentActiveSessions = activeSessionCount(userId);
        if (currentActiveSessions !== expectedActiveSessions) {
          throw routeError('kdjx_session_status_changed', 409);
        }
        const revokedSessions = revokeKdjxCredentials(userId);
        audit.success();
        return { ok: true, userId, revokedSessions, activeGameSessions: 0 };
      } catch (error) {
        audit.failed(error);
        throw error;
      }
    },
  );

  app.post(
    '/admin/games/kdjx/gm/payments/:gameOrderId/retry',
    { preHandler: app.adminRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      const audit = gmAudit(request, {
        action: 'retry_payment',
        targetType: 'payment',
        targetId: auditTarget(request.params?.gameOrderId),
        reason: auditReason(request.body?.reason),
      });
      try {
        const gameOrderId = cleanGameOrderId(request.params?.gameOrderId);
        const expectedStatus = optionalStatus(
          request.body?.expectedStatus,
          retryablePaymentStatuses,
          true,
        );
        const expectedAttempts = requiredNonNegativeInteger(
          request.body?.expectedAttempts,
          'expected_attempts',
        );
        const reason = requiredReason(request.body?.reason);
        audit.setContext({ targetId: gameOrderId, reason });
        releaseStaleKdjxPaymentClaims();
        const payment = one(
          `SELECT user_id, status, fulfillment_attempts
           FROM kdjx_payment_orders
           WHERE game_order_id = ?`,
          [gameOrderId],
        );
        if (!payment) throw routeError('payment_not_found', 404);
        if (!retryablePaymentStatuses.has(payment.status)) {
          throw routeError('kdjx_payment_not_retryable', 409);
        }
        if (payment.status !== expectedStatus) {
          throw routeError('kdjx_payment_status_changed', 409);
        }
        if (Number(payment.fulfillment_attempts) !== expectedAttempts) {
          throw routeError('kdjx_payment_version_changed', 409);
        }
        await retryPayment(Number(payment.user_id), gameOrderId, {
          status: expectedStatus,
          attempts: expectedAttempts,
        });
        const updated = paymentByGameOrderId(gameOrderId);
        if (!updated) throw routeError('payment_not_found', 404);
        const fulfilled = updated.status === 'fulfilled';
        if (fulfilled) audit.success();
        else audit.failedCode('kdjx_payment_delivery_failed');
        return { ok: fulfilled, payment: paymentJson(updated) };
      } catch (error) {
        audit.failed(error);
        throw error;
      }
    },
  );
}

function workbenchSummary() {
  const row = one(
    `SELECT
       (SELECT COUNT(*) FROM kdjx_game_account_links) AS linked_players,
       (SELECT COUNT(*) FROM kdjx_game_sessions
        WHERE revoked_at IS NULL
          AND datetime(expires_at) > datetime('now')) AS active_game_sessions,
       (SELECT COUNT(*) FROM kdjx_payment_orders) AS payment_orders,
       (SELECT COUNT(*) FROM kdjx_payment_orders
        WHERE status = 'delivery_failed') AS delivery_failed,
       (SELECT COUNT(*) FROM kdjx_payment_orders
        WHERE status = 'fulfilled') AS fulfilled,
       (SELECT COALESCE(SUM(coin_cost), 0) FROM kdjx_payment_orders)
         AS total_coin_spend`,
  ) || {};
  return {
    linkedPlayers: Number(row.linked_players || 0),
    activeGameSessions: Number(row.active_game_sessions || 0),
    paymentOrders: Number(row.payment_orders || 0),
    deliveryFailed: Number(row.delivery_failed || 0),
    fulfilled: Number(row.fulfilled || 0),
    totalCoinSpend: Number(row.total_coin_spend || 0),
  };
}

function recentGmActions() {
  return all(
    `SELECT log.id, log.admin_user_id, log.action, log.target_type,
            log.target_id, log.reason, log.result, log.error_code,
            log.created_at, user.email AS admin_email,
            user.nickname AS admin_nickname
     FROM kdjx_gm_action_logs log
     LEFT JOIN users user ON user.id = log.admin_user_id
     ORDER BY datetime(log.created_at) DESC, log.id DESC
     LIMIT 20`,
  ).map((row) => ({
    id: Number(row.id),
    adminUserId: row.admin_user_id === null
      ? null
      : Number(row.admin_user_id),
    adminEmail: row.admin_email || '',
    adminNickname: row.admin_nickname || '',
    action: row.action,
    targetType: row.target_type,
    targetId: row.target_id,
    reason: row.reason,
    result: row.result,
    errorCode: row.error_code || '',
    createdAt: row.created_at,
  }));
}

function playerFilters({ q, status }) {
  const clauses = [];
  const params = [];
  if (status) {
    clauses.push('user.status = ?');
    params.push(status);
  }
  if (q) {
    const value = `%${escapeLike(q.toLowerCase())}%`;
    clauses.push(`(
      CAST(user.id AS TEXT) LIKE ? ESCAPE '\\' OR
      LOWER(user.email) LIKE ? ESCAPE '\\' OR
      LOWER(user.nickname) LIKE ? ESCAPE '\\' OR
      LOWER(link.game_open_id) LIKE ? ESCAPE '\\' OR
      LOWER(link.game_account_id) LIKE ? ESCAPE '\\' OR
      LOWER(link.last_role_id) LIKE ? ESCAPE '\\' OR
      LOWER(link.last_server_key) LIKE ? ESCAPE '\\'
    )`);
    params.push(value, value, value, value, value, value, value);
  }
  return {
    clause: clauses.length ? `WHERE ${clauses.join(' AND ')}` : '',
    params,
  };
}

function paymentFilters({ q, status, userId }) {
  const clauses = [];
  const params = [];
  if (status) {
    clauses.push('payment.status = ?');
    params.push(status);
  }
  if (userId) {
    clauses.push('payment.user_id = ?');
    params.push(userId);
  }
  if (q) {
    const value = `%${escapeLike(q.toLowerCase())}%`;
    clauses.push(`(
      LOWER(payment.game_order_id) LIKE ? ESCAPE '\\' OR
      LOWER(payment.channel_order_id) LIKE ? ESCAPE '\\' OR
      LOWER(payment.game_open_id) LIKE ? ESCAPE '\\' OR
      LOWER(payment.account_id) LIKE ? ESCAPE '\\' OR
      LOWER(payment.role_id) LIKE ? ESCAPE '\\' OR
      LOWER(payment.product_name) LIKE ? ESCAPE '\\' OR
      LOWER(user.email) LIKE ? ESCAPE '\\' OR
      LOWER(user.nickname) LIKE ? ESCAPE '\\'
    )`);
    params.push(value, value, value, value, value, value, value, value);
  }
  return {
    clause: clauses.length ? `WHERE ${clauses.join(' AND ')}` : '',
    params,
  };
}

function playerJson(row) {
  return {
    userId: Number(row.user_id),
    email: row.email,
    nickname: row.nickname,
    userStatus: row.user_status,
    userRole: row.user_role,
    sakuraCoins: Number(row.sakura_coins || 0),
    userCreatedAt: row.user_created_at || '',
    lastLoginAt: row.last_login_at || '',
    gameOpenId: row.game_open_id,
    gameAccountId: row.game_account_id || '',
    lastRoleId: row.last_role_id || '',
    lastServerKey: row.last_server_key || '',
    linkedAt: row.linked_at || '',
    linkedUpdatedAt: row.linked_updated_at || '',
    activeGameSessions: Number(row.active_game_sessions || 0),
    paymentCount: Number(row.payment_count || 0),
    lastPaymentStatus: row.last_payment_status || '',
    lastPaymentAt: row.last_payment_at || '',
  };
}

function sessionJson(row) {
  const active = !row.revoked_at &&
    databaseTimeMs(row.expires_at) > Date.now();
  return {
    id: row.id,
    status: active ? 'active' : row.revoked_at ? 'revoked' : 'expired',
    expiresAt: row.expires_at,
    lastUsedAt: row.last_used_at || '',
    revokedAt: row.revoked_at || '',
    createdAt: row.created_at,
  };
}

function databaseTimeMs(value) {
  const text = String(value || '').trim();
  if (!text) return Number.NaN;
  const normalized = /[zZ]|[+-]\d\d:\d\d$/.test(text)
    ? text
    : `${text.replace(' ', 'T')}Z`;
  return Date.parse(normalized);
}

function paymentJson(row) {
  return {
    id: row.id,
    userId: Number(row.user_id),
    email: row.email || '',
    nickname: row.nickname || '',
    userStatus: row.user_status || '',
    gameOrderId: row.game_order_id,
    channelOrderId: row.channel_order_id,
    gameOpenId: row.game_open_id,
    accountId: row.account_id,
    roleId: row.role_id,
    serverKey: row.server_key,
    productId: row.product_id,
    productName: row.product_name,
    rechargeId: Number(row.recharge_id),
    moneyCents: Number(row.money_cents),
    coinCost: Number(row.coin_cost),
    status: row.status,
    attempts: Number(row.fulfillment_attempts || 0),
    fulfillmentReference: safeText(row.fulfillment_reference, 160),
    lastError: safeText(row.last_error, 240),
    canRetry: retryablePaymentStatuses.has(row.status),
    fulfilledAt: row.fulfilled_at || '',
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function requirePlayer(userId) {
  const player = one(
    'SELECT novel_user_id FROM kdjx_game_account_links WHERE novel_user_id = ?',
    [userId],
  );
  if (!player) throw routeError('kdjx_player_not_found', 404);
  return player;
}

function activeSessionCount(userId) {
  return Number(one(
    `SELECT COUNT(*) AS count
     FROM kdjx_game_sessions
     WHERE user_id = ? AND revoked_at IS NULL
       AND datetime(expires_at) > datetime('now')`,
    [userId],
  )?.count || 0);
}

function paymentByGameOrderId(gameOrderId) {
  return one(
    `SELECT payment.*, user.email, user.nickname,
            user.status AS user_status
     FROM kdjx_payment_orders payment
     JOIN users user ON user.id = payment.user_id
     WHERE payment.game_order_id = ?`,
    [gameOrderId],
  );
}

function gmAudit(request, {
  action,
  targetType,
  targetId,
  reason,
}) {
  const auditLogId = Number(run(
    `INSERT INTO kdjx_gm_action_logs
      (admin_user_id, action, target_type, target_id, reason, result)
     VALUES (?, ?, ?, ?, ?, 'pending')`,
    [
      Number(request.user.id),
      action,
      targetType,
      targetId,
      reason,
    ],
  ).lastInsertRowid);
  let finished = false;
  const finish = (result, errorCode = '') => {
    if (finished) return;
    try {
      const updated = run(
        `UPDATE kdjx_gm_action_logs
         SET result = ?, error_code = ?
         WHERE id = ? AND result = 'pending'`,
        [result, safeText(errorCode, 120), auditLogId],
      );
      finished = true;
      if ((updated.changes || 0) !== 1) {
        request.log.error(
          { auditLogId },
          'KDJX GM audit finalization did not update a pending row',
        );
      }
    } catch (error) {
      request.log.error(
        { err: error, auditLogId },
        'KDJX GM audit finalization failed',
      );
    }
  };
  return {
    setContext: ({ targetId: nextTargetId, reason: nextReason }) => {
      const updated = run(
        `UPDATE kdjx_gm_action_logs
         SET target_id = ?, reason = ?
         WHERE id = ? AND result = 'pending'`,
        [nextTargetId, nextReason, auditLogId],
      );
      if ((updated.changes || 0) !== 1) {
        throw routeError('kdjx_gm_audit_unavailable', 503);
      }
    },
    success: () => finish('success'),
    failed: (error) => finish('failed', publicErrorCode(error)),
    failedCode: (code) => finish('failed', code),
  };
}

function publicErrorCode(error) {
  return String(
    error?.publicCode ||
    error?.code ||
    (Number(error?.statusCode || 500) >= 500 ? 'internal_error' : '') ||
    'operation_failed',
  );
}

function optionalQuery(value) {
  const result = String(value || '').trim();
  if (result.length > 120) throw routeError('query_too_long', 400);
  return result;
}

function pageNumber(value) {
  const result = Number(value || 1);
  if (!Number.isSafeInteger(result) || result < 1 || result > 1_000_000) {
    throw routeError('page_invalid', 400);
  }
  return result;
}

function pageSizeNumber(value) {
  const result = Number(value || 20);
  if (!Number.isSafeInteger(result) || result < 1 || result > 100) {
    throw routeError('page_size_invalid', 400);
  }
  return result;
}

function optionalPositiveId(value, field) {
  if (value === undefined || value === null || value === '') return null;
  return positiveId(value, field);
}

function positiveId(value, field) {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result <= 0) {
    throw routeError(`${field}_invalid`, 400);
  }
  return result;
}

function requiredNonNegativeInteger(value, field) {
  const result = Number(value);
  if (
    value === undefined ||
    value === null ||
    value === '' ||
    !Number.isSafeInteger(result) ||
    result < 0
  ) {
    throw routeError(`${field}_invalid`, 400);
  }
  return result;
}

function optionalStatus(value, allowed, required = false) {
  const result = String(value || '').trim();
  if (!result && !required) return '';
  if (!allowed.has(result)) throw routeError('status_invalid', 400);
  return result;
}

function requiredReason(value) {
  const result = String(value || '').trim();
  if (result.length < 4 || result.length > 160) {
    throw routeError('reason_invalid', 400);
  }
  return result;
}

function auditReason(value) {
  return safeText(String(value || '').trim(), 160) || '(invalid reason)';
}

function auditTarget(value) {
  return safeText(String(value || '').trim(), 96) || '(invalid target)';
}

function cleanGameOrderId(value) {
  const result = String(value || '').trim();
  if (!result || result.length > 96 || !/^[A-Za-z0-9._:-]+$/.test(result)) {
    throw routeError('game_order_id_invalid', 400);
  }
  return result;
}

function safeText(value, maximumLength) {
  return String(value || '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .slice(0, maximumLength);
}

function escapeLike(value) {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}

function routeError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.publicCode = code;
  error.statusCode = statusCode;
  return error;
}
