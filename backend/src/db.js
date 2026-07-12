import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { config } from "./config.js";
import { hashPassword } from "./security.js";
import {
  encryptSettingSecret,
  isEncryptedSettingSecret,
} from "./settings-secrets.js";

fs.mkdirSync(path.dirname(config.dbPath), { recursive: true });

export const db = new DatabaseSync(config.dbPath);
db.exec("PRAGMA journal_mode = WAL");
db.exec("PRAGMA foreign_keys = ON");

export function migrate() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
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

    CREATE TABLE IF NOT EXISTS auth_tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      revoked_at TEXT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS image_captchas (
      id TEXT PRIMARY KEY,
      answer_hash TEXT NOT NULL,
      ip TEXT NOT NULL,
      user_agent TEXT NOT NULL DEFAULT '',
      expires_at TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      used_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS email_verifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT NOT NULL,
      code_hash TEXT NOT NULL,
      purpose TEXT NOT NULL,
      ip TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      verified_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      parent_id INTEGER,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL DEFAULT '',
      episode_id TEXT NOT NULL DEFAULT '',
      rating INTEGER,
      content TEXT NOT NULL,
      like_count INTEGER NOT NULL DEFAULT 0,
      reply_count INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'visible',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      deleted_at TEXT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (parent_id) REFERENCES comments(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_comments_target
      ON comments(target_type, target_id, chapter_id, episode_id, parent_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_comments_user
      ON comments(user_id, created_at);

    CREATE TABLE IF NOT EXISTS comment_target_meta (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      target_title TEXT NOT NULL DEFAULT '',
      chapter_id TEXT NOT NULL DEFAULT '',
      chapter_title TEXT NOT NULL DEFAULT '',
      episode_id TEXT NOT NULL DEFAULT '',
      episode_title TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (target_type, target_id, chapter_id, episode_id)
    );

    CREATE INDEX IF NOT EXISTS idx_comment_meta_target
      ON comment_target_meta(target_type, target_title, target_id);

    CREATE TABLE IF NOT EXISTS danmaku (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      video_id TEXT NOT NULL,
      anime_id TEXT NOT NULL DEFAULT '',
      episode_id TEXT NOT NULL DEFAULT '',
      time_ms INTEGER NOT NULL,
      content TEXT NOT NULL,
      color TEXT NOT NULL DEFAULT '#FFFFFF',
      mode TEXT NOT NULL DEFAULT 'scroll',
      status TEXT NOT NULL DEFAULT 'visible',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      deleted_at TEXT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_danmaku_video_time
      ON danmaku(video_id, time_ms, created_at);

    CREATE TABLE IF NOT EXISTS danmaku_video_aliases (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      alias_video_id TEXT NOT NULL UNIQUE,
      canonical_video_id TEXT NOT NULL,
      anime_id TEXT NOT NULL DEFAULT '',
      episode_id TEXT NOT NULL DEFAULT '',
      source_name TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_danmaku_alias_canonical
      ON danmaku_video_aliases(canonical_video_id);
    CREATE INDEX IF NOT EXISTS idx_danmaku_alias_episode
      ON danmaku_video_aliases(anime_id, episode_id);

    CREATE TABLE IF NOT EXISTS danmaku_episode_meta (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      canonical_video_id TEXT NOT NULL UNIQUE,
      anime_id TEXT NOT NULL DEFAULT '',
      anime_title TEXT NOT NULL DEFAULT '',
      episode_id TEXT NOT NULL DEFAULT '',
      episode_title TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_danmaku_meta_anime
      ON danmaku_episode_meta(anime_id, anime_title);
    CREATE INDEX IF NOT EXISTS idx_danmaku_meta_episode
      ON danmaku_episode_meta(episode_id, episode_title);

    CREATE TABLE IF NOT EXISTS chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      room_id TEXT NOT NULL,
      user_id INTEGER NOT NULL,
      type TEXT NOT NULL DEFAULT 'text',
      content TEXT NOT NULL,
      media_url TEXT NOT NULL DEFAULT '',
      metadata TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'visible',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      deleted_at TEXT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_chat_room_time
      ON chat_messages(room_id, created_at);

    CREATE TABLE IF NOT EXISTS chat_rooms (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      avatar_url TEXT NOT NULL DEFAULT '',
      min_level INTEGER NOT NULL DEFAULT 1,
      category TEXT NOT NULL DEFAULT 'novel',
      is_official INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active',
      owner_id INTEGER,
      bot_enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS chat_room_members (
      room_id TEXT NOT NULL,
      user_id INTEGER NOT NULL,
      role TEXT NOT NULL DEFAULT 'member',
      joined_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_seen_at TEXT NOT NULL DEFAULT '',
      last_read_at TEXT NOT NULL DEFAULT '',
      last_read_message_id INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (room_id, user_id),
      FOREIGN KEY (room_id) REFERENCES chat_rooms(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS private_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sender_id INTEGER NOT NULL,
      receiver_id INTEGER NOT NULL,
      content TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'visible',
      read_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (receiver_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_private_messages_pair
      ON private_messages(sender_id, receiver_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_private_messages_receiver
      ON private_messages(receiver_id, read_at, created_at);

    CREATE TABLE IF NOT EXISTS chat_bot_direct_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      sender TEXT NOT NULL DEFAULT 'bot',
      content TEXT NOT NULL,
      metadata TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_chat_bot_direct_user
      ON chat_bot_direct_messages(user_id, id);

    CREATE TABLE IF NOT EXISTS system_notifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'system',
      read_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_system_notifications_user
      ON system_notifications(user_id, read_at, created_at);

    CREATE TABLE IF NOT EXISTS user_follows (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      follower_id INTEGER NOT NULL,
      following_id INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (follower_id, following_id),
      FOREIGN KEY (follower_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (following_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_user_follows_follower
      ON user_follows(follower_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_user_follows_following
      ON user_follows(following_id, created_at);

    CREATE TABLE IF NOT EXISTS user_reward_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      action TEXT NOT NULL,
      points_delta INTEGER NOT NULL DEFAULT 0,
      coins_delta INTEGER NOT NULL DEFAULT 0,
      description TEXT NOT NULL DEFAULT '',
      related_type TEXT NOT NULL DEFAULT '',
      related_id TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_user_reward_events_user
      ON user_reward_events(user_id, action, created_at);

    CREATE TABLE IF NOT EXISTS horse_race_rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      status TEXT NOT NULL DEFAULT 'betting',
      seed TEXT NOT NULL DEFAULT '',
      round_key TEXT NOT NULL DEFAULT '',
      rules_version INTEGER NOT NULL DEFAULT 2,
      horses_json TEXT NOT NULL DEFAULT '[]',
      odds_json TEXT NOT NULL DEFAULT '[]',
      race_json TEXT NOT NULL DEFAULT '{}',
      result_json TEXT NOT NULL DEFAULT '{}',
      winner_index INTEGER NOT NULL DEFAULT 0,
      phase_started_at INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      locked_at TEXT NOT NULL DEFAULT '',
      settled_at TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE IF NOT EXISTS horse_race_bets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      round_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      horse_index INTEGER NOT NULL,
      amount INTEGER NOT NULL,
      odds REAL NOT NULL DEFAULT 0,
      payout INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(round_id, user_id, horse_index),
      FOREIGN KEY (round_id) REFERENCES horse_race_rounds(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_horse_race_bets_round
      ON horse_race_bets(round_id, horse_index);
    CREATE INDEX IF NOT EXISTS idx_horse_race_bets_user
      ON horse_race_bets(user_id, round_id);

    CREATE TABLE IF NOT EXISTS horse_race_bet_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id TEXT NOT NULL,
      round_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      horse_index INTEGER NOT NULL,
      amount INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(user_id, request_id),
      FOREIGN KEY (round_id) REFERENCES horse_race_rounds(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL DEFAULT 0,
      is_system INTEGER NOT NULL DEFAULT 0,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_horse_race_chat_time
      ON horse_race_chat_messages(created_at);

    CREATE TABLE IF NOT EXISTS profile_photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      image_url TEXT NOT NULL,
      caption TEXT NOT NULL DEFAULT '',
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_profile_photos_user
      ON profile_photos(user_id, sort_order, created_at);

    CREATE TABLE IF NOT EXISTS shop_items (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      price_coins INTEGER NOT NULL,
      item_type TEXT NOT NULL DEFAULT 'cosmetic',
      min_level INTEGER NOT NULL DEFAULT 0,
      asset_value TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS user_inventory (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      item_id TEXT NOT NULL,
      acquired_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (user_id, item_id),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (item_id) REFERENCES shop_items(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS user_equipment (
      user_id INTEGER NOT NULL,
      slot TEXT NOT NULL,
      item_id TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (user_id, slot),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (item_id) REFERENCES shop_items(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS likes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (user_id, target_type, target_id),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reporter_id INTEGER,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      handled_at TEXT,
      handled_by INTEGER,
      FOREIGN KEY (reporter_id) REFERENCES users(id) ON DELETE SET NULL,
      FOREIGN KEY (handled_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS chat_block_keywords (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      keyword TEXT NOT NULL UNIQUE,
      match_type TEXT NOT NULL DEFAULT 'contains',
      severity TEXT NOT NULL DEFAULT 'block',
      status TEXT NOT NULL DEFAULT 'active',
      note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS chat_violations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      room_id TEXT NOT NULL DEFAULT '',
      content TEXT NOT NULL DEFAULT '',
      keyword_id INTEGER,
      keyword TEXT NOT NULL DEFAULT '',
      action TEXT NOT NULL DEFAULT 'blocked',
      ip TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (keyword_id) REFERENCES chat_block_keywords(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_chat_violations_user_time
      ON chat_violations(user_id, created_at);

    CREATE TABLE IF NOT EXISTS banned_registration_ips (
      ip TEXT PRIMARY KEY,
      user_id INTEGER,
      reason TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL DEFAULT '',
      is_secret INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS admin_audit_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      admin_user_id INTEGER,
      method TEXT NOT NULL,
      path TEXT NOT NULL,
      status_code INTEGER NOT NULL DEFAULT 0,
      ip TEXT NOT NULL DEFAULT '',
      user_agent TEXT NOT NULL DEFAULT '',
      request_id TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_time
      ON admin_audit_logs(created_at, admin_user_id);

    CREATE TABLE IF NOT EXISTS admin_broadcasts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      admin_user_id INTEGER,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'system',
      recipient_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_time
      ON admin_broadcasts(created_at);

    CREATE TABLE IF NOT EXISTS user_app_installs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      install_id TEXT NOT NULL,
      version_name TEXT NOT NULL DEFAULT '',
      version_code INTEGER NOT NULL DEFAULT 0,
      platform TEXT NOT NULL DEFAULT '',
      os_version TEXT NOT NULL DEFAULT '',
      device_model TEXT NOT NULL DEFAULT '',
      first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_ip TEXT NOT NULL DEFAULT '',
      UNIQUE (user_id, install_id),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_user_app_installs_version
      ON user_app_installs(version_code, last_seen_at);
    CREATE INDEX IF NOT EXISTS idx_user_app_installs_user
      ON user_app_installs(user_id, last_seen_at);

    CREATE TABLE IF NOT EXISTS user_content_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      content_type TEXT NOT NULL,
      content_key TEXT NOT NULL,
      source_key TEXT NOT NULL DEFAULT '',
      item_id TEXT NOT NULL DEFAULT '',
      sub_item_id TEXT NOT NULL DEFAULT '',
      payload_json TEXT NOT NULL DEFAULT '{}',
      metadata_json TEXT NOT NULL DEFAULT '{}',
      device_id TEXT NOT NULL DEFAULT '',
      client_updated_at_ms INTEGER NOT NULL,
      revision INTEGER NOT NULL,
      deleted_at TEXT,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (user_id, content_type, content_key),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      CHECK (content_type IN ('novel', 'manga', 'anime'))
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_content_progress_revision
      ON user_content_progress(user_id, revision);
    CREATE INDEX IF NOT EXISTS idx_user_content_progress_updated
      ON user_content_progress(user_id, updated_at);

    CREATE TABLE IF NOT EXISTS app_telemetry_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER,
      install_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      event_name TEXT NOT NULL,
      screen TEXT NOT NULL DEFAULT '',
      duration_ms INTEGER NOT NULL DEFAULT 0,
      success INTEGER,
      metadata TEXT NOT NULL DEFAULT '{}',
      version_name TEXT NOT NULL DEFAULT '',
      version_code INTEGER NOT NULL DEFAULT 0,
      platform TEXT NOT NULL DEFAULT '',
      os_version TEXT NOT NULL DEFAULT '',
      device_model TEXT NOT NULL DEFAULT '',
      occurred_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_app_telemetry_events_time
      ON app_telemetry_events(created_at, event_name);
    CREATE INDEX IF NOT EXISTS idx_app_telemetry_events_install
      ON app_telemetry_events(install_id, session_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_app_telemetry_events_version
      ON app_telemetry_events(version_code, created_at);

    CREATE TABLE IF NOT EXISTS app_error_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER,
      install_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      fingerprint TEXT NOT NULL,
      error_type TEXT NOT NULL DEFAULT '',
      message TEXT NOT NULL DEFAULT '',
      stack TEXT NOT NULL DEFAULT '',
      screen TEXT NOT NULL DEFAULT '',
      fatal INTEGER NOT NULL DEFAULT 0,
      metadata TEXT NOT NULL DEFAULT '{}',
      version_name TEXT NOT NULL DEFAULT '',
      version_code INTEGER NOT NULL DEFAULT 0,
      platform TEXT NOT NULL DEFAULT '',
      os_version TEXT NOT NULL DEFAULT '',
      device_model TEXT NOT NULL DEFAULT '',
      occurred_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_app_error_reports_time
      ON app_error_reports(created_at, fatal);
    CREATE INDEX IF NOT EXISTS idx_app_error_reports_fingerprint
      ON app_error_reports(fingerprint, created_at);
    CREATE INDEX IF NOT EXISTS idx_app_error_reports_version
      ON app_error_reports(version_code, created_at);

    CREATE TABLE IF NOT EXISTS content_catalog (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content_type TEXT NOT NULL,
      stable_key TEXT NOT NULL UNIQUE,
      source_key TEXT NOT NULL,
      source_item_id TEXT NOT NULL,
      title TEXT NOT NULL,
      author TEXT NOT NULL DEFAULT '',
      cover_url TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'active',
      metadata_json TEXT NOT NULL DEFAULT '{}',
      alias_json TEXT NOT NULL DEFAULT '[]',
      last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
      revision INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (content_type, source_key, source_item_id),
      CHECK (content_type IN ('novel', 'manga', 'anime')),
      CHECK (status IN ('pending', 'active', 'inactive', 'missing'))
    );

    CREATE INDEX IF NOT EXISTS idx_content_catalog_search
      ON content_catalog(content_type, status, title, author);
    CREATE INDEX IF NOT EXISTS idx_content_catalog_source
      ON content_catalog(source_key, last_seen_at);

    CREATE TABLE IF NOT EXISTS content_source_health (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content_type TEXT NOT NULL,
      source_key TEXT NOT NULL,
      request_count INTEGER NOT NULL DEFAULT 0,
      success_count INTEGER NOT NULL DEFAULT 0,
      failure_count INTEGER NOT NULL DEFAULT 0,
      latency_total_ms INTEGER NOT NULL DEFAULT 0,
      last_latency_ms INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NOT NULL DEFAULT '',
      last_probed_at TEXT NOT NULL DEFAULT '',
      last_probe_error TEXT NOT NULL DEFAULT '',
      manual_request_count INTEGER NOT NULL DEFAULT 0,
      manual_success_count INTEGER NOT NULL DEFAULT 0,
      manual_failure_count INTEGER NOT NULL DEFAULT 0,
      manual_latency_total_ms INTEGER NOT NULL DEFAULT 0,
      observed_request_count INTEGER NOT NULL DEFAULT 0,
      observed_success_count INTEGER NOT NULL DEFAULT 0,
      observed_failure_count INTEGER NOT NULL DEFAULT 0,
      observed_latency_total_ms INTEGER NOT NULL DEFAULT 0,
      last_observed_at TEXT NOT NULL DEFAULT '',
      last_observation_error TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (content_type, source_key),
      CHECK (content_type IN ('novel', 'manga', 'anime'))
    );

    CREATE INDEX IF NOT EXISTS idx_content_source_health_probe
      ON content_source_health(last_probed_at, failure_count);

    CREATE TABLE IF NOT EXISTS content_source_probe_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content_type TEXT NOT NULL,
      source_key TEXT NOT NULL,
      success INTEGER NOT NULL,
      latency_ms INTEGER NOT NULL DEFAULT 0,
      error TEXT NOT NULL DEFAULT '',
      admin_user_id INTEGER,
      idempotency_key TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (admin_user_id, idempotency_key),
      FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (content_type IN ('novel', 'manga', 'anime'))
    );

    CREATE TABLE IF NOT EXISTS content_observation_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER,
      install_id TEXT NOT NULL,
      observation_id TEXT NOT NULL,
      content_type TEXT NOT NULL,
      stable_key TEXT NOT NULL,
      source_key TEXT NOT NULL,
      source_item_id TEXT NOT NULL,
      success INTEGER,
      latency_ms INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (install_id, observation_id),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (content_type IN ('novel', 'manga', 'anime'))
    );

    CREATE INDEX IF NOT EXISTS idx_content_observations_source
      ON content_observation_events(content_type, source_key, created_at);

    CREATE TABLE IF NOT EXISTS home_placements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      placement_type TEXT NOT NULL,
      position TEXT NOT NULL,
      content_key TEXT NOT NULL,
      custom_title TEXT NOT NULL DEFAULT '',
      custom_image_url TEXT NOT NULL DEFAULT '',
      sort_order INTEGER NOT NULL DEFAULT 0,
      starts_at TEXT NOT NULL DEFAULT '',
      ends_at TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'draft',
      audience_json TEXT NOT NULL DEFAULT '{}',
      revision INTEGER NOT NULL DEFAULT 1,
      idempotency_key TEXT NOT NULL DEFAULT '',
      created_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (content_key) REFERENCES content_catalog(stable_key)
        ON UPDATE CASCADE ON DELETE RESTRICT,
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (placement_type IN ('banner', 'recommend', 'ranking')),
      CHECK (status IN ('draft', 'active', 'disabled'))
    );

    CREATE INDEX IF NOT EXISTS idx_home_placements_active
      ON home_placements(placement_type, position, status, sort_order);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_home_placements_idempotency
      ON home_placements(created_by, idempotency_key)
      WHERE idempotency_key <> '';

    CREATE TABLE IF NOT EXISTS feature_flags (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL DEFAULT '{}',
      min_version_code INTEGER NOT NULL DEFAULT 0,
      max_version_code INTEGER NOT NULL DEFAULT 0,
      percentage_rollout INTEGER NOT NULL DEFAULT 100,
      enabled INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 1,
      idempotency_key TEXT NOT NULL DEFAULT '',
      updated_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (percentage_rollout BETWEEN 0 AND 100)
    );

    CREATE TABLE IF NOT EXISTS feature_flag_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      flag_key TEXT NOT NULL,
      revision INTEGER NOT NULL,
      value_json TEXT NOT NULL,
      min_version_code INTEGER NOT NULL,
      max_version_code INTEGER NOT NULL,
      percentage_rollout INTEGER NOT NULL,
      enabled INTEGER NOT NULL,
      changed_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (flag_key, revision),
      FOREIGN KEY (changed_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_feature_flag_history_key
      ON feature_flag_history(flag_key, revision DESC);

    CREATE TABLE IF NOT EXISTS cache_invalidations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      scope TEXT NOT NULL,
      cache_key TEXT NOT NULL DEFAULT '',
      reason TEXT NOT NULL,
      revision INTEGER NOT NULL UNIQUE,
      created_by INTEGER,
      idempotency_key TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_cache_invalidations_scope
      ON cache_invalidations(scope, cache_key, revision DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_cache_invalidations_idempotency
      ON cache_invalidations(created_by, idempotency_key)
      WHERE idempotency_key <> '';

    CREATE TABLE IF NOT EXISTS content_behavior_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE,
      user_id INTEGER,
      install_id TEXT NOT NULL,
      session_id TEXT NOT NULL DEFAULT '',
      actor_key TEXT NOT NULL,
      content_key TEXT NOT NULL,
      content_type TEXT NOT NULL,
      event_name TEXT NOT NULL,
      source TEXT NOT NULL,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      occurred_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL,
      FOREIGN KEY (content_key) REFERENCES content_catalog(stable_key)
        ON UPDATE CASCADE ON DELETE RESTRICT,
      CHECK (content_type IN ('novel', 'manga', 'anime')),
      CHECK (event_name IN ('exposure', 'click', 'open', 'start', 'complete', 'favorite'))
    );

    CREATE INDEX IF NOT EXISTS idx_content_behavior_content_time
      ON content_behavior_events(content_key, event_name, occurred_at);
    CREATE INDEX IF NOT EXISTS idx_content_behavior_actor_time
      ON content_behavior_events(actor_key, occurred_at);
    CREATE INDEX IF NOT EXISTS idx_content_behavior_user_time
      ON content_behavior_events(user_id, occurred_at);

    CREATE TABLE IF NOT EXISTS content_behavior_daily (
      event_date TEXT NOT NULL,
      content_key TEXT NOT NULL,
      content_type TEXT NOT NULL,
      event_name TEXT NOT NULL,
      event_count INTEGER NOT NULL DEFAULT 0,
      unique_actors INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (event_date, content_key, event_name),
      FOREIGN KEY (content_key) REFERENCES content_catalog(stable_key)
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_content_behavior_daily_board
      ON content_behavior_daily(event_date, content_type, event_name);

    CREATE TABLE IF NOT EXISTS content_behavior_daily_actors (
      event_date TEXT NOT NULL,
      content_key TEXT NOT NULL,
      event_name TEXT NOT NULL,
      actor_key TEXT NOT NULL,
      accepted_count INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (event_date, content_key, event_name, actor_key),
      FOREIGN KEY (content_key) REFERENCES content_catalog(stable_key)
        ON UPDATE CASCADE ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS content_ranking_controls (
      ranking_key TEXT NOT NULL,
      content_key TEXT NOT NULL,
      pinned INTEGER NOT NULL DEFAULT 0,
      excluded INTEGER NOT NULL DEFAULT 0,
      manual_weight REAL NOT NULL DEFAULT 0,
      note TEXT NOT NULL DEFAULT '',
      updated_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (ranking_key, content_key),
      FOREIGN KEY (content_key) REFERENCES content_catalog(stable_key)
        ON UPDATE CASCADE ON DELETE CASCADE,
      FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS campaigns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      campaign_key TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      banner_url TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'draft',
      starts_at TEXT NOT NULL DEFAULT '',
      ends_at TEXT NOT NULL DEFAULT '',
      audience_json TEXT NOT NULL DEFAULT '{}',
      min_version_code INTEGER NOT NULL DEFAULT 0,
      max_version_code INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 1,
      created_by INTEGER,
      updated_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL,
      FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (status IN ('draft', 'active', 'paused', 'ended', 'rolled_back'))
    );

    CREATE INDEX IF NOT EXISTS idx_campaigns_active
      ON campaigns(status, starts_at, ends_at);

    CREATE TABLE IF NOT EXISTS activity_tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      campaign_id INTEGER NOT NULL,
      task_key TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      event_name TEXT NOT NULL,
      target_count INTEGER NOT NULL DEFAULT 1,
      reward_points INTEGER NOT NULL DEFAULT 0,
      reward_coins INTEGER NOT NULL DEFAULT 0,
      filters_json TEXT NOT NULL DEFAULT '{}',
      sort_order INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (campaign_id, task_key),
      FOREIGN KEY (campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE,
      CHECK (status IN ('active', 'disabled'))
    );

    CREATE TABLE IF NOT EXISTS user_activity_progress (
      campaign_id INTEGER NOT NULL,
      task_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      progress_count INTEGER NOT NULL DEFAULT 0,
      completed_at TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (campaign_id, task_id, user_id),
      FOREIGN KEY (campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE,
      FOREIGN KEY (task_id) REFERENCES activity_tasks(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS reward_claims (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      campaign_id INTEGER NOT NULL,
      task_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      points_awarded INTEGER NOT NULL DEFAULT 0,
      coins_awarded INTEGER NOT NULL DEFAULT 0,
      idempotency_key TEXT NOT NULL DEFAULT '',
      claimed_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (task_id, user_id),
      FOREIGN KEY (campaign_id) REFERENCES campaigns(id) ON DELETE RESTRICT,
      FOREIGN KEY (task_id) REFERENCES activity_tasks(id) ON DELETE RESTRICT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS campaign_revisions (
      campaign_id INTEGER NOT NULL,
      revision INTEGER NOT NULL,
      campaign_json TEXT NOT NULL,
      tasks_json TEXT NOT NULL DEFAULT '[]',
      changed_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (campaign_id, revision),
      FOREIGN KEY (campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE,
      FOREIGN KEY (changed_by) REFERENCES users(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS horse_race_seasons (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      season_key TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft',
      starts_at TEXT NOT NULL,
      ends_at TEXT NOT NULL,
      config_json TEXT NOT NULL DEFAULT '{}',
      revision INTEGER NOT NULL DEFAULT 1,
      created_by INTEGER,
      updated_by INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL,
      FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (status IN ('draft', 'active', 'paused', 'ended'))
    );

    CREATE INDEX IF NOT EXISTS idx_horse_race_seasons_active
      ON horse_race_seasons(status, starts_at, ends_at);

    CREATE TABLE IF NOT EXISTS horse_race_season_user_stats (
      season_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      points INTEGER NOT NULL DEFAULT 0,
      rounds INTEGER NOT NULL DEFAULT 0,
      wins INTEGER NOT NULL DEFAULT 0,
      total_bet INTEGER NOT NULL DEFAULT 0,
      total_payout INTEGER NOT NULL DEFAULT 0,
      tier TEXT NOT NULL DEFAULT 'bronze',
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (season_id, user_id),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_horse_race_season_ranking
      ON horse_race_season_user_stats(season_id, points DESC, wins DESC);

    CREATE TABLE IF NOT EXISTS horse_race_season_round_results (
      season_id INTEGER NOT NULL,
      round_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      points_awarded INTEGER NOT NULL DEFAULT 0,
      amount INTEGER NOT NULL DEFAULT 0,
      payout INTEGER NOT NULL DEFAULT 0,
      won INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (season_id, round_id, user_id),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE CASCADE,
      FOREIGN KEY (round_id) REFERENCES horse_race_rounds(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_season_tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      season_id INTEGER NOT NULL,
      task_key TEXT NOT NULL,
      title TEXT NOT NULL,
      metric TEXT NOT NULL,
      target_count INTEGER NOT NULL DEFAULT 1,
      reward_points INTEGER NOT NULL DEFAULT 0,
      reward_coins INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active',
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE (season_id, task_key),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_season_task_progress (
      season_id INTEGER NOT NULL,
      task_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      progress_count INTEGER NOT NULL DEFAULT 0,
      completed_at TEXT NOT NULL DEFAULT '',
      claimed_at TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (task_id, user_id),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE CASCADE,
      FOREIGN KEY (task_id) REFERENCES horse_race_season_tasks(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_season_rewards (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      season_id INTEGER NOT NULL,
      reward_key TEXT NOT NULL,
      title TEXT NOT NULL,
      tier TEXT NOT NULL DEFAULT '',
      min_rank INTEGER NOT NULL DEFAULT 0,
      max_rank INTEGER NOT NULL DEFAULT 0,
      reward_points INTEGER NOT NULL DEFAULT 0,
      reward_coins INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active',
      UNIQUE (season_id, reward_key),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_season_reward_claims (
      season_id INTEGER NOT NULL,
      reward_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      points_awarded INTEGER NOT NULL DEFAULT 0,
      coins_awarded INTEGER NOT NULL DEFAULT 0,
      claimed_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (reward_id, user_id),
      FOREIGN KEY (season_id) REFERENCES horse_race_seasons(id) ON DELETE RESTRICT,
      FOREIGN KEY (reward_id) REFERENCES horse_race_season_rewards(id) ON DELETE RESTRICT,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_round_growth_events (
      round_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (round_id, user_id),
      FOREIGN KEY (round_id) REFERENCES horse_race_rounds(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_responsible_settings (
      user_id INTEGER PRIMARY KEY,
      cooldown_until TEXT NOT NULL DEFAULT '',
      self_excluded_until TEXT NOT NULL DEFAULT '',
      daily_bet_limit INTEGER NOT NULL DEFAULT 0,
      daily_loss_limit INTEGER NOT NULL DEFAULT 0,
      reminder_loss_threshold INTEGER NOT NULL DEFAULT 500,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS horse_race_responsible_notices (
      user_id INTEGER NOT NULL,
      notice_date TEXT NOT NULL,
      notice_type TEXT NOT NULL,
      amount INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (user_id, notice_date, notice_type),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS service_leases (
      lease_key TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      lease_until_ms INTEGER NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS ai_novels (
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
      FOREIGN KEY (reviewed_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (status IN ('pending', 'published', 'rejected'))
    );

    CREATE INDEX IF NOT EXISTS idx_ai_novels_public
      ON ai_novels(status, published_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS idx_ai_novels_owner
      ON ai_novels(user_id, updated_at DESC, id DESC);

    CREATE TABLE IF NOT EXISTS ai_novel_chapters (
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
      FOREIGN KEY (reviewed_by) REFERENCES users(id) ON DELETE SET NULL,
      CHECK (status IN ('pending', 'published', 'rejected'))
    );

    CREATE INDEX IF NOT EXISTS idx_ai_novel_chapters_order
      ON ai_novel_chapters(novel_id, status, sort_order, id);
  `);
  addMissingColumn("users", "bio", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "gender", "TEXT NOT NULL DEFAULT 'private'");
  addMissingColumn("users", "signature", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "space_title", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "profile_banner_url", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "dynamic_avatar_url", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "profile_theme", "TEXT NOT NULL DEFAULT 'sakura'");
  addMissingColumn("users", "privacy_mode", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("users", "points", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("users", "sakura_coins", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("users", "level", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("users", "register_ip", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "last_login_ip", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "banned_until", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "ban_reason", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("users", "chat_violation_total", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("users", "chat_temp_ban_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("image_captchas", "attempt_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("email_verifications", "attempt_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("chat_messages", "type", "TEXT NOT NULL DEFAULT 'text'");
  addMissingColumn("chat_messages", "media_url", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("chat_messages", "metadata", "TEXT NOT NULL DEFAULT '{}'");
  addMissingColumn("chat_rooms", "category", "TEXT NOT NULL DEFAULT 'novel'");
  addMissingColumn("chat_rooms", "is_official", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("chat_room_members", "last_seen_at", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("chat_room_members", "last_read_at", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("chat_room_members", "last_read_message_id", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("horse_race_rounds", "round_key", "TEXT NOT NULL DEFAULT ''");
  // Existing rows were created by the three-hour v1 rules and must finish
  // under those timings instead of being settled immediately during deploy.
  addMissingColumn("horse_race_rounds", "rules_version", "INTEGER NOT NULL DEFAULT 1");
  addMissingColumn("horse_race_rounds", "odds_json", "TEXT NOT NULL DEFAULT '[]'");
  addMissingColumn("horse_race_rounds", "race_json", "TEXT NOT NULL DEFAULT '{}'");
  addMissingColumn("horse_race_rounds", "result_json", "TEXT NOT NULL DEFAULT '{}'");
  addMissingColumn("horse_race_rounds", "locked_at", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("horse_race_bets", "odds", "REAL NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "manual_request_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "last_probe_error", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("content_source_health", "manual_success_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "manual_failure_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "manual_latency_total_ms", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "observed_request_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "observed_success_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "observed_failure_count", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "observed_latency_total_ms", "INTEGER NOT NULL DEFAULT 0");
  addMissingColumn("content_source_health", "last_observed_at", "TEXT NOT NULL DEFAULT ''");
  addMissingColumn("content_source_health", "last_observation_error", "TEXT NOT NULL DEFAULT ''");
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_auth_tokens_user_active
      ON auth_tokens(user_id, revoked_at, expires_at);
    CREATE INDEX IF NOT EXISTS idx_image_captchas_expiry
      ON image_captchas(expires_at, used_at);
    CREATE INDEX IF NOT EXISTS idx_email_verifications_email_purpose_time
      ON email_verifications(email, purpose, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_email_verifications_ip_purpose_time
      ON email_verifications(ip, purpose, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_email_verifications_expiry
      ON email_verifications(expires_at, verified_at);
    DELETE FROM image_captchas
      WHERE expires_at < datetime('now', '-1 day');
    DELETE FROM email_verifications
      WHERE expires_at < datetime('now', '-7 days');
    DELETE FROM auth_tokens
      WHERE expires_at < datetime('now', '-30 days')
         OR (revoked_at IS NOT NULL AND revoked_at < datetime('now', '-30 days'));
  `);
  db.exec(`
    CREATE UNIQUE INDEX IF NOT EXISTS idx_horse_race_round_key
      ON horse_race_rounds(round_key)
      WHERE round_key <> '';
    CREATE INDEX IF NOT EXISTS idx_horse_race_bets_user
      ON horse_race_bets(user_id, round_id);
  `);
  seedChatRooms();
  seedShopItems();
  seedChatBlockKeywords();
  encryptStoredSettingSecrets();
}

function encryptStoredSettingSecrets() {
  const rows = db
    .prepare("SELECT key, value FROM app_settings WHERE is_secret = 1")
    .all();
  const update = db.prepare(
    "UPDATE app_settings SET value = ?, updated_at = datetime('now') WHERE key = ?",
  );
  for (const row of rows) {
    if (!row.value || isEncryptedSettingSecret(row.value)) continue;
    update.run(encryptSettingSecret(row.value), row.key);
  }
}

function addMissingColumn(table, column, definition) {
  const columns = db.prepare(`PRAGMA table_info(${table})`).all();
  if (columns.some((item) => item.name === column)) return;
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}

function seedShopItems() {
  const items = [
    [
      "skin-sakura-card",
      "樱花资料卡皮肤",
      "给个人空间换上樱花主题资料卡。",
      120,
      "profile_skin",
      1,
      "sakura",
    ],
    [
      "bubble-night-chat",
      "夜樱聊天气泡",
      "聊天室专属夜樱气泡样式。",
      180,
      "chat_bubble",
      2,
      "night_sakura",
    ],
    [
      "bubble-sakura-pink",
      "樱粉聊天气泡",
      "柔粉渐变气泡，适合日常聊天。",
      160,
      "chat_bubble",
      2,
      "sakura_pink",
    ],
    [
      "bubble-moon-blue",
      "月蓝聊天气泡",
      "清透蓝紫气泡，带一点夜空感。",
      220,
      "chat_bubble",
      3,
      "moon_blue",
    ],
    [
      "bubble-mint-leaf",
      "薄荷聊天气泡",
      "轻盈薄荷绿气泡，阅读感更清爽。",
      260,
      "chat_bubble",
      4,
      "mint_leaf",
    ],
    [
      "bubble-gold-aurora",
      "鎏金极光气泡",
      "高阶鎏金渐变气泡，Lv6 专属兑换。",
      480,
      "chat_bubble",
      6,
      "gold_aurora",
    ],
    [
      "sticker-pack-sakura",
      "樱花小剧场表情包",
      "包含樱花挥手、喜欢、困了三枚专属表情。",
      260,
      "sticker_pack",
      4,
      "sakura_pack",
    ],
    [
      "sticker-pack-moon",
      "月光读者表情包",
      "包含月亮打招呼、星星、害羞三枚专属表情。",
      360,
      "sticker_pack",
      5,
      "moon_pack",
    ],
    [
      "frame-lv5-crystal",
      "Lv5 蓝晶头像框",
      "蓝晶光环头像框，适合个人页和聊天展示。",
      420,
      "avatar_frame",
      5,
      "lv5_crystal",
    ],
    [
      "room-sakura-glass",
      "樱花玻璃聊天室",
      "聊天室背景装修，带柔和樱花玻璃质感。",
      520,
      "chat_room_theme",
      6,
      "sakura_glass",
    ],
    [
      "dynamic-avatar-pass",
      "动态头像体验券",
      "Lv5 后可使用动态头像展示位。",
      360,
      "avatar_privilege",
      5,
      "dynamic_avatar",
    ],
  ];
  const statement = db.prepare(
    `INSERT OR IGNORE INTO shop_items
     (id, name, description, price_coins, item_type, min_level, asset_value)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  );
  for (const item of items) statement.run(...item);
}

function seedChatBlockKeywords() {
  const keywords = [
    ["赌博", "博彩广告"],
    ["博彩", "博彩广告"],
    ["彩票网", "博彩广告"],
    ["下注", "博彩广告"],
    ["澳门赌场", "博彩广告"],
    ["六合彩", "博彩广告"],
    ["私人影院", "涉黄引流"],
    ["裸聊", "涉黄引流"],
    ["约炮", "涉黄引流"],
    ["色情网", "涉黄引流"],
    ["成人视频", "涉黄引流"],
    ["刷单", "诈骗广告"],
    ["返利", "诈骗广告"],
    ["兼职赚钱", "诈骗广告"],
    ["贷款", "金融广告"],
    ["套现", "金融广告"],
    ["代充", "交易广告"],
    ["代刷", "交易广告"],
    ["外挂", "作弊工具"],
    ["脚本代练", "作弊工具"],
    ["卖号", "账号交易"],
    ["买号", "账号交易"],
    ["加微信", "站外引流"],
    ["加VX", "站外引流"],
    ["加Q", "站外引流"],
    ["加QQ", "站外引流"],
    ["私聊赚钱", "诈骗引流"],
    ["开户链接", "广告引流"],
    ["点击链接", "广告引流"],
    ["telegram", "站外引流"],
    ["电报群", "站外引流"],
  ];
  const statement = db.prepare(
    `INSERT OR IGNORE INTO chat_block_keywords (keyword, note)
     VALUES (?, ?)`,
  );
  for (const item of keywords) statement.run(...item);
}

function seedChatRooms() {
  const rooms = [
    ["global", "聊天室", "novel"],
    ["novel-official", "小说官方聊天室", "novel"],
    ["anime-official", "动漫官方聊天室", "anime"],
    ["manga-official", "漫画官方聊天室", "manga"],
  ];
  const statement = db.prepare(
    `INSERT OR IGNORE INTO chat_rooms
       (id, name, min_level, category, is_official, bot_enabled)
     VALUES (?, ?, 1, ?, 1, 1)`,
  );
  for (const room of rooms) statement.run(...room);
  db.prepare(
    `UPDATE chat_rooms
     SET category = 'novel', is_official = 1
     WHERE id = 'global'`,
  ).run();
}

export function seedAdmin() {
  if (!config.adminUsername || !config.adminPassword) return;

  const email = config.adminUsername.includes("@")
    ? config.adminUsername.toLowerCase()
    : `${config.adminUsername.toLowerCase()}@admin.local`;
  const nickname = config.adminUsername;
  const existing = db
    .prepare("SELECT id FROM users WHERE email = ?")
    .get(email);
  if (existing) return;

  db.prepare(
    `INSERT INTO users (email, nickname, password_hash, role, status)
     VALUES (?, ?, ?, 'admin', 'active')`,
  ).run(email, nickname, hashPassword(config.adminPassword));
}

export function one(sql, params = []) {
  return db.prepare(sql).get(...params);
}

export function all(sql, params = []) {
  return db.prepare(sql).all(...params);
}

export function run(sql, params = []) {
  return db.prepare(sql).run(...params);
}

export function closeDb() {
  db.close();
}
