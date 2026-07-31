#!/usr/bin/env bash
# Build a clean, self-contained legacy KDJX runtime tree. This script never
# modifies its source inputs or an existing release directory.
set -Eeuo pipefail

umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root=""
patch_source=""
anti_cheat_scripts=""
gm_catalog=""
gm_catalog_supplement="$script_dir/../catalogs/kdjx-gm-client-figure-items.json"
output_root=""
go_bin="/opt/kdjx/toolchain/go/bin/go"
candidate_root=""

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  stage-kdjx-runtime.sh \
    --source <pokemon-source-root> \
    --patch-source <release/login/patch-root> \
    --anti-cheat-scripts <release/anti_cheat/game_scripts-root> \
    --gm-catalog <validated-kdjx-gm-item-catalog.json> \
    --output <new-release-directory> \
    [--go </path/to/go>]

The patch root must contain cn/ and the complete production descriptor chain
through patch 17. Both input trees are copied into a temporary candidate,
sanitized, then subjected to a strict owned-endpoint audit. The output path
must not already exist.
EOF
}

cleanup() {
    if [[ -n "$candidate_root" && -d "$candidate_root" ]]; then
        rm -rf -- "$candidate_root"
    fi
}
trap cleanup EXIT

require_value() {
    [[ $# -eq 2 && -n "$2" ]] || fail "missing value for $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            require_value "$1" "${2:-}"
            source_root="$2"
            shift 2
            ;;
        --patch-source)
            require_value "$1" "${2:-}"
            patch_source="$2"
            shift 2
            ;;
        --anti-cheat-scripts)
            require_value "$1" "${2:-}"
            anti_cheat_scripts="$2"
            shift 2
            ;;
        --gm-catalog)
            require_value "$1" "${2:-}"
            gm_catalog="$2"
            shift 2
            ;;
        --output)
            require_value "$1" "${2:-}"
            output_root="$2"
            shift 2
            ;;
        --go)
            require_value "$1" "${2:-}"
            go_bin="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$source_root" && -n "$patch_source" && -n "$anti_cheat_scripts" \
    && -n "$gm_catalog" && -n "$output_root" ]] \
    || { usage >&2; fail "all input paths are required"; }

for required in rsync realpath python3 "$go_bin"; do
    command -v "$required" >/dev/null 2>&1 || fail "required command is unavailable: $required"
done

source_root="$(realpath -e -- "$source_root")"
patch_source="$(realpath -e -- "$patch_source")"
anti_cheat_scripts="$(realpath -e -- "$anti_cheat_scripts")"
[[ -f "$gm_catalog" && ! -L "$gm_catalog" ]] \
    || fail "GM item catalog must be a regular file"
gm_catalog="$(realpath -e -- "$gm_catalog")"
[[ -f "$gm_catalog_supplement" && ! -L "$gm_catalog_supplement" ]] \
    || fail "GM item supplement must be a regular file"
gm_catalog_supplement="$(realpath -e -- "$gm_catalog_supplement")"
[[ -d "$source_root/gosrc/tjgame" && -d "$source_root/release" ]] \
    || fail "source must contain gosrc/tjgame and release"
[[ -d "$patch_source/cn" ]] || fail "patch source must contain cn/"
[[ -d "$anti_cheat_scripts" ]] || fail "anti-cheat scripts must be a directory"
[[ -f "$anti_cheat_scripts/config/items.lua" && ! -L "$anti_cheat_scripts/config/items.lua" ]] \
    || fail "authoritative anti-cheat items.lua is missing or unsafe"
[[ -z "$(find "$patch_source" -type l -print -quit)" ]] || fail "patch source must not contain symlinks"
[[ -z "$(find "$anti_cheat_scripts" -type l -print -quit)" ]] || fail "anti-cheat scripts must not contain symlinks"

go_version="$($go_bin version)"
[[ "$go_version" == *"go1.13."* ]] || fail "KDJX requires Go 1.13; got: $go_version"

# Reject an incomplete source before the expensive runtime build. This catches
# accidentally selecting the original legacy patch directory (which only has
# 8.json) instead of the cumulative production input through patch 17.
python3 "$script_dir/validate-kdjx-login-patches.py" --source "$patch_source"

output_parent="$(dirname -- "$output_root")"
[[ -d "$output_parent" ]] || fail "output parent does not exist: $output_parent"
output_parent="$(realpath -e -- "$output_parent")"
output_name="$(basename -- "$output_root")"
[[ -n "$output_name" && "$output_name" != "." && "$output_name" != ".." ]] || fail "invalid output path"
final_root="$output_parent/$output_name"
[[ ! -e "$final_root" && ! -L "$final_root" ]] || fail "output already exists: $final_root"

