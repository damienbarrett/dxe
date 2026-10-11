#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.3 (implementer unit cases): in-process coverage for the start decision
# helpers in bin/lib/dx-persist-dir.sh that the acceptance suite
# (tests/test_persist_start_decision.sh) does not reach: the fail-closed arms
# of the record lookup and the report parser, every refusal message, and the
# per-token wiring helpers with the runtime replaced by recorders. WP4.4
# replaced the dx_persist_dir_establish placeholder these cases also pinned;
# its in-process cases are in tests/test_persist_dir_create_unit.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.3: start decision helpers (in-process)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-start-unit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

DX_CONTAINER_NAME=dx-u DX_REMOTE_HOST=nas-u.invalid DX_PERSIST_VOLUME=dx-u-persist
DX_PERSIST_HOST_ROOT=/share-u DX_PERSIST_STORAGE=host-path
unset DX_PERSIST_FRESH_START DX_PERSIST_HOST_MOUNT_SENTINEL
DIR=/share-u/dxe/dx-u/persist

# Recording stubs for every boundary a pure helper must not touch.
BIN="$(fake_tool_dir_create "$fixture")"
CALLS="$fixture/calls"
: >"$CALLS"
for t in ssh docker container mkdir mv rm chmod touch; do
    fake_tool_write "$BIN" "$t" "echo $t >> '$CALLS'; exit 99"
done

check() { # LABEL CONDITION...
    local label="$1"
    shift
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
one_error() { [ "$(grep -c '^Error:' <<<"$1")" = 1 ]; }
has() { grep -Fq -- "$2" <<<"$1"; }
same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}

# --- dx_persist_dir_record_path / _exists: fail-closed arms ------------------
got="$(XDG_STATE_HOME="" HOME="" dx_persist_dir_record_path)"
rc=$?
same "record path: no XDG_STATE_HOME and no HOME is non-zero, silent" "1|" "$rc|$got"
got="$(XDG_STATE_HOME="$fixture/xdg" DX_REMOTE_HOST="" dx_persist_dir_record_path)"
rc=$?
same "record path: an empty DX_REMOTE_HOST is non-zero, silent" "1|" "$rc|$got"
if XDG_STATE_HOME="$fixture/xdg" DX_REMOTE_HOST="" dx_persist_dir_record_exists; then
    test_pass "record exists: an unformable path counts as a record (fail-closed)"
else
    test_fail "record exists: an unformable path counts as a record (fail-closed)"
fi
if XDG_STATE_HOME="$fixture/xdg" dx_persist_dir_record_exists; then
    test_fail "record exists: a clean absence is status 1"
else
    test_pass "record exists: a clean absence is status 1"
fi

# --- dx_persist_start_decision: parser arms ----------------------------------
decide() { # WANT GUEST VOLUME RECORD OVERRIDE REPORT
    local got
    got="$(printf '%s' "$6" | PATH="$BIN:$PATH" dx_persist_start_decision "$2" "$3" "$4" "$5" 2>/dev/null)"
    check "decision: [$(tr '\n' '|' <<<"$6")] -> $1 (got $got)" [ "$got" = "$1" ]
}
decide refuse:root dx-u no no "" $'root=/s\nmounted=yes\nstate=absent\nmarker=absent\nleftover\n'
decide refuse:root dx-u no no "" $'root=/s\nmounted=yes\nstate=absent\nmarker=absent\nleftover'
decide create dx-u no no "" $'root=/s\nmounted=yes\nstate=absent\nmarker=absent'
decide refuse:root dx-u no no "" $'root=relative\nmounted=yes\nstate=absent\nmarker=absent\n'
decide refuse:empty "" yes no "" $'root=/s\nmounted=yes\nstate=empty\nmarker=absent\n'
decide refuse:retired dx-u no no "" $'root=/s\nmounted=yes\nstate=nonempty\nmarker=present\nschema=1\nguest=dx-u\nstate=retired'
check "decision: no runtime, remote or file-system call" [ ! -s "$CALLS" ]

# --- Recorders for the runtime and the controller state ----------------------
P_LOG="$fixture/log"
P_REPORT='' P_PROBE_RC=0 P_VOLUME=1 P_ENSURE_RC=0
dx_runtime_host_dir_probe() {
    echo "probe $1 $2" >>"$P_LOG"
    [ "$P_PROBE_RC" = 0 ] || return "$P_PROBE_RC"
    printf '%s\n' "$P_REPORT"
}
# The persist volume's state (WP4.4: dx_runtime_volume_state): P_VOLUME=0 is
# present, anything else absent.
dx_runtime_volume_state() {
    echo "volume_state $1" >>"$P_LOG"
    if [ "$P_VOLUME" = 0 ]; then echo present; else echo absent; fi
}
container_ensure_volume() { echo "ensure $1" >>"$P_LOG"; return "$P_ENSURE_RC"; }
rep() { # MOUNTED STATE MARKER [MARKER-TEXT]
    if [ "$3" = present ]; then
        printf 'root=/share-u\nmounted=%s\nstate=%s\nmarker=present\n%s' "$1" "$2" "$4"
    else
        printf 'root=/share-u\nmounted=%s\nstate=%s\nmarker=absent' "$1" "$2"
    fi
}
XDG_STATE_HOME="$fixture/state"
export XDG_STATE_HOME
REC="$fixture/state/dxe/persist-dirs/nas-u.invalid__dx-u"
record_on() { mkdir -p "${REC%/*}" && : >"$REC"; }
record_off() { rm -f "$REC"; }

