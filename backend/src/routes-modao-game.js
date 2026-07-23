import { enforceRateLimits } from './rate-limit.js';
import {
  createModaoPayment,
  findModaoPayment,
  modaoPaymentsAvailable,
  previewModaoPayment,
  retryModaoPayment,
} from './modao-payments.js';
import { ensureModaoGameSchema } from './modao-schema.js';
import {
  consumeModaoTicket,
  issueModaoTicket,
  modaoSsoAvailable,
  verifyModaoSharedSecret,
} from './modao-sso.js';

export async function modaoGameRoutes(app) {
  ensureModaoGameSchema();

  const paymentHandler = (handler) => async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!modaoPaymentsAvailable()) {
      return reply.code(503).send({ error: 'modao_payments_unavailable' });
    }
    try {
      return { ok: true, item: await handler(request) };
    } catch (error) {
      return reply
        .code(error.statusCode || 500)
        .send({ error: error.code || 'payment_failed' });
    }
  };

  app.post(
    '/games/modao/payments/preview',
    { preHandler: app.authRequired },
    paymentHandler((request) => previewModaoPayment({
      userId: request.user.id,
      ...request.body,
    })),
  );
  app.post(
    '/games/modao/payments',
    { preHandler: app.authRequired },
    paymentHandler((request) => createModaoPayment({
      userId: request.user.id,
      ...request.body,
      idempotencyKey:
        request.body?.idempotencyKey || request.headers['idempotency-key'],
    })),
  );
  app.get(
    '/games/modao/payments/:gameOrderId',
    { preHandler: app.authRequired },
    paymentHandler((request) => findModaoPayment(
      request.user.id,
      request.params.gameOrderId,
    )),
  );
  app.post(
    '/games/modao/payments/:gameOrderId/retry',
    { preHandler: app.authRequired },
    paymentHandler((request) => retryModaoPayment(
      request.user.id,
      request.params.gameOrderId,
    )),
  );

  app.post(
    '/games/modao/sso-ticket',
    { preHandler: app.authRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      if (!modaoSsoAvailable()) {
        return reply.code(503).send({ error: 'modao_sso_unavailable' });
      }
      const limited = enforceRateLimits(request, reply, [{
        scope: 'modao_sso_issue_user',
        key: String(request.user.id),
        limit: 10,
        windowMs: 60_000,
        error: 'sso_rate_limited',
      }]);
      if (limited) return limited;
      return issueModaoTicket(request.user.id);
    },
  );

  app.post('/games/modao/sso-ticket/consume', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!modaoSsoAvailable()) {
      return reply.code(503).send({ error: 'modao_sso_unavailable' });
    }
    if (!verifyModaoSharedSecret(request.headers['x-modao-sso-secret'])) {
      return reply.code(401).send({ error: 'unauthorized' });
    }
    const consumed = consumeModaoTicket(request.body?.ticket);
    if (!consumed) {
      return reply.code(401).send({ error: 'invalid_or_expired_ticket' });
    }
    return {
      ok: true,
      userId: String(consumed.user_id),
      gameOpenId: consumed.game_open_id,
      nickname: consumed.nickname,
      avatarUrl: consumed.avatar_url,
      expiresAt: consumed.expires_at,
    };
  });
}
