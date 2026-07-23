#!/usr/bin/env bash
set -euo pipefail

staging_dir="${1:-}"
release_dir="${MODAO_GAME_RELEASE_DIR:-/var/www/novel-download/games/modao}"
lock_file="${MODAO_GAME_RELEASE_LOCK_FILE:-/run/lock/novel-modao-game-release.lock}"
production_dir="/var/www/novel-download/games/modao"
maximum_apk_bytes=4294967296
maximum_version_code=2100000000
part_count=5
# Keep each immutable object comfortably below Cloudflare's 512 MB cache
# ceiling. A larger future APK must increase the part count deliberately.
maximum_part_bytes=500000000
approved_signing_certificate_sha256="c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c"
apksigner_bin="${MODAO_APKSIGNER_BIN:-apksigner}"
temporary_paths=()
current_manifest=""
manifest_needs_reprotect=false

reprotect_current_manifest() {
  if [[ "$manifest_needs_reprotect" == true && -n "$current_manifest" \
    && -f "$current_manifest" && ! -L "$current_manifest" ]]; then
    if chattr +i -- "$current_manifest" >/dev/null 2>&1; then
      manifest_needs_reprotect=false
    else
      printf '{"ok":false,"error":"manifest_reprotect_failed"}\n' >&2
    fi
  fi
}

