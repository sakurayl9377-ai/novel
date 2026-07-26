#!/usr/bin/env bash
set -euo pipefail

staging_dir="${1:-}"
release_dir="${KDJX_HOT_UPDATE_DIR:-/var/www/novel-download/games/kdjx/hot}"
lock_file="${KDJX_HOT_UPDATE_LOCK_FILE:-/run/lock/novel-kdjx-hot-update.lock}"
production_dir="/var/www/novel-download/games/kdjx/hot"
permission_test_bypass="${KDJX_HOT_UPDATE_TEST_PERMISSION_BYPASS:-0}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit 1
}

policy_helper="${KDJX_DOWNLOAD_URL_POLICY_HELPER:-}"
if [[ -z "$policy_helper" ]]; then
  for candidate in \
    "$script_dir/kdjx-download-url-policy.sh" \
    "$script_dir/novel-kdjx-download-url-policy"; do
    if [[ -f "$candidate" && ! -L "$candidate" ]]; then
      policy_helper="$candidate"
      break
    fi
  done
fi
[[ -n "$policy_helper" && -f "$policy_helper" && ! -L "$policy_helper" ]] \
  || fail "download_url_policy_missing"
endpoint_audit_helper="${KDJX_ENDPOINT_AUDIT_HELPER:-}"
if [[ -z "$endpoint_audit_helper" ]]; then
  for candidate in \
    "$script_dir/audit-kdjx-release-endpoints.py" \
    "$script_dir/novel-kdjx-release-endpoint-audit"; do
    if [[ -f "$candidate" && ! -L "$candidate" ]]; then
      endpoint_audit_helper="$candidate"
      break
    fi
  done
fi
[[ -n "$endpoint_audit_helper" && -f "$endpoint_audit_helper" && ! -L "$endpoint_audit_helper" ]] \
  || fail "endpoint_audit_missing"
# shellcheck source=kdjx-download-url-policy.sh
source "$policy_helper"
kdjx_load_download_base_urls || fail "download_url_policy_invalid"
hot_base_url="${KDJX_DOWNLOAD_BASE_URLS_ARRAY[0]}/hot/"

if [[ "$release_dir" == "$production_dir" && $EUID -ne 0 ]]; then
  fail "root_required"
fi
[[ -n "$staging_dir" ]] || fail "staging_path_missing"
[[ "$staging_dir" =~ ^/tmp/novel-kdjx-hot-update-[0-9]+-[A-Za-z0-9]+$ ]] \
  || fail "staging_path_invalid"
staging_dir="$(realpath -e -- "$staging_dir")"
[[ "$staging_dir" == /tmp/novel-kdjx-hot-update-* && ! -L "$staging_dir" ]] \
  || fail "staging_path_invalid"
expected_uid="$EUID"
expected_gid="$(id -g)"
if [[ "$permission_test_bypass" == "1" ]]; then
  [[ $EUID -ne 0 && "$release_dir" == /tmp/novel-kdjx-hot-update-target-* ]] \
    || fail "permission_test_bypass_invalid"
else
  [[ "$(stat -c '%u' -- "$staging_dir")" == "$expected_uid" \
    && "$(stat -c '%g' -- "$staging_dir")" == "$expected_gid" \
    && "$(stat -c '%a' -- "$staging_dir")" == "700" ]] \
    || fail "staging_permissions_invalid"
  while IFS= read -r -d '' entry; do
    [[ ! -L "$entry" \
      && "$(stat -c '%u' -- "$entry")" == "$expected_uid" \
      && "$(stat -c '%g' -- "$entry")" == "$expected_gid" ]] \
      || fail "staging_permissions_invalid"
    if [[ -d "$entry" ]]; then
      [[ "$(stat -c '%a' -- "$entry")" == "700" ]] \
        || fail "staging_permissions_invalid"
    elif [[ -f "$entry" ]]; then
      [[ "$(stat -c '%a' -- "$entry")" == "600" ]] \
        || fail "staging_permissions_invalid"
    else
      fail "staging_entry_invalid"
    fi
  done < <(find "$staging_dir" -mindepth 1 -print0)
fi

python3 "$endpoint_audit_helper" --hot-staging "$staging_dir" \
  || fail "endpoint_policy_violation"

lock_parent="$(dirname -- "$lock_file")"
[[ -d "$lock_parent" && ! -L "$lock_parent" ]] || fail "lock_directory_invalid"
exec 9>"$lock_file"
flock -n 9 || fail "release_in_progress"

