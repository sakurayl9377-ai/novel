import crypto from 'node:crypto';

import { config } from './config.js';
import { all, db, one, run } from './db.js';
import { randomToken, safeEqual } from './security.js';

export const supportedSsoScopes = Object.freeze([
  'profile:read',
  'wallet:read',
  'wallet:debit',
  'wallet:credit',
]);

export const defaultSsoClientScopes = Object.freeze([
  'profile:read',
  'wallet:read',
]);

export const defaultSsoAuthorizationScopes = Object.freeze([
  'profile:read',
  'wallet:read',
]);

const authorizationCodeTtlSeconds = 120;
const accessTokenTtlSeconds = 60 * 60;
const refreshTokenTtlSeconds = 30 * 24 * 60 * 60;
const maxWalletDelta = 1_000_000;
const clientIdPattern = /^[a-z0-9][a-z0-9._-]{2,63}$/;
const pkceChallengePattern = /^[A-Za-z0-9_-]{43}$/;
const pkceVerifierPattern = /^[A-Za-z0-9._~-]{43,128}$/;
const idempotencyKeyPattern = /^[A-Za-z0-9._:-]{8,128}$/;

export function createSsoClient({
  clientId,
  name,
  scopes,
  redirectUris,
  maxDebitPerTransaction = 0,
  dailyDebitLimit = 0,
  maxCreditPerTransaction = 0,
  dailyCreditLimit = 0,
} = {}) {
  const normalizedId = normalizeClientId(clientId);
  const normalizedName = requiredText(name, 'client_name', 80);
  const normalizedScopes = normalizeClientScopes(scopes);
  const normalizedRedirectUris = normalizeRedirectUris(redirectUris);
  const limits = normalizeClientLimits({
    maxDebitPerTransaction,
    dailyDebitLimit,
    maxCreditPerTransaction,
    dailyCreditLimit,
  });
  if (
    normalizedScopes.includes('wallet:debit') &&
    (limits.maxDebitPerTransaction === 0 || limits.dailyDebitLimit === 0)
  ) {
    throw ssoError(400, 'sso_debit_limit_required');
  }
  if (
    normalizedScopes.includes('wallet:credit') &&
    (limits.maxCreditPerTransaction === 0 || limits.dailyCreditLimit === 0)
  ) {
    throw ssoError(400, 'sso_credit_limit_required');
  }
  const clientSecret = randomToken();

  try {
    run(
      `INSERT INTO sso_clients
       (client_id, name, secret_hash, scopes, redirect_uris,
        max_debit_per_transaction, daily_debit_limit,
        max_credit_per_transaction, daily_credit_limit, status)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')`,
      [
        normalizedId,
        normalizedName,
        clientSecretHash(clientSecret),
        normalizedScopes.join(' '),
        JSON.stringify(normalizedRedirectUris),
        limits.maxDebitPerTransaction,
        limits.dailyDebitLimit,
        limits.maxCreditPerTransaction,
        limits.dailyCreditLimit,
      ],
    );
  } catch (error) {
    if (String(error?.message || '').includes('UNIQUE constraint failed')) {
      throw ssoError(409, 'sso_client_exists');
    }
    throw error;
  }

  return {
    client: serializeClient(
      one('SELECT * FROM sso_clients WHERE client_id = ?', [normalizedId]),
    ),
    clientSecret,
  };
}

export function rotateSsoClientSecret(clientId) {
  const normalizedId = normalizeClientId(clientId);
  const client = one('SELECT * FROM sso_clients WHERE client_id = ?', [
    normalizedId,
  ]);
  if (!client) throw ssoError(404, 'sso_client_not_found');

  const clientSecret = randomToken();
  withImmediateTransaction(() => {
    run(
      `UPDATE sso_clients
       SET secret_hash = ?, updated_at = datetime('now')
       WHERE client_id = ?`,
      [clientSecretHash(clientSecret), normalizedId],
    );
    revokeClientCredentials(normalizedId);
  });

  return {
    client: serializeClient(
      one('SELECT * FROM sso_clients WHERE client_id = ?', [normalizedId]),
    ),
    clientSecret,
  };
}

export function setSsoClientStatus(clientId, status) {
  const normalizedId = normalizeClientId(clientId);
  const normalizedStatus = String(status || '').trim().toLowerCase();
  if (!['active', 'disabled'].includes(normalizedStatus)) {
    throw ssoError(400, 'sso_client_status_invalid');
  }

  const result = withImmediateTransaction(() => {
    const update = run(
      `UPDATE sso_clients
       SET status = ?, updated_at = datetime('now')
       WHERE client_id = ?`,
      [normalizedStatus, normalizedId],
    );
    if (Number(update.changes || 0) !== 1) {
      throw ssoError(404, 'sso_client_not_found');
    }
    if (normalizedStatus === 'disabled') revokeClientCredentials(normalizedId);
    return one('SELECT * FROM sso_clients WHERE client_id = ?', [normalizedId]);
  });
  return serializeClient(result);
}