cleanup() {
  reprotect_current_manifest
  if (( ${#temporary_paths[@]} > 0 )); then
    rm -f -- "${temporary_paths[@]}"
  fi
}

trap cleanup EXIT

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit 1
}

if [[ "$release_dir" == "$production_dir" && $EUID -ne 0 ]]; then
  fail "root_required"
fi
[[ -n "$staging_dir" ]] || fail "staging_path_missing"
[[ "$staging_dir" =~ ^/tmp/novel-modao-release-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\+[0-9]+-[A-Za-z0-9]+$ ]] \
  || fail "staging_path_invalid"
staging_dir="$(realpath -e -- "$staging_dir")"
[[ "$staging_dir" == /tmp/novel-modao-release-* ]] || fail "staging_path_invalid"

lock_parent="$(dirname -- "$lock_file")"
[[ -d "$lock_parent" && ! -L "$lock_parent" ]] || fail "lock_directory_invalid"
exec 9>"$lock_file"
flock -n 9 || fail "release_in_progress"

manifest_path="$staging_dir/manifest.json"
[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || fail "manifest_missing"
manifest_snapshot="$(mktemp /tmp/.novel-modao-manifest.XXXXXX)"
temporary_paths+=("$manifest_snapshot")
install -m 0600 -- "$manifest_path" "$manifest_snapshot"
manifest_path="$manifest_snapshot"
base_manifest_path="$manifest_snapshot"

mapfile -t manifest_values < <(python3 - \
  "$manifest_path" \
  "$maximum_apk_bytes" \
  "$maximum_version_code" \
  "$approved_signing_certificate_sha256" <<'PY'
import json
import re
import sys
from urllib.parse import urlsplit

manifest_path = sys.argv[1]
maximum_bytes, maximum_version_code = map(int, sys.argv[2:4])
approved_signer = sys.argv[4]
with open(manifest_path, "r", encoding="utf-8") as source:
    value = json.load(source)
if not isinstance(value, dict):
    raise SystemExit(1)

package_name = value.get("packageName")
version_name = value.get("versionName")
version_code = value.get("versionCode")
apk_url = value.get("apkUrl")
size_bytes = value.get("sizeBytes")
sha256 = value.get("sha256")
signer = value.get("signingCertificateSha256")
notes = value.get("notes")

if package_name != "com.you91.fish.lucky":
    raise SystemExit(1)
if not isinstance(version_name, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", version_name):
    raise SystemExit(1)
if (
    not isinstance(version_code, int)
    or isinstance(version_code, bool)
    or not (0 < version_code <= maximum_version_code)
):
    raise SystemExit(1)
if not isinstance(size_bytes, int) or isinstance(size_bytes, bool) or not (0 < size_bytes <= maximum_bytes):
    raise SystemExit(1)
if not isinstance(sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
    raise SystemExit(1)
if signer != approved_signer:
    raise SystemExit(1)
if not isinstance(notes, list) or len(notes) > 8 or any(
    not isinstance(note, str) or not note.strip() or len(note) > 200 for note in notes
):
    raise SystemExit(1)

apk_name = f"modao-{version_code}-{sha256[:12]}.apk"
expected_url = f"https://novel.kxhub.xyz/games/modao/{apk_name}"
if not isinstance(apk_url, str) or apk_url != expected_url:
    raise SystemExit(1)
parsed = urlsplit(apk_url)
if (
    parsed.scheme != "https"
    or parsed.hostname != "novel.kxhub.xyz"
    or parsed.port not in (None, 443)
    or parsed.username is not None
    or parsed.password is not None
    or parsed.query
    or parsed.fragment
):
    raise SystemExit(1)

print(version_name)
print(version_code)
print(apk_name)
print(size_bytes)
print(sha256)
print(signer)
PY
) || fail "manifest_invalid"
[[ ${#manifest_values[@]} -eq 6 ]] || fail "manifest_invalid"
version_name="${manifest_values[0]}"
version_code="${manifest_values[1]}"
apk_name="${manifest_values[2]}"
expected_bytes="${manifest_values[3]}"
expected_sha256="${manifest_values[4]}"
signing_certificate_sha256="${manifest_values[5]}"

apk_path="$staging_dir/$apk_name"
[[ -f "$apk_path" && ! -L "$apk_path" ]] || fail "apk_missing"
actual_bytes="$(stat -c '%s' -- "$apk_path")"
(( actual_bytes > 0 && actual_bytes <= maximum_apk_bytes )) || fail "apk_size_invalid"
[[ "$actual_bytes" == "$expected_bytes" ]] || fail "apk_size_mismatch"
actual_sha256="$(sha256sum -- "$apk_path" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail "apk_checksum_mismatch"
python3 - "$apk_path" <<'PY' || fail "apk_archive_invalid"
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "r") as apk:
    names = set(apk.namelist())
    if "AndroidManifest.xml" not in names or "classes.dex" not in names:
        raise SystemExit(1)
    if apk.testzip() is not None:
        raise SystemExit(1)
PY

if [[ "$apksigner_bin" == */* ]]; then
  [[ -x "$apksigner_bin" ]] || fail "apksigner_missing"
else
  apksigner_bin="$(command -v "$apksigner_bin" || true)"
  [[ -n "$apksigner_bin" ]] || fail "apksigner_missing"
fi
signature_output="$("$apksigner_bin" verify --print-certs "$apk_path" 2>&1)" \
  || fail "apk_signature_invalid"
signer_digests=()
while IFS= read -r line; do
  if [[ "$line" =~ certificate[[:space:]]+SHA-256[[:space:]]+digest:[[:space:]]*([0-9A-Fa-f:]+) ]]; then
    signer_digests+=("${BASH_REMATCH[1],,}")
  fi
done <<<"$signature_output"
(( ${#signer_digests[@]} > 0 )) || fail "apk_signer_missing"
for signer_digest in "${signer_digests[@]}"; do
  signer_digest="${signer_digest//:/}"
  [[ "$signer_digest" == "$approved_signing_certificate_sha256" ]] \
    || fail "apk_signer_not_approved"
done

release_parent="$(dirname -- "$release_dir")"
[[ ! -L "$release_parent" && ! -L "$release_dir" ]] || fail "release_directory_invalid"
if [[ $EUID -eq 0 ]]; then
  install -d -m 0755 -o root -g root "$release_parent" "$release_dir"
else
  install -d -m 0755 "$release_parent" "$release_dir"
fi
[[ -d "$release_dir" && ! -L "$release_dir" ]] || fail "release_directory_invalid"
release_dir="$(realpath -e -- "$release_dir")"
if [[ "$release_dir" == "$production_dir" ]]; then
  [[ "$release_dir" == /var/www/novel-download/games/modao ]] || fail "release_directory_invalid"
fi

current_version_code=0
current_sha256=""
current_manifest="$release_dir/manifest.json"
if [[ -e "$current_manifest" ]]; then
  [[ -f "$current_manifest" && ! -L "$current_manifest" ]] || fail "current_manifest_invalid"
  mapfile -t current_values < <(python3 - "$current_manifest" "$maximum_version_code" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    value = json.load(source)
maximum_version_code = int(sys.argv[2])
version_code = value.get("versionCode")
sha256 = value.get("sha256")
if (
    not isinstance(version_code, int)
    or isinstance(version_code, bool)
    or not (0 < version_code <= maximum_version_code)
):
    raise SystemExit(1)
if not isinstance(sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", sha256):
    raise SystemExit(1)
print(version_code)
print(sha256)
PY
  ) || fail "current_manifest_invalid"
  [[ ${#current_values[@]} -eq 2 ]] || fail "current_manifest_invalid"
  current_version_code="${current_values[0]}"
  current_sha256="${current_values[1]}"
fi
(( version_code >= current_version_code )) || fail "version_rollback_blocked"
if (( version_code == current_version_code )) && [[ "$current_sha256" != "$expected_sha256" ]]; then
  fail "version_immutable_conflict"
fi

install_file() {
  local source_path="$1"
  local target_path="$2"
  if [[ $EUID -eq 0 ]]; then
    install -o root -g root -m 0644 -- "$source_path" "$target_path"
  else
    install -m 0644 -- "$source_path" "$target_path"
  fi
}

install_atomic() {
  local source_path="$1"
  local target_path="$2"
  local next_path="${target_path}.next.$$"
  temporary_paths+=("$next_path")
  install_file "$source_path" "$next_path"
  mv -Tf -- "$next_path" "$target_path"
}

part_base_size=$(( expected_bytes / part_count ))
part_remainder=$(( expected_bytes % part_count ))
largest_part_size="$part_base_size"
if (( part_remainder > 0 )); then
  largest_part_size=$(( largest_part_size + 1 ))
fi
(( part_base_size > 0 && largest_part_size <= maximum_part_bytes )) \
  || fail "apk_too_large_for_five_parts"

artifact_target="$release_dir/$apk_name"
artifact_stem="${apk_name%.apk}"
required_release_bytes=0
if [[ ! -e "$artifact_target" ]]; then
  required_release_bytes=$(( required_release_bytes + expected_bytes ))
fi
for (( part_index = 0; part_index < part_count; part_index++ )); do
  part_size="$part_base_size"
  if (( part_index < part_remainder )); then
    part_size=$(( part_size + 1 ))
  fi
  printf -v part_label '%03d' "$part_index"
  part_target="$release_dir/${artifact_stem}.part-${part_label}.apk"
  if [[ ! -e "$part_target" ]]; then
    required_release_bytes=$(( required_release_bytes + part_size ))
  fi
done
available_release_bytes="$(
  LC_ALL=C df -B1 --output=avail "$release_dir" | awk 'NR == 2 { print $1 }'
)"
[[ "$available_release_bytes" =~ ^[0-9]+$ ]] || fail "release_space_check_failed"
minimum_free_margin_bytes=$(( 64 * 1024 * 1024 ))
(( available_release_bytes >= required_release_bytes + minimum_free_margin_bytes )) \
  || fail "release_space_insufficient"

if [[ -e "$artifact_target" ]]; then
  [[ -f "$artifact_target" && ! -L "$artifact_target" ]] || fail "artifact_invalid"
  [[ "$(stat -c '%s' -- "$artifact_target")" == "$expected_bytes" ]] \
    || fail "artifact_size_conflict"
  [[ "$(sha256sum -- "$artifact_target" | awk '{print $1}')" == "$expected_sha256" ]] \
    || fail "artifact_checksum_conflict"
else
  artifact_next="${artifact_target}.next.$$"
  temporary_paths+=("$artifact_next")
  install_file "$apk_path" "$artifact_next"
  [[ "$(stat -c '%s' -- "$artifact_next")" == "$expected_bytes" ]] \
    || fail "artifact_copy_size_mismatch"
  [[ "$(sha256sum -- "$artifact_next" | awk '{print $1}')" == "$expected_sha256" ]] \
    || fail "artifact_copy_checksum_mismatch"
  mv -Tf -- "$artifact_next" "$artifact_target"
fi

parts_metadata="$(mktemp /tmp/.novel-modao-parts.XXXXXX)"
temporary_paths+=("$parts_metadata")
part_offset=0
for (( part_index = 0; part_index < part_count; part_index++ )); do
  part_size="$part_base_size"
  if (( part_index < part_remainder )); then
    part_size=$(( part_size + 1 ))
  fi
  printf -v part_label '%03d' "$part_index"
  part_name="${artifact_stem}.part-${part_label}.apk"
  part_url="https://novel.kxhub.xyz/games/modao/${part_name}"
  part_target="$release_dir/$part_name"
  part_next="${part_target}.next.$$"
  part_output="-"

  if [[ -e "$part_target" ]]; then
    [[ -f "$part_target" && ! -L "$part_target" ]] || fail "part_invalid"
    [[ "$(stat -c '%s' -- "$part_target")" == "$part_size" ]] \
      || fail "part_size_conflict"
  else
    [[ ! -e "$part_next" ]] || fail "part_temporary_conflict"
    temporary_paths+=("$part_next")
    part_output="$part_next"
  fi

  expected_part_sha256="$(python3 - \
    "$artifact_target" "$part_offset" "$part_size" "$part_output" <<'PY'
import hashlib
import os
import sys

source_path, offset_raw, size_raw, output_path = sys.argv[1:]
offset = int(offset_raw)
remaining = int(size_raw)
digest = hashlib.sha256()
output = None
try:
    if output_path != "-":
        output = open(output_path, "xb")
    with open(source_path, "rb") as source:
        source.seek(offset)
        while remaining:
            block = source.read(min(8 * 1024 * 1024, remaining))
            if not block:
                raise SystemExit(1)
            digest.update(block)
            if output is not None:
                output.write(block)
            remaining -= len(block)
    if output is not None:
        output.flush()
        os.fsync(output.fileno())
finally:
    if output is not None:
        output.close()
print(digest.hexdigest())
PY
  )" || fail "part_generation_failed"
  [[ "$expected_part_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "part_generation_failed"

  if [[ "$part_output" != "-" ]]; then
    [[ "$(stat -c '%s' -- "$part_next")" == "$part_size" ]] \
      || fail "part_copy_size_mismatch"
    [[ "$(sha256sum -- "$part_next" | awk '{print $1}')" == "$expected_part_sha256" ]] \
      || fail "part_copy_checksum_mismatch"
    if [[ $EUID -eq 0 ]]; then
      chown root:root -- "$part_next"
    fi
    chmod 0644 -- "$part_next"
    mv -Tf -- "$part_next" "$part_target"
  else
    [[ "$(sha256sum -- "$part_target" | awk '{print $1}')" == "$expected_part_sha256" ]] \
      || fail "part_checksum_conflict"
  fi

  printf '%s\t%s\t%s\t%s\n' \
    "$part_index" "$part_url" "$part_size" "$expected_part_sha256" \
    >> "$parts_metadata"
  part_offset=$(( part_offset + part_size ))
done
[[ "$part_offset" == "$expected_bytes" ]] || fail "part_size_mismatch"

generated_manifest="$(mktemp /tmp/.novel-modao-manifest-final.XXXXXX)"
temporary_paths+=("$generated_manifest")
python3 - "$base_manifest_path" "$parts_metadata" "$generated_manifest" "$part_count" <<'PY' \
  || fail "parts_manifest_generation_failed"
import json
import re
import sys

base_path, metadata_path, output_path, count_raw = sys.argv[1:]
count = int(count_raw)
with open(base_path, "r", encoding="utf-8") as source:
    manifest = json.load(source)
parts = []
with open(metadata_path, "r", encoding="utf-8") as source:
    for line in source:
        index_raw, url, size_raw, sha256 = line.rstrip("\n").split("\t")
        index = int(index_raw)
        size = int(size_raw)
        if index != len(parts) or size <= 0 or not re.fullmatch(r"[a-f0-9]{64}", sha256):
            raise SystemExit(1)
        parts.append({
            "index": index,
            "url": url,
            "sizeBytes": size,
            "sha256": sha256,
        })
if len(parts) != count or sum(part["sizeBytes"] for part in parts) != manifest["sizeBytes"]:
    raise SystemExit(1)
manifest["parts"] = parts
with open(output_path, "w", encoding="utf-8") as target:
    json.dump(manifest, target, separators=(",", ":"), ensure_ascii=False)
    target.write("\n")
PY
manifest_path="$generated_manifest"

history_manifest="$release_dir/manifest-${version_name}+${version_code}.json"
if [[ -e "$history_manifest" ]]; then
  [[ -f "$history_manifest" && ! -L "$history_manifest" ]] || fail "history_manifest_invalid"
  if ! cmp -s -- "$manifest_path" "$history_manifest"; then
    # A release published before multipart support may gain the generated
    # parts array, but no pre-existing release metadata may change.
    python3 - "$history_manifest" "$manifest_path" <<'PY' \
      || fail "history_manifest_conflict"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    current = json.load(source)
with open(sys.argv[2], "r", encoding="utf-8") as source:
    candidate = json.load(source)
current.pop("parts", None)
candidate.pop("parts", None)
if current != candidate:
    raise SystemExit(1)
PY
    install_atomic "$manifest_path" "$history_manifest"
  fi
else
  install_atomic "$manifest_path" "$history_manifest"
fi

# Switch the small manifest last. A client can never observe a manifest before
# the immutable APK it references is fully present and checksum-verified.
if [[ "$release_dir" == "$production_dir" ]]; then
  command -v chattr >/dev/null 2>&1 || fail "manifest_protection_unavailable"
  command -v lsattr >/dev/null 2>&1 || fail "manifest_protection_unavailable"
  if [[ -e "$current_manifest" ]]; then
    current_attributes="$(lsattr -d -- "$current_manifest" 2>/dev/null | awk '{print $1}')" \
      || fail "manifest_protection_check_failed"
    if [[ "$current_attributes" == *i* ]]; then
      chattr -i -- "$current_manifest" || fail "manifest_unprotect_failed"
      manifest_needs_reprotect=true
    fi
  fi
  manifest_needs_reprotect=true
  install_atomic "$manifest_path" "$current_manifest"
  chattr +i -- "$current_manifest" || fail "manifest_protect_failed"
  manifest_needs_reprotect=false
else
  install_atomic "$manifest_path" "$current_manifest"
fi

printf '{"ok":true,"data":{"versionName":"%s","versionCode":%s,"apk":"%s","sha256":"%s","signingCertificateSha256":"%s","bytes":%s,"parts":%s,"path":"/games/modao"}}\n' \
  "$version_name" "$version_code" "$apk_name" "$expected_sha256" \
  "$signing_certificate_sha256" "$expected_bytes" "$part_count"
