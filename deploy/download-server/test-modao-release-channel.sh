#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/deploy-modao-game-release.sh"
installer="$script_dir/install-modao-release-channel.sh"
approved_signer="c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c"
token="Audit$$${RANDOM}"
staging_dir="/tmp/novel-modao-release-10.0.0.0+2023981000-${token}"
release_dir="/tmp/novel-modao-release-target-${token}"
rejected_dir="/tmp/novel-modao-rejected-target-${token}"
lock_file="/tmp/novel-modao-release-${token}.lock"
mock_root="/tmp/novel-modao-mocks-${token}"
install_root="/tmp/novel-modao-install-${token}"

cleanup() {
  case "$staging_dir:$release_dir:$rejected_dir:$mock_root:$install_root" in
    /tmp/novel-modao-release-*:/tmp/novel-modao-release-target-*:/tmp/novel-modao-rejected-target-*:/tmp/novel-modao-mocks-*:/tmp/novel-modao-install-*)
      rm -rf -- "$staging_dir" "$release_dir" "$rejected_dir" "$mock_root" "$install_root"
      ;;
    *)
      printf 'Unsafe test cleanup paths\n' >&2
      ;;
  esac
  rm -f -- "$lock_file"
}

trap cleanup EXIT

mkdir -p -- "$staging_dir" "$mock_root" "$install_root"
grep -Fq \
  'lock_file="${MODAO_GAME_RELEASE_LOCK_FILE:-/run/lock/novel-modao-game-release.lock}"' \
  "$helper" || {
  printf 'Release helper must use the non-symlink /run/lock default\n' >&2
  exit 1
}

real_nginx_bin="${MODAO_REAL_NGINX_BIN:-$(command -v nginx || true)}"
[[ -n "$real_nginx_bin" && -x "$real_nginx_bin" ]] || {
  printf 'A real nginx binary is required for configuration syntax testing\n' >&2
  exit 1
}
openssl_bin="$(command -v openssl || true)"
[[ -n "$openssl_bin" && -x "$openssl_bin" ]] || {
  printf 'openssl is required for the Nginx TLS fixture\n' >&2
  exit 1
}
nginx_fixture="$install_root/real-nginx"
mkdir -p -- "$nginx_fixture"
"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=novel.kxhub.xyz' \
  -keyout "$nginx_fixture/key.pem" \
  -out "$nginx_fixture/cert.pem" >/dev/null 2>&1
sed \
  -e "s#/etc/letsencrypt/live/novel.kxhub.xyz/fullchain.pem#$nginx_fixture/cert.pem#" \
  -e "s#/etc/letsencrypt/live/novel.kxhub.xyz/privkey.pem#$nginx_fixture/key.pem#" \
  "$script_dir/nginx-https.conf" > "$nginx_fixture/site.conf"
cat > "$nginx_fixture/nginx.conf" <<EOF
worker_processes 1;
pid $nginx_fixture/nginx.pid;
error_log stderr notice;
events { worker_connections 16; }
http { include $nginx_fixture/site.conf; }
EOF
"$real_nginx_bin" -t -p "$nginx_fixture/" \
  -c "$nginx_fixture/nginx.conf" >/dev/null 2>&1

python3 - "$staging_dir" "$approved_signer" <<'PY'
import hashlib
import json
import pathlib
import sys
import zipfile

staging = pathlib.Path(sys.argv[1])
signer = sys.argv[2]
fixture = staging / "fixture.apk"
with zipfile.ZipFile(fixture, "w") as apk:
    apk.writestr("AndroidManifest.xml", b"release channel test manifest")
    apk.writestr("classes.dex", b"release channel test dex")
