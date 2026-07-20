import { enforceRateLimits } from './rate-limit.js';
import {
  applySsoWalletChange,
  authenticateSsoClient,
  createSsoAuthorizationCode,
  exchangeSsoAuthorizationCode,
  exchangeSsoRefreshToken,
  findSsoPrincipal,
  listSsoWalletChanges,
  listSsoWalletTransactions,
  revokeSsoToken,
  ssoUserInfo,
  ssoWalletBalance,
} from './sso.js';

export async function ssoRoutes(app) {
  app.post(
    '/sso/authorize',
    { preHandler: app.authRequired },
    async (request, reply) => {
      noStore(reply);
      const body = request.body || {};
      const rawClientId = body.client_id || body.clientId || '';
      const normalizedRateClientId = String(rawClientId)
        .trim()
        .toLowerCase()
        .slice(0, 80);
      const limited = enforceRateLimits(request, reply, [
        rateRule(
          'sso_authorize_user',
          request.user.id,
          60,
          5 * 60 * 1000,
        ),
        rateRule(
          'sso_authorize_user',
          `${request.user.id}:${normalizedRateClientId}`,
          20,
          5 * 60 * 1000,
        ),
      ]);
      if (limited) return limited;

      const method = String(
        body.code_challenge_method || body.codeChallengeMethod || '',
      ).trim();
      if (method !== 'S256') {
        return reply.code(400).send({ error: 'invalid_code_challenge_method' });
      }
      const state = String(body.state || '').trim();
      if (state.length < 16 || state.length > 256) {
        return reply.code(400).send({ error: 'state_invalid' });
      }
      const authorization = createSsoAuthorizationCode({
        userId: request.user.id,
        clientId: rawClientId,
        scope: body.scope,
        codeChallenge: body.code_challenge || body.codeChallenge,
        redirectUri: body.redirect_uri || body.redirectUri,
      });
      noStore(reply);
      return {
        code: authorization.code,
        expires_in: authorization.expiresIn,
        scope: authorization.scope,
        state,
        redirect_uri: authorization.redirectUri,
        client: {
          client_id: authorization.client.clientId,
          name: authorization.client.name,
        },
      };
    },
  );

  app.post('/sso/token', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(
      request,
      reply,
      'sso_token_ip',
      6000,
      5 * 60 * 1000,
    );
    if (ipLimited) return ipLimited;
    const client = clientFromBasicAuthorization(request);
    const limited = enforceRateLimits(request, reply, [
      client
        ? rateRule('sso_token_client', client.clientId, 6000, 5 * 60 * 1000)
        : rateRule('sso_token_invalid_ip', request.ip, 30, 5 * 60 * 1000),
    ]);
    if (limited) return limited;
    if (!client) return invalidClient(reply);
    const body = request.body || {};
    const grantType = String(body.grant_type || body.grantType || '');
    let exchanged;
    if (grantType === 'authorization_code') {
      exchanged = exchangeSsoAuthorizationCode({
        client,
        code: body.code,
        codeVerifier: body.code_verifier || body.codeVerifier,
        redirectUri: body.redirect_uri || body.redirectUri,
      });
    } else if (grantType === 'refresh_token') {
      exchanged = exchangeSsoRefreshToken({
        client,
        refreshToken: body.refresh_token || body.refreshToken,
      });
    } else {
      return reply.code(400).send({ error: 'unsupported_grant_type' });
    }
    noStore(reply);
    return {
      access_token: exchanged.accessToken,
      refresh_token: exchanged.refreshToken,
      token_type: exchanged.tokenType,
      expires_in: exchanged.expiresIn,
      refresh_expires_in: exchanged.refreshExpiresIn,
      scope: exchanged.scope,
      user: exchanged.user,
    };
  });

  app.get('/sso/userinfo', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(request, reply, 'sso_userinfo_ip');
    if (ipLimited) return ipLimited;
    const principal = principalFromBearer(request);
    const limited = enforceRateLimits(request, reply, [
      principal
        ? rateRule(
            'sso_userinfo_subject',
            `${principal.clientId}:${principal.user.id}`,
            300,
            60 * 1000,
          )
        : rateRule('sso_userinfo_invalid_ip', request.ip, 60, 60 * 1000),
    ]);
    if (limited) return limited;
    if (!principal) return invalidToken(reply);
    noStore(reply);
    return { user: ssoUserInfo(principal) };
  });

  app.get('/sso/wallet', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(request, reply, 'sso_wallet_read_ip');
    if (ipLimited) return ipLimited;
    const principal = principalFromBearer(request);
    const limited = enforceRateLimits(request, reply, [
      principal
        ? rateRule(
            'sso_wallet_read_subject',
            `${principal.clientId}:${principal.user.id}`,
            600,
            60 * 1000,
          )
        : rateRule('sso_wallet_read_invalid_ip', request.ip, 60, 60 * 1000),
    ]);
    if (limited) return limited;
    if (!principal) return invalidToken(reply);
    noStore(reply);
    return { wallet: ssoWalletBalance(principal) };
  });

  app.get('/sso/wallet/transactions', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(request, reply, 'sso_wallet_history_ip');
    if (ipLimited) return ipLimited;
    const principal = principalFromBearer(request);
    const limited = enforceRateLimits(request, reply, [
      principal
        ? rateRule(
            'sso_wallet_history_subject',
            `${principal.clientId}:${principal.user.id}`,
            300,
            60 * 1000,
          )
        : rateRule('sso_wallet_history_invalid_ip', request.ip, 60, 60 * 1000),
    ]);
    if (limited) return limited;
    if (!principal) return invalidToken(reply);
    const query = request.query || {};
    noStore(reply);
    return listSsoWalletTransactions(principal, {
      limit: query.limit,
      beforeId: query.before_id || query.beforeId,
    });
  });

  app.get('/sso/wallet/changes', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(request, reply, 'sso_wallet_changes_ip');
    if (ipLimited) return ipLimited;
    const principal = principalFromBearer(request);
    const limited = enforceRateLimits(request, reply, [
      principal
        ? rateRule(
            'sso_wallet_changes_subject',
            `${principal.clientId}:${principal.user.id}`,
            300,
            60 * 1000,
          )
        : rateRule('sso_wallet_changes_invalid_ip', request.ip, 60, 60 * 1000),
    ]);
    if (limited) return limited;
    if (!principal) return invalidToken(reply);
    const query = request.query || {};
    noStore(reply);
    return listSsoWalletChanges(principal, {
      limit: query.limit,
      afterId: query.after_id || query.afterId,
    });
  });

  app.post('/sso/wallet/transactions', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(
      request,
      reply,
      'sso_wallet_write_ip',
      6000,
    );
    if (ipLimited) return ipLimited;
    const client = clientFromBasicAuthorization(request);
    const limited = enforceRateLimits(request, reply, [
      client
        ? rateRule('sso_wallet_write_client', client.clientId, 6000, 60 * 1000)
        : rateRule('sso_wallet_write_invalid_ip', request.ip, 30, 60 * 1000),
    ]);
    if (limited) return limited;
    if (!client) return invalidClient(reply);
    const body = request.body || {};
    const result = applySsoWalletChange({
      client,
      accessToken: request.headers['x-sakura-user-token'],
      idempotencyKey: request.headers['idempotency-key'],
      delta: body.delta,
      reason: body.reason,
      referenceId: body.reference_id || body.referenceId,
      metadata: body.metadata,
    });
    noStore(reply);
    return result;
  });

  app.post('/sso/revoke', async (request, reply) => {
    noStore(reply);
    const ipLimited = preAuthRateLimit(
      request,
      reply,
      'sso_revoke_ip',
      6000,
      5 * 60 * 1000,
    );
    if (ipLimited) return ipLimited;
    const client = clientFromBasicAuthorization(request);
    const limited = enforceRateLimits(request, reply, [
      client
        ? rateRule('sso_revoke_client', client.clientId, 6000, 5 * 60 * 1000)
        : rateRule('sso_revoke_invalid_ip', request.ip, 30, 5 * 60 * 1000),
    ]);
    if (limited) return limited;
    if (!client) return invalidClient(reply);
    const body = request.body || {};
    revokeSsoToken(client, body.token || body.access_token || body.accessToken);
    noStore(reply);
    return { ok: true };
  });
}

