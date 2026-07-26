#!/usr/bin/env bash
set -Eeuo pipefail

runtime_root="${KDJX_RUNTIME_ROOT:-/opt/kdjx/runtime/current}"
image="${KDJX_PYTHON_IMAGE:-kdjx-legacy-python:2.7}"
shard="${1:-}"

case "$shard" in
    1|2) ;;
    *)
        printf 'error: KDJX game shard must be 1 or 2\n' >&2
        exit 2
        ;;
esac

[[ -f "$runtime_root/release/game_server.py" ]] || {
    printf 'error: KDJX Python runtime is incomplete: %s\n' "$runtime_root" >&2
    exit 2
}
[[ -d "$runtime_root/release/logs" && ! -L "$runtime_root/release/logs" ]] || {
    printf 'error: KDJX Python runtime log mount point is missing: %s\n' \
        "$runtime_root/release/logs" >&2
    exit 2
}
command -v docker >/dev/null 2>&1 || { printf 'error: docker is unavailable\n' >&2; exit 2; }
docker image inspect "$image" >/dev/null

state_dir="/var/lib/kdjx/game/$shard"
log_dir="/var/log/kdjx/game-$shard"
install -d -m 0750 "$state_dir" "$log_dir"

exec docker run --rm --name "kdjx-game-$shard" \
    --network host \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=128m \
    --mount "type=bind,source=$runtime_root/release,target=/app,readonly" \
    --mount "type=bind,source=$state_dir,target=/var/lib/kdjx" \
    --mount "type=bind,source=$log_dir,target=/app/logs" \
    -w /app \
    "$image" python2 game_server.py "game.cn.$shard"
