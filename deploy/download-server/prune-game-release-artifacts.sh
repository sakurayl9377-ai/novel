#!/usr/bin/env bash
set -euo pipefail

game="${1:-}"
mode="${2:---dry-run}"
confirmed_sha256="${3:-}"
confirmed_plan_id="${4:-}"
test_mode="${NOVEL_GAME_PRUNE_TEST_MODE:-0}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit 1
}

case "$game" in
  modao)
    production_dir="/var/www/novel-download/games/modao"
    package_name="com.you91.fish.lucky"
    lock_file="${MODAO_GAME_RELEASE_LOCK_FILE:-/run/lock/novel-modao-game-release.lock}"
    ;;
  kdjx)
    production_dir="/var/www/novel-download/games/kdjx"
    package_name="com.kd.kdjxcs"
    lock_file="${KDJX_GAME_RELEASE_LOCK_FILE:-/run/lock/novel-kdjx-game-release.lock}"
    ;;
  *)
    fail "game_invalid"
    ;;
esac

download_base_urls_csv="https://novel.kxhub.xyz/games/${game}"
if [[ "$game" == "kdjx" ]]; then
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
  # shellcheck source=kdjx-download-url-policy.sh
  source "$policy_helper"
  kdjx_load_download_base_urls || fail "download_url_policy_invalid"
  download_base_urls_csv="$(IFS=,; printf '%s' "${KDJX_DOWNLOAD_BASE_URLS_ARRAY[*]}")"
fi

release_dir="${NOVEL_GAME_PRUNE_RELEASE_DIR:-$production_dir}"
[[ "$mode" == "--dry-run" || "$mode" == "--apply" ]] || fail "mode_invalid"
if [[ "$release_dir" != "$production_dir" ]]; then
  [[ "$test_mode" == "1" && "$release_dir" == "/tmp/novel-game-prune-test-${game}-"* ]] \
    || fail "release_directory_invalid"
fi
[[ -d "$release_dir" && ! -L "$release_dir" ]] || fail "release_directory_invalid"
release_dir="$(realpath -e -- "$release_dir")"
if [[ "$test_mode" != "1" ]]; then
  [[ "$release_dir" == "$production_dir" ]] || fail "release_directory_invalid"