function clientFromBasicAuthorization(request) {
  const header = String(request.headers.authorization || '');
  const match = /^Basic\s+([^\s]+)$/i.exec(header);
  if (!match) return null;
  let decoded;
  try {
    decoded = Buffer.from(match[1], 'base64').toString('utf8');
  } catch {
    return null;
  }
  const separator = decoded.indexOf(':');
  if (separator <= 0) return null;
  return authenticateSsoClient(
    decoded.slice(0, separator),
    decoded.slice(separator + 1),
  );
}

function principalFromBearer(request) {
  const header = String(request.headers.authorization || '');
  const match = /^Bearer\s+([^\s]+)$/i.exec(header);
  return match ? findSsoPrincipal(match[1]) : null;
}

function invalidClient(reply) {
  noStore(reply);
  reply.header('WWW-Authenticate', 'Basic realm="sakura-sso"');
  return reply.code(401).send({ error: 'invalid_client' });
}

function invalidToken(reply) {
  noStore(reply);
  reply.header('WWW-Authenticate', 'Bearer error="invalid_token"');
  return reply.code(401).send({ error: 'invalid_token' });
}

function noStore(reply) {
  reply.header('Cache-Control', 'no-store');
  reply.header('Pragma', 'no-cache');
}

function preAuthRateLimit(
  request,
  reply,
  scope,
  limit = 1200,
  windowMs = 60 * 1000,
) {
  return enforceRateLimits(request, reply, [
    rateRule(scope, request.ip, limit, windowMs),
  ]);
}

function rateRule(scope, key, limit, windowMs) {
  return {
    scope,
    key: key || 'unknown',
    limit,
    windowMs,
    error: 'sso_rate_limited',
  };
}
