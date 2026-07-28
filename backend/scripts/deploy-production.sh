#!/usr/bin/env bash
set -euo pipefail

archive="${1:-}"
revision="${2:-}"
expected_checksum="${3:-}"
config_file="/etc/novel-backend-deploy.conf"
if [[ -f "$config_file" ]]; then
  # shellcheck source=/dev/null
  source "$config_file"
fi
app_link="${NOVEL_BACKEND_DIR:-/opt/novel-interaction-backend}"
service="${NOVEL_BACKEND_SERVICE:-novel-interaction.service}"
app_user="${NOVEL_BACKEND_USER:-ubuntu}"
release_root="${NOVEL_BACKEND_RELEASE_DIR:-/opt/novel-interaction-releases}"
shared_root="${NOVEL_BACKEND_SHARED_DIR:-/opt/novel-interaction-shared}"
database_backup_root="${NOVEL_DATABASE_BACKUP_DIR:-/opt/novel-interaction-db-backups}"
node_bin="${NOVEL_NODE_BIN:-/usr/local/bin/node}"
npm_bin="${NOVEL_NPM_BIN:-/usr/local/bin/npm}"
proxy_url="${NOVEL_DEPLOY_PROXY:-http://127.0.0.1:20808}"
health_url="${NOVEL_BACKEND_HEALTH_URL:-http://127.0.0.1:3010/health}"
database_path="${NOVEL_DATABASE_PATH:-$shared_root/data/interaction.sqlite}"
lock_file="/var/lock/novel-backend-deploy.lock"

fail() {
  echo "deploy_error=$1" >&2
  exit 1
}

healthy() {
  curl -fsS --max-time 5 "$health_url" >/dev/null
}

