#!/usr/bin/env bash
set -Eeuo pipefail

runtime_root="${KDJX_RUNTIME_ROOT:-/opt/kdjx/runtime/current}"
loopback_http_base="http://127.0.0.1"
curl_options=(--connect-timeout 2 --max-time 5)

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

require_udp_listener() {
    local port="$1"
    local listeners
    command -v ss >/dev/null 2>&1 || fail "ss is unavailable"
    listeners="$(ss --udp --listening --numeric --no-header "sport = :$port" 2>/dev/null)" \
        || fail "failed to inspect UDP listeners for port: $port"
    [[ -n "$listeners" ]] || fail "UDP port is unavailable: $port"
}

require_http_status() {
    local expected="$1"
    local method="$2"
    local route="$3"
    local result
    result="$(curl "${curl_options[@]}" --silent --output /dev/null --write-out '%{http_code}|%{redirect_url}' \
        --request "$method" -H 'Host: 49.232.137.85' "${loopback_http_base}${route}")"
    [[ "$result" == "$expected|" ]] || fail "unexpected HTTP result for $route: $result"
}

require_loopback_json_status() {
    local expected="$1"
    local route="$2"
    local result
    result="$(curl "${curl_options[@]}" --silent --output /dev/null --write-out '%{http_code}' \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "http://127.0.0.1:18080${route}")"
    [[ "$result" == "$expected" ]] || fail "unexpected loopback HTTP result for $route: $result"
}

[[ -d "$runtime_root" ]] || fail "runtime root is invalid: $runtime_root"
runtime_root="$(realpath -e -- "$runtime_root")"
audit_script="${KDJX_RUNTIME_AUDIT_SCRIPT:-$runtime_root/scripts/audit-runtime-addresses.py}"
[[ -x "$audit_script" ]] || fail "runtime address audit is unavailable: $audit_script"
runtime_env_validator="${KDJX_RUNTIME_ENV_VALIDATOR:-$runtime_root/scripts/validate-runtime-env.py}"
[[ -x "$runtime_env_validator" ]] || fail "runtime environment validation is unavailable: $runtime_env_validator"
gm_env_validator="${KDJX_GM_ENV_VALIDATOR:-$runtime_root/scripts/validate-gm-env.py}"
[[ -x "$gm_env_validator" ]] || fail "GM environment validation is unavailable: $gm_env_validator"
economy_gate="$runtime_root/sakura-economy-compatibility-gate.txt"
[[ -f "$economy_gate" && ! -L "$economy_gate" ]] \
    || fail "Sakura economy compatibility gate is unavailable"
[[ "$(tr -d '[:space:]' < "$economy_gate")" == "sakura-economy-compatibility-v1" ]] \
    || fail "Sakura economy compatibility gate is invalid"
payment_rpc_gate="$runtime_root/sakura-payment-rpc-gate.txt"
[[ -f "$payment_rpc_gate" && ! -L "$payment_rpc_gate" ]] \
    || fail "Sakura payment RPC gate is unavailable"
[[ "$(tr -d '[:space:]' < "$payment_rpc_gate")" == "sakura-payment-rpc-gate-v1" ]] \
    || fail "Sakura payment RPC gate is invalid"
grep -Fq 'def VerifySakuraPayment(' "$runtime_root/release/src/game/rpc.py" \
    || fail "Sakura payment verification RPC is unavailable"
grep -Fq 'def PayForRecharge(' "$runtime_root/release/src/game/rpc.py" \
    || fail "Sakura payment fulfillment RPC is unavailable"
grep -Fq 'rePro, channel))' "$runtime_root/release/src/game/rpc.py" \
    || fail "Sakura offline payment channel cache is unavailable"
grep -Fq 'channel=channel)' \
    "$runtime_root/release/src/game/handler/_game.py" \
    || fail "Sakura offline payment channel replay is unavailable"
grep -Fq 'SakuraRechargeRMB = {' "$runtime_root/release/src/game/object/game/role.py" \
    || fail "Sakura recharge value compatibility is unavailable"
grep -Fq 'def _applySakuraRechargeCompatibility(self):' \
    "$runtime_root/release/src/game/object/game/role.py" \
    || fail "Sakura recharge history compatibility is unavailable"
grep -Fq 'def _applySakuraTrainerExperienceCompatibility(self):' \
    "$runtime_root/release/src/game/object/game/role.py" \
    || fail "Sakura trainer experience compatibility is unavailable"
grep -Fq "attachs['role_exp']" "$runtime_root/release/src/game/rpc.py" \
    || fail "Sakura trainer experience delivery mapping is unavailable"
command -v luajit >/dev/null 2>&1 || fail "LuaJIT is unavailable"
"$runtime_env_validator" --env-file /etc/kdjx/runtime.env
"$gm_env_validator" --env-file /etc/kdjx/gm.env

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

for port in 2113 27159 4150 4160 4161 18080 16666; do
    require_tcp "$port"
done
require_udp_listener 32888

curl "${curl_options[@]}" --fail --silent --show-error --compressed http://127.0.0.1:18080/servers >/dev/null
require_loopback_json_status 401 /internal/sakura/payments/verify
require_loopback_json_status 401 /internal/sakura/payments/fulfill
require_loopback_json_status 401 /internal/sakura/gm/deliveries
curl "${curl_options[@]}" --fail --silent --show-error --compressed -H 'Host: 49.232.137.85' http://127.0.0.1/kdjx/servers >/dev/null
version_payload="$(curl "${curl_options[@]}" --fail --silent --show-error --compressed \
    -H 'Host: 49.232.137.85' \
    'http://127.0.0.1/kdjx/version?fake=true')"
expected_app_version='2.1.'
expected_app_version+='0.0'
[[ "$version_payload" == *"\"app_version\":\"$expected_app_version\""* ]] \
    || fail "unexpected KDJX app version response"
[[ "$version_payload" == *'"patch_url":"https://novel.kxhub.xyz/games/kdjx/hot/"'* ]] \
    || fail "unexpected KDJX hot-update URL"
curl "${curl_options[@]}" --fail --silent --show-error --compressed -H 'Host: 49.232.137.85' http://127.0.0.1/kdjx/notice >/dev/null
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
    /kdjx/internal/sakura/gm/deliveries \
    /novel-api/games/kdjx/sessions/verify \
    /novel-api/games/kdjx/sessions/verify/; do
    require_http_status 404 GET "$route"
done

"$audit_script" --runtime-root "$runtime_root"
printf 'KDJX runtime health check passed.\n'