candidate_root="$(mktemp -d "$output_parent/.kdjx-runtime-stage.XXXXXXXX")"
[[ "$candidate_root" == "$output_parent"/.kdjx-runtime-stage.* ]] || fail "unsafe staging path"

mkdir -p "$candidate_root/gosrc" "$candidate_root/release" "$candidate_root/bin" \
    "$candidate_root/host" "$candidate_root/online-fight-forward" \
    "$candidate_root/online_fight_forward" "$candidate_root/anti-cheat"
# Docker cannot create /app/logs after /app is mounted read-only. Keep the
# nested bind target in every staged release; the host log bind covers it.
install -d -m 0750 "$candidate_root/release/logs"

# The legacy bundle contains non-production endpoints even in source comments
# and inactive SDK branches. Never let an operator bypass this transformation
# by handing the staging script a prebuilt, unaudited tree.
python3 "$script_dir/sanitize-kdjx-runtime-inputs.py" \
    --patch-source "$patch_source" \
    --anti-cheat-source "$anti_cheat_scripts" \
    --output "$candidate_root/clean-inputs"
clean_patch_source="$candidate_root/clean-inputs/patch"
clean_anti_cheat_scripts="$candidate_root/clean-inputs/anti-cheat-scripts"
python3 "$script_dir/validate-kdjx-login-patches.py" \
    --source "$patch_source" \
    --candidate "$clean_patch_source"

rsync -a --delete \
    --exclude '.git/' \
    --exclude 'bin/' \
    --exclude 'test/' \
    --exclude '*.pyc' \
    --exclude '__pycache__/' \
    "$source_root/gosrc/tjgame/" "$candidate_root/gosrc/tjgame/"

# Only runtime inputs are copied from release/. Legacy binaries, database data,
# admin tools, archive files, and payment listeners never enter the candidate.
for file in game_server.py dev_patch.py disable_words.txt cn_config_csv.py cn.config_csv.msgpack crossdata.json; do
    [[ -f "$source_root/release/$file" && ! -L "$source_root/release/$file" ]] \
        || fail "required release input is missing: $file"
    install -m 0640 "$source_root/release/$file" "$candidate_root/release/$file"
done
rsync -a --delete \
    --exclude '*.pyc' \
    --exclude '__pycache__/' \
    "$source_root/release/src/" "$candidate_root/release/src/"

python3 "$script_dir/apply-sakura-only-login.py" --source-root "$candidate_root"
python3 "$script_dir/apply-runtime-hardening.py" --source-root "$candidate_root"
python3 "$script_dir/apply-runtime-data-compatibility.py" \
    --source-root "$candidate_root"
union_training_test="$script_dir/../tests/union_training_level_fallback_test.go"
[[ -f "$union_training_test" && ! -L "$union_training_test" ]] \
    || fail "union training compatibility test is missing or unsafe"
install -m 0640 "$union_training_test" \
    "$candidate_root/gosrc/tjgame/services/union/training_level_fallback_test.go"
python3 "$script_dir/apply-sakura-economy-compatibility.py" \
    --source-root "$candidate_root"
printf 'sakura-economy-compatibility-v1\n' \
    > "$candidate_root/sakura-economy-compatibility-gate.txt"
chmod 0640 "$candidate_root/sakura-economy-compatibility-gate.txt"
python3 "$script_dir/apply-sakura-payment-rpc.py" \
    --source-root "$candidate_root"
printf 'sakura-payment-rpc-gate-v1\n' \
    > "$candidate_root/sakura-payment-rpc-gate.txt"
chmod 0640 "$candidate_root/sakura-payment-rpc-gate.txt"
python3 "$script_dir/apply-sakura-gm-delivery.py" \
    --source-root "$candidate_root" \
    --patch-root "$script_dir/../patches/sakura-gm"
python3 "$script_dir/generate-runtime-config.py" --runtime-root "$candidate_root"
python3 "$script_dir/validate-kdjx-gm-item-catalog.py" \
    --catalog "$gm_catalog" \
    --items-lua "$anti_cheat_scripts/config/items.lua" \
    --role-figure-lua "$anti_cheat_scripts/config/role_figure.lua" \
    --supplement "$gm_catalog_supplement"
install -m 0640 "$gm_catalog" "$candidate_root/kdjx-gm-item-catalog.json"

rsync -a --delete "$clean_patch_source/cn/" "$candidate_root/login/patch/cn/"
rsync -a --delete "$clean_anti_cheat_scripts/" "$candidate_root/anti-cheat-scripts/"
python3 "$script_dir/validate-kdjx-login-patches.py" \
    --source "$clean_patch_source" \
    --candidate "$candidate_root/login/patch"
