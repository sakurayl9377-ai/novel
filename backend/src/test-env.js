import os from 'node:os';
import path from 'node:path';

// Unit tests must be runnable from a clean clone without a developer .env.
// Each Node test worker gets its own SQLite file through its process id.
process.env.DB_PATH ||= path.join(
  os.tmpdir(),
  `novel-backend-test-${process.pid}.sqlite`,
);
process.env.TOKEN_SECRET ||= 'unit-test-token-secret';
process.env.SETTINGS_ENCRYPTION_KEY ||= 'unit-test-settings-encryption-key';
process.env.ADMIN_USERNAME ||= 'admin';
process.env.ADMIN_PASSWORD ||= 'unit-test-admin-password';
process.env.ALLOW_DEV_AUTH_CODES ||= 'false';
process.env.DBZY_SYNC_ENABLED ||= 'false';
process.env.SPEECH_ALLOW_REMOTE_AUDIO ||= 'false';
