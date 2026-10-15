#!/bin/bash
# tier: live
# bash32: no
# WP7.1 (plans/do; spec section 9 W3; R15-R18, R21, R24-R28, R39): /persist
# host-path storage, LIVE, on a disposable QNAP guest.
#
# This suite talks to a real NAS and destroys and resets the guest it runs on.
# It runs only when ALL of these hold, and otherwise makes no remote call:
#   1. tests/run.sh --live (SKIP_INTEGRATION=false), with a profile that is
#      not the default guest (tests/test_helpers.sh's live_tail_enabled);
#   2. DXE_PERSIST_LIVE_CANARY is set (unset: the suite SKIPS, so a plain
#      `tests/run.sh --live --tier live` sweep with dx-test is unaffected);
#   3. persist_live_guard (tests/lib/persist-live.sh) accepts the profile:
#      DXE_PERSIST_LIVE_CANARY equals DX_CONTAINER_NAME, the name is a canary
#      name (^dx-[a-z0-9-]*canary[a-z0-9-]*$, never dx-host, dx-test or
#      dx-qnap), DX_RUNTIME=docker-ssh, DX_PERSIST_STORAGE=host-path, a
#      normalised DX_PERSIST_HOST_ROOT, canary-named volumes, image and key
#      pair, a non-default SSH port, restart policy no, usage service off and
#      a mount sentinel. A refusal exits non-zero before any remote call.
#
#   DXE_PERSIST_LIVE_CANARY=<canary name> \
#     ./bin/dx-profile <canary profile> tests/run.sh --live \
#     --file tests/test_persist_host_dir_live.sh
#
# Optional: DXE_PERSIST_LIVE_RUN_DIR=<dir outside the checkout> (logs, the
# isolated XDG_STATE_HOME holding the canary's D-7 record and SSH pins, the
# dx-backup mirror; default: a new mktemp directory), DXE_PERSIST_LIVE_SKIP_DX_AI=1
# (do not install the optional AI tools for R28; that part is then reported
# as SKIP), DXE_PERSIST_LIVE_KEEP=1 (skip the final cleanup),
# DXE_PERSIST_LIVE_KEEP_RUNNING=1 (after a failure, do not stop the canary
# container), DXE_PERSIST_LIVE_CLEANUP_ONLY=1 (run only the final cleanup;
# pass the same DXE_PERSIST_LIVE_RUN_DIR so the canary's record is found).
#
# Behaviour:
#   - Fail-fast: the suite stops at the first failing check, puts back what
#     the interrupted case had moved (the leaf, the marker, the leaf's mode,
#     the record), stops the canary container (unless
#     DXE_PERSIST_LIVE_KEEP_RUNNING=1) so a failed unattended run never leaves
#     it running, leaves the rest of the canary in place for inspection and
#     prints the cleanup-only command. Each check prints one PASS/FAIL line.
#   - Three kinds of check are FINDINGS instead: recorded as a failure
#     ("FINDING: ...", listed again at the end) but the run goes on, so the
#     later cases and the final cleanup still run. They are the gaps this run
#     is expected to measure:
#       * the NAS operations case (du and the marker's temp file + mv run as
#         the management account, uid 1000, against a 30033:30001 0755 leaf
#         that holds root-only etc/ssh);
#       * the dx-ai checks of the /nix recovery case (R28);
#       * the /persist bind source. The checks compare Docker's reported
#         source with the CONFIGURED path <root>/dxe/<canary>/persist. A QTS
#         share root is normally a symlink into its pool's data path; if
#         Docker reports the resolved path, that is a WP3.4 finding (dx-status
#         and dx-start-container compare the configured path with it, so they
#         report a configured/actual mismatch), not a suite bug: it is
#         recorded once and the run continues with the reported path. Any
#         other bind shape still stops the run.
#   - Everything the suite changes on the share it changes from a root
#     one-off container whose only bind is the canary's own directory
#     <root>/dxe/<canary> (persist_live_root_sh), with the fixed in-container
#     scripts of tests/lib/persist-live.sh: the leaf, its aside copy, the
#     saved marker. It never deletes anything on the NAS recursively: the
#     final cleanup moves the leaf aside and prints the manual removal.
#   - Every local file it writes is under the run directory; XDG_STATE_HOME
#     points there, so the canary's D-7 record never touches the operator's
#     own state directory.
#
# Cases, in order (each name is its PASS/FAIL prefix):
#   preflight               no canary container or volume yet; the share
#                           root resolves and its sentinel is present; the
#                           canary directory and record do not exist.
#   new-guest refusals      dx-create-volumes with a sentinel that does not
#                           exist (the share is "not mounted") and with an
#                           empty sentinel: one Error line each, and nothing
#                           created (directory, volumes, record).
#   creation                dx-create-volumes (the step of the `dx` chain that
#                           creates): leaf 30033:30001 0755 holding only a
#                           0644 marker (schema/guest/state=ready/created-at)
#                           and no temp file; the D-7 record (0600, mode=create,
#                           the marker's created-at); nix and bootstrap volumes
#                           only, never the persist volume.
#   record backfill         a ready directory without a record: dx-create-volumes
#                           writes it back (mode=backfill), nothing else.
#   bring-up                `dx true`: one rw bind of the leaf at /persist, the
#                           guest's own "Verified host-path" line, dx's ids are
#                           30033:30001, dx-status configured == actual; the
#                           SSH host key fingerprint and an application-state
#                           file in /persist are recorded.
#   stop/start, recreate    both keep the bind, the application state, the
#                           host key (fingerprint and the accept-new pin), the
#                           marker and the record (R24).
#   mismatch                with DX_PERSIST_STORAGE=volume, dx-status reports
#                           configured, actual and the mismatch, and
#                           dx-start-container warns naming dx-recreate; nothing
#                           changes (R21).
#   backup/restore          dx-backup mirrors a file from /persist; after it is
#                           deleted in the guest, dx-restore puts it back (R39).
#   refusals (guest stopped; each restored afterwards; dx-create-volumes and
#   dx-start-container both refuse with one Error line, nothing changes, the
#   guest stays stopped):
#                           missing directory (also with an unmounted
#                           sentinel: the mount hint), symlinked leaf, marker
#                           for another guest, marker copying, marker retired,
#                           non-empty unmarked directory, empty directory with
#                           the old persist volume (then a wrong-guest
#                           DX_PERSIST_FRESH_START is refused, and the right one
#                           marks it ready: root:root -> 30033:30001 proves the
#                           root container's chown; the volume is kept).
#   restart                 dx-start-container works again; dx-status lists the
#                           kept persist volume (R26).
#   guest self-check        docker start straight through the runtime (as a
#                           restart policy does) with the marker hidden, then
#                           with a marker for another guest: the guest logs the
#                           WP4.5 refusal and stops itself before touching
#                           /persist (the leaf keeps the 0751 mode the suite gave
#                           it; setup_persist would reset it to 0755); with the
#                           leaf missing, docker start itself fails and creates
#                           nothing (--mount, R19).
#   R28 preparation         dx-ai installs the optional AI tools, whose profile
#                           lives in /persist and points into /nix (SKIP with
#                           the reason if they cannot be installed).
#   factory reset           dx-factory-reset --force removes container, image,
#                           nix and bootstrap volumes and the key pair, and
#                           keeps the directory, the persist volume and the
#                           record, printing their removal steps (R25, R26).
#   reuse after reset       `dx true` reuses the directory (no creation), with
#                           the same marker, record, application state, ids and
#                           host key (R27).
#   /nix recovery           on the new /nix, Home Manager tools run and the
#                           dx-ai profile in /persist resolves into the store
#                           again with codex working, with no manual step
#                           (R28). The dx-ai checks are FINDINGS on failure.
#   destroy volumes         dx-destroy then dx-destroy-volumes --force remove
#                           nix and bootstrap only (R25, R26).
#   NAS operations          the management-account operations the unit
#                           transcripts record: host_dir_usage, host_dir_free
#                           and host_dir_marker_write (same bytes; no temp
#                           file left) work on the real share (FINDINGS on
#                           failure; see Behaviour).
#   final cleanup           leaf moved aside to persist.dxe-live-removed-<UTC>,
#                           dx-factory-reset --force, the persist volume
#                           deleted (DQ6-checked), the record deleted; nothing
#                           named for the canary is left but that directory,
#                           whose manual removal command is printed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-live.sh
source "$SCRIPT_DIR/lib/persist-live.sh"
BIN_DIR="$BASE_DIR/bin"

