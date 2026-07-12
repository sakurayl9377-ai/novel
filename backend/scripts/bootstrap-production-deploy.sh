#!/usr/bin/env bash
set -euo pipefail

public_key="${1:-}"
deploy_user="${NOVEL_DEPLOY_USER:-novel-deploy}"
script_source="${NOVEL_DEPLOY_SCRIPT_SOURCE:-./scripts/deploy-production.sh}"
helper_source="${NOVEL_MIHOMO_HELPER_SOURCE:-./scripts/mihomo-admin-control.py}"
updater_source="${NOVEL_MIHOMO_UPDATER_SOURCE:-./scripts/mihomo-subscription-update.py}"
migration_source="${NOVEL_LAYOUT_MIGRATION_SOURCE:-./scripts/migrate-production-layout.sh}"
app_user="${NOVEL_BACKEND_USER:-ubuntu}"
deploy_proxy="${NOVEL_DEPLOY_PROXY:-http://127.0.0.1:20808}"
system_path="${NOVEL_RUNTIME_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
config_tmp=""
migration_copy=""
sudoers_tmp=""
ssh_config_tmp=""
ssh_config_backup=""

cleanup() {
  rm -f \
    "${config_tmp:-}" \
    "${migration_copy:-}" \
    "${sudoers_tmp:-}" \
    "${ssh_config_tmp:-}" \
    "${ssh_config_backup:-}"
}

install_sqlite_cli() {
  command -v sqlite3 >/dev/null 2>&1 && return
  command -v apt-get >/dev/null 2>&1 || {
    echo "bootstrap_error=sqlite_cli_missing" >&2
    exit 1
  }

  apt_env=(env DEBIAN_FRONTEND=noninteractive)
  if "${apt_env[@]}" apt-get update \
    && "${apt_env[@]}" apt-get install -y --no-install-recommends sqlite3; then
    :
  elif command -v curl >/dev/null 2>&1 \
    && curl -x "$deploy_proxy" -fsS --max-time 5 https://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
    proxy_apt_env=(
      env
      DEBIAN_FRONTEND=noninteractive
      "http_proxy=$deploy_proxy"
      "https_proxy=$deploy_proxy"
      "no_proxy=127.0.0.1,localhost"
    )
    if ! "${proxy_apt_env[@]}" apt-get update \
      || ! "${proxy_apt_env[@]}" apt-get install -y --no-install-recommends sqlite3; then
      echo "bootstrap_error=sqlite_install_failed" >&2
      exit 1
    fi
  else
    echo "bootstrap_error=sqlite_install_failed" >&2
    exit 1
  fi
  command -v sqlite3 >/dev/null 2>&1 || {
    echo "bootstrap_error=sqlite_install_failed" >&2
    exit 1
  }
}

install_sudoers_rule() {
  local target="$1"
  local rule_user="$2"
  local command_path="$3"

  sudoers_tmp="$(mktemp "/etc/sudoers.d/.${rule_user}.XXXXXX")"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$rule_user" "$command_path" > "$sudoers_tmp"
  chown root:root "$sudoers_tmp"
  chmod 0440 "$sudoers_tmp"
  visudo -cf "$sudoers_tmp" >/dev/null
  mv -f "$sudoers_tmp" "$target"
  sudoers_tmp=""
}

reload_sshd() {
  systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
}

restore_ssh_config() {
  local target="$1"

  if [[ -n "$ssh_config_backup" && -f "$ssh_config_backup" ]]; then
    mv -Tf "$ssh_config_backup" "$target"
    ssh_config_backup=""
  else
    rm -f "$target"
  fi
}

