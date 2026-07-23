# Modao game APK release

This directory documents the isolated game release channel served at:

- Manifest: `https://novel.kxhub.xyz/games/modao/manifest.json`
- APK: `https://novel.kxhub.xyz/games/modao/modao-<versionCode>-<sha12>.apk`
- Five immutable parts: `https://novel.kxhub.xyz/games/modao/modao-<versionCode>-<sha12>.part-000.apk` through `.part-004.apk`
- Server root: `/var/www/novel-download/games/modao`
- Download server: `47.88.26.14`

It is independent of the novel app update channel under `/app3/`. Do not put
game APKs or the game manifest in `/app3/`.

The download server is also independent of the application/game backend at
`49.232.137.85`. Do not install this release helper through
`backend/scripts/bootstrap-production-deploy.sh` or
`backend/scripts/deploy-production.sh`; those scripts run on the backend host.

## Build an offline release bundle

Read the APK signer certificate SHA-256 from a trusted local Android SDK:

```powershell
apksigner verify --print-certs D:\release\modao.apk
```

Generate the versioned APK copy and manifest without contacting a server:

```powershell
powershell -ExecutionPolicy Bypass -File tool\publish_modao_game_release.ps1 `
  -ApkPath D:\release\modao.apk `
  -VersionName 10.0.0.0 `
  -VersionCode 2023981000 `
  -SigningCertificateSha256 c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c `
  -Notes "Initial app game-center release"
```

The generator uses local `apkanalyzer` and `apksigner` tools to verify the APK
application ID, version, and signer. The only approved signing certificate is
`c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c`.
`-SkipApkMetadataCheck` is available only for publisher unit tests; production
releases must not use it.

The default output is `build/modao-release/`. Validate the exact bundle again
before staging it for deployment:

```powershell
powershell -ExecutionPolicy Bypass -File tool\publish_modao_game_release.ps1 `
  -ValidateOnly `
  -ManifestPath build\modao-release\manifest.json `
  -ApkPath build\modao-release\modao-2023981000-<sha12>.apk
```

`manifest.json.example` documents the final public manifest shape. Its zero
APK and part digests are invalid for production and must never be published.
The offline publisher deliberately emits only the full-APK fields; the trusted
server helper derives and replaces the `parts` array from the verified APK.

## Install or upgrade the download server

Upload a clean repository release bundle to `47.88.26.14`, then run the
dedicated installer on that host:

```bash
sudo bash deploy/download-server/install-modao-release-channel.sh 47.88.26.14
```

The installer refuses any other server acknowledgement. It validates the
existing and candidate Nginx configuration, requires `apksigner`, installs the
helper at `/usr/local/sbin/novel-modao-game-release-deploy`, preserves the
existing `/app3/` routes, and rolls back its files if validation or reload
fails. On the Alibaba Linux download host it updates
`/etc/nginx/conf.d/novel-download.conf` directly and does not create a
`sites-enabled` symlink.

## Activate a game release

Place only the generated `manifest.json` and its referenced APK into a staging
directory named like `/tmp/novel-modao-release-10.0.0.0+2023981000-A1B2C3`, then run:

```bash
sudo /usr/local/sbin/novel-modao-game-release-deploy \
  /tmp/novel-modao-release-10.0.0.0+2023981000-A1B2C3
```

The server helper validates the URL, package name, size, content SHA-256,
the fixed certificate field, the APK's actual cryptographic signature, ZIP
integrity, and monotonic version code. It keeps the complete immutable APK for
older App versions, then derives five byte-for-byte contiguous, near-equal
parts, verifies every part SHA-256, and adds their `index`, `url`, `sizeBytes`,
and `sha256` fields to the public manifest. All APK and part files are present
before it atomically switches the history manifest and `manifest.json` last.

For the current 2,105,724,535-byte APK, all five parts are exactly 421,144,907
bytes. Part names end in `.apk`, an extension Cloudflare caches by default, and
Nginx serves them with `public, max-age=31536000, immutable, no-transform` plus
Range support. This keeps each object comfortably below Cloudflare's 512 MB
Free/Pro/Business cache ceiling and lets the App download the five objects in
parallel. The full 2 GB APK remains `no-store` and is only the compatibility
fallback.
