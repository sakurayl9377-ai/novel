import { spawn } from 'node:child_process';
import {
  createHash,
  randomUUID,
  timingSafeEqual,
} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

import { config } from './config.js';

export const appReleaseChunkBytes = 3 * 1024 * 1024;
const maximumReleaseBytes = 256 * 1024 * 1024;
const maximumPartCount = Math.ceil(maximumReleaseBytes / appReleaseChunkBytes);
const publisherPath = '/usr/local/sbin/novel-app-release-deploy';
const maximumHelperOutputBytes = 1024 * 1024;

export function loadAppReleaseSpec(rootDir = config.rootDir) {
  const specPath = path.join(rootDir, 'app-release.json');
  if (!fs.existsSync(specPath)) return null;

  let value;
  try {
    value = JSON.parse(fs.readFileSync(specPath, 'utf8'));
  } catch {
    throw releaseError('app_release_spec_invalid', 503);
  }
  const versionName = String(value?.versionName || '').trim();
  const versionCode = Number(value?.versionCode || 0);
  const sha256 = String(value?.sha256 || '').trim().toLowerCase();
  const uploadTokenSha256 = String(value?.uploadTokenSha256 || '')
    .trim()
    .toLowerCase();
  const apkUrl = String(value?.apkUrl || '').trim();
  const expectedUrl =
    `https://novel.kxhub.xyz/app3/app-release-${versionName}+${versionCode}.apk`;
  if (
    !/^\d+\.\d+\.\d+$/.test(versionName) ||
    !Number.isSafeInteger(versionCode) ||
    versionCode <= 0 ||
    !/^[a-f0-9]{64}$/.test(sha256) ||
    !/^[a-f0-9]{64}$/.test(uploadTokenSha256) ||
    apkUrl !== expectedUrl ||
    !Array.isArray(value?.notes)
  ) {
    throw releaseError('app_release_spec_invalid', 503);
  }
  return {
    versionName,
    versionCode,
    apkUrl,
    sha256,
    uploadTokenSha256,
    force: value.force === true,
    notes: value.notes
      .map((item) => String(item || '').trim())
      .filter(Boolean)
      .slice(0, 30),
  };
}

export function authorizeAppReleaseUpload(token, options = {}) {
  const spec = options.spec || loadAppReleaseSpec(options.rootDir);
  if (!spec) throw releaseError('app_release_upload_disabled', 404);
  const supplied = String(token || '').trim();
  if (!supplied || supplied.length > 512) {
    throw releaseError('app_release_upload_unauthorized', 401);
  }
  const actual = createHash('sha256').update(supplied).digest();
  const expected = Buffer.from(spec.uploadTokenSha256, 'hex');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw releaseError('app_release_upload_unauthorized', 401);
  }
  return spec;
}

export async function appReleaseUploadStatus({ token, rootDir = config.rootDir }) {
  const spec = authorizeAppReleaseUpload(token, { rootDir });
  const workspace = releaseWorkspace(rootDir, spec);
  const metadata = await readUploadMetadata(workspace);
  const receivedParts = await receivedPartIndexes(workspace);
  return {
    versionName: spec.versionName,
    versionCode: spec.versionCode,
    consumed: await exists(path.join(workspace, 'consumed.json')),
    partCount: metadata?.partCount || 0,
    receivedParts: receivedParts.length,
    receivedPartIndexes: receivedParts,
    chunkBytes: appReleaseChunkBytes,
  };
}

