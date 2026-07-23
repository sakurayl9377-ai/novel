#!/usr/bin/env bash
set -euo pipefail

staging_dir="${1:-}"
release_dir="${MODAO_HOT_UPDATE_DIR:-/var/www/novel-download/games/modao/hot}"
lock_file="${MODAO_HOT_UPDATE_LOCK_FILE:-/run/lock/novel-modao-hot-update.lock}"
production_dir="/var/www/novel-download/games/modao/hot"

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit 1
}

if [[ "$release_dir" == "$production_dir" && $EUID -ne 0 ]]; then
  fail "root_required"
fi
[[ -n "$staging_dir" ]] || fail "staging_path_missing"
[[ "$staging_dir" =~ ^/tmp/novel-modao-hot-update-[0-9]+-[A-Za-z0-9]+$ ]] \
  || fail "staging_path_invalid"
staging_dir="$(realpath -e -- "$staging_dir")"
[[ "$staging_dir" == /tmp/novel-modao-hot-update-* && ! -L "$staging_dir" ]] \
  || fail "staging_path_invalid"
expected_uid="$EUID"
expected_gid="$(id -g)"
[[ "$(stat -c '%u' -- "$staging_dir")" == "$expected_uid" \
  && "$(stat -c '%g' -- "$staging_dir")" == "$expected_gid" \
  && "$(stat -c '%a' -- "$staging_dir")" == "700" ]] \
  || fail "staging_permissions_invalid"
while IFS= read -r -d '' staging_entry; do
  [[ ! -L "$staging_entry" \
    && "$(stat -c '%u' -- "$staging_entry")" == "$expected_uid" \
    && "$(stat -c '%g' -- "$staging_entry")" == "$expected_gid" ]] \
    || fail "staging_permissions_invalid"
  if [[ -d "$staging_entry" ]]; then
    [[ "$(stat -c '%a' -- "$staging_entry")" == "700" ]] \
      || fail "staging_permissions_invalid"
  elif [[ -f "$staging_entry" ]]; then
    [[ "$(stat -c '%a' -- "$staging_entry")" == "600" ]] \
      || fail "staging_permissions_invalid"
  else
    fail "staging_entry_invalid"
  fi
done < <(find "$staging_dir" -mindepth 1 -print0)

lock_parent="$(dirname -- "$lock_file")"
[[ -d "$lock_parent" && ! -L "$lock_parent" ]] || fail "lock_directory_invalid"
exec 9>"$lock_file"
flock -n 9 || fail "release_in_progress"

release_parent="$(dirname -- "$release_dir")"
[[ -d "$release_parent" && ! -L "$release_parent" ]] \
  || fail "release_parent_invalid"
[[ ! -L "$release_dir" ]] || fail "release_path_invalid"

if ! validation_output="$(python3 - "$staging_dir" "$release_dir" 2>/dev/null <<'PY'
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile

staging = pathlib.Path(sys.argv[1]).resolve(strict=True)
release_root = pathlib.Path(sys.argv[2])
base_url = "https://novel.kxhub.xyz/games/modao/hot/"
maximum_total_bytes = 64 * 1024 * 1024
path_pattern = re.compile(r"[A-Za-z0-9._/-]+")


def fail(code):
    raise RuntimeError(code)


def read_json(path):
    if not path.is_file() or path.is_symlink():
        fail("manifest_missing")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        fail("manifest_invalid")


version_manifest_path = staging / "version.manifest"
project_manifest_path = staging / "project.manifest"
metadata_path = staging / "release-metadata.json"
version_manifest = read_json(version_manifest_path)
project_manifest = read_json(project_manifest_path)
metadata = read_json(metadata_path)

version = project_manifest.get("version")
if (
    not isinstance(version, str)
    or not re.fullmatch(r"\d{1,9}", version)
    or version_manifest.get("version") != version
):
    fail("version_invalid")
