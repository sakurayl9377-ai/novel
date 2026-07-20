import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-notification-migration-"));
process.env.DB_PATH = path.join(tempDir, "migration.sqlite");
process.env.TOKEN_SECRET = "notification-migration-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "notification-migration-settings-secret";
process.env.ADMIN_USERNAME = "admin";
process.env.ADMIN_PASSWORD = "admin123456";

const legacyDb = new DatabaseSync(process.env.DB_PATH);
legacyDb.exec(`
  PRAGMA foreign_keys = ON;
  CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    nickname TEXT NOT NULL,
    avatar_url TEXT NOT NULL DEFAULT '',
    gender TEXT NOT NULL DEFAULT 'private',
    bio TEXT NOT NULL DEFAULT '',
    signature TEXT NOT NULL DEFAULT '',
    space_title TEXT NOT NULL DEFAULT '',
    profile_banner_url TEXT NOT NULL DEFAULT '',
    dynamic_avatar_url TEXT NOT NULL DEFAULT '',
    profile_theme TEXT NOT NULL DEFAULT 'sakura',
    privacy_mode INTEGER NOT NULL DEFAULT 0,
    points INTEGER NOT NULL DEFAULT 0,
    sakura_coins INTEGER NOT NULL DEFAULT 0,
    level INTEGER NOT NULL DEFAULT 0,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_login_at TEXT
  );
  INSERT INTO users (id, email, nickname, password_hash, role, status)
  VALUES (1, 'legacy-admin@example.com', 'Legacy admin', 'legacy-hash', 'admin', 'active');

  CREATE TABLE app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    is_secret INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  INSERT INTO app_settings (key, value, updated_at) VALUES
    ('app_announcement.enabled', 'true', '2026-01-03 04:05:06'),
    ('app_announcement.title', '公告', '2026-01-03 04:05:06'),
    ('app_announcement.content', '欢迎来到二次元的世界', '2026-01-03 04:05:06'),
    ('app_announcement.version', 'legacy-announcement-v1', '2026-01-03 04:05:06');

  CREATE TABLE system_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'system',
    read_at TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );
  CREATE INDEX idx_system_notifications_user
    ON system_notifications(user_id, read_at, created_at);
  INSERT INTO system_notifications (id, user_id, title, content)
  VALUES (10, 1, 'Legacy notice', 'Keep this delivery');

  CREATE TABLE admin_broadcasts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    admin_user_id INTEGER,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'system',
    recipient_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL
  );
  CREATE INDEX idx_admin_broadcasts_time ON admin_broadcasts(created_at);
  INSERT INTO admin_broadcasts
    (id, admin_user_id, title, content, recipient_count, created_at)
  VALUES
    (20, 1, 'Legacy broadcast', 'Keep this broadcast', 1, '2026-01-02 03:04:05');
`);
legacyDb.close();

const { closeDb, migrate, one } = await import("./db.js");

test("notification migration upgrades the production legacy schema safely", () => {
  try {
    assert.doesNotThrow(() => migrate());
    assert.doesNotThrow(() => migrate(), "notification migration must be idempotent");

    const delivery = one("SELECT * FROM system_notifications WHERE id = 10");
    assert.equal(delivery.title, "Legacy notice");
    assert.equal(delivery.broadcast_id, null);

    const broadcast = one("SELECT * FROM admin_broadcasts WHERE id = 20");
    assert.equal(broadcast.status, "sent");
    assert.equal(broadcast.delivered_count, 1);
    assert.equal(broadcast.preview_count, 1);
    assert.deepEqual(JSON.parse(broadcast.audience_json), {
      scope: "all_active",
      legacy: true,
    });
    assert.equal(broadcast.sent_at, "2026-01-02 03:04:05");
    assert.equal(broadcast.updated_at, "2026-01-02 03:04:05");

    const announcement = one(
      "SELECT * FROM app_announcement_revisions ORDER BY id LIMIT 1",
    );
    assert.equal(announcement.version, "legacy-announcement-v1");
    assert.equal(announcement.title, "公告");
    assert.equal(announcement.content, "欢迎来到二次元的世界");
    assert.equal(announcement.enabled, 1);
    assert.equal(announcement.created_at, "2026-01-03 04:05:06");

    for (const indexName of [
      "idx_system_notifications_broadcast",
      "idx_system_notifications_broadcast_user",
      "idx_admin_broadcasts_status",
    ]) {
      assert.ok(
        one(
          `SELECT 1 AS present
           FROM sqlite_master
           WHERE type = 'index' AND name = ?`,
          [indexName],
        ),
        `${indexName} must be created after its columns are available`,
      );
    }
  } finally {
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
