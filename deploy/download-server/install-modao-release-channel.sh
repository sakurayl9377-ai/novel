#!/usr/bin/env bash
set -euo pipefail

expected_server="47.88.26.14"
acknowledged_server="${1:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper_source="${MODAO_RELEASE_HELPER_SOURCE:-$script_dir/deploy-modao-game-release.sh}"
nginx_source="${NOVEL_DOWNLOAD_NGINX_SOURCE:-$script_dir/nginx-https.conf}"
helper_target="${MODAO_RELEASE_HELPER_TARGET:-/usr/local/sbin/novel-modao-game-release-deploy}"
if [[ -n "${NOVEL_DOWNLOAD_NGINX_TARGET:-}" ]]; then
  nginx_target="$NOVEL_DOWNLOAD_NGINX_TARGET"
elif [[ -d /etc/nginx/conf.d ]]; then
  nginx_target="/etc/nginx/conf.d/novel-download.conf"
elif [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
  nginx_target="/etc/nginx/sites-available/novel-download.conf"
else
  nginx_target="/etc/nginx/conf.d/novel-download.conf"
fi
if [[ -n "${NOVEL_DOWNLOAD_NGINX_ENABLED:-}" ]]; then
  nginx_enabled="$NOVEL_DOWNLOAD_NGINX_ENABLED"
elif [[ "$(basename -- "$(dirname -- "$nginx_target")")" == "conf.d" ]]; then
  nginx_enabled=""
else
  nginx_enabled="/etc/nginx/sites-enabled/novel-download.conf"
fi
release_dir="${MODAO_GAME_RELEASE_DIR:-/var/www/novel-download/games/modao}"
nginx_command="${NOVEL_DOWNLOAD_NGINX_BIN:-nginx}"
apksigner_command="${MODAO_APKSIGNER_BIN:-apksigner}"
skip_reload="${NOVEL_DOWNLOAD_SKIP_RELOAD:-0}"
work_dir=""
nginx_backup=""
helper_backup=""
nginx_switched=false
helper_switched=false
enabled_created=false
committed=false

fail() {
  printf 'download_install_error=%s\n' "$1" >&2
  exit 1
}

resolve_command() {
  local candidate="$1"
  if [[ "$candidate" == */* ]]; then
    [[ -x "$candidate" ]] || return 1
    realpath -e -- "$candidate"
  else
    command -v "$candidate"
  fi
}

restore_file() {
  local backup="$1"
  local target="$2"
  local mode="$3"
  local restore="${target}.restore.$$"
  if [[ -f "$backup" ]]; then
    install -o root -g root -m "$mode" -- "$backup" "$restore"
    mv -Tf -- "$restore" "$target"
  else
    rm -f -- "$target"
  fi
}

rollback() {
  set +e
  if [[ "$helper_switched" == true ]]; then
    restore_file "$helper_backup" "$helper_target" 0755
  fi
  if [[ "$nginx_switched" == true ]]; then
    restore_file "$nginx_backup" "$nginx_target" 0644
  fi
  if [[ -n "$nginx_enabled" && "$enabled_created" == true ]]; then
    rm -f -- "$nginx_enabled"
  fi
  if [[ "$skip_reload" != "1" ]] && [[ "$nginx_switched" == true ]]; then
    systemctl reload nginx.service >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$work_dir" && "$work_dir" == /tmp/novel-download-install.* && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  if (( status != 0 )) && [[ "$committed" != true ]]; then
    rollback
  fi
  cleanup
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || fail "root_required"
[[ "$acknowledged_server" == "$expected_server" ]] || fail "server_acknowledgement_required"
for target in "$helper_target" "$nginx_target" "$release_dir"; do
  [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] \
    || fail "target_path_invalid"
done
if [[ -n "$nginx_enabled" ]]; then
  [[ "$nginx_enabled" == /* && "$nginx_enabled" != *$'\n'* && "$nginx_enabled" != *$'\r'* ]] \
    || fail "target_path_invalid"
fi
[[ -f "$helper_source" && ! -L "$helper_source" ]] || fail "helper_source_invalid"
[[ -f "$nginx_source" && ! -L "$nginx_source" ]] || fail "nginx_source_invalid"
bash -n "$helper_source" || fail "helper_syntax_invalid"
grep -Fq 'part_count=5' "$helper_source" \
  || fail "helper_modao_parts_missing"
grep -Fq 'location = /games/modao/manifest.json {' "$nginx_source" \
  || fail "nginx_modao_manifest_route_missing"
grep -Fq '.part-00[0-4]\.apk$' "$nginx_source" \
  || fail "nginx_modao_part_route_missing"
grep -Fq 'public, max-age=31536000, immutable, no-transform' "$nginx_source" \
  || fail "nginx_modao_part_cache_missing"
grep -Fq 'Cloudflare-CDN-Cache-Control' "$nginx_source" \
  || fail "nginx_modao_part_cdn_cache_missing"
grep -Fq 'location = /app3/version.json {' "$nginx_source" \
  || fail "nginx_app3_manifest_route_missing"
grep -Fq 'location = /app3/app-release.apk {' "$nginx_source" \
  || fail "nginx_app3_apk_route_missing"
nginx_bin="$(resolve_command "$nginx_command")" || fail "nginx_missing"
apksigner_bin="$(resolve_command "$apksigner_command")" || fail "apksigner_missing"
"$apksigner_bin" --version >/dev/null 2>&1 || fail "apksigner_unusable"
"$nginx_bin" -t >/dev/null 2>&1 || fail "existing_nginx_config_invalid"

helper_parent="$(dirname -- "$helper_target")"
nginx_parent="$(dirname -- "$nginx_target")"
target_parents=("$helper_parent" "$nginx_parent")
if [[ -n "$nginx_enabled" ]]; then
  target_parents+=("$(dirname -- "$nginx_enabled")")
fi
for parent in "${target_parents[@]}"; do
  [[ -d "$parent" && ! -L "$parent" ]] || fail "target_directory_invalid"
done
[[ ! -L "$helper_target" && ! -L "$nginx_target" ]] || fail "target_symlink_invalid"
if [[ -n "$nginx_enabled" && -e "$nginx_enabled" ]]; then
  [[ -L "$nginx_enabled" ]] || fail "nginx_enabled_path_conflict"
  [[ "$(readlink -f -- "$nginx_enabled")" == "$(realpath -m -- "$nginx_target")" ]] \
    || fail "nginx_enabled_link_conflict"
fi

work_dir="$(mktemp -d /tmp/novel-download-install.XXXXXX)"
nginx_backup="$work_dir/nginx.previous"
helper_backup="$work_dir/helper.previous"
[[ ! -f "$nginx_target" ]] || cp -a -- "$nginx_target" "$nginx_backup"
[[ ! -f "$helper_target" ]] || cp -a -- "$helper_target" "$helper_backup"

nginx_next="${nginx_target}.next.$$"
install -o root -g root -m 0644 -- "$nginx_source" "$nginx_next"
mv -Tf -- "$nginx_next" "$nginx_target"
nginx_switched=true
if [[ -n "$nginx_enabled" && ! -e "$nginx_enabled" ]]; then
  enabled_next="${nginx_enabled}.next.$$"
  ln -s "$nginx_target" "$enabled_next"
  mv -Tf -- "$enabled_next" "$nginx_enabled"
  enabled_created=true
fi
"$nginx_bin" -t >/dev/null 2>&1 || fail "candidate_nginx_config_invalid"

helper_next="${helper_target}.next.$$"
install -o root -g root -m 0755 -- "$helper_source" "$helper_next"
mv -Tf -- "$helper_next" "$helper_target"
helper_switched=true
install -d -m 0755 -o root -g root -- "$release_dir"

if [[ "$skip_reload" != "1" ]]; then
  systemctl reload nginx.service || fail "nginx_reload_failed"
fi
committed=true
printf 'download_install_status=ok\n'
printf 'download_install_server=%s\n' "$expected_server"
printf 'download_install_helper=%s\n' "$helper_target"
printf 'download_install_nginx=%s\n' "$nginx_target"
printf 'download_install_release_dir=%s\n' "$release_dir"
