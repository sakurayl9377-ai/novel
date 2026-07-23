#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper_source="${NOVEL_GAME_CONTROL_SOURCE:-$script_dir/game-service-control.py}"
helper_target="${NOVEL_GAME_CONTROL_TARGET:-/usr/local/sbin/novel-game-service-control}"
app_user="${NOVEL_BACKEND_USER:-ubuntu}"
sudoers_target="${NOVEL_GAME_CONTROL_SUDOERS:-/etc/sudoers.d/${app_user}-novel-game-service-control}"
helper_tmp=""
sudoers_tmp=""
python_cache=""
backup_dir=""
helper_backup=""
sudoers_backup=""
helper_restore=""
sudoers_restore=""
install_started=false
committed=false

cleanup_paths() {
  rm -f \
    "${helper_tmp:-}" \
    "${sudoers_tmp:-}" \
    "${helper_restore:-}" \
    "${sudoers_restore:-}"
  if [[ -n "${python_cache:-}" ]]; then
    rm -rf -- "$python_cache"
  fi
  if [[ -n "${backup_dir:-}" ]]; then
    rm -rf -- "$backup_dir"
  fi
}

restore_installation() {
  local restore_status=0
  if [[ -e "$helper_backup" || -L "$helper_backup" ]]; then
    cp -a -- "$helper_backup" "$helper_restore" \
      && mv -Tf -- "$helper_restore" "$helper_target" \
      || restore_status=1
  else
    rm -f -- "$helper_target" || restore_status=1
  fi
  if [[ -e "$sudoers_backup" || -L "$sudoers_backup" ]]; then
    cp -a -- "$sudoers_backup" "$sudoers_restore" \
      && mv -Tf -- "$sudoers_restore" "$sudoers_target" \
      || restore_status=1
  else
    rm -f -- "$sudoers_target" || restore_status=1
  fi
  return "$restore_status"
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if (( status != 0 )) \
    && [[ "$install_started" == true ]] \
    && [[ "$committed" != true ]]; then
    if restore_installation; then
      echo "game_control_install_rollback=ok" >&2
    else
      echo "game_control_install_rollback=failed" >&2
    fi
  fi
  cleanup_paths
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "game_control_install_error=$1" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "root_required"
[[ -f "$helper_source" ]] || fail "helper_source_missing"
[[ "$helper_target" == "/usr/local/sbin/novel-game-service-control" ]] \
  || fail "helper_target_invalid"
[[ "$app_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "app_user_invalid"
[[ "$sudoers_target" == "/etc/sudoers.d/${app_user}-novel-game-service-control" ]] \
  || fail "sudoers_target_invalid"
id "$app_user" >/dev/null 2>&1 || fail "app_user_missing"
[[ -x /usr/bin/systemctl ]] || fail "systemctl_missing"
command -v python3 >/dev/null 2>&1 || fail "python3_missing"
command -v visudo >/dev/null 2>&1 || fail "visudo_missing"
command -v sudo >/dev/null 2>&1 || fail "sudo_missing"

python_cache="$(mktemp -d /tmp/novel-game-control-pycache.XXXXXX)"
PYTHONPYCACHEPREFIX="$python_cache" python3 -m py_compile "$helper_source"

helper_tmp="$(mktemp /usr/local/sbin/.novel-game-service-control.XXXXXX)"
install -o root -g root -m 0755 "$helper_source" "$helper_tmp"

sudoers_tmp="$(mktemp /etc/sudoers.d/.novel-game-service-control.XXXXXX)"
printf '%s ALL=(root) NOPASSWD: %s\n' "$app_user" "$helper_target" > "$sudoers_tmp"
chown root:root "$sudoers_tmp"
chmod 0440 "$sudoers_tmp"
visudo -cf "$sudoers_tmp" >/dev/null

backup_dir="$(mktemp -d /tmp/novel-game-control-install.XXXXXX)"
helper_backup="$backup_dir/helper.previous"
sudoers_backup="$backup_dir/sudoers.previous"
helper_restore="$(dirname "$helper_target")/.novel-game-service-control.restore.$$"
sudoers_restore="${sudoers_target}.restore.$$"
[[ -e "$helper_target" || -L "$helper_target" ]] \
  && cp -a -- "$helper_target" "$helper_backup"
[[ -e "$sudoers_target" || -L "$sudoers_target" ]] \
  && cp -a -- "$sudoers_target" "$sudoers_backup"

install_started=true
mv -Tf "$helper_tmp" "$helper_target"
helper_tmp=""
mv -Tf "$sudoers_tmp" "$sudoers_target"
sudoers_tmp=""

sudo -u "$app_user" sudo -n "$helper_target" modao status >/dev/null \
  || fail "installed_helper_check_failed"
sudo -u "$app_user" sudo -n "$helper_target" bailian status >/dev/null \
  || fail "installed_helper_check_failed"
committed=true

echo "game_control_install_status=ok"
echo "game_control_helper=$helper_target"
echo "game_control_sudoers=$sudoers_target"
