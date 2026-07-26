import { enforceRateLimits } from './rate-limit.js';
import {
  createKdjxDeviceAuthorization,
  decideKdjxDeviceAuthorization,
  exchangeKdjxDeviceCode,
  kdjxDeviceAuthorizationAvailable,
} from './kdjx-device-auth.js';
import {
  createKdjxPayment,
  findKdjxPayment,
  kdjxPaymentsAvailable,
  previewKdjxPayment,
  retryKdjxPayment,
} from './kdjx-payments.js';
import { ensureKdjxGameSchema } from './kdjx-schema.js';
import {
  revokeKdjxCredentials,
  verifyKdjxCredential,
  verifyKdjxSharedSecret,
} from './kdjx-sso.js';

export async function kdjxGameRoutes(app) {
  ensureKdjxGameSchema();

  const paymentHandler = (handler) => async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!kdjxPaymentsAvailable()) {
      return reply.code(503).send({ error: 'kdjx_payments_unavailable' });
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
    '/games/kdjx/payments/preview',
    { preHandler: app.authRequired },
    paymentHandler((request) => previewKdjxPayment({
      userId: request.user.id,
      ...request.body,
    })),
  );
  app.post(
    '/games/kdjx/payments',
    { preHandler: app.authRequired },
    paymentHandler((request) => createKdjxPayment({
      userId: request.user.id,
      ...request.body,
      idempotencyKey:
        request.body?.idempotencyKey || request.headers['idempotency-key'],
    })),
  );
  app.get(
    '/games/kdjx/payments/:gameOrderId',
    { preHandler: app.authRequired },
    paymentHandler((request) => findKdjxPayment(
      request.user.id,
      request.params.gameOrderId,
    )),
  );
  app.post(
    '/games/kdjx/payments/:gameOrderId/retry',
    { preHandler: app.authRequired },
    paymentHandler((request) => retryKdjxPayment(
      request.user.id,
      request.params.gameOrderId,
    )),
  );

  app.post('/games/kdjx/device-authorizations', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!kdjxDeviceAuthorizationAvailable()) {
      return reply
        .code(503)
        .send({ error: 'kdjx_device_authorization_unavailable' });
    }
    const limited = enforceRateLimits(request, reply, [{
      scope: 'kdjx_device_authorization_create_ip',
      key: request.ip,
      limit: 10,
      windowMs: 60_000,
      error: 'device_authorization_rate_limited',
    }]);
    if (limited) return limited;
    try {
      return createKdjxDeviceAuthorization();
    } catch (error) {
      return reply
        .code(error.statusCode || 500)
        .send({ error: error.code || 'device_authorization_failed' });
    }
  });

  const deviceDecisionHandler = (approve) => async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!kdjxDeviceAuthorizationAvailable()) {
      return reply
        .code(503)
        .send({ error: 'kdjx_device_authorization_unavailable' });
    }
    const limited = enforceRateLimits(request, reply, [
      {
        scope: 'kdjx_device_authorization_decide_user',
        key: String(request.user.id),
        limit: 10,
        windowMs: 60_000,
        error: 'device_authorization_rate_limited',
      },
      {
        scope: 'kdjx_device_authorization_decide_ip',
        key: request.ip,
        limit: 20,
        windowMs: 60_000,
        error: 'device_authorization_rate_limited',
      },
    ]);
    if (limited) return limited;
    try {
      const result = decideKdjxDeviceAuthorization({
        userId: request.user.id,
        deviceCode: request.body?.deviceCode,
        userCode: request.body?.userCode,
        approve,
      });
      return { ok: true, ...result };
    } catch (error) {
      return reply
        .code(error.statusCode || 500)
        .send({ error: error.code || 'device_authorization_failed' });
    }
  };

  app.post(
    '/games/kdjx/device-authorizations/approve',
    { preHandler: app.authRequired },
    deviceDecisionHandler(true),
  );
  app.post(
    '/games/kdjx/device-authorizations/deny',
    { preHandler: app.authRequired },
    deviceDecisionHandler(false),
  );

  app.post('/games/kdjx/device-authorizations/token', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!kdjxDeviceAuthorizationAvailable()) {
      return reply
        .code(503)
        .send({ error: 'kdjx_device_authorization_unavailable' });
    }
    const limited = enforceRateLimits(request, reply, [{
      scope: 'kdjx_device_authorization_poll_ip',
      key: request.ip,
      limit: 120,
      windowMs: 60_000,
      error: 'device_authorization_rate_limited',
    }]);
    if (limited) return limited;
    try {
      const result = exchangeKdjxDeviceCode(request.body?.deviceCode);
      if (result.status === 'pending') {
        reply.header('Retry-After', String(result.retryAfter));
        return reply.code(202).send({
          status: 'pending',
          error: 'authorization_pending',
          retryAfter: result.retryAfter,
        });
      }
      return {
        ok: true,
        status: result.status,
        tokenType: 'Bearer',
        credential: result.credential,
        credentialExpiresAt: result.credentialExpiresAt,
        credentialExpiresIn: result.credentialExpiresIn,
        gameOpenId: result.gameOpenId,
      };
    } catch (error) {
      if (error.retryAfter) {
        reply.header('Retry-After', String(error.retryAfter));
      }
      return reply
        .code(error.statusCode || 500)
        .send({
          error: error.code || 'device_authorization_failed',
          ...(error.retryAfter ? { retryAfter: error.retryAfter } : {}),
        });
    }
  });

  app.post('/games/kdjx/sessions/verify', async (request, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!verifyKdjxSharedSecret(request.headers['x-kdjx-sso-secret'])) {
      return reply.code(401).send({ error: 'unauthorized' });
    }
    const identity = verifyKdjxCredential(request.body?.credential);
    if (!identity) {
      return reply.code(401).send({ error: 'invalid_or_expired_credential' });
    }
    return internalIdentityJson(identity);
  });

  app.post(
    '/games/kdjx/sessions/revoke',
    { preHandler: app.authRequired },
    async (request, reply) => {
      reply.header('Cache-Control', 'no-store');
      try {
        const hasCredential = Object.hasOwn(request.body || {}, 'credential');
        const revoked = revokeKdjxCredentials(
          request.user.id,
          hasCredential ? request.body.credential : undefined,
        );
        return { ok: true, revoked };
      } catch (error) {
        return reply
          .code(error.statusCode || 500)
          .send({ error: error.code || 'session_revoke_failed' });
      }
    },
  );
}

function internalIdentityJson(identity) {
  return {
    ok: true,
    userId: String(identity.userId),
    gameOpenId: identity.gameOpenId,
    accountName: identity.accountName,
    accountPassword: identity.accountPassword,
    channel: identity.channel,
    nickname: identity.nickname,
    avatarUrl: identity.avatarUrl,
    credentialExpiresAt: identity.credentialExpiresAt,
  };
}
