#!/usr/bin/env bash
# Install the exact Android SDK zipalign binary required by KDJX publishing.
set -euo pipefail

version="33.0.3"
archive_name="build-tools_r33.0.3-linux.zip"
archive_url="https://dl.google.com/android/repository/${archive_name}"
archive_size="56003317"
archive_sha1="83d08ea1cdad9733cae08e33c84758835987a508"
tool_root="/opt/android-build-tools/${version}"
wrapper="/usr/local/bin/zipalign"
temporary_archive=""
temporary_root=""
wrapper_candidate=""
created_tool_root=false
created_wrapper=false
installed=false

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

verify_zipalign() {
  local output
  output="$("$1" 2>&1 || true)"
  grep -Fq 'Zip alignment utility' <<<"$output" \
    && grep -Fq 'Usage: zipalign' <<<"$output"
}

cleanup() {
  [[ -n "$temporary_archive" ]] && rm -f -- "$temporary_archive"
  [[ -n "$temporary_root" ]] && rm -rf -- "$temporary_root"
  [[ -n "$wrapper_candidate" ]] && rm -f -- "$wrapper_candidate"
  if [[ "$installed" != true ]]; then
    [[ "$created_tool_root" == true ]] && rm -rf -- "$tool_root"
    [[ "$created_wrapper" == true ]] && rm -f -- "$wrapper"
  fi
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "root_required"
command -v curl >/dev/null 2>&1 || fail "curl_missing"
command -v unzip >/dev/null 2>&1 || fail "unzip_missing"
command -v sha1sum >/dev/null 2>&1 || fail "sha1sum_missing"
[[ "$tool_root" == "/opt/android-build-tools/${version}" ]] || fail "tool_root_invalid"
[[ "$wrapper" == "/usr/local/bin/zipalign" ]] || fail "wrapper_path_invalid"

if [[ -x "$tool_root/zipalign" && -f "$tool_root/lib64/libc++.so" && -f "$wrapper" ]]; then
  verify_zipalign "$wrapper" || fail "existing_zipalign_unusable"
  printf 'zipalign_install=already_present version=%s path=%s\n' "$version" "$tool_root/zipalign"
  installed=true
  exit 0
fi

[[ ! -e "$tool_root" && ! -e "$wrapper" ]] || fail "existing_incomplete_zipalign_install"
temporary_archive="$(mktemp /tmp/kdjx-android-build-tools.XXXXXXXX.zip)"
temporary_root="$(mktemp -d /opt/.kdjx-android-build-tools.XXXXXXXX)"

curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
  --output "$temporary_archive" "$archive_url"
[[ "$(stat -c '%s' "$temporary_archive")" == "$archive_size" ]] \
  || fail "archive_size_mismatch"
[[ "$(sha1sum "$temporary_archive" | awk '{print $1}')" == "$archive_sha1" ]] \
  || fail "archive_checksum_mismatch"

unzip -q "$temporary_archive" -d "$temporary_root"
source_root="$temporary_root/android-13"
[[ -x "$source_root/zipalign" && -f "$source_root/lib64/libc++.so" ]] \
  || fail "zipalign_binary_missing"

install -d -m 0755 "$tool_root/lib64"
created_tool_root=true
install -m 0755 "$source_root/zipalign" "$tool_root/zipalign"
install -m 0644 "$source_root/lib64/libc++.so" "$tool_root/lib64/libc++.so"

wrapper_candidate="${wrapper}.next.$$"
cat > "$wrapper_candidate" <<EOF
#!/usr/bin/env sh
tool_root='${tool_root}'
if [ -n "\${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="\$tool_root/lib64:\$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="\$tool_root/lib64"
fi
exec "\$tool_root/zipalign" "\$@"
EOF
chmod 0755 "$wrapper_candidate"
verify_zipalign "$wrapper_candidate" || fail "zipalign_candidate_unusable"
mv -Tf -- "$wrapper_candidate" "$wrapper"
wrapper_candidate=""
created_wrapper=true
verify_zipalign "$wrapper" || fail "zipalign_wrapper_unusable"
installed=true
printf 'zipalign_install=ok version=%s path=%s\n' "$version" "$tool_root/zipalign"
