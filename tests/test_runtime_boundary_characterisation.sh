#!/bin/bash
# No `-e`: this file deliberately captures the exit status of entrypoints
# that are expected to fail in some scenarios (bare `out="$(...)"; rc=$?`,
# the same convention tests/test_section16_persist_storage.sh uses for the
# same reason) -- `set -e` would abort the whole suite the first time one of
# those scenarios' command substitution returns non-zero.
set -uo pipefail

# Branch 11 / Phase 1 (qnap-dxe-plan.md DQ2) CHARACTERISATION TESTS.
#
# These pin today's raw Apple `container` invocation shape (exact argv,
# stdin handling, captured-vs-streamed output, exit status, error paths) for
# every entrypoint in docs/refactor/runtime-boundary-inventory.md that has no
# existing hermetic fake-container coverage elsewhere. They must pass against
# the UNCHANGED production code (this file adds no behaviour, no fixes) and
# must keep passing, unmodified, through every later increment that moves
# these raw calls behind bin/lib/dx-runtime.sh / dx-runtime-apple.sh -- that
# is the whole point of a characterisation test: if migrating an entrypoint
# ever requires editing one of these assertions, the migration changed
# behaviour and must stop.
#
# Coverage already established elsewhere and NOT duplicated here (see
# docs/refactor/runtime-boundary-inventory.md for the full map):
#   - bin/lib/dx-container.sh's own wrapper functions (container_exists,
#     container_is_running, container_image_exists, container_ensure_volume,
#     container_stop_bounded's full bounded stop/kill/runtime-process
#     sequence, dx_container_list_names's --quiet/fallback branches):
#     tests/test_sourceable_coverage.sh.
#   - bin/dx-create-container (create argv, DX_NIX_DISK_SIZE forwarding),
#     bin/dx-reclaim, bin/dx-wait-ssh, bin/dx-migrate-persist (file-content
#     assertions): tests/test_section9_host_scripts.sh.
#   - bin/dx-migrate-persist's runtime-client-race retry (dx_runtime_run_
#     ephemeral's future home): tests/test_section16_persist_storage.sh.
#   - bin/dx-status (image/container listing, logs, bootstrap generation,
#     drift, dead guest): tests/test_section9_host_scripts.sh.
#   - bin/dx-sync-bootstrap, bin/dx-start-container (bootstrap publish/
#     confirm, D7 option 3): tests/test_bootstrap_publication.sh.
#   - bin/lib/dx-backup.sh (exec with -u/-i, tar both directions):
#     tests/test_dx_backup.sh, tests/test_dx_restore.sh.
#
# New here (no prior hermetic fake-container test existed for any of these):
#   dx-destroy-container, dx-destroy-image, dx-create-volumes' legacy-volume
#   guard, dx-destroy-volumes, dx-enter, dx-export, dx-gc, dx-get, dx-put.
#
# Logging convention used by every fake `container` below: when a case arm
# wants to record an invocation, it logs the COMPLETE, UNSHIFTED "$@" (the
# verb included), one argument per line, followed by a lone form-feed line
# ("\f") as a record separator -- so a full log's content can be compared
# byte for byte against an expected here-string built the same way, with no
# reliance on grep's handling of embedded newlines in a pattern (BSD and GNU
# grep -F disagree on that, and this suite runs under both).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "Runtime boundary characterisation (Branch 11 / Phase 1)"

fresh_home() {
    local dir="$1"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

# =============================================================================
# bin/dx-destroy-container: bounded stop then plain delete; force-delete
# fallback when the bounded stop cannot bring the container down.
# =============================================================================

dc_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-destroy-container.XXXXXX")"

fake_tool_write "$dc_fixture/bin" container '
case "$1" in
    list)
        shift
        all=false
        for a in "$@"; do [ "$a" = -a ] && all=true; done
        if [ "$all" = true ]; then
            [ "${DX_FAKE_EXISTS:-1}" = 1 ] && printf "%s\n" "$DX_CONTAINER_NAME"
        elif [ ! -f "$DX_FAKE_STOPPED_MARKER" ] && [ "${DX_FAKE_RUNNING:-1}" = 1 ]; then
            printf "%s\n" "$DX_CONTAINER_NAME"
        fi
        exit 0
        ;;
    stop)
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        [ "${DX_FAKE_STOP_WORKS:-1}" = 1 ] && : > "$DX_FAKE_STOPPED_MARKER"
        exit 0
        ;;
    kill)
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
    delete)
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
    *) exit 1 ;;
