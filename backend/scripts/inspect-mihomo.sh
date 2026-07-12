#!/usr/bin/env bash
set -euo pipefail

redact() {
  sed -E \
    -e 's#https?://[^[:space:]]+#https://[redacted]#g' \
    -e 's/(SECRET|TOKEN|PASSWORD|URL)=.*/\1=[redacted]/Ig'
}

echo '[mihomo-service]'
systemctl show mihomo.service \
  -p FragmentPath -p User -p Group -p ExecStart -p EnvironmentFiles \
  -p ActiveState -p SubState --no-pager
systemctl cat mihomo.service | redact

echo '[subscription-service]'
systemctl show mihomo-subscription-update.service \
  -p FragmentPath -p User -p Group -p ExecStart -p EnvironmentFiles \
  -p ActiveState -p Result --no-pager
systemctl cat mihomo-subscription-update.service | redact

echo '[subscription-updater]'
if [[ -f /usr/local/libexec/mihomo-update-subscription ]]; then
  sed -E \
    -e 's#https?://[^[:space:]]+#https://[redacted]#g' \
    -e 's/(URL|TOKEN|SECRET|PASSWORD)=.*/\1=[redacted]/Ig' \
    /usr/local/libexec/mihomo-update-subscription
fi
echo '[subscription-env-keys]'
if [[ -f /etc/mihomo/subscription.env ]]; then
  sed -n -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=[configured]/p' \
    /etc/mihomo/subscription.env
fi

echo '[subscription-timer]'
systemctl status mihomo-subscription-update.timer --no-pager -l | sed -n '1,80p'

echo '[mihomo-files]'
find /etc /opt /usr/local -maxdepth 4 -type f \
  \( -path '*mihomo*' -o -path '*clash*' \) \
  -printf '%U:%G %m %s %p\n' 2>/dev/null | sed -n '1,160p'

echo '[config-summary]'
config=''
for candidate in \
  /etc/mihomo/config.yaml \
  /etc/mihomo/config.yml \
  /root/.config/mihomo/config.yaml \
  /home/ubuntu/.config/mihomo/config.yaml; do
  if [[ -f "$candidate" ]]; then
    config="$candidate"
    break
  fi
done
echo "config_path=${config:-unknown}"
if [[ -n "$config" ]]; then
  awk '
    /^[A-Za-z][A-Za-z0-9_-]*:/ {
      key=$1; sub(/:$/, "", key);
      if (key ~ /^(secret|password|token)$/) print key ": [configured]";
      else if (key ~ /^(mixed-port|port|socks-port|redir-port|tproxy-port|allow-lan|bind-address|mode|log-level|ipv6|external-controller)$/) print;
      else print key ":";
    }
  ' "$config" | sed -n '1,160p'
fi

echo '[controller-summary]'
controller_secret=''
if [[ -f /etc/mihomo/controller.secret ]]; then
  controller_secret="$(cat /etc/mihomo/controller.secret)"
fi
CONTROLLER_SECRET="$controller_secret" python3 - <<'PY'
import json
import os
import urllib.request

secret = os.environ.get('CONTROLLER_SECRET', '')
for path in ('/version', '/configs', '/proxies', '/providers/proxies'):
    try:
        request = urllib.request.Request('http://127.0.0.1:9090' + path)
        if secret:
            request.add_header('Authorization', 'Bearer ' + secret)
        with urllib.request.urlopen(request, timeout=3) as response:
            data = json.load(response)
        if path == '/version':
            print('version=' + str(data.get('version', 'unknown')))
        elif path == '/configs':
            for key in ('port', 'socks-port', 'mixed-port', 'mode', 'log-level', 'ipv6'):
                if key in data:
                    print(f'{key}={data[key]}')
        elif path == '/proxies':
            proxies = data.get('proxies', {})
            group_types = {'Selector', 'URLTest', 'Fallback', 'LoadBalance'}
            groups = [
                {
                    'name': name,
                    'type': item.get('type'),
                    'now': item.get('now'),
                    'options': len(item.get('all', [])),
                }
                for name, item in proxies.items()
                if item.get('type') in group_types
            ]
            print(f'proxies={len(proxies)} groups={len(groups)}')
            print('group_summary=' + json.dumps(groups, ensure_ascii=False))
        else:
            print(f"providers={len(data.get('providers', {}))}")
    except Exception as error:
        print(path, 'unavailable', type(error).__name__)
PY

echo '[proxy-users]'
grep -RIlE '127\.0\.0\.1:20808|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY' \
  /etc/systemd /etc/environment /etc/profile.d /opt 2>/dev/null \
  | sed -n '1,160p'

echo '[outbound-check]'
for url in \
  https://www.google.com/generate_204 \
  https://api.github.com \
  https://api.ipify.org; do
  code="$(curl -x http://127.0.0.1:20808 -sS -o /dev/null \
    -w '%{http_code}' --max-time 10 "$url" || true)"
  echo "$url $code"
done
