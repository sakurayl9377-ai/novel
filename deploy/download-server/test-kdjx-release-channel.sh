#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/deploy-kdjx-game-release.sh"
hot_helper="$script_dir/deploy-kdjx-hot-update.sh"
installer="$script_dir/install-kdjx-release-channel.sh"
endpoint_audit="$script_dir/audit-kdjx-release-endpoints.py"
zipalign_installer="$script_dir/install-kdjx-zipalign.sh"
approved_signer="1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
legacy_signer="a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"
download_base_urls="https://novel.kxhub.xyz/games/kdjx"
download_hosts="novel.kxhub.xyz"
token="Audit$$${RANDOM}"
staging_dir="/tmp/novel-kdjx-release-2.1.0.0+3-${token}"
rollback_staging_dir="/tmp/novel-kdjx-release-2.0.0+2-${token}"
release_dir="/tmp/novel-kdjx-release-target-${token}"
rejected_dir="/tmp/novel-kdjx-rejected-target-${token}"
lock_file="/tmp/novel-kdjx-release-${token}.lock"
mock_root="/tmp/novel-kdjx-mocks-${token}"
install_root="/tmp/novel-kdjx-install-test-${token}"
hot_staging_dir="/tmp/novel-kdjx-hot-update-39-${token}"
hot_release_dir="/tmp/novel-kdjx-hot-update-target-${token}"
hot_lock_file="/tmp/novel-kdjx-hot-update-${token}.lock"
prune_dir="/tmp/novel-game-prune-test-kdjx-${token}"
modao_prune_dir="/tmp/novel-game-prune-test-modao-${token}"

fail() {
  printf 'KDJX download channel test failed: %s\n' "$1" >&2
  exit 1
}

KDJX_TEST_REAL_PYTHON=""
for python_candidate in python3 python; do
  if command -v "$python_candidate" >/dev/null 2>&1 \
    && "$python_candidate" -c \
      'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' \
      >/dev/null 2>&1; then
    KDJX_TEST_REAL_PYTHON="$(command -v "$python_candidate")"
    break
  fi
done
[[ -n "$KDJX_TEST_REAL_PYTHON" ]] || {
  printf 'Python 3 is required for KDJX download channel tests\n' >&2
  exit 1
}
export KDJX_TEST_REAL_PYTHON

cleanup() {
  case "$staging_dir:$rollback_staging_dir:$release_dir:$rejected_dir:$mock_root:$install_root:$hot_staging_dir:$hot_release_dir:$prune_dir:$modao_prune_dir" in
    /tmp/novel-kdjx-release-*:/tmp/novel-kdjx-release-*:/tmp/novel-kdjx-release-target-*:/tmp/novel-kdjx-rejected-target-*:/tmp/novel-kdjx-mocks-*:/tmp/novel-kdjx-install-test-*:/tmp/novel-kdjx-hot-update-*:/tmp/novel-kdjx-hot-update-target-*:/tmp/novel-game-prune-test-kdjx-*:/tmp/novel-game-prune-test-modao-*)
      rm -rf -- \
        "$staging_dir" \
        "$rollback_staging_dir" \
        "$release_dir" \
        "$rejected_dir" \
        "$mock_root" \
        "$install_root" \
        "$hot_staging_dir" \
        "$hot_release_dir" \
        "$prune_dir" \
        "$modao_prune_dir"
      ;;
    *)
      printf 'Unsafe KDJX test cleanup paths\n' >&2
      ;;
  esac
  rm -f -- "$lock_file" "$hot_lock_file"
}

trap cleanup EXIT

bash -n "$helper"
bash -n "$hot_helper"
bash -n "$installer"
bash -n "$script_dir/kdjx-download-url-policy.sh"
bash -n "$zipalign_installer"
"$KDJX_TEST_REAL_PYTHON" "$endpoint_audit" --help >/dev/null
grep -Fq 'lock_file="${KDJX_GAME_RELEASE_LOCK_FILE:-/run/lock/novel-kdjx-game-release.lock}"' \
  "$helper"