release_parent="$(dirname -- "$release_dir")"
[[ -d "$release_parent" && ! -L "$release_parent" ]] \
  || fail "release_parent_invalid"
[[ ! -L "$release_dir" ]] || fail "release_path_invalid"

if ! validation_output="$(python3 - "$staging_dir" "$release_dir" "$hot_base_url" 2>/dev/null <<'PY'
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import sys
import tempfile

staging = pathlib.Path(sys.argv[1]).resolve(strict=True)
release_root = pathlib.Path(sys.argv[2])
base_url = sys.argv[3]
maximum_total_bytes = 512 * 1024 * 1024
maximum_asset_count = 20000
path_pattern = re.compile(r"[A-Za-z0-9._@()/-]+")


def fail(code):
    raise RuntimeError(code)


def read_json(path):
    if not path.is_file() or path.is_symlink():
        fail("manifest_missing")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        fail("manifest_invalid")


def file_md5(path):
    digest = hashlib.md5()
    size = 0
    with path.open("rb") as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return size, digest.hexdigest()


version_path = staging / "version.manifest"
project_path = staging / "project.manifest"
metadata_path = staging / "release-metadata.json"
legacy_metadata_path = staging / "legacy-patch.json"
version_manifest = read_json(version_path)
project_manifest = read_json(project_path)
metadata = read_json(metadata_path)
legacy_metadata = read_json(legacy_metadata_path)
version = project_manifest.get("version")
if (
    not isinstance(version, str)
    or not re.fullmatch(r"\d{1,9}", version)
    or version_manifest.get("version") != version
):
    fail("version_invalid")
expected_urls = {
    "packageUrl": f"{base_url}releases/{version}/",
    "remoteVersionUrl": f"{base_url}version.manifest",
    "remoteManifestUrl": f"{base_url}project.manifest",
}
for key, expected in expected_urls.items():
    if project_manifest.get(key) != expected or version_manifest.get(key) != expected:
        fail("manifest_url_invalid")
if "assets" in version_manifest:
    fail("version_manifest_assets_forbidden")
if project_manifest.get("searchPaths") != []:
    fail("search_paths_invalid")
assets = project_manifest.get("assets")
if not isinstance(assets, dict) or not (1 <= len(assets) <= maximum_asset_count):
    fail("assets_invalid")
release_source = staging / "releases" / version
if not release_source.is_dir() or release_source.is_symlink():
    fail("release_source_invalid")
release_source_resolved = release_source.resolve(strict=True)
validated = []
total_bytes = 0
for relative, metadata_value in assets.items():
    if (
        not isinstance(relative, str)
        or not path_pattern.fullmatch(relative)
        or relative.startswith("/")
        or "\\" in relative
        or any(part in ("", ".", "..") for part in relative.split("/"))
        or not isinstance(metadata_value, dict)
    ):
        fail("asset_path_invalid")
    expected_size = metadata_value.get("size")
    expected_md5 = metadata_value.get("md5")
    if (
        not isinstance(expected_size, int)
        or isinstance(expected_size, bool)
        or not (0 < expected_size <= maximum_total_bytes)
        or not isinstance(expected_md5, str)
        or not re.fullmatch(r"[a-f0-9]{32}", expected_md5)
        or metadata_value.get("compressed") is not False
    ):
        fail("asset_metadata_invalid")
    source = release_source.joinpath(*relative.split("/"))
    if not source.is_file() or source.is_symlink():
        fail("asset_missing")
    try:
        source.resolve(strict=True).relative_to(release_source_resolved)
    except ValueError:
        fail("asset_path_invalid")
    actual_size, actual_md5 = file_md5(source)
    if actual_size != expected_size or actual_md5 != expected_md5:
        fail("asset_digest_mismatch")
    total_bytes += actual_size
    if total_bytes > maximum_total_bytes:
        fail("release_too_large")
    validated.append((relative, source))
if (
    metadata.get("version") != version
    or metadata.get("assetCount") != len(validated)
    or metadata.get("totalBytes") != total_bytes
):
    fail("release_metadata_invalid")

legacy_files = legacy_metadata.get("files")
if (
    not isinstance(legacy_files, list)
    or not (1 <= len(legacy_files) <= maximum_asset_count)
    or legacy_metadata.get("svn_version") != version
    or not isinstance(legacy_metadata.get("git_version"), str)
    or not re.fullmatch(r"[a-f0-9]{40}", legacy_metadata["git_version"])
):
    fail("legacy_patch_metadata_invalid")