raw = fixture.read_bytes()
sha256 = hashlib.sha256(raw).hexdigest()
apk_name = f"modao-2023981000-{sha256[:12]}.apk"
fixture.rename(staging / apk_name)
manifest = {
    "packageName": "com.you91.fish.lucky",
    "versionName": "10.0.0.0",
    "versionCode": 2023981000,
    "apkUrl": f"https://novel.kxhub.xyz/games/modao/{apk_name}",
    "sizeBytes": len(raw),
    "sha256": sha256,
    "signingCertificateSha256": signer,
    "notes": ["offline release channel test"],
}
(staging / "manifest.json").write_text(
    json.dumps(manifest, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY

cat > "$mock_root/apksigner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '0.9\n'
  exit 0
fi
[[ "${1:-}" == "verify" && "${2:-}" == "--print-certs" && -f "${3:-}" ]]
printf 'Signer #1 certificate SHA-256 digest: %s\n' "${MOCK_APK_SIGNER_SHA256:?}"
SH
chmod 0755 "$mock_root/apksigner"

MOCK_APK_SIGNER_SHA256="$approved_signer" \
MODAO_APKSIGNER_BIN="$mock_root/apksigner" \
MODAO_GAME_RELEASE_DIR="$release_dir" \
MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
  bash "$helper" "$staging_dir" >/dev/null

# Exercise the in-place migration used by the already-published production
# release: replace both manifests with their legacy no-parts form, then rerun.
cp -- "$staging_dir/manifest.json" "$release_dir/manifest.json"
cp -- "$staging_dir/manifest.json" \
  "$release_dir/manifest-10.0.0.0+2023981000.json"
for part_index in 0 1 2 3 4; do
  printf -v part_label '%03d' "$part_index"
  rm -f -- "$release_dir"/modao-2023981000-*.part-"${part_label}".apk
done
MOCK_APK_SIGNER_SHA256="$approved_signer" \
MODAO_APKSIGNER_BIN="$mock_root/apksigner" \
MODAO_GAME_RELEASE_DIR="$release_dir" \
MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
  bash "$helper" "$staging_dir" >/dev/null

python3 - "$release_dir" <<'PY'
import hashlib
import json
import pathlib
import sys

release = pathlib.Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
apk_name = f"modao-{manifest['versionCode']}-{manifest['sha256'][:12]}.apk"
apk = (release / apk_name).read_bytes()
assert hashlib.sha256(apk).hexdigest() == manifest["sha256"]
parts = manifest["parts"]
assert len(parts) == 5
assert [part["index"] for part in parts] == list(range(5))
assert sum(part["sizeBytes"] for part in parts) == manifest["sizeBytes"]
assert max(part["sizeBytes"] for part in parts) - min(part["sizeBytes"] for part in parts) <= 1
rebuilt = bytearray()
for index, part in enumerate(parts):
    expected_name = f"{apk_name[:-4]}.part-{index:03d}.apk"
    assert part["url"] == f"https://novel.kxhub.xyz/games/modao/{expected_name}"
    payload = (release / expected_name).read_bytes()
    assert len(payload) == part["sizeBytes"]
    assert hashlib.sha256(payload).hexdigest() == part["sha256"]
    rebuilt.extend(payload)
assert bytes(rebuilt) == apk
history = release / f"manifest-{manifest['versionName']}+{manifest['versionCode']}.json"
assert json.loads(history.read_text(encoding="utf-8"))["parts"] == parts
assert not list(release.glob("*.next.*"))
PY

if MOCK_APK_SIGNER_SHA256="$(printf '1%.0s' {1..64})" \
  MODAO_APKSIGNER_BIN="$mock_root/apksigner" \
  MODAO_GAME_RELEASE_DIR="$rejected_dir" \
  MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$helper" "$staging_dir" >"$mock_root/rejected.out"; then
  printf 'Unapproved APK signer was accepted\n' >&2
  exit 1
fi
grep -Fq '"error":"apk_signer_not_approved"' "$mock_root/rejected.out"
[[ ! -e "$rejected_dir/manifest.json" ]]

python3 - "$staging_dir/manifest.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["signingCertificateSha256"] = "1" * 64
path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
if MOCK_APK_SIGNER_SHA256="$approved_signer" \
  MODAO_APKSIGNER_BIN="$mock_root/apksigner" \
  MODAO_GAME_RELEASE_DIR="$rejected_dir" \
  MODAO_GAME_RELEASE_LOCK_FILE="$lock_file" \
    bash "$helper" "$staging_dir" >"$mock_root/manifest-rejected.out"; then
  printf 'Unapproved manifest signer was accepted\n' >&2
  exit 1
fi
grep -Fq '"error":"manifest_invalid"' "$mock_root/manifest-rejected.out"

cat > "$mock_root/nginx" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-t" ]]
if [[ "${MOCK_NGINX_REJECT_MODAO:-0}" == "1" ]] &&
  [[ -f "${MOCK_NGINX_CONFIG:?}" ]] &&
  grep -Fq 'location = /games/modao/manifest.json {' "$MOCK_NGINX_CONFIG"; then
  exit 1
fi
SH
chmod 0755 "$mock_root/nginx"
mkdir -p \
  "$install_root/sbin" \
  "$install_root/conf.d" \
  "$install_root/releases"
installed_helper="$install_root/sbin/novel-modao-game-release-deploy"
installed_nginx="$install_root/conf.d/novel-download.conf"

installer_env=(
  env
  "MODAO_RELEASE_HELPER_TARGET=$installed_helper"
  "NOVEL_DOWNLOAD_NGINX_TARGET=$installed_nginx"
  "MODAO_GAME_RELEASE_DIR=$install_root/releases/modao"
  "NOVEL_DOWNLOAD_NGINX_BIN=$mock_root/nginx"
  "MODAO_APKSIGNER_BIN=$mock_root/apksigner"
  "NOVEL_DOWNLOAD_SKIP_RELOAD=1"
  "MOCK_APK_SIGNER_SHA256=$approved_signer"
  "MOCK_NGINX_CONFIG=$installed_nginx"
)
if "${installer_env[@]}" bash "$installer" 49.232.137.85 >/dev/null 2>&1; then
  printf 'Installer accepted the backend server address\n' >&2
  exit 1
fi

printf 'previous nginx configuration\n' > "$installed_nginx"
printf '#!/usr/bin/env bash\nexit 0\n' > "$installed_helper"
chmod 0755 "$installed_helper"
nginx_before="$(sha256sum -- "$installed_nginx" | awk '{print $1}')"
helper_before="$(sha256sum -- "$installed_helper" | awk '{print $1}')"
if "${installer_env[@]}" "MOCK_NGINX_REJECT_MODAO=1" \
  bash "$installer" 47.88.26.14 >/dev/null 2>&1; then
  printf 'Installer kept an invalid candidate Nginx configuration\n' >&2
  exit 1
fi
[[ "$(sha256sum -- "$installed_nginx" | awk '{print $1}')" == "$nginx_before" ]]
[[ "$(sha256sum -- "$installed_helper" | awk '{print $1}')" == "$helper_before" ]]

"${installer_env[@]}" bash "$installer" 47.88.26.14 >/dev/null
"${installer_env[@]}" bash "$installer" 47.88.26.14 >/dev/null
[[ -x "$installed_helper" ]]
[[ -f "$installed_nginx" ]]
[[ ! -L "$installed_nginx" ]]
[[ ! -e "$install_root/sites-enabled/novel-download.conf" ]]
[[ -d "$install_root/releases/modao" ]]

printf 'Modao download release channel tests passed.\n'
