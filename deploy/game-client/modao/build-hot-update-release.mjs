import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import {
  managedHotUpdateBaseUrl,
  readManagedHotUpdateManifests,
} from "./prepare-hot-update.mjs";

const [assetsRoot, outputRoot, requestedVersion] = process.argv.slice(2);
if (!assetsRoot || !outputRoot) {
  throw new Error(
    "usage: node build-hot-update-release.mjs <decoded-assets-root> <output-root> [release-version]",
  );
}
if (fs.existsSync(outputRoot)) {
  throw new Error("hot update output already exists");
}

const { project, version } = readManagedHotUpdateManifests(assetsRoot);
const embeddedVersion = String(project.value.version || "");
const releaseVersion = requestedVersion || embeddedVersion;
if (
  !/^\d{1,9}$/.test(releaseVersion) ||
  version.value.version !== embeddedVersion ||
  !/^\d{1,9}$/.test(embeddedVersion) ||
  Number(releaseVersion) < Number(embeddedVersion)
) {
  throw new Error("hot update manifest versions do not match");
}
const expectedMetadata = {
  version: releaseVersion,
  packageUrl: `${managedHotUpdateBaseUrl}releases/${releaseVersion}/`,
  remoteVersionUrl: `${managedHotUpdateBaseUrl}version.manifest`,
  remoteManifestUrl: `${managedHotUpdateBaseUrl}project.manifest`,
};
for (const manifest of [project.value, version.value]) {
  Object.assign(manifest, expectedMetadata);
}

const releaseRoot = path.join(outputRoot, "releases", releaseVersion);
fs.mkdirSync(releaseRoot, { recursive: true });
let totalBytes = 0;
for (const [relative, asset] of Object.entries(project.value.assets)) {
  if (
    path.isAbsolute(relative) ||
    relative.includes("\\") ||
    relative.split("/").includes("..")
  ) {
    throw new Error(`hot update asset path is invalid: ${relative}`);
  }
  const source = path.join(assetsRoot, ...relative.split("/"));
  const data = fs.readFileSync(source);
  const digest = crypto.createHash("md5").update(data).digest("hex");
  if (data.length !== asset.size || digest !== asset.md5) {
    throw new Error(`hot update asset metadata mismatch: ${relative}`);
  }
  const destination = path.join(releaseRoot, ...relative.split("/"));
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
  totalBytes += data.length;
}
fs.writeFileSync(
  path.join(outputRoot, "version.manifest"),
  `${JSON.stringify(version.value, null, 2)}\n`,
  "utf8",
);
fs.writeFileSync(
  path.join(outputRoot, "project.manifest"),
  `${JSON.stringify(project.value, null, 2)}\n`,
  "utf8",
);
fs.writeFileSync(
  path.join(outputRoot, "release-metadata.json"),
  `${JSON.stringify(
    {
      version: releaseVersion,
      assetCount: Object.keys(project.value.assets).length,
      totalBytes,
    },
    null,
    2,
  )}\n`,
  "utf8",
);

console.log(
  JSON.stringify({
    ok: true,
    version: releaseVersion,
    assetCount: Object.keys(project.value.assets).length,
    totalBytes,
  }),
);
