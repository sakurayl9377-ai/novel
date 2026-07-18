import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { config } from './config.js';
import { all, migrate, one, run } from './db.js';

test('removes retired Suibian and DBZY server data', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'retired-video-'));
  const originalCoverDir = config.videoCoverDir;
  const originalDbzyCacheFile = process.env.DBZY_CACHE_FILE;
  const originalCatalogFile = process.env.SUIBIAN_CATALOG_FILE;
  config.videoCoverDir = path.join(directory, 'video-covers');
  process.env.DBZY_CACHE_FILE = path.join(directory, 'dbzy-cache.json');
  process.env.SUIBIAN_CATALOG_FILE = path.join(directory, 'suibian-catalog.json');
  t.after(() => {
    config.videoCoverDir = originalCoverDir;
    restoreEnv('DBZY_CACHE_FILE', originalDbzyCacheFile);
    restoreEnv('SUIBIAN_CATALOG_FILE', originalCatalogFile);
    fs.rmSync(directory, { recursive: true, force: true });
  });

  migrate();
  run('CREATE TABLE suibian_favorites (user_id INTEGER, drama_id TEXT)');
  run('CREATE TABLE suibian_likes (user_id INTEGER, drama_id TEXT)');
  run('CREATE TABLE suibian_watch_history (user_id INTEGER, drama_id TEXT)');
  run('CREATE TABLE video_content_overrides (source_key TEXT, source_item_id TEXT)');
  run('CREATE TABLE video_category_policies (source_key TEXT, category_id INTEGER)');
  run(`CREATE TABLE IF NOT EXISTS video_cover_urls (
    source_key TEXT NOT NULL,
    item_key TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    year TEXT NOT NULL DEFAULT '',
    cover_url TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    matched_title TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (source_key, item_key)
  )`);

  const exclusiveName = `${'a'.repeat(64)}.jpg`;
  const sharedName = `${'b'.repeat(64)}.webp`;
  const exclusiveUrl = `/video-covers/files/${exclusiveName}`;
  const sharedUrl = `/video-covers/files/${sharedName}`;
  fs.mkdirSync(config.videoCoverDir, { recursive: true });
  fs.writeFileSync(path.join(config.videoCoverDir, exclusiveName), 'dbzy');
  fs.writeFileSync(path.join(config.videoCoverDir, sharedName), 'shared');
  fs.writeFileSync(process.env.DBZY_CACHE_FILE, '{}');
  fs.writeFileSync(process.env.SUIBIAN_CATALOG_FILE, '{}');

  run(
    `INSERT INTO video_cover_urls (source_key, item_key, cover_url, provider)
     VALUES ('wuhandky', 'exclusive', ?, 'dbzy')`,
    [exclusiveUrl],
  );
  run(
    `INSERT INTO video_cover_urls (source_key, item_key, cover_url, provider)
     VALUES ('wuhandky', 'shared-dbzy', ?, 'dbzy')`,
    [sharedUrl],
  );
  run(
    `INSERT INTO video_cover_urls (source_key, item_key, cover_url, provider)
     VALUES ('wuhandky', 'shared-douban', ?, 'douban')`,
    [sharedUrl],
  );

  migrate();

  for (const table of [
    'suibian_favorites',
    'suibian_likes',
    'suibian_watch_history',
    'video_content_overrides',
    'video_category_policies',
  ]) {
    assert.equal(
      one("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table]),
      undefined,
    );
  }
  assert.deepEqual(
    all('SELECT provider FROM video_cover_urls ORDER BY provider').map(
      (row) => row.provider,
    ),
    ['douban'],
  );
  assert.equal(fs.existsSync(path.join(config.videoCoverDir, exclusiveName)), false);
  assert.equal(fs.existsSync(path.join(config.videoCoverDir, sharedName)), true);
  assert.equal(fs.existsSync(process.env.DBZY_CACHE_FILE), false);
  assert.equal(fs.existsSync(process.env.SUIBIAN_CATALOG_FILE), false);
});

function restoreEnv(name, value) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