export function updateSsoClient(clientId, changes = {}) {
  const normalizedId = normalizeClientId(clientId);
  const existing = one('SELECT * FROM sso_clients WHERE client_id = ?', [
    normalizedId,
  ]);
  if (!existing) throw ssoError(404, 'sso_client_not_found');
  const current = serializeClient(existing);
  const name =
    changes.name == null
      ? current.name
      : requiredText(changes.name, 'client_name', 80);
  const scopes =
    changes.scopes == null
      ? current.scopes
      : normalizeClientScopes(changes.scopes);
  const redirectUris =
    changes.redirectUris == null
      ? current.redirectUris
      : normalizeRedirectUris(changes.redirectUris);
  const limits = normalizeClientLimits({
    maxDebitPerTransaction:
      changes.maxDebitPerTransaction ?? current.limits.maxDebitPerTransaction,
    dailyDebitLimit:
      changes.dailyDebitLimit ?? current.limits.dailyDebitLimit,
    maxCreditPerTransaction:
      changes.maxCreditPerTransaction ?? current.limits.maxCreditPerTransaction,
    dailyCreditLimit:
      changes.dailyCreditLimit ?? current.limits.dailyCreditLimit,
  });
  if (
    scopes.includes('wallet:debit') &&
    (limits.maxDebitPerTransaction === 0 || limits.dailyDebitLimit === 0)
  ) {
    throw ssoError(400, 'sso_debit_limit_required');
  }
  if (
    scopes.includes('wallet:credit') &&
    (limits.maxCreditPerTransaction === 0 || limits.dailyCreditLimit === 0)
  ) {
    throw ssoError(400, 'sso_credit_limit_required');
  }

  return serializeClient(
    withImmediateTransaction(() => {
      run(
        `UPDATE sso_clients
         SET name = ?, scopes = ?, redirect_uris = ?,
             max_debit_per_transaction = ?, daily_debit_limit = ?,
             max_credit_per_transaction = ?, daily_credit_limit = ?,
             updated_at = datetime('now')
         WHERE client_id = ?`,
        [
          name,
          scopes.join(' '),
          JSON.stringify(redirectUris),
          limits.maxDebitPerTransaction,
          limits.dailyDebitLimit,
          limits.maxCreditPerTransaction,
          limits.dailyCreditLimit,
          normalizedId,
        ],
      );
      revokeClientCredentials(normalizedId);
      return one('SELECT * FROM sso_clients WHERE client_id = ?', [
        normalizedId,
      ]);
    }),
  );
}

export function listSsoClients() {
  return all(
    `SELECT * FROM sso_clients
     ORDER BY created_at ASC, client_id ASC`,
  ).map(serializeClient);
}

export function authenticateSsoClient(clientId, clientSecret) {
  let normalizedId;
  try {
    normalizedId = normalizeClientId(clientId);
  } catch {
    return null;
  }
  const secret = String(clientSecret || '');
  if (!secret) return null;

  const row = one(
    `SELECT * FROM sso_clients
     WHERE client_id = ? AND status = 'active'`,
    [normalizedId],
  );
  if (
    !row ||
    !safeEqual(
      clientSecretHash(secret),
      String(row.secret_hash || ''),
    )
  ) {
    return null;
  }
  return clientPrincipal(row);
}