# run_fn FN [ARG...]: call FN in a subshell; sets RC OUT ERR LOG.
run_fn() {
    : >"$P_LOG"
    OUT="$("$@" 2>"$fixture/err")"
    RC=$?
    ERR="$(cat "$fixture/err")"
    LOG="$(cat "$P_LOG")"
}

# --- dx_persist_host_dir_decide and every refusal message --------------------
refused() { # LABEL KEYWORD...
    local label="$1" k
    shift
    same "$label: status 1, nothing on stdout" "1|" "$RC|$OUT"
    check "$label: exactly one Error line" one_error "$ERR"
    for k in "$@"; do
        check "$label: the Error line names [$k]" has "$(grep '^Error:' <<<"$ERR")" "$k"
    done
}

DX_CONTAINER_NAME=_dx-u run_fn dx_persist_host_dir_decide
refused "decide, a guest name the directory cannot carry" DX_CONTAINER_NAME DX_PERSIST_STORAGE=volume
check "decide, a guest name the directory cannot carry: no probe, no lookup" [ -z "$LOG" ]

P_PROBE_RC=1
run_fn dx_persist_host_dir_decide
refused "decide, the probe fails" DX_PERSIST_HOST_ROOT=/share-u nas-u
check "decide: one probe of the configured root and guest, one volume lookup" \
    [ "$LOG" = "$(printf 'probe /share-u dx-u\nvolume_state dx-u-persist')" ]
P_PROBE_RC=0

P_REPORT="$(rep unknown nonempty present $'schema=1\nguest=dx-u\nstate=ready')"
run_fn dx_persist_host_dir_decide
same "decide, ready marker: prints ok, status 0, no Error" "0|ok|" "$RC|$OUT|$ERR"

P_REPORT="$(rep yes symlink absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:symlink" symlink "$DIR"

P_REPORT="$(rep yes nonempty present 'junk')"
run_fn dx_persist_host_dir_decide
refused "refuse:marker-invalid" "$DIR/.dxe-persist-dir"

P_REPORT="$(rep yes nonempty present $'schema=1\nguest=dx-v\nstate=ready')"
run_fn dx_persist_host_dir_decide
refused "refuse:marker-guest" "names guest dx-v, not dx-u"

P_REPORT="$(rep yes nonempty present $'schema=1\nguest=dx-u\nstate=copying\nsource-volume=old-vol')"
run_fn dx_persist_host_dir_decide
refused "refuse:copying with a source volume" "marked copying" "persist volume old-vol" dx-persist-migrate

P_REPORT="$(rep yes nonempty present $'schema=1\nguest=dx-u\nstate=copying')"
run_fn dx_persist_host_dir_decide
refused "refuse:copying without a source volume" "from the persist volume has not finished"

P_REPORT="$(rep yes nonempty present $'schema=1\nguest=dx-u\nstate=retired\nsource-volume=old-vol')"
run_fn dx_persist_host_dir_decide
refused "refuse:retired" "marked retired" "persist volume old-vol" DX_PERSIST_STORAGE=volume

P_REPORT="$(rep yes nonempty absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:unmarked" "not empty" dx-persist-migrate

P_VOLUME=0
P_REPORT="$(rep yes empty absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:empty, volume exists" "persist volume dx-u-persist exists" DX_PERSIST_FRESH_START=dx-u
check "refuse:empty, no override: no override hint" [ "$(grep -c 'does not name this guest' <<<"$ERR")" = 0 ]
record_on
DX_PERSIST_FRESH_START=dx-v run_fn dx_persist_host_dir_decide
refused "refuse:empty, volume and record, override for another guest" \
    "dx-u-persist exists and a host-path record exists" "DX_PERSIST_FRESH_START=dx-v does not name this guest" DX_PERSIST_FRESH_START=dx-u
P_VOLUME=1
run_fn dx_persist_host_dir_decide
refused "refuse:empty, record only" "(a host-path record exists)"

P_REPORT="$(rep yes absent absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:missing, record only, mounted" "$DIR is missing" "$REC" "never creates empty replacement storage"
check "refuse:missing, mounted: no mount hint" [ "$(grep -c 'mount or unlock' <<<"$ERR")" = 0 ]
record_off
P_VOLUME=0
P_REPORT="$(rep no absent absent)"
DX_PERSIST_HOST_MOUNT_SENTINEL=flag run_fn dx_persist_host_dir_decide
refused "refuse:missing, volume only, sentinel missing" "$DIR" dx-persist-migrate "DX_PERSIST_HOST_MOUNT_SENTINEL=flag is missing"
check "refuse:missing, volume only: no record named" [ "$(grep -c 'the record' <<<"$ERR")" = 0 ]
P_REPORT="$(rep unknown absent absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:missing, mount state unknown" "set DX_PERSIST_HOST_MOUNT_SENTINEL to have this checked"
P_VOLUME=1

