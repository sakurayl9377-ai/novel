import { db } from './db.js';

let schemaReady = false;

export function ensureKdjxGameSchema() {
  if (schemaReady) return;

  db.exec(`
    DROP TABLE IF EXISTS kdjx_game_sso_tickets;

    CREATE TABLE IF NOT EXISTS kdjx_game_account_links (
      novel_user_id INTEGER PRIMARY KEY,
      game_open_id TEXT NOT NULL UNIQUE,
      account_password_cipher TEXT NOT NULL,
      game_account_id TEXT NOT NULL DEFAULT '',
      last_role_id TEXT NOT NULL DEFAULT '',
      last_server_key TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (novel_user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS kdjx_game_sessions (
      id TEXT PRIMARY KEY,
      token_hash TEXT NOT NULL UNIQUE,
      user_id INTEGER NOT NULL,
      game_open_id TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      last_used_at TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_game_sessions_user
      ON kdjx_game_sessions(user_id, revoked_at, expires_at);
    CREATE INDEX IF NOT EXISTS idx_kdjx_game_sessions_expiry
      ON kdjx_game_sessions(expires_at, revoked_at);

    CREATE TABLE IF NOT EXISTS kdjx_game_login_tickets (
      ticket_hash TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      consumed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (session_id) REFERENCES kdjx_game_sessions(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_game_login_tickets_session
      ON kdjx_game_login_tickets(session_id, consumed_at);
    CREATE INDEX IF NOT EXISTS idx_kdjx_game_login_tickets_expiry
      ON kdjx_game_login_tickets(expires_at, consumed_at);

    CREATE TABLE IF NOT EXISTS kdjx_device_authorizations (
      device_code_hash TEXT PRIMARY KEY,
      user_code_hash TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'denied', 'consumed')),
      user_id INTEGER,
      poll_interval_seconds INTEGER NOT NULL CHECK (poll_interval_seconds > 0),
      expires_at TEXT NOT NULL,
      last_polled_at TEXT,
      approved_at TEXT,
      denied_at TEXT,
      consumed_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_device_authorizations_expiry
      ON kdjx_device_authorizations(expires_at, status);

    CREATE TABLE IF NOT EXISTS kdjx_payment_orders (
      id TEXT PRIMARY KEY,
      game_order_id TEXT NOT NULL UNIQUE,
      channel_order_id TEXT NOT NULL UNIQUE,
      user_id INTEGER NOT NULL,
      game_open_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      role_id TEXT NOT NULL,
      server_key TEXT NOT NULL,
      product_id TEXT NOT NULL,
      product_name TEXT NOT NULL,
      recharge_id INTEGER NOT NULL CHECK (recharge_id > 0),
      yy_id INTEGER NOT NULL DEFAULT 0 CHECK (yy_id >= 0),
      csv_id INTEGER NOT NULL DEFAULT 0 CHECK (csv_id >= 0),
      money_cents INTEGER NOT NULL CHECK (money_cents > 0),
      coin_cost INTEGER NOT NULL CHECK (coin_cost > 0),
      idempotency_key TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'paid'
        CHECK (status IN (
          'paid', 'fulfilling', 'delivery_failed', 'fulfilled'
        )),
      fulfillment_attempts INTEGER NOT NULL DEFAULT 0,
      fulfillment_reference TEXT NOT NULL DEFAULT '',
      last_error TEXT NOT NULL DEFAULT '',
      fulfilled_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
      UNIQUE(user_id, idempotency_key)
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_payment_orders_user
      ON kdjx_payment_orders(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_kdjx_payment_orders_delivery
      ON kdjx_payment_orders(status, updated_at);
  `);

  schemaReady = true;
}
