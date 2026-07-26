import {
  horseRaceHistoryJson,
  horseRaceStateJson,
  placeHorseRaceBet,
} from "./horse-race.js";
import { optionalInt } from "./validators.js";
import {
  bailianSsoAvailable,
  consumeBailianTicket,
  issueBailianTicket,
  verifyBailianSharedSecret,
} from './bailian-sso.js';
import { enforceRateLimits } from './rate-limit.js';
import {
  bailianPaymentsAvailable, createBailianPayment, findBailianPayment,
  listBailianPayments,
  previewBailianPayment, retryBailianPayment,
} from './bailian-payments.js';
import { kdjxGameRoutes } from './routes-kdjx-game.js';
import { modaoGameRoutes } from './routes-modao-game.js';

export async function gameRoutes(app) {
  app.register(kdjxGameRoutes);
  app.register(modaoGameRoutes);

  const paymentHandler = (handler) => async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!bailianPaymentsAvailable()) return reply.code(503).send({ error: 'bailian_payments_unavailable' });
    try { return { ok: true, item: await handler(request) }; }
    catch (error) { return reply.code(error.statusCode || 500).send({ error: error.code || 'payment_failed' }); }
  };

  app.post('/games/bailian/payments/preview', { preHandler: app.authRequired }, paymentHandler(
    (request) => previewBailianPayment({ userId: request.user.id, ...request.body }),
  ));
  app.post('/games/bailian/payments', { preHandler: app.authRequired }, paymentHandler(
    (request) => createBailianPayment({
      userId: request.user.id, ...request.body,
      idempotencyKey: request.body?.idempotencyKey || request.headers['idempotency-key'],
    }),
  ));
  app.get('/games/bailian/payments', { preHandler: app.authRequired }, paymentHandler(
    (request) => listBailianPayments(request.user.id, request.query),
  ));
  app.get('/games/bailian/payments/:gameOrderId', { preHandler: app.authRequired }, paymentHandler(
    (request) => findBailianPayment(request.user.id, request.params.gameOrderId),
  ));
  app.post('/games/bailian/payments/:gameOrderId/retry', { preHandler: app.authRequired }, paymentHandler(
    (request) => retryBailianPayment(request.user.id, request.params.gameOrderId),
  ));
  app.post(
    '/games/bailian/sso-ticket',
    { preHandler: app.authRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      if (!bailianSsoAvailable()) {
        return reply.code(503).send({ error: 'bailian_sso_unavailable' });
      }
      const limited = enforceRateLimits(request, reply, [{
        scope: 'bailian_sso_issue_user',
        key: String(request.user.id),
        limit: 10,
        windowMs: 60_000,
        error: 'sso_rate_limited',
      }]);
      if (limited) return limited;
      return issueBailianTicket(request.user.id);
    },
  );

  app.post('/games/bailian/sso-ticket/consume', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!bailianSsoAvailable()) {
      return reply.code(503).send({ error: 'bailian_sso_unavailable' });
    }
    if (!verifyBailianSharedSecret(request.headers['x-bailian-sso-secret'])) {
      return reply.code(401).send({ error: 'unauthorized' });
    }
    const consumed = consumeBailianTicket(
      request.body?.ticket,
      request.body?.openId,
    );
    if (!consumed) {
      return reply.code(401).send({ error: 'invalid_or_expired_ticket' });
    }
    return {
      ok: true,
      userId: String(consumed.user_id),
      gameOpenId: consumed.game_open_id,
      expiresAt: consumed.expires_at,
    };
  });

  app.get(
    "/games/horse-race",
    { preHandler: app.authRequired },
    async (request) => ({ item: horseRaceStateJson(request.user.id) }),
  );

  app.post(
    "/games/horse-race/bets",
    { preHandler: app.authRequired },
    async (request) => {
      const state = placeHorseRaceBet({
        userId: request.user.id,
        horseIndex: optionalInt(request.body?.horseIndex, -1),
        amount: optionalInt(request.body?.amount, 0),
        requestId:
          request.body?.requestId || request.headers["idempotency-key"] || "",
      });
      if (typeof app.broadcastHorseRace === "function") {
        app.broadcastHorseRace();
      }
      return { ok: true, item: state };
    },
  );

  app.get(
    "/games/horse-race/history",
    { preHandler: app.authRequired },
    async (request) => ({
      items: horseRaceHistoryJson({
        userId: request.user.id,
        limit: optionalInt(request.query?.limit, 10),
      }),
    }),
  );
}
