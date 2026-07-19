#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

import {
  managedUploadFolders,
  managedUploadKeyFromAnyUrl,
} from '../src/upload-security.js';

const apiPrefix = process.env.API_PREFIX || '/novel-api';
const retiredTables = [
  'suibian_watch_history',
  'suibian_likes',
  'suibian_favorites',
  'video_category_policies',
  'video_content_overrides',
];

export function sanitizeRetiredVideoDatabase(file) {
  const target = path.resolve(file);
  if (!fs.existsSync(target)) {
    return { skipped: true, removedTables: 0, removedCovers: 0 };
  }

  const database = new DatabaseSync(target);
  database.function(
    'managed_upload_key',
    { deterministic: true },
    (url) => managedUploadKeyFromAnyUrl({
      url,
      apiPrefix,
      folders: managedUploadFolders,
    }) || '',
  );
  database.exec('PRAGMA busy_timeout = 10000; PRAGMA foreign_keys = OFF');

  let transactionStarted = false;
  try {
    const existingTables = new Set(
      database
        .prepare(
          `SELECT name FROM sqlite_master
           WHERE type = 'table' AND name IN (${retiredTables.map(() => '?').join(', ')})`,
        )
        .all(...retiredTables)
        .map((row) => row.name),
    );
    const videoCoverTable = database
      .prepare(
        `SELECT 1 AS present FROM sqlite_master
         WHERE type = 'table' AND name = 'video_cover_urls'`,
      )
      .get();

    database.exec('BEGIN IMMEDIATE');
    transactionStarted = true;
    for (const table of retiredTables) {
      database.exec(`DROP TABLE IF EXISTS ${table}`);
    }
    const removedCovers = videoCoverTable
      ? Number(
          database
            .prepare(
              `DELETE FROM video_cover_urls
               WHERE lower(trim(provider)) = 'dbzy'
                  OR lower(trim(source_key)) = 'dbzy'`,
            )
            .run().changes,
        )
      : 0;
    database.exec('COMMIT');
    transactionStarted = false;
    return {
      skipped: false,
      removedTables: existingTables.size,
      removedCovers,
    };
  } catch (error) {
    if (transactionStarted) database.exec('ROLLBACK');
    throw error;
  } finally {
    database.close();
  }
}

function sanitizeFiles(files) {
  let sanitized = 0;
  let skipped = 0;
  let removedTables = 0;
  let removedCovers = 0;
  for (const file of files) {
    const result = sanitizeRetiredVideoDatabase(file);
    if (result.skipped) skipped += 1;
    else sanitized += 1;
    removedTables += result.removedTables;
    removedCovers += result.removedCovers;
  }
  process.stdout.write([
    `retired_video_databases_sanitized=${sanitized}`,
    `retired_video_databases_skipped=${skipped}`,
    `retired_video_tables_removed=${removedTables}`,
    `retired_video_covers_removed=${removedCovers}`,
    '',
  ].join('\n'));
}

const isMain = process.argv[1]
  ? fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
  : false;

if (isMain) {
  const files = process.argv.slice(2);
  if (files.length === 0) throw new Error('database path is required');
  sanitizeFiles(files);
}
