#!/bin/bash
# tier: live
# bash32: no
# WP7.2 (plans/do; spec section 9 W4, section 6 and 6.1; R31-R37): the /persist
# MIGRATION dry run, LIVE, on a disposable QNAP guest -- inventory, migrate,
# interrupt and resume, verify, switch, change files, roll back into a new
# volume, refuse the retired directory, move it aside and migrate again.
#
# This suite talks to a real NAS and destroys and resets the guest it runs on.
# It runs only when ALL of these hold, and otherwise makes no remote call:
#   1. tests/run.sh --live (SKIP_INTEGRATION=false), with a profile that is
#      not the default guest (tests/test_helpers.sh's live_tail_enabled);
#   2. DXE_PERSIST_LIVE_CANARY is set (unset: the suite SKIPS);
#   3. persist_migrate_live_guard (tests/lib/persist-migrate-live.sh) accepts
#      the profile: every WP7.1 rule (a host-path canary profile: canary-named
#      container, volumes, image and keys, a port other than 2222 and 8787,
#      restart policy no, usage service off, a mount sentinel), plus a
#      canary-named rollback volume, a root without ",", a sane bulk size and
#      a valid opt-in for the production inventory.
#
#   DXE_PERSIST_LIVE_CANARY=<canary name> \
#     ./bin/dx-profile <canary profile> tests/run.sh --live \
#     --file tests/test_persist_migrate_live.sh
#
# The profile stays as installed (host-path). The suite STARTS the canary in
# volume mode by exporting DX_PERSIST_STORAGE=volume over it, and switches the
# mode and DX_PERSIST_VOLUME itself at each step, exactly where the runbook
# (docs/qnap-runbook.md section 11) tells the user to edit the profile.
#
# Optional: DXE_PERSIST_LIVE_RUN_DIR=<dir outside the checkout> (logs,
# listings, results, the isolated XDG_STATE_HOME holding the canary's D-7
# record and SSH pins; default: a new mktemp directory);
# DXE_PERSIST_LIVE_ROLLBACK_VOLUME (default <DX_PERSIST_VOLUME>-rollback);
# DXE_PERSIST_LIVE_BULK_MIB (64..16384, default 2048: the incompressible file
# whose copy the interrupt lands in; raise it if the copy finishes before the
# interrupt); DXE_PERSIST_LIVE_INTERRUPT_DEADLINE (seconds, 10..3600, default
# 900); DXE_PERSIST_LIVE_KEEP=1 (skip the final cleanup);
# DXE_PERSIST_LIVE_KEEP_RUNNING=1 (after a failure, do not stop the canary);
# DXE_PERSIST_LIVE_CLEANUP_ONLY=1 (run only the final cleanup; pass the same
# DXE_PERSIST_LIVE_RUN_DIR).
#
# A SEPARATE, opt-in run: DXE_PERSIST_LIVE_INVENTORY_REAL=dx-qnap runs ONLY
# the read-only dx-persist-inventory of the production guest through the
# production profile `qnap` (no canary case, no cleanup): it records size,
# counts and the measured time, and stops, starts or writes nothing of dx-qnap.
# Never by default; the coordinator asks the user first.
#
# How the mid-copy interrupt works (deterministic, NAS side). The seed puts
# one incompressible file of DXE_PERSIST_LIVE_BULK_MIB MiB at
# /persist/dxe-live-bulk/dxe-live-blob.bin. dx-persist-migrate runs in the
# background; meanwhile ONE ssh call runs PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT
# in the NAS shell (the management account): it waits for exactly one RUNNING
# container that mounts the canary persist volume, runs the guest-volume rsync
# with "... /src/ /dst/" and binds the canary directory at /dst -- those three
# single out the copy, which carries no name or label of its own; the
# `ancestor=<canary image>` filter only narrows the list, since the canary
# image is a tag of the shared base the production guest runs too -- then for
# rsync's temp file of the blob (.dxe-live-blob.bin.XXXXXX; with rsync
# --inplace there would be none, see tests/lib/persist-migrate-live.sh),
# and at that moment sends that one container `docker kill` (SIGKILL) -- a NAS
# reboot or an OOM kill in the middle of the largest file -- and waits until
# --rm has removed it. The migrate command then reports the stopped copy
# (exit 1, marker copying) and the suite runs it again.
#
# Behaviour (as WP7.1):
#   - Fail-fast: the first failing check stops the run; the background
#     migrate is waited for, the canary container is stopped (unless
#     DXE_PERSIST_LIVE_KEEP_RUNNING=1), the rest is left for inspection, and
#     the cleanup-only command is printed. One PASS/FAIL line per check.
#   - FINDINGS are recorded as failures ("FINDING: ...", listed at the end) but
#     the run goes on, so the later cases and the cleanup still run:
#       * the inventory exiting 3 with a named blocker;
#       * the resume failing its verification because the killed rsync left
#         its temp file in the destination (forward rsync has no --delete):
#         the suite then moves that one file aside (mv, canary directory only)
#         and runs the migration a third time;
#       * the /persist bind source reported resolved (as WP7.1).
#   - Everything the suite changes on the share it changes from a root one-off
#     container whose only bind is <root>/dxe/<canary> (tests/lib's fixed
#     scripts); it never deletes anything on the NAS recursively: it moves the
#     retired directory aside to persist.retired-<UTC> (the runbook's step),
#     and the final cleanup moves the leaf to persist.dxe-live-removed-<UTC>
#     and prints the manual removal for the user. Volumes are read only through
#     `-v <volume>:/v:ro` after their DQ6 check; volumes are deleted only by
#     exact canary name through the DQ6-checked delete.
#
# Cases, in order (each name is its PASS/FAIL prefix):
#   preflight            no canary container, volume (nix, persist, bootstrap,
#                        rollback), directory or record yet; the share root
#                        is mounted (sentinel).
#   volume bring-up      `dx true` in volume mode: /persist is the persist
#                        volume, dx-status configured == actual, nothing on
#                        the share; the SSH host key is recorded.
#   seed                 through the guest: nested directories, hard links (a
#                        group of three across directories), two ._* files, a
#                        FIFO, a socket (tmux; reported if it cannot), relative,
#                        absolute, dangling and directory symlinks, private
#                        modes, an empty file, odd names (space, leading dash,
#                        TAB, quotes, backslash, glob characters, $, UTF-8,
#                        newline) and the bulk file; the guest's check.
#   inventory            dx-persist-inventory exits 0 (3 with a named blocker:
#                        FINDING), lists both ._* files and the special files,
#                        writes nothing.
#   stop and list        the guest stopped; the read-only listing of the
#                        volume's seeded tree and bulk file (L0).
#   interrupted copy     migrate in the background, killed mid-blob: exit 1,
#                        "stopped before it finished", marker copying for this
#                        guest and volume, the blob not complete, no record.
#   resumed copy         migrate again: resumes into the same directory, exit
#                        0, marker ready (the first created-at), record
#                        mode=migrate, report (copy/verify seconds, both ._*
#                        files); the directory's listing == L0 without ._*.
#   switch to directory  DX_PERSIST_STORAGE=host-path + dx-recreate: one rw
#                        bind of the leaf, the guest's own check line,
#                        dx-status configured == actual, the same host key,
#                        the seeded data (guest check), no ._* file.
#   changes              through the guest: write, overwrite, delete (a file
#                        and a hard link), rename (a file and a directory), a
#                        new ._* file; stop; the directory's listing (L1).
#   rollback             dx-persist-rollback --volume <rollback>: exit 0,
#                        marker retired, the record untouched, the report.
#   switch back          DX_PERSIST_STORAGE=volume DX_PERSIST_VOLUME=<rollback>
#                        + dx-recreate: the guest sees the changes, not the new
#                        ._* file; the rollback volume's listing == L1 without
#                        ._*; the ORIGINAL volume's listing == L0 (unchanged).
#   retired refused      host-path again: dx-create-volumes and
#                        dx-start-container refuse the retired directory.
#   retired aside        mv persist persist.retired-<UTC> (root container,
#                        canary directory only; only a retired leaf moves).
#   migrate again        from the rollback volume into a fresh directory:
#                        exit 0, marker ready, no ._* file; listing == the
#                        rollback volume's.
#   switch again         host-path + dx-recreate, confirmed as before.
#   final cleanup        leaf moved aside, dx-factory-reset --force, both
#                        persist volumes deleted by exact name (DQ6), the
#                        record deleted; the manual NAS removal is printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-live.sh
source "$SCRIPT_DIR/lib/persist-live.sh"
# shellcheck source=lib/persist-migrate-live.sh
source "$SCRIPT_DIR/lib/persist-migrate-live.sh"
BIN_DIR="$BASE_DIR/bin"

test_section "WP7.2: /persist migration dry run, live on a disposable QNAP guest"

LV_INVOCATION="DXE_PERSIST_LIVE_CANARY=<canary name> ./bin/dx-profile <canary profile> tests/run.sh --live --file tests/test_persist_migrate_live.sh"