export async function saveAppReleasePart({
  token,
  index,
  partCount,
  declaredSha256,
  stream,
  rootDir = config.rootDir,
}) {
  const spec = authorizeAppReleaseUpload(token, { rootDir });
  const safePartCount = positiveInteger(partCount);
  const safeIndex = nonNegativeInteger(index);
  const partSha256 = String(declaredSha256 || '').trim().toLowerCase();
  if (
    safePartCount < 1 ||
    safePartCount > maximumPartCount ||
    safeIndex >= safePartCount ||
    !/^[a-f0-9]{64}$/.test(partSha256)
  ) {
    throw releaseError('app_release_part_invalid');
  }

  const workspace = releaseWorkspace(rootDir, spec);
  await fs.promises.mkdir(workspace, { recursive: true, mode: 0o700 });
  if (await exists(path.join(workspace, 'consumed.json'))) {
    throw releaseError('app_release_upload_consumed', 409);
  }
  await ensureUploadMetadata(workspace, spec, safePartCount);

  const partPath = path.join(workspace, partFileName(safeIndex));
  const temporaryPath = `${partPath}.${randomUUID()}.tmp`;
  const hasher = createHash('sha256');
  let bytes = 0;
  const meter = new Transform({
    transform(chunk, _encoding, callback) {
      bytes += chunk.length;
      if (bytes > appReleaseChunkBytes) {
        callback(releaseError('app_release_part_too_large', 413));
        return;
      }
      hasher.update(chunk);
      callback(null, chunk);
    },
  });
  try {
    await pipeline(
      stream,
      meter,
      fs.createWriteStream(temporaryPath, { flags: 'wx', mode: 0o600 }),
    );
    if (stream.truncated || bytes <= 0) {
      throw releaseError(
        stream.truncated ? 'app_release_part_too_large' : 'app_release_part_empty',
        stream.truncated ? 413 : 400,
      );
    }
    const actualSha256 = hasher.digest('hex');
    if (actualSha256 !== partSha256) {
      throw releaseError('app_release_part_checksum_mismatch');
    }
    await fs.promises.rename(temporaryPath, partPath);
    return {
      index: safeIndex,
      bytes,
      sha256: actualSha256,
      receivedParts: await receivedPartCount(workspace),
      partCount: safePartCount,
    };
  } finally {
    await fs.promises.rm(temporaryPath, { force: true }).catch(() => {});
  }
}

export async function finalizeAppReleaseUpload({
  token,
  rootDir = config.rootDir,
  publish = runReleasePublisher,
}) {
  const spec = authorizeAppReleaseUpload(token, { rootDir });
  const workspace = releaseWorkspace(rootDir, spec);
  const consumedPath = path.join(workspace, 'consumed.json');
  if (await exists(consumedPath)) {
    return { alreadyPublished: true, versionName: spec.versionName, versionCode: spec.versionCode };
  }
  const metadata = await readUploadMetadata(workspace);
  if (!metadata || metadata.versionCode !== spec.versionCode) {
    throw releaseError('app_release_upload_incomplete', 409);
  }

  const lockPath = path.join(workspace, 'finalize.lock');
  let lock;
  try {
    lock = await fs.promises.open(lockPath, 'wx', 0o600);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      throw releaseError('app_release_finalize_in_progress', 409);
    }
    throw error;
  }

  const stagingDir = await fs.promises.mkdtemp(
    path.join(os.tmpdir(), `novel-app-release-${spec.versionName}+${spec.versionCode}-`),
  );
  try {
    const apkName = `app-release-${spec.versionName}+${spec.versionCode}.apk`;
    const apkPath = path.join(stagingDir, apkName);
    const combined = await combineParts({
      workspace,
      partCount: metadata.partCount,
      destination: apkPath,
    });
    if (combined.sha256 !== spec.sha256) {
      throw releaseError('app_release_checksum_mismatch');
    }
    await fs.promises.writeFile(
      path.join(stagingDir, 'version.json'),
      `${JSON.stringify(publicManifest(spec), null, 2)}\n`,
      { encoding: 'utf8', mode: 0o600, flag: 'wx' },
    );

    const published = await publish(stagingDir, spec);
    await fs.promises.writeFile(
      consumedPath,
      `${JSON.stringify({
        versionName: spec.versionName,
        versionCode: spec.versionCode,
        sha256: spec.sha256,
        publishedAt: new Date().toISOString(),
      })}\n`,
      { encoding: 'utf8', mode: 0o600, flag: 'wx' },
    );
    await removePartFiles(workspace);
    return {
      alreadyPublished: false,
      versionName: spec.versionName,
      versionCode: spec.versionCode,
      sha256: spec.sha256,
      bytes: combined.bytes,
      published,
    };
  } finally {
    await lock.close().catch(() => {});
    await fs.promises.rm(lockPath, { force: true }).catch(() => {});
    await fs.promises.rm(stagingDir, { recursive: true, force: true }).catch(() => {});
  }
}

export function releaseTokenFromAuthorization(value) {
  const match = /^Release\s+([^\s]+)$/i.exec(String(value || '').trim());
  return match?.[1] || '';
}