grep -Fq 'legacy_test_signer_forbidden' "$helper"
grep -Fq 'part_count=5' "$helper"
grep -Fq 'endpoint_policy_violation' "$helper"
grep -Fq 'endpoint_policy_violation' "$hot_helper"
grep -Fq 'archive_sha1="83d08ea1cdad9733cae08e33c84758835987a508"' "$zipalign_installer"
grep -Fq 'created_tool_root' "$zipalign_installer"
grep -Fq 'verify_zipalign "$wrapper_candidate"' "$zipalign_installer"
if grep -Fq '"$wrapper" -h' "$zipalign_installer"; then
  fail "zipalign_help_flag_is_not_supported"
fi
bash -n "$script_dir/prune-game-release-artifacts.sh"
grep -Fq 'location = /games/kdjx/manifest.json {' \
  "$script_dir/nginx-kdjx-locations.conf"
grep -Fq '/games/kdjx/hot/[1-9][0-9]{0,8}/' \
  "$script_dir/nginx-kdjx-locations.conf"
grep -Fq 'limit_except GET HEAD {' \
  "$script_dir/nginx-kdjx-locations.conf"

mkdir -p -- \
  "$staging_dir" \
  "$rollback_staging_dir" \
  "$mock_root" \
  "$install_root/sbin" \
  "$install_root/snippets" \
  "$install_root/policy" \
  "$install_root/releases" \
  "$install_root/conf"

cat > "$mock_root/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$mock_root/apksigner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '0.9\n'
  exit 0
fi
[[ "${1:-}" == "verify" && "${2:-}" == "--verbose" \
  && "${3:-}" == "--print-certs" && -f "${4:-}" ]]
printf 'Signer #1 certificate SHA-256 digest: %s\n' "${MOCK_APK_SIGNER_SHA256:?}"
SH
cat > "$mock_root/nginx" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-t" ]]
if [[ "${MOCK_NGINX_REJECT_KDJX:-0}" == "1" \
  && -f "${MOCK_NGINX_CONFIG:?}" ]] \
  && grep -Fq 'include ' "$MOCK_NGINX_CONFIG" \
  && grep -Fq 'novel-kdjx-download.conf;' "$MOCK_NGINX_CONFIG"; then
  exit 1
fi
SH
cat > "$mock_root/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
grep -Eq -- '--resolve [a-z0-9.-]+:443:47\.88\.26\.14' <<<"$*"
exit 0
SH
cat > "$mock_root/python3" <<'SH'
#!/usr/bin/env bash
set -o pipefail
"${KDJX_TEST_REAL_PYTHON:?}" "$@" | tr -d '\r'
SH
chmod 0755 \
  "$mock_root/flock" \
  "$mock_root/apksigner" \
  "$mock_root/nginx" \
  "$mock_root/curl" \
  "$mock_root/python3"
export PATH="$mock_root:$PATH"
export KDJX_DOWNLOAD_BASE_URLS="$download_base_urls"

python3 - "$mock_root/legacy-endpoint.apk" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as apk:
    apk.writestr("AndroidManifest.xml", b"fixture")
    apk.writestr("classes.dex", b"fixture")
    apk.writestr("assets/legacy.lua", b"return 'http://192.168.1.99/legacy'")
PY
if python3 "$endpoint_audit" --apk "$mock_root/legacy-endpoint.apk" \
  > "$mock_root/apk-endpoint.out" 2>&1; then
  printf 'KDJX APK endpoint audit accepted a legacy endpoint\n' >&2
  exit 1
fi
grep -Fq 'legacy 192.168.' "$mock_root/apk-endpoint.out"

python3 - "$staging_dir" "$rollback_staging_dir" "$approved_signer" "$download_base_urls" <<'PY'
import hashlib
import json
import pathlib
import shutil
import sys
import zipfile