# --- Gates: no remote call before all three pass ----------------------------
if ! live_tail_enabled; then
    [ -n "$DXE_LIVE_TAIL_REFUSED" ] || test_skip "Live /persist migration suite skipped (SKIP_INTEGRATION is not false); run it with: $LV_INVOCATION"
    print_summary
    exit_with_code
fi
if [ -z "${DXE_PERSIST_LIVE_CANARY:-}" ]; then
    test_skip "Live /persist migration suite not opted in: set DXE_PERSIST_LIVE_CANARY to the canary profile's DX_CONTAINER_NAME ($LV_INVOCATION)"
    print_summary
    exit_with_code
fi
if ! persist_migrate_live_guard; then
    test_fail "the live /persist migration suite refuses this profile (the Refusing: lines above); nothing was contacted"
    print_summary
    exit_with_code
fi

LV_RUN_DIR="${DXE_PERSIST_LIVE_RUN_DIR:-}"
if [ -z "$LV_RUN_DIR" ]; then
    LV_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-migrate-live.XXXXXX")" || { test_fail "could not create a run directory"; print_summary; exit_with_code; }
else
    mkdir -p "$LV_RUN_DIR" || { test_fail "could not create $LV_RUN_DIR"; print_summary; exit_with_code; }
fi
LV_RUN_DIR="$(cd "$LV_RUN_DIR" && pwd -P)"
case "$LV_RUN_DIR/" in
    "$(cd "$BASE_DIR" && pwd -P)/"*)
        test_fail "DXE_PERSIST_LIVE_RUN_DIR=$LV_RUN_DIR is inside the checkout; its logs hold NAS addresses and must stay outside the repository"
        print_summary
        exit_with_code
        ;;
esac
mkdir -p "$LV_RUN_DIR/logs" "$LV_RUN_DIR/state" "$LV_RUN_DIR/listings"
XDG_STATE_HOME="$LV_RUN_DIR/state"
export XDG_STATE_HOME

LV_DIR="$(persist_live_canary_dir)"
LV_LEAF="$(persist_live_leaf)"
LV_RECORD="$(persist_live_record_path)"
LV_OWNER=30033:30001
LV_ORIG="$DX_PERSIST_VOLUME"
LV_ROLLBACK="$(persist_migrate_live_rollback_volume)"
LV_BULK_MIB="$(persist_migrate_live_bulk_mib)"
LV_BULK_BYTES=$((LV_BULK_MIB * 1048576))
LV_INTERRUPT_DEADLINE="${DXE_PERSIST_LIVE_INTERRUPT_DEADLINE:-900}"
LV_STAMP0="$(date -u +%Y%m%dT%H%M%SZ)"
LV_TOKEN="dxe-live-$LV_STAMP0-$$"
LV_TOKEN2="dxe-live-changed-$LV_STAMP0-$$"
LV_RESULTS="$LV_RUN_DIR/results.txt"
LV_PROFILE_NAME="${DXE_CONFIG_ORIGIN_DX_CONTAINER_NAME:-}"
LV_PROFILE_NAME="${LV_PROFILE_NAME#profile:}"
[ -n "$LV_PROFILE_NAME" ] || LV_PROFILE_NAME="<canary profile>"
LV_CLEANUP_COMMAND="DXE_PERSIST_LIVE_CLEANUP_ONLY=1 DXE_PERSIST_LIVE_RUN_DIR=$LV_RUN_DIR DXE_PERSIST_LIVE_CANARY=$DX_CONTAINER_NAME ./bin/dx-profile $LV_PROFILE_NAME tests/run.sh --live --file tests/test_persist_migrate_live.sh"
LV_REAL=""
[ -z "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" ] || LV_REAL=1

echo "  canary guest:    $DX_CONTAINER_NAME (port $DX_SSH_PORT, image $DX_IMAGE)"
echo "  canary volumes:  $DX_NIX_VOLUME $LV_ORIG $DX_BOOTSTRAP_VOLUME, rollback $LV_ROLLBACK"
echo "  share directory: $LV_LEAF (the suite binds only $LV_DIR)"
echo "  bulk file:       $LV_BULK_MIB MiB"
echo "  run directory:   $LV_RUN_DIR (XDG_STATE_HOME=$XDG_STATE_HOME)"

# --- Recording, checks, fail-fast (WP7.1's helpers) ----------------------------
LV_SEQ=0
LV_RC=0
LV_OUT=""
LV_ERR=""
LV_CASE=""
LV_FAILURE=""
LV_FINDINGS=""
LV_ACTUAL=""
LV_CANON_LEAF=""
LV_FPR0=""
LV_SOCKET=no
LV_CREATED1=""
LV_MARKER1=""
LV_RECORD1=""
LV_BG_PID=""
LV_BG_OUT=""
LV_BG_ERR=""
LV_ASIDES=""

lv_case() {
    LV_CASE="$1"
    echo ""
    echo "--- $1 ---"
}

lv_ok() { test_pass "$LV_CASE: $1"; }

lv_bad() {
    test_fail "$LV_CASE: $1"
    LV_FAILURE="$LV_CASE: $1"
    return 1
}

lv_check() {
    local description="$1"
    shift
    if "$@"; then
        lv_ok "$description"
        return 0
    fi
    lv_bad "$description"
}

lv_finding() {
    test_fail "$LV_CASE: FINDING: $1"
    LV_FINDINGS="$LV_FINDINGS
  - $LV_CASE: $1"
    return 0
}

lv_result() { printf '%s=%s\n' "$1" "$2" >>"$LV_RESULTS"; }

# lv_run [--stdin FILE] LABEL [NAME=VALUE...] -- COMMAND [ARG...]
lv_run() {
    local stdin=/dev/null label base pair shown
    local pairs=()
    if [ "$1" = --stdin ]; then
        stdin="$2"
        shift 2
    fi
    label="$1"
    shift
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        pairs+=("$1")
        shift
    done
    [ "${1:-}" != -- ] || shift
    LV_SEQ=$((LV_SEQ + 1))
    base="$(printf '%s/logs/%03d-%s' "$LV_RUN_DIR" "$LV_SEQ" "$label")"
    LV_OUT="$base.out"
    LV_ERR="$base.err"
    shown="${pairs[*]+${pairs[*]} }$(basename "$1") ${*:2}"
    echo "  [$LV_SEQ] $label: ${shown:0:120}"
    LV_RC=0
    (
        for pair in "${pairs[@]+"${pairs[@]}"}"; do
            export "${pair?}"
        done
        "$@"
    ) >"$LV_OUT" 2>"$LV_ERR" <"$stdin" || LV_RC=$?
    return 0
}

# lv_run_bg LABEL -- COMMAND [ARG...]: lv_run in the background (LV_BG_PID);
# lv_bg_wait collects it into LV_RC, LV_OUT and LV_ERR.
lv_run_bg() {
    local label="$1" base
    shift
    [ "${1:-}" != -- ] || shift
    LV_SEQ=$((LV_SEQ + 1))
    base="$(printf '%s/logs/%03d-%s' "$LV_RUN_DIR" "$LV_SEQ" "$label")"
    LV_BG_OUT="$base.out"
    LV_BG_ERR="$base.err"
    echo "  [$LV_SEQ] $label (background): $(basename "$1") ${*:2}"
    ("$@") >"$LV_BG_OUT" 2>"$LV_BG_ERR" </dev/null &
    LV_BG_PID=$!
}

lv_bg_wait() {
    [ -n "$LV_BG_PID" ] || return 0
    LV_RC=0
    wait "$LV_BG_PID" || LV_RC=$?
    LV_BG_PID=""
    LV_OUT="$LV_BG_OUT"
    LV_ERR="$LV_BG_ERR"
}

lv_show_logs() {
    echo "    exit status: $LV_RC"
    echo "    --- last lines of $LV_OUT"
    tail -n 25 "$LV_OUT" 2>/dev/null | sed 's/^/    | /'
    echo "    --- last lines of $LV_ERR"
    tail -n 25 "$LV_ERR" 2>/dev/null | sed 's/^/    | /'
}

lv_rc_zero() { [ "$LV_RC" -eq 0 ] || { lv_show_logs; return 1; }; }
lv_rc_is() { [ "$LV_RC" -eq "$1" ] || { lv_show_logs; return 1; }; }
lv_out_has() { grep -Fq -- "$1" "$LV_OUT" || { lv_show_logs; return 1; }; }
lv_out_lacks() { ! grep -Fq -- "$1" "$LV_OUT" || { lv_show_logs; return 1; }; }
lv_err_has() { grep -Fq -- "$1" "$LV_ERR" || { lv_show_logs; return 1; }; }
lv_out_line() { grep -Fqx -- "$1" "$LV_OUT" || { lv_show_logs; return 1; }; }
lv_one_error() {
    local n
    n="$(grep -c '^Error:' "$LV_ERR" 2>/dev/null)" || true
    [ "${n:-0}" = 1 ] || { echo "    $n Error: lines"; lv_show_logs; return 1; }
}