export function createSsoAuthorizationCode({
  userId,
  clientId,
  scope,
  codeChallenge,
  redirectUri,
} = {}) {
  const normalizedId = normalizeClientId(clientId);
  const challenge = String(codeChallenge || '').trim();
  if (!pkceChallengePattern.test(challenge)) {
    throw ssoError(400, 'invalid_code_challenge');
  }

  const clientRow = one(
    `SELECT * FROM sso_clients
     WHERE client_id = ? AND status = 'active'`,
    [normalizedId],
  );
  if (!clientRow) throw ssoError(400, 'invalid_client');

  const user = one('SELECT * FROM users WHERE id = ? AND status = ?', [
    Number(userId),
    'active',
  ]);
  if (!user) throw ssoError(403, 'account_not_active');

  const client = clientPrincipal(clientRow);
  const normalizedRedirectUri = resolveRedirectUri(redirectUri, client);
  const authorizedScopes = resolveRequestedScopes(scope, client.scopes);
  const code = randomToken();
  const expiresAt = secondsFromNow(authorizationCodeTtlSeconds);

  withImmediateTransaction(() => {
    ensureSsoUserLink(normalizedId, user.id);
    run(
      `DELETE FROM sso_authorization_codes
       WHERE client_id = ? AND user_id = ?
         AND (used_at IS NOT NULL OR datetime(expires_at) <= datetime('now'))`,
      [normalizedId, user.id],
    );
    run(
      `INSERT INTO sso_authorization_codes
       (code_hash, client_id, user_id, scopes, code_challenge, redirect_uri,
        expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        credentialHash('authorization-code', code),
        normalizedId,
        user.id,
        authorizedScopes.join(' '),
        challenge,
        normalizedRedirectUri,
        expiresAt,
      ],
    );
  });

  return {
    code,
    expiresIn: authorizationCodeTtlSeconds,
    client: {
      clientId: client.clientId,
      name: client.name,
    },
    scope: authorizedScopes.join(' '),
    redirectUri: normalizedRedirectUri,
  };
}

export function exchangeSsoAuthorizationCode({
  client,
  code,
  codeVerifier,
  redirectUri,
} = {}) {
  if (!client?.clientId) throw ssoError(401, 'invalid_client');
  const rawCode = String(code || '').trim();
  const verifier = String(codeVerifier || '').trim();
  let normalizedRedirectUri;
  try {
    normalizedRedirectUri = normalizeRedirectUri(redirectUri);
  } catch {
    throw ssoError(400, 'invalid_grant');
  }
  if (!rawCode || !pkceVerifierPattern.test(verifier)) {
    throw ssoError(400, 'invalid_grant');
  }

  return withImmediateTransaction(() => {
    const row = one(
      `SELECT authorization.*, user.*
       FROM sso_authorization_codes authorization
       JOIN users user ON user.id = authorization.user_id
       WHERE authorization.code_hash = ?
         AND authorization.client_id = ?
         AND authorization.used_at IS NULL
         AND datetime(authorization.expires_at) > datetime('now')`,
      [
        credentialHash('authorization-code', rawCode),
        client.clientId,
      ],
    );
    if (
      !row ||
      row.status !== 'active' ||
      row.redirect_uri !== normalizedRedirectUri ||
      !safeEqual(pkceChallenge(verifier), row.code_challenge)
    ) {
      throw ssoError(400, 'invalid_grant');
    }

    const consumed = run(
      `UPDATE sso_authorization_codes
       SET used_at = datetime('now')
       WHERE code_hash = ? AND used_at IS NULL`,
      [credentialHash('authorization-code', rawCode)],
    );
    if (Number(consumed.changes || 0) !== 1) {
      throw ssoError(400, 'invalid_grant');
    }

    ensureSsoUserLink(client.clientId, row.user_id, true);
    return issueSsoTokenPair({
      clientId: client.clientId,
      user: row,
      scopeText: row.scopes,
    });
  });
}

export function exchangeSsoRefreshToken({ client, refreshToken } = {}) {
  if (!client?.clientId) throw ssoError(401, 'invalid_client');
  const rawToken = String(refreshToken || '').trim();
  if (!rawToken) throw ssoError(400, 'invalid_grant');
  const tokenHash = credentialHash('refresh-token', rawToken);

  const outcome = withImmediateTransaction(() => {
    const row = one(
      `SELECT refresh.*, user.*,
              refresh.client_id AS sso_client_id,
              refresh.scopes AS sso_scopes,
              refresh.user_id AS sso_user_id,
              refresh.revoked_at AS refresh_revoked_at,
              refresh.expires_at AS refresh_expires_at
       FROM sso_refresh_tokens refresh
       JOIN sso_clients client ON client.client_id = refresh.client_id
       JOIN users user ON user.id = refresh.user_id
       WHERE refresh.token_hash = ? AND refresh.client_id = ?
         AND client.status = 'active' AND user.status = 'active'`,
      [tokenHash, client.clientId],
    );
    if (!row) return { error: 'invalid_grant' };
    if (row.refresh_revoked_at) {
      revokeSsoTokenFamily(
        row.sso_client_id,
        row.sso_user_id,
        row.family_id,
      );
      return { error: 'invalid_grant' };
    }
    if (Date.parse(row.refresh_expires_at) <= Date.now()) {
      run(
        `UPDATE sso_refresh_tokens
         SET revoked_at = datetime('now')
         WHERE token_hash = ? AND revoked_at IS NULL`,
        [tokenHash],
      );
      return { error: 'invalid_grant' };
    }

    const replacement = issueSsoTokenPair({
      clientId: client.clientId,
      user: row,
      scopeText: row.sso_scopes,
      familyId: row.family_id,
      refreshExpiresAt: row.refresh_expires_at,
    });
    run(
      `UPDATE sso_refresh_tokens
       SET revoked_at = datetime('now'), replaced_by_hash = ?
       WHERE token_hash = ? AND revoked_at IS NULL`,
      [
        credentialHash('refresh-token', replacement.refreshToken),
        tokenHash,
      ],
    );
    return replacement;
  });
  if (outcome.error) throw ssoError(400, outcome.error);
  return outcome;
}

export function findSsoPrincipal(accessToken, requiredScope = '') {
  const token = String(accessToken || '').trim();
  if (!token) return null;

  const row = one(
    `SELECT token.client_id AS sso_client_id,
            token.scopes AS sso_scopes,
            user.*
     FROM sso_access_tokens token
     JOIN sso_clients client ON client.client_id = token.client_id
     JOIN users user ON user.id = token.user_id
     WHERE token.token_hash = ?
       AND token.revoked_at IS NULL
       AND datetime(token.expires_at) > datetime('now')
       AND client.status = 'active'
       AND user.status = 'active'`,
    [credentialHash('access-token', token)],
  );
  if (!row) return null;

  const principal = {
    clientId: row.sso_client_id,
    scopes: new Set(parseScopeText(row.sso_scopes)),
    user: row,
  };
  if (requiredScope && !principal.scopes.has(requiredScope)) return null;
  return principal;
}

export function ssoUserInfo(principal) {
  if (!principal?.user || !principal?.clientId) {
    throw ssoError(401, 'invalid_token');
  }
  requirePrincipalScope(principal, 'profile:read');
  return serializeSsoUser(
    principal.user,
    principal.clientId,
    principal.scopes,
  );
}

export function revokeSsoToken(client, tokenValue) {
  if (!client?.clientId) throw ssoError(401, 'invalid_client');
  const token = String(tokenValue || '').trim();
  if (!token) return;
  withImmediateTransaction(() => {
    const credential =
      one(
        `SELECT family_id, user_id
         FROM sso_access_tokens
         WHERE token_hash = ? AND client_id = ?`,
        [credentialHash('access-token', token), client.clientId],
      ) ||
      one(
        `SELECT family_id, user_id
         FROM sso_refresh_tokens
         WHERE token_hash = ? AND client_id = ?`,
        [credentialHash('refresh-token', token), client.clientId],
      );
    if (credential) {
      revokeSsoTokenFamily(
        client.clientId,
        credential.user_id,
        credential.family_id,
      );
    }
  });
}

export function revokeSsoCredentialsForUser(userId) {
  const normalizedUserId = Number(userId);
  if (!Number.isSafeInteger(normalizedUserId) || normalizedUserId <= 0) return;
  run('DELETE FROM sso_authorization_codes WHERE user_id = ?', [
    normalizedUserId,
  ]);
  run(
    `UPDATE sso_access_tokens
     SET revoked_at = datetime('now')
     WHERE user_id = ? AND revoked_at IS NULL`,
    [normalizedUserId],
  );
  run(
    `UPDATE sso_refresh_tokens
     SET revoked_at = datetime('now')
     WHERE user_id = ? AND revoked_at IS NULL`,
    [normalizedUserId],
  );
}

export function ssoWalletBalance(principal) {
  requirePrincipalScope(principal, 'wallet:read');
  const row = one(
    `SELECT user.*,
            (SELECT COALESCE(MAX(event.id), 0)
             FROM user_reward_events event
             WHERE event.user_id = user.id AND event.coins_delta != 0
            ) AS wallet_version
     FROM users user
     WHERE user.id = ? AND user.status = 'active'`,
    [principal.user.id],
  );
  if (!row) throw ssoError(401, 'invalid_token');
  return {
    currency: 'SAKURA_COIN',
    balance: nonNegativeInteger(row.sakura_coins),
    version: Number(row.wallet_version || 0),
    updatedAt: row.updated_at,
  };
}

export function listSsoWalletChanges(
  principal,
  { limit = 50, afterId = 0 } = {},
) {
  requirePrincipalScope(principal, 'wallet:read');
  const safeLimit = Math.max(1, Math.min(100, Math.trunc(Number(limit) || 50)));
  const cursor = Math.max(0, Math.trunc(Number(afterId) || 0));
  return withDeferredTransaction(() => {
    const rows = all(
      `SELECT id, coins_delta, created_at
       FROM user_reward_events
       WHERE user_id = ? AND coins_delta != 0 AND id > ?
       ORDER BY id ASC
       LIMIT ?`,
      [principal.user.id, cursor, safeLimit + 1],
    );
    const hasMore = rows.length > safeLimit;
    const items = rows.slice(0, safeLimit).map((row) => ({
      id: Number(row.id),
      currency: 'SAKURA_COIN',
      delta: Number(row.coins_delta),
      direction: Number(row.coins_delta) > 0 ? 'credit' : 'debit',
      createdAt: row.created_at,
    }));
    return {
      wallet: ssoWalletBalance(principal),
      items,
      nextCursor: items.length ? items.at(-1).id : cursor,
      hasMore,
    };
  });
}

export function listSsoWalletTransactions(
  principal,
  { limit = 20, beforeId = 0 } = {},
) {
  requirePrincipalScope(principal, 'wallet:read');
  const safeLimit = Math.max(1, Math.min(100, Math.trunc(Number(limit) || 20)));
  const cursor = Math.max(0, Math.trunc(Number(beforeId) || 0));
  const params = [principal.user.id, principal.clientId];
  const cursorSql = cursor ? 'AND id < ?' : '';
  if (cursor) params.push(cursor);
  params.push(safeLimit);

  const items = all(
    `SELECT * FROM sso_wallet_transactions
     WHERE user_id = ? AND client_id = ?
       ${cursorSql}
     ORDER BY id DESC
     LIMIT ?`,
    params,
  ).map(serializeWalletTransaction);
  return {
    items,
    nextCursor: items.length === safeLimit ? items.at(-1).id : null,
  };
}

export function applySsoWalletChange({
  client,
  accessToken,
  idempotencyKey,
  delta,
  reason,
  referenceId = '',
  metadata = {},
} = {}) {
  if (!client?.clientId) throw ssoError(401, 'invalid_client');
  const principal = findSsoPrincipal(accessToken);
  if (!principal || principal.clientId !== client.clientId) {
    throw ssoError(401, 'invalid_token');
  }

  const amount = Number(delta);
  if (
    !Number.isSafeInteger(amount) ||
    amount === 0 ||
    Math.abs(amount) > maxWalletDelta
  ) {
    throw ssoError(400, 'wallet_delta_invalid');
  }
  const requiredScope = amount < 0 ? 'wallet:debit' : 'wallet:credit';
  requirePrincipalScope(principal, requiredScope);
  if (!client.scopes.has(requiredScope)) {
    throw ssoError(403, 'insufficient_scope');
  }
  const operationLimit =
    amount < 0
      ? client.limits.maxDebitPerTransaction
      : client.limits.maxCreditPerTransaction;
  const dailyLimit =
    amount < 0 ? client.limits.dailyDebitLimit : client.limits.dailyCreditLimit;
  if (operationLimit <= 0 || dailyLimit <= 0) {
    throw ssoError(403, 'wallet_operation_not_allowed');
  }
  if (Math.abs(amount) > operationLimit) {
    throw ssoError(409, 'wallet_transaction_limit_exceeded');
  }

  const requestKey = String(idempotencyKey || '').trim();
  if (!idempotencyKeyPattern.test(requestKey)) {
    throw ssoError(400, 'idempotency_key_invalid');
  }
  const normalizedReason = requiredText(reason, 'reason', 120);
  const normalizedReferenceId = optionalText(referenceId, 'reference_id', 120);
  const normalizedMetadata = normalizeMetadata(metadata);
  const requestHash = walletRequestHash({
    userId: principal.user.id,
    delta: amount,
    reason: normalizedReason,
    referenceId: normalizedReferenceId,
    metadata: normalizedMetadata.value,
  });

  return withImmediateTransaction(() => {
    const previous = one(
      `SELECT * FROM sso_wallet_transactions
       WHERE client_id = ? AND idempotency_key = ?`,
      [client.clientId, requestKey],
    );
    if (previous) {
      if (!safeEqual(previous.request_hash, requestHash)) {
        throw ssoError(409, 'idempotency_conflict');
      }
      return {
        transaction: serializeWalletTransaction(previous),
        replayed: true,
      };
    }

    const daily = one(
      `SELECT COALESCE(SUM(ABS(delta)), 0) AS total
       FROM sso_wallet_transactions
       WHERE client_id = ?
         ${amount < 0 ? 'AND user_id = ?' : ''}
         AND ${amount < 0 ? 'delta < 0' : 'delta > 0'}
         AND created_at >= datetime('now', '+8 hours', 'start of day', '-8 hours')
         AND created_at < datetime('now', '+8 hours', 'start of day', '+1 day', '-8 hours')`,
      amount < 0
        ? [client.clientId, principal.user.id]
        : [client.clientId],
    );
    if (Number(daily?.total || 0) + Math.abs(amount) > dailyLimit) {
      throw ssoError(409, 'wallet_daily_limit_exceeded');
    }

    const user = one(
      `SELECT * FROM users
       WHERE id = ? AND status = 'active'`,
      [principal.user.id],
    );
    if (!user) throw ssoError(401, 'invalid_token');
    const balanceBefore = Number(user.sakura_coins);
    const balanceAfter = balanceBefore + amount;
    if (
      !Number.isSafeInteger(balanceBefore) ||
      balanceBefore < 0 ||
      !Number.isSafeInteger(balanceAfter)
    ) {
      throw ssoError(409, 'wallet_balance_invalid');
    }
    if (balanceAfter < 0) {
      throw ssoError(409, 'insufficient_sakura_coins');
    }

    const updated = run(
      `UPDATE users
       SET sakura_coins = ?, updated_at = datetime('now')
       WHERE id = ? AND status = 'active'`,
      [balanceAfter, user.id],
    );
    if (Number(updated.changes || 0) !== 1) {
      throw ssoError(409, 'wallet_update_conflict');
    }

    const rewardEvent = run(
      `INSERT INTO user_reward_events
       (user_id, action, coins_delta, description, related_type, related_id)
       VALUES (?, ?, ?, ?, 'sso_wallet', ?)`,
      [
        user.id,
        amount < 0 ? 'sso_wallet_debit' : 'sso_wallet_credit',
        amount,
        `${client.name}: ${normalizedReason}`.slice(0, 240),
        `${client.clientId}:${requestKey}`,
      ],
    );
    const inserted = run(
      `INSERT INTO sso_wallet_transactions
       (client_id, user_id, reward_event_id, idempotency_key, request_hash,
        delta, balance_before, balance_after, reason, reference_id, metadata_json)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        client.clientId,
        user.id,
        Number(rewardEvent.lastInsertRowid),
        requestKey,
        requestHash,
        amount,
        balanceBefore,
        balanceAfter,
        normalizedReason,
        normalizedReferenceId,
        normalizedMetadata.json,
      ],
    );
    const transactionId = Number(inserted.lastInsertRowid);

    return {
      transaction: serializeWalletTransaction(
        one('SELECT * FROM sso_wallet_transactions WHERE id = ?', [
          transactionId,
        ]),
      ),
      replayed: false,
    };
  });
}

