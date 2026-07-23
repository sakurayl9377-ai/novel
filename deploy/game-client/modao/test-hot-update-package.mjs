import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import {
  managedHotUpdateBaseUrl,
  managedHotUpdateVersion,
  readManagedHotUpdateManifests,
} from "./prepare-hot-update.mjs";

const assetsRoot = process.argv[2];
if (!assetsRoot) {
  throw new Error("usage: node test-hot-update-package.mjs <decoded-assets-root>");
}

const indexPath = path.join(assetsRoot, "assets", "main", "index.js");
const applicationPath = path.join(assetsRoot, "src", "application.js");
const index = fs.readFileSync(indexPath, "utf8");
const application = fs.readFileSync(applicationPath, "utf8");
const { project, version } = readManagedHotUpdateManifests(assetsRoot);

assert.match(index, /SakuraHotUpdateReady/);
assert.match(index, /armUpdateTimeout\(1e4\)/);
assert.match(index, /armUpdateTimeout\(12e4\)/);
assert.match(index, /h=\[this\._storagePath\]/);
assert.match(
  index,
  /setTimeout\(\(\(\)=>\{[A-Za-z_$][\w$]*\.restart\(\)\}\),1500\)/,
);
assert.doesNotMatch(index, /HoeSeahPths|asset-mote\//);
assert.match(application, /SakuraHotUpdateReady/);
assert.match(application, /getWritablePath\(\) \+ 'sakura-hot\/'/);

for (const manifest of [project.value, version.value]) {
  assert.equal(manifest.version, managedHotUpdateVersion);
  assert.equal(
    manifest.packageUrl,
    `${managedHotUpdateBaseUrl}releases/${managedHotUpdateVersion}/`,
  );
  assert.equal(
    manifest.remoteVersionUrl,
    `${managedHotUpdateBaseUrl}version.manifest`,
  );
  assert.equal(
    manifest.remoteManifestUrl,
    `${managedHotUpdateBaseUrl}project.manifest`,
  );
  assert.doesNotMatch(JSON.stringify(manifest), /http:\/\//);
}
assert.ok(project.value.assets["assets/main/index.js"]);
assert.ok(project.value.assets["src/application.js"]);

let totalBytes = 0;
for (const [relative, asset] of Object.entries(project.value.assets)) {
  assert.doesNotMatch(relative, /(^|\/)\.\.(\/|$)|\\/);
  const source = path.join(assetsRoot, ...relative.split("/"));
  const data = fs.readFileSync(source);
  assert.equal(data.length, asset.size, `${relative} size`);
  assert.equal(
    crypto.createHash("md5").update(data).digest("hex"),
    asset.md5,
    `${relative} md5`,
  );
  totalBytes += data.length;
}
assert.ok(totalBytes > 0 && totalBytes < 64 * 1024 * 1024);

console.log(
  `managed hot update package tests passed (${Object.keys(project.value.assets).length} files, ${totalBytes} bytes)`,
);
