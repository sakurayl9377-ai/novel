#!/usr/bin/env bash
set -euo pipefail

staging_dir="${1:-}"
canonical_dir="/var/www/novel-download/app3"
legacy_app3_dir="/var/www/yunpan/app3"
legacy_app_dir="/var/www/yunpan/app"
lock_file="/var/lock/novel-app-release.lock"

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit 1
}

[[ $EUID -eq 0 ]] || fail "root_required"
exec 9>"$lock_file"
flock -n 9 || fail "release_in_progress"
[[ "$staging_dir" =~ ^/tmp/novel-app-release-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+-[A-Za-z0-9]+$ ]] \
  || fail "staging_path_invalid"
staging_dir="$(realpath -e -- "$staging_dir")"
[[ "$staging_dir" == /tmp/novel-app-release-* ]] || fail "staging_path_invalid"
manifest_path="$staging_dir/version.json"
[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || fail "manifest_missing"

mapfile -t manifest_values < <(python3 - "$manifest_path" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    value = json.load(source)
version_name = str(value.get("versionName", "")).strip()
version_code = value.get("versionCode")
apk_url = str(value.get("apkUrl", "")).strip()
sha256 = str(value.get("sha256", "")).strip().lower()
notes = value.get("notes")
force = value.get("force", False)
if not re.fullmatch(r"\d+\.\d+\.\d+", version_name):
    raise SystemExit(1)
if not isinstance(version_code, int) or isinstance(version_code, bool) or version_code <= 0:
    raise SystemExit(1)
if not re.fullmatch(r"[a-f0-9]{64}", sha256):
    raise SystemExit(1)
if not isinstance(force, bool) or not isinstance(notes, list):
    raise SystemExit(1)
if "uploadTokenSha256" in value:
    raise SystemExit(1)
print(version_name)
print(version_code)
print(apk_url)
print(sha256)
PY
) || fail "manifest_invalid"
[[ ${#manifest_values[@]} -eq 4 ]] || fail "manifest_invalid"
version_name="${manifest_values[0]}"
version_code="${manifest_values[1]}"
apk_url="${manifest_values[2]}"
expected_sha256="${manifest_values[3]}"
expected_apk_url="https://novel.kxhub.xyz/app3/app-release-${version_name}+${version_code}.apk"
[[ "$apk_url" == "$expected_apk_url" ]] || fail "apk_url_invalid"

apk_name="app-release-${version_name}+${version_code}.apk"
apk_path="$staging_dir/$apk_name"
[[ -f "$apk_path" && ! -L "$apk_path" ]] || fail "apk_missing"
apk_bytes="$(stat -c '%s' -- "$apk_path")"
(( apk_bytes > 0 && apk_bytes <= 268435456 )) || fail "apk_size_invalid"
actual_sha256="$(sha256sum -- "$apk_path" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail "apk_checksum_mismatch"
python3 - "$apk_path" <<'PY' || fail "apk_archive_invalid"
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "r") as apk:
    names = set(apk.namelist())
    if "AndroidManifest.xml" not in names or "classes.dex" not in names:
        raise SystemExit(1)
    bad = apk.testzip()
    if bad is not None:
        raise SystemExit(1)
PY

[[ -d "$canonical_dir" && ! -L "$canonical_dir" ]] || fail "release_directory_missing"
for target_dir in "$legacy_app3_dir" "$legacy_app_dir"; do
  if [[ -e "$target_dir" || -L "$target_dir" ]]; then
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || fail "release_directory_invalid"
  fi
done

# New download hosts only expose the canonical directory. Keep older mirrors
# synchronized when they exist, without requiring obsolete paths to be created.
manifest_dirs=()
alias_dirs=("$canonical_dir")
if [[ -d "$legacy_app_dir" ]]; then
  manifest_dirs+=("$legacy_app_dir")
fi
if [[ -d "$legacy_app3_dir" ]]; then
  manifest_dirs+=("$legacy_app3_dir")
  alias_dirs+=("$legacy_app3_dir")
fi
manifest_dirs+=("$canonical_dir")

current_version_code=0
current_sha256=""
if [[ -f "$canonical_dir/version.json" ]]; then
  mapfile -t current_values < <(python3 - "$canonical_dir/version.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    value = json.load(source)
print(int(value.get("versionCode", 0) or 0))
print(str(value.get("sha256", "")).strip().lower())
PY
  ) || fail "current_manifest_invalid"
  current_version_code="${current_values[0]:-0}"
  current_sha256="${current_values[1]:-}"
fi
(( version_code >= current_version_code )) || fail "version_rollback_blocked"
if (( version_code == current_version_code )) && [[ "$current_sha256" != "$expected_sha256" ]]; then
  fail "version_immutable_conflict"
fi

versioned_target="$canonical_dir/$apk_name"
if [[ -f "$versioned_target" ]]; then
  [[ ! -L "$versioned_target" ]] || fail "versioned_apk_invalid"
  [[ "$(sha256sum -- "$versioned_target" | awk '{print $1}')" == "$expected_sha256" ]] \
    || fail "versioned_apk_conflict"
else
  versioned_next="${versioned_target}.next.$$"
  install -o root -g root -m 0644 -- "$apk_path" "$versioned_next"
  [[ "$(sha256sum -- "$versioned_next" | awk '{print $1}')" == "$expected_sha256" ]] \
    || fail "versioned_apk_copy_failed"
  mv -Tf -- "$versioned_next" "$versioned_target"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
for target_dir in "${manifest_dirs[@]}"; do
  backup_dir="$target_dir/backup-${timestamp}-pre-${version_name}+${version_code}"
  install -d -m 0755 -o root -g root "$backup_dir"
  [[ ! -f "$target_dir/version.json" ]] \
    || cp -a -- "$target_dir/version.json" "$backup_dir/version.json"
done
for target_dir in "${alias_dirs[@]}"; do
  backup_dir="$target_dir/backup-${timestamp}-pre-${version_name}+${version_code}"
  [[ ! -f "$target_dir/app-release.apk" ]] \
    || cp --reflink=auto -a -- "$target_dir/app-release.apk" "$backup_dir/app-release.apk"
done

install_atomic() {
  local source_path="$1"
  local target_path="$2"
  local next_path="${target_path}.next.$$"
  install -o root -g root -m 0644 -- "$source_path" "$next_path"
  mv -Tf -- "$next_path" "$target_path"
}

for target_dir in "${alias_dirs[@]}"; do
  install_atomic "$apk_path" "$target_dir/app-release.apk"
  [[ "$(sha256sum -- "$target_dir/app-release.apk" | awk '{print $1}')" == "$expected_sha256" ]] \
    || fail "alias_checksum_mismatch"
done

history_name="version-${version_name}+${version_code}.json"
for target_dir in "${manifest_dirs[@]}"; do
  install_atomic "$manifest_path" "$target_dir/$history_name"
done

# Each manifest points to the immutable domain APK. Switch the canonical
# manifest last so new clients only see a release after every legacy entry is ready.
for target_dir in "${manifest_dirs[@]}"; do
  install_atomic "$manifest_path" "$target_dir/version.json"
done

printf '{"ok":true,"data":{"versionName":"%s","versionCode":%s,"sha256":"%s","bytes":%s,"targets":%s}}\n' \
  "$version_name" "$version_code" "$expected_sha256" "$apk_bytes" "${#manifest_dirs[@]}"