lv_run_ok() {
    local description="$1"
    shift
    lv_run "$@"
    lv_check "$description" lv_rc_zero
}

lv_equal() {
    [ "$1" = "$2" ] && return 0
    echo "    expected: $(printf '%s' "$2" | tr '\n' '|')"
    echo "    actual:   $(printf '%s' "$1" | tr '\n' '|')"
    return 1
}

lv_has_line() { grep -Fqx -- "$2" <<<"$1"; }
lv_number() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
lv_timestamp_ok() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
    esac
    return 1
}

# lv_mode volume|host-path VOLUME: the configuration the next commands see,
# as the runbook has the user edit it in the profile.
lv_mode() {
    DX_PERSIST_STORAGE="$1"
    DX_PERSIST_VOLUME="$2"
    export DX_PERSIST_STORAGE DX_PERSIST_VOLUME
    echo "    (configuration now: DX_PERSIST_STORAGE=$1 DX_PERSIST_VOLUME=$2)"
}

# --- Remote facts (read-only) ----------------------------------------------
lv_probe() { dxe_runtime_call dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$DX_CONTAINER_NAME" 2>/dev/null; }
lv_stat() { persist_live_root_sh ro "$PERSIST_LIVE_SCRIPT_STAT" </dev/null 2>/dev/null; }
lv_marker_of() { printf '%s\n' "$1" | sed '1,4d'; }
lv_marker_now() { lv_marker_of "$(lv_probe)"; }
lv_entries_of() { printf '%s\n' "$1" | sed -n 's/^entry=//p'; }
lv_volume_state() {
    local state
    state="$(dxe_runtime_call dx_runtime_volume_state "$1" 2>/dev/null)" || :
    printf '%s\n' "${state:-unknown}" | sed -n '1p'
}
lv_volume_is() { [ "$(lv_volume_state "$2")" = "$1" ]; }
lv_container_exists() { dxe_runtime_call dx_runtime_container_exists "$DX_CONTAINER_NAME" >/dev/null 2>&1; }
lv_container_running() { dxe_runtime_call dx_runtime_container_running "$DX_CONTAINER_NAME" >/dev/null 2>&1; }
lv_container_stopped() { lv_container_exists && ! lv_container_running; }
lv_container_absent() {
    local list
    list="$(dxe_runtime_call dx_runtime_container_list -a 2>/dev/null)" || return 1
    ! printf '%s\n' "$list" | awk -v n="$DX_CONTAINER_NAME" '$1 == n { found = 1 } END { exit !found }'
}
lv_image_absent() {
    local list
    list="$(dxe_runtime_call dx_runtime_image_list 2>/dev/null)" || return 1
    ! printf '%s\n' "$list" | awk -v n="$DX_IMAGE" '$1 == n { found = 1 } END { exit !found }'
}
lv_image_present() { dxe_runtime_call dx_runtime_image_exists "$DX_IMAGE" >/dev/null 2>&1; }
lv_ensure_image() {
    lv_image_present && return 0
    lv_run create-image -- "$BIN_DIR/dx-create-image"
    lv_check "dx-create-image provides $DX_IMAGE for the suite's one-off containers" lv_rc_zero
}
lv_mount_line() {
    dxe_runtime_call dx_runtime_container_mounts "$DX_CONTAINER_NAME" 2>/dev/null | awk -F'|' '$3 == "/persist"'
}

# lv_check_bind: /persist is exactly one read-write bind of the leaf (WP7.1's
# check, with its FINDING for a source Docker reports resolved).
lv_check_bind() {
    local line source
    line="$(lv_mount_line)"
    if [ "$line" = "bind|$LV_LEAF|/persist|rw" ]; then
        LV_ACTUAL="$LV_LEAF"
        lv_ok "/persist is one read-write bind of $LV_LEAF"
        return 0
    fi
    case "$line" in
        *"
"*) : ;;
        "bind|/"*"/dxe/$DX_CONTAINER_NAME/persist|/persist|rw")
            source="${line#bind|}"
            source="${source%%|*}"
            if [ -z "$LV_ACTUAL" ] || [ "$LV_ACTUAL" = "$LV_LEAF" ]; then
                LV_ACTUAL="$source"
                lv_finding "Docker reports the /persist bind source as $source, not the configured $LV_LEAF (WP3.4: dx-status and dx-start-container would report a configured/actual mismatch)"
                return 0
            fi
            if [ "$source" = "$LV_ACTUAL" ]; then
                lv_ok "/persist is one read-write bind of $LV_LEAF (reported as $source, as before)"
                return 0
            fi
            ;;
    esac
    lv_equal "$line" "bind|${LV_ACTUAL:-$LV_LEAF}|/persist|rw"
    lv_bad "/persist is one read-write bind of $LV_LEAF"
}
lv_logs() { dxe_runtime_call dx_runtime_logs "$DX_CONTAINER_NAME" 2>&1; }
lv_log_count() {
    local logs n
    logs="$(lv_logs)"
    n="$(grep -cF -- "$1" <<<"$logs")" || true
    printf '%s\n' "${n:-0}"
}
lv_guest() { guest_bash "$1" 2>/dev/null | tr -d '\r' | sed -n '$p'; }
lv_host_fingerprint() {
    local endpoint host
    endpoint="$(dxe_runtime_call dx_ssh_endpoint 2>/dev/null)" || return 1
    host="${endpoint#*@}"
    [ -n "$host" ] || return 1
    ssh-keyscan -T 15 -p "$DX_SSH_PORT" -t ed25519 "$host" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk 'NR == 1 { print $2 }'
}
lv_record_text() { cat "$LV_RECORD" 2>/dev/null; }

# Everything a refusal must leave as it was: the probe report (state and
# marker bytes), the canary directory's facts, the four volumes, whether the
# container runs, and the record's bytes.
lv_state() {
    local report stat record=absent running=no
    report="$(lv_probe)" || report="probe-failed"
    stat="$(lv_stat)" || stat="stat-unavailable"
    [ ! -e "$LV_RECORD" ] || record="$(cksum <"$LV_RECORD")"
    if lv_container_running; then running=yes; fi
    printf '%s\n--\n%s\n--\nnix=%s persist=%s rollback=%s bootstrap=%s\nrunning=%s\nrecord=%s\n' \
        "$report" "$stat" "$(lv_volume_state "$DX_NIX_VOLUME")" "$(lv_volume_state "$LV_ORIG")" \
        "$(lv_volume_state "$LV_ROLLBACK")" "$(lv_volume_state "$DX_BOOTSTRAP_VOLUME")" "$running" "$record"
}
lv_state_unchanged() {
    local now
    now="$(lv_state)"
    [ "$now" = "$1" ] && return 0
    printf '%s\n' "$1" >"$LV_RUN_DIR/logs/state-before.txt"
    printf '%s\n' "$now" >"$LV_RUN_DIR/logs/state-after.txt"
    diff "$LV_RUN_DIR/logs/state-before.txt" "$LV_RUN_DIR/logs/state-after.txt" | sed 's/^/    /'
    return 1
}

# lv_expect_refusals ESSENTIAL...: dx-create-volumes and dx-start-container
# (guest stopped) each exit non-zero with exactly one Error line holding every
# ESSENTIAL, the guest stays stopped, and nothing changes.
lv_expect_refusals() {
    local before cmd essential
    before="$(lv_state)"
    for cmd in dx-create-volumes dx-start-container; do
        lv_run "$cmd-refused" -- "$BIN_DIR/$cmd"
        lv_check "$cmd refuses (non-zero)" test "$LV_RC" -ne 0 || { lv_show_logs; return 1; }
        lv_check "$cmd prints exactly one Error: line" lv_one_error || return 1
        for essential in "$@"; do
            lv_check "$cmd says: $essential" lv_err_has "$essential" || return 1
        done
        lv_check "the guest is still stopped after $cmd" lv_container_stopped || return 1
    done
    lv_check "nothing changed on the share, the volumes or the record" lv_state_unchanged "$before"
}

# --- Share changes (root one-off container; canary directory only) ---------
lv_share() {
    local label="$1"
    shift
    lv_run "share-$label" -- persist_live_root_sh rw "$@"
    lv_check "share change: $label" lv_rc_zero
}

# --- Listings (read-only; tests/lib's LIST script) ----------------------------
lv_listing_ok() { persist_migrate_live_listing_ok "$1"; }
lv_records() { persist_migrate_live_records "$1"; }
lv_records_without_apple() { persist_migrate_live_records_without_apple "$1"; }
# lv_record FILE PATH: the record for that exact (escaped) path.
lv_record() { LV_P="$2" awk -F'\t' '$NF == ENVIRON["LV_P"]' "$1"; }
lv_field() { printf '%s\n' "$1" | awk -F'\t' -v i="$2" '{ print $i }'; }

