#!/usr/bin/env bash
set -euo pipefail

app_dir="${NOVEL_BACKEND_DIR:-/opt/novel-interaction-backend}"
service="${NOVEL_BACKEND_SERVICE:-novel-interaction.service}"

section() {
  printf '\n[%s]\n' "$1"
}

section identity
hostname
date -Is
uptime
id

section operating_system
cat /etc/os-release
uname -a

section resources
printf 'cpu_count='; nproc
free -h
df -hT / /opt /var 2>/dev/null || df -hT
df -ih / /opt /var 2>/dev/null || true

section runtime
node --version
npm --version
nginx -v 2>&1 || true

section service
systemctl is-enabled "$service" || true
systemctl is-active "$service" || true
systemctl show "$service" \
  -p FragmentPath -p User -p Group -p WorkingDirectory -p ExecStart \
  -p Restart -p MemoryCurrent -p TasksCurrent --no-pager
curl -fsS --max-time 10 http://127.0.0.1:3010/health || true

section listeners
ss -lntup

section firewall
ufw status verbose 2>/dev/null || true

section project_layout
stat -c '%U:%G %a %n' "$app_dir" "$app_dir/.env" "$app_dir/data" 2>/dev/null || true
du -sh "$app_dir" "$app_dir/data" "$app_dir/node_modules" 2>/dev/null || true

section logs
journalctl --disk-usage
journalctl -u "$service" --since '24 hours ago' -p warning --no-pager -q | sed -n '1,80p'

section nginx
nginx -t 2>&1 || true

section updates
apt list --upgradable 2>/dev/null | sed -n '1,80p'