expected = {
    "packageUrl": f"{base_url}releases/{version}/",
    "remoteVersionUrl": f"{base_url}version.manifest",
    "remoteManifestUrl": f"{base_url}project.manifest",
}
for key, value in expected.items():
    if project_manifest.get(key) != value or version_manifest.get(key) != value:
        fail("manifest_url_invalid")
if "assets" in version_manifest:
    fail("version_manifest_assets_forbidden")
if project_manifest.get("searchPaths") != []:
    fail("search_paths_invalid")
assets = project_manifest.get("assets")
if not isinstance(assets, dict) or not (1 <= len(assets) <= 100):
    fail("assets_invalid")

release_source = staging / "releases" / version
if not release_source.is_dir() or release_source.is_symlink():
    fail("release_source_invalid")
validated = []
total_bytes = 0
for relative, asset in assets.items():
    if (
        not isinstance(relative, str)
        or not path_pattern.fullmatch(relative)
        or relative.startswith("/")
        or "\\" in relative
        or ".." in relative.split("/")
        or not isinstance(asset, dict)
    ):
        fail("asset_path_invalid")
    size = asset.get("size")
    md5 = asset.get("md5")
    if (
        not isinstance(size, int)
        or isinstance(size, bool)
        or not (0 < size <= maximum_total_bytes)
        or not isinstance(md5, str)
        or not re.fullmatch(r"[a-f0-9]{32}", md5)
        or asset.get("compressed") is not False
    ):
        fail("asset_metadata_invalid")
    source = release_source.joinpath(*relative.split("/"))
    if not source.is_file() or source.is_symlink():
        fail("asset_missing")
    resolved = source.resolve(strict=True)
    try:
        resolved.relative_to(release_source.resolve(strict=True))
    except ValueError:
        fail("asset_path_invalid")
    data = source.read_bytes()
    if len(data) != size or hashlib.md5(data).hexdigest() != md5:
        fail("asset_digest_mismatch")
    total_bytes += size
    if total_bytes > maximum_total_bytes:
        fail("release_too_large")
    validated.append((relative, source))

if (
    metadata.get("version") != version
    or metadata.get("assetCount") != len(validated)
    or metadata.get("totalBytes") != total_bytes
):
    fail("release_metadata_invalid")

release_root.mkdir(mode=0o755, parents=False, exist_ok=True)
if release_root.is_symlink():
    fail("release_path_invalid")
releases_root = release_root / "releases"
releases_root.mkdir(mode=0o755, exist_ok=True)
history_root = release_root / "history"
history_root.mkdir(mode=0o755, exist_ok=True)
final_release = releases_root / version

current_version_path = release_root / "version.manifest"
if current_version_path.exists():
    current = read_json(current_version_path)
    current_version = current.get("version")
    if not isinstance(current_version, str) or not current_version.isdigit():
        fail("current_manifest_invalid")
    if int(current_version) > int(version):
        fail("version_regression")
    if int(current_version) == int(version):
        current_project = (release_root / "project.manifest").read_bytes()
        if (
            current_version_path.read_bytes() != version_manifest_path.read_bytes()
            or current_project != project_manifest_path.read_bytes()
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
            or destination.read_bytes() != source.read_bytes()
        ):
            fail("immutable_release_conflict")
final_release.chmod(0o755)

for name, source in (
    (f"project-{version}.manifest", project_manifest_path),
    (f"version-{version}.manifest", version_manifest_path),
):
    destination = history_root / name
    if destination.exists() and destination.read_bytes() != source.read_bytes():
        fail("immutable_history_conflict")
    if not destination.exists():
        shutil.copyfile(source, destination)
        destination.chmod(0o644)

for name, source in (
    ("project.manifest", project_manifest_path),
    ("version.manifest", version_manifest_path),
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
}, separators=(",", ":")))
PY
)"; then
  fail "release_validation_failed"
fi
printf '%s\n' "$validation_output"