# lv_list_dir NAME SUBTREE: list <leaf>/SUBTREE into listings/NAME.
lv_list_dir() {
    local file="$LV_RUN_DIR/listings/$1"
    lv_run "list-$1" -- persist_migrate_live_dir_read "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" "persist/$2"
    cp "$LV_OUT" "$file" 2>/dev/null
    lv_check "the directory's $2 can be listed (read-only)" lv_rc_zero || return 1
    lv_check "the listing $1 is complete" lv_listing_ok "$file"
}

# lv_list_volume NAME VOLUME SUBTREE: list VOLUME's SUBTREE into listings/NAME
# (DQ6-checked with DX_PERSIST_VOLUME=VOLUME, mounted :ro).
lv_list_volume() {
    local file="$LV_RUN_DIR/listings/$1"
    lv_run "list-$1" "DX_PERSIST_VOLUME=$2" -- persist_migrate_live_volume_read "$2" "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" "$3"
    cp "$LV_OUT" "$file" 2>/dev/null
    lv_check "the volume $2's $3 can be listed (DQ6-checked, read-only)" lv_rc_zero || return 1
    lv_check "the listing $1 is complete" lv_listing_ok "$file"
}

# lv_same_records A B: two record streams (files) are identical.
lv_same_records() {
    cmp -s "$1" "$2" && return 0
    echo "    the listings differ (< expected, > actual):"
    diff "$1" "$2" | sed -n '1,30p' | sed 's/^/    /'
    return 1
}
lv_compare() {
    local description="$1" expected="$LV_RUN_DIR/listings/$2.cmp" actual="$LV_RUN_DIR/listings/$3.cmp"
    case "${4:-}" in
        drop-apple) lv_records_without_apple "$LV_RUN_DIR/listings/$2" >"$expected" ;;
        *) lv_records "$LV_RUN_DIR/listings/$2" >"$expected" ;;
    esac
    lv_records "$LV_RUN_DIR/listings/$3" >"$actual"
    lv_check "$description" lv_same_records "$expected" "$actual"
}

# --- Guest scripts -------------------------------------------------------------
lv_guest_script() {
    local script="$1"
    shift
    guest_bash "$(printf '%q ' bash -c "$script" "$@")"
}
lv_guest_check_ok() {
    [ "$LV_RC" -eq 0 ] && grep -Eq '^checks=[0-9]+ bad=0$' "$LV_OUT" && ! grep -q '^bad ' "$LV_OUT" && return 0
    grep '^bad ' "$LV_OUT" | sed 's/^/    /'
    lv_show_logs
    return 1
}
# lv_guest_check STATE DESCRIPTION
lv_guest_check() {
    lv_run "guest-check-$1" -- lv_guest_script "$PERSIST_MIGRATE_LIVE_GUEST_CHECK" dxe-live-check /persist "$1" \
        "$LV_TOKEN" "$LV_TOKEN2" "$LV_SOCKET" "$LV_BULK_BYTES"
    lv_check "$2" lv_guest_check_ok
}

lv_report() { sed -n "s/^$1: //p" "$LV_OUT" | sed -n '1p'; }
lv_report_all() { sed -n "s/^$1: //p" "$LV_OUT"; }
# shellcheck disable=SC2086 # one line per word, on purpose
lv_words_lines() { printf '%s\n' $1; }

lv_same_guest_identity() {
    lv_check "the SSH host key is the one the volume guest had (fingerprint)" lv_equal "$(lv_host_fingerprint)" "$LV_FPR0" || return 1
    lv_check "dx-ssh still connects under the accept-new pin" lv_equal "$(lv_guest 'echo pinned-ok')" pinned-ok
}

lv_stop() {
    echo ""
    echo "Stopped at the first failure: $LV_FAILURE"
    if [ -n "$LV_BG_PID" ]; then
        echo "  Waiting for the background dx-persist-migrate to finish (it ends with its copy)..."
        lv_bg_wait
        echo "  It exited $LV_RC (see $LV_ERR)."
    fi
    if [ -n "$LV_REAL" ]; then
        echo "The production inventory run touched nothing of the canary. Logs: $LV_RUN_DIR/logs"
        return 0
    fi
    if [ "${DXE_PERSIST_LIVE_KEEP_RUNNING:-}" = 1 ]; then
        echo "  DXE_PERSIST_LIVE_KEEP_RUNNING=1: the canary container is left as it is."
    elif lv_container_running; then
        lv_run stop-after-failure -- "$BIN_DIR/dx-stop-container"
        if [ "$LV_RC" -eq 0 ]; then
            echo "  Stopped the canary container $DX_CONTAINER_NAME."
        else
            echo "  WARNING: could not stop $DX_CONTAINER_NAME (see $LV_ERR); stop it by hand: ./bin/dx-profile $LV_PROFILE_NAME ./bin/dx-stop-container"
        fi
    fi
    echo "The canary is left in place for inspection. Logs: $LV_RUN_DIR/logs"
    echo "To remove it afterwards: $LV_CLEANUP_COMMAND"
}

# --- Cases --------------------------------------------------------------------
c_preflight() {
    local report vol
    lv_case "preflight"
    lv_mode volume "$LV_ORIG"
    lv_check "no container named $DX_CONTAINER_NAME exists yet (a leftover? run the cleanup mode first)" lv_container_absent || return 1
    for vol in "$DX_NIX_VOLUME" "$LV_ORIG" "$DX_BOOTSTRAP_VOLUME" "$LV_ROLLBACK"; do
        lv_check "volume $vol does not exist yet" lv_volume_is absent "$vol" || return 1
    done
    report="$(lv_probe)"
    lv_check "the read-only probe of the share root answers" test -n "$report" || return 1
    LV_CANON_LEAF="$(persist_live_kv root "$report")/dxe/$DX_CONTAINER_NAME/persist"
    echo "    canonical leaf (as the migration names it): $LV_CANON_LEAF"
    lv_check "the share root is mounted: sentinel $DX_PERSIST_HOST_MOUNT_SENTINEL present" lv_equal "$(persist_live_kv mounted "$report")" yes || return 1
    lv_check "the canary's /persist directory does not exist yet" lv_equal "$(persist_live_kv state "$report")" absent || return 1
    lv_check "no D-7 record exists for the canary in this run's state directory" test ! -e "$LV_RECORD"
}

c_volume_bring_up() {
    lv_case "volume bring-up"
    lv_run_ok "dx brings the canary up in volume mode (DX_PERSIST_STORAGE=volume over the profile)" dx-bring-up -- "$BIN_DIR/dx" true || return 1
    lv_check "dx-create-volumes ensured the persist volume" lv_out_has "Ensuring persist volume $LV_ORIG" || return 1
    lv_check "and used no host directory" lv_out_lacks "/persist directory" || return 1
    lv_check "the container is running" lv_container_running || return 1
    lv_check "/persist is the persist volume, read-write" lv_equal "$(lv_mount_line)" "volume|$LV_ORIG|/persist|rw" || return 1
    lv_run_ok "dx-status runs" status-volume -- "$BIN_DIR/dx-status" || return 1
    lv_check "dx-status: configured is the persist volume" lv_out_line "configured: $LV_ORIG" || return 1
    lv_check "dx-status: actual is the persist volume" lv_out_line "actual: $LV_ORIG" || return 1
    lv_check "dx-status reports no mismatch" lv_out_lacks "mismatch:" || return 1
    lv_check "volume mode created nothing on the share" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_check "and wrote no D-7 record" test ! -e "$LV_RECORD" || return 1
    LV_FPR0="$(lv_host_fingerprint)"
    lv_check "the guest's SSH host key fingerprint is readable" test -n "$LV_FPR0" || return 1
    echo "    host key: $LV_FPR0"
}

c_seed() {
    local bytes
    lv_case "seed"
    lv_run seed -- lv_guest_script "$PERSIST_MIGRATE_LIVE_GUEST_SEED" dxe-live-seed /persist "$LV_TOKEN" "$LV_BULK_MIB"
    lv_check "the guest seeds /persist (tree and $LV_BULK_MIB MiB bulk file)" lv_rc_zero || return 1
    lv_check "the seed reports success" grep -q '^seeded=ok ' "$LV_OUT" || { lv_show_logs; return 1; }
    LV_SOCKET="$(sed -n 's/^seeded=ok socket=\([a-z]*\) .*/\1/p' "$LV_OUT" | tr -d '\r' | sed -n '1p')"
    bytes="$(sed -n 's/^seeded=ok .* bulk_bytes=\([0-9]*\).*/\1/p' "$LV_OUT" | sed -n '1p')"
    lv_check "the bulk file has $LV_BULK_BYTES bytes" lv_equal "$bytes" "$LV_BULK_BYTES" || return 1
    if [ "$LV_SOCKET" = yes ]; then
        lv_ok "a socket was seeded (tmux leaves its socket file)"
    else
        LV_SOCKET=no
        echo "    (no socket could be seeded: tmux left none; the FIFO is the seeded special file)"
    fi
    lv_result socket_seeded "$LV_SOCKET"
    lv_guest_check seeded "the guest sees every seeded entry: links, special files, modes, odd names, both ._* files"
}