staging = pathlib.Path(sys.argv[1])
rollback = pathlib.Path(sys.argv[2])
signer = sys.argv[3]
bases = sys.argv[4].split(",")
fixture = staging / "fixture.apk"
with zipfile.ZipFile(fixture, "w") as apk:
    apk.writestr("AndroidManifest.xml", b"KDJX release fixture manifest")
    apk.writestr("classes.dex", b"KDJX release fixture dex")
    apk.writestr("assets/payload.bin", b"0123456789" * 127)
raw = fixture.read_bytes()
sha256 = hashlib.sha256(raw).hexdigest()
name = f"kdjx-3-{sha256[:12]}.apk"
fixture.rename(staging / name)
manifest = {
    "packageName": "com.kd.kdjxcs",
    "versionName": "2.1.0.0",
    "versionCode": 3,
    "apkUrl": f"{bases[0]}/{name}",
    "apkUrls": [f"{base}/{name}" for base in bases],
    "sizeBytes": len(raw),
    "sha256": sha256,
    "signingCertificateSha256": signer,
    "notes": ["offline KDJX release fixture"],
}
(staging / "manifest.json").write_text(
    json.dumps(manifest, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
rollback_manifest = dict(manifest)
rollback_manifest["versionName"] = "2.0.0"
rollback_manifest["versionCode"] = 2
rollback_name = f"kdjx-2-{sha256[:12]}.apk"
rollback_manifest["apkUrl"] = f"{bases[0]}/{rollback_name}"
rollback_manifest["apkUrls"] = [f"{base}/{rollback_name}" for base in bases]
shutil.copyfile(staging / name, rollback / rollback_name)
(rollback / "manifest.json").write_text(
    json.dumps(rollback_manifest, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

MOCK_APK_SIGNER_SHA256="$approved_signer" \
KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256="$approved_signer" \
KDJX_APKSIGNER_BIN="$mock_root/apksigner" \
KDJX_GAME_RELEASE_DIR="$release_dir" \
KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
  bash "$helper" "$staging_dir" >/dev/null

python3 - "$release_dir" "$download_base_urls" <<'PY'
import hashlib
import json
import pathlib
import sys

release = pathlib.Path(sys.argv[1])
bases = sys.argv[2].split(",")
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
apk_name = f"kdjx-{manifest['versionCode']}-{manifest['sha256'][:12]}.apk"
apk = (release / apk_name).read_bytes()
assert hashlib.sha256(apk).hexdigest() == manifest["sha256"]
assert manifest["apkUrls"] == [f"{base}/{apk_name}" for base in bases]
parts = manifest["parts"]
assert len(parts) == 5
assert [part["index"] for part in parts] == list(range(5))
assert sum(part["sizeBytes"] for part in parts) == manifest["sizeBytes"]
assert max(part["sizeBytes"] for part in parts) - min(part["sizeBytes"] for part in parts) <= 1
rebuilt = bytearray()
for index, part in enumerate(parts):
    expected_name = f"{apk_name[:-4]}.part-{index:03d}.apk"
    assert part["url"] == f"{bases[index % len(bases)]}/{expected_name}"
    payload = (release / expected_name).read_bytes()
    assert len(payload) == part["sizeBytes"]
    assert hashlib.sha256(payload).hexdigest() == part["sha256"]
    rebuilt.extend(payload)
assert bytes(rebuilt) == apk
history = release / f"manifest-{manifest['versionName']}+{manifest['versionCode']}.json"
assert history.read_bytes() == (release / "manifest.json").read_bytes()
assert not list(release.glob("*.next.*"))
PY

if MOCK_APK_SIGNER_SHA256="$approved_signer" \
  KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256="$approved_signer" \
  KDJX_APKSIGNER_BIN="$mock_root/apksigner" \
  KDJX_GAME_RELEASE_DIR="$release_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$helper" "$rollback_staging_dir" > "$mock_root/rollback.out"; then
  printf 'KDJX helper accepted a version rollback\n' >&2
  exit 1
fi
grep -Fq '"error":"version_rollback_blocked"' "$mock_root/rollback.out"

if MOCK_APK_SIGNER_SHA256="$(printf '2%.0s' {1..64})" \
  KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256="$approved_signer" \
  KDJX_APKSIGNER_BIN="$mock_root/apksigner" \
  KDJX_GAME_RELEASE_DIR="$rejected_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$helper" "$staging_dir" > "$mock_root/signer.out"; then
  printf 'KDJX helper accepted an unapproved APK signer\n' >&2
  exit 1
fi
grep -Fq '"error":"apk_signer_not_approved"' "$mock_root/signer.out"

if KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256="$legacy_signer" \
  KDJX_GAME_RELEASE_DIR="$rejected_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$helper" "$staging_dir" > "$mock_root/legacy.out"; then
  printf 'KDJX helper accepted the legacy Android test signer\n' >&2
  exit 1
fi
grep -Fq '"error":"legacy_test_signer_forbidden"' "$mock_root/legacy.out"

mkdir -p -- "$prune_dir/hot/releases/1"
cp -- "$release_dir/manifest.json" "$prune_dir/manifest.json"
cp -- "$release_dir"/manifest-*.json "$prune_dir/"
cp -- "$release_dir"/*.apk "$prune_dir/"
printf 'unmanaged file must survive\n' > "$prune_dir/keep.txt"
printf 'hot update must survive\n' > "$prune_dir/hot/releases/1/asset.bin"
printf 'old whole APK\n' > "$prune_dir/kdjx-2-aaaaaaaaaaaa.apk"
for part_index in 0 1 2 3 4; do
  printf -v part_label '%03d' "$part_index"
  printf 'old part %s\n' "$part_label" \
    > "$prune_dir/kdjx-2-aaaaaaaaaaaa.part-${part_label}.apk"
done
printf '{"old":true}\n' > "$prune_dir/manifest-2.0.0+2.json"

dry_plan="$(
  NOVEL_GAME_PRUNE_TEST_MODE=1 \
  NOVEL_GAME_PRUNE_RELEASE_DIR="$prune_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$script_dir/prune-game-release-artifacts.sh" kdjx
)"
mapfile -t prune_confirmation < <(python3 - "$dry_plan" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert value["mode"] == "dry-run"
assert value["candidateCount"] == 7
print(value["currentSha256"])
print(value["planId"])
PY
)
[[ ${#prune_confirmation[@]} -eq 2 ]]
current_prune_sha="${prune_confirmation[0]}"
stale_plan_id="${prune_confirmation[1]}"
printf 'change after dry-run\n' >> "$prune_dir/kdjx-2-aaaaaaaaaaaa.apk"
if NOVEL_GAME_PRUNE_TEST_MODE=1 \
  NOVEL_GAME_PRUNE_RELEASE_DIR="$prune_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$script_dir/prune-game-release-artifacts.sh" \
      kdjx --apply "$current_prune_sha" "$stale_plan_id" \
      > "$mock_root/stale-prune.out"; then
  printf 'KDJX prune helper accepted a stale plan\n' >&2
  exit 1
fi
[[ -f "$prune_dir/kdjx-2-aaaaaaaaaaaa.apk" ]]

dry_plan="$(
  NOVEL_GAME_PRUNE_TEST_MODE=1 \
  NOVEL_GAME_PRUNE_RELEASE_DIR="$prune_dir" \
  KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$script_dir/prune-game-release-artifacts.sh" kdjx
)"
mapfile -t prune_confirmation < <(python3 - "$dry_plan" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
print(value["currentSha256"])
print(value["planId"])
PY
)
NOVEL_GAME_PRUNE_TEST_MODE=1 \
NOVEL_GAME_PRUNE_RELEASE_DIR="$prune_dir" \
KDJX_GAME_RELEASE_LOCK_FILE="$lock_file" \
  bash "$script_dir/prune-game-release-artifacts.sh" \
    kdjx --apply "${prune_confirmation[0]}" "${prune_confirmation[1]}" \
    >/dev/null
[[ ! -e "$prune_dir/kdjx-2-aaaaaaaaaaaa.apk" ]]
[[ ! -e "$prune_dir/manifest-2.0.0+2.json" ]]
[[ -f "$prune_dir/manifest.json" && -f "$prune_dir/keep.txt" ]]
[[ -f "$prune_dir/hot/releases/1/asset.bin" ]]
[[ "$(find "$prune_dir" -maxdepth 1 -type f -name 'kdjx-*.apk' | wc -l | tr -d ' ')" == "6" ]]

mkdir -p -- "$modao_prune_dir/hot/releases/119"
python3 - "$modao_prune_dir" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
payload = b"current modao APK fixture"
sha256 = hashlib.sha256(payload).hexdigest()
apk_name = f"modao-2023981004-{sha256[:12]}.apk"
(root / apk_name).write_bytes(payload)
parts = []
offset = 0
base, remainder = divmod(len(payload), 5)
for index in range(5):
    size = base + (1 if index < remainder else 0)
    part_payload = payload[offset:offset + size]
    offset += size
    name = f"{apk_name[:-4]}.part-{index:03d}.apk"
    (root / name).write_bytes(part_payload)
    parts.append({
        "index": index,
        "url": f"https://novel.kxhub.xyz/games/modao/{name}",
        "sizeBytes": len(part_payload),
        "sha256": hashlib.sha256(part_payload).hexdigest(),
    })
manifest = {
    "packageName": "com.you91.fish.lucky",
    "versionName": "10.0.0.0",
    "versionCode": 2023981004,
    "apkUrl": f"https://novel.kxhub.xyz/games/modao/{apk_name}",
    "sizeBytes": len(payload),
    "sha256": sha256,
    "signingCertificateSha256": "1" * 64,
    "notes": [],
    "parts": parts,
}
encoded = json.dumps(manifest, separators=(",", ":")) + "\n"
(root / "manifest.json").write_text(encoded, encoding="utf-8")
(root / "manifest-10.0.0.0+2023981004.json").write_text(encoded, encoding="utf-8")
(root / "modao-2023981002-aaaaaaaaaaaa.apk").write_bytes(b"old")
for index in range(5):
    (root / f"modao-2023981002-aaaaaaaaaaaa.part-{index:03d}.apk").write_bytes(b"old")
(root / "manifest-10.0.0.0+2023981002.json").write_text("{}\n", encoding="utf-8")
(root / "hot" / "releases" / "119" / "asset.bin").write_bytes(b"hot")
PY
modao_dry_plan="$(
  NOVEL_GAME_PRUNE_TEST_MODE=1 \
  NOVEL_GAME_PRUNE_RELEASE_DIR="$modao_prune_dir" \
  MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$script_dir/prune-game-release-artifacts.sh" modao
)"
mapfile -t modao_confirmation < <(python3 - "$modao_dry_plan" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert value["game"] == "modao"
assert value["candidateCount"] == 7
print(value["currentSha256"])
print(value["planId"])
PY
)
NOVEL_GAME_PRUNE_TEST_MODE=1 \
NOVEL_GAME_PRUNE_RELEASE_DIR="$modao_prune_dir" \
MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
  bash "$script_dir/prune-game-release-artifacts.sh" \
    modao --apply "${modao_confirmation[0]}" "${modao_confirmation[1]}" \
    >/dev/null
[[ ! -e "$modao_prune_dir/modao-2023981002-aaaaaaaaaaaa.apk" ]]
[[ ! -e "$modao_prune_dir/manifest-10.0.0.0+2023981002.json" ]]
[[ "$(find "$modao_prune_dir" -maxdepth 1 -type f -name 'modao-*.apk' | wc -l | tr -d ' ')" == "6" ]]
[[ -f "$modao_prune_dir/hot/releases/119/asset.bin" ]]

nginx_config="$install_root/conf/novel-download.conf"
cat > "$nginx_config" <<'NGINX'
server {
    listen 80;
    server_name novel.kxhub.xyz;
}
server {
    listen 443 ssl;
    server_name novel.kxhub.xyz;
    location = /games/modao/manifest.json { return 404; }
    location = /app3/version.json { return 404; }
    location / { return 404; }
}
NGINX
installed_helper="$install_root/sbin/novel-kdjx-game-release-deploy"
installed_hot_helper="$install_root/sbin/novel-kdjx-hot-update-deploy"
installed_prune_helper="$install_root/sbin/novel-game-release-prune"
installed_url_policy_helper="$install_root/sbin/novel-kdjx-download-url-policy"
installed_endpoint_audit="$install_root/sbin/novel-kdjx-release-endpoint-audit"
installed_snippet="$install_root/snippets/novel-kdjx-download.conf"
installed_policy="$install_root/policy/kdjx-release-signer.sha256"
installed_url_policy="$install_root/policy/kdjx-download-base-urls"
installer_env=(
  env
  "KDJX_INSTALL_TEST_MODE=1"
  "NOVEL_DOWNLOAD_SKIP_RELOAD=1"
  "NOVEL_DOWNLOAD_NGINX_BIN=$mock_root/nginx"
  "KDJX_APKSIGNER_BIN=$mock_root/apksigner"
  "NOVEL_DOWNLOAD_NGINX_TARGET=$nginx_config"
  "KDJX_RELEASE_HELPER_TARGET=$installed_helper"
  "KDJX_HOT_UPDATE_HELPER_TARGET=$installed_hot_helper"
  "GAME_RELEASE_PRUNE_HELPER_TARGET=$installed_prune_helper"
  "KDJX_DOWNLOAD_URL_POLICY_HELPER_TARGET=$installed_url_policy_helper"
  "KDJX_ENDPOINT_AUDIT_HELPER_TARGET=$installed_endpoint_audit"
  "KDJX_NGINX_SNIPPET_TARGET=$installed_snippet"
  "KDJX_SIGNER_POLICY_FILE=$installed_policy"
  "KDJX_DOWNLOAD_URL_POLICY_FILE=$installed_url_policy"
  "KDJX_GAME_RELEASE_DIR=$install_root/releases/kdjx"
  "KDJX_CURL_BIN=$mock_root/curl"
  "MOCK_APK_SIGNER_SHA256=$approved_signer"
  "MOCK_NGINX_CONFIG=$nginx_config"
  "MOCK_CURL_LOG=$mock_root/curl.log"
)
if "${installer_env[@]}" bash "$installer" 49.232.137.85 "$approved_signer" >/dev/null 2>&1; then
  printf 'KDJX installer accepted the backend server address\n' >&2
  exit 1
fi
if "${installer_env[@]}" bash "$installer" 47.88.26.14 "$legacy_signer" >/dev/null 2>&1; then
  printf 'KDJX installer accepted the legacy Android test signer\n' >&2
  exit 1
fi
if "${installer_env[@]}" bash "$installer" 47.88.26.14 "$approved_signer" \
  "novel.kxhub.xyz,mirror.kxhub.xyz" >/dev/null 2>&1; then
  printf 'KDJX installer accepted an unverified download mirror\n' >&2
  exit 1
fi

config_before="$(sha256sum -- "$nginx_config" | awk '{print $1}')"
if "${installer_env[@]}" "MOCK_NGINX_REJECT_KDJX=1" \
  bash "$installer" 47.88.26.14 "$approved_signer" >/dev/null 2>&1; then
  printf 'KDJX installer kept an invalid Nginx candidate\n' >&2
  exit 1
fi
[[ "$(sha256sum -- "$nginx_config" | awk '{print $1}')" == "$config_before" ]]
[[ ! -e "$installed_snippet" ]]

"${installer_env[@]}" bash "$installer" 47.88.26.14 "$approved_signer" "$download_hosts" >/dev/null
"${installer_env[@]}" bash "$installer" 47.88.26.14 "$approved_signer" "$download_hosts" >/dev/null
[[ -x "$installed_helper" && -x "$installed_hot_helper" && -x "$installed_prune_helper" && -x "$installed_url_policy_helper" && -x "$installed_endpoint_audit" ]]
[[ -f "$installed_snippet" && -f "$installed_policy" && -f "$installed_url_policy" ]]
[[ "$(cat "$installed_policy")" == "$approved_signer" ]]
[[ "$(paste -sd, "$installed_url_policy")" == "$download_base_urls" ]]
[[ "$(grep -Fc "include $installed_snippet;" "$nginx_config")" == "1" ]]
[[ -d "$install_root/releases/kdjx" ]]
grep -Fq -- "--resolve novel.kxhub.xyz:443:47.88.26.14" "$mock_root/curl.log"
! grep -Fq -- "--resolve mirror.kxhub.xyz:443:47.88.26.14" "$mock_root/curl.log"

mkdir -p -- "$hot_staging_dir/releases/39/assets/main"
python3 - "$hot_staging_dir" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import sys

staging = pathlib.Path(sys.argv[1])
plist = plistlib.dumps(
    {"app_version": "2.1.0.0", "patch": "9"},
    fmt=plistlib.FMT_XML,
    sort_keys=False,
).replace(
    b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n',
    b"",
)
payloads = {
    "assets/main/index.lua": b"managed KDJX hot update fixture\n",
    "res/version.plist": plist,
    "src/app.defines.app_defines": b"return {}\n",
    "src/app.game_app": b"return {}\n",
    "src/app.sdk.helper": b"return {}\n",
    "src/app.sdk.init": b"return {}\n",
    "src/app.sdk.none": b"return {}\n",
    "src/app.views.login.view": b"return {}\n",
    "x64/src/app.defines.app_defines": b"return {}\n",
    "x64/src/app.game_app": b"return {}\n",
    "x64/src/app.sdk.helper": b"return {}\n",
    "x64/src/app.sdk.init": b"return {}\n",
    "x64/src/app.sdk.none": b"return {}\n",
    "x64/src/app.views.login.view": b"return {}\n",
}
for index in range(2559 - len(payloads)):
    payloads[f"assets/cumulative/{index:04d}.bin"] = b"cumulative fixture\n"
manifest_assets = {}
legacy_files = []
legacy_revision = hashlib.sha1()
for relative, payload in sorted(payloads.items()):
    compatibility = staging / "releases" / "39" / relative
    compatibility.parent.mkdir(parents=True, exist_ok=True)
    compatibility.write_bytes(payload)
    legacy = staging / "9" / relative
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_bytes(payload)
    digest = hashlib.md5(payload).hexdigest()
    manifest_assets[relative] = {
        "size": len(payload),
        "md5": digest,
        "compressed": False,
    }
    legacy_files.append({
        "name": relative,
        "size": len(payload),
        "md5": digest,
        "patch": 9,
    })
    legacy_revision.update(
        f"{relative}\0{len(payload)}\0{digest}\n".encode("utf-8")
    )
base = "https://novel.kxhub.xyz/games/kdjx/hot/"
shared = {
    "version": "39",
    "packageUrl": f"{base}releases/39/",
    "remoteVersionUrl": f"{base}version.manifest",
    "remoteManifestUrl": f"{base}project.manifest",
}
project = {
    **shared,
    "assets": manifest_assets,
    "searchPaths": [],
}
(staging / "version.manifest").write_text(
    json.dumps(shared, separators=(",", ":")) + "\n", encoding="utf-8"
)
(staging / "project.manifest").write_text(
    json.dumps(project, separators=(",", ":")) + "\n", encoding="utf-8"
)
(staging / "release-metadata.json").write_text(
    json.dumps(
        {
            "version": "39",
            "assetCount": len(payloads),
            "totalBytes": sum(map(len, payloads.values())),
        },
        separators=(",", ":"),
    ) + "\n",
    encoding="utf-8",
)
(staging / "legacy-patch.json").write_text(
    json.dumps(
        {
            "files": legacy_files,
            "svn_version": "39",
            "git_version": legacy_revision.hexdigest(),
        },
        separators=(",", ":"),
    ) + "\n",
    encoding="utf-8",
)
PY

if KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
  KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
    bash "$hot_helper" "$hot_staging_dir" > "$mock_root/hot-permission.out"; then
  printf 'KDJX hot helper accepted unsafe Git Bash staging modes\n' >&2
  exit 1
fi
grep -Fq '"error":"staging_permissions_invalid"' "$mock_root/hot-permission.out"

printf 'return "http://192.168.1.99/legacy"\n' \
  > "$hot_staging_dir/releases/39/assets/main/index.lua"
if KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
  KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
  KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
    bash "$hot_helper" "$hot_staging_dir" > "$mock_root/hot-endpoint.out" 2>&1; then
  printf 'KDJX hot helper accepted a legacy endpoint\n' >&2
  exit 1
fi
grep -Fq '"error":"endpoint_policy_violation"' "$mock_root/hot-endpoint.out"
printf 'managed KDJX hot update fixture\n' \
  > "$hot_staging_dir/releases/39/assets/main/index.lua"

cp -- "$hot_staging_dir/legacy-patch.json" \
  "$mock_root/legacy-patch.valid.json"
python3 - "$hot_staging_dir/legacy-patch.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["files"].pop()
path.write_text(
    json.dumps(value, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
if KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
  KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
  KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
    bash "$hot_helper" "$hot_staging_dir" > "$mock_root/hot-first-sakura-count.out" 2>&1; then
  printf 'KDJX hot helper accepted an incomplete first Sakura patch\n' >&2
  exit 1
fi
grep -Fq '"error":"release_validation_failed"' \
  "$mock_root/hot-first-sakura-count.out"
cp -- "$mock_root/legacy-patch.valid.json" \
  "$hot_staging_dir/legacy-patch.json"

python3 - "$hot_staging_dir/legacy-patch.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["git_version"] = "0" * 40
path.write_text(
    json.dumps(value, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
if KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
  KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
  KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
    bash "$hot_helper" "$hot_staging_dir" > "$mock_root/hot-legacy-revision.out" 2>&1; then
  printf 'KDJX hot helper accepted a false legacy revision\n' >&2
  exit 1
fi
grep -Fq '"error":"release_validation_failed"' \
  "$mock_root/hot-legacy-revision.out"
cp -- "$mock_root/legacy-patch.valid.json" \
  "$hot_staging_dir/legacy-patch.json"

printf 'tampered legacy fixture\n' \
  > "$hot_staging_dir/9/assets/main/index.lua"
if KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
  KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
  KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
    bash "$hot_helper" "$hot_staging_dir" > "$mock_root/hot-legacy-digest.out" 2>&1; then
  printf 'KDJX hot helper accepted a legacy digest mismatch\n' >&2
  exit 1
fi
grep -Fq '"error":"release_validation_failed"' "$mock_root/hot-legacy-digest.out"
printf 'managed KDJX hot update fixture\n' \
  > "$hot_staging_dir/9/assets/main/index.lua"

KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
  bash "$hot_helper" "$hot_staging_dir" >/dev/null
KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS=1 \
KDJX_HOT_UPDATE_DIR="$hot_release_dir" \
KDJX_HOT_UPDATE_LOCK_FILE="$hot_lock_file" \
  bash "$hot_helper" "$hot_staging_dir" >/dev/null
cmp -- \
  "$hot_staging_dir/releases/39/assets/main/index.lua" \
  "$hot_release_dir/releases/39/assets/main/index.lua"
cmp -- \
  "$hot_staging_dir/9/assets/main/index.lua" \
  "$hot_release_dir/9/assets/main/index.lua"
cmp -- \
  "$hot_staging_dir/9/res/version.plist" \
  "$hot_release_dir/9/res/version.plist"
cmp -- "$hot_staging_dir/project.manifest" "$hot_release_dir/project.manifest"
cmp -- "$hot_staging_dir/version.manifest" "$hot_release_dir/version.manifest"
[[ -f "$hot_release_dir/history/project-39.manifest" ]]
[[ -f "$hot_release_dir/history/version-39.manifest" ]]
cmp -- \
  "$hot_staging_dir/legacy-patch.json" \
  "$hot_release_dir/history/legacy-patch-9.json"
[[ "$(stat -c '%a' -- "$hot_release_dir/9")" == "755" ]]

printf 'KDJX download release channel tests passed.\n'
