import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const managedHotUpdateVersion = "117";
export const managedHotUpdateBaseUrl =
  "https://novel.kxhub.xyz/games/modao/hot/";

function replaceOnce(source, label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

function walkFiles(root) {
  const result = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) result.push(...walkFiles(target));
    else if (entry.isFile()) result.push(target);
  }
  return result;
}

function manifestFiles(assetsRoot) {
  const remoteRoot = path.join(assetsRoot, "remote");
  const manifests = walkFiles(remoteRoot).filter((file) =>
    file.endsWith(".manifest"),
  );
  if (manifests.length !== 2) {
    throw new Error(
      `managed hot update manifests: expected 2 files, found ${manifests.length}`,
    );
  }
  const parsed = manifests.map((file) => ({
    file,
    value: JSON.parse(fs.readFileSync(file, "utf8")),
  }));
  const project = parsed.filter(
    ({ value }) => value.assets && typeof value.assets === "object",
  );
  const version = parsed.filter(
    ({ value }) => !value.assets || typeof value.assets !== "object",
  );
  if (project.length !== 1 || version.length !== 1) {
    throw new Error("managed hot update manifests: project/version mismatch");
  }
  return { project: project[0], version: version[0] };
}

function md5(file) {
  return crypto.createHash("md5").update(fs.readFileSync(file)).digest("hex");
}

export function patchHotUpdateApplication(source) {
  const before = `        start() {
          return cc.game.init({`;
  const after = `        start() {
          try {
            const fileUtils = cc.native && cc.native.fileUtils;
            if (
              fileUtils &&
              typeof localStorage !== 'undefined' &&
              localStorage.getItem('SakuraHotUpdateReady') === '1'
            ) {
              const updateRoot = fileUtils.getWritablePath() + 'sakura-hot/';
              if (
                typeof fileUtils.isDirectoryExist !== 'function' ||
                fileUtils.isDirectoryExist(updateRoot)
              ) {
                const searchPaths = fileUtils
                  .getSearchPaths()
                  .filter((value) => value !== updateRoot);
                searchPaths.unshift(updateRoot);
                fileUtils.setSearchPaths(searchPaths);
              } else {
                localStorage.removeItem('SakuraHotUpdateReady');
              }
            }
          } catch (error) {
            console.error('Unable to restore Sakura hot update', error);
          }
          return cc.game.init({`;
  return replaceOnce(
    source,
    "managed hot update cold-start bootstrap",
    before,
    after,
  );
}

export function prepareManagedHotUpdateAssets(
  assetsRoot,
  version = managedHotUpdateVersion,
) {
  if (!/^\d{1,9}$/.test(version)) {
    throw new Error("managed hot update version is invalid");
  }
  const applicationPath = path.join(assetsRoot, "src", "application.js");
  const application = fs.readFileSync(applicationPath, "utf8");
  fs.writeFileSync(
    applicationPath,
    patchHotUpdateApplication(application),
    "utf8",
  );

  const manifests = manifestFiles(assetsRoot);
  const metadata = {
    version,
    packageUrl: `${managedHotUpdateBaseUrl}releases/${version}/`,
    remoteVersionUrl: `${managedHotUpdateBaseUrl}version.manifest`,
    remoteManifestUrl: `${managedHotUpdateBaseUrl}project.manifest`,
  };
  Object.assign(manifests.version.value, metadata);
  Object.assign(manifests.project.value, metadata);
  manifests.project.value.searchPaths = [];

  for (const [relative, asset] of Object.entries(
    manifests.project.value.assets,
  )) {
    if (
      path.isAbsolute(relative) ||
      relative.includes("\\") ||
      relative.split("/").includes("..")
    ) {
      throw new Error(`managed hot update asset path is invalid: ${relative}`);
    }
    const source = path.join(assetsRoot, ...relative.split("/"));
    const stats = fs.statSync(source);
    if (!stats.isFile()) {
      throw new Error(`managed hot update asset is not a file: ${relative}`);
    }
    asset.size = stats.size;
    asset.md5 = md5(source);
    asset.compressed = false;
  }

  fs.writeFileSync(
    manifests.version.file,
    `${JSON.stringify(manifests.version.value, null, 2)}\n`,
    "utf8",
  );
  fs.writeFileSync(
    manifests.project.file,
    `${JSON.stringify(manifests.project.value, null, 2)}\n`,
    "utf8",
  );

  return {
    version,
    projectManifestPath: manifests.project.file,
    versionManifestPath: manifests.version.file,
  };
}

export function readManagedHotUpdateManifests(assetsRoot) {
  return manifestFiles(assetsRoot);
}