c_inventory() {
    local blockers seconds t0 t1 apple expected n
    lv_case "inventory"
    t0="$(date +%s)"
    lv_run inventory -- "$BIN_DIR/dx-persist-inventory"
    t1="$(date +%s)"
    seconds=$((t1 - t0))
    case "$LV_RC" in
        0) lv_ok "dx-persist-inventory exits 0: nothing blocks the migration" ;;
        3)
            blockers="$(grep -E '^rsync_check: refused|^target_room: no$|^rollback_room: no$' "$LV_OUT" | tr '\n' ';')"
            if [ -n "$blockers" ]; then
                lv_finding "dx-persist-inventory exits 3 naming a blocker: $blockers"
            else
                lv_show_logs
                lv_bad "dx-persist-inventory exit 3 names a blocker"
                return 1
            fi
            ;;
        *)
            lv_show_logs
            lv_bad "dx-persist-inventory exits 0 (or 3 with a named blocker)"
            return 1
            ;;
    esac
    lv_check "the report names the persist volume" lv_out_line "volume: $LV_ORIG" || return 1
    lv_check "size_kb holds at least the bulk file" test "$(lv_report size_kb)" -ge $((LV_BULK_MIB * 1024)) || { lv_show_logs; return 1; }
    lv_check "entries counts at least the seeded entries" test "$(lv_report entries)" -ge 37 || { lv_show_logs; return 1; }
    lv_check "hard_links counts at least the seeded group of three" test "$(lv_report hard_links)" -ge 3 || { lv_show_logs; return 1; }
    apple="$(lv_report_all appledouble)"
    expected="$(lv_words_lines "$PERSIST_MIGRATE_LIVE_SEED_APPLE")"
    lv_check "it lists exactly the two seeded ._* files (to rescue before the copy)" lv_equal "$apple" "$expected" || return 1
    lv_check "appledouble_count is 2" lv_out_line "appledouble_count: 2" || return 1
    lv_check "it lists the FIFO among the special files" lv_out_line "special: dxe-live-seed/fifo" || return 1
    if [ "$LV_SOCKET" = yes ]; then
        lv_check "and the socket" lv_out_line "special: dxe-live-seed/dxe-live.sock" || return 1
    fi
    n="$(grep -c '^special: ' "$LV_OUT")" || true
    lv_check "special_count matches the listed special files" lv_out_line "special_count: $n" || return 1
    lv_check "it names an rsync version" grep -Eq '^rsync_version: [0-9]+[.][0-9]+' "$LV_OUT" || { lv_show_logs; return 1; }
    lv_check "it reports acls and xattrs" grep -Eq '^acls: (none|unknown|present)$' "$LV_OUT" || { lv_show_logs; return 1; }
    lv_check "it wrote nothing: still no directory" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_check "and no record" test ! -e "$LV_RECORD" || return 1
    lv_result inventory_seconds "$seconds"
    lv_result inventory_size_kb "$(lv_report size_kb)"
    lv_result inventory_entries "$(lv_report entries)"
    lv_result inventory_rsync "$(lv_report rsync_version) $(lv_report rsync_check)"
    echo "    inventory took $seconds s; acls: $(lv_report acls), xattrs: $(lv_report xattrs), rsync $(lv_report rsync_version)"
}

c_stop_and_list() {
    local rec
    lv_case "stop and list"
    lv_run_ok "dx-stop-container stops the guest (runbook step 2)" stop-for-migrate -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    lv_list_volume L0-seed "$LV_ORIG" "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_volume L0-bulk "$LV_ORIG" "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L0-seed" ./fifo)"
    lv_check "the listing holds the FIFO" lv_equal "$(lv_field "$rec" 1)" p || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L0-seed" ./dangling)"
    lv_check "and the dangling symlink" lv_equal "$(lv_field "$rec" 1):$(lv_field "$rec" 9)" l:does-not-exist || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L0-seed" ./nested/hardlink-c)"
    lv_check "and the hard-link group across directories" lv_equal "$(lv_field "$rec" 6):$(lv_field "$rec" 8)" 3:./hardlink-a || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L0-seed" ./private/key)"
    lv_check "and dx's private key file, 0600, owned $LV_OWNER" lv_equal "$(lv_field "$rec" 2) $(lv_field "$rec" 3)" "600 $LV_OWNER" || return 1
    lv_check "and both ._* files" test "$(( $(lv_records "$LV_RUN_DIR/listings/L0-seed" | wc -l) - $(lv_records_without_apple "$LV_RUN_DIR/listings/L0-seed" | wc -l) ))" = 2 || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L0-bulk" "./$PERSIST_MIGRATE_LIVE_BLOB")"
    lv_check "the bulk file has $LV_BULK_BYTES bytes" lv_equal "$(lv_field "$rec" 4)" "$LV_BULK_BYTES"
}

c_migrate_interrupted() {
    local docker_bin watch_rc watch_out temp report marker stat rec
    lv_case "interrupted copy"
    docker_bin="$(dxe_runtime_call dx_runtime_docker_require_bin 2>/dev/null)" || docker_bin=""
    lv_check "the NAS's docker CLI path is known" test -n "$docker_bin" || return 1
    lv_run_bg migrate-interrupted -- "$BIN_DIR/dx-persist-migrate"
    lv_run interrupt -- persist_migrate_live_interrupt "$docker_bin" "$LV_CANON_LEAF" "$LV_INTERRUPT_DEADLINE"
    watch_rc="$LV_RC"
    watch_out="$LV_OUT"
    cp "$LV_OUT" "$LV_RUN_DIR/logs/interrupt-watcher.out" 2>/dev/null
    lv_bg_wait
    if [ "$watch_rc" -ne 0 ]; then
        echo "    the NAS-side watcher exited $watch_rc:"
        sed 's/^/    | /' "$watch_out" "${watch_out%.out}.err" 2>/dev/null
        case "$watch_rc" in
            3) lv_bad "the copy ended before rsync started on the $LV_BULK_MIB MiB file, so nothing was interrupted mid-copy; raise DXE_PERSIST_LIVE_BULK_MIB" ;;
            7) lv_bad "the NAS management account cannot list the destination's bulk directory, so the watcher cannot see the copy's progress (nothing was killed; the copy ran to its end)" ;;
            2) lv_bad "no copy container (canary volume, guest-volume rsync, /dst on $LV_CANON_LEAF) appeared, or rsync never reached the bulk file, within $LV_INTERRUPT_DEADLINE s; nothing was killed (see the migration's log: it may have refused or failed before copying)" ;;
            4) lv_bad "a docker call of the NAS-side watcher failed (ps, inspect or kill); see its log above" ;;
            5) lv_bad "the killed copy container did not go away within $LV_INTERRUPT_DEADLINE s (--rm); look at it on the NAS before going on" ;;
            6) lv_bad "more than one copy container matched (two copies into the canary directory at once?); the watcher touched none -- stop and inspect the NAS" ;;
            *) lv_bad "the NAS-side watcher found the copy container and killed it mid-copy (exit $watch_rc)" ;;
        esac
        return 1
    fi
    lv_ok "the NAS-side watcher found the one copy container and sent it SIGKILL while rsync wrote the bulk file"
    temp="$(sed -n 's/^interrupted=[0-9a-f]* temp=//p' "$watch_out" | sed -n '1p')"
    echo "    killed while rsync wrote $temp"
    lv_check "the killed copy container is gone (--rm)" grep -q '^gone=' "$watch_out" || return 1
    lv_check "dx-persist-migrate exits 1 after the interrupted copy" lv_rc_is 1 || return 1
    lv_check "it created the directory with the copying marker" lv_out_has "Creating $LV_CANON_LEAF with the marker copying..." || return 1
    lv_check "it started the copy" lv_out_has "Copying the persist volume $LV_ORIG into $LV_CANON_LEAF" || return 1
    lv_check "it says the copy stopped before it finished" lv_err_has "Error: the copy into $LV_CANON_LEAF stopped before it finished (rsync exit" || return 1
    lv_check "and how to resume" lv_err_has "Run dx-persist-migrate again to resume the copy." || return 1
    lv_check "with exactly one Error: line" lv_one_error || return 1
    report="$(lv_probe)"
    marker="$(lv_marker_of "$report")"
    LV_CREATED1="$(persist_live_kv created-at "$marker")"
    lv_check "the marker's created-at is a UTC timestamp" lv_timestamp_ok "$LV_CREATED1" || return 1
    lv_check "the marker stays copying, for this guest and the persist volume" \
        lv_equal "$marker" "$(persist_live_marker_text "$DX_CONTAINER_NAME" copying "$LV_ORIG" "$LV_CREATED1")" || return 1
    stat="$(lv_stat)"
    lv_check "the leaf is $LV_OWNER" lv_has_line "$stat" "leaf_owner=$LV_OWNER" || return 1
    lv_check "with mode 0755" lv_has_line "$stat" "leaf_mode=755" || return 1
    lv_list_dir dir1-bulk-partial "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/dir1-bulk-partial" "./$PERSIST_MIGRATE_LIVE_BLOB")"
    lv_check "the bulk file never completed: the interrupt landed mid-copy" test -z "$rec" || return 1
    echo "    the destination's bulk directory after the kill:"
    lv_records "$LV_RUN_DIR/listings/dir1-bulk-partial" | awk -F'\t' '{ print "      " $1 " " $4 " " $NF }'
    lv_check "no D-7 record before the verification" test ! -e "$LV_RECORD"
}