test_section "WP7.1: /persist host-path storage, live on a disposable QNAP guest"

LV_INVOCATION="DXE_PERSIST_LIVE_CANARY=<canary name> ./bin/dx-profile <canary profile> tests/run.sh --live --file tests/test_persist_host_dir_live.sh"

# --- Gates: no remote call before all three pass ----------------------------
if ! live_tail_enabled; then
    [ -n "$DXE_LIVE_TAIL_REFUSED" ] || test_skip "Live /persist host-path suite skipped (SKIP_INTEGRATION is not false); run it with: $LV_INVOCATION"
    print_summary
    exit_with_code
fi
if [ -z "${DXE_PERSIST_LIVE_CANARY:-}" ]; then
    test_skip "Live /persist host-path suite not opted in: set DXE_PERSIST_LIVE_CANARY to the canary profile's DX_CONTAINER_NAME ($LV_INVOCATION)"
    print_summary
    exit_with_code
fi
if ! persist_live_guard; then
    test_fail "the live /persist host-path suite refuses this profile (the Refusing: lines above); nothing was contacted"
    print_summary
    exit_with_code
fi

LV_RUN_DIR="${DXE_PERSIST_LIVE_RUN_DIR:-}"
if [ -z "$LV_RUN_DIR" ]; then
    dxe_test_mktemp_dir LV_RUN_DIR "${TMPDIR:-/tmp}/dxe-persist-live.XXXXXX"
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
mkdir -p "$LV_RUN_DIR/logs" "$LV_RUN_DIR/state" "$LV_RUN_DIR/backup"
XDG_STATE_HOME="$LV_RUN_DIR/state"
export XDG_STATE_HOME

LV_DIR="$(persist_live_canary_dir)"
LV_LEAF="$(persist_live_leaf)"
LV_RECORD="$(persist_live_record_path)"
LV_OWNER=30033:30001
LV_TOKEN="dxe-live-$(date -u +%Y%m%dT%H%M%SZ)-$$"
LV_OTHER_GUEST=dx-live-other-canary
LV_WRONG_OVERRIDE=dx-live-not-this-guest
LV_BOGUS_SENTINEL="dxe-live-no-such-sentinel-$$"
LV_PROFILE_NAME="${DXE_CONFIG_ORIGIN_DX_CONTAINER_NAME:-}"
LV_PROFILE_NAME="${LV_PROFILE_NAME#profile:}"
[ -n "$LV_PROFILE_NAME" ] || LV_PROFILE_NAME="<canary profile>"
LV_CLEANUP_COMMAND="DXE_PERSIST_LIVE_CLEANUP_ONLY=1 DXE_PERSIST_LIVE_RUN_DIR=$LV_RUN_DIR DXE_PERSIST_LIVE_CANARY=$DX_CONTAINER_NAME ./bin/dx-profile $LV_PROFILE_NAME tests/run.sh --live --file tests/test_persist_host_dir_live.sh"

echo "  canary guest:    $DX_CONTAINER_NAME (port $DX_SSH_PORT, image $DX_IMAGE)"
echo "  canary volumes:  $DX_NIX_VOLUME $DX_PERSIST_VOLUME $DX_BOOTSTRAP_VOLUME"
echo "  share directory: $LV_LEAF (the suite binds only $LV_DIR)"
echo "  run directory:   $LV_RUN_DIR (XDG_STATE_HOME=$XDG_STATE_HOME)"

# --- Recording, checks, fail-fast ------------------------------------------
LV_SEQ=0
LV_RC=0
LV_OUT=""
LV_ERR=""
LV_CASE=""
LV_FAILURE=""
LV_INFLIGHT=""
LV_MARKER0=""
LV_RECORD0=""
LV_FPR0=""
LV_CREATED_AT=""
LV_FACTS0=""
LV_DX_AI=""
LV_DX_AI_REASON=""
LV_FINDINGS=""
LV_ACTUAL=""

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

# lv_check DESCRIPTION COMMAND [ARG...]: one PASS/FAIL line; status of COMMAND.
lv_check() {
    local description="$1"
    shift
    if "$@"; then
        lv_ok "$description"
        return 0
    fi
    lv_bad "$description"
}

# lv_finding DESCRIPTION: a known, expected gap this run exists to surface. It
# is recorded as a failure ("FINDING: ...") and listed at the end, but the run
# goes on, so the later cases and the final cleanup still run. Used only where
# the header says so; every other check stops the run.
lv_finding() {
    test_fail "$LV_CASE: FINDING: $1"
    LV_FINDINGS="$LV_FINDINGS
  - $LV_CASE: $1"
    return 0
}

# lv_check_or_finding DESCRIPTION COMMAND [ARG...]: lv_check, except that a
# failure is a FINDING. Always returns 0.
lv_check_or_finding() {
    local description="$1"
    shift
    if "$@"; then
        lv_ok "$description"
    else
        lv_finding "$description"
    fi
    return 0
}

# lv_run [--stdin FILE] LABEL [NAME=VALUE...] -- COMMAND [ARG...]
# Runs COMMAND (an entry point or a shell function) in a subshell with the
# NAME=VALUE pairs exported, stdout and stderr in the run directory's logs.
# Sets LV_RC, LV_OUT and LV_ERR (the two log paths). Always returns 0.
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

lv_show_logs() {
    echo "    exit status: $LV_RC"
    echo "    --- last lines of $LV_OUT"
    tail -n 25 "$LV_OUT" 2>/dev/null | sed 's/^/    | /'
    echo "    --- last lines of $LV_ERR"
    tail -n 25 "$LV_ERR" 2>/dev/null | sed 's/^/    | /'
}

lv_rc_zero() { [ "$LV_RC" -eq 0 ] || { lv_show_logs; return 1; }; }
lv_rc_nonzero() { [ "$LV_RC" -ne 0 ] || { lv_show_logs; return 1; }; }
lv_out_has() { grep -Fq -- "$1" "$LV_OUT" || { lv_show_logs; return 1; }; }
lv_out_lacks() { ! grep -Fq -- "$1" "$LV_OUT" || { lv_show_logs; return 1; }; }
lv_err_has() { grep -Fq -- "$1" "$LV_ERR" || { lv_show_logs; return 1; }; }
lv_one_error() {
    local n
    n="$(grep -c '^Error:' "$LV_ERR" 2>/dev/null)" || true
    [ "${n:-0}" = 1 ] || { echo "    $n Error: lines"; lv_show_logs; return 1; }
}

# lv_run_ok DESCRIPTION LABEL [NAME=VALUE...] -- COMMAND...: run, expect status 0.
lv_run_ok() {
    local description="$1"
    shift
    lv_run "$@"
    lv_check "$description" lv_rc_zero
}

# lv_wait_until TIMEOUT INTERVAL COMMAND [ARG...]: poll until COMMAND succeeds.
lv_wait_until() {
    local timeout="$1" interval="$2" waited=0
    shift 2
    while :; do
        if "$@"; then return 0; fi
        [ "$waited" -lt "$timeout" ] || return 1
        sleep "$interval"
        waited=$((waited + interval))
    done
}

lv_equal() {
    [ "$1" = "$2" ] && return 0
    echo "    expected: $(printf '%s' "$2" | tr '\n' '|')"
    echo "    actual:   $(printf '%s' "$1" | tr '\n' '|')"
    return 1
}

lv_has_line() { grep -Fqx -- "$2" <<<"$1"; }

