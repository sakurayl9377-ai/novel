#!/usr/bin/env bash
set -euo pipefail

expected_server="47.88.26.14"
acknowledged_server="${1:-}"
approved_signer="${2:-${KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256:-}}"
download_hosts_raw="${3:-${KDJX_DOWNLOAD_HOSTS:-novel.kxhub.xyz}}"
legacy_android_test_certificate_sha256="a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper_source="${KDJX_RELEASE_HELPER_SOURCE:-$script_dir/deploy-kdjx-game-release.sh}"
hot_helper_source="${KDJX_HOT_UPDATE_HELPER_SOURCE:-$script_dir/deploy-kdjx-hot-update.sh}"
prune_helper_source="${GAME_RELEASE_PRUNE_HELPER_SOURCE:-$script_dir/prune-game-release-artifacts.sh}"
url_policy_source="${KDJX_DOWNLOAD_URL_POLICY_SOURCE:-$script_dir/kdjx-download-url-policy.sh}"
endpoint_audit_source="${KDJX_ENDPOINT_AUDIT_SOURCE:-$script_dir/audit-kdjx-release-endpoints.py}"
snippet_source="${KDJX_NGINX_SNIPPET_SOURCE:-$script_dir/nginx-kdjx-locations.conf}"
helper_target="${KDJX_RELEASE_HELPER_TARGET:-/usr/local/sbin/novel-kdjx-game-release-deploy}"
hot_helper_target="${KDJX_HOT_UPDATE_HELPER_TARGET:-/usr/local/sbin/novel-kdjx-hot-update-deploy}"
prune_helper_target="${GAME_RELEASE_PRUNE_HELPER_TARGET:-/usr/local/sbin/novel-game-release-prune}"
url_policy_helper_target="${KDJX_DOWNLOAD_URL_POLICY_HELPER_TARGET:-/usr/local/sbin/novel-kdjx-download-url-policy}"
endpoint_audit_helper_target="${KDJX_ENDPOINT_AUDIT_HELPER_TARGET:-/usr/local/sbin/novel-kdjx-release-endpoint-audit}"
snippet_target="${KDJX_NGINX_SNIPPET_TARGET:-/etc/nginx/snippets/novel-kdjx-download.conf}"
policy_target="${KDJX_SIGNER_POLICY_FILE:-/etc/novel/kdjx-release-signer.sha256}"
url_policy_target="${KDJX_DOWNLOAD_URL_POLICY_FILE:-/etc/novel/kdjx-download-base-urls}"
release_dir="${KDJX_GAME_RELEASE_DIR:-/var/www/novel-download/games/kdjx}"
nginx_command="${NOVEL_DOWNLOAD_NGINX_BIN:-nginx}"
apksigner_command="${KDJX_APKSIGNER_BIN:-apksigner}"
curl_command="${KDJX_CURL_BIN:-curl}"
skip_reload="${NOVEL_DOWNLOAD_SKIP_RELOAD:-0}"
test_mode="${KDJX_INSTALL_TEST_MODE:-0}"
if [[ -n "${NOVEL_DOWNLOAD_NGINX_TARGET:-}" ]]; then
  nginx_target="$NOVEL_DOWNLOAD_NGINX_TARGET"
elif [[ -f /etc/nginx/conf.d/novel-download.conf ]]; then
  nginx_target="/etc/nginx/conf.d/novel-download.conf"
elif [[ -f /etc/nginx/sites-available/novel-download.conf ]]; then
  nginx_target="/etc/nginx/sites-available/novel-download.conf"
else
  nginx_target="/etc/nginx/conf.d/novel-download.conf"
fi

work_dir=""
committed=false
switched_targets=()

fail() {
  printf 'kdjx_download_install_error=%s\n' "$1" >&2
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

download_base_urls="$(python3 - "$download_hosts_raw" <<'PY'
import ipaddress
import re
import sys

hosts = []
for raw in re.split(r"[\s,]+", sys.argv[1]):
    if not raw:
        continue
    host = raw.lower()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise SystemExit(1)
    if not re.fullmatch(
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+",
        host,
    ):
        raise SystemExit(1)
    if host not in hosts:
        hosts.append(host)
if hosts != ["novel.kxhub.xyz"]:
    raise SystemExit(1)
print(",".join(f"https://{host}/games/kdjx" for host in hosts))
PY
)" || fail "download_host_policy_invalid"
KDJX_DOWNLOAD_BASE_URLS="$download_base_urls"
[[ -f "$url_policy_source" && ! -L "$url_policy_source" ]] \
  || fail "download_url_policy_source_invalid"