# lv_migrate_report_ok VOLUME APPLE...: the migration report (WP6.4 I).
lv_migrate_report_ok() {
    local volume="$1" copy verify expected
    shift
    lv_check "report: migrated: $LV_CANON_LEAF" lv_out_line "migrated: $LV_CANON_LEAF" || return 1
    lv_check "report: source_volume: $volume" lv_out_line "source_volume: $volume" || return 1
    lv_check "report: marker: ready" lv_out_line "marker: ready" || return 1
    lv_check "report: record: $LV_RECORD" lv_out_line "record: $LV_RECORD" || return 1
    copy="$(lv_report copy_seconds)"
    verify="$(lv_report verify_seconds)"
    lv_check "report: copy_seconds is a number ($copy)" lv_number "$copy" || return 1
    lv_check "report: verify_seconds is a number ($verify)" lv_number "$verify" || return 1
    lv_check "report: appledouble_dropped_count: $#" lv_out_line "appledouble_dropped_count: $#" || return 1
    if [ "$#" -eq 0 ]; then
        expected=none
    else
        expected="$(printf '%s\n' "$@")"
    fi
    lv_check "report: the dropped ._* files are listed" lv_equal "$(lv_report_all appledouble_dropped)" "$expected" || return 1
    lv_check "report: next names DX_PERSIST_STORAGE=host-path and dx-recreate" \
        grep -Eq '^next: .*DX_PERSIST_STORAGE=host-path.*dx-recreate' "$LV_OUT" || { lv_show_logs; return 1; }
    LV_LAST_COPY="$copy"
    LV_LAST_VERIFY="$verify"
}
LV_LAST_COPY=""
LV_LAST_VERIFY=""
LV_STATUS_OUT=""

c_migrate_resume() {
    local migrated expected stat
    lv_case "resumed copy"
    lv_run migrate-resume -- "$BIN_DIR/dx-persist-migrate"
    if [ "$LV_RC" -eq 3 ]; then
        lv_check "the resume says it resumes" lv_out_has "Resuming the interrupted copy into $LV_CANON_LEAF (marker copying)..." || return 1
        lv_list_dir dir1-bulk-after-resume "$PERSIST_MIGRATE_LIVE_BULK" || return 1
        if lv_records "$LV_RUN_DIR/listings/dir1-bulk-after-resume" | LV_P="./.$PERSIST_MIGRATE_LIVE_BLOB." awk -F'\t' \
            'index($NF, ENVIRON["LV_P"]) == 1 && length($NF) == length(ENVIRON["LV_P"]) + 6 { found = 1 } END { exit !found }'; then
            lv_finding "the resumed migration does not verify (exit 3): the killed rsync left its temp file ./$PERSIST_MIGRATE_LIVE_BULK/.$PERSIST_MIGRATE_LIVE_BLOB.XXXXXX in the destination, and the forward copy (no --delete) keeps it, so 'run it again' never succeeds after a hard kill (R35; runbook 11.4 covers only the marker's temp file)"
            lv_share temp-aside "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" "$PERSIST_MIGRATE_LIVE_BULK" "$PERSIST_MIGRATE_LIVE_BLOB" || return 1
            LV_ASIDES="$LV_ASIDES $PERSIST_MIGRATE_LIVE_TEMP_ASIDE"
            lv_result resume_finding "stale rsync temp file; moved aside and resumed again"
            lv_run migrate-resume-again -- "$BIN_DIR/dx-persist-migrate"
        else
            lv_show_logs
            lv_bad "the resumed migration verifies (exit 3 with no stale rsync temp file to explain it)"
            return 1
        fi
    fi
    lv_check "the resumed migration exits 0" lv_rc_zero || return 1
    lv_check "it resumed into the same directory" lv_out_has "Resuming the interrupted copy into $LV_CANON_LEAF (marker copying)..." || return 1
    lv_check "it created nothing new" lv_out_lacks "Creating $LV_CANON_LEAF" || return 1
    # shellcheck disable=SC2086 # the seeded ._* paths are one word each
    lv_migrate_report_ok "$LV_ORIG" $PERSIST_MIGRATE_LIVE_SEED_APPLE || return 1
    lv_result migrate1_copy_seconds "$LV_LAST_COPY"
    lv_result migrate1_verify_seconds "$LV_LAST_VERIFY"
    LV_MARKER1="$(lv_marker_now)"
    migrated="$(persist_live_kv migrated-at "$LV_MARKER1")"
    lv_check "migrated-at is a UTC timestamp" lv_timestamp_ok "$migrated" || return 1
    lv_check "the marker is ready, keeping the first run's created-at" \
        lv_equal "$LV_MARKER1" "$(persist_live_marker_text "$DX_CONTAINER_NAME" ready "$LV_ORIG" "$LV_CREATED1" "$migrated")" || return 1
    expected="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=migrate\ncreated-at=%s' "$DX_CONTAINER_NAME" "$DX_PERSIST_HOST_ROOT" "$LV_CREATED1")"
    lv_check "the D-7 record is exactly schema, guest, root, mode=migrate and the created-at" lv_equal "$(lv_record_text)" "$expected" || return 1
    lv_check "the record has mode 0600" lv_equal "$(file_mode "$LV_RECORD")" 600 || return 1
    LV_RECORD1="$(lv_record_text)"
    stat="$(lv_stat)"
    lv_check "the leaf is still $LV_OWNER 0755" lv_equal "$(printf '%s\n' "$stat" | grep -E '^leaf_(owner|mode)=')" "$(printf 'leaf_owner=%s\nleaf_mode=755' "$LV_OWNER")" || return 1
    lv_check "the marker is 0644" lv_has_line "$stat" "marker_mode=644" || return 1
    lv_check "with no temp file beside it" lv_equal "$(lv_entries_of "$stat" | grep -c '^\.dxe-persist-dir')" 1 || return 1
    lv_list_dir dir1-seed "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_dir dir1-bulk "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    lv_compare "the directory's seeded tree equals the volume's without the ._* files (types, modes, owners, sizes, mtimes, links, checksums, names)" L0-seed dir1-seed drop-apple || return 1
    lv_compare "the bulk file came across whole after the resume" L0-bulk dir1-bulk || return 1
    lv_check "the original volume is kept" lv_volume_is present "$LV_ORIG"
}

# lv_switched_to_dir: dx-recreate in host-path mode, confirmed (runbook 11.3 step 5).
lv_switched_to_dir() {
    local kept="$1"
    lv_run_ok "dx-recreate switches the guest to the directory" "recreate-to-dir" -- "$BIN_DIR/dx-recreate" true || return 1
    lv_check "it used the migrated directory as it was" lv_out_has "Using /persist directory $LV_LEAF (marker ready)" || return 1
    lv_check "it created nothing" lv_out_lacks "Creating /persist directory" || return 1
    lv_check_bind || return 1
    lv_check "the guest verified its mount and marker before using /persist" \
        test "$(lv_log_count "Verified host-path /persist for guest $DX_CONTAINER_NAME: a mount point with a ready .dxe-persist-dir.")" -ge 1 || return 1
    lv_run_ok "dx-status runs" status-dir -- "$BIN_DIR/dx-status" || return 1
    LV_STATUS_OUT="$LV_OUT"
    lv_check "dx-status: configured is the directory" lv_out_line "configured: $LV_LEAF" || return 1
    lv_check "dx-status: actual is the bind source Docker reports" lv_out_line "actual: $LV_ACTUAL" || return 1
    if [ "$LV_ACTUAL" = "$LV_LEAF" ]; then
        lv_check "dx-status reports no mismatch" lv_out_lacks "mismatch:" || return 1
    fi
    lv_check "dx-status lists the kept volume $kept" lv_out_line "kept volume: $kept" || return 1
    lv_same_guest_identity
}

c_switch_to_dir() {
    lv_case "switch to directory"
    lv_mode host-path "$LV_ORIG"
    lv_switched_to_dir "$LV_ORIG" || return 1
    lv_guest_check migrated "the guest sees the seeded data intact on the directory, and no ._* file" || return 1
    lv_list_dir dir1-seed-running "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_compare "booting the guest on the directory changed nothing in the seeded tree (owners and modes included)" dir1-seed dir1-seed-running || return 1
    lv_check "the marker is unchanged" lv_equal "$(lv_marker_now)" "$LV_MARKER1" || return 1
    lv_check "the record is unchanged" lv_equal "$(lv_record_text)" "$LV_RECORD1"
}