esac
'

run_destroy_container() {
    local log="$1"; shift
    : > "$log"
    rm -f "$dc_fixture/stopped-marker"
    env PATH="$dc_fixture/bin:/usr/bin:/bin" \
        HOME="$(fresh_home "$dc_fixture/home-$RANDOM")" \
        DX_CONTAINER_NAME=dxe-rtb-destroy \
        DX_FAKE_ARGV_LOG="$log" \
        DX_FAKE_STOPPED_MARKER="$dc_fixture/stopped-marker" \
        DX_STOP_COMMAND_TIMEOUT=1 DX_STOP_GRACE_SECONDS=1 DX_STOP_WAIT_TIMEOUT=1 \
        "$@" "$BASE_DIR/bin/dx-destroy-container"
}

log="$dc_fixture/argv.log"
out="$(run_destroy_container "$log" env DX_FAKE_EXISTS=0 2>&1)"
if [ ! -s "$log" ] && printf '%s\n' "$out" | stdin_matches "does not exist"; then
    test_pass "dx-destroy-container is a no-op (no delete call) when the container does not exist"
else
    test_fail "dx-destroy-container is a no-op when the container does not exist (log=[$(cat "$log" 2>/dev/null)] out=$out)"
fi

out="$(run_destroy_container "$log" env DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=0 2>&1)"
rc=$?
expected=$'delete\ndxe-rtb-destroy\n\f'
if [ "$rc" -eq 0 ] && [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-destroy-container skips the bounded stop and deletes directly when already stopped"
else
    test_fail "dx-destroy-container skips the bounded stop when already stopped (log=[$(cat "$log")] out=$out)"
fi

out="$(run_destroy_container "$log" env DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_STOP_WORKS=1 2>&1)"
rc=$?
expected=$'stop\n--time\n1\ndxe-rtb-destroy\n\f\ndelete\ndxe-rtb-destroy\n\f'
if [ "$rc" -eq 0 ] && [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-destroy-container stops then plain-deletes when the bounded stop succeeds"
else
    test_fail "dx-destroy-container stops then plain-deletes when the bounded stop succeeds (rc=$rc log=[$(cat "$log")] out=$out)"
fi

out="$(run_destroy_container "$log" env DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_STOP_WORKS=0 2>&1)"
rc=$?
expected=$'stop\n--time\n1\ndxe-rtb-destroy\n\f\nkill\ndxe-rtb-destroy\n\f\ndelete\n--force\ndxe-rtb-destroy\n\f'
if [ "$rc" -eq 0 ] && [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-destroy-container force-deletes when the bounded stop cannot bring the container down"
else
    test_fail "dx-destroy-container force-deletes when the bounded stop fails (rc=$rc log=[$(cat "$log")] out=$out)"
fi
rm -rf "$dc_fixture"

# =============================================================================
# bin/dx-destroy-image: skip when absent; `container image rm IMAGE` when
# present, output discarded.
# =============================================================================

di_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-destroy-image.XXXXXX")"

fake_tool_write "$di_fixture/bin" container '
case "$1" in
    image)
        case "$2" in
            list)
                if [ "${3:-}" = --quiet ]; then
                    [ "${DX_FAKE_IMAGE_EXISTS:-1}" = 1 ] && printf "%s\n" "$DX_IMAGE"
                fi
                exit 0
                ;;
            rm)
                printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
                printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
                printf "noise-that-must-be-discarded\n"
                exit "${DX_FAKE_RM_RC:-0}"
                ;;
        esac
        exit 1
        ;;
    *) exit 1 ;;
esac
'

run_destroy_image() {
    local log="$1"; shift
    : > "$log"
    env PATH="$di_fixture/bin:/usr/bin:/bin" \
        HOME="$(fresh_home "$di_fixture/home-$RANDOM")" \
        DX_IMAGE=dxe-rtb-image \
        DX_FAKE_ARGV_LOG="$log" \
        "$@" "$BASE_DIR/bin/dx-destroy-image"
}

log="$di_fixture/argv.log"
out="$(run_destroy_image "$log" env DX_FAKE_IMAGE_EXISTS=0 2>&1)"
if [ ! -s "$log" ] && printf '%s\n' "$out" | stdin_matches "does not exist; nothing to destroy"; then
    test_pass "dx-destroy-image is a no-op when the image does not exist"