# --- Remote facts (read-only) ----------------------------------------------
lv_probe() { dxe_runtime_call dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$DX_CONTAINER_NAME" 2>/dev/null; }
lv_stat() { persist_live_root_sh ro "$PERSIST_LIVE_SCRIPT_STAT" </dev/null 2>/dev/null; }
lv_marker_of() { printf '%s\n' "$1" | sed '1,4d'; }
lv_entries_of() { printf '%s\n' "$1" | sed -n 's/^entry=//p'; }
lv_volume_state() {
    local state
    state="$(dxe_runtime_call dx_runtime_volume_state "$1" 2>/dev/null)" || :
    printf '%s\n' "${state:-unknown}" | sed -n '1p'
}
lv_volume_is() { [ "$(lv_volume_state "$2")" = "$1" ]; }
lv_container_exists() { dxe_runtime_call dx_runtime_container_exists "$DX_CONTAINER_NAME" >/dev/null 2>&1; }
lv_container_running() { dxe_runtime_call dx_runtime_container_running "$DX_CONTAINER_NAME" >/dev/null 2>&1; }
# Stopped = the container answers inspect (so the transport works) and is not
# running: a transport failure never reads as "stopped".
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

# lv_check_bind: /persist is exactly one read-write bind of the leaf. Docker
# may report the bind source with the share root resolved (a QTS share root is
# usually a symlink into its pool's data path): the first time, that is a
# FINDING for WP3.4 (dx-status and dx-start-container compare the configured
# path with the reported one, so they would show a mismatch) and the run goes
# on with the reported path in LV_ACTUAL; later binds must report the same
# path. Any other shape -- no bind, a volume, read-only, two /persist mounts,
# another directory -- stops the run.
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
lv_timestamp_ok() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
    esac
    return 1
}

# Everything a refusal must leave as it was: the probe report (state and
# marker bytes), the canary directory's facts, the three volumes, whether the
# container runs, and the record's bytes.
lv_state() {
    local report stat record=absent running=no
    report="$(lv_probe)" || report="probe-failed"
    stat="$(lv_stat)" || stat="stat-unavailable"
    [ ! -e "$LV_RECORD" ] || record="$(cksum <"$LV_RECORD")"
    if lv_container_running; then running=yes; fi
    printf '%s\n--\n%s\n--\nnix=%s persist=%s bootstrap=%s\nrunning=%s\nrecord=%s\n' \
        "$report" "$stat" "$(lv_volume_state "$DX_NIX_VOLUME")" "$(lv_volume_state "$DX_PERSIST_VOLUME")" \
        "$(lv_volume_state "$DX_BOOTSTRAP_VOLUME")" "$running" "$record"
}

# The facts a restored or kept directory must show again: the leaf's and the
# marker's kinds, owner and mode, the leaf's entries, the aside slots and the
# application state.
lv_facts() { lv_stat | grep -E '^(leaf|leaf_owner|leaf_mode|marker|marker_mode|aside|orig|entry|app_state)='; }
lv_state_unchanged() {
    local now
    now="$(lv_state)"
    [ "$now" = "$1" ] && return 0
    printf '%s\n' "$1" >"$LV_RUN_DIR/logs/state-before.txt"
    printf '%s\n' "$now" >"$LV_RUN_DIR/logs/state-after.txt"
    diff "$LV_RUN_DIR/logs/state-before.txt" "$LV_RUN_DIR/logs/state-after.txt" | sed 's/^/    /'
    return 1
}

# --- Share changes (root one-off container; canary directory only) ---------
lv_share() {
    local label="$1"
    shift
    lv_run "share-$label" -- persist_live_root_sh rw "$@"
    lv_check "share change: $label" lv_rc_zero
}
lv_share_stdin() {
    local label="$1" file="$2"
    shift 2
    lv_run --stdin "$file" "share-$label" -- persist_live_root_sh rw "$@"
    lv_check "share change: $label" lv_rc_zero
}
lv_inflight_add() { LV_INFLIGHT="$LV_INFLIGHT $1"; }
lv_inflight_clear() { LV_INFLIGHT=""; }

lv_restore_inflight() {
    [ -n "${LV_INFLIGHT// /}" ] || return 0
    echo "  Restoring what the interrupted case changed:$LV_INFLIGHT"
    case " $LV_INFLIGHT " in
        *" leaf "*)
            persist_live_root_sh rw "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null \
                || echo "  WARNING: could not put $LV_LEAF back from $LV_DIR/$PERSIST_LIVE_ASIDE; do it by hand." ;;
    esac
    case " $LV_INFLIGHT " in
        *" marker "*)
            persist_live_root_sh rw "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" </dev/null \
                || echo "  WARNING: could not put the marker back from $LV_DIR/$PERSIST_LIVE_MARKER_ORIG; do it by hand." ;;
    esac
    case " $LV_INFLIGHT " in
        *" mode "*)
            persist_live_root_sh rw "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0755 </dev/null \
                || echo "  WARNING: could not reset $LV_LEAF to mode 0755." ;;
    esac
    case " $LV_INFLIGHT " in
        *" record "*)
            if [ -f "$LV_RECORD.dxe-live-aside" ]; then
                mv -f -- "$LV_RECORD.dxe-live-aside" "$LV_RECORD" || echo "  WARNING: could not put the record back from $LV_RECORD.dxe-live-aside."
            fi ;;
    esac
    lv_inflight_clear
}

