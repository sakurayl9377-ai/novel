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
  nodeEnvironment: env('NODE_ENV', 'development').trim().toLowerCase(),
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
  websocketMaxPayloadBytes: envNumber('WS_MAX_PAYLOAD_BYTES', 64 * 1024),
  allowLegacyWebSocketQueryToken: envBool(
    'ALLOW_LEGACY_WS_QUERY_TOKEN',
    false,
  ),
  corsOrigin: env('CORS_ORIGIN', '*'),
  trustedProxies: envList('TRUST_PROXY', '127.0.0.1,::1'),
  allowDevAuthCodes: envBool('ALLOW_DEV_AUTH_CODES', false),
  allowBetaTestSession: envBool('ALLOW_BETA_TEST_SESSION', false),
  bailianLaunchUrl: env('BAILIAN_LAUNCH_URL'),
  bailianSsoSharedSecret: env('BAILIAN_SSO_SHARED_SECRET'),
  bailianSsoTtlSeconds: Math.max(
    1,
    Math.min(60, Math.trunc(envNumber('BAILIAN_SSO_TTL_SECONDS', 60))),
  ),
  bailianPaymentCatalogFile: env('BAILIAN_PAYMENT_CATALOG_FILE'),
  bailianPaymentCatalogJson: env('BAILIAN_PAYMENT_CATALOG_JSON'),
  bailianPaymentFulfillmentUrl: env('BAILIAN_PAYMENT_FULFILLMENT_URL'),
  bailianPaymentHmacSecret: env('BAILIAN_PAYMENT_HMAC_SECRET'),
  bailianPaymentMaxAttempts: Math.max(
    1,
    Math.min(10, Math.trunc(envNumber('BAILIAN_PAYMENT_MAX_ATTEMPTS', 3))),
  ),
  bailianPaymentTimeoutMs: Math.max(
    1000,
    Math.min(30000, Math.trunc(envNumber('BAILIAN_PAYMENT_TIMEOUT_MS', 5000))),
  ),
  videoCoverDir: path.resolve(
    rootDir,
    env('VIDEO_COVER_DIR', './data/video-covers'),
  ),
  videoCoverMaxBytes: envNumber(
    'VIDEO_COVER_MAX_BYTES',
    3 * 1024 * 1024,
  ),
  wenku8BaseUrl: env('WENKU8_BASE_URL', 'https://www.wenku8.cc'),
  wenku8Username: env('WENKU8_USERNAME'),
  wenku8Password: env('WENKU8_PASSWORD'),
  wenku8AccountFile: path.resolve(
    rootDir,
    env('WENKU8_ACCOUNT_FILE', './data/wenku8-account.json'),
  ),
  wenku8AutoRegister: envBool('WENKU8_AUTO_REGISTER', true),
  wenku8CacheTtlMs: envNumber('WENKU8_CACHE_TTL_MS', 10 * 60 * 1000),
  wenku8TimeoutMs: envNumber('WENKU8_TIMEOUT_MS', 8000),
  speechAllowRemoteAudio: envBool('SPEECH_ALLOW_REMOTE_AUDIO', false),
  speechAudioMaxBytes: envNumber('SPEECH_AUDIO_MAX_BYTES', 5 * 1024 * 1024),
  speechAudioTimeoutMs: envNumber('SPEECH_AUDIO_TIMEOUT_MS', 8000),
  uploadMaxFilesPerUser: envNumber('UPLOAD_MAX_FILES_PER_USER', 100),
  uploadMaxBytesPerUser: envNumber(
    'UPLOAD_MAX_BYTES_PER_USER',
    100 * 1024 * 1024,
  ),
  uploadOrphanGraceMs: envNumber(
    'UPLOAD_ORPHAN_GRACE_MS',
    24 * 60 * 60 * 1000,
  ),
  uploadOrphanSweepIntervalMs: envNumber(
    'UPLOAD_ORPHAN_SWEEP_INTERVAL_MS',
    60 * 60 * 1000,
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
