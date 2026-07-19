import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import { sanitizeRetiredVideoDatabase } from '../scripts/sanitize-retired-video-database.js';
import {
  managedUploadFolders,
  managedUploadKeyFromAnyUrl,
} from './upload-security.js';

test('sanitizes databases that contain managed upload expression indexes', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'retired-video-database-'));
  const databasePath = path.join(directory, 'interaction.sqlite');
  const database = openDatabase(databasePath);
  database.exec(`
    CREATE TABLE suibian_watch_history (user_id INTEGER, drama_id TEXT);
    CREATE TABLE suibian_likes (user_id INTEGER, drama_id TEXT);
    CREATE TABLE suibian_favorites (user_id INTEGER, drama_id TEXT);
    CREATE TABLE video_category_policies (source_key TEXT, category_id INTEGER);
    CREATE TABLE video_content_overrides (source_key TEXT, source_item_id TEXT);
    CREATE TABLE video_cover_urls (
      source_key TEXT NOT NULL,
      item_key TEXT NOT NULL,
      cover_url TEXT NOT NULL DEFAULT '',
      provider TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (source_key, item_key)
    );
    CREATE INDEX idx_managed_upload_ref_video_cover_urls_cover_url
      ON video_cover_urls(managed_upload_key(cover_url))
      WHERE managed_upload_key(cover_url) <> '';
    INSERT INTO video_cover_urls (source_key, item_key, cover_url, provider)
    VALUES
      ('dbzy', 'retired', '/novel-api/uploads/content/novel-covers/1-retired.png', 'dbzy'),
      ('wuhandky', 'active', '/novel-api/uploads/content/novel-covers/1-active.png', 'douban');
  `);
  database.close();

  try {
    const first = sanitizeRetiredVideoDatabase(databasePath);
    assert.deepEqual(first, {
      skipped: false,
      removedTables: 5,
      removedCovers: 1,
    });
    assert.deepEqual(sanitizeRetiredVideoDatabase(databasePath), {
      skipped: false,
      removedTables: 0,
      removedCovers: 0,
    });

    const verified = openDatabase(databasePath);
    try {
      for (const table of [
        'suibian_watch_history',
        'suibian_likes',
        'suibian_favorites',
        'video_category_policies',
        'video_content_overrides',
      ]) {
        assert.equal(
          verified
            .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
            .get(table),
          undefined,
        );
      }
      assert.deepEqual(
        verified
          .prepare('SELECT source_key, provider FROM video_cover_urls ORDER BY item_key')
          .all()
          .map((row) => ({
            source_key: row.source_key,
            provider: row.provider,
          })),
        [{ source_key: 'wuhandky', provider: 'douban' }],
      );
      assert.ok(
        verified
          .prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?")
          .get('idx_managed_upload_ref_video_cover_urls_cover_url'),
      );
    } finally {
      verified.close();
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

function openDatabase(file) {
  const database = new DatabaseSync(file);
  database.function(
    'managed_upload_key',
    { deterministic: true },
    (url) => managedUploadKeyFromAnyUrl({
      url,
      apiPrefix: '/novel-api',
      folders: managedUploadFolders,
    }) || '',
  );
  return database;
}