c_changes() {
    local rec
    lv_case "changes"
    lv_run changes -- lv_guest_script "$PERSIST_MIGRATE_LIVE_GUEST_CHANGES" dxe-live-changes /persist "$LV_TOKEN2"
    lv_check "the guest writes, overwrites, deletes and renames files on the directory" lv_rc_zero || return 1
    lv_check "the changes script reports success" grep -q '^changed=ok' "$LV_OUT" || { lv_show_logs; return 1; }
    lv_guest_check changed-dir "the guest sees its changes on the directory" || return 1
    lv_run_ok "dx-stop-container stops the guest (rollback step 1)" stop-for-rollback -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    lv_list_dir L1-seed "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_dir L1-bulk "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    rec="$(lv_record "$LV_RUN_DIR/listings/L1-seed" ./written-after-switch.txt)"
    lv_check "the directory holds the new file" test -n "$rec" || return 1
    lv_check "and no longer the deleted one" test -z "$(lv_record "$LV_RUN_DIR/listings/L1-seed" ./nested/to-delete.txt)" || return 1
    lv_check "and the new ._* file" test -n "$(lv_record "$LV_RUN_DIR/listings/L1-seed" ./._rollback-meta)" || return 1
    lv_compare "the bulk file is unchanged" L0-bulk L1-bulk
}

c_rollback() {
    local marker retired expected
    lv_case "rollback"
    lv_run rollback -- "$BIN_DIR/dx-persist-rollback" --volume "$LV_ROLLBACK"
    lv_check "dx-persist-rollback --volume $LV_ROLLBACK exits 0" lv_rc_zero || return 1
    lv_check "it created the new volume with this profile's labels" lv_out_has "Creating the volume $LV_ROLLBACK (this profile's persist labels)..." || return 1
    lv_check "report: rolled_back: $LV_CANON_LEAF" lv_out_line "rolled_back: $LV_CANON_LEAF" || return 1
    lv_check "report: volume: $LV_ROLLBACK" lv_out_line "volume: $LV_ROLLBACK" || return 1
    lv_check "report: original_volume: $LV_ORIG" lv_out_line "original_volume: $LV_ORIG" || return 1
    lv_check "report: marker: retired" lv_out_line "marker: retired" || return 1
    lv_check "report: copy_seconds is a number" lv_number "$(lv_report copy_seconds)" || return 1
    lv_check "report: verify_seconds is a number" lv_number "$(lv_report verify_seconds)" || return 1
    lv_check "report: the new ._* file was dropped and listed" lv_equal "$(lv_report_all appledouble_dropped)" "$PERSIST_MIGRATE_LIVE_CHANGES_APPLE" || return 1
    lv_check "report: appledouble_dropped_count: 1" lv_out_line "appledouble_dropped_count: 1" || return 1
    lv_check "report: next names DX_PERSIST_STORAGE=volume, DX_PERSIST_VOLUME=$LV_ROLLBACK and dx-recreate" \
        grep -Eq "^next: .*DX_PERSIST_STORAGE=volume.*DX_PERSIST_VOLUME=$LV_ROLLBACK.*dx-recreate" "$LV_OUT" || { lv_show_logs; return 1; }
    lv_result rollback_copy_seconds "$(lv_report copy_seconds)"
    lv_result rollback_verify_seconds "$(lv_report verify_seconds)"
    marker="$(lv_marker_now)"
    retired="$(persist_live_kv retired-at "$marker")"
    lv_check "retired-at is a UTC timestamp" lv_timestamp_ok "$retired" || return 1
    expected="$(persist_live_marker_text "$DX_CONTAINER_NAME" retired "$LV_ORIG" "$LV_CREATED1" "$(persist_live_kv migrated-at "$LV_MARKER1")" "$retired")"
    lv_check "the marker is retired, keeping source-volume, created-at and migrated-at" lv_equal "$marker" "$expected" || return 1
    lv_check "the D-7 record is untouched" lv_equal "$(lv_record_text)" "$LV_RECORD1" || return 1
    lv_check "the rollback volume exists" lv_volume_is present "$LV_ROLLBACK" || return 1
    lv_run rollback-volume-owned "DX_PERSIST_VOLUME=$LV_ROLLBACK" -- dxe_runtime_call dx_runtime_volume_owned "$LV_ROLLBACK" check
    lv_check "it carries this profile's DQ6 persist labels" lv_rc_zero || return 1
    lv_check "the original volume is kept" lv_volume_is present "$LV_ORIG"
}

c_switch_back() {
    lv_case "switch back"
    lv_mode volume "$LV_ROLLBACK"
    lv_run_ok "dx-recreate switches the guest to the rollback volume" recreate-to-rollback -- "$BIN_DIR/dx-recreate" true || return 1
    lv_check "it ensured the rollback volume" lv_out_has "Ensuring persist volume $LV_ROLLBACK" || return 1
    lv_check "and used no host directory" lv_out_lacks "/persist directory" || return 1
    lv_check "/persist is the rollback volume, read-write" lv_equal "$(lv_mount_line)" "volume|$LV_ROLLBACK|/persist|rw" || return 1
    lv_run_ok "dx-status runs" status-rollback -- "$BIN_DIR/dx-status" || return 1
    lv_check "dx-status: configured is the rollback volume" lv_out_line "configured: $LV_ROLLBACK" || return 1
    lv_check "dx-status: actual is the rollback volume" lv_out_line "actual: $LV_ROLLBACK" || return 1
    lv_check "dx-status reports no mismatch" lv_out_lacks "mismatch:" || return 1
    lv_same_guest_identity || return 1
    lv_guest_check changed-volume "the guest sees the write, overwrite, delete and renames made on the directory, and not the new ._* file" || return 1
    lv_run_ok "dx-stop-container stops the guest" stop-after-rollback -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    lv_list_volume rb-seed "$LV_ROLLBACK" "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_volume rb-bulk "$LV_ROLLBACK" "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    lv_compare "the rollback volume's tree equals the directory's at rollback time, without the ._* file" L1-seed rb-seed drop-apple || return 1
    lv_compare "the rollback volume's bulk file is whole" L0-bulk rb-bulk || return 1
    lv_list_volume orig-seed-after "$LV_ORIG" "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_volume orig-bulk-after "$LV_ORIG" "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    lv_compare "the ORIGINAL volume is unchanged since before the migration (its ._* files too)" L0-seed orig-seed-after || return 1
    lv_compare "and so is its bulk file" L0-bulk orig-bulk-after
}

c_retired_refused() {
    lv_case "retired refused"
    lv_mode host-path "$LV_ROLLBACK"
    lv_check "the probe reads a retired marker" lv_equal "$(persist_live_kv state "$(lv_marker_now)")" retired || return 1
    lv_expect_refusals "$LV_LEAF is marked retired" || return 1
    lv_mode volume "$LV_ROLLBACK"
}

c_retired_aside() {
    local stamp
    lv_case "retired aside"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    lv_share "retired-aside" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" "$DX_CONTAINER_NAME" "$stamp" || return 1
    LV_ASIDES="$LV_ASIDES $PERSIST_MIGRATE_LIVE_RETIRED_PREFIX$stamp"
    lv_result retired_aside "$LV_DIR/$PERSIST_MIGRATE_LIVE_RETIRED_PREFIX$stamp"
    lv_check "no directory is left where the tooling looks" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_check "the record still exists (it refuses an empty replacement until migrated again)" test -f "$LV_RECORD"
}

c_migrate_again() {
    local marker created migrated expected
    lv_case "migrate again"
    lv_run migrate-again -- "$BIN_DIR/dx-persist-migrate"
    lv_check "dx-persist-migrate from the rollback volume exits 0" lv_rc_zero || return 1
    lv_check "it created a fresh directory" lv_out_has "Creating $LV_CANON_LEAF with the marker copying..." || return 1
    lv_check "it did not resume anything" lv_out_lacks "Resuming" || return 1
    lv_migrate_report_ok "$LV_ROLLBACK" || return 1
    lv_result migrate2_copy_seconds "$LV_LAST_COPY"
    lv_result migrate2_verify_seconds "$LV_LAST_VERIFY"
    marker="$(lv_marker_now)"
    created="$(persist_live_kv created-at "$marker")"
    migrated="$(persist_live_kv migrated-at "$marker")"
    lv_check "the new marker's times are UTC timestamps" lv_timestamp_ok "$created" || return 1
    lv_check "and migrated-at too" lv_timestamp_ok "$migrated" || return 1
    lv_check "the fresh directory's marker is ready from the rollback volume" \
        lv_equal "$marker" "$(persist_live_marker_text "$DX_CONTAINER_NAME" ready "$LV_ROLLBACK" "$created" "$migrated")" || return 1
    expected="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=migrate\ncreated-at=%s' "$DX_CONTAINER_NAME" "$DX_PERSIST_HOST_ROOT" "$created")"
    lv_check "the D-7 record names the new migration" lv_equal "$(lv_record_text)" "$expected" || return 1
    LV_MARKER1="$marker"
    LV_RECORD1="$(lv_record_text)"
    lv_list_dir dir2-seed "$PERSIST_MIGRATE_LIVE_SEED" || return 1
    lv_list_dir dir2-bulk "$PERSIST_MIGRATE_LIVE_BULK" || return 1
    lv_compare "the fresh directory's tree equals the rollback volume's" rb-seed dir2-seed || return 1
    lv_compare "and its bulk file is whole" L0-bulk dir2-bulk
}

