# KDJX Legacy Runtime

This directory contains reproducible deployment assets for the KDJX legacy
runtime on the application backend host. It deliberately creates a new runtime
tree and never copies a legacy Supervisor configuration into production.

The only production network targets permitted by these assets are:

| Use | Address |
| --- | --- |
| KDJX login, game, and public backend routes | `49.232.137.85` |
| APK and hot-update distribution | `https://novel.kxhub.xyz/games/kdjx/` |
| Same-host dependencies | `127.0.0.1` |

The source layout used by the staging script is the actual KDJX layout:

```text
<source>/gosrc/tjgame/login
<source>/gosrc/tjgame/host
<source>/gosrc/tjgame/anti_cheat
<source>/release
<source>/release/online_fight_forward/cn_patch
```

`release/gosrc` is not used because that directory does not exist in the
source snapshot.

Only the numeric `cn_patch` file is consumed from
`release/online_fight_forward`. The legacy agent binary, deployment scripts,
and definitions in that directory are never copied into the staged runtime.

## Runtime Topology

`kdjx-runtime.target` starts the following local-only dependencies before the
client-facing services:

- MongoDB 3.6, bound to `127.0.0.1:27159`
- NSQ lookupd and nsqd, bound to loopback
- Go host services: account DB, gift DB, storage shards, PVP services, and
  cross services
- Go anti-cheat service
- System LuaJIT for anti-cheat and online-fight Lua runners
- One Python 2 game shard in an isolated container. The legacy configuration
  expands to several gigabytes in memory, so the 4 GB production host must not
  start a second shard without a capacity upgrade.
- The Go login server on TCP `16666`, with its HTTP sidecar bound to
  `127.0.0.1:18080`

The staging patch also binds anti-cheat metrics to `127.0.0.1:2112`; the
online-fight-forward unit explicitly binds its metrics port to loopback.
The NSQ units wait for their loopback health endpoints before systemd starts
dependent services, preventing cold-start races after a reboot.

The legacy Python payment listener is not staged or started. Sakura payments
are handled only by the Go login adapter at the private endpoints
`/internal/sakura/payments/verify` and `/internal/sakura/payments/fulfill`.
The Nginx snippet rejects public requests to those endpoints.

The staging step also replaces legacy SDK configuration with an empty config,
inserts a Sakura-only gate into the Go login check path, and patches the Go
verifier to accept only `kdjx_login_*` one-time tickets. Non-Sakura channels,
long-lived `kdjx_session_*` credentials, and legacy proof formats fail closed.

## Build A Runtime Tree

Prepare the unmodified KDJX source bundle outside this repository. The staging
script copies `release/login/patch` and `release/anti_cheat/game_scripts` into
its private candidate, sanitizes every inherited text endpoint, then performs a
strict owned-endpoint audit before building. It does not package the opaque
legacy anti-cheat agent binary: the online-fight service is patched to use its
source-provided LuaJIT runner. The output path must not already exist.

```bash
deploy/kdjx-backend/scripts/stage-kdjx-runtime.sh \
  --source /srv/kdjx-source/pokemon \
  --patch-source /srv/kdjx-source/pokemon/release/login/patch \
  --anti-cheat-scripts /srv/kdjx-source/pokemon/release/anti_cheat/game_scripts \
  --output /opt/kdjx/runtime/releases/20260726-1 \
  --go /opt/kdjx/toolchain/go/bin/go
```

The patch root must contain `cn/`. To review the sanitized input tree before a
release build, run `scripts/sanitize-kdjx-runtime-inputs.py` with those same
two input paths and a new `--output` directory. The staging script builds `login_server`,
`host_server`, `anti_cheat_server`, and `online_fight_forward_server` from the
source tree. It refuses to use bundled legacy binaries, legacy payment
listeners, legacy SDK configuration, or any existing destination directory.
The Go login patch URL is generated as
`https://novel.kxhub.xyz/games/kdjx/hot/`; it intentionally does not retain a
direct-IP or `/kdjx/patch/` legacy path.

