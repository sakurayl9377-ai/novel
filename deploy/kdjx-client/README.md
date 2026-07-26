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
  --server-patch-catalog-dir E:\workSpace\kdjx\mnt\pokemon\release\login\patch\cn `
  --server-patch-files-dir E:\workSpace\kdjx\www\wwwroot\game\pokemon\patch `
  --hot-version 39 `
  --login-patch 9 `
  --apk-version-code 4
```

These three values are independent release contracts:

| CLI value | Written to | Current production value |
| --- | --- | --- |
| `--hot-version` | Compatibility Cocos manifests and `releases/<version>` | `39` for the next compatibility release |
| `--login-patch` | Go catalog, download path, and hot `res/version.plist` | `9` for the first Sakura update |
| `--apk-version-code` | Android manifest and apktool rebuild metadata | `4`, strictly above the source APK's `3` |

`--hot-version` and `--login-patch` are both required so a hot release number
can never silently become the legacy updater patch. For an APK build the
builder reads and preserves the source APK's real patch baseline. The original
APK is `patch=1`; it is not equivalent to patch 8 and must not be relabeled.
The builder therefore writes owned endpoints with `patch=1` into the bootstrap
APK while the downloadable `res/version.plist` contains `patch=9`.

Before producing output, the builder audits the retained server catalog and
download tree supplied by `--server-patch-catalog-dir` and
`--server-patch-files-dir`. For this release it requires the cumulative
`8.json` and checks all 2553 entries against the exact retained files.

Patch 8 still contains historical endpoints, so patch 9 is a new cumulative
snapshot. The builder copies all 2553 patch 8 names, replaces the owned plist
and application files in both the root and `x64/` namespaces, and adds six new
root/`x64` SDK adapter names. The resulting `9.json` has 2559 entries, all
marked `patch=9`, and the complete tree is endpoint-audited. This causes the Go
last-patch-wins merge to replace every patch 8 name for clients starting at
either patch 1 or patch 8.

Catalog names are sorted by POSIX relative path before the deterministic
`git_version` revision is calculated. The download-server deploy helper
recomputes that revision as well as every file size and MD5.

Patch 9 is fail-closed to compatibility version 39, source APK patch 1, the
single audited patch 8 upgrade path with 2553 files, and APK versionCode 4.
The download-server deploy helper separately requires all 2559 final entries
and every owned root/`x64` overlay. These guards prevent a partial catalog or a
mislabeled bootstrap APK from being published under the first Sakura release
number.

APK builds also require `--apk-version-code`, reject a value that does not
increase the source APK version, and decode the rebuilt APK's manifest to
verify the requested value. A hot-only `--skip-apk` build rejects
`--apk-version-code` as an unused and potentially misleading argument.

The output contains:

- `kdjx-sakura-unsigned.apk`: repacked bootstrap APK, deliberately unsigned.
- `hot-staging/9/`: files served from the legacy `patch_url + patch + / + name`
  contract.
- `login-patch/cn/9.json`: catalog installed in the Go login backend.
- `hot-staging/legacy-patch.json`: deploy-helper metadata; not a public file.
- `hot-staging/releases/39/` and manifests: compatibility Cocos artifacts.
- `verification.json`: generated endpoint and digest audit.

The output directory is marked by the script. `--force` removes only a
previously marked output directory.

Run the version-contract regression tests with:

```powershell
python -m unittest discover -s E:\workSpace\novel\deploy\kdjx-client `
  -p "test_*.py" -v
```

## Runtime Contract

| Concern | Client target |
| --- | --- |
| TCP login | `49.232.137.85:16666` |
| Legacy discovery | `https://49.232.137.85/kdjx/{servers,version,notice}` |
| Device authorization API | `https://49.232.137.85/novel-api/games/kdjx/device-authorizations` |
| One-time login ticket API | `https://49.232.137.85/novel-api/games/kdjx/sessions/login-ticket` |
| Legacy patch downloads | `https://novel.kxhub.xyz/games/kdjx/hot/` |

