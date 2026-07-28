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

    CREATE TABLE IF NOT EXISTS kdjx_gm_action_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      admin_user_id INTEGER,
      action TEXT NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      reason TEXT NOT NULL,
      result TEXT NOT NULL CHECK (result IN ('pending', 'success', 'failed')),
      error_code TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_gm_action_logs_time
      ON kdjx_gm_action_logs(created_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS idx_kdjx_gm_action_logs_target
      ON kdjx_gm_action_logs(target_type, target_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS kdjx_gm_deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id TEXT NOT NULL UNIQUE,
      admin_user_id INTEGER,
      user_id INTEGER NOT NULL,
      game_open_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      role_id TEXT NOT NULL,
      server_key TEXT NOT NULL,
      link_updated_at TEXT NOT NULL,
      delivery_type TEXT NOT NULL
        CHECK (delivery_type = 'mail'),
      item_id TEXT NOT NULL,
      item_name TEXT NOT NULL,
      item_type TEXT NOT NULL DEFAULT '',
      item_quality TEXT NOT NULL DEFAULT '',
      quantity INTEGER NOT NULL CHECK (quantity > 0 AND quantity <= 9999),
      reason TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'succeeded', 'failed', 'unknown')),
      outcome_reference TEXT NOT NULL DEFAULT '',
      error_code TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      completed_at TEXT,
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
    );

    CREATE INDEX IF NOT EXISTS idx_kdjx_gm_deliveries_time
      ON kdjx_gm_deliveries(created_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS idx_kdjx_gm_deliveries_user
      ON kdjx_gm_deliveries(user_id, created_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS idx_kdjx_gm_deliveries_status
      ON kdjx_gm_deliveries(status, created_at DESC, id DESC);
  `);

  migrateKdjxGmDeliveryQuantityLimit();

  schemaReady = true;
}

function migrateKdjxGmDeliveryQuantityLimit() {
  const table = db.prepare(
    `SELECT sql FROM sqlite_master
     WHERE type = 'table' AND name = 'kdjx_gm_deliveries'`,
  ).get();
  if (!/quantity\s*<=\s*999\b/i.test(String(table?.sql || ''))) return;

  db.exec('BEGIN IMMEDIATE');
  try {
    db.exec(`
      DROP TABLE IF EXISTS kdjx_gm_deliveries_v2;
      CREATE TABLE kdjx_gm_deliveries_v2 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id TEXT NOT NULL UNIQUE,
        admin_user_id INTEGER,
        user_id INTEGER NOT NULL,
        game_open_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        role_id TEXT NOT NULL,
        server_key TEXT NOT NULL,
        link_updated_at TEXT NOT NULL,
        delivery_type TEXT NOT NULL CHECK (delivery_type = 'mail'),
        item_id TEXT NOT NULL,
        item_name TEXT NOT NULL,
        item_type TEXT NOT NULL DEFAULT '',
        item_quality TEXT NOT NULL DEFAULT '',
        quantity INTEGER NOT NULL CHECK (quantity > 0 AND quantity <= 9999),
        reason TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'succeeded', 'failed', 'unknown')),
        outcome_reference TEXT NOT NULL DEFAULT '',
        error_code TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        completed_at TEXT,
        FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
      );

      INSERT INTO kdjx_gm_deliveries_v2
        (id, request_id, admin_user_id, user_id, game_open_id, account_id,
         role_id, server_key, link_updated_at, delivery_type, item_id,
         item_name, item_type, item_quality, quantity, reason, status,
         outcome_reference, error_code, created_at, updated_at, completed_at)
      SELECT id, request_id, admin_user_id, user_id, game_open_id, account_id,
             role_id, server_key, link_updated_at, delivery_type, item_id,
             item_name, item_type, item_quality, quantity, reason, status,
             outcome_reference, error_code, created_at, updated_at, completed_at
        FROM kdjx_gm_deliveries;

      DROP TABLE kdjx_gm_deliveries;
      ALTER TABLE kdjx_gm_deliveries_v2 RENAME TO kdjx_gm_deliveries;

      CREATE INDEX idx_kdjx_gm_deliveries_time
        ON kdjx_gm_deliveries(created_at DESC, id DESC);
      CREATE INDEX idx_kdjx_gm_deliveries_user
        ON kdjx_gm_deliveries(user_id, created_at DESC, id DESC);
      CREATE INDEX idx_kdjx_gm_deliveries_status
        ON kdjx_gm_deliveries(status, created_at DESC, id DESC);
    `);
    const foreignKeyViolation = db.prepare(
      'PRAGMA foreign_key_check(kdjx_gm_deliveries)',
    ).get();
    if (foreignKeyViolation) {
      throw new Error('KDJX GM delivery migration failed foreign key check');
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
}
