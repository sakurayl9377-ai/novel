import fs from 'node:fs';
import { createHmac, randomUUID } from 'node:crypto';
import { config } from './config.js';
import { db, one, run } from './db.js';
import { ensureModaoGameSchema } from './modao-schema.js';

let catalogCache;

export function modaoPaymentsAvailable() {
  try {
    return getCatalog().size > 0 &&
      isHttpsUrl(config.modaoPaymentVerifyUrl) &&
      isHttpsUrl(config.modaoPaymentFulfillmentUrl) &&
      Boolean(config.modaoPaymentHmacSecret?.trim());
  } catch {
    return false;
  }
}

export function resetModaoPaymentCatalogForTests() {
  catalogCache = undefined;
}

export async function previewModaoPayment({ userId, gameOrderId, productId }) {
  ensureModaoGameSchema();
  const product = requireProduct(productId);
  const normalizedOrderId = cleanId(gameOrderId, 'game_order_id');
  const link = requireGameAccountLink(userId);
  await verifyGameOrder({
    gameOrderId: normalizedOrderId,
    gameOpenId: link.game_open_id,
    product,
  });
  const balance = userBalance(userId);
  return {
    gameOrderId: normalizedOrderId,
    ...product,
    balance,
  };
}

export async function createModaoPayment({
  userId,
  gameOrderId,
  productId,
  idempotencyKey,
}) {
  ensureModaoGameSchema();
  releaseStaleDeliveryClaims();
  const normalizedOrderId = cleanId(gameOrderId, 'game_order_id');
  const normalizedKey = cleanId(
    idempotencyKey || normalizedOrderId,
    'idempotency_key',
  );
  const product = requireProduct(productId);
  const coinCost = product.coinCost;
  let order;

  const existingBeforeVerify = findExistingOrder(
    userId,
    normalizedOrderId,
    normalizedKey,
  );
  if (existingBeforeVerify) {
    assertMatchingOrder(
      existingBeforeVerify,
      userId,
      normalizedOrderId,
      normalizedKey,
      product.productId,
    );
    order = existingBeforeVerify;
  } else {
    const link = requireGameAccountLink(userId);
    if (userBalance(userId) < coinCost) {
      throw paymentError('coins_not_enough', 409);
    }
    await verifyGameOrder({
      gameOrderId: normalizedOrderId,
      gameOpenId: link.game_open_id,
      product,
    });
  }

  db.exec('BEGIN IMMEDIATE');
  try {
    const byGameOrder = one(
      'SELECT * FROM modao_payment_orders WHERE game_order_id = ?',
      [normalizedOrderId],
    );
    const byIdempotencyKey = one(
      `SELECT * FROM modao_payment_orders
       WHERE user_id = ? AND idempotency_key = ?`,
      [userId, normalizedKey],
    );
    const existing = byGameOrder || byIdempotencyKey;
    if (existing) {
      assertMatchingOrder(
        existing,
        userId,
        normalizedOrderId,
        normalizedKey,
        product.productId,
        byGameOrder,
        byIdempotencyKey,
      );
      order = existing;
    } else {
      const link = requireGameAccountLink(userId);
      const debit = run(
        `UPDATE users
         SET sakura_coins = sakura_coins - ?, updated_at = datetime('now')
         WHERE id = ? AND status = 'active' AND sakura_coins >= ?`,
        [coinCost, userId, coinCost],
      );
      if ((debit.changes ?? 0) !== 1) {
        throw paymentError('coins_not_enough', 409);
      }
      const id = randomUUID();
      run(
        `INSERT INTO modao_payment_orders
          (id, game_order_id, user_id, game_open_id, product_id, product_name,
           money_cents, coin_cost, idempotency_key, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid')`,
        [
          id,
          normalizedOrderId,
          userId,
          link.game_open_id,
          product.productId,
          product.productName,
          product.moneyCents,
          coinCost,
          normalizedKey,
        ],
      );
      run(
        `INSERT INTO user_reward_events
          (user_id, action, coins_delta, description, related_type, related_id)
         VALUES (?, 'modao_payment', ?, ?, 'modao_payment_order', ?)`,
        [userId, -coinCost, `Modao game payment: ${product.productName}`, id],
      );
      order = one('SELECT * FROM modao_payment_orders WHERE id = ?', [id]);
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }

  if (['paid', 'delivery_failed'].includes(order.status)) {
    order = await fulfillModaoPayment(order.id, { force: false });
  }
  return paymentJson(order);
}

export function findModaoPayment(userId, gameOrderId) {
  ensureModaoGameSchema();
  releaseStaleDeliveryClaims();
  const order = one(
    `SELECT * FROM modao_payment_orders
     WHERE user_id = ? AND game_order_id = ?`,
    [userId, cleanId(gameOrderId, 'game_order_id')],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  return paymentJson(order);
}

export async function retryModaoPayment(userId, gameOrderId) {
  ensureModaoGameSchema();
  releaseStaleDeliveryClaims();
  const order = one(
    `SELECT * FROM modao_payment_orders
     WHERE user_id = ? AND game_order_id = ?`,
    [userId, cleanId(gameOrderId, 'game_order_id')],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  if (!['paid', 'delivery_failed'].includes(order.status)) {
    return paymentJson(order);
  }
  return paymentJson(await fulfillModaoPayment(order.id, { force: true }));
}

async function fulfillModaoPayment(orderId, { force }) {
  let order = one('SELECT * FROM modao_payment_orders WHERE id = ?', [orderId]);
  if (!order || !['paid', 'delivery_failed'].includes(order.status)) return order;
  if (
    !force &&
    Number(order.fulfillment_attempts) >= config.modaoPaymentMaxAttempts
  ) {
    return order;
  }

  const claimed = run(
    `UPDATE modao_payment_orders
     SET status = 'fulfilling', fulfillment_attempts = fulfillment_attempts + 1,
         updated_at = datetime('now')
     WHERE id = ? AND status IN ('paid', 'delivery_failed')`,
    [orderId],
  );
  if ((claimed.changes ?? 0) !== 1) {
    return one('SELECT * FROM modao_payment_orders WHERE id = ?', [orderId]);
  }

  order = one('SELECT * FROM modao_payment_orders WHERE id = ?', [orderId]);
  const request = signedPaymentRequest({
    novelOrderId: order.id,
    gameOrderId: order.game_order_id,
    gameOpenId: order.game_open_id,
    productId: order.product_id,
    moneyCents: Number(order.money_cents),
    coinCost: Number(order.coin_cost),
  });

  try {
    const response = await fetch(config.modaoPaymentFulfillmentUrl, {
      method: 'POST',
      body: request.body,
      signal: AbortSignal.timeout(config.modaoPaymentTimeoutMs),
      headers: request.headers,
    });
    if (!response.ok) throw new Error(`fulfillment_http_${response.status}`);
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error('fulfillment_response_invalid');
    }
    if (
      payload?.ok !== true ||
      payload.fulfilled !== true ||
      String(payload.gameOrderId) !== order.game_order_id ||
      Number(payload.payState) !== 2
    ) {
      throw new Error('fulfillment_response_mismatch');
    }
    run(
      `UPDATE modao_payment_orders
       SET status = 'fulfilled', fulfilled_at = datetime('now'),
           last_error = '', updated_at = datetime('now')
       WHERE id = ? AND status = 'fulfilling'`,
      [orderId],
    );
  } catch (error) {
    const message = String(error?.message || 'fulfillment_failed').slice(0, 200);
    run(
      `UPDATE modao_payment_orders
       SET status = 'delivery_failed', last_error = ?, updated_at = datetime('now')
       WHERE id = ? AND status = 'fulfilling'`,
      [message, orderId],
    );
  }
  return one('SELECT * FROM modao_payment_orders WHERE id = ?', [orderId]);
}

function releaseStaleDeliveryClaims() {
  const cutoff = new Date(
    Date.now() - config.modaoPaymentClaimTtlMs,
  ).toISOString();
  run(
    `UPDATE modao_payment_orders
     SET status = 'delivery_failed', last_error = 'stale_delivery_claim',
         updated_at = datetime('now')
     WHERE status = 'fulfilling' AND datetime(updated_at) < datetime(?)`,
    [cutoff],
  );
}

async function verifyGameOrder({ gameOrderId, gameOpenId, product }) {
  const request = signedPaymentRequest({
    gameOrderId,
    gameOpenId,
    productId: product.productId,
    moneyCents: product.moneyCents,
    coinCost: product.coinCost,
  });
  let response;
  try {
    response = await fetch(config.modaoPaymentVerifyUrl, {
      method: 'POST',
      body: request.body,
      signal: AbortSignal.timeout(config.modaoPaymentTimeoutMs),
      headers: request.headers,
    });
  } catch {
    throw paymentError('game_order_verification_unavailable', 503);
  }

  let payload;
  try {
    payload = await response.json();
  } catch {
    throw paymentError('game_order_verification_invalid', 502);
  }
  if (!response.ok || payload?.ok !== true) {
    throw paymentError(
      response.status >= 400 && response.status < 500
        ? 'game_order_not_payable'
        : 'game_order_verification_unavailable',
      response.status >= 400 && response.status < 500 ? 409 : 503,
    );
  }
  const remote = payload.order;
  if (
    !remote ||
    String(remote.gameOrderId) !== gameOrderId ||
    String(remote.gameOpenId) !== gameOpenId ||
    String(remote.productId) !== product.productId ||
    Number(remote.moneyCents) !== product.moneyCents ||
    Number(remote.coinCost) !== product.coinCost
  ) {
    throw paymentError('game_order_verification_mismatch', 502);
  }
}

function signedPaymentRequest(payload) {
  const body = JSON.stringify(payload);
  const timestamp = String(Date.now());
  const nonce = randomUUID();
  const signature = createHmac('sha256', config.modaoPaymentHmacSecret)
    .update(`${timestamp}\n${nonce}\n${body}`)
    .digest('hex');
  return {
    body,
    headers: {
      'content-type': 'application/json',
      'x-novel-timestamp': timestamp,
      'x-novel-nonce': nonce,
      'x-novel-signature': signature,
      'x-novel-signature-version': 'v1',
    },
  };
}

function requireGameAccountLink(userId) {
  const link = one(
    `SELECT game_open_id FROM modao_game_account_links
     WHERE novel_user_id = ?`,
    [userId],
  );
  if (!link) throw paymentError('game_account_not_linked', 409);
  return link;
}

function findExistingOrder(userId, gameOrderId, idempotencyKey) {
  const byGameOrder = one(
    'SELECT * FROM modao_payment_orders WHERE game_order_id = ?',
    [gameOrderId],
  );
  const byIdempotencyKey = one(
    `SELECT * FROM modao_payment_orders
     WHERE user_id = ? AND idempotency_key = ?`,
    [userId, idempotencyKey],
  );
  if (!sameOrder(byGameOrder, byIdempotencyKey)) {
    throw paymentError('payment_idempotency_conflict', 409);
  }
  return byGameOrder || byIdempotencyKey;
}

function assertMatchingOrder(
  existing,
  userId,
  gameOrderId,
  idempotencyKey,
  productId,
  byGameOrder = existing,
  byIdempotencyKey = existing,
) {
  if (
    !sameOrder(byGameOrder, byIdempotencyKey) ||
    Number(existing.user_id) !== Number(userId) ||
    existing.product_id !== productId ||
    existing.game_order_id !== gameOrderId ||
    existing.idempotency_key !== idempotencyKey
  ) {
    throw paymentError('payment_idempotency_conflict', 409);
  }
}

function getCatalog() {
  if (catalogCache) return catalogCache;
  const raw = config.modaoPaymentCatalogFile?.trim()
    ? fs.readFileSync(config.modaoPaymentCatalogFile, 'utf8')
    : config.modaoPaymentCatalogJson;
  const document = JSON.parse(raw || '[]');
  const parsed = Array.isArray(document) ? document : document?.products;
  if (!Array.isArray(parsed)) {
    throw new Error(
      'MODAO payment catalog must be an array or an object with products',
    );
  }
  if (
    !Array.isArray(document) &&
    ((document.productCount !== undefined &&
      Number(document.productCount) !== parsed.length) ||
      (document.conversion !== undefined &&
        document.conversion !== '10_SAKURA_COINS_EQUAL_1_CNY'))
  ) {
    throw new Error('Invalid Modao payment catalog metadata');
  }
  const result = new Map();
  for (const item of parsed) {
    const productId = String(item.productId || '').trim();
    const productName = String(item.productName || item.name || '').trim();
    const moneyCents = Number(item.moneyCents);
    if (
      !productId ||
      !productName ||
      !Number.isSafeInteger(moneyCents) ||
      moneyCents <= 0 ||
      moneyCents % 10 !== 0 ||
      result.has(productId)
    ) {
      throw new Error(
        `Invalid or duplicate Modao product: ${productId || '<empty>'}`,
      );
    }
    const expectedCoinCost = moneyCents / 10;
    const declaredCoinCost = item.coinCost;
    if (
      !Number.isSafeInteger(expectedCoinCost) ||
      (declaredCoinCost !== undefined &&
        (!Number.isSafeInteger(Number(declaredCoinCost)) ||
          Number(declaredCoinCost) !== expectedCoinCost))
    ) {
      throw new Error(`Invalid Modao coin conversion: ${productId}`);
    }
    result.set(productId, {
      productId,
      productName,
      moneyCents,
      coinCost: expectedCoinCost,
    });
  }
  catalogCache = result;
  return result;
}

function isHttpsUrl(value) {
  try {
    return new URL(String(value || '')).protocol === 'https:';
  } catch {
    return false;
  }
}

function requireProduct(productId) {
  const product = getCatalog().get(String(productId || '').trim());
  if (!product) throw paymentError('payment_product_not_found', 404);
  return product;
}

function cleanId(value, field) {
  const result = String(value || '').trim();
  if (
    !result ||
    result.length > 128 ||
    !/^[A-Za-z0-9._:-]+$/.test(result)
  ) {
    throw paymentError(`invalid_${field}`, 400);
  }
  return result;
}

function sameOrder(left, right) {
  return !left || !right || left.id === right.id;
}

function userBalance(userId) {
  return Number(
    one('SELECT sakura_coins FROM users WHERE id = ?', [userId])?.sakura_coins || 0,
  );
}

export function paymentError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}

function paymentJson(row) {
  return {
    gameOrderId: row.game_order_id,
    productId: row.product_id,
    productName: row.product_name,
    moneyCents: Number(row.money_cents),
    coinCost: Number(row.coin_cost),
    balance: userBalance(row.user_id),
    status: row.status,
    attempts: Number(row.fulfillment_attempts),
    createdAt: row.created_at,
  };
}
