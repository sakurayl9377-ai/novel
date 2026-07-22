import fs from 'node:fs';
import { createHmac, randomUUID } from 'node:crypto';
import { config } from './config.js';
import { all, db, one, run } from './db.js';

let catalogCache;

export function bailianPaymentsAvailable() {
  try {
    return getCatalog().size > 0 && Boolean(
      config.bailianPaymentFulfillmentUrl?.trim() &&
      config.bailianPaymentHmacSecret?.trim(),
    );
  } catch {
    return false;
  }
}

export function resetBailianPaymentCatalogForTests() {
  catalogCache = undefined;
}

export function previewBailianPayment({ userId, gameOrderId, productId }) {
  const product = requireProduct(productId);
  const balance = Number(one('SELECT sakura_coins FROM users WHERE id = ?', [userId])?.sakura_coins || 0);
  return { gameOrderId: cleanId(gameOrderId, 'game_order_id'), ...product, coinCost: product.moneyCents / 10, balance };
}

export async function createBailianPayment({ userId, gameOrderId, productId, idempotencyKey }) {
  const normalizedOrderId = cleanId(gameOrderId, 'game_order_id');
  const normalizedKey = cleanId(idempotencyKey || normalizedOrderId, 'idempotency_key');
  const product = requireProduct(productId);
  const coinCost = product.moneyCents / 10;
  let order;
  db.exec('BEGIN IMMEDIATE');
  try {
    const existing = one(
      `SELECT * FROM bailian_payment_orders
       WHERE game_order_id = ? OR (user_id = ? AND idempotency_key = ?)`,
      [normalizedOrderId, userId, normalizedKey],
    );
    if (existing) {
      if (Number(existing.user_id) !== Number(userId) || existing.product_id !== product.productId || existing.game_order_id !== normalizedOrderId) {
        throw paymentError('payment_idempotency_conflict', 409);
      }
      order = existing;
    } else {
      const link = one('SELECT game_open_id FROM game_account_links WHERE novel_user_id = ?', [userId]);
      if (!link) throw paymentError('game_account_not_linked', 409);
      const debit = run(
        `UPDATE users SET sakura_coins = sakura_coins - ?, updated_at = datetime('now')
         WHERE id = ? AND status = 'active' AND sakura_coins >= ?`,
        [coinCost, userId, coinCost],
      );
      if ((debit.changes ?? 0) !== 1) throw paymentError('coins_not_enough', 409);
      const id = randomUUID();
      run(
        `INSERT INTO bailian_payment_orders
          (id, game_order_id, user_id, game_open_id, product_id, product_name,
           money_cents, coin_cost, idempotency_key, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid')`,
        [id, normalizedOrderId, userId, link.game_open_id, product.productId, product.productName, product.moneyCents, coinCost, normalizedKey],
      );
      run(
        `INSERT INTO user_reward_events
          (user_id, action, coins_delta, description, related_type, related_id)
         VALUES (?, 'bailian_payment', ?, ?, 'bailian_payment_order', ?)`,
        [userId, -coinCost, `百练英雄充值：${product.productName}`, id],
      );
      order = one('SELECT * FROM bailian_payment_orders WHERE id = ?', [id]);
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
  if (order.status === 'paid' || order.status === 'delivery_failed') {
    order = await fulfillBailianPayment(order.id);
  }
  return paymentJson(order);
}

export function findBailianPayment(userId, gameOrderId) {
  const order = one(
    'SELECT * FROM bailian_payment_orders WHERE user_id = ? AND game_order_id = ?',
    [userId, cleanId(gameOrderId, 'game_order_id')],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  return paymentJson(order);
}

export function listBailianPayments(userId, { limit = 20, offset = 0 } = {}) {
  const safeLimit = Math.max(1, Math.min(50, Math.trunc(Number(limit) || 20)));
  const safeOffset = Math.max(0, Math.trunc(Number(offset) || 0));
  const rows = all(
    `SELECT * FROM bailian_payment_orders
     WHERE user_id = ?
     ORDER BY created_at DESC, id DESC
     LIMIT ? OFFSET ?`,
    [userId, safeLimit + 1, safeOffset],
  );
  const hasMore = rows.length > safeLimit;
  return {
    items: rows.slice(0, safeLimit).map(paymentJsonWithoutBalance),
    hasMore,
    nextOffset: safeOffset + Math.min(rows.length, safeLimit),
  };
}

export async function retryBailianPayment(userId, gameOrderId) {
  const order = one(
    'SELECT * FROM bailian_payment_orders WHERE user_id = ? AND game_order_id = ?',
    [userId, cleanId(gameOrderId, 'game_order_id')],
  );
  if (!order) throw paymentError('payment_not_found', 404);
  if (!['paid', 'delivery_failed'].includes(order.status)) return paymentJson(order);
  return paymentJson(await fulfillBailianPayment(order.id));
}

async function fulfillBailianPayment(orderId) {
  let order = one('SELECT * FROM bailian_payment_orders WHERE id = ?', [orderId]);
  if (!order || !['paid', 'delivery_failed'].includes(order.status)) return order;
  const claimed = run(
    `UPDATE bailian_payment_orders SET status = 'fulfilling',
       fulfillment_attempts = fulfillment_attempts + 1, updated_at = datetime('now')
     WHERE id = ? AND status IN ('paid', 'delivery_failed')`,
    [orderId],
  );
  if ((claimed.changes ?? 0) !== 1) {
    return one('SELECT * FROM bailian_payment_orders WHERE id = ?', [orderId]);
  }
  order = one('SELECT * FROM bailian_payment_orders WHERE id = ?', [orderId]);
  const body = JSON.stringify({
    novelOrderId: order.id, gameOrderId: order.game_order_id,
    gameOpenId: order.game_open_id, productId: order.product_id,
    moneyCents: order.money_cents,
  });
  const timestamp = String(Date.now());
  const nonce = randomUUID();
  const signature = createHmac('sha256', config.bailianPaymentHmacSecret)
    .update(`${timestamp}\n${body}`).digest('hex');
  try {
    const response = await fetch(config.bailianPaymentFulfillmentUrl, {
      method: 'POST', body, signal: AbortSignal.timeout(config.bailianPaymentTimeoutMs),
      headers: {
        'content-type': 'application/json',
        'x-novel-timestamp': timestamp,
        'x-novel-nonce': nonce,
        'x-novel-signature': signature,
      },
    });
    if (!response.ok) throw new Error(`fulfillment_http_${response.status}`);
    run(
      `UPDATE bailian_payment_orders SET status = 'fulfilled', fulfilled_at = datetime('now'),
       last_error = '', updated_at = datetime('now') WHERE id = ? AND status = 'fulfilling'`,
      [orderId],
    );
  } catch (error) {
    const message = String(error?.message || 'fulfillment_failed').slice(0, 200);
    if (order.fulfillment_attempts >= config.bailianPaymentMaxAttempts) refundOrder(orderId, message);
    else run(
      `UPDATE bailian_payment_orders SET status = 'delivery_failed', last_error = ?,
       updated_at = datetime('now') WHERE id = ? AND status = 'fulfilling'`,
      [message, orderId],
    );
  }
  return one('SELECT * FROM bailian_payment_orders WHERE id = ?', [orderId]);
}

function refundOrder(orderId, reason) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const order = one("SELECT * FROM bailian_payment_orders WHERE id = ? AND status = 'fulfilling'", [orderId]);
    if (order) {
      run("UPDATE users SET sakura_coins = sakura_coins + ?, updated_at = datetime('now') WHERE id = ?", [order.coin_cost, order.user_id]);
      run(
        `INSERT INTO user_reward_events
          (user_id, action, coins_delta, description, related_type, related_id)
         VALUES (?, 'bailian_payment_refund', ?, '百练英雄充值发货失败退款', 'bailian_payment_order', ?)`,
        [order.user_id, order.coin_cost, order.id],
      );
      run(
        `UPDATE bailian_payment_orders SET status = 'refunded', refunded_at = datetime('now'),
         last_error = ?, updated_at = datetime('now') WHERE id = ?`,
        [reason, orderId],
      );
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
}

function getCatalog() {
  if (catalogCache) return catalogCache;
  const raw = config.bailianPaymentCatalogFile?.trim()
    ? fs.readFileSync(config.bailianPaymentCatalogFile, 'utf8')
    : config.bailianPaymentCatalogJson;
  const parsed = JSON.parse(raw || '[]');
  if (!Array.isArray(parsed)) throw new Error('BAILIAN payment catalog must be an array');
  const result = new Map();
  for (const item of parsed) {
    const productId = String(item.productId || '').trim();
    const productName = String(item.productName || item.name || '').trim();
    const moneyCents = Number(item.moneyCents);
    if (!productId || !productName || !Number.isSafeInteger(moneyCents) || moneyCents <= 0 || moneyCents % 10 !== 0 || result.has(productId)) {
      throw new Error(`Invalid or duplicate Bailian product: ${productId || '<empty>'}`);
    }
    result.set(productId, { productId, productName, moneyCents });
  }
  catalogCache = result;
  return result;
}

function requireProduct(productId) {
  const product = getCatalog().get(String(productId || '').trim());
  if (!product) throw paymentError('payment_product_not_found', 404);
  return product;
}

function cleanId(value, field) {
  const result = String(value || '').trim();
  if (!result || result.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(result)) throw paymentError(`invalid_${field}`, 400);
  return result;
}

export function paymentError(code, statusCode) {
  const error = new Error(code); error.code = code; error.statusCode = statusCode; return error;
}

function paymentJson(row) {
  const balance = Number(one('SELECT sakura_coins FROM users WHERE id = ?', [row.user_id])?.sakura_coins || 0);
  return {
    ...paymentJsonWithoutBalance(row),
    balance,
  };
}

function paymentJsonWithoutBalance(row) {
  return {
    gameOrderId: row.game_order_id,
    productId: row.product_id,
    productName: row.product_name,
    moneyCents: Number(row.money_cents),
    coinCost: Number(row.coin_cost),
    status: row.status,
    attempts: Number(row.fulfillment_attempts),
    createdAt: row.created_at,
    fulfilledAt: row.fulfilled_at || '',
    refundedAt: row.refunded_at || '',
  };
}

if (config.bailianPaymentCatalogFile?.trim() || config.bailianPaymentCatalogJson?.trim()) {
  getCatalog();
}
