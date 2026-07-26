#!/usr/bin/env python3
"""Overlay the KDJX Node adapter onto a known-good Novel backend release.

The production backend has other independently deployed game integrations.
This helper intentionally copies only the KDJX modules and makes narrow,
anchor-checked edits without depending on another game integration.
"""

from __future__ import print_function

import argparse
import shutil
import sys
from pathlib import Path


KDJX_CONFIG = """  kdjxDeviceAuthorizationUrl: env('KDJX_DEVICE_AUTHORIZATION_URL'),
  kdjxSsoSharedSecret: env('KDJX_SSO_SHARED_SECRET'),
  kdjxSessionTtlDays: Math.max(
    30,
    Math.min(3650, Math.trunc(envNumber('KDJX_SESSION_TTL_DAYS', 3650))),
  ),
  kdjxSessionMaxPerUser: Math.max(
    1,
    Math.min(50, Math.trunc(envNumber('KDJX_SESSION_MAX_PER_USER', 10))),
  ),
  kdjxLoginTicketTtlSeconds: Math.max(
    15,
    Math.min(
      60,
      Math.trunc(envNumber('KDJX_LOGIN_TICKET_TTL_SECONDS', 60)),
    ),
  ),
  kdjxDeviceCodeTtlSeconds: Math.max(
    300,
    Math.min(
      900,
      Math.trunc(envNumber('KDJX_DEVICE_CODE_TTL_SECONDS', 600)),
    ),
  ),
  kdjxDevicePollIntervalSeconds: Math.max(
    2,
    Math.min(
      15,
      Math.trunc(envNumber('KDJX_DEVICE_POLL_INTERVAL_SECONDS', 5)),
    ),
  ),
  kdjxPaymentCatalogFile: env('KDJX_PAYMENT_CATALOG_FILE'),
  kdjxPaymentCatalogJson: env('KDJX_PAYMENT_CATALOG_JSON'),
  kdjxPaymentVerifyUrl: env('KDJX_PAYMENT_VERIFY_URL'),
  kdjxPaymentFulfillmentUrl: env('KDJX_PAYMENT_FULFILLMENT_URL'),
  kdjxPaymentHmacSecret: env('KDJX_PAYMENT_HMAC_SECRET'),
  kdjxPaymentMaxAttempts: Math.max(
    1,
    Math.min(10, Math.trunc(envNumber('KDJX_PAYMENT_MAX_ATTEMPTS', 3))),
  ),
  kdjxPaymentTimeoutMs: Math.max(
    1000,
    Math.min(30000, Math.trunc(envNumber('KDJX_PAYMENT_TIMEOUT_MS', 5000))),
  ),
  kdjxPaymentClaimTtlMs: Math.max(
    30000,
    Math.min(600000, Math.trunc(envNumber('KDJX_PAYMENT_CLAIM_TTL_MS', 60000))),
  ),
"""

CONFIG_INSERT_ANCHOR = "  videoCoverDir: path.resolve(\n"
GAME_ROUTES_ANCHOR = "export async function gameRoutes(app) {\n"

KDJX_MODULE_NAMES = (
    "kdjx-config.js",
    "kdjx-device-auth.js",
    "kdjx-payments.js",
    "kdjx-schema.js",
    "kdjx-sso.js",
    "kdjx-url-policy.js",
    "routes-kdjx-game.js",
)

DEPLOY_HEALTH_ANCHOR = '''healthy() {
  curl -fsS --max-time 5 "$health_url" >/dev/null
}

'''

DEPLOY_REQUIRED_FILES_ANCHOR = (
    "for required in backend/package.json backend/package-lock.json "
    "backend/src/server.js backend/admin-dist/index.html; do"
)

DEPLOY_NEW_RELEASE_ANCHOR = 'chown -R "$app_user:$app_user" "$new_release"\n'

ENV_EXAMPLE_INSERT_ANCHOR = "\nVIDEO_COVER_DIR=./data/video-covers\n"

