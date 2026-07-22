import { all, one } from "./db.js";
import { badRequest } from "./validators.js";

export function listUserOrders(userId, query = {}) {
  const limit = boundedInteger(query.limit, 20, 1, 50);
  const offset = nonNegativeInteger(query.offset, 0, "offset");
  const snapshotMaxId = eventSnapshotMaxId({
    userId,
    requested: query.snapshotMaxId ?? query.maxId,
    where: "coins_delta < 0",
  });
  const total = Number(one(
    `SELECT COUNT(*) AS total FROM user_reward_events
     WHERE user_id = ? AND coins_delta < 0 AND id <= ?`,
    [userId, snapshotMaxId],
  )?.total || 0);
  const rows = all(
    `SELECT e.id, e.action, e.coins_delta, e.description, e.related_type,
            e.related_id, e.created_at,
            p.product_id, p.product_name, p.money_cents, p.status
       FROM user_reward_events e
       LEFT JOIN bailian_payment_orders p
         ON e.related_type = 'bailian_payment_order'
        AND p.id = e.related_id
      WHERE e.user_id = ? AND e.coins_delta < 0 AND e.id <= ?
      ORDER BY e.id DESC
      LIMIT ? OFFSET ?`,
    [userId, snapshotMaxId, limit + 1, offset],
  );
  const hasMore = rows.length > limit;
  return {
    items: rows.slice(0, limit).map(orderJson),
    hasMore,
    total,
    nextOffset: offset + Math.min(rows.length, limit),
    snapshotMaxId,
  };
}

export function listUserWallet(userId, query = {}) {
  const page = positiveInteger(query.page, 1, "page");
  const pageSize = boundedInteger(query.pageSize, 20, 1, 50);
  const offset = (page - 1) * pageSize;
  if (!Number.isSafeInteger(offset)) throw badRequest("wallet page is invalid");
  const snapshotMaxId = eventSnapshotMaxId({
    userId,
    requested: query.snapshotMaxId ?? query.maxId,
    where: "coins_delta <> 0",
  });
  const ledgerTotal = Number(one(
    `SELECT COUNT(*) AS total FROM user_reward_events
     WHERE user_id = ? AND coins_delta <> 0 AND id <= ?`,
    [userId, snapshotMaxId],
  )?.total || 0);
  const ledgerItems = all(
    `SELECT id, action, points_delta, coins_delta, description,
            related_type, related_id, created_at
       FROM user_reward_events
      WHERE user_id = ? AND coins_delta <> 0 AND id <= ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?`,
    [userId, snapshotMaxId, pageSize, offset],
  ).map((row) => ({
    id: String(row.id),
    action: row.action,
    pointsDelta: Number(row.points_delta || 0),
    coinsDelta: Number(row.coins_delta || 0),
    description: row.description || "",
    relatedType: row.related_type || "",
    relatedId: row.related_id || "",
    createdAt: utcIso(row.created_at),
  }));
  const orderPage = listUserOrders(userId, {
    limit: pageSize,
    offset,
    snapshotMaxId,
  });
  return {
    balance: Number(one("SELECT sakura_coins FROM users WHERE id = ?", [userId])?.sakura_coins || 0),
    snapshotMaxId,
    ledger: {
      page,
      pageSize,
      total: ledgerTotal,
      hasMore: offset + ledgerItems.length < ledgerTotal,
      snapshotMaxId,
      items: ledgerItems,
    },
    orders: {
      page,
      pageSize,
      total: orderPage.total,
      hasMore: orderPage.hasMore,
      snapshotMaxId: orderPage.snapshotMaxId,
      items: orderPage.items,
    },
  };
}

function orderJson(row) {
  const isBailian = row.related_type === "bailian_payment_order";
  return {
    id: String(row.id),
    action: row.action,
    title: row.product_name || row.description || "樱花币消费",
    coinCost: Math.max(0, -Number(row.coins_delta || 0)),
    source: isBailian ? "bailian" : sourceFor(row.action),
    status: isBailian ? row.status || "paid" : "completed",
    createdAt: utcIso(row.created_at),
    relatedType: row.related_type || "",
    relatedId: row.related_id || "",
    productId: row.product_id || "",
    productName: row.product_name || "",
    moneyCents: row.money_cents == null ? null : Number(row.money_cents),
  };
}

function sourceFor(action) {
  if (action === "shop_redeem") return "shop";
  if (action === "horse_race_bet") return "horse_race";
  return "other";
}

function boundedInteger(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
}

function positiveInteger(value, fallback, name) {
  if (value == null || String(value).trim() === "") return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw badRequest(`${name} is invalid`);
  return parsed;
}

function nonNegativeInteger(value, fallback, name) {
  if (value == null || String(value).trim() === "") return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw badRequest(`${name} is invalid`);
  return parsed;
}

function eventSnapshotMaxId({ userId, requested, where }) {
  const currentMaxId = Number(one(
    `SELECT COALESCE(MAX(id), 0) AS max_id FROM user_reward_events
     WHERE user_id = ? AND ${where}`,
    [userId],
  )?.max_id || 0);
  if (requested == null || String(requested).trim() === "") return currentMaxId;
  const parsed = Number(requested);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw badRequest("snapshotMaxId is invalid");
  }
  return Math.min(parsed, currentMaxId);
}

function utcIso(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  const normalized = /(?:[zZ]|[+-]\d\d:\d\d)$/.test(text)
    ? text
    : `${text.replace(" ", "T")}Z`;
  const parsed = new Date(normalized);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : text;
}