async function combineParts({ workspace, partCount, destination }) {
  const output = fs.createWriteStream(destination, { flags: 'wx', mode: 0o600 });
  const hasher = createHash('sha256');
  let bytes = 0;
  try {
    for (let index = 0; index < partCount; index += 1) {
      const partPath = path.join(workspace, partFileName(index));
      if (!await exists(partPath)) throw releaseError('app_release_upload_incomplete', 409);
      for await (const chunk of fs.createReadStream(partPath)) {
        bytes += chunk.length;
        if (bytes > maximumReleaseBytes) throw releaseError('app_release_too_large', 413);
        hasher.update(chunk);
        if (!output.write(chunk)) await once(output, 'drain');
      }
    }
    if (bytes <= 0) throw releaseError('app_release_upload_incomplete', 409);
    const finished = once(output, 'finish');
    output.end();
    await finished;
    return { bytes, sha256: hasher.digest('hex') };
  } catch (error) {
    output.destroy();
    throw error;
  }
}

function runReleasePublisher(stagingDir) {
  return new Promise((resolve, reject) => {
    const child = spawn('sudo', ['-n', publisherPath, stagingDir], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    const stdout = [];
    const stderr = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(releaseError('app_release_publish_timeout', 504));
    }, 10 * 60 * 1000);
    timer.unref?.();
    child.stdout.on('data', (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes <= maximumHelperOutputBytes) stdout.push(chunk);
    });
    child.stderr.on('data', (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes <= maximumHelperOutputBytes) stderr.push(chunk);
    });
    child.on('error', () => finish(releaseError('app_release_publisher_unavailable', 503)));
    child.on('close', (code) => {
      const output = Buffer.concat(stdout).toString('utf8').trim();
      let decoded;
      try {
        decoded = JSON.parse(output || '{}');
      } catch {
        decoded = null;
      }
      if (code === 0 && decoded?.ok === true) {
        finish(null, decoded.data || {});
        return;
      }
      const detail = decoded?.error || Buffer.concat(stderr).toString('utf8').trim();
      const error = releaseError('app_release_publish_failed', 503);
      error.details = String(detail || 'publisher_failed').slice(0, 500);
      finish(error);
    });
  });
}

function publicManifest(spec) {
  return {
    versionName: spec.versionName,
    versionCode: spec.versionCode,
    apkUrl: spec.apkUrl,
    sha256: spec.sha256,
    force: spec.force,
    notes: spec.notes,
  };
}

function releaseWorkspace(rootDir, spec) {
  return path.join(rootDir, 'data', 'app-release-uploads', spec.uploadTokenSha256);
}

async function ensureUploadMetadata(workspace, spec, partCount) {
  const metadataPath = path.join(workspace, 'metadata.json');
  const expected = {
    versionName: spec.versionName,
    versionCode: spec.versionCode,
    sha256: spec.sha256,
    partCount,
  };
  try {
    await fs.promises.writeFile(metadataPath, `${JSON.stringify(expected)}\n`, {
      encoding: 'utf8',
      mode: 0o600,
      flag: 'wx',
    });
    return;
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error;
  }
  const current = await readUploadMetadata(workspace);
  if (JSON.stringify(current) !== JSON.stringify(expected)) {
    throw releaseError('app_release_upload_metadata_conflict', 409);
  }
}

async function readUploadMetadata(workspace) {
  try {
    return JSON.parse(await fs.promises.readFile(path.join(workspace, 'metadata.json'), 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw releaseError('app_release_upload_metadata_invalid', 409);
  }
}

async function receivedPartCount(workspace) {
  return (await receivedPartIndexes(workspace)).length;
}

async function receivedPartIndexes(workspace) {
  try {
    const names = await fs.promises.readdir(workspace);
    return names
      .filter((name) => /^part-\d{4}\.bin$/.test(name))
      .map((name) => Number(name.slice(5, 9)))
      .sort((left, right) => left - right);
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }
}

async function removePartFiles(workspace) {
  const names = await fs.promises.readdir(workspace);
  await Promise.all(
    names
      .filter((name) => /^part-\d{4}\.bin$/.test(name))
      .map((name) => fs.promises.rm(path.join(workspace, name), { force: true })),
  );
}

function partFileName(index) {
  return `part-${String(index).padStart(4, '0')}.bin`;
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 0;
}

function nonNegativeInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : -1;
}

async function exists(filePath) {
  try {
    await fs.promises.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function releaseError(code, statusCode = 400) {
  const error = new Error(code);
  error.publicCode = code;
  error.statusCode = statusCode;
  return error;
}
