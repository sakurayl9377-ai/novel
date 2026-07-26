# KDJX game release channel

KDJX uses an isolated, verified release channel on the download host:

- Manifest: `https://novel.kxhub.xyz/games/kdjx/manifest.json`
- APK: `https://novel.kxhub.xyz/games/kdjx/kdjx-<versionCode>-<sha12>.apk`
- APK URL: the single verified TLS entry `novel.kxhub.xyz`
- Five download parts: the APK stem plus `.part-000.apk` through
  `.part-004.apk`
- Hot update manifests: `https://novel.kxhub.xyz/games/kdjx/hot/`
- Server root: `/var/www/novel-download/games/kdjx`
- Download server: `47.88.26.14`

This channel is independent of the novel app under `/app3/`, the Modao game
under `/games/modao/`, and the application/game backend at `49.232.137.85`.
Do not run these helpers through the backend deployment scripts.

## Signing gate

`E:\workSpace\kdjx\kdjx.APK` is not a publishable artifact. Its metadata is
`com.kd.kdjxcs`, `2.1.0.0`, version code `3`, but `apksigner` reports stripped
v2/v3 signature blocks and the v1 entry digests no longer match the payload.
The embedded certificate is the generic Android test certificate, which the
publisher and server helper explicitly reject.

Obtain an intact upstream release or sign the final APK with the project's
controlled production key. Record the resulting certificate SHA-256 as
`<production-signer-sha256>` below. A certificate digest is public metadata;
the keystore and its password must remain outside Git and only in the secure
release environment.

## Build an offline release bundle

Verify the final APK first:

```powershell
apksigner verify --verbose --print-certs D:\release\kdjx-signed.apk
apkanalyzer manifest application-id D:\release\kdjx-signed.apk
apkanalyzer manifest version-name D:\release\kdjx-signed.apk
apkanalyzer manifest version-code D:\release\kdjx-signed.apk
```

Generate the immutable APK name and base manifest without contacting a server:

```powershell
powershell -ExecutionPolicy Bypass -File tool\publish_kdjx_game_release.ps1 `
  -ApkPath D:\release\kdjx-signed.apk `
  -VersionName 2.1.0.0 `
  -VersionCode 3 `
  -SigningCertificateSha256 <production-signer-sha256> `
  -ApprovedSigningCertificateSha256 <production-signer-sha256> `
  -Notes "Sakura SSO and Sakura Coin payment release"
```

The default output is `build/kdjx-release/`. Validate the exact staged pair:

```powershell
powershell -ExecutionPolicy Bypass -File tool\publish_kdjx_game_release.ps1 `
  -ValidateOnly `
  -ManifestPath build\kdjx-release\manifest.json `
  -ApkPath build\kdjx-release\kdjx-3-<sha12>.apk `
  -ApprovedSigningCertificateSha256 <production-signer-sha256>
```

`manifest.json.example` only documents fields. Its zero digests are invalid and
must never be published. The server adds the verified `parts` array after it
creates the five immutable pieces.

Build the Sakura app with the same KDJX signer pin and fixed host policy:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_kdjx_android_release.ps1 `
  -KdjxSigningCertificateSha256 <production-signer-sha256>
```

`novel.kxhub.xyz` is the only permitted public KDJX download host. Five
independently verified APK parts still provide the parallel download paths.

## Install the download channel

Upload a clean repository bundle to `47.88.26.14`, then run:

```bash
sudo bash deploy/download-server/install-kdjx-release-channel.sh \
  47.88.26.14 \
  <production-signer-sha256> \
  novel.kxhub.xyz
```

The installer adds a location include to the existing TLS server instead of
replacing its configuration. It verifies that the Modao and `/app3/` routes
are still present, tests Nginx before reload, and rolls all managed files back
if validation fails. The approved public signer digest is stored at
`/etc/novel/kdjx-release-signer.sha256`. The third argument must be exactly
`novel.kxhub.xyz`; the installer probes that TLS hostname directly against the
owned download origin with `curl --resolve novel.kxhub.xyz:443:47.88.26.14`.
It never publishes a raw-IP HTTPS URL or an undeployed mirror.

## Activate an APK release

Place only the generated `manifest.json` and its referenced APK in a root-owned
staging directory named like
`/tmp/novel-kdjx-release-2.1.0.0+3-A1B2C3`, then run:

```bash
sudo /usr/local/sbin/novel-kdjx-game-release-deploy \
  /tmp/novel-kdjx-release-2.1.0.0+3-A1B2C3
```

The helper checks the package contract, size, SHA-256, ZIP integrity, Android
signature, pinned signer and monotonic version. It installs the whole APK,
generates and verifies five parts, stores an immutable version manifest, then
atomically switches `manifest.json` last.

## Keep only the current APK release

The shared prune helper supports only `modao` and `kdjx`. It never traverses
subdirectories, so hot updates are outside its deletion scope. It only plans
strictly named whole APKs, `.part-000` through `.part-004`, and versioned APK
manifests that are not referenced by the current manifest.

Always preview first:

```bash
sudo /usr/local/sbin/novel-game-release-prune kdjx
sudo /usr/local/sbin/novel-game-release-prune modao
```

The JSON result includes `currentSha256`, `planId`, every absolute candidate
path, size and mtime. Preview also re-hashes the current whole APK and all
current parts before producing a plan. Review the list, then pass both values
back unchanged:

```bash
sudo /usr/local/sbin/novel-game-release-prune \
  kdjx --apply <currentSha256> <planId>
```

Apply fails before deleting anything if the current APK, candidate names,
sizes, or mtimes changed after the preview. Unknown files, `manifest.json`,
the current version manifest, current APK/parts, and `hot/` are never removed.

## Publish a hot update

A hot-update staging directory must be root-owned mode `0700`; every directory
inside it must be `0700` and every file `0600`. Its name is
`/tmp/novel-kdjx-hot-update-<numeric-version>-<token>` and it contains:

```text
project.manifest
version.manifest
release-metadata.json
releases/<numeric-version>/<asset paths from project.manifest>
```

Both Cocos manifests use these fixed URLs:

```text
packageUrl=https://novel.kxhub.xyz/games/kdjx/hot/releases/<version>/
remoteVersionUrl=https://novel.kxhub.xyz/games/kdjx/hot/version.manifest
remoteManifestUrl=https://novel.kxhub.xyz/games/kdjx/hot/project.manifest
```

`release-metadata.json` contains `version`, `assetCount`, and `totalBytes`.
After validating every asset's declared size and MD5, activate it with:

```bash
sudo /usr/local/sbin/novel-kdjx-hot-update-deploy \
  /tmp/novel-kdjx-hot-update-1-A1B2C3
```

This release channel does not package or deploy the extracted legacy server
tree. That source includes credentials, private addresses, logs, and database
dumps. Only the separately sanitized KDJX adapter defined by
`backend/docs/kdjx-adapter-contract.md` may be deployed to the backend host.