`reportUrl`, `disableWordCheckUrl`, and `feedBackUrl` are also namespaced
under `/kdjx/`. The backend nginx configuration must provide controlled owned
handlers for `/kdjx/report`, `/kdjx/word-check`, and `/kdjx/feedback` (a
no-op/204 endpoint is acceptable where the legacy service is intentionally not
retained). They must not be redirected to a historical address.

The production client updater reads `/kdjx/version`. The Go service loads
`login-patch/cn/<patch>.json` and returns catalog entries containing `name`,
`size`, `md5`, and `patch`. The client downloads each entry from:

```text
https://novel.kxhub.xyz/games/kdjx/hot/<patch>/<name>
```

For the first Sakura release, clients at patch 1 and patch 8 resolve the final
cumulative entries from `9.json`; a client at patch 9 receives an empty file
list. Every catalog entry is checked against the staged file's exact byte size
and MD5 before the build succeeds.

`project.manifest` and `version.manifest` remain compatibility artifacts only.
They are not the active updater protocol used by this client.

## Backend Catalog Release

`deploy-kdjx-hot-update.sh` publishes the immutable download-server trees under
`/games/kdjx/hot/9/` and `/games/kdjx/hot/releases/39/`, then atomically
switches the compatibility manifests. It never writes the application backend.

Install `login-patch/cn/9.json` through a new KDJX runtime release: place it
beside the retained `8.json` in the release patch source, run
`deploy/kdjx-backend/scripts/stage-kdjx-runtime.sh --patch-source <patch-root>`
to create a fresh `/opt/kdjx/runtime/releases/<release>` tree, then atomically
switch `/opt/kdjx/runtime/current` using the normal release-switch procedure.
Restart the login service only after the download-server patch 9 tree is
published. Never copy `9.json` directly into the active runtime.

`http://47.88.26.14/kdjx/patch/` is not compatible with the managed release
channel and must not be emitted by any runtime generator.

## Sakura Login And Payment

`SakuraGameActivity` implements the public device authorization flow:

1. It requests a device code from the owned Novel API.
2. It validates the server `userCode` against `verificationUriComplete` and
   shows that code in a non-cancellable KDJX confirmation dialog.
3. Only after the user confirms, it opens
   `sakura-novel://game/kdjx/authorize?...` in
   `com.novel.novel_app`.
4. After the App approval return it polls the public token endpoint.
5. It stores the returned `kdjx_session_*` credential in Android Keystore:
   AES-GCM on API 23+, RSA wrapping on API 18-22, and never plaintext.
6. Before every login it sends the saved credential over HTTPS to the public
   login-ticket endpoint. The response binds the current Sakura user and
   contains a 60-second `kdjx_login_*` ticket. A revoked or mismatched
   credential is cleared and re-authorized, while transient network errors do
   not erase the long-lived credential.
7. Native returns only the one-time ticket to Lua. The Lua adapter sets
   `channel=sakura` and places that ticket in both legacy login fields. The Go
   login service accepts only `kdjx_login_*` and atomically consumes it through
   the private verifier; `kdjx_session_*` never enters Lua or TCP transport.

The APK intentionally ignores externally supplied `sakura_sso_ticket` and
`sakura_sso_exchange_url` values. It mints a fresh ticket directly from its
Keystore credential for every login, and never accepts a credential from a
deep link. No internal SSO endpoint or shared secret appears in the APK.

The Lua adapter sends only game order/product/account/role/server identifiers
to the Sakura App. Payment cost is calculated server-side from `productId`.
The game keeps its original `XX元` labels unchanged.

An in-flight payment and its return nonce are stored for at most 15 minutes.
If Android recreates the game Activity while Sakura is confirming payment, the
validated return atomically replaces that pending record with a terminal
result. The same game order receives that result when Lua reconnects; it does
not reopen Sakura or remain blocked until the timeout.

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