KDJX_ENV_EXAMPLE = """
# KDJX device authorization, long-lived revocable credentials, 60-second
# one-time login tickets, and Sakura coin payment. The app deep link only
# carries a short-lived device code.
KDJX_DEVICE_AUTHORIZATION_URL=sakura-novel://game/kdjx/authorize
KDJX_SSO_SHARED_SECRET=
KDJX_SESSION_TTL_DAYS=3650
KDJX_SESSION_MAX_PER_USER=10
KDJX_LOGIN_TICKET_TTL_SECONDS=60
KDJX_DEVICE_CODE_TTL_SECONDS=600
KDJX_DEVICE_POLL_INTERVAL_SECONDS=5
KDJX_PAYMENT_CATALOG_FILE=./catalogs/kdjx-payment-catalog.json
KDJX_PAYMENT_CATALOG_JSON=
KDJX_PAYMENT_VERIFY_URL=http://127.0.0.1:18080/internal/sakura/payments/verify
KDJX_PAYMENT_FULFILLMENT_URL=http://127.0.0.1:18080/internal/sakura/payments/fulfill
KDJX_PAYMENT_HMAC_SECRET=
KDJX_PAYMENT_MAX_ATTEMPTS=3
KDJX_PAYMENT_TIMEOUT_MS=5000
KDJX_PAYMENT_CLAIM_TTL_MS=60000
"""

