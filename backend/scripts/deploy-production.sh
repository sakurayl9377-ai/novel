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
for required in backend/package.json backend/package-lock.json backend/src/server.js; do
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
helper_backup="$work_dir/novel-mihomo-control.previous"
updater_backup="$work_dir/mihomo-update-subscription.previous"
deploy_script_backup="$work_dir/novel-backend-deploy.previous"
sudoers_path="/etc/sudoers.d/${app_user}-novel-mihomo-control"
sudoers_backup="$work_dir/mihomo-sudoers.previous"
sudoers_next="${sudoers_path}.next.$$"
helper_next="$(dirname "$helper_target")/.novel-mihomo-control.next.$$"
updater_next="$(dirname "$updater_target")/.mihomo-update-subscription.next.$$"
deploy_script_next="$(dirname "$deploy_script_target")/.novel-backend-deploy.next.$$"
sudoers_restore="${sudoers_path}.restore.$$"
helper_restore="$(dirname "$helper_target")/.novel-mihomo-control.restore.$$"
updater_restore="$(dirname "$updater_target")/.mihomo-update-subscription.restore.$$"
deploy_script_restore="$(dirname "$deploy_script_target")/.novel-backend-deploy.restore.$$"
switched=false
tools_installed=false

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
    "$sudoers_restore" \
    "$helper_restore" \
    "$updater_restore" \
    "$deploy_script_restore"
}

restore_tools() {
  local restore_status=0

  if [[ "$tools_installed" != true ]]; then
    return
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
  (( status == 0 )) || rollback
  cleanup
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar -xzf "$archive" -C "$work_dir" --no-same-owner
staged_dir="$work_dir/backend"
chown -R "$app_user:$app_user" "$staged_dir"

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
done < <(find "$staged_dir/src" "$staged_dir/public" -type f -name '*.js' -print0)
sudo -u "$app_user" "${runtime_env[@]}" "$npm_bin" run security --prefix "$staged_dir"
python_cache="$work_dir/python-cache"
PYTHONPYCACHEPREFIX="$python_cache" python3 -m py_compile "$staged_dir"/scripts/*.py
PYTHONPYCACHEPREFIX="$python_cache" python3 "$staged_dir/scripts/test_mihomo_subscription_update.py"
/bin/bash -n \
  "$staged_dir/scripts/deploy-production.sh" \
  "$staged_dir/scripts/bootstrap-production-deploy.sh" \
  "$staged_dir/scripts/migrate-production-layout.sh" \
  "$staged_dir/scripts/audit-production.sh" \
  "$staged_dir/scripts/inspect-mihomo.sh"

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

[[ -f "$new_release/scripts/mihomo-admin-control.py" ]] || fail "mihomo_helper_missing"
[[ -f "$new_release/scripts/mihomo-subscription-update.py" ]] || fail "mihomo_updater_missing"
[[ -f "$new_release/scripts/deploy-production.sh" ]] || fail "deploy_script_missing"
[[ -f "$helper_target" ]] && cp -a "$helper_target" "$helper_backup"
[[ -f "$updater_target" ]] && cp -a "$updater_target" "$updater_backup"
[[ -f "$deploy_script_target" ]] && cp -a "$deploy_script_target" "$deploy_script_backup"
[[ -f "$sudoers_path" ]] && cp -a "$sudoers_path" "$sudoers_backup"
tools_installed=true
install -d -m 0755 -o root -g root "$(dirname "$updater_target")"
install -o root -g root -m 0755 "$new_release/scripts/mihomo-admin-control.py" "$helper_next"
install -o root -g root -m 0755 "$new_release/scripts/mihomo-subscription-update.py" "$updater_next"
install -o root -g root -m 0755 "$new_release/scripts/deploy-production.sh" "$deploy_script_next"
printf '%s ALL=(root) NOPASSWD: %s\n' "$app_user" "$helper_target" > "$sudoers_next"
chown root:root "$sudoers_next"
chmod 0440 "$sudoers_next"
visudo -cf "$sudoers_next" >/dev/null
mv -Tf "$helper_next" "$helper_target"
mv -Tf "$updater_next" "$updater_target"
mv -Tf "$deploy_script_next" "$deploy_script_target"
mv -Tf "$sudoers_next" "$sudoers_path"

rm -f "${app_link}.next"
ln -s "$new_release" "${app_link}.next"
mv -Tf "${app_link}.next" "$app_link"
switched=true
systemctl restart "$service"
wait_for_health || fail "health_check_failed"

current_release="$(readlink -f "$app_link")"
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
echo "deploy_revision=$revision"
echo "deploy_previous=$previous_release"
systemctl is-active "$service"
curl -fsS --max-time 10 "$health_url"