export function pkceChallenge(codeVerifier) {
  return crypto
    .createHash('sha256')
    .update(String(codeVerifier || ''), 'utf8')
    .digest('base64url');
}

function issueSsoTokenPair({
  clientId,
  user,
  scopeText,
  familyId = randomToken(18),
  refreshExpiresAt = secondsFromNow(refreshTokenTtlSeconds),
}) {
  const accessToken = randomToken();
  const refreshToken = randomToken();
  run(
    `INSERT INTO sso_access_tokens
     (token_hash, family_id, client_id, user_id, scopes, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      credentialHash('access-token', accessToken),
      familyId,
      clientId,
      user.id,
      scopeText,
      secondsFromNow(accessTokenTtlSeconds),
    ],
  );
  run(
    `INSERT INTO sso_refresh_tokens
     (token_hash, family_id, client_id, user_id, scopes, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      credentialHash('refresh-token', refreshToken),
      familyId,
      clientId,
      user.id,
      scopeText,
      refreshExpiresAt,
    ],
  );
  return {
    accessToken,
    refreshToken,
    tokenType: 'Bearer',
    expiresIn: accessTokenTtlSeconds,
    refreshExpiresIn: secondsUntil(refreshExpiresAt),
    scope: scopeText,
    user: serializeSsoUser(user, clientId, scopeText),
  };
}