else
    test_fail "dx-destroy-image is a no-op when the image does not exist (log=[$(cat "$log")] out=$out)"
fi

out="$(run_destroy_image "$log" env DX_FAKE_IMAGE_EXISTS=1 2>&1)"
expected=$'image\nrm\ndxe-rtb-image\n\f'
if [ "$(cat "$log")" = "$expected" ] && ! printf '%s\n' "$out" | stdin_matches "noise-that-must-be-discarded"; then
    test_pass "dx-destroy-image removes the image by exact name and discards its stdout"
else
    test_fail "dx-destroy-image removes the image by exact name (log=[$(cat "$log")] out=$out)"
fi
rm -rf "$di_fixture"

# =============================================================================
# bin/dx-create-volumes: legacy-workspace-volume guard (both `container
# volume inspect` calls). Existing coverage (test_section16_persist_storage.sh)
# is static (grep) or live-only; this drives the actual branch decision.
# =============================================================================

cv_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-create-volumes.XXXXXX")"

fake_tool_write "$cv_fixture/bin" container '
case "$1" in
    volume)
        case "$2" in
            inspect)
                case "$3" in
                    "$DX_FAKE_LEGACY_VOLUME") exit "${DX_FAKE_LEGACY_EXISTS:-1}" ;;
                    "$DX_PERSIST_VOLUME") exit "${DX_FAKE_PERSIST_EXISTS:-1}" ;;
                    *) exit 1 ;;
                esac
                ;;
            create) exit 0 ;;
        esac
        exit 1
        ;;
    *) exit 1 ;;
esac
'

run_create_volumes() {
    env PATH="$cv_fixture/bin:/usr/bin:/bin" \
        HOME="$(fresh_home "$cv_fixture/home-$RANDOM")" \
        DX_NIX_VOLUME=dxe-rtb-nix DX_PERSIST_VOLUME=dxe-rtb-persist DX_BOOTSTRAP_VOLUME=dxe-rtb-bootstrap \
        DX_LEGACY_WORKSPACE_VOLUME=dxe-rtb-legacy \
        DX_FAKE_LEGACY_VOLUME=dxe-rtb-legacy \
        "$@" "$BASE_DIR/bin/dx-create-volumes"
}

# Legacy volume absent (inspect exits 1 = not found): the guard's `&&` chain
# short-circuits on the first failing test, so create-volumes proceeds
# straight to ensuring every volume.
out="$(run_create_volumes env DX_FAKE_LEGACY_EXISTS=1 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | stdin_matches "Run bin/dx-migrate-persist"; then
    test_pass "dx-create-volumes proceeds normally when no legacy volume exists"
else
    test_fail "dx-create-volumes proceeds normally when no legacy volume exists (rc=$rc out=$out)"
fi

# Legacy volume present AND persist volume absent: refuse with the migration
# message, before creating anything.
out="$(run_create_volumes env DX_FAKE_LEGACY_EXISTS=0 DX_FAKE_PERSIST_EXISTS=1 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "Run bin/dx-migrate-persist"; then
    test_pass "dx-create-volumes refuses when a legacy volume exists but the persist volume does not"
else
    test_fail "dx-create-volumes refuses on an unmigrated legacy volume (rc=$rc out=$out)"
fi

# Legacy volume present but persist volume ALSO already present: already
# migrated, so the guard's second test fails and create-volumes proceeds.
out="$(run_create_volumes env DX_FAKE_LEGACY_EXISTS=0 DX_FAKE_PERSIST_EXISTS=0 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | stdin_matches "Run bin/dx-migrate-persist"; then
    test_pass "dx-create-volumes proceeds when the legacy volume was already migrated (persist volume already exists)"
else
    test_fail "dx-create-volumes proceeds once persist already exists (rc=$rc out=$out)"
fi
rm -rf "$cv_fixture"

# =============================================================================
# bin/dx-destroy-volumes: no-volumes no-op; --force skips the confirmation
# prompt and removes each configured volume by exact name; a failed removal
# is a clear, immediate error; refuses to prompt on non-tty stdin without
# --force.
# =============================================================================

dv_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-destroy-volumes.XXXXXX")"

fake_tool_write "$dv_fixture/bin" container '
case "$1" in
    volume)
        case "$2" in
            inspect)
                case " $DX_FAKE_EXISTING_VOLUMES " in
                    *" $3 "*) exit 0 ;;
                    *) exit 1 ;;
                esac
                ;;
            rm)
                printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
                printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
                case " $DX_FAKE_RM_FAIL_VOLUMES " in
                    *" $3 "*) exit 1 ;;
                    *) exit 0 ;;
                esac
                ;;
        esac
        exit 1
        ;;
    *) exit 1 ;;