install_deploy_ssh_policy() {
  local target="/etc/ssh/sshd_config.d/60-novel-deploy.conf"
  local effective_config=""

  command -v sshd >/dev/null 2>&1 || {
    echo "bootstrap_error=sshd_missing" >&2
    exit 1
  }
  sshd -t || {
    echo "bootstrap_error=ssh_config_invalid_existing" >&2
    exit 1
  }
  install -d -m 0755 -o root -g root /etc/ssh/sshd_config.d
  if [[ -f "$target" ]]; then
    ssh_config_backup="$(mktemp /etc/ssh/sshd_config.d/.60-novel-deploy.backup.XXXXXX)"
    cp -a "$target" "$ssh_config_backup"
  fi
  ssh_config_tmp="$(mktemp /etc/ssh/sshd_config.d/.60-novel-deploy.candidate.XXXXXX)"
  {
    printf 'Match User %s\n' "$deploy_user"
    printf '    AuthenticationMethods publickey\n'
    printf '    PubkeyAuthentication yes\n'
    printf '    PasswordAuthentication no\n'
    printf '    KbdInteractiveAuthentication no\n'
    printf 'Match all\n'
  } > "$ssh_config_tmp"
  chown root:root "$ssh_config_tmp"
  chmod 0644 "$ssh_config_tmp"
  sshd -t -f "$ssh_config_tmp" || {
    echo "bootstrap_error=deploy_ssh_policy_invalid" >&2
    exit 1
  }
  mv -Tf "$ssh_config_tmp" "$target"
  ssh_config_tmp=""

  if ! sshd -t; then
    restore_ssh_config "$target"
    sshd -t || true
    echo "bootstrap_error=ssh_config_invalid" >&2
    exit 1
  fi
  if ! effective_config="$(sshd -T -C "user=$deploy_user,host=localhost,addr=127.0.0.1")"; then
    restore_ssh_config "$target"
    echo "bootstrap_error=deploy_ssh_policy_check_failed" >&2
    exit 1
  fi
  if ! grep -Fxq 'authenticationmethods publickey' <<<"$effective_config" \
    || ! grep -Fxq 'pubkeyauthentication yes' <<<"$effective_config" \
    || ! grep -Fxq 'passwordauthentication no' <<<"$effective_config" \
    || ! grep -Fxq 'kbdinteractiveauthentication no' <<<"$effective_config"; then
    restore_ssh_config "$target"
    echo "bootstrap_error=deploy_ssh_policy_not_effective" >&2
    exit 1
  fi
  if ! reload_sshd; then
    restore_ssh_config "$target"
    reload_sshd || true
    echo "bootstrap_error=sshd_reload_failed" >&2
    exit 1
  fi
  rm -f "${ssh_config_backup:-}"
  ssh_config_backup=""
}

trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "bootstrap_error=root_required" >&2; exit 1; }
[[ "$deploy_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "bootstrap_error=deploy_user_invalid" >&2; exit 1; }
if [[ "$public_key" == *$'\n'* || "$public_key" == *$'\r'* ]] \
  || [[ ! "$public_key" =~ ^ssh-(ed25519|rsa)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
  echo "bootstrap_error=public_key_invalid" >&2
  exit 1
fi
[[ -f "$script_source" ]] || { echo "bootstrap_error=deploy_script_missing" >&2; exit 1; }
[[ -f "$helper_source" ]] || { echo "bootstrap_error=mihomo_helper_missing" >&2; exit 1; }
[[ -f "$updater_source" ]] || { echo "bootstrap_error=mihomo_updater_missing" >&2; exit 1; }
[[ -f "$migration_source" ]] || { echo "bootstrap_error=migration_script_missing" >&2; exit 1; }
id "$app_user" >/dev/null 2>&1 || { echo "bootstrap_error=app_user_missing" >&2; exit 1; }

node_bin="${NOVEL_NODE_BIN:-}"
npm_bin="${NOVEL_NPM_BIN:-}"
[[ -n "$node_bin" ]] || node_bin="$(sudo -u "$app_user" env "PATH=$system_path" sh -c 'command -v node' || true)"
[[ -n "$npm_bin" ]] || npm_bin="$(sudo -u "$app_user" env "PATH=$system_path" sh -c 'command -v npm' || true)"
[[ -n "$node_bin" && -n "$npm_bin" ]] || { echo "bootstrap_error=node_runtime_missing" >&2; exit 1; }
[[ "$node_bin" == /* && "$npm_bin" == /* ]] || { echo "bootstrap_error=node_runtime_path_invalid" >&2; exit 1; }
runtime_path="$(dirname "$node_bin"):$(dirname "$npm_bin"):$system_path"
if ! node_major="$(sudo -u "$app_user" env "PATH=$runtime_path" "$node_bin" -p 'process.versions.node.split(".")[0]')"; then
  echo "bootstrap_error=node_runtime_unusable" >&2
  exit 1
fi
if [[ ! "$node_major" =~ ^[0-9]+$ ]] || (( 10#$node_major < 24 )); then
  echo "bootstrap_error=node_version_unsupported" >&2
  exit 1
fi
sudo -u "$app_user" env "PATH=$runtime_path" "$npm_bin" --version >/dev/null || {
  echo "bootstrap_error=npm_runtime_unusable" >&2
  exit 1
}
install_sqlite_cli

config_tmp="$(mktemp /etc/.novel-backend-deploy.conf.XXXXXX)"
{
  printf 'NOVEL_BACKEND_DIR=%q\n' /opt/novel-interaction-backend
  printf 'NOVEL_BACKEND_SERVICE=%q\n' novel-interaction.service
  printf 'NOVEL_BACKEND_USER=%q\n' "$app_user"
  printf 'NOVEL_BACKEND_RELEASE_DIR=%q\n' /opt/novel-interaction-releases
  printf 'NOVEL_BACKEND_SHARED_DIR=%q\n' /opt/novel-interaction-shared
  printf 'NOVEL_DATABASE_BACKUP_DIR=%q\n' /opt/novel-interaction-db-backups
  printf 'NOVEL_NODE_BIN=%q\n' "$node_bin"
  printf 'NOVEL_NPM_BIN=%q\n' "$npm_bin"
  printf 'NOVEL_DEPLOY_PROXY=%q\n' "$deploy_proxy"
  printf 'NOVEL_BACKEND_HEALTH_URL=%q\n' http://127.0.0.1:3010/health
  printf 'NOVEL_DATABASE_PATH=%q\n' /opt/novel-interaction-shared/data/interaction.sqlite
} > "$config_tmp"
chown root:root "$config_tmp"
chmod 0644 "$config_tmp"
mv -f "$config_tmp" /etc/novel-backend-deploy.conf
config_tmp=""

migration_copy="$(mktemp /tmp/novel-layout-migration.XXXXXX)"
cp "$migration_source" "$migration_copy"
chmod 0700 "$migration_copy"
bash "$migration_copy"
rm -f "$migration_copy"
migration_copy=""

if ! id "$deploy_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$deploy_user"
fi
usermod --lock "$deploy_user"
home_dir="$(getent passwd "$deploy_user" | cut -d: -f6)"
install -d -m 700 -o "$deploy_user" -g "$deploy_user" "$home_dir/.ssh"
printf 'restrict %s\n' "$public_key" > "$home_dir/.ssh/authorized_keys"
chown "$deploy_user:$deploy_user" "$home_dir/.ssh/authorized_keys"
chmod 600 "$home_dir/.ssh/authorized_keys"

install -o root -g root -m 0755 "$script_source" /usr/local/sbin/novel-backend-deploy
install -o root -g root -m 0755 "$helper_source" /usr/local/sbin/novel-mihomo-control
install -d -m 0755 -o root -g root /usr/local/libexec
install -o root -g root -m 0755 "$updater_source" /usr/local/libexec/mihomo-update-subscription
install_sudoers_rule \
  "/etc/sudoers.d/${deploy_user}-novel-backend" \
  "$deploy_user" \
  /usr/local/sbin/novel-backend-deploy
install_sudoers_rule \
  "/etc/sudoers.d/${app_user}-novel-mihomo-control" \
  "$app_user" \
  /usr/local/sbin/novel-mihomo-control
install_deploy_ssh_policy

echo "bootstrap_status=ok"
echo "bootstrap_user=$deploy_user"
trap - EXIT
