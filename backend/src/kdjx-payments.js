import fs from 'node:fs';
import { createHmac, randomUUID } from 'node:crypto';
import { kdjxConfig, kdjxPaymentEndpointAllowed } from './kdjx-config.js';
import { db, one, run } from './db.js';
import { ensureKdjxGameSchema } from './kdjx-schema.js';
import { recordKdjxGameIdentity } from './kdjx-sso.js';

let catalogCache;

export function kdjxPaymentsAvailable() {
  try {
    return getCatalog().size > 0 &&
      kdjxPaymentEndpointAllowed(kdjxConfig.paymentVerifyUrl, 'verify') &&
      kdjxPaymentEndpointAllowed(kdjxConfig.paymentFulfillmentUrl, 'fulfill') &&
      Boolean(kdjxConfig.paymentHmacSecret.trim());
  } catch {
    return false;
  }
}

export function resetKdjxPaymentCatalogForTests() {
  catalogCache = undefined;
}

export async function previewKdjxPayment(input) {
  ensureKdjxGameSchema();
  const order = normalizeOrderInput(input);
  const product = requireProduct(input.productId);
  requireGameAccountLink(input.userId);
  return paymentPreview(input.userId, order, product);
}

export async function createKdjxPayment(input) {
  ensureKdjxGameSchema();
  releaseStaleKdjxPaymentClaims();
  const orderInput = normalizeOrderInput(input);
  const expectedQuote = normalizeExpectedQuote(input);
  const idempotencyKey = cleanId(
    input.idempotencyKey || orderInput.gameOrderId,
    'idempotency_key',
    128,
  );
  let product;
  let order;

  const existingBeforeVerify = findExistingOrder(
    input.userId,
    orderInput.gameOrderId,
    idempotencyKey,
  );
  if (existingBeforeVerify) {
    assertMatchingOrder({
      existing: existingBeforeVerify,
      userId: input.userId,
      orderInput,
      idempotencyKey,
      expectedQuote,
    });
    order = existingBeforeVerify;
  } else {
    product = requireProduct(orderInput.productId);
    assertCurrentQuote(product, expectedQuote);
    const link = requireGameAccountLink(input.userId);
    if (userBalance(input.userId) < product.coinCost) {
      throw paymentError('coins_not_enough', 409);
    }
    await verifyGameOrder({
      userId: input.userId,
      link,
      order: orderInput,
      product,
    });
  }

  db.exec('BEGIN IMMEDIATE');
  try {
    const byGameOrder = one(
      `SELECT * FROM kdjx_payment_orders WHERE game_order_id = ?`,
      [orderInput.gameOrderId],
    );
    const byIdempotencyKey = one(
      `SELECT * FROM kdjx_payment_orders
       WHERE user_id = ? AND idempotency_key = ?`,
      [input.userId, idempotencyKey],
    );
    const existing = byGameOrder || byIdempotencyKey;
    if (existing) {
      if (!sameOrder(byGameOrder, byIdempotencyKey)) {
        throw paymentError('payment_idempotency_conflict', 409);
      }
      assertMatchingOrder({
        existing,
        userId: input.userId,
        orderInput,
        idempotencyKey,
        expectedQuote,
      });
      order = existing;
    } else {
      product = requireProduct(orderInput.productId);
      assertCurrentQuote(product, expectedQuote);
      const link = requireGameAccountLink(input.userId);
      const debit = run(
        `UPDATE users
         SET sakura_coins = sakura_coins - ?, updated_at = datetime('now')
         WHERE id = ? AND status = 'active' AND sakura_coins >= ?`,
        [product.coinCost, input.userId, product.coinCost],
      );
      if ((debit.changes || 0) !== 1) {
        throw paymentError('coins_not_enough', 409);
      }
      const id = randomUUID();
      run(
        `INSERT INTO kdjx_payment_orders
          (id, game_order_id, channel_order_id, user_id, game_open_id,
           account_id, role_id, server_key, product_id, product_name,
           recharge_id, yy_id, csv_id, money_cents, coin_cost,
           idempotency_key, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid')`,
        [
          id,
          orderInput.gameOrderId,
          channelOrderId(orderInput.gameOrderId),
          input.userId,
          link.game_open_id,
          orderInput.accountId,
          orderInput.roleId,
          orderInput.serverKey,
          product.productId,
          product.productName,
          product.rechargeId,
          orderInput.yyId,
          orderInput.csvId,
          product.moneyCents,
          product.coinCost,
          idempotencyKey,
        ],
      );
      run(
        `INSERT INTO user_reward_events
          (user_id, action, coins_delta, description, related_type, related_id)
         VALUES (?, 'kdjx_payment', ?, ?, 'kdjx_payment_order', ?)`,
        [
          input.userId,
          -product.coinCost,
          `KDJX game payment: ${product.productName}`,
          id,
        ],
      );
      order = one('SELECT * FROM kdjx_payment_orders WHERE id = ?', [id]);
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }

  if (['paid', 'delivery_failed'].includes(order.status)) {
    order = await fulfillKdjxPayment(order.id, { force: false });
  }
  return paymentJson(order);
}

export function findKdjxPayment(userId, gameOrderId) {
  ensureKdjxGameSchema();
  releaseStaleKdjxPaymentClaims();
  const order = one(
    `SELECT * FROM kdjx_payment_orders
     WHERE user_id = ? AND game_order_id = ?`,
    [userId, cleanId(gameOrderId, 'game_order_id', 96)],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  return paymentJson(order);
}

export async function retryKdjxPayment(userId, gameOrderId, expected = {}) {
  ensureKdjxGameSchema();
  releaseStaleKdjxPaymentClaims();
  const order = one(
    `SELECT * FROM kdjx_payment_orders
     WHERE user_id = ? AND game_order_id = ?`,
    [userId, cleanId(gameOrderId, 'game_order_id', 96)],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  if (expected.status && order.status !== expected.status) {
    throw paymentError('kdjx_payment_status_changed', 409);
  }
  if (
    expected.attempts !== undefined &&
    Number(order.fulfillment_attempts) !== expected.attempts
  ) {
    throw paymentError('kdjx_payment_version_changed', 409);
  }
  if (!['paid', 'delivery_failed'].includes(order.status)) {
    return paymentJson(order);
  }
  return paymentJson(await fulfillKdjxPayment(order.id, {
    force: true,
    expectedAttempts: expected.attempts,
  }));
}

async function fulfillKdjxPayment(orderId, {
  force,
  expectedAttempts,
}) {
  let order = one('SELECT * FROM kdjx_payment_orders WHERE id = ?', [orderId]);
  if (!order || !['paid', 'delivery_failed'].includes(order.status)) return order;
  if (
    !force &&
    Number(order.fulfillment_attempts) >= kdjxConfig.paymentMaxAttempts
  ) {
    return order;
  }

  const claimVersionClause = expectedAttempts === undefined
    ? ''
    : ' AND fulfillment_attempts = ?';
  const claimed = run(
    `UPDATE kdjx_payment_orders
     SET status = 'fulfilling', fulfillment_attempts = fulfillment_attempts + 1,
         updated_at = datetime('now')
     WHERE id = ? AND status IN ('paid', 'delivery_failed')
       ${claimVersionClause}`,
    expectedAttempts === undefined
      ? [orderId]
      : [orderId, expectedAttempts],
  );
  if ((claimed.changes || 0) !== 1) {
    if (expectedAttempts !== undefined) {
      throw paymentError('kdjx_payment_version_changed', 409);
    }
    return one('SELECT * FROM kdjx_payment_orders WHERE id = ?', [orderId]);
  }

  order = one('SELECT * FROM kdjx_payment_orders WHERE id = ?', [orderId]);
  const request = signedPaymentRequest(fulfillmentPayload(order));
  try {
    const response = await fetch(kdjxConfig.paymentFulfillmentUrl, {
      method: 'POST',
      body: request.body,
      signal: AbortSignal.timeout(kdjxConfig.paymentTimeoutMs),
      headers: request.headers,
    });
    if (!response.ok) throw new Error(`fulfillment_http_${response.status}`);
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error('fulfillment_response_invalid');
    }
    const reference = String(payload?.gamePaymentOrderId || '').toLowerCase();
    if (
      payload?.ok !== true ||
      payload.fulfilled !== true ||
      payload.rechargeFlag !== true ||
      String(payload.gameOrderId) !== order.game_order_id ||
      String(payload.channelOrderId) !== order.channel_order_id ||
      !/^[0-9a-f]{24}$/.test(reference)
    ) {
      throw new Error('fulfillment_response_mismatch');
    }
    run(
      `UPDATE kdjx_payment_orders
       SET status = 'fulfilled', fulfillment_reference = ?,
           fulfilled_at = datetime('now'), last_error = '',
           updated_at = datetime('now')
       WHERE id = ? AND status = 'fulfilling'`,
      [reference, orderId],
    );
  } catch (error) {
    const message = String(error?.message || 'fulfillment_failed').slice(0, 200);
    run(
      `UPDATE kdjx_payment_orders
       SET status = 'delivery_failed', last_error = ?,
           updated_at = datetime('now')
       WHERE id = ? AND status = 'fulfilling'`,
      [message, orderId],
    );
  }
  return one('SELECT * FROM kdjx_payment_orders WHERE id = ?', [orderId]);
}

async function verifyGameOrder({ userId, link, order, product }) {
  const expected = verificationPayload(link.game_open_id, order, product);
  const request = signedPaymentRequest(expected);
  let response;
  try {
    response = await fetch(kdjxConfig.paymentVerifyUrl, {
      method: 'POST',
      body: request.body,
      signal: AbortSignal.timeout(kdjxConfig.paymentTimeoutMs),
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
    const clientError = response.status >= 400 && response.status < 500;
    throw paymentError(
      clientError
        ? 'game_order_not_payable'
        : 'game_order_verification_unavailable',
      clientError ? 409 : 503,
    );
  }
  if (!sameVerificationOrder(payload.order, expected)) {
    throw paymentError('game_order_verification_mismatch', 502);
  }
  recordKdjxGameIdentity({
    userId,
    gameOpenId: link.game_open_id,
    accountId: order.accountId,
    roleId: order.roleId,
    serverKey: order.serverKey,
  });
}

function verificationPayload(gameOpenId, order, product) {
  return {
    gameOrderId: order.gameOrderId,
    gameOpenId,
    accountId: order.accountId,
    roleId: order.roleId,
    serverKey: order.serverKey,
    productId: product.productId,
    rechargeId: product.rechargeId,
    yyId: order.yyId,
    csvId: order.csvId,
    moneyCents: product.moneyCents,
    coinCost: product.coinCost,
    amountYuan: (product.moneyCents / 100).toFixed(2),
  };
}

function fulfillmentPayload(order) {
  return {
    novelOrderId: order.id,
    gameOrderId: order.game_order_id,
    channelOrderId: order.channel_order_id,
    gameOpenId: order.game_open_id,
    accountId: order.account_id,
    roleId: order.role_id,
    serverKey: order.server_key,
    productId: order.product_id,
    rechargeId: Number(order.recharge_id),
    yyId: Number(order.yy_id),
    csvId: Number(order.csv_id),
    moneyCents: Number(order.money_cents),
    coinCost: Number(order.coin_cost),
    amountYuan: (Number(order.money_cents) / 100).toFixed(2),
    channel: 'sakura',
  };
}

function signedPaymentRequest(payload) {
  const body = JSON.stringify(payload);
  const timestamp = String(Date.now());
  const nonce = randomUUID();
  const signature = createHmac('sha256', kdjxConfig.paymentHmacSecret)
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

export function releaseStaleKdjxPaymentClaims() {
  const cutoff = new Date(
    Date.now() - kdjxConfig.paymentClaimTtlMs,
  ).toISOString();
  run(
    `UPDATE kdjx_payment_orders
     SET status = 'delivery_failed', last_error = 'stale_delivery_claim',
         updated_at = datetime('now')
     WHERE status = 'fulfilling' AND datetime(updated_at) < datetime(?)`,
    [cutoff],
  );
}

function normalizeOrderInput(input) {
  return {
    gameOrderId: cleanId(input.gameOrderId, 'game_order_id', 96),
    productId: cleanId(input.productId, 'product_id', 128),
    accountId: objectId(input.accountId, 'account_id'),
    roleId: objectId(input.roleId, 'role_id'),
    serverKey: cleanId(input.serverKey, 'server_key', 128),
    yyId: optionalPositiveInteger(input.yyId, 'yy_id'),
    csvId: optionalPositiveInteger(input.csvId, 'csv_id'),
  };
}

function findExistingOrder(userId, gameOrderId, idempotencyKey) {
  const byGameOrder = one(
    'SELECT * FROM kdjx_payment_orders WHERE game_order_id = ?',
    [gameOrderId],
  );
  const byIdempotencyKey = one(
    `SELECT * FROM kdjx_payment_orders
     WHERE user_id = ? AND idempotency_key = ?`,
    [userId, idempotencyKey],
  );
  if (!sameOrder(byGameOrder, byIdempotencyKey)) {
    throw paymentError('payment_idempotency_conflict', 409);
  }
  return byGameOrder || byIdempotencyKey;
}

function assertMatchingOrder({
  existing,
  userId,
  orderInput,
  idempotencyKey,
  expectedQuote,
}) {
  if (
    Number(existing.user_id) !== Number(userId) ||
    existing.game_order_id !== orderInput.gameOrderId ||
    existing.idempotency_key !== idempotencyKey ||
    existing.account_id !== orderInput.accountId ||
    existing.role_id !== orderInput.roleId ||
    existing.server_key !== orderInput.serverKey ||
    existing.product_id !== orderInput.productId ||
    Number(existing.yy_id) !== orderInput.yyId ||
    Number(existing.csv_id) !== orderInput.csvId ||
    Number(existing.money_cents) !== expectedQuote.moneyCents ||
    Number(existing.coin_cost) !== expectedQuote.coinCost
  ) {
    throw paymentError('payment_idempotency_conflict', 409);
  }
}

function requireGameAccountLink(userId) {
  const link = one(
    `SELECT game_open_id FROM kdjx_game_account_links
     WHERE novel_user_id = ?`,
    [userId],
  );
  if (!link) throw paymentError('game_account_not_linked', 409);
  return link;
}

function getCatalog() {
  if (catalogCache) return catalogCache;
  const raw = kdjxConfig.paymentCatalogFile
    ? fs.readFileSync(kdjxConfig.paymentCatalogFile, 'utf8')
    : kdjxConfig.paymentCatalogJson;
  const document = JSON.parse(raw || '[]');
  const parsed = Array.isArray(document) ? document : document?.products;
  if (!Array.isArray(parsed)) {
    throw new Error(
      'KDJX payment catalog must be an array or an object with products',
    );
  }
  if (
    !Array.isArray(document) &&
    (document.productCount !== undefined &&
      Number(document.productCount) !== parsed.length ||
      document.conversion !== undefined &&
      document.conversion !== '10_SAKURA_COINS_EQUAL_1_CNY')
  ) {
    throw new Error('Invalid KDJX payment catalog metadata');
  }

  const result = new Map();
  for (const item of parsed) {
    const productId = String(item.productId ?? item.rechargeId ?? '').trim();
    const productName = String(item.productName || item.name || '').trim();
    const rechargeId = Number(item.rechargeId);
    const moneyCents = Number(item.moneyCents);
    const coinCost = moneyCents / 10;
    if (productId === '100' || rechargeId === 100) continue;
    if (
      !productId ||
      !/^[A-Za-z0-9._:-]+$/.test(productId) ||
      !productName ||
      !Number.isSafeInteger(rechargeId) ||
      rechargeId <= 0 ||
      !Number.isSafeInteger(moneyCents) ||
      moneyCents <= 0 ||
      moneyCents % 10 !== 0 ||
      !Number.isSafeInteger(coinCost) ||
      (item.coinCost !== undefined && Number(item.coinCost) !== coinCost) ||
      result.has(productId)
    ) {
      throw new Error(`Invalid or duplicate KDJX product: ${productId || '<empty>'}`);
    }
    result.set(productId, {
      productId,
      productName,
      rechargeId,
      moneyCents,
      coinCost,
    });
  }
  catalogCache = result;
  return result;
}

function requireProduct(productId) {
  const product = getCatalog().get(String(productId || '').trim());
  if (!product) throw paymentError('payment_product_not_found', 404);
  return product;
}

function normalizeExpectedQuote(input) {
  const moneyCents = requiredPositiveInteger(
    input.expectedMoneyCents,
    'expected_money_cents',
  );
  const coinCost = requiredPositiveInteger(
    input.expectedCoinCost,
    'expected_coin_cost',
  );
  const displayPrice = String(input.expectedDisplayPrice || '').trim();
  if (
    moneyCents !== coinCost * 10 ||
    displayPrice !== displayPriceFor(moneyCents)
  ) {
    throw paymentError('invalid_payment_quote', 400);
  }
  return { moneyCents, coinCost, displayPrice };
}

function assertCurrentQuote(product, expectedQuote) {
  if (
    product.moneyCents !== expectedQuote.moneyCents ||
    product.coinCost !== expectedQuote.coinCost ||
    displayPriceFor(product.moneyCents) !== expectedQuote.displayPrice
  ) {
    throw paymentError('price_changed', 409);
  }
}

function sameVerificationOrder(actual, expected) {
  if (!actual) return false;
  const textFields = [
    'gameOrderId',
    'gameOpenId',
    'accountId',
    'roleId',
    'serverKey',
    'productId',
    'amountYuan',
  ];
  const numberFields = [
    'rechargeId',
    'yyId',
    'csvId',
    'moneyCents',
    'coinCost',
  ];
  return textFields.every(
    (field) => String(actual[field]) === String(expected[field]),
  ) && numberFields.every(
    (field) => Number(actual[field]) === Number(expected[field]),
  );
}

function paymentPreview(userId, order, product) {
  const paymentOrderId = channelOrderId(order.gameOrderId);
  return {
    gameOrderId: order.gameOrderId,
    channelOrderId: paymentOrderId,
    sakuraOrderId: paymentOrderId,
    accountId: order.accountId,
    roleId: order.roleId,
    serverKey: order.serverKey,
    yyId: order.yyId,
    csvId: order.csvId,
    ...product,
    displayPrice: displayPriceFor(product.moneyCents),
    balance: userBalance(userId),
    status: 'preview',
    lastError: '',
    canRetry: false,
  };
}

function paymentJson(row) {
  return {
    gameOrderId: row.game_order_id,
    channelOrderId: row.channel_order_id,
    sakuraOrderId: row.channel_order_id,
    accountId: row.account_id,
    roleId: row.role_id,
    serverKey: row.server_key,
    productId: row.product_id,
    productName: row.product_name,
    rechargeId: Number(row.recharge_id),
    yyId: Number(row.yy_id),
    csvId: Number(row.csv_id),
    moneyCents: Number(row.money_cents),
    coinCost: Number(row.coin_cost),
    displayPrice: displayPriceFor(Number(row.money_cents)),
    balance: userBalance(row.user_id),
    status: row.status,
    attempts: Number(row.fulfillment_attempts),
    fulfillmentReference: row.fulfillment_reference,
    lastError: row.last_error,
    canRetry: row.status === 'delivery_failed',
    createdAt: row.created_at,
  };
}

function userBalance(userId) {
  return Number(
    one('SELECT sakura_coins FROM users WHERE id = ?', [userId])
      ?.sakura_coins || 0,
  );
}

function cleanId(value, field, maximumLength) {
  const result = String(value || '').trim();
  if (
    !result ||
    result.length > maximumLength ||
    !/^[A-Za-z0-9._:-]+$/.test(result)
  ) {
    throw paymentError(`invalid_${field}`, 400);
  }
  return result;
}

function objectId(value, field) {
  const result = String(value || '').trim().toLowerCase();
  if (!/^[0-9a-f]{24}$/.test(result)) {
    throw paymentError(`invalid_${field}`, 400);
  }
  return result;
}

function optionalPositiveInteger(value, field) {
  if (value === undefined || value === null || value === '') return 0;
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result < 0) {
    throw paymentError(`invalid_${field}`, 400);
  }
  return result;
}

function requiredPositiveInteger(value, field) {
  const result = Number(value);
  if (
    value === undefined ||
    value === null ||
    value === '' ||
    !Number.isSafeInteger(result) ||
    result <= 0
  ) {
    throw paymentError(`invalid_${field}`, 400);
  }
  return result;
}

function displayPriceFor(moneyCents) {
  return moneyCents % 100 === 0
    ? `${moneyCents / 100}\u5143`
    : `${(moneyCents / 100).toFixed(2)}\u5143`;
}

function channelOrderId(gameOrderId) {
  return `sakura_${gameOrderId}`;
}

function sameOrder(left, right) {
  return !left || !right || left.id === right.id;
}

export function paymentError(code, statusCode) {
  const error = new Error(code);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}
