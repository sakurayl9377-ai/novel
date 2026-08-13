import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-app-release-route-'));
process.env.DB_PATH = path.join(tempDir, 'route.sqlite');
process.env.TOKEN_SECRET = `release-route-token-${process.pid}`;
process.env.ADMIN_PASSWORD = `release-route-admin-${process.pid}`;

const { buildServer } = await import('./server.js');
const { config } = await import('./config.js');

test('release upload routes accept an authorized multipart chunk', async () => {
  const token = 'route-release-capability';
  const apk = Buffer.from('route apk fixture');
  config.rootDir = tempDir;
  fs.mkdirSync(path.join(tempDir, 'public'), { recursive: true });
  fs.writeFileSync(
    path.join(tempDir, 'app-release.json'),
    `${JSON.stringify({
      versionName: '4.1.33',
      versionCode: 86,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-4.1.33+86.apk',
      sha256: digest(apk),
      force: false,
      notes: ['route test'],
      uploadTokenSha256: digest(Buffer.from(token)),
    })}\n`,
  );

  const app = await buildServer();
  try {
    const unauthorized = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/internal/app-release/status`,
    });
    assert.equal(unauthorized.statusCode, 401);

    const boundary = 'novel-release-route-boundary';
    const multipart = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\n` +
        'Content-Disposition: form-data; name="apk"; filename="part-0000.bin"\r\n' +
        'Content-Type: application/octet-stream\r\n\r\n',
      ),
      apk,
      Buffer.from(`\r\n--${boundary}--\r\n`),
    ]);
    const uploaded = await app.inject({
      method: 'PUT',
      url: `${config.apiPrefix}/internal/app-release/chunks/0`,
      headers: {
        authorization: `Release ${token}`,
        'content-type': `multipart/form-data; boundary=${boundary}`,
        'x-release-part-count': '1',
        'x-release-part-sha256': digest(apk),
      },
      payload: multipart,
    });
    assert.equal(uploaded.statusCode, 200, uploaded.body);
    assert.equal(uploaded.json().receivedParts, 1);

    const status = await app.inject({
      method: 'GET',
      url: `${config.apiPrefix}/internal/app-release/status`,
      headers: { authorization: `Release ${token}` },
    });
    assert.equal(status.statusCode, 200, status.body);
    assert.deepEqual(status.json().receivedPartIndexes, [0]);
  } finally {
    await app.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function digest(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}
