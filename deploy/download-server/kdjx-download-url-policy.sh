#!/usr/bin/env bash

# Shared KDJX URL policy. The public TLS hostname remains stable while this
# release channel verifies it directly against the owned download origin.
kdjx_primary_download_base_url="https://novel.kxhub.xyz/games/kdjx"
kdjx_default_download_url_policy_file="/etc/novel/kdjx-download-base-urls"
KDJX_DOWNLOAD_BASE_URLS_ARRAY=()
KDJX_DOWNLOAD_HOSTS_ARRAY=()

kdjx_load_download_base_urls() {
  local raw_urls="${KDJX_DOWNLOAD_BASE_URLS:-}"
  local policy_file="${KDJX_DOWNLOAD_URL_POLICY_FILE:-$kdjx_default_download_url_policy_file}"
  local parsed_urls
  if [[ -z "$raw_urls" && -f "$policy_file" && ! -L "$policy_file" ]]; then
    raw_urls="$(tr '\n' ',' < "$policy_file")"
  fi
  if [[ -z "$raw_urls" ]]; then
    raw_urls="$kdjx_primary_download_base_url"
  fi
  parsed_urls="$(python3 - "$raw_urls" "$kdjx_primary_download_base_url" <<'PY'
import ipaddress
import re
import sys
from urllib.parse import urlsplit

raw, primary = sys.argv[1:]
values = []
for value in re.split(r"[\s,]+", raw):
    if not value:
        continue
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise SystemExit(1)
    if (
        parsed.scheme != "https"
        or not host
        or not re.fullmatch(
            r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+",
            host,
        )
        or parsed.port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path.rstrip("/") != "/games/kdjx"
    ):
        raise SystemExit(1)
    normalized = f"https://{host}/games/kdjx"
    if normalized not in values:
        values.append(normalized)
if values != [primary]:
    raise SystemExit(1)
print("\n".join(values))
PY
)" || return 1
  mapfile -t KDJX_DOWNLOAD_BASE_URLS_ARRAY <<<"$parsed_urls"
  (( ${#KDJX_DOWNLOAD_BASE_URLS_ARRAY[@]} > 0 )) || return 1
  KDJX_DOWNLOAD_HOSTS_ARRAY=()
  local url host
  for url in "${KDJX_DOWNLOAD_BASE_URLS_ARRAY[@]}"; do
    host="${url#https://}"
    host="${host%%/*}"
    KDJX_DOWNLOAD_HOSTS_ARRAY+=("$host")
  done
}

kdjx_write_download_base_url_policy() {
  local target="$1"
  local temporary="${target}.next.$$"
  (( ${#KDJX_DOWNLOAD_BASE_URLS_ARRAY[@]} > 0 )) || return 1
  printf '%s\n' "${KDJX_DOWNLOAD_BASE_URLS_ARRAY[@]}" > "$temporary"
  chmod 0644 -- "$temporary"
  mv -Tf -- "$temporary" "$target"
}

kdjx_verify_download_origins() {
  local origin_ip="$1"
  local curl_bin="$2"
  local host
  [[ "$origin_ip" == "47.88.26.14" ]] || return 1
  (( ${#KDJX_DOWNLOAD_HOSTS_ARRAY[@]} > 0 )) || return 1
  for host in "${KDJX_DOWNLOAD_HOSTS_ARRAY[@]}"; do
    "$curl_bin" \
      --proto '=https' \
      --tlsv1.2 \
      --noproxy '*' \
      --silent \
      --show-error \
      --head \
      --resolve "${host}:443:${origin_ip}" \
      --connect-timeout 10 \
      --max-time 20 \
      "https://${host}/games/kdjx/manifest.json" >/dev/null
  done
}