validate_kdjx_production_config() {
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
  KDJX_GM_DELIVERY_URL: 'http://127.0.0.1:18080/internal/sakura/gm/deliveries',
  KDJX_GM_DELIVERY_TIMEOUT_MS: '20000',
  KDJX_SESSION_TTL_DAYS: '3650',
  KDJX_LOGIN_TICKET_TTL_SECONDS: '60',
};
for (const [key, expected] of Object.entries(required)) {
  if (values[key] !== expected) {
    process.stderr.write(`kdjx_configuration_invalid=${key}\n`);
    process.exit(1);
  }
}
for (const key of [
  'KDJX_SSO_SHARED_SECRET',
  'KDJX_PAYMENT_HMAC_SECRET',
  'KDJX_GM_DELIVERY_HMAC_SECRET',
]) {
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
  'KDJX_GM_DELIVERY_URL',
  'KDJX_GM_DELIVERY_HMAC_SECRET',
  'KDJX_GM_DELIVERY_TIMEOUT_MS',
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

wait_for_health() {
  for _ in $(seq 1 20); do
    healthy && return 0
    sleep 1
  done
  return 1
}

[[ $EUID -eq 0 ]] || fail "root_required"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "revision_invalid"
[[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "checksum_invalid"
[[ "$archive" == "/tmp/novel-backend-${revision}.tar.gz" ]] || fail "archive_path_invalid"
[[ -f "$archive" ]] || fail "archive_missing"
[[ -x "$node_bin" && -x "$npm_bin" ]] || fail "node_runtime_missing"
id "$app_user" >/dev/null 2>&1 || fail "app_user_missing"

exec 9>"$lock_file"
flock -n 9 || fail "deployment_in_progress"

actual_checksum="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$actual_checksum" == "$expected_checksum" ]] || fail "checksum_mismatch"

archive_entries="$(tar -tzf "$archive")"
for required in backend/package.json backend/package-lock.json backend/src/server.js backend/admin-dist/index.html backend/catalogs/kdjx-payment-catalog.json; do
  grep -Fxq "$required" <<<"$archive_entries" || fail "archive_layout_invalid"
done
while IFS= read -r entry; do
  case "$entry" in
    backend/.env.example) ;;
    */.env|*/.env.*|*/data|*/data/*|*/node_modules|*/node_modules/*|*/__pycache__|*/__pycache__/*|*.pyc|*/.git|*/.git/*|*/.ssh|*/.ssh/*|*.pem|*.key|*.p12|*.pfx)
      fail "archive_contains_private_files"
      ;;
  esac
done <<<"$archive_entries"
if grep -Eq '(^|/)\.\.(/|$)|^/' <<<"$archive_entries"; then
  fail "archive_path_traversal"
fi

work_dir="$(mktemp -d /opt/novel-backend-deploy.XXXXXX)"
new_release="$release_root/$revision"
previous_release=""
helper_target="/usr/local/sbin/novel-mihomo-control"
updater_target="/usr/local/libexec/mihomo-update-subscription"
deploy_script_target="/usr/local/sbin/novel-backend-deploy"
app_release_target="/usr/local/sbin/novel-app-release-deploy"
game_helper_target="/usr/local/sbin/novel-game-service-control"
helper_backup="$work_dir/novel-mihomo-control.previous"
updater_backup="$work_dir/mihomo-update-subscription.previous"
deploy_script_backup="$work_dir/novel-backend-deploy.previous"
app_release_backup="$work_dir/novel-app-release-deploy.previous"
game_helper_backup="$work_dir/novel-game-service-control.previous"
sudoers_path="/etc/sudoers.d/${app_user}-novel-mihomo-control"
sudoers_backup="$work_dir/mihomo-sudoers.previous"
app_release_sudoers_path="/etc/sudoers.d/${app_user}-novel-app-release"
app_release_sudoers_backup="$work_dir/app-release-sudoers.previous"
game_sudoers_path="/etc/sudoers.d/${app_user}-novel-game-service-control"
game_sudoers_backup="$work_dir/game-service-sudoers.previous"
sudoers_next="${sudoers_path}.next.$$"
helper_next="$(dirname "$helper_target")/.novel-mihomo-control.next.$$"
updater_next="$(dirname "$updater_target")/.mihomo-update-subscription.next.$$"
deploy_script_next="$(dirname "$deploy_script_target")/.novel-backend-deploy.next.$$"
app_release_next="$(dirname "$app_release_target")/.novel-app-release-deploy.next.$$"
sudoers_restore="${sudoers_path}.restore.$$"
app_release_sudoers_next="${app_release_sudoers_path}.next.$$"
app_release_sudoers_restore="${app_release_sudoers_path}.restore.$$"
game_sudoers_restore="${game_sudoers_path}.restore.$$"
helper_restore="$(dirname "$helper_target")/.novel-mihomo-control.restore.$$"
updater_restore="$(dirname "$updater_target")/.mihomo-update-subscription.restore.$$"
deploy_script_restore="$(dirname "$deploy_script_target")/.novel-backend-deploy.restore.$$"
app_release_restore="$(dirname "$app_release_target")/.novel-app-release-deploy.restore.$$"
game_helper_restore="$(dirname "$game_helper_target")/.novel-game-service-control.restore.$$"
switched=false
tools_installed=false
committed=false

cleanup() {
  rm -rf "$work_dir"
  rm -f \
    "$archive" \
    "${app_link}.next" \
    "${app_link}.rollback" \
    "$sudoers_next" \
    "$helper_next" \
    "$updater_next" \
    "$deploy_script_next" \
    "$app_release_next" \
    "$sudoers_restore" \
    "$app_release_sudoers_next" \
    "$app_release_sudoers_restore" \
    "$game_sudoers_restore" \
    "$helper_restore" \
    "$updater_restore" \
    "$deploy_script_restore" \
    "$app_release_restore" \
    "$game_helper_restore"
}

remove_retired_video_releases() {
  local active_release="$1"
  while IFS= read -r -d '' release; do
    [[ "$release" == "$active_release" ]] && continue
    if find "$release" -type f \
      \( -iname '*dbzy*' -o -iname '*suibian*' \) \
      -print -quit | grep -q .; then
      rm -rf "$release"
    fi
  done < <(find "$release_root" -mindepth 1 -maxdepth 1 -type d -print0)
}

verify_retired_video_cleanup() {
  if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(DBZY_|SUIBIAN_|VIDEO_POLICY_TIMEZONE[[:space:]]*=)' "$shared_root/.env"; then
    fail "retired_video_environment_present"
  fi
  [[ ! -e "$shared_root/data/dbzy-cache.json" ]] || fail "retired_video_cache_present"
  [[ ! -e "$shared_root/data/suibian-catalog.json" ]] || fail "retired_video_catalog_present"
  local legacy_tables
  legacy_tables="$(sqlite3 "$database_path" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('suibian_watch_history','suibian_likes','suibian_favorites','video_category_policies','video_content_overrides');")"
  [[ "$legacy_tables" == "0" ]] || fail "retired_video_tables_present"
  if [[ "$(sqlite3 "$database_path" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'video_cover_urls';")" == "1" ]]; then
    local legacy_covers
    legacy_covers="$(sqlite3 "$database_path" \
      "SELECT COUNT(*) FROM video_cover_urls WHERE lower(trim(provider)) = 'dbzy' OR lower(trim(source_key)) = 'dbzy';")"
    [[ "$legacy_covers" == "0" ]] || fail "retired_video_covers_present"
  fi
}

restore_tools() {
  local restore_status=0

  if [[ "$tools_installed" != true ]]; then
    return 0
  fi
  if [[ -f "$helper_backup" ]]; then
    install -o root -g root -m 0755 "$helper_backup" "$helper_restore" \
      && mv -Tf "$helper_restore" "$helper_target" \
      || restore_status=1
  else
    rm -f "$helper_target" || restore_status=1
  fi
  if [[ -f "$sudoers_backup" ]]; then
    install -o root -g root -m 0440 "$sudoers_backup" "$sudoers_restore" \
      && visudo -cf "$sudoers_restore" >/dev/null \
      && mv -Tf "$sudoers_restore" "$sudoers_path" \
      || restore_status=1
  else
    rm -f "$sudoers_path" || restore_status=1
  fi
  if [[ -f "$updater_backup" ]]; then
    install -o root -g root -m 0755 "$updater_backup" "$updater_restore" \
      && mv -Tf "$updater_restore" "$updater_target" \
      || restore_status=1
  else
    rm -f "$updater_target" || restore_status=1
  fi
  if [[ -f "$deploy_script_backup" ]]; then
    install -o root -g root -m 0755 "$deploy_script_backup" "$deploy_script_restore" \
      && mv -Tf "$deploy_script_restore" "$deploy_script_target" \
      || restore_status=1
  else
    rm -f "$deploy_script_target" || restore_status=1
  fi
  if [[ -f "$app_release_backup" ]]; then
    install -o root -g root -m 0755 "$app_release_backup" "$app_release_restore" \
      && mv -Tf "$app_release_restore" "$app_release_target" \
      || restore_status=1
  else
    rm -f "$app_release_target" || restore_status=1
  fi
  if [[ -f "$app_release_sudoers_backup" ]]; then
    install -o root -g root -m 0440 "$app_release_sudoers_backup" "$app_release_sudoers_restore" \
      && visudo -cf "$app_release_sudoers_restore" >/dev/null \
      && mv -Tf "$app_release_sudoers_restore" "$app_release_sudoers_path" \
      || restore_status=1
  else
    rm -f "$app_release_sudoers_path" || restore_status=1
  fi
  if [[ -f "$game_helper_backup" ]]; then
    install -o root -g root -m 0755 "$game_helper_backup" "$game_helper_restore" \
      && mv -Tf "$game_helper_restore" "$game_helper_target" \
      || restore_status=1
  else
    rm -f "$game_helper_target" || restore_status=1
  fi
  if [[ -f "$game_sudoers_backup" ]]; then
    install -o root -g root -m 0440 "$game_sudoers_backup" "$game_sudoers_restore" \
      && visudo -cf "$game_sudoers_restore" >/dev/null \
      && mv -Tf "$game_sudoers_restore" "$game_sudoers_path" \
      || restore_status=1
  else
    rm -f "$game_sudoers_path" || restore_status=1
  fi
  return "$restore_status"
}

rollback() {
  set +e
  echo "deploy_status=rolling_back" >&2
  restore_tools || echo "rollback_tools=failed" >&2
  if [[ "$switched" == true && -n "$previous_release" && -d "$previous_release" ]]; then
    if rm -f "${app_link}.rollback" \
      && ln -s "$previous_release" "${app_link}.rollback" \
      && mv -Tf "${app_link}.rollback" "$app_link" \
      && systemctl restart "$service" \
      && wait_for_health; then
      echo "rollback_status=ok" >&2
    else
      echo "rollback_status=failed" >&2
    fi
  elif [[ "$switched" == true ]]; then
    echo "rollback_status=previous_release_missing" >&2
  fi
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if (( status != 0 )) && [[ "$committed" != true ]]; then
    rollback
  fi
  cleanup
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar -xzf "$archive" -C "$work_dir" --no-same-owner
staged_dir="$work_dir/backend"
chown -R "$app_user:$app_user" "$staged_dir"
# The application user owns the staged tree but must also be able to traverse
# the root-owned temporary parent. Keep the parent non-listable and non-writable.
chmod 0711 "$work_dir"

runtime_path="$(dirname "$node_bin"):$(dirname "$npm_bin"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
runtime_env=(env "PATH=$runtime_path")
if ! node_major="$(sudo -u "$app_user" "${runtime_env[@]}" "$node_bin" -p 'process.versions.node.split(".")[0]')"; then
  fail "node_runtime_unusable"
fi
if [[ ! "$node_major" =~ ^[0-9]+$ ]] || (( 10#$node_major < 24 )); then
  fail "node_version_unsupported"
fi
if curl -x "$proxy_url" -fsS --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
  runtime_env+=("HTTP_PROXY=$proxy_url" "HTTPS_PROXY=$proxy_url" "NO_PROXY=127.0.0.1,localhost")
fi
sudo -u "$app_user" "${runtime_env[@]}" "$npm_bin" ci --omit=dev --prefix "$staged_dir"
while IFS= read -r -d '' file; do
  sudo -u "$app_user" "$node_bin" --check "$file" >/dev/null
done < <(find "$staged_dir/src" "$staged_dir/public" "$staged_dir/admin-dist" "$staged_dir/scripts" -type f -name '*.js' -print0)
sudo -u "$app_user" "${runtime_env[@]}" "$npm_bin" run security --prefix "$staged_dir"
python_cache="$work_dir/python-cache"
PYTHONPYCACHEPREFIX="$python_cache" python3 -m py_compile "$staged_dir"/scripts/*.py
PYTHONPYCACHEPREFIX="$python_cache" python3 "$staged_dir/scripts/test_mihomo_subscription_update.py"
PYTHONPYCACHEPREFIX="$python_cache" python3 "$staged_dir/scripts/test_game_service_control.py"
/bin/bash -n \
  "$staged_dir/scripts/deploy-production.sh" \
  "$staged_dir/scripts/deploy-app-release.sh" \
  "$staged_dir/scripts/install-game-service-control.sh" \
  "$staged_dir/scripts/bootstrap-production-deploy.sh" \
  "$staged_dir/scripts/migrate-production-layout.sh" \
  "$staged_dir/scripts/audit-production.sh" \
  "$staged_dir/scripts/inspect-mihomo.sh" \
  "$staged_dir/scripts/prune-apk-backups.sh"

install -d -m 0755 -o root -g root "$release_root" "$shared_root"

[[ -L "$app_link" ]] || fail "release_layout_not_bootstrapped"
previous_release="$(readlink -f "$app_link")"
[[ -d "$previous_release" && -f "$shared_root/.env" && -d "$shared_root/data" ]] || fail "shared_layout_invalid"

if [[ -f "$database_path" ]]; then
  command -v sqlite3 >/dev/null 2>&1 || fail "sqlite_cli_missing"
  install -d -m 0750 -o root -g "$app_user" "$database_backup_root"
  database_backup="$database_backup_root/interaction-$(date -u +%Y%m%dT%H%M%SZ)-${revision}.sqlite"
  sqlite3 "$database_path" ".timeout 10000" ".backup '$database_backup'"
  chown root:"$app_user" "$database_backup"
  chmod 0640 "$database_backup"
fi

if [[ -e "$new_release" ]]; then
  [[ "$(readlink -f "$app_link")" != "$new_release" ]] || fail "revision_already_active"
  rm -rf "$new_release"
fi
mv "$staged_dir" "$new_release"
ln -s "$shared_root/.env" "$new_release/.env"
ln -s "$shared_root/data" "$new_release/data"
chown -R "$app_user:$app_user" "$new_release"
validate_kdjx_production_config

[[ -f "$new_release/scripts/mihomo-admin-control.py" ]] || fail "mihomo_helper_missing"
[[ -f "$new_release/scripts/mihomo-subscription-update.py" ]] || fail "mihomo_updater_missing"
[[ -f "$new_release/scripts/deploy-production.sh" ]] || fail "deploy_script_missing"
[[ -f "$new_release/scripts/deploy-app-release.sh" ]] || fail "app_release_helper_missing"
[[ -f "$new_release/scripts/game-service-control.py" ]] || fail "game_control_helper_missing"
[[ -f "$new_release/scripts/install-game-service-control.sh" ]] \
  || fail "game_control_installer_missing"
[[ -f "$new_release/scripts/sanitize-retired-video-database.js" ]] || fail "database_sanitizer_missing"
[[ -f "$helper_target" ]] && cp -a "$helper_target" "$helper_backup"
[[ -f "$updater_target" ]] && cp -a "$updater_target" "$updater_backup"
[[ -f "$deploy_script_target" ]] && cp -a "$deploy_script_target" "$deploy_script_backup"
[[ -f "$app_release_target" ]] && cp -a "$app_release_target" "$app_release_backup"
[[ -f "$sudoers_path" ]] && cp -a "$sudoers_path" "$sudoers_backup"
[[ -f "$app_release_sudoers_path" ]] && cp -a "$app_release_sudoers_path" "$app_release_sudoers_backup"
if [[ -e "$game_helper_target" || -L "$game_helper_target" ]]; then
  [[ -f "$game_helper_target" && ! -L "$game_helper_target" ]] \
    || fail "game_control_helper_target_invalid"
  cp -a "$game_helper_target" "$game_helper_backup"
fi
if [[ -e "$game_sudoers_path" || -L "$game_sudoers_path" ]]; then
  [[ -f "$game_sudoers_path" && ! -L "$game_sudoers_path" ]] \
    || fail "game_control_sudoers_target_invalid"
  cp -a "$game_sudoers_path" "$game_sudoers_backup"
fi
tools_installed=true
install -d -m 0755 -o root -g root "$(dirname "$updater_target")"
install -o root -g root -m 0755 "$new_release/scripts/mihomo-admin-control.py" "$helper_next"
install -o root -g root -m 0755 "$new_release/scripts/mihomo-subscription-update.py" "$updater_next"
install -o root -g root -m 0755 "$new_release/scripts/deploy-production.sh" "$deploy_script_next"
install -o root -g root -m 0755 "$new_release/scripts/deploy-app-release.sh" "$app_release_next"
printf '%s ALL=(root) NOPASSWD: %s\n' "$app_user" "$helper_target" > "$sudoers_next"
chown root:root "$sudoers_next"
chmod 0440 "$sudoers_next"
visudo -cf "$sudoers_next" >/dev/null
printf '%s ALL=(root) NOPASSWD: %s\n' "$app_user" "$app_release_target" > "$app_release_sudoers_next"
chown root:root "$app_release_sudoers_next"
chmod 0440 "$app_release_sudoers_next"
visudo -cf "$app_release_sudoers_next" >/dev/null
mv -Tf "$helper_next" "$helper_target"
mv -Tf "$updater_next" "$updater_target"
mv -Tf "$deploy_script_next" "$deploy_script_target"
mv -Tf "$sudoers_next" "$sudoers_path"
mv -Tf "$app_release_next" "$app_release_target"
mv -Tf "$app_release_sudoers_next" "$app_release_sudoers_path"
NOVEL_BACKEND_USER="$app_user" \
  NOVEL_GAME_CONTROL_SOURCE="$new_release/scripts/game-service-control.py" \
  NOVEL_GAME_CONTROL_TARGET="$game_helper_target" \
  NOVEL_GAME_CONTROL_SUDOERS="$game_sudoers_path" \
  /bin/bash "$new_release/scripts/install-game-service-control.sh"

rm -f "${app_link}.next"
ln -s "$new_release" "${app_link}.next"
mv -Tf "${app_link}.next" "$app_link"
switched=true
systemctl restart "$service"
wait_for_health || fail "health_check_failed"
# The new release is healthy. Post-deploy retirement failures must not roll
# back to a release that can start the removed collector again.
committed=true
"$node_bin" "$new_release/scripts/retire-video-environment.js" "$shared_root/.env"
rm -f \
  "$shared_root/data/dbzy-cache.json" \
  "$shared_root/data/suibian-catalog.json"
database_targets=("$database_path")
while IFS= read -r -d '' database_backup; do
  database_targets+=("$database_backup")
done < <(find "$database_backup_root" -mindepth 1 -maxdepth 1 -type f -name 'interaction-*.sqlite' -print0 2>/dev/null)
"$node_bin" "$new_release/scripts/sanitize-retired-video-database.js" "${database_targets[@]}"
verify_retired_video_cleanup

current_release="$(readlink -f "$app_link")"
remove_retired_video_releases "$current_release"
find "$release_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -nr \
  | awk 'NR > 6 { sub(/^[^ ]+ /, ""); print }' \
  | while IFS= read -r old_release; do
      [[ -z "$old_release" || "$old_release" == "$current_release" || "$old_release" == "$previous_release" ]] && continue
      rm -rf "$old_release" || true
    done
find "$database_backup_root" -mindepth 1 -maxdepth 1 -type f -name 'interaction-*.sqlite' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr \
  | awk 'NR > 10 { sub(/^[^ ]+ /, ""); print }' \
  | xargs -r rm -f || true

echo "deploy_status=ok"
echo "retired_video_environment=removed"
echo "deploy_revision=$revision"
echo "deploy_previous=$previous_release"
systemctl is-active "$service"
curl -fsS --max-time 10 "$health_url"