legacy_patch = None
for entry in legacy_files:
    if not isinstance(entry, dict):
        fail("legacy_patch_entry_invalid")
    entry_patch = entry.get("patch")
    if isinstance(entry_patch, bool) or not isinstance(entry_patch, int):
        fail("legacy_patch_version_invalid")
    if legacy_patch is None:
        legacy_patch = entry_patch
    elif legacy_patch != entry_patch:
        fail("legacy_patch_version_invalid")
if not (1 <= legacy_patch <= 999999999):
    fail("legacy_patch_version_invalid")
if legacy_patch == 9 and (version != "39" or len(legacy_files) != 2559):
    fail("first_sakura_patch_contract_invalid")
legacy_source = staging / str(legacy_patch)
if not legacy_source.is_dir() or legacy_source.is_symlink():
    fail("legacy_patch_source_invalid")
legacy_source_resolved = legacy_source.resolve(strict=True)
legacy_validated = []
legacy_names = set()
legacy_total_bytes = 0
legacy_previous_name = ""
legacy_revision = hashlib.sha1()
for entry in legacy_files:
    if not isinstance(entry, dict):
        fail("legacy_patch_entry_invalid")
    relative = entry.get("name")
    expected_size = entry.get("size")
    expected_md5 = entry.get("md5")
    if (
        not isinstance(relative, str)
        or not path_pattern.fullmatch(relative)
        or relative.startswith("/")
        or "\\" in relative
        or any(part in ("", ".", "..") for part in relative.split("/"))
        or relative in legacy_names
    ):
        fail("legacy_patch_path_invalid")
    if legacy_previous_name and relative <= legacy_previous_name:
        fail("legacy_patch_order_invalid")
    legacy_previous_name = relative
    if (
        not isinstance(expected_size, int)
        or isinstance(expected_size, bool)
        or not (0 < expected_size <= maximum_total_bytes)
        or not isinstance(expected_md5, str)
        or not re.fullmatch(r"[a-f0-9]{32}", expected_md5)
        or entry.get("patch") != legacy_patch
    ):
        fail("legacy_patch_entry_invalid")
    source = legacy_source.joinpath(*relative.split("/"))
    if not source.is_file() or source.is_symlink():
        fail("legacy_patch_asset_missing")
    try:
        source.resolve(strict=True).relative_to(legacy_source_resolved)
    except ValueError:
        fail("legacy_patch_path_invalid")
    actual_size, actual_md5 = file_md5(source)
    if actual_size != expected_size or actual_md5 != expected_md5:
        fail("legacy_patch_digest_mismatch")
    legacy_names.add(relative)
    legacy_validated.append((relative, source))
    legacy_revision.update(
        f"{relative}\0{actual_size}\0{actual_md5}\n".encode("utf-8")
    )
    legacy_total_bytes += actual_size
    if legacy_total_bytes > maximum_total_bytes:
        fail("legacy_patch_too_large")
if legacy_metadata["git_version"] != legacy_revision.hexdigest():
    fail("legacy_patch_revision_mismatch")
actual_legacy_names = {
    path.relative_to(legacy_source).as_posix()
    for path in legacy_source.rglob("*")
    if path.is_file() and not path.is_symlink()
}
if actual_legacy_names != legacy_names:
    fail("legacy_patch_file_set_mismatch")
if legacy_patch == 9:
    required_sakura_assets = {
        "res/version.plist",
        "src/app.defines.app_defines",
        "src/app.game_app",
        "src/app.sdk.helper",
        "src/app.sdk.init",
        "src/app.sdk.none",
        "src/app.views.login.view",
        "x64/src/app.defines.app_defines",
        "x64/src/app.game_app",
        "x64/src/app.sdk.helper",
        "x64/src/app.sdk.init",
        "x64/src/app.sdk.none",
        "x64/src/app.views.login.view",
    }
    if not required_sakura_assets.issubset(legacy_names):
        fail("first_sakura_asset_set_invalid")
if legacy_names != set(assets):
    fail("legacy_patch_compatibility_set_mismatch")
for relative, source in legacy_validated:
    compatibility = release_source.joinpath(*relative.split("/"))
    if file_md5(source) != file_md5(compatibility):
        fail("legacy_patch_compatibility_digest_mismatch")
if "res/version.plist" not in legacy_names:
    fail("legacy_patch_version_plist_missing")
try:
    plist_patch = str(
        plistlib.loads((legacy_source / "res" / "version.plist").read_bytes())["patch"]
    )
except Exception:
    fail("legacy_patch_version_plist_invalid")
if plist_patch != str(legacy_patch):
    fail("legacy_patch_version_plist_mismatch")