esac
'

run_destroy_volumes() {
    local log="$1"; shift
    : > "$log"
    env PATH="$dv_fixture/bin:/usr/bin:/bin" \
        HOME="$(fresh_home "$dv_fixture/home-$RANDOM")" \
        DX_NIX_VOLUME=dxe-rtb-nix DX_PERSIST_VOLUME=dxe-rtb-persist DX_BOOTSTRAP_VOLUME=dxe-rtb-bootstrap \
        DX_FAKE_ARGV_LOG="$log" \
        "$@" "$BASE_DIR/bin/dx-destroy-volumes" --force < /dev/null
}

log="$dv_fixture/argv.log"
out="$(run_destroy_volumes "$log" env DX_FAKE_EXISTING_VOLUMES='' 2>&1)"
if [ ! -s "$log" ] && printf '%s\n' "$out" | stdin_matches "No DX volumes exist"; then
    test_pass "dx-destroy-volumes is a no-op when none of the configured volumes exist"
else
    test_fail "dx-destroy-volumes no-op on no existing volumes (log=[$(cat "$log")] out=$out)"
fi

out="$(run_destroy_volumes "$log" env DX_FAKE_EXISTING_VOLUMES='dxe-rtb-nix dxe-rtb-persist dxe-rtb-bootstrap' 2>&1)"
rc=$?
expected=$'volume\nrm\ndxe-rtb-nix\n\f\nvolume\nrm\ndxe-rtb-persist\n\f\nvolume\nrm\ndxe-rtb-bootstrap\n\f'
if [ "$rc" -eq 0 ] && [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-destroy-volumes --force removes exactly the existing configured volumes by name, in order, with no prompt"
else
    test_fail "dx-destroy-volumes --force removes the existing volumes (rc=$rc log=[$(cat "$log")] out=$out)"
fi

out="$(run_destroy_volumes "$log" env DX_FAKE_EXISTING_VOLUMES='dxe-rtb-nix dxe-rtb-persist' DX_FAKE_RM_FAIL_VOLUMES='dxe-rtb-persist' 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "Failed to remove volume dxe-rtb-persist"; then
    test_pass "dx-destroy-volumes stops with a clear error the moment one volume's removal fails"
else
    test_fail "dx-destroy-volumes reports a failed removal clearly (rc=$rc out=$out)"
fi

out="$(env PATH="$dv_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$dv_fixture/home-noforce")" \
    DX_NIX_VOLUME=dxe-rtb-nix DX_PERSIST_VOLUME=dxe-rtb-persist DX_BOOTSTRAP_VOLUME=dxe-rtb-bootstrap \
    DX_FAKE_EXISTING_VOLUMES='dxe-rtb-nix' DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-destroy-volumes" < /dev/null 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "Refusing to destroy volumes without --force"; then
    test_pass "dx-destroy-volumes refuses to prompt (and does not delete) when stdin is not a TTY and --force is absent"
else
    test_fail "dx-destroy-volumes refuses without --force on non-tty stdin (rc=$rc out=$out)"
fi
rm -rf "$dv_fixture"

# =============================================================================
# bin/dx-enter: interactive exec, no-args and args-quoting branches. A real
# TTY is not exercised (the fake stands in for the binary, as everywhere else
# in this suite); the quoted-argv case is proven by replaying the logged,
# %q-quoted command through a real bash rather than pinning %q's exact byte
# output, which is not guaranteed identical across bash versions.
# =============================================================================

en_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-enter.XXXXXX")"

fake_tool_write "$en_fixture/bin" container '
case "$1" in
    exec)
        shift
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
    *) exit 1 ;;
esac
'

log="$en_fixture/argv.log"
: > "$log"
env PATH="$en_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$en_fixture/home1")" \
    DX_CONTAINER_NAME=dxe-rtb-enter DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-enter" >/dev/null 2>&1
expected=$'-it\ndxe-rtb-enter\nbash\n-l\n\f'
if [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-enter with no arguments execs an interactive login shell (-it NAME bash -l)"
else
    test_fail "dx-enter with no arguments (got: $(cat "$log"))"
fi

: > "$log"
env PATH="$en_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$en_fixture/home2")" \
    DX_CONTAINER_NAME=dxe-rtb-enter DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-enter" echo "hello world" >/dev/null 2>&1