# The verified copies above are now in their runtime locations. Do not retain a
# second full Lua tree in the release artifact.
rm -rf -- "$candidate_root/clean-inputs"

# Normalize inherited Go source before it is compiled, including vendor
# documentation and inactive legacy endpoint literals.
python3 "$script_dir/sanitize-kdjx-runtime-inputs.py" --runtime-root "$candidate_root"

# Go host and online-forward read CSV data from their current directory.
# crossdata.json is a Python list consumed by cn_config_csv.py. Keeping it in
# either Go working directory makes conf.LoadDefine inspect it as a service
# definition map and abort before it reaches defines.json.
for target in host online-fight-forward; do
    install -m 0640 "$candidate_root/release/cn_config_csv.py" "$candidate_root/$target/cn_config_csv.py"
    install -m 0640 "$candidate_root/release/cn.config_csv.msgpack" "$candidate_root/$target/cn.config_csv.msgpack"
done

# The forward service reads cn_patch from its working directory, while the
# cross service watches the legacy sibling path ../online_fight_forward/.
# Keep two small regular-file copies so neither runtime depends on a symlink.
forward_patch_source="$source_root/release/online_fight_forward/cn_patch"
[[ -f "$forward_patch_source" && ! -L "$forward_patch_source" ]] \
    || fail "required online-fight patch input is missing or unsafe: $forward_patch_source"
forward_patch="$(tr -d '[:space:]' < "$forward_patch_source")"
[[ "$forward_patch" =~ ^[0-9]+$ ]] \
    || fail "online-fight patch input must contain a non-negative integer"
printf '%s\n' "$forward_patch" > "$candidate_root/online-fight-forward/cn_patch"
install -m 0640 "$candidate_root/online-fight-forward/cn_patch" \
    "$candidate_root/online_fight_forward/cn_patch"

export GO111MODULE=on
(
    cd "$candidate_root/gosrc/tjgame"
    "$go_bin" test ./services/union
)
rm -f -- "$candidate_root/gosrc/tjgame/services/union/training_level_fallback_test.go"

build_go_component() {
    local package="$1"
    local destination="$2"
    if [[ "$package" == "login" ]]; then
        # The legacy login server owns a nested Go 1.13 module. Building it
        # from tjgame/ makes Go reject the directory as outside the module.
        (
            cd "$candidate_root/gosrc/tjgame/login"
            "$go_bin" build -trimpath -o "$candidate_root/bin/$destination" .
        )
    else
        (
            cd "$candidate_root/gosrc/tjgame"
            "$go_bin" build -trimpath -o "$candidate_root/bin/$destination" "./$package"
        )
    fi
    chmod 0750 "$candidate_root/bin/$destination"
}

build_go_component login login_server
build_go_component host host_server
build_go_component anti_cheat anti_cheat_server
build_go_component online_fight_forward online_fight_forward_server

# The temporary source tree contains historical comments and test fixtures. The
# compiled Sakura-gated binaries are the only Go artifacts retained at runtime.
rm -rf -- "$candidate_root/gosrc"
printf 'sakura-only-login-ticket-gate-v2\n' > "$candidate_root/sakura-only-login-gate.txt"
chmod 0640 "$candidate_root/sakura-only-login-gate.txt"
printf 'sakura-gm-timeout-reconciliation-v1\n' \
    > "$candidate_root/sakura-gm-timeout-reconciliation-gate.txt"
chmod 0640 "$candidate_root/sakura-gm-timeout-reconciliation-gate.txt"
printf 'loopback-metrics-gate-v1\n' > "$candidate_root/loopback-metrics-gate.txt"
chmod 0640 "$candidate_root/loopback-metrics-gate.txt"

# Sanitize the shipped game inputs before installing operational helpers. The
# helper sources contain their own endpoint-policy literals and must remain
# byte-for-byte identical to the verifier used during staging.
python3 "$script_dir/sanitize-kdjx-runtime-inputs.py" --runtime-root "$candidate_root"
mkdir -p "$candidate_root/scripts"
for helper in audit-runtime-addresses.py run-host-service.sh run-python-game.sh healthcheck-kdjx-runtime.sh kdjx_env.py validate-gm-env.py validate-runtime-env.py; do
    install -m 0750 "$script_dir/$helper" "$candidate_root/scripts/$helper"
done
python3 "$script_dir/audit-runtime-addresses.py" --runtime-root "$candidate_root"

mv -- "$candidate_root" "$final_root"
candidate_root=""
printf 'KDJX runtime staged at %s\n' "$final_root"
