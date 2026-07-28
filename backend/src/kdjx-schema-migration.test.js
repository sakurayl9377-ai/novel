import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-kdjx-schema-'));
process.env.NODE_ENV = 'test';
process.env.DB_PATH = path.join(tempDir, 'kdjx-schema.sqlite');
process.env.TOKEN_SECRET = 'kdjx-schema-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY = 'kdjx-schema-settings-secret';
process.env.ADMIN_USERNAME = 'kdjx-schema-admin';
process.env.ADMIN_PASSWORD = 'kdjx-schema-admin-password';

const { all, closeDb, db, migrate, one, run } = await import('./db.js');
const { ensureKdjxGameSchema } = await import('./kdjx-schema.js');

after(() => {
  closeDb();
  fs.rmSync(tempDir, { recursive: true, force: true });
});

test('KDJX GM delivery migration preserves rows and raises the limit to 9999', () => {
  migrate();
  const userId = Number(run(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES ('schema-player@example.test', 'schema-player', 'hash', 'user', 'active')`,
  ).lastInsertRowid);
  db.exec(`
    CREATE TABLE kdjx_gm_deliveries (
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
      quantity INTEGER NOT NULL CHECK (quantity > 0 AND quantity <= 999),
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
    CREATE INDEX idx_kdjx_gm_deliveries_time
      ON kdjx_gm_deliveries(created_at DESC, id DESC);
    CREATE INDEX idx_kdjx_gm_deliveries_user
      ON kdjx_gm_deliveries(user_id, created_at DESC, id DESC);
    CREATE INDEX idx_kdjx_gm_deliveries_status
      ON kdjx_gm_deliveries(status, created_at DESC, id DESC);
  `);
  run(
    `INSERT INTO kdjx_gm_deliveries
      (request_id, user_id, game_open_id, account_id, role_id, server_key,
       link_updated_at, delivery_type, item_id, item_name, quantity, reason,
       status, outcome_reference, completed_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'mail', '400', 'Trainer EXP', 999, ?,
             'succeeded', 'legacy-mail-1', datetime('now'))`,
    [
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      userId,
      'sakura_schema_player_01',
      '64a000000000000000000001',
      '64b000000000000000000001',
      'game.cn.1',
      '2026-07-29 00:00:00',
      'Preserve legacy delivery',
    ],
  );

  ensureKdjxGameSchema();
  ensureKdjxGameSchema();

  const row = one(
    `SELECT * FROM kdjx_gm_deliveries WHERE request_id = ?`,
    ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'],
  );
  assert.equal(row.quantity, 999);
  assert.equal(row.outcome_reference, 'legacy-mail-1');
  assert.equal(row.status, 'succeeded');

  const tableSql = String(one(
    `SELECT sql FROM sqlite_master
     WHERE type = 'table' AND name = 'kdjx_gm_deliveries'`,
  ).sql);
  assert.match(tableSql, /quantity\s*<=\s*9999\b/i);
  assert.doesNotMatch(tableSql, /quantity\s*<=\s*999\b/i);
  assert.doesNotThrow(() => run(
    'UPDATE kdjx_gm_deliveries SET quantity = 9999 WHERE id = ?',
    [row.id],
  ));
  assert.throws(
    () => run(
      'UPDATE kdjx_gm_deliveries SET quantity = 10000 WHERE id = ?',
      [row.id],
    ),
    /constraint/i,
  );
  assert.deepEqual(
    new Set(all(`PRAGMA index_list('kdjx_gm_deliveries')`).map((item) => item.name)),
    new Set([
      'sqlite_autoindex_kdjx_gm_deliveries_1',
      'idx_kdjx_gm_deliveries_time',
      'idx_kdjx_gm_deliveries_user',
      'idx_kdjx_gm_deliveries_status',
    ]),
  );
  assert.deepEqual(all('PRAGMA foreign_key_check(kdjx_gm_deliveries)'), []);
});