KDJX_DEPLOY_VALIDATOR = r'''validate_kdjx_production_config() {
  local environment_file="$shared_root/.env"
  local catalog_file="$new_release/catalogs/kdjx-payment-catalog.json"
  [[ -r "$environment_file" ]] || fail "kdjx_environment_missing"
  [[ -f "$catalog_file" ]] || fail "kdjx_catalog_missing"

  "$node_bin" - "$environment_file" "$catalog_file" <<'NODE'
const fs = require('node:fs');

const [environmentFile, catalogFile] = process.argv.slice(2);
const source = fs.readFileSync(environmentFile, 'utf8');
const values = {};
for (const rawLine of source.split(/\r?\n/)) {
  const line = rawLine.trim();
  if (!line || line.startsWith('#')) continue;
  const normalized = line.startsWith('export ') ? line.slice(7).trim() : line;
  const equals = normalized.indexOf('=');
  if (equals < 1) continue;
  const key = normalized.slice(0, equals).trim();
  let value = normalized.slice(equals + 1).trim();
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    value = value.slice(1, -1);
  }
  values[key] = value;
}

const required = {
  KDJX_DEVICE_AUTHORIZATION_URL: 'sakura-novel://game/kdjx/authorize',
  KDJX_PAYMENT_CATALOG_FILE: './catalogs/kdjx-payment-catalog.json',
  KDJX_PAYMENT_VERIFY_URL: 'http://127.0.0.1:18080/internal/sakura/payments/verify',
  KDJX_PAYMENT_FULFILLMENT_URL: 'http://127.0.0.1:18080/internal/sakura/payments/fulfill',
  KDJX_SESSION_TTL_DAYS: '3650',
  KDJX_LOGIN_TICKET_TTL_SECONDS: '60',
};
for (const [key, expected] of Object.entries(required)) {
  if (values[key] !== expected) {
    process.stderr.write(`kdjx_configuration_invalid=${key}\n`);
    process.exit(1);
  }
}
for (const key of ['KDJX_SSO_SHARED_SECRET', 'KDJX_PAYMENT_HMAC_SECRET']) {
  if ((values[key] || '').length < 32) {
    process.stderr.write(`kdjx_configuration_invalid=${key}\n`);
    process.exit(1);
  }
}
const allowedKdjxKeys = new Set([
  'KDJX_DEVICE_AUTHORIZATION_URL',
  'KDJX_SSO_SHARED_SECRET',
  'KDJX_SESSION_TTL_DAYS',
  'KDJX_SESSION_MAX_PER_USER',
  'KDJX_LOGIN_TICKET_TTL_SECONDS',
  'KDJX_DEVICE_CODE_TTL_SECONDS',
  'KDJX_DEVICE_POLL_INTERVAL_SECONDS',
  'KDJX_PAYMENT_CATALOG_FILE',
  'KDJX_PAYMENT_CATALOG_JSON',
  'KDJX_PAYMENT_VERIFY_URL',
  'KDJX_PAYMENT_FULFILLMENT_URL',
  'KDJX_PAYMENT_HMAC_SECRET',
  'KDJX_PAYMENT_MAX_ATTEMPTS',
  'KDJX_PAYMENT_TIMEOUT_MS',
  'KDJX_PAYMENT_CLAIM_TTL_MS',
]);
if (Object.keys(values).some(
  (key) => key.startsWith('KDJX_') && !allowedKdjxKeys.has(key),
)) {
  process.stderr.write('kdjx_configuration_invalid=unsupported_kdjx_key\n');
  process.exit(1);
}
if ((values.KDJX_PAYMENT_CATALOG_JSON || '') !== '') {
  process.stderr.write('kdjx_configuration_invalid=KDJX_PAYMENT_CATALOG_JSON\n');
  process.exit(1);
}
if (/\b(?:192\.168\.|10\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(source)) {
  process.stderr.write('kdjx_configuration_invalid=legacy_private_address\n');
  process.exit(1);
}
const catalog = JSON.parse(fs.readFileSync(catalogFile, 'utf8'));
if (catalog.conversion !== '10_SAKURA_COINS_EQUAL_1_CNY' ||
    catalog.productCount !== 27 ||
    !Array.isArray(catalog.products) || catalog.products.length !== 27) {
  process.stderr.write('kdjx_catalog_invalid\n');
  process.exit(1);
}
NODE
}

'''


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def copy_file(source, destination):
    if not source.is_file() or source.is_symlink():
        fail("overlay file is missing or invalid: {}".format(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(source), str(destination))


def patch_config(path):
    content = path.read_text(encoding="utf-8")
    if "kdjxDeviceAuthorizationUrl:" not in content:
        if content.count(CONFIG_INSERT_ANCHOR) != 1:
            fail("Novel config anchor does not match the supported release")
        content = content.replace(
            CONFIG_INSERT_ANCHOR,
            KDJX_CONFIG + CONFIG_INSERT_ANCHOR,
            1,
        )
        path.write_text(content, encoding="utf-8")
    required = (
        "kdjxDeviceAuthorizationUrl:",
        "kdjxSsoSharedSecret:",
        "kdjxSessionTtlDays:",
        "kdjxLoginTicketTtlSeconds:",
        "kdjxPaymentVerifyUrl:",
        "kdjxPaymentFulfillmentUrl:",
        "kdjxPaymentHmacSecret:",
    )
    if any(marker not in path.read_text(encoding="utf-8") for marker in required):
        fail("Novel KDJX configuration is incomplete")


def patch_game_routes(path):
    content = path.read_text(encoding="utf-8")
    import_line = "import { kdjxGameRoutes } from './routes-kdjx-game.js';"
    if import_line not in content:
        if content.count(GAME_ROUTES_ANCHOR) != 1:
            fail("Novel game route import anchor does not match the supported release")
        content = content.replace(
            GAME_ROUTES_ANCHOR,
            import_line + "\n\n" + GAME_ROUTES_ANCHOR,
            1,
        )

    registration = "  app.register(kdjxGameRoutes);"
    if registration not in content:
        if content.count(GAME_ROUTES_ANCHOR) != 1:
            fail("Novel game route registration anchor does not match the supported release")
        content = content.replace(
            GAME_ROUTES_ANCHOR,
            GAME_ROUTES_ANCHOR + registration + "\n",
            1,
        )
    path.write_text(content, encoding="utf-8")


def patch_deploy_script(path):
    content = path.read_text(encoding="utf-8")
    if "validate_kdjx_production_config()" not in content:
        if content.count(DEPLOY_HEALTH_ANCHOR) != 1:
            fail("Novel deploy health anchor does not match the supported release")
        content = content.replace(
            DEPLOY_HEALTH_ANCHOR,
            DEPLOY_HEALTH_ANCHOR + KDJX_DEPLOY_VALIDATOR,
            1,
        )

    catalog_required = (
        "for required in backend/package.json backend/package-lock.json "
        "backend/src/server.js backend/admin-dist/index.html "
        "backend/catalogs/kdjx-payment-catalog.json; do"
    )
    if catalog_required not in content:
        if content.count(DEPLOY_REQUIRED_FILES_ANCHOR) != 1:
            fail("Novel deploy archive anchor does not match the supported release")
        content = content.replace(
            DEPLOY_REQUIRED_FILES_ANCHOR,
            catalog_required,
            1,
        )

    validation_call = DEPLOY_NEW_RELEASE_ANCHOR + "validate_kdjx_production_config\n"
    if validation_call not in content:
        if content.count(DEPLOY_NEW_RELEASE_ANCHOR) != 1:
            fail("Novel deploy release anchor does not match the supported release")
        content = content.replace(
            DEPLOY_NEW_RELEASE_ANCHOR,
            validation_call,
            1,
        )
    path.write_text(content, encoding="utf-8")


def patch_env_example(path):
    content = path.read_text(encoding="utf-8")
    if "KDJX_DEVICE_AUTHORIZATION_URL=" not in content:
        if content.count(ENV_EXAMPLE_INSERT_ANCHOR) != 1:
            fail("Novel env example anchor does not match the supported release")
        content = content.replace(
            ENV_EXAMPLE_INSERT_ANCHOR,
            KDJX_ENV_EXAMPLE + ENV_EXAMPLE_INSERT_ANCHOR,
            1,
        )
    required = (
        "KDJX_DEVICE_AUTHORIZATION_URL=sakura-novel://game/kdjx/authorize",
        "KDJX_SESSION_TTL_DAYS=3650",
        "KDJX_LOGIN_TICKET_TTL_SECONDS=60",
        "KDJX_PAYMENT_CATALOG_FILE=./catalogs/kdjx-payment-catalog.json",
        "KDJX_PAYMENT_VERIFY_URL=http://127.0.0.1:18080/internal/sakura/payments/verify",
        "KDJX_PAYMENT_FULFILLMENT_URL=http://127.0.0.1:18080/internal/sakura/payments/fulfill",
    )
    if any(marker not in content for marker in required):
        fail("Novel KDJX env example is incomplete")
    path.write_text(content, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-root", required=True)
    parser.add_argument("--overlay-root", required=True)
    args = parser.parse_args()

    backend_root = Path(args.backend_root).resolve()
    overlay_root = Path(args.overlay_root).resolve()
    source_root = overlay_root / "backend"
    if not (backend_root / "src" / "config.js").is_file():
        fail("backend root is not a Novel backend release")
    if not source_root.is_dir():
        fail("overlay root is invalid")

    for name in KDJX_MODULE_NAMES:
        copy_file(source_root / "src" / name, backend_root / "src" / name)
    copy_file(
        source_root / "catalogs" / "kdjx-payment-catalog.json",
        backend_root / "catalogs" / "kdjx-payment-catalog.json",
    )
    patch_config(backend_root / "src" / "config.js")
    patch_game_routes(backend_root / "src" / "routes-game.js")
    patch_deploy_script(backend_root / "scripts" / "deploy-production.sh")
    patch_env_example(backend_root / ".env.example")

    print("Novel KDJX backend adapter prepared at {}".format(backend_root))


if __name__ == "__main__":
    main()
