import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';

import {
  appReleaseUploadStatus,
  finalizeAppReleaseUpload,
  saveAppReleasePart,
} from './app-release-upload.js';

test('stages verified chunks, publishes once, and consumes the capability', async () => {
  const rootDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'novel-app-release-test-'));
  const token = 'test-release-capability';
  const bytes = Buffer.from('signed apk fixture split across chunks');
  const chunks = [bytes.subarray(0, 14), bytes.subarray(14)];
  const spec = releaseSpec({ token, bytes });
  await fs.promises.writeFile(
    path.join(rootDir, 'app-release.json'),
    `${JSON.stringify(spec)}\n`,
  );
  let publishCalls = 0;
  try {
    await assert.rejects(
      saveAppReleasePart({
        token: 'wrong-token',
        index: 0,
        partCount: 2,
        declaredSha256: digest(chunks[0]),
        stream: Readable.from(chunks[0]),
        rootDir,
      }),
      /app_release_upload_unauthorized/,
    );
    for (let index = 0; index < chunks.length; index += 1) {
      const saved = await saveAppReleasePart({
        token,
        index,
        partCount: chunks.length,
        declaredSha256: digest(chunks[index]),
        stream: Readable.from(chunks[index]),
        rootDir,
      });
      assert.equal(saved.index, index);
      assert.equal(saved.partCount, chunks.length);
    }

    const before = await appReleaseUploadStatus({ token, rootDir });
    assert.equal(before.consumed, false);
    assert.equal(before.receivedParts, 2);
    assert.deepEqual(before.receivedPartIndexes, [0, 1]);

    const published = await finalizeAppReleaseUpload({
      token,
      rootDir,
      publish: async (stagingDir, currentSpec) => {
        publishCalls += 1;
        const apk = await fs.promises.readFile(
          path.join(stagingDir, 'app-release-4.1.33+86.apk'),
        );
        const manifest = JSON.parse(
          await fs.promises.readFile(path.join(stagingDir, 'version.json'), 'utf8'),
        );
        assert.deepEqual(apk, bytes);
        assert.equal(manifest.versionCode, 86);
        assert.equal(manifest.uploadTokenSha256, undefined);
        assert.equal(currentSpec.sha256, digest(bytes));
        return { targets: 3 };
      },
    });
    assert.equal(published.alreadyPublished, false);
    assert.equal(published.published.targets, 3);
    assert.equal(publishCalls, 1);

    const repeated = await finalizeAppReleaseUpload({
      token,
      rootDir,
      publish: async () => {
        publishCalls += 1;
      },
    });
    assert.equal(repeated.alreadyPublished, true);
    assert.equal(publishCalls, 1);

    const after = await appReleaseUploadStatus({ token, rootDir });
    assert.equal(after.consumed, true);
    assert.equal(after.receivedParts, 0);
    assert.deepEqual(after.receivedPartIndexes, []);
  } finally {
    await fs.promises.rm(rootDir, { recursive: true, force: true });
  }
});

test('does not publish when the combined APK checksum is wrong', async () => {
  const rootDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'novel-app-release-bad-'));
  const token = 'bad-release-capability';
  const expected = Buffer.from('expected apk');
  const uploaded = Buffer.from('different apk');
  await fs.promises.writeFile(
    path.join(rootDir, 'app-release.json'),
    `${JSON.stringify(releaseSpec({ token, bytes: expected }))}\n`,
  );
  try {
    await saveAppReleasePart({
      token,
      index: 0,
      partCount: 1,
      declaredSha256: digest(uploaded),
      stream: Readable.from(uploaded),
      rootDir,
    });
    await assert.rejects(
      finalizeAppReleaseUpload({
        token,
        rootDir,
        publish: async () => assert.fail('publisher must not run'),
      }),
      /app_release_checksum_mismatch/,
    );
  } finally {
    await fs.promises.rm(rootDir, { recursive: true, force: true });
  }
});

function releaseSpec({ token, bytes }) {
  return {
    versionName: '4.1.33',
    versionCode: 86,
    apkUrl: 'https://novel.kxhub.xyz/app3/app-release-4.1.33+86.apk',
    sha256: digest(bytes),
    force: false,
    notes: ['test release'],
    uploadTokenSha256: digest(Buffer.from(token)),
  };
}

function digest(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}