first_four="$(sed -n '1,4p' "$log")"
quoted_line="$(sed -n '5p' "$log")"
replay="$(bash -c "$quoted_line" 2>&1)"
if [ "$first_four" = $'-it\ndxe-rtb-enter\nbash\n-lc' ] && [ "$replay" = "hello world" ]; then
    test_pass "dx-enter with arguments execs -it NAME bash -lc with %q-quoted argv that replays exactly"
else
    test_fail "dx-enter with arguments (first_four=[$first_four] quoted=[$quoted_line] replay=[$replay])"
fi
rm -rf "$en_fixture"

# =============================================================================
# bin/dx-export: existence check must fail closed; on success `container
# export NAME` streams straight to the redirected file, byte for byte.
# =============================================================================

ex_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-export.XXXXXX")"

fake_tool_write "$ex_fixture/bin" container '
case "$1" in
    list)
        shift
        for a in "$@"; do
            if [ "$a" = -a ]; then
                [ "${DX_FAKE_EXISTS:-1}" = 1 ] && printf "%s\n" "$DX_CONTAINER_NAME"
                exit 0
            fi
        done
        exit 0
        ;;
    export)
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        printf "FAKE-TAR-BYTES-%s" "$DX_CONTAINER_NAME"
        exit 0
        ;;
    *) exit 1 ;;
esac
'

out_file="$ex_fixture/out.tar"
log="$ex_fixture/argv.log"
: > "$log"
out="$(env PATH="$ex_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$ex_fixture/home1")" \
    DX_CONTAINER_NAME=dxe-rtb-export DX_FAKE_EXISTS=0 DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-export" "$out_file" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$out_file" ] && printf '%s\n' "$out" | stdin_matches "does not exist"; then
    test_pass "dx-export refuses a nonexistent container before touching the output file"
else
    test_fail "dx-export refuses a nonexistent container (rc=$rc out=$out)"
fi

env PATH="$ex_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$ex_fixture/home2")" \
    DX_CONTAINER_NAME=dxe-rtb-export DX_FAKE_EXISTS=1 DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-export" "$out_file" >/dev/null 2>&1
expected=$'export\ndxe-rtb-export\n\f'
if [ "$(cat "$out_file")" = "FAKE-TAR-BYTES-dxe-rtb-export" ] && [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-export streams the archive verbatim to the redirected output file"
else
    test_fail "dx-export streams the archive to the output file (content=$(cat "$out_file" 2>/dev/null) log=$(cat "$log"))"
fi
rm -rf "$ex_fixture"

# =============================================================================
# bin/dx-gc: refuses when not running; when running, two plain (non-captured)
# `-u dx` exec calls in a fixed order, output streamed straight through.
# =============================================================================

gc_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-gc.XXXXXX")"

fake_tool_write "$gc_fixture/bin" container '
case "$1" in
    list)
        [ "${DX_FAKE_RUNNING:-1}" = 1 ] && printf "%s\n" "$DX_CONTAINER_NAME"
        exit 0
        ;;
    exec)
        shift
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
    *) exit 1 ;;
esac
'

log="$gc_fixture/argv.log"
out="$(env PATH="$gc_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$gc_fixture/home1")" \
    DX_CONTAINER_NAME=dxe-rtb-gc DX_FAKE_RUNNING=0 DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-gc" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "is not running"; then
    test_pass "dx-gc refuses when the container is not running"
else
    test_fail "dx-gc refuses when not running (rc=$rc out=$out)"
fi

: > "$log"
env PATH="$gc_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$gc_fixture/home2")" \
    DX_CONTAINER_NAME=dxe-rtb-gc DX_FAKE_RUNNING=1 DX_FAKE_ARGV_LOG="$log" \
    "$BASE_DIR/bin/dx-gc" >/dev/null 2>&1
expected=$'-u\ndx\ndxe-rtb-gc\nbash\n-lc\nnix-collect-garbage --delete-older-than 14d\n\f\n-u\ndx\ndxe-rtb-gc\nbash\n-lc\nnix-store --optimise\n\f'
if [ "$(cat "$log")" = "$expected" ]; then
    test_pass "dx-gc runs garbage collection then store optimisation, in order, as dx, with the exact commands"
else
    test_fail "dx-gc runs the two maintenance commands as dx in order (got: $(cat "$log"))"
fi
rm -rf "$gc_fixture"