release_root.mkdir(mode=0o755, parents=False, exist_ok=True)
if release_root.is_symlink():
    fail("release_path_invalid")
releases_root = release_root / "releases"
releases_root.mkdir(mode=0o755, exist_ok=True)
history_root = release_root / "history"
history_root.mkdir(mode=0o755, exist_ok=True)
final_release = releases_root / version
final_legacy = release_root / str(legacy_patch)
existing_legacy_patches = []
for child in release_root.iterdir():
    if child.name.isdigit():
        if not child.is_dir() or child.is_symlink():
            fail("current_legacy_patch_invalid")
        existing_legacy_patches.append(int(child.name))
if existing_legacy_patches and max(existing_legacy_patches) > legacy_patch:
    fail("legacy_patch_version_regression")
if final_legacy.exists():
    if not final_legacy.is_dir() or final_legacy.is_symlink():
        fail("legacy_patch_immutable_conflict")
    final_names = {
        path.relative_to(final_legacy).as_posix()
        for path in final_legacy.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    if final_names != legacy_names:
        fail("legacy_patch_immutable_conflict")
    for relative, source in legacy_validated:
        destination = final_legacy.joinpath(*relative.split("/"))
        if (
            not destination.is_file()
            or destination.is_symlink()
            or file_md5(destination) != file_md5(source)
        ):
            fail("legacy_patch_immutable_conflict")
current_version_path = release_root / "version.manifest"
if current_version_path.exists():
    current = read_json(current_version_path)
    current_version = current.get("version")
    if not isinstance(current_version, str) or not current_version.isdigit():
        fail("current_manifest_invalid")
    if int(current_version) > int(version):
        fail("version_regression")
    if int(current_version) == int(version):
        if (
            current_version_path.read_bytes() != version_path.read_bytes()
            or (release_root / "project.manifest").read_bytes() != project_path.read_bytes()
        ):
            fail("immutable_version_conflict")

temporary_release = None
if not final_release.exists():
    temporary_release = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{version}.next.", dir=releases_root)
    )
    try:
        for relative, source in validated:
            destination = temporary_release.joinpath(*relative.split("/"))
            destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            destination.chmod(0o644)
        temporary_release.chmod(0o755)
        os.rename(temporary_release, final_release)
        temporary_release = None
    finally:
        if temporary_release is not None:
            shutil.rmtree(temporary_release, ignore_errors=True)
else:
    if not final_release.is_dir() or final_release.is_symlink():
        fail("immutable_release_conflict")
    for relative, source in validated:
        destination = final_release.joinpath(*relative.split("/"))
        if (
            not destination.is_file()
            or destination.is_symlink()
            or file_md5(destination) != file_md5(source)
        ):
            fail("immutable_release_conflict")
final_release.chmod(0o755)

temporary_legacy = None
if not final_legacy.exists():
    temporary_legacy = pathlib.Path(
        tempfile.mkdtemp(prefix=f".legacy-{legacy_patch}.next.", dir=release_root)
    )
    try:
        for relative, source in legacy_validated:
            destination = temporary_legacy.joinpath(*relative.split("/"))
            destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            destination.chmod(0o644)
        temporary_legacy.chmod(0o755)
        os.rename(temporary_legacy, final_legacy)
        temporary_legacy = None
    finally:
        if temporary_legacy is not None:
            shutil.rmtree(temporary_legacy, ignore_errors=True)
final_legacy.chmod(0o755)

for name, source in (
    (f"project-{version}.manifest", project_path),
    (f"version-{version}.manifest", version_path),
    (f"legacy-patch-{legacy_patch}.json", legacy_metadata_path),
):
    destination = history_root / name
    if destination.exists() and destination.read_bytes() != source.read_bytes():
        fail("immutable_history_conflict")
    if not destination.exists():
        shutil.copyfile(source, destination)
        destination.chmod(0o644)

for name, source in (
    ("project.manifest", project_path),
    ("version.manifest", version_path),
):
    destination = release_root / name
    temporary = release_root / f".{name}.next.{os.getpid()}"
    shutil.copyfile(source, temporary)
    temporary.chmod(0o644)
    os.replace(temporary, destination)

print(json.dumps({
    "ok": True,
    "version": version,
    "assetCount": len(validated),
    "totalBytes": total_bytes,
    "legacyPatch": legacy_patch,
    "legacyAssetCount": len(legacy_validated),
    "legacyTotalBytes": legacy_total_bytes,
}, separators=(",", ":")))
PY
)"; then
  fail "release_validation_failed"
fi
printf '%s\n' "$validation_output"
