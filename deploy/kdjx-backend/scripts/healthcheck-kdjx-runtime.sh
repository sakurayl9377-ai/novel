#!/usr/bin/env bash
set -Eeuo pipefail

runtime_root="${KDJX_RUNTIME_ROOT:-/opt/kdjx/runtime/current}"
loopback_http_base="http://127.0.0.1"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_active() {
    systemctl is-active --quiet "$1" || fail "inactive service: $1"
}

require_tcp() {
    local port="$1"
    timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" >/dev/null 2>&1 \
        || fail "loopback TCP port is unavailable: $port"
}

require_http_status() {
    local expected="$1"
    local method="$2"
    local route="$3"
    local result
    result="$(curl --silent --output /dev/null --write-out '%{http_code}|%{redirect_url}' \
        --request "$method" -H 'Host: 49.232.137.85' "${loopback_http_base}${route}")"
    [[ "$result" == "$expected|" ]] || fail "unexpected HTTP result for $route: $result"
}

[[ -d "$runtime_root" ]] || fail "runtime root is invalid: $runtime_root"
runtime_root="$(realpath -e -- "$runtime_root")"
audit_script="${KDJX_RUNTIME_AUDIT_SCRIPT:-$runtime_root/scripts/audit-runtime-addresses.py}"
[[ -x "$audit_script" ]] || fail "runtime address audit is unavailable: $audit_script"
runtime_env_validator="${KDJX_RUNTIME_ENV_VALIDATOR:-$runtime_root/scripts/validate-runtime-env.py}"
[[ -x "$runtime_env_validator" ]] || fail "runtime environment validation is unavailable: $runtime_env_validator"
command -v luajit >/dev/null 2>&1 || fail "LuaJIT is unavailable"
"$runtime_env_validator" --env-file /etc/kdjx/runtime.env

forward_patch="$runtime_root/online-fight-forward/cn_patch"
cross_forward_patch="$runtime_root/online_fight_forward/cn_patch"
for patch_file in "$forward_patch" "$cross_forward_patch"; do
    [[ -f "$patch_file" && ! -L "$patch_file" ]] \
        || fail "online-fight patch file is missing or unsafe: $patch_file"
    patch_value="$(tr -d '[:space:]' < "$patch_file")"
    [[ "$patch_value" =~ ^[0-9]+$ ]] \
        || fail "online-fight patch file is invalid: $patch_file"
done
cmp --silent "$forward_patch" "$cross_forward_patch" \
    || fail "online-fight patch files do not match"

for service in \
    kdjx-mongodb.service \
    kdjx-nsqlookupd.service \
    kdjx-nsqd.service \
    kdjx-host@accountdb.service \
    kdjx-host@giftdb.service \
    kdjx-host@storage1.service \
    kdjx-host@storage2.service \
    kdjx-host@pvp1.service \
    kdjx-host@pvp2.service \
    kdjx-host@crossdb.service \
    kdjx-host@cross.service \
    kdjx-anti-cheat.service \
    kdjx-online-fight-forward.service \
    kdjx-game@1.service \
    kdjx-login.service; do
    require_active "$service"
done

for port in 27159 4150 4160 4161 18080 16666 28879; do
    require_tcp "$port"
done

curl --fail --silent --show-error --compressed http://127.0.0.1:18080/servers >/dev/null
curl --fail --silent --show-error --compressed -H 'Host: 49.232.137.85' http://127.0.0.1/kdjx/servers >/dev/null
version_payload="$(curl --fail --silent --show-error --compressed \
    -H 'Host: 49.232.137.85' \
    'http://127.0.0.1/kdjx/version?fake=true')"
expected_app_version='2.1.'
expected_app_version+='0.0'
[[ "$version_payload" == *"\"app_version\":\"$expected_app_version\""* ]] \
    || fail "unexpected KDJX app version response"
[[ "$version_payload" == *'"patch_url":"https://novel.kxhub.xyz/games/kdjx/hot/"'* ]] \
    || fail "unexpected KDJX hot-update URL"
curl --fail --silent --show-error --compressed -H 'Host: 49.232.137.85' http://127.0.0.1/kdjx/notice >/dev/null
for route in report word-check feedback; do
    require_http_status 204 POST "/kdjx/$route"
done
for route in /games/kdjx/support /games/kdjx/privacy; do
    require_http_status 200 GET "$route"
done
for route in /games/kdjx/telemetry /games/kdjx/telemetry/client; do
    require_http_status 204 POST "$route"
done
for route in \
    /kdjx/internal/sakura/payments/verify \
    /novel-api/games/kdjx/sessions/verify \
    /novel-api/games/kdjx/sessions/verify/; do
    require_http_status 404 GET "$route"
done

"$audit_script" --runtime-root "$runtime_root"
printf 'KDJX runtime health check passed.\n'