c_switch_again() {
    lv_case "switch again"
    lv_mode host-path "$LV_ROLLBACK"
    lv_switched_to_dir "$LV_ROLLBACK" || return 1
    lv_check "the original volume $LV_ORIG is still kept" lv_volume_is present "$LV_ORIG" || return 1
    if ! grep -Fqx "kept volume: $LV_ORIG" "$LV_STATUS_OUT" 2>/dev/null; then
        echo "    (note: dx-status lists only $LV_ROLLBACK as kept now; the original $LV_ORIG is no longer named by the profile or the marker)"
        lv_result original_volume_unlisted yes
    fi
    lv_guest_check changed-volume "the guest sees the rolled-back data on the fresh directory" || return 1
    lv_check "the marker is unchanged" lv_equal "$(lv_marker_now)" "$LV_MARKER1" || return 1
    lv_check "the record is unchanged" lv_equal "$(lv_record_text)" "$LV_RECORD1"
}

c_final_cleanup() {
    local stamp docker_bin base_ref vol
    lv_case "final cleanup"
    # The profile's own values: in host-path mode dx-factory-reset keeps every
    # persist volume, which are then deleted one by one, by exact name.
    lv_mode host-path "$LV_ORIG"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    lv_bg_wait
    if lv_container_running; then
        lv_run_ok "dx-stop-container stops the guest" stop-for-cleanup -- "$BIN_DIR/dx-stop-container" || return 1
    fi
    lv_check "the share root answers the probe" test -n "$(lv_probe)" || return 1
    lv_ensure_image || return 1
    if lv_stat >/dev/null; then
        lv_share "leaf-retire-$stamp" "$PERSIST_LIVE_SCRIPT_RETIRE" "$stamp" || return 1
    else
        echo "    $LV_DIR cannot be bound (no canary directory on the share); nothing to move aside"
    fi
    lv_check "no canary directory is left where the tooling looks" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_run_ok "dx-factory-reset --force removes the canary's container, image, nix and bootstrap volumes and keys" factory-reset-cleanup -- "$BIN_DIR/dx-factory-reset" --force || return 1
    for vol in "$LV_ORIG" "$LV_ROLLBACK"; do
        if lv_volume_is present "$vol"; then
            lv_run_ok "the canary volume $vol is deleted by exact name (DQ6 ownership checked)" "volume-delete-$vol" \
                "DX_PERSIST_VOLUME=$vol" -- dxe_runtime_call dx_runtime_volume_delete "$vol" || return 1
        fi
    done
    rm -f -- "$LV_RECORD"
    lv_check "the canary's D-7 record is deleted" test ! -e "$LV_RECORD" || return 1
    lv_check "no canary container is left" lv_container_absent || return 1
    lv_check "no canary image is left" lv_image_absent || return 1
    for vol in "$DX_NIX_VOLUME" "$LV_ORIG" "$DX_BOOTSTRAP_VOLUME" "$LV_ROLLBACK"; do
        lv_check "no volume $vol is left" lv_volume_is absent "$vol" || return 1
    done
    docker_bin="$(dxe_runtime_call dx_runtime_docker_require_bin 2>/dev/null)" || docker_bin=""
    [ -n "$docker_bin" ] || docker_bin=docker
    base_ref="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "${DX_CONTEXT_DIR:-$BASE_DIR/container/dx-nixos-26.05}/Containerfile" | sed -n '1p')"
    echo ""
    echo "  Nothing on the NAS was deleted. The canary's directory $LV_DIR now holds:"
    echo "    $PERSIST_LIVE_REMOVED_PREFIX$stamp (the last leaf)${LV_ASIDES:+, and from this run:$LV_ASIDES}"
    echo "  (plus whatever earlier runs moved aside there). Its files belong to root and $LV_OWNER, so remove"
    echo "  the whole canary directory by hand, as root, after a last look:"
    echo "    ssh $DX_REMOTE_HOST \"$docker_bin run --rm --network none --user 0:0 --mount type=bind,source=$DX_PERSIST_HOST_ROOT/dxe,target=/dxe --entrypoint ls $base_ref -la /dxe/$DX_CONTAINER_NAME\""
    echo "    ssh $DX_REMOTE_HOST \"$docker_bin run --rm --network none --user 0:0 --mount type=bind,source=$DX_PERSIST_HOST_ROOT/dxe,target=/dxe --entrypoint rm $base_ref -rf -- /dxe/$DX_CONTAINER_NAME\""
    echo "  The run directory $LV_RUN_DIR (logs, listings, results, SSH pins) is kept for the record; delete it when done."
}

c_real_inventory() {
    local t0 t1 seconds blockers file key
    lv_case "production inventory"
    echo "    read-only: dx-persist-inventory of $PERSIST_MIGRATE_LIVE_REAL_GUEST through the production profile '$PERSIST_MIGRATE_LIVE_REAL_PROFILE'"
    echo "    (nothing of $PERSIST_MIGRATE_LIVE_REAL_GUEST is stopped, started or written; the canary is not touched)"
    t0="$(date +%s)"
    lv_run real-inventory -- persist_migrate_live_real_inventory "$PERSIST_MIGRATE_LIVE_REAL_PROFILE" "$DX_PERSIST_HOST_ROOT" "$BIN_DIR/dx-persist-inventory"
    t1="$(date +%s)"
    seconds=$((t1 - t0))
    case "$LV_RC" in
        0) lv_ok "the production inventory completes (exit 0) in $seconds s" ;;
        3)
            blockers="$(grep -E '^rsync_check: refused|^target_room: no$|^rollback_room: no$' "$LV_OUT" | tr '\n' ';')"
            if [ -z "$blockers" ]; then
                lv_show_logs
                lv_bad "the production inventory's exit 3 names a blocker"
                return 1
            fi
            lv_finding "the production inventory names a blocker for the real migration: $blockers"
            ;;
        *)
            lv_show_logs
            lv_bad "the production inventory completes (exit 0, or 3 with a named blocker)"
            return 1
            ;;
    esac
    lv_check "it names $PERSIST_MIGRATE_LIVE_REAL_GUEST's persist volume" grep -q '^volume: ' "$LV_OUT" || { lv_show_logs; return 1; }
    file="$LV_RUN_DIR/real-inventory.txt"
    {
        printf 'measured_seconds=%s\n' "$seconds"
        printf 'measures=the dx-persist-inventory run only (no manifest pass)\n'
        for key in volume size_kb entries hard_links appledouble_count special_count acls xattrs rsync_version rsync_check target_free_kb target_room rollback_free_kb rollback_room; do
            printf '%s=%s\n' "$key" "$(lv_report "$key")"
        done
    } >"$file"
    echo "    recorded (private, outside the repository): $file"
    sed 's/^/      /' "$file"
}

if [ -n "$LV_REAL" ]; then
    LV_CASES="c_real_inventory"
else
    LV_CASES="c_preflight c_volume_bring_up c_seed c_inventory c_stop_and_list c_migrate_interrupted c_migrate_resume c_switch_to_dir c_changes c_rollback c_switch_back c_retired_refused c_retired_aside c_migrate_again c_switch_again"
    if [ "${DXE_PERSIST_LIVE_KEEP:-}" != 1 ]; then
        LV_CASES="$LV_CASES c_final_cleanup"
    fi
    if [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" = 1 ]; then
        LV_CASES="c_final_cleanup"
    fi
    if [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" != 1 ]; then
        echo "  Expected duration: one full guest bootstrap on the NAS, the $LV_BULK_MIB MiB seed, three or"
        echo "  four copies and verifications of it, four recreates -- typically 45 to 120 minutes."
    fi
fi
lv_result started "$LV_STAMP0"
for lv_case_fn in $LV_CASES; do
    if ! "$lv_case_fn"; then
        [ -n "$LV_FAILURE" ] || LV_FAILURE="$LV_CASE"
        lv_stop
        break
    fi
done
lv_result finished "$(date -u +%Y%m%dT%H%M%SZ)"
if [ -z "$LV_FAILURE" ] && [ -z "$LV_REAL" ] && [ "${DXE_PERSIST_LIVE_KEEP:-}" = 1 ] && [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" != 1 ]; then
    echo "DXE_PERSIST_LIVE_KEEP=1: the canary is left in place. To remove it: $LV_CLEANUP_COMMAND"
fi
if [ -n "$LV_FINDINGS" ]; then
    echo ""
    echo "Findings (each recorded as a failure; the run went on past them):$LV_FINDINGS"
fi
echo ""
echo "Results ($LV_RESULTS):"
sed 's/^/  /' "$LV_RESULTS" 2>/dev/null

print_summary
exit_with_code
