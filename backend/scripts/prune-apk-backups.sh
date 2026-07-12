#!/usr/bin/env bash
set -euo pipefail

keep="${NOVEL_APK_BACKUP_KEEP:-5}"
mode="${1:-apply}"
roots=(
  /var/www/yunpan/app
  /var/www/yunpan/app3
)

[[ $EUID -eq 0 ]] || { echo "prune_error=root_required" >&2; exit 1; }
[[ "$keep" =~ ^[0-9]+$ ]] && (( 10#$keep >= 1 && 10#$keep <= 20 )) || {
  echo "prune_error=keep_invalid" >&2
  exit 1
}
[[ "$mode" == apply || "$mode" == --dry-run ]] || {
  echo "prune_error=mode_invalid" >&2
  exit 1
}

for expected_root in "${roots[@]}"; do
  [[ -d "$expected_root" ]] || {
    echo "prune_error=root_missing path=$expected_root" >&2
    exit 1
  }
  root="$(realpath -e -- "$expected_root")"
  [[ "$root" == "$expected_root" ]] || {
    echo "prune_error=root_unexpected path=$root" >&2
    exit 1
  }

  mapfile -d '' entries < <(
    find "$root" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -name 'backup-*' \
      -printf '%T@\t%p\0' \
      | sort -z -nr
  )

  removed=0
  reclaimed=0
  for (( index=keep; index<${#entries[@]}; index++ )); do
    candidate="${entries[$index]#*$'\t'}"
    resolved="$(realpath -e -- "$candidate")"
    [[ "$(dirname -- "$resolved")" == "$root" && "$(basename -- "$resolved")" == backup-* ]] || {
      echo "prune_error=target_outside_root path=$resolved" >&2
      exit 1
    }
    bytes="$(du -sb -- "$resolved" | awk '{print $1}')"
    if [[ "$mode" == apply ]]; then
      rm -rf --one-file-system -- "$resolved"
    else
      printf 'prune_candidate=%s bytes=%s\n' "$resolved" "$bytes"
    fi
    (( removed += 1 ))
    (( reclaimed += bytes ))
  done

  printf 'prune_root=%s kept=%s removed=%s reclaimed_bytes=%s mode=%s\n' \
    "$root" "$keep" "$removed" "$reclaimed" "$mode"
done