# =============================================================================
# bin/dx-get: existence/directory tests via `container exec ... [ -e/-d ... ]`
# (exit status only), then a guest-to-host tar pipeline or a direct cat
# redirect, byte for byte. The fake passes `exec` straight through to a real
# local shell rooted at a fixture directory standing in for the guest (the
# same idiom as tests/test_bootstrap_publication.sh / test_dx_restore.sh):
# there is no real guest, so source/dest arguments here are RELATIVE (no
# leading "/"), letting the fake's `cd` scope them correctly -- dx-get itself
# has no opinion on whether guest paths are absolute or relative.
# =============================================================================

get_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-get.XXXXXX")"
guest_root="$get_fixture/guest-root"
mkdir -p "$guest_root/adir/sub"
printf 'file content' > "$guest_root/adir/sub/leaf.txt"
printf 'plain file content' > "$guest_root/plain.txt"

fake_tool_write "$get_fixture/bin" container '
case "$1" in
    exec)
        shift
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        shift
        cd "$DX_FAKE_GUEST_ROOT" || exit 1
        "$@"
        ;;
    *) exit 1 ;;
esac
'

log="$get_fixture/argv.log"
run_get() {
    : > "$log"
    env PATH="$get_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$get_fixture/home-$RANDOM")" \
        DX_CONTAINER_NAME=dxe-rtb-get DX_FAKE_ARGV_LOG="$log" DX_FAKE_GUEST_ROOT="$guest_root" \
        "$BASE_DIR/bin/dx-get" "$@"
}

out="$(run_get nowhere "$get_fixture/dest-missing" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "does not exist in container"; then
    test_pass "dx-get refuses a source path that does not exist in the guest"
else
    test_fail "dx-get refuses a missing source (rc=$rc out=$out)"
fi

dest_dir="$get_fixture/dest-dir"
run_get adir "$dest_dir/" >/dev/null 2>&1
if [ "$(cat "$dest_dir/adir/sub/leaf.txt" 2>/dev/null)" = "file content" ]; then
    test_pass "dx-get copies a guest directory (with a trailing-slash destination) preserving its subtree"
else
    test_fail "dx-get copies a guest directory into a trailing-slash destination (tree: $(find "$dest_dir" 2>&1))"
fi

dest_as="$get_fixture/dest-as"
run_get adir "$dest_as" >/dev/null 2>&1
if [ "$(cat "$dest_as/sub/leaf.txt" 2>/dev/null)" = "file content" ]; then
    test_pass "dx-get copies a guest directory 'as' a new name, stripping the source's own basename"
else
    test_fail "dx-get copies a guest directory as a new name (contents: $(find "$dest_as" 2>&1))"
fi

dest_file="$get_fixture/dest-file.txt"
run_get plain.txt "$dest_file" >/dev/null 2>&1
expected=$'exec\ndxe-rtb-get\ncat\nplain.txt\n\f'
if [ "$(cat "$dest_file" 2>/dev/null)" = "plain file content" ]; then
    test_pass "dx-get copies a guest file byte for byte via a redirected cat"
else
    test_fail "dx-get copies a guest file via cat redirect (got: $(cat "$dest_file" 2>&1), log=$(cat "$log"))"
fi
rm -rf "$get_fixture"

# =============================================================================
# bin/dx-put: the reverse direction. Proves BOTH stdin-passthrough shapes the
# contract must preserve (Increment 2 requirement (a)): a host tar piped into
# `container exec -i`, and a host file redirected (`< SOURCE`) into
# `container exec -i`. Same pass-through-exec idiom, relative guest paths, as
# dx-get above.
# =============================================================================

put_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-put.XXXXXX")"
guest_root="$put_fixture/guest-root"
mkdir -p "$guest_root"
source_dir="$put_fixture/source-dir"
mkdir -p "$source_dir/sub"
printf 'alpha' > "$source_dir/sub/one.txt"
source_file="$put_fixture/source-file.txt"
printf 'a lone file, not a pipe' > "$source_file"

fake_tool_write "$put_fixture/bin" container '
case "$1" in
    exec)
        shift
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        printf "\f\n" >> "$DX_FAKE_ARGV_LOG"
        stdin_flag=false
        [ "${1:-}" = -i ] && { stdin_flag=true; shift; }
        shift
        cd "$DX_FAKE_GUEST_ROOT" || exit 1
        if [ "$stdin_flag" = true ]; then
            cat > "$DX_FAKE_STDIN_LOG"
            "$@" < "$DX_FAKE_STDIN_LOG"
        else
            "$@"
        fi
        ;;
    *) exit 1 ;;
