#!/usr/bin/env bash
set -euo pipefail

config_file="/etc/novel-backend-deploy.conf"
if [[ -f "$config_file" ]]; then
  # shellcheck source=/dev/null
  source "$config_file"
fi
app_path="${NOVEL_BACKEND_DIR:-/opt/novel-interaction-backend}"
service="${NOVEL_BACKEND_SERVICE:-novel-interaction.service}"
release_root="${NOVEL_BACKEND_RELEASE_DIR:-/opt/novel-interaction-releases}"
shared_root="${NOVEL_BACKEND_SHARED_DIR:-/opt/novel-interaction-shared}"
marker="/opt/.novel-interaction-layout-migration"
health_url="${NOVEL_BACKEND_HEALTH_URL:-http://127.0.0.1:3010/health}"
legacy_release=""

[[ $EUID -eq 0 ]] || { echo "migration_error=root_required" >&2; exit 1; }

healthy() {
  for _ in $(seq 1 20); do
    curl -fsS --max-time 5 "$health_url" >/dev/null && return 0
    sleep 1
  done
  return 1
}

recover() {
  local recovery_status=0

  if ! systemctl stop "$service"; then
    echo "migration_recovery=service_stop_failed" >&2
    return 1
  fi
  if [[ -L "$app_path" ]]; then
    rm -f "$app_path" || recovery_status=1
  fi
  if [[ -n "${legacy_release:-}" && -d "${legacy_release:-}" ]]; then
    if [[ -L "$legacy_release/.env" ]]; then
      rm -f "$legacy_release/.env" || recovery_status=1
    fi
    if [[ -L "$legacy_release/data" ]]; then
      rm -f "$legacy_release/data" || recovery_status=1
    fi
    if [[ -f "$shared_root/.env" && ! -e "$legacy_release/.env" ]]; then
      mv "$shared_root/.env" "$legacy_release/.env" || recovery_status=1
    fi
    if [[ -d "$shared_root/data" && ! -e "$legacy_release/data" ]]; then
      mv "$shared_root/data" "$legacy_release/data" || recovery_status=1
    fi
    if [[ ! -e "$app_path" ]]; then
      mv "$legacy_release" "$app_path" || recovery_status=1
    fi
  fi
  if (( recovery_status == 0 )); then
    rm -f "$marker" || recovery_status=1
  fi
  if ! systemctl start "$service"; then
    recovery_status=1
  elif ! healthy; then
    recovery_status=1
  fi
  return "$recovery_status"
}

handle_error() {
  local status=$?
  trap - ERR INT TERM
  recover || echo "migration_recovery=failed" >&2
  exit "$status"
}

handle_signal() {
  local status="$1"
  trap - ERR INT TERM
  recover || echo "migration_recovery=failed" >&2
  exit "$status"
}

write_marker() {
  printf 'legacy_release=%q\n' "$legacy_release" > "$marker"
  chmod 0600 "$marker"
}

if [[ -f "$marker" ]]; then
  # The marker is root-owned and only contains shell-escaped state written above.
  # shellcheck source=/dev/null
  source "$marker"
  recover || {
    echo "migration_error=stale_recovery_failed" >&2
    exit 1
  }
fi

if [[ -L "$app_path" ]]; then
  [[ -f "$shared_root/.env" && -d "$shared_root/data" ]] || {
    echo "migration_error=shared_layout_invalid" >&2
    exit 1
  }
  rm -f "$marker"
  echo "migration_status=already_complete"
  exit 0
fi

[[ -d "$app_path" && -f "$app_path/.env" && -d "$app_path/data" ]] || {
  echo "migration_error=live_layout_invalid" >&2
  exit 1
}
[[ ! -e "$shared_root/.env" && ! -e "$shared_root/data" ]] || {
  echo "migration_error=shared_path_already_exists" >&2
  exit 1
}

install -d -m 0755 -o root -g root "$release_root" "$shared_root"
legacy_release="$release_root/legacy-$(date -u +%Y%m%dT%H%M%SZ)"
write_marker
trap handle_error ERR
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

systemctl stop "$service"
mv "$app_path" "$legacy_release"
mv "$legacy_release/.env" "$shared_root/.env"
mv "$legacy_release/data" "$shared_root/data"
ln -s "$shared_root/.env" "$legacy_release/.env"
ln -s "$shared_root/data" "$legacy_release/data"
ln -s "$legacy_release" "$app_path"
systemctl start "$service"
healthy

rm -f "$marker"
trap - ERR INT TERM
echo "migration_status=ok"
echo "migration_release=$legacy_release"
