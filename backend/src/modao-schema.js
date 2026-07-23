import { db } from './db.js';

let schemaReady = false;

export function ensureModaoGameSchema() {
  if (schemaReady) return;

  db.exec(`
    CREATE TABLE IF NOT EXISTS modao_game_account_links (
      novel_user_id INTEGER PRIMARY KEY,
      game_open_id TEXT NOT NULL UNIQUE,
      player_id TEXT NOT NULL DEFAULT '',
      server_id TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (novel_user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS modao_game_sso_tickets (
      ticket_hash TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL,
      game_open_id TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      consumed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_modao_game_sso_tickets_expiry
      ON modao_game_sso_tickets(expires_at, consumed_at);

    CREATE TABLE IF NOT EXISTS modao_payment_orders (
      id TEXT PRIMARY KEY,
      game_order_id TEXT NOT NULL UNIQUE,
      user_id INTEGER NOT NULL,
      game_open_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      product_name TEXT NOT NULL,
      money_cents INTEGER NOT NULL CHECK (money_cents > 0),
      coin_cost INTEGER NOT NULL CHECK (coin_cost > 0),
      idempotency_key TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'paid'
        CHECK (status IN ('paid', 'fulfilling', 'delivery_failed', 'fulfilled', 'refunded')),
      fulfillment_attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NOT NULL DEFAULT '',
      fulfilled_at TEXT,
      refunded_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
      UNIQUE(user_id, idempotency_key)
    );

    CREATE INDEX IF NOT EXISTS idx_modao_payment_orders_user
      ON modao_payment_orders(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_modao_payment_orders_delivery
      ON modao_payment_orders(status, updated_at);
  `);

  schemaReady = true;
}