esac
'

log="$put_fixture/argv.log"
stdin_log="$put_fixture/stdin.log"
run_put() {
    : > "$log"; : > "$stdin_log"
    env PATH="$put_fixture/bin:/usr/bin:/bin" HOME="$(fresh_home "$put_fixture/home-$RANDOM")" \
        DX_CONTAINER_NAME=dxe-rtb-put DX_FAKE_ARGV_LOG="$log" DX_FAKE_STDIN_LOG="$stdin_log" \
        DX_FAKE_GUEST_ROOT="$guest_root" \
        "$BASE_DIR/bin/dx-put" "$@"
}

# Directory destination: a real tar stream piped through `-i`, not a plain
# redirect.
mkdir -p "$guest_root/target1"
run_put "$source_dir" "target1/" >/dev/null 2>&1
if [ "$(cat "$guest_root/target1/source-dir/sub/one.txt" 2>/dev/null)" = "alpha" ]; then
    test_pass "dx-put streams a directory into the guest via a real piped tar (-i), landing at DEST/basename(SOURCE)"
else
    test_fail "dx-put streams a directory via piped tar (tree: $(find "$guest_root/target1" 2>&1), log=$(cat "$log"))"
fi
if grep -F -x -q -- -i "$log" && grep -F -x -q -- tar "$log"; then
    test_pass "dx-put's directory-copy exec includes -i (stdin attached for the piped tar)"
else
    test_fail "dx-put's directory-copy exec includes -i (log=$(cat "$log"))"
fi

# File destination: stdin is a host file REDIRECTED (`< SOURCE`), not piped
# from a command -- the second stdin shape the contract must preserve
# exactly.
mkdir -p "$guest_root/target2"
run_put "$source_file" "target2/copied.txt" >/dev/null 2>&1
if [ "$(cat "$guest_root/target2/copied.txt" 2>/dev/null)" = "a lone file, not a pipe" ] \
    && [ "$(cat "$stdin_log")" = "a lone file, not a pipe" ]; then
    test_pass "dx-put streams a file into the guest with stdin redirected from the source file (not piped), byte for byte"
else
    test_fail "dx-put streams a file via redirected stdin (guest content: $(cat "$guest_root/target2/copied.txt" 2>&1), stdin captured: $(cat "$stdin_log"))"
fi
rm -rf "$put_fixture"

# =============================================================================
# bin/dx-create-container's rendered Apple `container create` argv, byte for
# byte, after Branch 11 / Phase 2 replaced its Apple-flavoured CREATE_FLAGS
# array with bin/lib/dx-runtime.sh's runtime-neutral vocabulary (qnap-dxe-plan.md
# DQ2: "runtime-specific CLI syntax ... lives only in the adapter"). Every
# config value below is pinned explicitly so the expected argv can be built
# independently and compared exactly, in order, against what
# dx_runtime_apple_container_create actually renders -- proving the
# refactor changed nothing observable for DX_RUNTIME=apple.
# =============================================================================

cc_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rtb-create-container.XXXXXX")"
fake_tool_write "$cc_fixture/bin" container '
case "$1" in
    list) exit 1 ;;
    image) [ "$2 $3" = "list --quiet" ] && printf "%s\n" "$DX_IMAGE"; exit 0 ;;
    create)
        shift
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
    *) exit 0 ;;
esac
'

cc_home="$(fresh_home "$cc_fixture/home")"
cc_log="$cc_fixture/argv.log"
: > "$cc_log"
env PATH="$cc_fixture/bin:/usr/bin:/bin" \
    HOME="$cc_home" \
    DX_CONTAINER_NAME=dxe-rtb-create \
    DX_IMAGE=dxe-rtb-image \
    DX_NIX_VOLUME=dxe-rtb-nix \
    DX_PERSIST_VOLUME=dxe-rtb-persist \
    DX_BOOTSTRAP_VOLUME=dxe-rtb-bootstrap \
    DX_BOOTSTRAP_PATH=/guest-bootstrap \
    DX_GUEST_ACTIVATION_TIMEOUT=1800 \
    DX_GUEST_ACTIVATION_ATTEMPTS=2 \
    DX_GUEST_ACTIVATION_RETRY_DELAY=5 \
    DX_NIX_DISK_SIZE=64G \
    DX_CONTAINER_MEMORY=12G \
    DX_CONTAINER_CPUS=4 \
    DX_SSH_PORT=2222 \
    DX_CONTAINER_RESTART_POLICY=no \
    DX_GIT_MOUNT_SOURCE='' \
    DX_SSH_KEY_PUB="$cc_fixture/no-such-key.pub" \
    DX_FAKE_ARGV_LOG="$cc_log" \
    "$BASE_DIR/bin/dx-create-container" >/dev/null 2>&1

