import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "novel-ai-migration-"));
process.env.DB_PATH = path.join(tempDir, "migration.sqlite");
process.env.TOKEN_SECRET = "ai-migration-test-secret";
process.env.SETTINGS_ENCRYPTION_KEY = "ai-migration-settings-secret";
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
  INSERT INTO users (email, nickname, password_hash, role, status)
  VALUES ('legacy-writer@example.com', '旧版作者', 'legacy-hash', 'user', 'active');

  CREATE TABLE ai_novels (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    pen_name TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'AI原创',
    cover_url TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    review_note TEXT NOT NULL DEFAULT '',
    reviewed_by INTEGER,
    reviewed_at TEXT NOT NULL DEFAULT '',
    published_at TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CHECK (status IN ('pending', 'published', 'rejected'))
  );
  INSERT INTO ai_novels
    (user_id, title, pen_name, category, description, status)
  VALUES (1, '旧版投稿', '旧版作者', '科幻', '迁移前提交的作品', 'pending');

  CREATE TABLE ai_novel_chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    novel_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    review_note TEXT NOT NULL DEFAULT '',
    reviewed_by INTEGER,
    reviewed_at TEXT NOT NULL DEFAULT '',
    published_at TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (novel_id, sort_order),
    FOREIGN KEY (novel_id) REFERENCES ai_novels(id) ON DELETE CASCADE,
    CHECK (status IN ('pending', 'published', 'rejected'))
  );
  INSERT INTO ai_novel_chapters
    (novel_id, title, content, sort_order, status)
  VALUES (1, '第一章', '迁移前正文', 0, 'pending');
`);
legacyDb.close();

const { closeDb, migrate, one, run } = await import("./db.js");

test("AI novel migration preserves legacy submissions and enables drafts", () => {
  try {
    migrate();

    const migrated = one("SELECT * FROM ai_novels WHERE title = '旧版投稿'");
    assert.equal(migrated.status, "pending");
    assert.equal(migrated.revision, 1);
    assert.equal(migrated.serialization_status, "ongoing");
    assert.ok(migrated.submitted_at);
    assert.equal(
      one("SELECT content FROM ai_novel_chapters WHERE novel_id = ?", [migrated.id])
        .content,
      "迁移前正文",
    );
    assert.doesNotThrow(() =>
      run(
        `INSERT INTO ai_novels
           (user_id, title, pen_name, category, description, status)
         VALUES (1, '迁移后草稿', '旧版作者', '科幻', '', 'draft')`,
      ),
    );
    assert.ok(
      one(
        `SELECT 1 AS present
         FROM sqlite_master
         WHERE type = 'table' AND name = 'ai_novel_review_events'`,
      ),
    );
    assert.ok(
      one(
        `SELECT 1 AS present
         FROM sqlite_master
         WHERE type = 'trigger'
           AND name = 'trg_active_upload_ai_novels_cover_url_retirement'`,
      ),
      "managed upload reference trigger must be rebuilt after table migration",
    );
    assert.ok(
      one(
        `SELECT 1 AS present
         FROM pragma_table_info('ai_novel_chapters')
         WHERE name = 'replaces_chapter_id'`,
      ),
      "chapter revision linkage must be added to legacy databases",
    );
    assert.ok(
      one(
        `SELECT 1 AS present
         FROM sqlite_master
         WHERE type = 'index' AND name = 'idx_ai_novel_chapter_active_revision'`,
      ),
      "only one active revision may exist for each published chapter",
    );
  } finally {
    closeDb();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
