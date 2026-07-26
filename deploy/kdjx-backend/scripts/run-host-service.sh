#!/usr/bin/env bash
set -Eeuo pipefail

runtime_root="${KDJX_RUNTIME_ROOT:-/opt/kdjx/runtime/current}"
role="${1:-}"

case "$role" in
    accountdb) config="accountdb.cn.1" ;;
    giftdb) config="giftdb.cn.1" ;;
    storage1) config="storage.cn.1" ;;
    storage2) config="storage.cn.2" ;;
    pvp1) config="pvp.cn.1" ;;
    pvp2) config="pvp.cn.2" ;;
    crossdb) config="crossdb.cn.1" ;;
    cross) config="cross.cn.1" ;;
    *)
        printf 'error: unsupported KDJX host role: %s\n' "$role" >&2
        exit 2
        ;;
esac

[[ -x "$runtime_root/bin/host_server" && -f "$runtime_root/host/defines.json" ]] || {
    printf 'error: KDJX host runtime is incomplete: %s\n' "$runtime_root" >&2
    exit 2
}

cd "$runtime_root/host"
exec "$runtime_root/bin/host_server" -config="$config" -language=cn