P_REPORT="$(rep no absent absent)"
DX_PERSIST_HOST_MOUNT_SENTINEL=flag run_fn dx_persist_host_dir_decide
refused "refuse:unmounted" "/share-u does not look mounted" DX_PERSIST_HOST_MOUNT_SENTINEL=flag

P_REPORT="$(rep unknown empty absent)"
run_fn dx_persist_host_dir_decide
refused "refuse:mount-unknown" "cannot tell whether the share root /share-u is mounted" DX_PERSIST_HOST_MOUNT_SENTINEL

run_fn dx_persist_refusal refuse:bogus "" no no
check "refusal: an unknown token still gives one Error line" one_error "$ERR"
check "refusal: an unknown token is named" has "$ERR" "unexpected /persist decision 'refuse:bogus'"

# --- dx_persist_create_decision ----------------------------------------------
DX_PERSIST_STORAGE=volume run_fn dx_persist_create_decision
same "create decision, volume mode: status 0, silent, no call" "0|||" "$RC|$OUT|$ERR|$LOG"
P_REPORT="$(rep yes absent absent)"
run_fn dx_persist_create_decision
same "create decision, host-path, new guest on a mounted share: create, then the probe report" \
    "0|$(printf 'create\n%s' "$P_REPORT")" "$RC|$OUT"

# --- dx_persist_storage_ensure -------------------------------------------------
establish_log() { echo "establish $*" >>"$P_LOG"; return "${P_ESTABLISH_RC:-0}"; }
DX_PERSIST_STORAGE=volume run_fn dx_persist_storage_ensure ""
same "ensure, volume mode: the named volume is ensured, as before" \
    "0|ensure dx-u-persist|Ensuring persist volume dx-u-persist..." "$RC|$LOG|$OUT"
P_ENSURE_RC=4
DX_PERSIST_STORAGE=volume run_fn dx_persist_storage_ensure ""
check "ensure, volume mode: a failing ensure is returned" [ "$RC" -eq 4 ]
P_ENSURE_RC=0
dx_persist_dir_establish() { establish_log "$@"; }
dx_persist_dir_record_backfill() { echo "backfill $(printf '%s' "$*" | tr '\n' '|')" >>"$P_LOG"; }
run_fn dx_persist_storage_ensure ok
same "ensure, host-path ok: the record backfill (no report), no volume, no establish" "0|backfill " "$RC|$LOG"
run_fn dx_persist_storage_ensure "$(printf 'ok\nroot=/share-u\nmounted=yes')"
same "ensure, host-path ok: the backfill gets the report after the token" "0|backfill root=/share-u|mounted=yes" "$RC|$LOG"
check "ensure, host-path ok: names the directory" has "$OUT" "$DIR"
for pair in create:create adopt:adopt ok-fresh-start:fresh-start; do
    run_fn dx_persist_storage_ensure "${pair%%:*}"
    same "ensure, host-path ${pair%%:*}: establish ${pair#*:} once, never the volume" \
        "0|establish ${pair#*:}" "$RC|$LOG"
done
P_ESTABLISH_RC=3
run_fn dx_persist_storage_ensure create
check "ensure, host-path: a failing establish is returned" [ "$RC" -eq 3 ]
P_ESTABLISH_RC=0
run_fn dx_persist_storage_ensure ""
same "ensure, host-path without a decision: status 1, no call" \
    "1|" "$RC|$LOG"
check "ensure, host-path without a decision: one Error line" one_error "$ERR"

# --- dx_persist_start_check ----------------------------------------------------
DX_PERSIST_STORAGE=volume run_fn dx_persist_start_check
same "start check, volume mode: status 0, silent, no call" "0|||" "$RC|$OUT|$ERR|$LOG"
P_REPORT="$(rep unknown nonempty present $'schema=1\nguest=dx-u\nstate=ready')"
run_fn dx_persist_start_check
same "start check, ready marker: status 0, silent" "0||" "$RC|$OUT|$ERR"
P_REPORT="$(rep yes absent absent)"
run_fn dx_persist_start_check
refused "start check, new guest" "does not exist yet" dx-create-volumes
P_REPORT="$(rep yes empty absent)"
run_fn dx_persist_start_check
refused "start check, empty leftover" "empty and has no marker" dx-create-volumes
P_VOLUME=0
DX_PERSIST_FRESH_START=dx-u run_fn dx_persist_start_check
refused "start check, fresh start" "DX_PERSIST_FRESH_START is applied by dx-create-volumes"
P_VOLUME=1
P_REPORT="$(rep yes nonempty absent)"
run_fn dx_persist_start_check
refused "start check, a refusal" dx-persist-migrate

check "no runtime, remote or file-system tool was called by any helper" [ ! -s "$CALLS" ]

print_summary
exit_with_code