# Independently reconstructed (not copy-pasted from the adapter): the exact
# argv bin/dx-create-container built before Branch 11 / Phase 2, in the
# same order -- name, entrypoint, cap-add, the three volumes, five env
# vars, memory, cpus, publish, [no git volume, no pub-key env: neither was
# configured above].
(
    source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
    entrypoint_cmd="$(dx_bootstrap_launch_command)"
    # HOST_TZ is host-detected (dx_get_host_timezone), not pinned above, so
    # the comparison does not depend on this machine's own timezone.
    host_tz="$(dx_get_host_timezone)"; [ -n "$host_tz" ] || host_tz=UTC
    printf '%s\n' \
        --name dxe-rtb-create --entrypoint sh --cap-add CAP_SYS_ADMIN \
        --volume dxe-rtb-nix:/var/lib/dx-nix-raw:rw \
        --volume dxe-rtb-persist:/persist:rw \
        --volume dxe-rtb-bootstrap:/guest-bootstrap:rw \
        -e "HOST_TZ=$host_tz" \
        -e DX_GUEST_ACTIVATION_TIMEOUT=1800 \
        -e DX_GUEST_ACTIVATION_ATTEMPTS=2 \
        -e DX_GUEST_ACTIVATION_RETRY_DELAY=5 \
        -e DX_NIX_DISK_SIZE=64G \
        -m 12G -c 4 \
        -p 127.0.0.1:2222:2222 \
        dxe-rtb-image -c "$entrypoint_cmd" -- /guest-bootstrap \
        > "$cc_fixture/expected.log"
)
if diff "$cc_fixture/expected.log" "$cc_log" >/dev/null 2>&1; then
    test_pass "dx-create-container renders today's exact Apple container-create argv, byte for byte, in order"
else
    test_fail "dx-create-container renders today's exact Apple container-create argv, byte for byte, in order (diff: $(diff "$cc_fixture/expected.log" "$cc_log" 2>&1))"
fi

# The optional git-mount volume and pub-key env, when configured, land in
# their documented positions (after the fixed flags, in the order
# bin/dx-create-container adds them) -- a substring proof, not a second
# full byte-for-byte log, since the first proof above already pins the
# fixed portion exactly.
cc_git_src="$cc_fixture/git-src"; mkdir -p "$cc_git_src"
cc_key_pub="$cc_fixture/dx_key.pub"; printf 'FIXTURE-NOT-A-REAL-KEY-0123456789\n' > "$cc_key_pub"
: > "$cc_log"
env PATH="$cc_fixture/bin:/usr/bin:/bin" \
    HOME="$(fresh_home "$cc_fixture/home2")" \
    DX_CONTAINER_NAME=dxe-rtb-create2 \
    DX_IMAGE=dxe-rtb-image \
    DX_NIX_VOLUME=dxe-rtb-nix2 \
    DX_PERSIST_VOLUME=dxe-rtb-persist2 \
    DX_BOOTSTRAP_VOLUME=dxe-rtb-bootstrap2 \
    DX_GIT_MOUNT_SOURCE="$cc_git_src" \
    DX_GIT_MOUNT_TARGET=/workspace \
    DX_SSH_KEY_PUB="$cc_key_pub" \
    DX_FAKE_ARGV_LOG="$cc_log" \
    "$BASE_DIR/bin/dx-create-container" >/dev/null 2>&1
got="$(cat "$cc_log")"
if printf '%s\n' "$got" | stdin_matches -F -- "$cc_git_src:/workspace:rw" \
    && printf '%s\n' "$got" | stdin_matches -F -- "DX_PUB_KEY=FIXTURE-NOT-A-REAL-KEY-0123456789"; then
    test_pass "dx-create-container's optional git-mount volume and pub-key env still reach the Apple create argv"
else
    test_fail "dx-create-container's optional git-mount volume and pub-key env still reach the Apple create argv (got: $got)"
fi
rm -rf "$cc_fixture"

print_summary
exit_with_code