fi
if [[ "$mode" == "--apply" ]]; then
  if [[ "$release_dir" == "$production_dir" ]]; then
    [[ $EUID -eq 0 ]] || fail "root_required"
  fi
  [[ "$confirmed_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "confirmation_sha256_invalid"
  [[ "$confirmed_plan_id" =~ ^[a-f0-9]{64}$ ]] || fail "confirmation_plan_id_invalid"
else
  [[ -z "$confirmed_sha256" && -z "$confirmed_plan_id" ]] \
    || fail "dry_run_arguments_invalid"
fi

lock_parent="$(dirname -- "$lock_file")"
[[ -d "$lock_parent" && ! -L "$lock_parent" ]] || fail "lock_directory_invalid"
exec 9>"$lock_file"
flock -n 9 || fail "release_in_progress"

python3 - \
  "$game" \
  "$package_name" \
  "$release_dir" \
  "$mode" \
  "$confirmed_sha256" \
  "$confirmed_plan_id" \
  "$download_base_urls_csv" <<'PY' || fail "prune_validation_failed"
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from datetime import datetime, timezone
from urllib.parse import urlsplit

game, package_name, root_raw, mode, confirmed_sha256, confirmed_plan_id, download_base_urls_raw = sys.argv[1:]
root = pathlib.Path(root_raw)
manifest_path = root / "manifest.json"
if not manifest_path.is_file() or manifest_path.is_symlink():
    raise SystemExit(1)
try:
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes.decode("utf-8"))
except Exception:
    raise SystemExit(1)
manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
version_name = manifest.get("versionName")
version_code = manifest.get("versionCode")
apk_sha256 = manifest.get("sha256")
apk_url = manifest.get("apkUrl")
size_bytes = manifest.get("sizeBytes")
if (
    manifest.get("packageName") != package_name
    or not isinstance(version_name, str)
    or not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", version_name)
    or not isinstance(version_code, int)
    or isinstance(version_code, bool)
    or not (0 < version_code <= 2100000000)
    or not isinstance(apk_sha256, str)
    or not re.fullmatch(r"[a-f0-9]{64}", apk_sha256)
    or not isinstance(size_bytes, int)
    or isinstance(size_bytes, bool)
    or size_bytes <= 0
):
    raise SystemExit(1)

download_base_urls = download_base_urls_raw.split(",")


def validated_name(url, expected_name):
    if not isinstance(url, str):
        raise SystemExit(1)
    parsed = urlsplit(url)
    expected_urls = [f"{base_url}/{expected_name}" for base_url in download_base_urls]
    if url not in expected_urls or (
        parsed.scheme != "https"
        or parsed.port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise SystemExit(1)
    return expected_name


apk_name = f"{game}-{version_code}-{apk_sha256[:12]}.apk"
history_name = f"manifest-{version_name}+{version_code}.json"
if game == "kdjx":
    expected_apk_urls = [f"{base_url}/{apk_name}" for base_url in download_base_urls]
    if apk_url != expected_apk_urls[0] or manifest.get("apkUrls") != expected_apk_urls:
        raise SystemExit(1)
keep_names = {
    "manifest.json",
    history_name,
    validated_name(apk_url, apk_name),
}


def verify_current_file(name, expected_size, expected_sha256):
    path = root / name
    current = path.lstat()
    if not stat.S_ISREG(current.st_mode) or current.st_size != expected_size:
        raise SystemExit(1)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            block = source.read(8 * 1024 * 1024)
            if not block:
                break
            digest.update(block)
    if digest.hexdigest() != expected_sha256:
        raise SystemExit(1)


verify_current_file(apk_name, size_bytes, apk_sha256)
parts = manifest.get("parts")
if parts is not None:
    if not isinstance(parts, list) or len(parts) != 5:
        raise SystemExit(1)
    parts_total = 0
    for expected_index, part in enumerate(parts):
        expected_name = f"{apk_name[:-4]}.part-{expected_index:03d}.apk"
        if (
            not isinstance(part, dict)
            or part.get("index") != expected_index
            or not isinstance(part.get("sizeBytes"), int)
            or isinstance(part.get("sizeBytes"), bool)
            or part["sizeBytes"] <= 0
            or not isinstance(part.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", part["sha256"])
        ):
            raise SystemExit(1)
        keep_names.add(validated_name(part.get("url"), expected_name))
        verify_current_file(expected_name, part["sizeBytes"], part["sha256"])
        parts_total += part["sizeBytes"]
    if parts_total != size_bytes:
        raise SystemExit(1)

history_path = root / history_name
if not history_path.is_file() or history_path.is_symlink():
    raise SystemExit(1)
try:
    history = json.loads(history_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if (
    history.get("versionName") != version_name
    or history.get("versionCode") != version_code
    or history.get("sha256") != apk_sha256
):
    raise SystemExit(1)

artifact_pattern = re.compile(
    rf"{re.escape(game)}-\d+-[a-f0-9]{{12}}(?:\.part-00[0-4])?\.apk"
)
history_pattern = re.compile(
    r"manifest-\d+\.\d+\.\d+(?:\.\d+)?\+\d+\.json"
)
candidates = []
with os.scandir(root) as entries:
    for entry in entries:
        if entry.name in keep_names:
            continue
        if not (artifact_pattern.fullmatch(entry.name) or history_pattern.fullmatch(entry.name)):
            continue
        entry_stat = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(entry_stat.st_mode):
            raise SystemExit(1)
        candidates.append({
            "name": entry.name,
            "path": str(root / entry.name),
            "sizeBytes": entry_stat.st_size,
            "mtimeNs": entry_stat.st_mtime_ns,
            "mtimeUtc": datetime.fromtimestamp(
                entry_stat.st_mtime, timezone.utc
            ).isoformat(),
        })
candidates.sort(key=lambda item: item["name"])
plan_basis = {
    "game": game,
    "releaseDirectory": str(root),
    "currentSha256": apk_sha256,
    "manifestSha256": manifest_sha256,
    "candidates": [
        {
            "name": item["name"],
            "sizeBytes": item["sizeBytes"],
            "mtimeNs": item["mtimeNs"],
        }
        for item in candidates
    ],
}
plan_id = hashlib.sha256(
    json.dumps(plan_basis, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
result = {
    "ok": True,
    "mode": "apply" if mode == "--apply" else "dry-run",
    "game": game,
    "releaseDirectory": str(root),
    "currentVersionName": version_name,
    "currentVersionCode": version_code,
    "currentSha256": apk_sha256,
    "manifestSha256": manifest_sha256,
    "planId": plan_id,
    "candidateCount": len(candidates),
    "candidateBytes": sum(item["sizeBytes"] for item in candidates),
    "candidates": candidates,
}
if mode == "--apply":
    if confirmed_sha256 != apk_sha256:
        raise SystemExit(1)
    if confirmed_plan_id != plan_id:
        raise SystemExit(1)
    if os.stat in os.supports_dir_fd and os.unlink in os.supports_dir_fd:
        directory_fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            for item in candidates:
                current = os.stat(item["name"], dir_fd=directory_fd, follow_symlinks=False)
                if (
                    not stat.S_ISREG(current.st_mode)
                    or current.st_size != item["sizeBytes"]
                    or current.st_mtime_ns != item["mtimeNs"]
                ):
                    raise SystemExit(1)
            for item in candidates:
                os.unlink(item["name"], dir_fd=directory_fd)
        finally:
            os.close(directory_fd)
    else:
        # The fallback exists for the repository's Windows test runner. Linux
        # production uses the directory-fd branch above to close rename races.
        for item in candidates:
            path = root / item["name"]
            current = path.lstat()
            if (
                path.parent != root
                or not stat.S_ISREG(current.st_mode)
                or current.st_size != item["sizeBytes"]
                or current.st_mtime_ns != item["mtimeNs"]
            ):
                raise SystemExit(1)
        for item in candidates:
            (root / item["name"]).unlink()
    result["removedCount"] = len(candidates)
    result["removedBytes"] = sum(item["sizeBytes"] for item in candidates)
print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
PY
