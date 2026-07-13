import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

dotenv.config({ path: path.join(rootDir, '.env') });

function env(name, fallback = '') {
  const value = process.env[name];
  return value == null || value === '' ? fallback : value;
}

function requiredEnv(name) {
  const value = env(name).trim();
  if (!value) {
    throw new Error(`${name} must be configured`);
  }
  return value;
}

function envNumber(name, fallback) {
  const raw = env(name, String(fallback));
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function envBool(name, fallback) {
  const raw = env(name, String(fallback)).toLowerCase();
  return raw === 'true' || raw === '1' || raw === 'yes';
}

function normalizePrefix(value, fallback) {
  const raw = value || fallback;
  if (raw === '/') return '';
  return `/${raw.replace(/^\/+|\/+$/g, '')}`;
}

function envList(name, fallback = '') {
  return env(name, fallback)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

export const config = {
  rootDir,
  host: env('HOST', '0.0.0.0'),
  port: envNumber('PORT', 3010),
  dbPath: path.resolve(rootDir, env('DB_PATH', './data/interaction.sqlite')),
  appReleaseDir: path.resolve(
    rootDir,
    env('APP_RELEASE_DIR', './data/releases'),
  ),
  tokenSecret: requiredEnv('TOKEN_SECRET'),
  settingsEncryptionKey: env('SETTINGS_ENCRYPTION_KEY'),
  apiPrefix: normalizePrefix(env('API_PREFIX', '/api'), '/api'),
  adminPath: normalizePrefix(env('ADMIN_PATH', '/admin'), '/admin'),
  wsChatPath: normalizePrefix(env('WS_CHAT_PATH', '/ws/chat'), '/ws/chat'),
  wsGamePath: normalizePrefix(env('WS_GAME_PATH', '/ws/game'), '/ws/game'),
  wsDanmakuPath: normalizePrefix(
    env('WS_DANMAKU_PATH', '/ws/danmaku'),
    '/ws/danmaku',
  ),
  corsOrigin: env('CORS_ORIGIN', '*'),
  trustedProxies: envList('TRUST_PROXY', '127.0.0.1,::1'),
  allowDevAuthCodes: envBool('ALLOW_DEV_AUTH_CODES', false),
  // The mobile app only receives normalized catalog data and episode HLS URLs.
  // A local server-managed catalog is preferred; an authenticated HTTPS
  // endpoint can be configured when the catalog is maintained elsewhere.
  suibianCatalogFile: path.resolve(
    rootDir,
    env('SUIBIAN_CATALOG_FILE', './data/suibian-catalog.json'),
  ),
  suibianCatalogUrl: env('SUIBIAN_CATALOG_URL'),
  suibianCatalogToken: env('SUIBIAN_CATALOG_TOKEN'),
  suibianCatalogTimeoutMs: envNumber('SUIBIAN_CATALOG_TIMEOUT_MS', 8000),
  suibianCatalogCacheTtlMs: envNumber('SUIBIAN_CATALOG_CACHE_TTL_MS', 300000),
  suibianCatalogMaxBytes: envNumber('SUIBIAN_CATALOG_MAX_BYTES', 5 * 1024 * 1024),
  dbzyEnabled: envBool('DBZY_ENABLED', true),
  dbzyBaseUrl: env(
    'DBZY_BASE_URL',
    'https://caiji.dbzy5.com/api.php/provide/vod/from/dbm3u8/at/josn/',
  ),
  dbzyCacheFile: path.resolve(rootDir, env('DBZY_CACHE_FILE', './data/dbzy-cache.json')),
  dbzyCacheTtlMs: envNumber('DBZY_CACHE_TTL_MS', 10 * 60 * 1000),
  dbzyIncrementalHours: envNumber('DBZY_INCREMENTAL_HOURS', 24),
  dbzyIncrementalMaxPages: envNumber('DBZY_INCREMENTAL_MAX_PAGES', 10),
  dbzyTimeoutMs: envNumber('DBZY_TIMEOUT_MS', 8000),
  dbzyMinRequestIntervalMs: envNumber('DBZY_MIN_REQUEST_INTERVAL_MS', 350),
  dbzyMaxBytes: envNumber('DBZY_MAX_BYTES', 8 * 1024 * 1024),
  dbzySyncEnabled: envBool('DBZY_SYNC_ENABLED', true),
  dbzySyncIntervalMs: envNumber('DBZY_SYNC_INTERVAL_MS', 30 * 60 * 1000),
  videoPolicyTimezone: env('VIDEO_POLICY_TIMEZONE', 'Asia/Hong_Kong'),
  speechAllowRemoteAudio: envBool('SPEECH_ALLOW_REMOTE_AUDIO', false),
  speechAudioMaxBytes: envNumber('SPEECH_AUDIO_MAX_BYTES', 5 * 1024 * 1024),
  speechAudioTimeoutMs: envNumber('SPEECH_AUDIO_TIMEOUT_MS', 8000),
  uploadMaxFilesPerUser: envNumber('UPLOAD_MAX_FILES_PER_USER', 100),
  uploadMaxBytesPerUser: envNumber(
    'UPLOAD_MAX_BYTES_PER_USER',
    100 * 1024 * 1024,
  ),
  adminUsername: env('ADMIN_USERNAME', 'admin'),
  adminPassword: requiredEnv('ADMIN_PASSWORD'),
  smtp: {
    host: env('SMTP_HOST'),
    port: envNumber('SMTP_PORT', 465),
    secure: envBool('SMTP_SECURE', true),
    user: env('SMTP_USER'),
    pass: env('SMTP_PASS'),
    from: env('SMTP_FROM', '"Novel App" <no-reply@example.com>'),
  },
};