# shellcheck source=kdjx-download-url-policy.sh
source "$url_policy_source"
kdjx_load_download_base_urls || fail "download_host_policy_invalid"

backup_name() {
  printf '%s/%s.backup' "$work_dir" "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
}

backup_target() {
  local target="$1"
  local backup
  backup="$(backup_name "$target")"
  if [[ -f "$target" && ! -L "$target" ]]; then
    cp -a -- "$target" "$backup"
  else
    : > "${backup}.missing"
  fi
}

restore_target() {
  local target="$1"
  local backup
  backup="$(backup_name "$target")"
  if [[ -f "$backup" ]]; then
    local restore="${target}.restore.$$"
    cp -a -- "$backup" "$restore"
    mv -Tf -- "$restore" "$target"
  elif [[ -f "${backup}.missing" ]]; then
    rm -f -- "$target"
  fi
}

rollback() {
  set +e
  local index
  for (( index = ${#switched_targets[@]} - 1; index >= 0; index-- )); do
    restore_target "${switched_targets[$index]}"
  done
  if [[ "$skip_reload" != "1" && ${#switched_targets[@]} -gt 0 ]]; then
    systemctl reload nginx.service >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$work_dir" && "$work_dir" == /tmp/novel-kdjx-install.* && -d "$work_dir" ]]; then
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

install_owner=()
if [[ $EUID -eq 0 ]]; then
  install_owner=(-o root -g root)
else
  [[ "$test_mode" == "1" && "$skip_reload" == "1" ]] || fail "root_required"
fi
[[ "$acknowledged_server" == "$expected_server" ]] \
  || fail "server_acknowledgement_required"
approved_signer="${approved_signer,,}"
approved_signer="${approved_signer//:/}"
approved_signer="${approved_signer//[[:space:]]/}"
[[ "$approved_signer" =~ ^[a-f0-9]{64}$ ]] || fail "signer_policy_invalid"
[[ "$approved_signer" != "$(printf '0%.0s' {1..64})" ]] \
  || fail "signer_policy_placeholder"
[[ "$approved_signer" != "$legacy_android_test_certificate_sha256" ]] \
  || fail "legacy_test_signer_forbidden"

for target in \
  "$helper_target" \
  "$hot_helper_target" \
  "$prune_helper_target" \
  "$url_policy_helper_target" \
  "$endpoint_audit_helper_target" \
  "$snippet_target" \
  "$policy_target" \
  "$url_policy_target" \
  "$release_dir" \
  "$nginx_target"; do
  [[ "$target" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "target_path_invalid"
done
if [[ $EUID -ne 0 ]]; then
  for target in \
    "$helper_target" \
    "$hot_helper_target" \
    "$prune_helper_target" \
    "$url_policy_helper_target" \
    "$endpoint_audit_helper_target" \
    "$snippet_target" \
    "$policy_target" \
    "$url_policy_target" \
    "$release_dir" \
    "$nginx_target"; do
    [[ "$target" == /tmp/novel-kdjx-install-test-* ]] \
      || fail "test_target_outside_tmp"
  done
fi
for source in \
  "$helper_source" \
  "$hot_helper_source" \
  "$prune_helper_source" \
  "$url_policy_source" \
  "$endpoint_audit_source" \
  "$snippet_source"; do
  [[ -f "$source" && ! -L "$source" ]] || fail "source_invalid"
done
[[ -f "$nginx_target" && ! -L "$nginx_target" ]] \
  || fail "existing_nginx_config_missing"
bash -n "$helper_source" || fail "helper_syntax_invalid"
bash -n "$hot_helper_source" || fail "hot_helper_syntax_invalid"
bash -n "$prune_helper_source" || fail "prune_helper_syntax_invalid"
bash -n "$url_policy_source" || fail "url_policy_syntax_invalid"
python3 "$endpoint_audit_source" --help >/dev/null || fail "endpoint_audit_invalid"
grep -Fq 'part_count=5' "$helper_source" || fail "helper_parts_missing"
grep -Fq 'location = /games/kdjx/manifest.json {' "$snippet_source" \
  || fail "snippet_manifest_route_missing"
grep -Fq '/games/kdjx/hot/(version|project)\.manifest' "$snippet_source" \
  || fail "snippet_hot_route_missing"
grep -Fq '/games/kdjx/hot/[1-9][0-9]{0,8}/' "$snippet_source" \
  || fail "snippet_legacy_hot_route_missing"
grep -Fq 'limit_except GET HEAD {' "$snippet_source" \
  || fail "snippet_legacy_hot_read_only_missing"
grep -Fq '.part-00[0-4]\.apk$' "$snippet_source" \
  || fail "snippet_parts_route_missing"
grep -Fq 'Cloudflare-CDN-Cache-Control' "$snippet_source" \
  || fail "snippet_part_cache_missing"
grep -Fq 'location = /games/modao/manifest.json {' "$nginx_target" \
  || fail "existing_modao_route_missing"
grep -Fq 'location = /app3/version.json {' "$nginx_target" \
  || fail "existing_app_route_missing"

nginx_bin="$(resolve_command "$nginx_command")" || fail "nginx_missing"
apksigner_bin="$(resolve_command "$apksigner_command")" || fail "apksigner_missing"
curl_bin="$(resolve_command "$curl_command")" || fail "curl_missing"
"$apksigner_bin" --version >/dev/null 2>&1 || fail "apksigner_unusable"
"$nginx_bin" -t >/dev/null 2>&1 || fail "existing_nginx_config_invalid"

for target in \
  "$helper_target" \
  "$hot_helper_target" \
  "$prune_helper_target" \
  "$url_policy_helper_target" \
  "$endpoint_audit_helper_target" \
  "$snippet_target" \
  "$policy_target" \
  "$url_policy_target" \
  "$nginx_target"; do
  [[ ! -L "$target" ]] || fail "target_symlink_invalid"
done
for parent in \
  "$(dirname -- "$helper_target")" \
  "$(dirname -- "$hot_helper_target")" \
  "$(dirname -- "$prune_helper_target")" \
  "$(dirname -- "$url_policy_helper_target")" \
  "$(dirname -- "$endpoint_audit_helper_target")" \
  "$(dirname -- "$nginx_target")"; do
  [[ -d "$parent" && ! -L "$parent" ]] || fail "target_directory_invalid"
done
install -d -m 0755 "${install_owner[@]}" -- \
  "$(dirname -- "$snippet_target")" \
  "$(dirname -- "$policy_target")" \
  "$(dirname -- "$url_policy_target")" \
  "$(dirname -- "$release_dir")"
for parent in \
  "$(dirname -- "$snippet_target")" \
  "$(dirname -- "$policy_target")" \
  "$(dirname -- "$url_policy_target")" \
  "$(dirname -- "$release_dir")"; do
  [[ -d "$parent" && ! -L "$parent" ]] || fail "target_directory_invalid"
done

work_dir="$(mktemp -d /tmp/novel-kdjx-install.XXXXXX)"
for target in \
  "$helper_target" \
  "$hot_helper_target" \
  "$prune_helper_target" \
  "$url_policy_helper_target" \
  "$endpoint_audit_helper_target" \
  "$snippet_target" \
  "$policy_target" \
  "$url_policy_target" \
  "$nginx_target"; do
  backup_target "$target"
done

nginx_candidate="$work_dir/nginx.candidate"
snippet_target_b64="$(printf '%s' "$snippet_target" | base64 | tr -d '\n')"
KDJX_NGINX_INCLUDE_B64="$snippet_target_b64" \
python3 - "$nginx_target" "$nginx_candidate" <<'PY' \
  || fail "nginx_include_injection_failed"
import base64
import os
import pathlib
import re
import sys

source_path, output_path = sys.argv[1:]
include_path = base64.b64decode(os.environ["KDJX_NGINX_INCLUDE_B64"]).decode("ascii")
text = pathlib.Path(source_path).read_text(encoding="utf-8")
include_line = f"    include {include_path};"

masked = list(text)
quote = None
escaped = False
comment = False
for index, char in enumerate(text):
    if comment:
        if char == "\n":
            comment = False
        else:
            masked[index] = " "
        continue
    if quote is not None:
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == quote:
            quote = None
        if char != "\n":
            masked[index] = " "
        continue
    if char == "#":
        comment = True
        masked[index] = " "
    elif char in "\"'":
        quote = char
        masked[index] = " "
mask = "".join(masked)


def depth_before(position):
    return mask[:position].count("{") - mask[:position].count("}")


def closing_brace(opening):
    depth = 0
    for index in range(opening, len(mask)):
        if mask[index] == "{":
            depth += 1
        elif mask[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


selected = None
for match in re.finditer(r"\bserver\s*\{", mask):
    if depth_before(match.start()) != 0:
        continue
    opening = mask.find("{", match.start(), match.end())
    closing = closing_brace(opening)
    if closing is None:
        raise SystemExit(1)
    body = text[opening + 1:closing]
    if (
        re.search(r"(?m)^\s*listen\s+(?:\[[^]]+\]:)?443(?:\s|;)", body)
        and re.search(r"(?m)^\s*server_name\s+[^;]*\bnovel\.kxhub\.xyz\b[^;]*;", body)
    ):
        if selected is not None:
            raise SystemExit(1)
        selected = (opening, closing)
if selected is None:
    raise SystemExit(1)
opening, closing = selected
include_matches = list(re.finditer(
    rf"(?m)^\s*include\s+{re.escape(include_path)}\s*;\s*$",
    text,
))
if include_matches:
    if len(include_matches) != 1 or not (opening < include_matches[0].start() < closing):
        raise SystemExit(1)
    pathlib.Path(output_path).write_text(text, encoding="utf-8")
    raise SystemExit(0)
prefix = text[:closing].rstrip()
suffix = text[closing:]
result = f"{prefix}\n\n{include_line}\n{suffix}"
pathlib.Path(output_path).write_text(result, encoding="utf-8")
PY

install_switch() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local next="${target}.next.$$"
  install "${install_owner[@]}" -m "$mode" -- "$source" "$next"
  mv -Tf -- "$next" "$target"
  switched_targets+=("$target")
}

install_switch "$snippet_source" "$snippet_target" 0644
install_switch "$nginx_candidate" "$nginx_target" 0644
"$nginx_bin" -t >/dev/null 2>&1 || fail "candidate_nginx_config_invalid"
install_switch "$helper_source" "$helper_target" 0755
install_switch "$hot_helper_source" "$hot_helper_target" 0755
install_switch "$prune_helper_source" "$prune_helper_target" 0755
install_switch "$url_policy_source" "$url_policy_helper_target" 0755
install_switch "$endpoint_audit_source" "$endpoint_audit_helper_target" 0755
printf '%s\n' "$approved_signer" > "$work_dir/signer-policy"
install_switch "$work_dir/signer-policy" "$policy_target" 0644
printf '%s\n' "${KDJX_DOWNLOAD_BASE_URLS_ARRAY[@]}" > "$work_dir/download-base-urls"
install_switch "$work_dir/download-base-urls" "$url_policy_target" 0644
install -d -m 0755 "${install_owner[@]}" -- "$release_dir"

if [[ "$skip_reload" != "1" ]]; then
  systemctl reload nginx.service || fail "nginx_reload_failed"
fi
kdjx_verify_download_origins "$expected_server" "$curl_bin" \
  || fail "download_origin_verification_failed"
committed=true
printf 'kdjx_download_install_status=ok\n'
printf 'kdjx_download_install_server=%s\n' "$expected_server"
printf 'kdjx_download_install_helper=%s\n' "$helper_target"
printf 'kdjx_download_install_hot_helper=%s\n' "$hot_helper_target"
printf 'kdjx_download_install_prune_helper=%s\n' "$prune_helper_target"
printf 'kdjx_download_install_url_policy_helper=%s\n' "$url_policy_helper_target"
printf 'kdjx_download_install_endpoint_audit_helper=%s\n' "$endpoint_audit_helper_target"
printf 'kdjx_download_install_signer_policy=%s\n' "$policy_target"
printf 'kdjx_download_install_url_policy=%s\n' "$url_policy_target"
printf 'kdjx_download_install_nginx_snippet=%s\n' "$snippet_target"
printf 'kdjx_download_install_release_dir=%s\n' "$release_dir"
printf 'kdjx_download_install_hosts=%s\n' "$(IFS=,; printf '%s' "${KDJX_DOWNLOAD_HOSTS_ARRAY[*]}")"
