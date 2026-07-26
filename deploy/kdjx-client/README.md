# KDJX Sakura Client Build

This directory creates the KDJX Sakura hot update and an unsigned bootstrap
APK. It never signs, uploads, deploys, or stores a key, password, token, or
server secret.

The original APK's Lua implementation is embedded in the runtime. The client
therefore uses a Cocos hot update for Lua behavior and a small `classes2.dex`
bridge for Android App-to-App authorization and payment returns.

## Source Input

Do not use `patch/<number>/src/app.*` as source input. Those are flattened
historic release files and do not contain the complete modules needed for a
safe replacement.

Use a checked-out KDJX tree with a complete `application/src` hierarchy. This
workspace currently resolves it from:

```text
E:\workSpace\kdjx\mnt\pokemon\release\anti_cheat\game_scripts\application\src
```

The preparation helper copies only the five required Lua source files into a
disposable input directory:

```powershell
python E:\workSpace\novel\deploy\kdjx-client\prepare_kdjx_client_source.py `
  --kdjx-root E:\workSpace\kdjx `
  --output E:\workSpace\novel\tmp\kdjx-client-source
```

`build_kdjx_client.py --game-source E:\workSpace\kdjx` also resolves this
full hierarchy directly. It rejects a flattened patch directory.

## Build

```powershell
python E:\workSpace\novel\deploy\kdjx-client\build_kdjx_client.py `
  --apk E:\workSpace\kdjx\kdjx.APK `
  --game-source E:\workSpace\novel\tmp\kdjx-client-source `
  --output E:\workSpace\novel\tmp\kdjx-client-build `
  --hot-version 38
```

The output contains:

- `kdjx-sakura-unsigned.apk`: repacked bootstrap APK, deliberately unsigned.
- `hot-staging/`: input for `deploy/download-server/deploy-kdjx-hot-update.sh`.
- `verification.json`: generated endpoint and digest audit.

The output directory is marked by the script. `--force` removes only a
previously marked output directory.

## Runtime Contract

| Concern | Client target |
| --- | --- |
| TCP login | `49.232.137.85:16666` |
| Legacy discovery | `https://49.232.137.85/kdjx/{servers,version,notice}` |
| Device authorization API | `https://49.232.137.85/novel-api/games/kdjx/device-authorizations` |
| Cocos hot update | `https://novel.kxhub.xyz/games/kdjx/hot/` |

`reportUrl`, `disableWordCheckUrl`, and `feedBackUrl` are also namespaced
under `/kdjx/`. The backend nginx configuration must provide controlled owned
handlers for `/kdjx/report`, `/kdjx/word-check`, and `/kdjx/feedback` (a
no-op/204 endpoint is acceptable where the legacy service is intentionally not
retained). They must not be redirected to a historical address.

The hot-update manifest URLs are fixed to:

```text
packageUrl=https://novel.kxhub.xyz/games/kdjx/hot/releases/<version>/
remoteVersionUrl=https://novel.kxhub.xyz/games/kdjx/hot/version.manifest
remoteManifestUrl=https://novel.kxhub.xyz/games/kdjx/hot/project.manifest
```

`http://47.88.26.14/kdjx/patch/` is not compatible with the managed release
channel and must not be emitted by any runtime generator.

## Sakura Login And Payment

`SakuraGameActivity` implements the public device authorization flow:

1. It requests a device code from the owned Novel API.
2. It opens only `sakura-novel://game/kdjx/authorize?...` in
   `com.novel.novel_app`.
3. After the App approval return it polls the public token endpoint.
4. It stores the returned `kdjx_session_*` credential in Android Keystore:
   AES-GCM on API 23+, RSA wrapping on API 18-22, and never plaintext.
5. The Lua adapter sets `channel=sakura` and uses the saved credential for
   both legacy login fields. The Go login service validates it with its
   server-only shared secret.

The APK intentionally ignores `sakura_sso_ticket` and
`sakura_sso_exchange_url`; Game Center should launch the installed KDJX game
directly instead of minting an unused short ticket. No internal SSO endpoint
or shared secret appears in the APK.

The Lua adapter sends only game order/product/account/role/server identifiers
to the Sakura App. Payment cost is calculated server-side from `productId`.
The game keeps its original `XX元` labels unchanged.

## Audit And Signing Gate

Before producing `verification.json`, the build scans every hot-update file
and every ZIP entry in the generated APK, including `classes*.dex`, for known
legacy KDJX IPs and hosts. It also replaces the original config plist, legacy
SDK host configuration, legacy privacy/pingback URLs, and disables bundled
legacy telemetry manifest metadata.

The unsigned APK is not publishable. On the download server, use the
server-only Sakura release keystore to zipalign and sign it, then run
`apksigner verify --verbose --print-certs` and publish through the existing
five-part release helper. Do not copy a keystore, alias password, or signed
APK into this repository.