lv_stop() {
    echo ""
    echo "Stopped at the first failure: $LV_FAILURE"
    lv_restore_inflight
    # A failed run must not leave the canary running unattended (overnight,
    # next to the production guest) unless the operator asked for that.
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

# lv_expect_refusals ESSENTIAL...: dx-create-volumes and dx-start-container
# (guest stopped) each exit non-zero with exactly one Error line holding every
# ESSENTIAL, the guest stays stopped, and nothing changes.
lv_expect_refusals() {
    local before cmd essential
    before="$(lv_state)"
    for cmd in dx-create-volumes dx-start-container; do
        lv_run "$cmd-refused" -- "$BIN_DIR/$cmd"
        lv_check "$cmd refuses (non-zero)" lv_rc_nonzero || return 1
        lv_check "$cmd prints exactly one Error: line" lv_one_error || return 1
        for essential in "$@"; do
            lv_check "$cmd says: $essential" lv_err_has "$essential" || return 1
        done
        lv_check "the guest is still stopped after $cmd" lv_container_stopped || return 1
    done
    lv_check "nothing changed on the share, the volumes or the record" lv_state_unchanged "$before"
}

# lv_back_to_baseline [FACTS]: the marker is the one created, and the canary
# directory shows FACTS again (default: the stopped guest's, LV_FACTS0).
lv_back_to_baseline() {
    local expected="${1:-$LV_FACTS0}"
    lv_check "the marker is byte-identical to the one created" lv_equal "$(lv_marker_of "$(lv_probe)")" "$LV_MARKER0" || return 1
    lv_check "the directory is as it was: kind, owner, mode, entries, marker and application state" \
        lv_equal "$(lv_facts)" "$expected"
}

lv_marker_file() {
    local file="$LV_RUN_DIR/logs/marker-$1.txt"
    shift
    persist_live_marker_text "$@" >"$file"
    printf '%s\n' "$file"
}

# --- Cases --------------------------------------------------------------------
c_preflight() {
    local report
    lv_case "preflight"
    lv_check "no container named $DX_CONTAINER_NAME exists yet (a leftover? run the cleanup mode first)" lv_container_absent || return 1
    local vol
    for vol in "$DX_NIX_VOLUME" "$DX_PERSIST_VOLUME" "$DX_BOOTSTRAP_VOLUME"; do
        lv_check "volume $vol does not exist yet" lv_volume_is absent "$vol" || return 1
    done
    report="$(lv_probe)"
    lv_check "the read-only probe of the share root answers" test -n "$report" || return 1
    echo "    canonical share root: $(persist_live_kv root "$report")"
    lv_check "the share root is mounted: sentinel $DX_PERSIST_HOST_MOUNT_SENTINEL present" lv_equal "$(persist_live_kv mounted "$report")" yes || return 1
    lv_check "the canary directory does not exist yet" lv_equal "$(persist_live_kv state "$report")" absent || return 1
    lv_check "no D-7 record exists for the canary in this run's state directory" test ! -e "$LV_RECORD"
}

c_new_guest_refusals() {
    local before
    lv_case "new-guest refusals"
    lv_run_ok "dx-create-keys makes the canary key pair" create-keys -- "$BIN_DIR/dx-create-keys" || return 1
    lv_run_ok "dx-create-image tags the canary image" create-image -- "$BIN_DIR/dx-create-image" || return 1
    before="$(lv_state)"
    lv_run create-volumes-unmounted "DX_PERSIST_HOST_MOUNT_SENTINEL=$LV_BOGUS_SENTINEL" -- "$BIN_DIR/dx-create-volumes"
    lv_check "dx-create-volumes refuses a share whose sentinel is missing" lv_rc_nonzero || return 1
    lv_check "with exactly one Error: line" lv_one_error || return 1
    lv_check "naming the missing sentinel" lv_err_has "does not look mounted: its sentinel file DX_PERSIST_HOST_MOUNT_SENTINEL=$LV_BOGUS_SENTINEL is missing" || return 1
    lv_check "nothing was created (directory, volumes, record)" lv_state_unchanged "$before" || return 1
    lv_run create-volumes-mount-unknown "DX_PERSIST_HOST_MOUNT_SENTINEL=" -- "$BIN_DIR/dx-create-volumes"
    lv_check "dx-create-volumes refuses to create without a sentinel" lv_rc_nonzero || return 1
    lv_check "with exactly one Error: line" lv_one_error || return 1
    lv_check "saying it cannot tell whether the share is mounted" lv_err_has "cannot tell whether the share root $DX_PERSIST_HOST_ROOT is mounted" || return 1
    lv_check "nothing was created (directory, volumes, record)" lv_state_unchanged "$before"
}

c_create() {
    local report marker stat expected
    lv_case "creation"
    lv_run_ok "dx-create-volumes creates the canary's directory" create-volumes -- "$BIN_DIR/dx-create-volumes" || return 1
    lv_check "it says it creates $LV_LEAF" lv_out_has "Creating /persist directory $LV_LEAF" || return 1
    report="$(lv_probe)"
    lv_check "the probe sees a marked directory" lv_equal "$(printf '%s\n' "$report" | sed -n '3,4p')" "$(printf 'state=nonempty\nmarker=present')" || return 1
    marker="$(lv_marker_of "$report")"
    LV_CREATED_AT="$(persist_live_kv created-at "$marker")"
    lv_check "created-at is a UTC timestamp" lv_timestamp_ok "$LV_CREATED_AT" || return 1
    lv_check "the marker is exactly schema, guest, state=ready and created-at" \
        lv_equal "$marker" "$(persist_live_marker_text "$DX_CONTAINER_NAME" ready "" "$LV_CREATED_AT")" || return 1
    LV_MARKER0="$marker"
    stat="$(lv_stat)"
    lv_check "the leaf is a real directory" lv_has_line "$stat" "leaf=dir" || return 1
    lv_check "the root container's chown made it $LV_OWNER (mkdir by root alone gives 0:0)" lv_has_line "$stat" "leaf_owner=$LV_OWNER" || return 1
    lv_check "the leaf has mode 0755" lv_has_line "$stat" "leaf_mode=755" || return 1
    lv_check "the marker is a regular file with mode 0644" lv_has_line "$stat" "marker_mode=644" || return 1
    lv_check "the leaf holds only the marker: the mv left no temp file" lv_equal "$(lv_entries_of "$stat")" ".dxe-persist-dir" || return 1
    lv_check "the D-7 record exists" test -f "$LV_RECORD" || return 1
    lv_check "the record has mode 0600" lv_equal "$(file_mode "$LV_RECORD")" 600 || return 1
    expected="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=create\ncreated-at=%s' "$DX_CONTAINER_NAME" "$DX_PERSIST_HOST_ROOT" "$LV_CREATED_AT")"
    lv_check "the record is exactly schema, guest, root, mode=create and the marker's created-at" lv_equal "$(lv_record_text)" "$expected" || return 1
    LV_RECORD0="$(lv_record_text)"
    lv_check "the nix volume exists" lv_volume_is present "$DX_NIX_VOLUME" || return 1
    lv_check "the bootstrap volume exists" lv_volume_is present "$DX_BOOTSTRAP_VOLUME" || return 1
    lv_check "host-path mode never creates the persist volume" lv_volume_is absent "$DX_PERSIST_VOLUME"
}

c_record_backfill() {
    local expected
    lv_case "record backfill"
    mv -f -- "$LV_RECORD" "$LV_RECORD.dxe-live-aside" || { lv_bad "could not move the record aside"; return 1; }
    lv_inflight_add record
    lv_run_ok "dx-create-volumes succeeds on the ready directory" create-volumes-backfill -- "$BIN_DIR/dx-create-volumes" || return 1
    expected="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=backfill\ncreated-at=%s' "$DX_CONTAINER_NAME" "$DX_PERSIST_HOST_ROOT" "$LV_CREATED_AT")"
    lv_check "it wrote the missing record back (mode=backfill, the marker's created-at)" lv_equal "$(lv_record_text)" "$expected" || return 1
    lv_check "the backfilled record has mode 0600" lv_equal "$(file_mode "$LV_RECORD")" 600 || return 1
    lv_check "the marker is unchanged" lv_equal "$(lv_marker_of "$(lv_probe)")" "$LV_MARKER0" || return 1
    mv -f -- "$LV_RECORD.dxe-live-aside" "$LV_RECORD" || { lv_bad "could not put the record back"; return 1; }
    lv_inflight_clear
    lv_check "the original record is back" lv_equal "$(lv_record_text)" "$LV_RECORD0"
}

c_bring_up() {
    local ids stat
    lv_case "bring-up"
    lv_run_ok "dx brings the guest up and runs a command in it" dx-bring-up -- "$BIN_DIR/dx" true || return 1
    lv_check "dx used the directory as it was (no second creation)" lv_out_has "Using /persist directory $LV_LEAF (marker ready)" || return 1
    lv_check "the container is running" lv_container_running || return 1
    lv_check_bind || return 1
    lv_check "the guest verified its mount and marker before using /persist (WP4.5)" \
        test "$(lv_log_count "Verified host-path /persist for guest $DX_CONTAINER_NAME: a mount point with a ready .dxe-persist-dir.")" -ge 1 || return 1
    lv_check "/persist is a mount point inside the guest" test "$(lv_guest 'grep -c " /persist " /proc/self/mountinfo')" -ge 1 || return 1
    ids="$(lv_guest 'printf "%s:%s\n" "$(id -u)" "$(id -g)"')"
    lv_check "the guest's dx user is $LV_OWNER, the owner the tooling gave the directory" lv_equal "$ids" "$LV_OWNER" || return 1
    stat="$(lv_stat)"
    lv_check "after boot the leaf is still $LV_OWNER, mode 0755" lv_has_line "$stat" "leaf_owner=$LV_OWNER" || return 1
    lv_check "and mode 0755" lv_has_line "$stat" "leaf_mode=755" || return 1
    lv_run_ok "dx-status runs" status -- "$BIN_DIR/dx-status" || return 1
    lv_check "dx-status: configured is the leaf" lv_out_has "configured: $LV_LEAF" || return 1
    lv_check "dx-status: actual is the bind source Docker reports" lv_out_has "actual: $LV_ACTUAL" || return 1
    if [ "$LV_ACTUAL" = "$LV_LEAF" ]; then
        lv_check "dx-status reports no mismatch" lv_out_lacks "mismatch:" || return 1
    else
        echo "    (dx-status reports a mismatch: the bind-source FINDING above)"
    fi
    LV_FPR0="$(lv_host_fingerprint)"
    lv_check "the guest's SSH host key fingerprint is readable" test -n "$LV_FPR0" || return 1
    echo "    host key: $LV_FPR0"
    guest_bash "mkdir -p /persist/dxe-live && printf '%s\n' $LV_TOKEN > /persist/dxe-live/app-state.txt" >/dev/null 2>&1
    lv_check "an application-state file is written in /persist" lv_equal "$(lv_guest 'cat /persist/dxe-live/app-state.txt')" "$LV_TOKEN" || return 1
    stat="$(lv_stat)"
    lv_check "the NAS sees the same file in the leaf" lv_has_line "$stat" "app_state=$LV_TOKEN" || return 1
}

lv_same_guest_state() {
    lv_check "the application state survived" lv_equal "$(lv_guest 'cat /persist/dxe-live/app-state.txt')" "$LV_TOKEN" || return 1
    lv_check "the SSH host key is the same (fingerprint)" lv_equal "$(lv_host_fingerprint)" "$LV_FPR0" || return 1
    lv_check "dx-ssh still connects under the accept-new pin" lv_equal "$(lv_guest 'echo pinned-ok')" pinned-ok || return 1
    lv_check "the marker is unchanged" lv_equal "$(lv_marker_of "$(lv_probe)")" "$LV_MARKER0" || return 1
    lv_check "the record is unchanged" lv_equal "$(lv_record_text)" "$LV_RECORD0"
}

c_stop_start() {
    lv_case "stop/start"
    lv_run_ok "dx-stop-container stops the guest" stop -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    lv_run_ok "dx-start-container starts it again" start -- "$BIN_DIR/dx-start-container" || return 1
    lv_run_ok "dx-wait-ssh sees it come up" wait-ssh -- "$BIN_DIR/dx-wait-ssh" || return 1
    lv_same_guest_state
}

c_recreate() {
    lv_case "recreate"
    lv_run_ok "dx-recreate rebuilds the container" recreate -- "$BIN_DIR/dx-recreate" true || return 1
    lv_check "it reused the directory" lv_out_has "Using /persist directory $LV_LEAF (marker ready)" || return 1
    lv_check "it created nothing on the share" lv_out_lacks "Creating /persist directory" || return 1
    lv_check_bind || return 1
    lv_check "the persist volume still does not exist" lv_volume_is absent "$DX_PERSIST_VOLUME" || return 1
    lv_same_guest_state
}

c_mismatch() {
    local before
    lv_case "mismatch"
    before="$(lv_state)"
    lv_run status-volume-config DX_PERSIST_STORAGE=volume -- "$BIN_DIR/dx-status"
    lv_check "dx-status reports the configured volume" lv_out_has "configured: $DX_PERSIST_VOLUME" || return 1
    lv_check "and the actual directory" lv_out_has "actual: $LV_ACTUAL" || return 1
    lv_check "and the mismatch, naming dx-recreate" lv_out_has "mismatch: /persist is not on the configured storage; dx-recreate applies the configuration" || return 1
    lv_run start-volume-config DX_PERSIST_STORAGE=volume -- "$BIN_DIR/dx-start-container"
    lv_check "dx-start-container warns about the mismatch, naming dx-recreate" \
        lv_err_has "Warning: $DX_CONTAINER_NAME's /persist is on $LV_ACTUAL but the configuration says $DX_PERSIST_VOLUME; run dx-recreate to apply the configuration." || return 1
    lv_check_bind || return 1
    lv_check "nothing changed on the share, the volumes or the record" lv_state_unchanged "$before"
}

c_backup_restore() {
    local probe mirror current
    lv_case "backup/restore"
    probe="backup-$LV_TOKEN"
    guest_bash "mkdir -p /persist/dxe-live && printf '%s\n' $probe > /persist/dxe-live/backup-probe.txt" >/dev/null 2>&1
    lv_check "a file to back up exists in /persist" lv_equal "$(lv_guest 'cat /persist/dxe-live/backup-probe.txt')" "$probe" || return 1
    lv_run_ok "dx-backup succeeds on the host-path guest" backup "DX_BACKUP_DIR=$LV_RUN_DIR/backup" -- "$BIN_DIR/dx-backup" || return 1
    # <DX_BACKUP_DIR>/<container>/<daemon identity>/current, a symlink to the
    # published generation (bin/lib/dx-backup.sh).
    mirror=""
    for current in "$LV_RUN_DIR"/backup/"$DX_CONTAINER_NAME"/*/current; do
        [ -f "$current/dxe-live/backup-probe.txt" ] && mirror="$current/dxe-live/backup-probe.txt"
    done
    lv_check "the mirror's current generation holds the file" test -n "$mirror" || return 1
    lv_check "with its content" lv_equal "$(cat "$mirror")" "$probe" || return 1
    guest_bash "rm -f /persist/dxe-live/backup-probe.txt" >/dev/null 2>&1
    lv_check "the file is deleted in the guest" lv_equal "$(lv_guest 'test -e /persist/dxe-live/backup-probe.txt && echo present || echo gone')" gone || return 1
    lv_run_ok "dx-restore succeeds" restore "DX_BACKUP_DIR=$LV_RUN_DIR/backup" -- "$BIN_DIR/dx-restore" dxe-live/backup-probe.txt || return 1
    lv_check "it restored one file" lv_out_has "Restored 1 file(s)" || return 1
    lv_check "the file is back with its content" lv_equal "$(lv_guest 'cat /persist/dxe-live/backup-probe.txt')" "$probe" || return 1
    lv_check "owned by the guest's dx user" lv_equal "$(lv_guest 'stat -c %u:%g /persist/dxe-live/backup-probe.txt')" "$LV_OWNER"
}

c_refusals_begin() {
    lv_case "refusals: stop the guest"
    lv_run_ok "dx-stop-container stops the guest" stop-for-refusals -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    LV_FACTS0="$(lv_facts)"
    lv_check "the leaf holds the application state" lv_has_line "$LV_FACTS0" "app_state=$LV_TOKEN"
}

c_refuse_missing() {
    lv_case "refusal: missing directory"
    lv_share leaf-aside "$PERSIST_LIVE_SCRIPT_ASIDE" || return 1
    lv_inflight_add leaf
    lv_check "the probe sees no directory" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_expect_refusals "is missing, but $DX_CONTAINER_NAME already has /persist data" \
        "the record $LV_RECORD says it used this directory" \
        "The tooling never creates empty replacement storage." || return 1
    local before
    before="$(lv_state)"
    lv_run create-volumes-missing-unmounted "DX_PERSIST_HOST_MOUNT_SENTINEL=$LV_BOGUS_SENTINEL" -- "$BIN_DIR/dx-create-volumes"
    lv_check "with the sentinel missing too, dx-create-volumes still refuses" lv_rc_nonzero || return 1
    lv_check "with exactly one Error: line" lv_one_error || return 1
    lv_check "adding the mount hint" lv_err_has "The share may not be mounted: its sentinel DX_PERSIST_HOST_MOUNT_SENTINEL=$LV_BOGUS_SENTINEL is missing" || return 1
    lv_check "and creating nothing" lv_state_unchanged "$before" || return 1
    lv_share leaf-restore "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
    lv_inflight_clear
    lv_back_to_baseline
}

c_refuse_symlink() {
    lv_case "refusal: symlinked leaf"
    lv_share leaf-aside "$PERSIST_LIVE_SCRIPT_ASIDE" || return 1
    lv_inflight_add leaf
    lv_share leaf-symlink "$PERSIST_LIVE_SCRIPT_REPLACE" symlink || return 1
    lv_check "the probe sees a symlink" lv_equal "$(persist_live_kv state "$(lv_probe)")" symlink || return 1
    lv_expect_refusals "is a symlink; /persist must be a real directory" || return 1
    lv_share leaf-restore "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
    lv_inflight_clear
    lv_back_to_baseline
}

# lv_refuse_marker LABEL MARKER_FILE ESSENTIAL
lv_refuse_marker() {
    lv_share_stdin "marker-$1" "$2" "$PERSIST_LIVE_SCRIPT_MARKER_OUT" swap || return 1
    lv_inflight_add marker
    lv_check "the probe reads the replacement marker" lv_equal "$(lv_marker_of "$(lv_probe)")" "$(cat "$2")" || return 1
    lv_expect_refusals "$3" || return 1
    lv_share marker-restore "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" || return 1
    lv_inflight_clear
    lv_back_to_baseline
}

c_refuse_marker_guest() {
    lv_case "refusal: marker for another guest"
    lv_refuse_marker other-guest "$(lv_marker_file other-guest "$LV_OTHER_GUEST" ready "" "$LV_CREATED_AT")" \
        "names guest $LV_OTHER_GUEST, not $DX_CONTAINER_NAME"
}

c_refuse_marker_copying() {
    lv_case "refusal: marker copying"
    lv_refuse_marker copying "$(lv_marker_file copying "$DX_CONTAINER_NAME" copying "$DX_PERSIST_VOLUME" "$LV_CREATED_AT")" \
        "$LV_LEAF is marked copying"
}

c_refuse_marker_retired() {
    lv_case "refusal: marker retired"
    lv_refuse_marker retired "$(lv_marker_file retired "$DX_CONTAINER_NAME" retired "$DX_PERSIST_VOLUME" "$LV_CREATED_AT" "" "$LV_CREATED_AT")" \
        "$LV_LEAF is marked retired"
}

c_refuse_unmarked() {
    lv_case "refusal: non-empty unmarked directory"
    lv_share leaf-aside "$PERSIST_LIVE_SCRIPT_ASIDE" || return 1
    lv_inflight_add leaf
    lv_share leaf-unmarked "$PERSIST_LIVE_SCRIPT_REPLACE" unmarked || return 1
    lv_check "the probe sees a non-empty unmarked directory" \
        lv_equal "$(lv_probe | sed -n '3,4p')" "$(printf 'state=nonempty\nmarker=absent')" || return 1
    lv_expect_refusals "is not empty and has no .dxe-persist-dir marker" || return 1
    lv_share leaf-restore "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
    lv_inflight_clear
    lv_back_to_baseline
}

c_refuse_empty_fresh_start() {
    local stat before report marker created expected
    lv_case "refusal: empty directory with the old volume; DX_PERSIST_FRESH_START"
    lv_run_ok "the canary's persist volume is created (labelled), standing for the old volume" volume-create -- dxe_runtime_call dx_runtime_volume_create "$DX_PERSIST_VOLUME" || return 1
    lv_check "the persist volume exists" lv_volume_is present "$DX_PERSIST_VOLUME" || return 1
    lv_share leaf-aside "$PERSIST_LIVE_SCRIPT_ASIDE" || return 1
    lv_inflight_add leaf
    lv_share leaf-empty "$PERSIST_LIVE_SCRIPT_REPLACE" empty || return 1
    mv -f -- "$LV_RECORD" "$LV_RECORD.dxe-live-aside" || { lv_bad "could not move the record aside"; return 1; }
    lv_inflight_add record
    stat="$(lv_stat)"
    lv_check "the empty stand-in is owned by root (0:0)" lv_has_line "$stat" "leaf_owner=0:0" || return 1
    lv_check "and holds nothing" lv_equal "$(lv_entries_of "$stat")" "" || return 1
    lv_expect_refusals "is empty and unmarked" "the persist volume $DX_PERSIST_VOLUME exists" \
        "DX_PERSIST_FRESH_START=$DX_CONTAINER_NAME" || return 1
    before="$(lv_state)"
    lv_run create-volumes-wrong-override "DX_PERSIST_FRESH_START=$LV_WRONG_OVERRIDE" -- "$BIN_DIR/dx-create-volumes"
    lv_check "an override naming another guest is refused" lv_rc_nonzero || return 1
    lv_check "with exactly one Error: line" lv_one_error || return 1
    lv_check "saying so" lv_err_has "(DX_PERSIST_FRESH_START=$LV_WRONG_OVERRIDE does not name this guest.)" || return 1
    lv_check "and changing nothing" lv_state_unchanged "$before" || return 1
    lv_run_ok "DX_PERSIST_FRESH_START=$DX_CONTAINER_NAME dx-create-volumes marks it ready" create-volumes-fresh-start \
        "DX_PERSIST_FRESH_START=$DX_CONTAINER_NAME" -- "$BIN_DIR/dx-create-volumes" || return 1
    lv_check "it says it is a fresh start that keeps the volume" lv_out_has "Fresh start (DX_PERSIST_FRESH_START)" || return 1
    stat="$(lv_stat)"
    lv_check "chown changed the owner on the real share: 0:0 -> $LV_OWNER" lv_has_line "$stat" "leaf_owner=$LV_OWNER" || return 1
    lv_check "mode 0755" lv_has_line "$stat" "leaf_mode=755" || return 1
    lv_check "a 0644 marker" lv_has_line "$stat" "marker_mode=644" || return 1
    lv_check "and no temp file beside it" lv_equal "$(lv_entries_of "$stat")" ".dxe-persist-dir" || return 1
    report="$(lv_probe)"
    marker="$(lv_marker_of "$report")"
    created="$(persist_live_kv created-at "$marker")"
    lv_check "the new marker is ready for this guest" lv_equal "$marker" "$(persist_live_marker_text "$DX_CONTAINER_NAME" ready "" "$created")" || return 1
    expected="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=fresh-start\ncreated-at=%s' "$DX_CONTAINER_NAME" "$DX_PERSIST_HOST_ROOT" "$created")"
    lv_check "the record is written after the marker (mode=fresh-start)" lv_equal "$(lv_record_text)" "$expected" || return 1
    lv_check "the old persist volume is kept" lv_volume_is present "$DX_PERSIST_VOLUME" || return 1
    lv_share leaf-restore "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
    mv -f -- "$LV_RECORD.dxe-live-aside" "$LV_RECORD" || { lv_bad "could not put the record back"; return 1; }
    lv_inflight_clear
    lv_check "the original record is back" lv_equal "$(lv_record_text)" "$LV_RECORD0" || return 1
    lv_back_to_baseline
}

c_restart_after_refusals() {
    lv_case "restart"
    lv_run_ok "dx-start-container starts the guest on its directory" start-after-refusals -- "$BIN_DIR/dx-start-container" || return 1
    lv_run_ok "dx-wait-ssh sees it come up" wait-ssh-after-refusals -- "$BIN_DIR/dx-wait-ssh" || return 1
    lv_same_guest_state || return 1
    lv_run_ok "dx-status runs" status-kept -- "$BIN_DIR/dx-status" || return 1
    lv_check "dx-status lists the kept persist volume" lv_out_has "kept volume: $DX_PERSIST_VOLUME"
}

# lv_raw_start_stops LABEL LOG_LINE: docker start through the runtime, the
# guest stops itself, the log line appears once more, /persist untouched.
lv_raw_start_stops() {
    local n0 n1 stat entries
    n0="$(lv_log_count "$2")"
    entries="$(lv_entries_of "$(lv_stat)")"
    lv_check "the leaf's entries are readable before the start" test -n "$entries" || return 1
    lv_run "raw-start-$1" -- dxe_runtime_call dx_runtime_container_start "$DX_CONTAINER_NAME"
    lv_check "docker start succeeds (the guest itself decides)" lv_rc_zero || return 1
    lv_check "the guest stops itself" lv_wait_until 600 5 lv_container_stopped || return 1
    n1="$(lv_log_count "$2")"
    lv_check "its log says why: $2" test "$n1" -gt "$n0" || return 1
    stat="$(lv_stat)"
    lv_check "it stopped before touching /persist: the leaf kept mode 0751" lv_has_line "$stat" "leaf_mode=751" || return 1
    lv_check "the leaf's entries are unchanged" lv_equal "$(lv_entries_of "$stat")" "$entries" || return 1
    lv_check "the application state is untouched" lv_has_line "$stat" "app_state=$LV_TOKEN"
}

c_guest_self_check() {
    lv_case "guest self-check"
    lv_run_ok "dx-stop-container stops the guest" stop-for-self-check -- "$BIN_DIR/dx-stop-container" || return 1
    lv_check "the guest is stopped" lv_container_stopped || return 1
    lv_share leaf-mode-0751 "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0751 || return 1
    lv_inflight_add mode
    lv_share marker-hide "$PERSIST_LIVE_SCRIPT_MARKER_OUT" hide || return 1
    lv_inflight_add marker
    lv_raw_start_stops marker-missing "Error: /persist/.dxe-persist-dir is missing, so /persist is not a prepared directory for guest $DX_CONTAINER_NAME" || return 1
    lv_share marker-restore "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" || return 1
    lv_share_stdin marker-other-guest "$(lv_marker_file self-other-guest "$LV_OTHER_GUEST" ready "" "$LV_CREATED_AT")" \
        "$PERSIST_LIVE_SCRIPT_MARKER_OUT" swap || return 1
    lv_raw_start_stops marker-other-guest "names guest $LV_OTHER_GUEST, not $DX_CONTAINER_NAME" || return 1
    lv_share marker-restore "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" || return 1
    lv_share leaf-mode-0755 "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0755 || return 1
    lv_inflight_clear
    lv_share leaf-aside "$PERSIST_LIVE_SCRIPT_ASIDE" || return 1
    lv_inflight_add leaf
    lv_run raw-start-leaf-missing -- dxe_runtime_call dx_runtime_container_start "$DX_CONTAINER_NAME"
    lv_check "with the leaf missing, docker start itself fails" lv_rc_nonzero || return 1
    lv_check "the guest is not running" lv_container_stopped || return 1
    lv_check "and Docker created nothing at the leaf path (--mount, never -v)" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_share leaf-restore "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
    lv_inflight_clear
    lv_back_to_baseline || return 1
    lv_run_ok "dx-start-container starts the guest normally again" start-after-self-check -- "$BIN_DIR/dx-start-container" || return 1
    lv_run_ok "dx-wait-ssh sees it come up" wait-ssh-after-self-check -- "$BIN_DIR/dx-wait-ssh" || return 1
    lv_same_guest_state || return 1
    lv_check "the guest re-asserted mode 0755 on a normal boot" lv_has_line "$(lv_stat)" "leaf_mode=755"
}

lv_dx_ai_profile() { lv_guest 'readlink -e /persist/home/dx/.local/state/dx-ai/current/profile || echo unresolved'; }
lv_dangling_nix_links() {
    guest_bash 'find /persist/home/dx -xdev -type l -lname "/nix/store/*" ! -exec test -e {} \; -print 2>/dev/null | sed -n "1,40p"' 2>/dev/null
}

c_dx_ai_prepare() {
    local profile
    lv_case "R28 preparation"
    if [ "${DXE_PERSIST_LIVE_SKIP_DX_AI:-}" = 1 ]; then
        LV_DX_AI=skipped
        LV_DX_AI_REASON="the operator set DXE_PERSIST_LIVE_SKIP_DX_AI=1"
        test_skip "$LV_CASE: dx-ai not installed ($LV_DX_AI_REASON)"
        return 0
    fi
    lv_run dx-ai -- guest_bash dx-ai
    if [ "$LV_RC" -ne 0 ]; then
        LV_DX_AI=unavailable
        LV_DX_AI_REASON="dx-ai could not install the optional AI tools on the canary (exit $LV_RC; see $LV_ERR and $LV_OUT)"
        lv_show_logs
        test_skip "$LV_CASE: $LV_DX_AI_REASON; the recovery of that /nix-linked state is NOT validated by this run"
        return 0
    fi
    profile="$(lv_dx_ai_profile)"
    lv_check "dx-ai's profile in /persist resolves into the Nix store" test "${profile#/nix/store/}" != "$profile" || return 1
    lv_run_ok "codex runs" codex-version -- guest_bash 'codex --version' || return 1
    LV_DX_AI=ready
    echo "    dangling /nix/store links under /persist/home/dx before the reset:"
    lv_dangling_nix_links | sed 's/^/      /'
}

c_factory_reset() {
    local facts
    lv_case "factory reset"
    facts="$(lv_facts)"
    lv_check "the directory's facts are readable before the reset" test -n "$facts" || return 1
    lv_run_ok "dx-factory-reset --force succeeds" factory-reset -- "$BIN_DIR/dx-factory-reset" --force || return 1
    lv_check "it names the kept directory" lv_out_has "Kept /persist host directory: $LV_LEAF" || return 1
    lv_check "and the record's manual removal" lv_out_has "manual removal 2: delete the record file $LV_RECORD" || return 1
    lv_check "and the kept persist volume" lv_out_has "Kept persist volume: $DX_PERSIST_VOLUME" || return 1
    lv_check "with its delete command" lv_out_has "delete with: docker volume rm $DX_PERSIST_VOLUME" || return 1
    lv_check "it never removed the persist volume" lv_out_lacks "Removing volume $DX_PERSIST_VOLUME" || return 1
    lv_check "the container is gone" lv_container_absent || return 1
    lv_check "the image is gone" lv_image_absent || return 1
    lv_check "the nix volume is gone" lv_volume_is absent "$DX_NIX_VOLUME" || return 1
    lv_check "the bootstrap volume is gone" lv_volume_is absent "$DX_BOOTSTRAP_VOLUME" || return 1
    lv_check "the canary key pair is gone" test ! -e "$DX_SSH_KEY" || return 1
    lv_check "the persist volume is kept" lv_volume_is present "$DX_PERSIST_VOLUME" || return 1
    lv_check "the record is kept, byte for byte" lv_equal "$(lv_record_text)" "$LV_RECORD0" || return 1
    lv_ensure_image || return 1
    lv_back_to_baseline "$facts"
}

c_reuse_after_reset() {
    lv_case "reuse after reset"
    lv_run_ok "dx brings the reset guest up again (new image, keys and /nix)" dx-after-reset -- "$BIN_DIR/dx" true || return 1
    lv_check "it reused the directory" lv_out_has "Using /persist directory $LV_LEAF (marker ready)" || return 1
    lv_check "it created nothing" lv_out_lacks "Creating /persist directory" || return 1
    lv_check_bind || return 1
    lv_check "the guest's dx user is still $LV_OWNER" lv_equal "$(lv_guest 'printf "%s:%s\n" "$(id -u)" "$(id -g)"')" "$LV_OWNER" || return 1
    lv_same_guest_state
}

c_nix_state_recovery() {
    local profile
    lv_case "/nix recovery"
    lv_run_ok "Home Manager tools run on the new /nix (nvim)" nvim -- guest_bash 'nvim --headless +q' || return 1
    echo "    dangling /nix/store links under /persist/home/dx after the reset (information):"
    lv_dangling_nix_links | sed 's/^/      /'
    if [ "$LV_DX_AI" != ready ]; then
        test_skip "$LV_CASE: dx-ai's /nix-linked state not validated (${LV_DX_AI_REASON:-not prepared})"
        return 0
    fi
    # Expected gap (bootstrap's ai_tools_opted_in looks for an executable codex
    # through this very profile): a failure here is a FINDING, not a stop.
    profile="$(lv_dx_ai_profile)"
    lv_check_or_finding "dx-ai's profile in /persist resolves into the new Nix store with no manual step (R28; got: $profile)" \
        test "${profile#/nix/store/}" != "$profile"
    lv_run codex-version-after -- guest_bash 'codex --version'
    lv_check_or_finding "codex runs with no manual step (R28)" lv_rc_zero
}

c_destroy_volumes() {
    local facts
    lv_case "destroy volumes"
    facts="$(lv_facts)"
    lv_check "the directory's facts are readable before the destroy" test -n "$facts" || return 1
    lv_run_ok "dx-destroy removes the container and image" destroy -- "$BIN_DIR/dx-destroy" || return 1
    lv_run_ok "dx-destroy-volumes --force succeeds" destroy-volumes -- "$BIN_DIR/dx-destroy-volumes" --force || return 1
    lv_check "it removed the nix volume" lv_out_has "Removing volume $DX_NIX_VOLUME" || return 1
    lv_check "it removed the bootstrap volume" lv_out_has "Removing volume $DX_BOOTSTRAP_VOLUME" || return 1
    lv_check "it never removed the persist volume" lv_out_lacks "Removing volume $DX_PERSIST_VOLUME" || return 1
    lv_check "it names the kept directory" lv_out_has "Kept /persist host directory: $LV_LEAF" || return 1
    lv_check "and the kept persist volume" lv_out_has "Kept persist volume: $DX_PERSIST_VOLUME" || return 1
    lv_check "the nix volume is gone" lv_volume_is absent "$DX_NIX_VOLUME" || return 1
    lv_check "the bootstrap volume is gone" lv_volume_is absent "$DX_BOOTSTRAP_VOLUME" || return 1
    lv_check "the persist volume is kept" lv_volume_is present "$DX_PERSIST_VOLUME" || return 1
    lv_check "the record is kept, byte for byte" lv_equal "$(lv_record_text)" "$LV_RECORD0" || return 1
    lv_ensure_image || return 1
    lv_back_to_baseline "$facts"
}

lv_usage_line_ok() {
    awk -F'\t' -v p="$LV_LEAF" 'NF == 2 && $1 ~ /^[0-9]+$/ && $2 == p { ok = 1 } END { exit !ok }' "$LV_OUT" || { lv_show_logs; return 1; }
}

# The management account is uid 1000, not root, and the leaf is 30033:30001
# 0755 with root-only etc/ssh inside: du exits 1 on the unreadable directories
# and a temp file cannot be created in the leaf. These are the gaps this case
# exists to measure (WP5.2's usage line, WP6.4/6.5's marker writes), so every
# check here is a FINDING on failure and the run goes on to the cleanup.
c_nas_operations() {
    local free stat entries
    lv_case "NAS operations"
    echo "    (the probe ran in every case above; establish, its chown and its marker mv in creation and fresh start)"
    lv_run host-dir-usage -- dxe_runtime_call dx_runtime_host_dir_usage "$LV_LEAF"
    lv_check_or_finding "host_dir_usage (du -sk over the management account) succeeds" lv_rc_zero
    lv_check_or_finding "it prints <KiB><TAB><leaf>" lv_usage_line_ok
    lv_run host-dir-free -- dxe_runtime_call dx_runtime_host_dir_free "$DX_PERSIST_HOST_ROOT"
    lv_check_or_finding "host_dir_free (df -P -k over the management account) succeeds" lv_rc_zero
    free="$(cat "$LV_OUT")"
    lv_check_or_finding "it reports a filesystem" test -n "$(persist_live_kv fs "$free")"
    lv_check_or_finding "and numeric total KiB" grep -Eq '^total_kb=[0-9]+$' "$LV_OUT"
    lv_check_or_finding "and numeric available KiB" grep -Eq '^avail_kb=[0-9]+$' "$LV_OUT"
    entries="$(lv_entries_of "$(lv_stat)")"
    lv_run host-dir-marker-write -- dxe_runtime_call dx_runtime_host_dir_marker_write "$LV_LEAF" "$LV_MARKER0"
    lv_check_or_finding "host_dir_marker_write (temp file + mv over the management account) succeeds on the $LV_OWNER-owned leaf" lv_rc_zero
    lv_check_or_finding "the marker holds the same bytes afterwards" lv_equal "$(lv_marker_of "$(lv_probe)")" "$LV_MARKER0"
    stat="$(lv_stat)"
    lv_check_or_finding "no temp file is left in the leaf" lv_equal "$(lv_entries_of "$stat")" "$entries"
    lv_check_or_finding "and the marker is 0644" lv_has_line "$stat" "marker_mode=644"
    return 0
}

c_final_cleanup() {
    local stamp docker_bin base_ref vol
    lv_case "final cleanup"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if lv_container_running; then
        lv_run_ok "dx-stop-container stops the guest" stop-for-cleanup -- "$BIN_DIR/dx-stop-container" || return 1
    fi
    lv_check "the share root answers the probe" test -n "$(lv_probe)" || return 1
    lv_ensure_image || return 1
    if lv_stat >/dev/null; then
        lv_share leaf-restore-before-cleanup "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" || return 1
        lv_share marker-restore-before-cleanup "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" || return 1
        lv_share "leaf-retire-$stamp" "$PERSIST_LIVE_SCRIPT_RETIRE" "$stamp" || return 1
    else
        echo "    $LV_DIR cannot be bound (no canary directory on the share); nothing to move aside"
    fi
    lv_check "no canary directory is left where the tooling looks" lv_equal "$(persist_live_kv state "$(lv_probe)")" absent || return 1
    lv_run_ok "dx-factory-reset --force removes the canary's container, image, volumes and keys" factory-reset-cleanup -- "$BIN_DIR/dx-factory-reset" --force || return 1
    if lv_volume_is present "$DX_PERSIST_VOLUME"; then
        lv_run_ok "the canary's persist volume is deleted (DQ6 ownership checked)" volume-delete -- dxe_runtime_call dx_runtime_volume_delete "$DX_PERSIST_VOLUME" || return 1
    fi
    rm -f -- "$LV_RECORD" "$LV_RECORD.dxe-live-aside"
    lv_check "the canary's D-7 record is deleted" test ! -e "$LV_RECORD" || return 1
    lv_check "no canary container is left" lv_container_absent || return 1
    lv_check "no canary image is left" lv_image_absent || return 1
    for vol in "$DX_NIX_VOLUME" "$DX_PERSIST_VOLUME" "$DX_BOOTSTRAP_VOLUME"; do
        lv_check "no volume $vol is left" lv_volume_is absent "$vol" || return 1
    done
    docker_bin="$(dxe_runtime_call dx_runtime_docker_require_bin 2>/dev/null)" || docker_bin=""
    [ -n "$docker_bin" ] || docker_bin=docker
    base_ref="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "${DX_CONTEXT_DIR:-$BASE_DIR/container/dx-nixos-26.05}/Containerfile" | sed -n '1p')"
    echo ""
    echo "  The canary's NAS directory was moved aside, never deleted: $LV_DIR/$PERSIST_LIVE_REMOVED_PREFIX$stamp"
    echo "  (plus any $PERSIST_LIVE_ASIDE or $PERSIST_LIVE_MARKER_ORIG an interrupted run left). Its files belong"
    echo "  to root and $LV_OWNER, so remove the whole canary directory by hand, as root, after a last look:"
    echo "    ssh $DX_REMOTE_HOST \"$docker_bin run --rm --network none --user 0:0 --mount type=bind,source=$DX_PERSIST_HOST_ROOT/dxe,target=/dxe --entrypoint ls $base_ref -la /dxe/$DX_CONTAINER_NAME\""
    echo "    ssh $DX_REMOTE_HOST \"$docker_bin run --rm --network none --user 0:0 --mount type=bind,source=$DX_PERSIST_HOST_ROOT/dxe,target=/dxe --entrypoint rm $base_ref -rf -- /dxe/$DX_CONTAINER_NAME\""
    echo "  The run directory $LV_RUN_DIR (logs, SSH pins, the backup mirror) is kept for the record; delete it when done."
}

LV_CASES="c_preflight c_new_guest_refusals c_create c_record_backfill c_bring_up c_stop_start c_recreate c_mismatch c_backup_restore c_refusals_begin c_refuse_missing c_refuse_symlink c_refuse_marker_guest c_refuse_marker_copying c_refuse_marker_retired c_refuse_unmarked c_refuse_empty_fresh_start c_restart_after_refusals c_guest_self_check c_dx_ai_prepare c_factory_reset c_reuse_after_reset c_nix_state_recovery c_destroy_volumes c_nas_operations"
if [ "${DXE_PERSIST_LIVE_KEEP:-}" != 1 ]; then
    LV_CASES="$LV_CASES c_final_cleanup"
fi
if [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" = 1 ]; then
    LV_CASES="c_final_cleanup"
fi

if [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" != 1 ]; then
    echo "  Expected duration: two full guest bootstraps on the NAS, the optional AI"
    echo "  tools install, and about thirty start, stop and one-off container"
    echo "  cycles -- typically 1.5 to 3 hours."
fi
for lv_case_fn in $LV_CASES; do
    if ! "$lv_case_fn"; then
        [ -n "$LV_FAILURE" ] || LV_FAILURE="$LV_CASE"
        lv_stop
        break
    fi
done
if [ -z "$LV_FAILURE" ] && [ "${DXE_PERSIST_LIVE_KEEP:-}" = 1 ] && [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" != 1 ]; then
    echo "DXE_PERSIST_LIVE_KEEP=1: the canary is left in place. To remove it: $LV_CLEANUP_COMMAND"
fi
if [ -n "$LV_FINDINGS" ]; then
    echo ""
    echo "Findings (each recorded as a failure; the run went on past them):$LV_FINDINGS"
fi

print_summary
exit_with_code