function revokeClientCredentials(clientId) {
  run('DELETE FROM sso_authorization_codes WHERE client_id = ?', [clientId]);
  run(
    `UPDATE sso_access_tokens
     SET revoked_at = datetime('now')
     WHERE client_id = ? AND revoked_at IS NULL`,
    [clientId],
  );
  run(
    `UPDATE sso_refresh_tokens
     SET revoked_at = datetime('now')
     WHERE client_id = ? AND revoked_at IS NULL`,
    [clientId],
  );
}

function revokeSsoTokenFamily(clientId, userId, familyId) {
  run(
    `UPDATE sso_access_tokens
     SET revoked_at = datetime('now')
     WHERE client_id = ? AND user_id = ? AND family_id = ?
       AND revoked_at IS NULL`,
    [clientId, userId, familyId],
  );
  run(
    `UPDATE sso_refresh_tokens
     SET revoked_at = datetime('now')
     WHERE client_id = ? AND user_id = ? AND family_id = ?
       AND revoked_at IS NULL`,
    [clientId, userId, familyId],
  );
}

function serializeClient(row) {
  if (!row) return null;
  return {
    clientId: row.client_id,
    name: row.name,
    scopes: parseScopeText(row.scopes),
    redirectUris: parseRedirectUris(row.redirect_uris),
    limits: {
      maxDebitPerTransaction: Number(row.max_debit_per_transaction),
      dailyDebitLimit: Number(row.daily_debit_limit),
      maxCreditPerTransaction: Number(row.max_credit_per_transaction),
      dailyCreditLimit: Number(row.daily_credit_limit),
    },
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function clientPrincipal(row) {
  return {
    ...serializeClient(row),
    scopes: new Set(parseScopeText(row.scopes)),
  };
}

function serializeSsoUser(user, clientId, scopes) {
  const scopeSet = scopes instanceof Set ? scopes : new Set(parseScopeText(scopes));
  const serialized = {
    sub: ssoSubject(clientId, user.id),
  };
  if (scopeSet.has('profile:read')) {
    serialized.nickname = String(user.nickname || '');
    serialized.avatarUrl = String(user.avatar_url || '');
    serialized.updatedAt = user.updated_at;
  }
  if (scopeSet.has('wallet:read')) {
    serialized.sakuraCoins = nonNegativeInteger(user.sakura_coins);
  }
  return serialized;
}

function serializeWalletTransaction(row) {
  return {
    id: Number(row.id),
    rewardEventId: Number(row.reward_event_id),
    currency: 'SAKURA_COIN',
    delta: Number(row.delta),
    balanceBefore: Number(row.balance_before),
    balanceAfter: Number(row.balance_after),
    reason: row.reason,
    referenceId: row.reference_id || '',
    metadata: parseStoredMetadata(row.metadata_json),
    createdAt: row.created_at,
  };
}

function resolveRequestedScopes(value, allowedScopes) {
  const requested = parseScopeInput(value);
  const defaults = defaultSsoAuthorizationScopes.filter((scope) =>
    allowedScopes.has(scope),
  );
  const selected = requested.length ? requested : defaults;
  if (!selected.length || selected.some((scope) => !allowedScopes.has(scope))) {
    throw ssoError(400, 'invalid_scope');
  }
  return selected;
}

function normalizeClientScopes(value) {
  const scopes = parseScopeInput(value);
  const selected = scopes.length ? scopes : [...defaultSsoClientScopes];
  if (
    !selected.length ||
    selected.some((scope) => !supportedSsoScopes.includes(scope))
  ) {
    throw ssoError(400, 'sso_client_scope_invalid');
  }
  return selected;
}

function normalizeRedirectUris(value) {
  const items = Array.isArray(value)
    ? value
    : String(value || '')
        .split(/[\r\n,]+/)
        .filter(Boolean);
  const uris = [...new Set(items.map(normalizeRedirectUri))];
  if (!uris.length || uris.length > 10) {
    throw ssoError(400, 'sso_redirect_uris_invalid');
  }
  return uris;
}

function normalizeRedirectUri(value) {
  const raw = requiredText(value, 'redirect_uri', 500);
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw ssoError(400, 'redirect_uri_invalid');
  }
  if (url.username || url.password || url.hash) {
    throw ssoError(400, 'redirect_uri_invalid');
  }
  const scheme = url.protocol.toLowerCase();
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(
    url.hostname.toLowerCase(),
  );
  const customScheme =
    /^[a-z][a-z0-9+.-]*:$/.test(scheme) &&
    !['http:', 'https:', 'file:', 'data:', 'javascript:'].includes(scheme);
  if (scheme !== 'https:' && !(scheme === 'http:' && loopback) && !customScheme) {
    throw ssoError(400, 'redirect_uri_invalid');
  }
  return url.toString();
}

function parseRedirectUris(value) {
  try {
    const parsed = JSON.parse(String(value || '[]'));
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

function resolveRedirectUri(value, client) {
  const redirectUri = normalizeRedirectUri(value);
  if (!client.redirectUris.includes(redirectUri)) {
    throw ssoError(400, 'redirect_uri_not_allowed');
  }
  return redirectUri;
}

function normalizeClientLimits(values) {
  return {
    maxDebitPerTransaction: normalizeLimit(
      values.maxDebitPerTransaction,
      0,
      maxWalletDelta,
    ),
    dailyDebitLimit: normalizeLimit(
      values.dailyDebitLimit,
      0,
      Number.MAX_SAFE_INTEGER,
    ),
    maxCreditPerTransaction: normalizeLimit(
      values.maxCreditPerTransaction,
      0,
      maxWalletDelta,
    ),
    dailyCreditLimit: normalizeLimit(
      values.dailyCreditLimit,
      0,
      Number.MAX_SAFE_INTEGER,
    ),
  };
}

function normalizeLimit(value, fallback, maximum) {
  const number = value == null || value === '' ? fallback : Number(value);
  if (!Number.isSafeInteger(number) || number < 0 || number > maximum) {
    throw ssoError(400, 'sso_client_limit_invalid');
  }
  return number;
}

function parseScopeInput(value) {
  const items = Array.isArray(value)
    ? value
    : String(value || '')
        .split(/[\s,]+/)
        .filter(Boolean);
  return [...new Set(items.map((item) => String(item).trim()).filter(Boolean))];
}

function parseScopeText(value) {
  return String(value || '')
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function requirePrincipalScope(principal, scope) {
  if (!principal?.scopes?.has(scope)) {
    throw ssoError(403, 'insufficient_scope');
  }
}

function normalizeClientId(value) {
  const clientId = String(value || '').trim().toLowerCase();
  if (!clientIdPattern.test(clientId)) {
    throw ssoError(400, 'sso_client_id_invalid');
  }
  return clientId;
}

function requiredText(value, field, maxLength) {
  const text = String(value || '').trim();
  if (!text || text.length > maxLength || /[\u0000-\u001f\u007f]/.test(text)) {
    throw ssoError(400, `${field}_invalid`);
  }
  return text;
}

function optionalText(value, field, maxLength) {
  const text = String(value || '').trim();
  if (text.length > maxLength || /[\u0000-\u001f\u007f]/.test(text)) {
    throw ssoError(400, `${field}_invalid`);
  }
  return text;
}

function normalizeMetadata(value) {
  const metadata = value == null ? {} : value;
  if (
    typeof metadata !== 'object' ||
    Array.isArray(metadata) ||
    Object.getPrototypeOf(metadata) !== Object.prototype
  ) {
    throw ssoError(400, 'metadata_invalid');
  }
  const normalized = stableValue(metadata);
  const json = JSON.stringify(normalized);
  if (Buffer.byteLength(json, 'utf8') > 2048) {
    throw ssoError(400, 'metadata_too_large');
  }
  return { value: normalized, json };
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

function parseStoredMetadata(value) {
  try {
    const parsed = JSON.parse(String(value || '{}'));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    return {};
  }
}

function walletRequestHash(payload) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(payload), 'utf8')
    .digest('hex');
}

function ensureSsoUserLink(clientId, userId, touch = false) {
  let link = one(
    `SELECT * FROM sso_user_links
     WHERE client_id = ? AND user_id = ?`,
    [clientId, userId],
  );
  for (let attempt = 0; !link && attempt < 3; attempt += 1) {
    run(
      `INSERT OR IGNORE INTO sso_user_links
       (client_id, user_id, subject)
       VALUES (?, ?, ?)`,
      [clientId, userId, randomToken(24)],
    );
    link = one(
      `SELECT * FROM sso_user_links
       WHERE client_id = ? AND user_id = ?`,
      [clientId, userId],
    );
  }
  if (!link) throw ssoError(500, 'sso_subject_creation_failed');
  if (touch) {
    run(
      `UPDATE sso_user_links
       SET last_login_at = datetime('now')
       WHERE client_id = ? AND user_id = ?`,
      [clientId, userId],
    );
  }
  return link;
}

function ssoSubject(clientId, userId) {
  return ensureSsoUserLink(clientId, userId).subject;
}

function credentialHash(kind, value) {
  return crypto
    .createHmac('sha256', config.tokenSecret)
    .update(`sso-${kind}:${String(value || '')}`, 'utf8')
    .digest('base64url');
}

function clientSecretHash(value) {
  return crypto
    .createHash('sha256')
    .update(`sso-client-secret:${String(value || '')}`, 'utf8')
    .digest('base64url');
}

function secondsFromNow(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

function secondsUntil(timestamp) {
  return Math.max(0, Math.ceil((Date.parse(timestamp) - Date.now()) / 1000));
}

function nonNegativeInteger(value) {
  return Math.max(0, Math.trunc(Number(value) || 0));
}

function withImmediateTransaction(callback) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = callback();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // Preserve the original error if SQLite already ended the transaction.
    }
    throw error;
  }
}

function withDeferredTransaction(callback) {
  db.exec('BEGIN');
  try {
    const result = callback();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    try {
      db.exec('ROLLBACK');
    } catch {
      // Preserve the original error if SQLite already ended the transaction.
    }
    throw error;
  }
}

function ssoError(statusCode, publicCode) {
  const error = new Error(publicCode);
  error.statusCode = statusCode;
  error.publicCode = publicCode;
  return error;
}