After reviewing the generated manifest and address audit, make
`/opt/kdjx/runtime/current` point at the staged release using the host's
normal release-switch procedure. Keep `/etc/kdjx/runtime.env` on the server;
do not place that file in this repository. Start from
`templates/runtime.env.example`, replace its placeholders with independently
generated values, and set mode `0600`.

Build the Python 2 runtime image from `templates/legacy-python.Dockerfile`:

```bash
docker build -t kdjx-legacy-python:2.7 \
  -f deploy/kdjx-backend/templates/legacy-python.Dockerfile \
  deploy/kdjx-backend/templates
```

Install the distro LuaJIT package before enabling the runtime. The two Lua
services refuse to start when it is unavailable:

```bash
sudo apt-get update
sudo apt-get install -y luajit
```

Install the systemd unit templates and Nginx location snippet only after the
staged tree passes `scripts/audit-runtime-addresses.py --runtime-root ...`.
The templates intentionally do not enable or restart any service.

## Required Server-Side Files

```text
/etc/kdjx/runtime.env                         mode 0600, root-readable only
/opt/kdjx/runtime/current                     approved staged release
/var/lib/kdjx/mongo                           MongoDB data
/var/lib/kdjx/nsq                             NSQ data
/var/lib/kdjx/game/{1,2}                      Python runtime writable state
/var/log/kdjx                                 service logs
```

The MongoDB template uses no authentication because it is published only on
loopback. Do not change it to an externally reachable bind address. If Mongo
authentication is enabled later, keep the credential exclusively in
`/etc/kdjx/runtime.env` and regenerate the staged runtime; never add it to a
JSON configuration committed to Git.

## Public HTTP Routes

Add `nginx/kdjx-login-locations.conf` to the existing server block for the
backend host. It exposes only `/kdjx/version`, `/kdjx/notice`, and
`/kdjx/servers`, plus local `204` acknowledgements for `/kdjx/report`,
`/kdjx/word-check`, and `/kdjx/feedback`; it also serves local `200` support
and privacy pages and acknowledges `/games/kdjx/telemetry/` with `204`. It
does not proxy a catch-all path. The app and APK hot-update files remain on the
download host. The public device authorization flow returns a long-lived
`kdjx_session_*` credential only to the game's Android Keystore. Before each
TCP login, Native exchanges that credential at
`/novel-api/games/kdjx/sessions/login-ticket` for a 60-second
`kdjx_login_*` ticket. The Go login service sends only that ticket to the
private `/novel-api/games/kdjx/sessions/verify` endpoint, where it is consumed
atomically after the linked session and user are confirmed active. The Nginx
include explicitly rejects the private verify route before any general API
proxy; the long-lived credential never enters Lua or legacy TCP transport.

## Install Units

Copy the files in `systemd/` to `/etc/systemd/system/`, build the Python image,
and keep `/etc/kdjx/runtime.env` mode `0600`. Then run `systemctl daemon-reload`
and enable `kdjx-runtime.target`. The target does not start the legacy Python
payment listener. Before enabling it, run:

```bash
deploy/kdjx-backend/scripts/verify-deployment-assets.sh
```

Run `systemctl start kdjx-runtime.target` only after the runtime symlink,
private env file, Docker images, Nginx include, and firewall ports have all
been reviewed.

Run `scripts/healthcheck-kdjx-runtime.sh` after enabling the units and after
every release switch. It validates the local dependency sockets, service
states, private payment-route denial, public route behavior, and staged address
audit without printing secrets.

The Novel backend catalog registers KDJX as the fixed `kdjx` service group.
Its control helper maps that ID only to the reviewed `kdjx-*` units and target;
the public App catalog therefore exposes KDJX only while the complete runtime
is active. Stopping and disabling Modao removes Modao from the same catalog
without affecting KDJX.
