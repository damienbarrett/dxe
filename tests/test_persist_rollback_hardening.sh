#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.5b acceptance: safety hardening of dx-persist-rollback, the WP6.4b
# guest re-check carried over to the rollback (plans/do plan.md D-3, D-10;
# spec R36, section 6.1). It extends, and never contradicts, WP6.5's
# tests/test_persist_rollback.sh (the command, contract E) and WP6.4b's
# tests/test_persist_migrate_hardening.sh (contract C, the migration's
# re-check).
#
# Interface contract (pinned by this file; the implementation must match):
#
# A. dx_persist_rollback_main re-checks the guest after the verification. In
#    host-path mode the directory IS the guest's /persist, so a guest started
#    during the copy or the verification may have changed it after rsync read
#    it, and the new volume would then not hold what the directory holds.
#    Once the manifest verify (reverse) has passed and BEFORE the marker-set
#    ready -> retired, it calls dx_runtime_container_state
#    "$DX_CONTAINER_NAME" (WP6.4 J1) a second time (the first is still the
#    first call after the lock, WP6.5 E1):
#      stopped or absent -> on (marker retired, report, exit 0);
#      running or unknown (the operation's non-zero) -> exit 1 with exactly
#      ONE line starting "Error:", on stderr (none on stdout), naming the
#      guest, NAME, "--volume" (run again with a NEW --volume name) and
#      "ready" (the directory stays ready); for running also
#      "dx-stop-container". No marker-set: the marker stays ready, byte for
#      byte. No report. NAME is kept (B), and the lock is released last.
#
# B. The kept volume. Every failure AFTER NAME was created -- the copy
#    failed (exit 1), the copy did not verify (exit 3), the guest re-check
#    refused (A, exit 1), the controller's clock was unusable after the
#    verification (exit 1), the marker could not be set to retired (exit 1)
#    -- also prints exactly ONE line, on stderr, that does not start with
#    "Error:" and holds "docker volume rm NAME", with no volume-name
#    character ([A-Za-z0-9_.-]) right after NAME (so the command can be
#    copied as it stands): how to remove NAME if it is not wanted. It is only
#    printed; nothing removes NAME (no runtime call beyond the run's own
#    operations, and no tool call at all). The command's one Error line stays
#    the only one. A failure BEFORE NAME exists (the volume cannot be
#    created; a refusal such as an existing NAME) and a successful run print
#    no "docker volume rm" anywhere.
#
# Test-only conventions. Everything lives under one scratch area made by the
# WP0.2 fixtures; every fixture share is a directory this file created there.
# The rollback's runtime operations are replaced by in-process recorders that
# act on a fixture share (the WP6.5 unit suite's shape), and the lifecycle
# lock by a recorder. ssh, docker and container are fail-closed recording
# tools: none may be called. Nothing here deletes or moves anything outside
# the scratch area, and no case hands a dangerous path to the code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../bin/lib/dx-config.sh
source "$BASE_DIR/bin/lib/dx-config.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-container.sh
source "$BASE_DIR/bin/lib/dx-container.sh"
# shellcheck source=../bin/lib/dx-persist-dir.sh
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP6.5b: rollback hardening"

SCRATCH="$(persist_fixture_root_create)" || exit 1
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
SCRATCH_PHYS="$(cd -P "$SCRATCH" && pwd -P)"

G=dx-rb
V=dx-rb-persist
NEW=dx-rb-new
T_C=2026-10-01T10:00:00Z
T_M=2026-10-01T11:00:00Z
MARKER_NAME=.dxe-persist-dir

DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST" DX_CONTAINER_NAME="$G" DX_GUEST_SYSTEM=x86_64-linux
DX_PERSIST_VOLUME="$V" DX_NIX_VOLUME=dx-rb-nix DX_BOOTSTRAP_VOLUME=dx-rb-bootstrap
DX_PERSIST_HOST_ROOT="$SCRATCH_PHYS/dxe-unused-root" DX_PERSIST_HOST_MOUNT_SENTINEL=flag
DX_IMAGE=img-rb DXE_RUNTIME_DOCKER_BIN=docker XDG_STATE_HOME="$SCRATCH_PHYS/dxe-state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_PERSIST_VOLUME DX_NIX_VOLUME DX_BOOTSTRAP_VOLUME
export DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL DX_IMAGE DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")" || exit 1
CALLS="$SCRATCH/calls"
: >"$CALLS"
for t in ssh docker container; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$CALLS'; exit 99"
done
PATH="$BIN:$PATH"
export PATH

same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}
check() { # LABEL CONDITION...
    local label="$1"
    shift
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
has() { grep -Fq -- "$2" <<<"$1"; }
error_lines() { grep -c '^Error:' <<<"$1" || true; }
rm_lines() { grep -cF -- 'docker volume rm' <<<"$1" || true; }

# The ready marker the migration left (WP4.1's format).
READY="$(dx_persist_marker_format "$G" ready "$V" "$T_C" "$T_M")"

share() {
    local d
    d="$(mktemp -d "$SCRATCH_PHYS/dxe-share.XXXXXX")" || return 1
    : >"$d/flag"
    printf '%s\n' "$d"
}

OPS="$SCRATCH/ops"
STATES="$SCRATCH/states"
STATE_N="$SCRATCH/state-n"
INV_OK='df_avail_kb=900
size_kb=100
entries=5
hardlinks=0
appledouble=0
special=0
acl=0
xattr=0
status=ok'

# rb_case STATE...: one dx_persist_rollback_main --volume NEW on a new
# fixture share whose directory holds the ready marker and one file. The
# guest's state answers are STATE... in call order (unknown = the operation's
# non-zero "unknown"; a missing answer is unknown). Knobs from the
# environment: P_TARGET (the volume_state answer for NEW, default absent),
# P_CREATE_RC, P_RSYNC_RC, P_VERIFY_RC, P_MS_RC (the operations' statuses,
# default 0) and P_CLOCK (the controller's UTC time; default the real one).
# Sets RC OUT ERR SEQ OPSEQ LEAF CALLED.
rb_case() {
    R="$(share)" || exit 1
    LEAF="$R/dxe/$G/persist"
    mkdir -p "$LEAF"
    printf '%s\n' "$READY" >"$LEAF/$MARKER_NAME"
    echo data >"$LEAF/plain.txt"
    : >"$OPS"
    : >"$CALLS"
    printf '%s\n' "$@" >"$STATES"
    echo 0 >"$STATE_N"
    OUT="$( (
        DX_PERSIST_HOST_ROOT="$R"
        dx_lifecycle_lock_hold() { echo lock >>"$OPS"; }
        dx_lifecycle_lock_drop() { echo unlock >>"$OPS"; }
        dx_runtime_host_copy_containers() { :; } # WP6.4c: no copy or verify container is left
        dx_runtime_container_state() {
            local n s
            n=$(($(cat "$STATE_N") + 1))
            echo "$n" >"$STATE_N"
            s="$(sed -n "${n}p" "$STATES")"
            echo "state $1" >>"$OPS"
            echo "${s:-unknown}"
            [ "${s:-unknown}" != unknown ]
        }
        dx_runtime_host_dir_probe() {
            echo "probe $1 $2" >>"$OPS"
            printf 'root=%s\nmounted=yes\nstate=nonempty\nmarker=present\n' "$1"
            cat "$1/dxe/$2/persist/$MARKER_NAME"
        }
        dx_runtime_volume_state() { echo "volume-state $1" >>"$OPS"; echo "${P_TARGET:-absent}"; }
        dx_runtime_host_dir_inventory() { echo "inventory $1" >>"$OPS"; printf '%s\n' "$INV_OK"; }
        dx_runtime_host_rsync_check() { echo "rsync-check" >>"$OPS"; echo version=3.3.0; }
        dx_runtime_volume_create() { echo "create $1" >>"$OPS"; return "${P_CREATE_RC:-0}"; }
        dx_runtime_host_rsync() { echo "rsync $1 $2" >>"$OPS"; return "${P_RSYNC_RC:-0}"; }
        dx_runtime_host_manifest_verify() { echo "verify $1 $2" >>"$OPS"; return "${P_VERIFY_RC:-0}"; }
        dx_runtime_host_dir_marker_set() {
            echo "marker-set $3" >>"$OPS"
            [ "${P_MS_RC:-0}" = 0 ] || return "$P_MS_RC"
            printf '%s\n' "$4" >"$1/dxe/$2/persist/$MARKER_NAME"
        }
        if [ -n "${P_CLOCK:-}" ]; then
            dx_persist_dir_utc_now() { echo "$P_CLOCK"; }
        fi
        dx_persist_rollback_main --volume "$NEW"
    ) 2>"$SCRATCH/err" )"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    CALLED="$(cat "$CALLS")"
    SEQ="$(grep -e '^state ' -e '^verify ' -e '^marker-set ' "$OPS" | tr '\n' '|' | sed 's/|$//')"
    OPSEQ="$(sed 's/ .*//' "$OPS" | tr '\n' '|' | sed 's/|$//')"
}
marker_state() { sed -n 's/^state=//p' "$LEAF/$MARKER_NAME" 2>/dev/null; }

# names_rm LINE: LINE holds "docker volume rm NEW" and no volume-name
# character follows NEW.
names_rm() {
    local rest="${1#*docker volume rm "$NEW"}"
    [ "$rest" != "$1" ] || return 1
    case "$rest" in
        [A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

# expect_kept LABEL: B's one line for a failure after NEW was created.
expect_kept() {
    local label="$1" line
    line="$(grep -F -- 'docker volume rm' <<<"$ERR" || true)"
    same "$label: exactly one line says docker volume rm, on stderr (none on stdout)" "1|0" \
        "$(rm_lines "$ERR")|$(rm_lines "$OUT")"
    if names_rm "$line"; then test_pass "$label: that line holds 'docker volume rm $NEW', ready to copy"
    else test_fail "$label: that line holds 'docker volume rm $NEW', ready to copy (line: $line)"; fi
    same "$label: that line is not an Error: line" 0 "$(error_lines "$line")"
    same "$label: the command's Error line stays the only one" "1|0" "$(error_lines "$ERR")|$(error_lines "$OUT")"
    same "$label: nothing is removed (no tool call at all)" "" "$CALLED"
    same "$label: and no runtime operation but the run's own" "" \
        "$(grep -v -e '^lock$' -e '^unlock$' -e '^state ' -e '^probe ' -e '^volume-state ' -e '^inventory ' \
            -e '^rsync-check$' -e '^create ' -e '^rsync ' -e '^verify ' -e '^marker-set ' "$OPS" || true)"
}
# expect_no_rm LABEL: no "docker volume rm" anywhere.
expect_no_rm() {
    same "$1: no line says docker volume rm (stderr|stdout)" "0|0" "$(rm_lines "$ERR")|$(rm_lines "$OUT")"
    same "$1: no tool call" "" "$CALLED"
}

# =============================================================================
test_section "WP6.5b A: the guest is re-checked after the verification, before the retired marker"

rb_case stopped stopped
same "stopped, then stopped: exit 0" 0 "$RC"
same "stopped, then stopped: the state is checked first and again between the verification and the marker-set" \
    "state $G|verify reverse $NEW|state $G|marker-set ready" "$SEQ"
same "stopped, then stopped: the guest check is still the first call after the lock" "lock|state" \
    "$(sed -n 1,2p "$OPS" | sed 's/ .*//' | tr '\n' '|' | sed 's/|$//')"
same "stopped, then stopped: the marker is retired" retired "$(marker_state)"
check "stopped, then stopped: the report is printed" has "$OUT" "rolled_back: $LEAF"
same "stopped, then stopped: no Error line" "0|0" "$(error_lines "$ERR")|$(error_lines "$OUT")"
same "stopped, then stopped: the lock is released last" unlock "$(tail -n 1 "$OPS")"
expect_no_rm "stopped, then stopped"

rb_case stopped absent
same "stopped, then absent (removed meanwhile): exit 0, marker retired, report" "0|retired|yes" \
    "$RC|$(marker_state)|$(has "$OUT" "rolled_back: $LEAF" && echo yes)"

a_refused() { # LABEL KEYWORD...: the re-check's refusal
    local label="$1" line k
    shift
    same "$label: exit 1" 1 "$RC"
    same "$label: exactly one Error: line, on stderr" "1|0" "$(error_lines "$ERR")|$(error_lines "$OUT")"
    line="$(grep '^Error:' <<<"$ERR" || true)"
    for k in "$@"; do
        check "$label: the Error line names [$k]" has "$line" "$k"
    done
    same "$label: copied, verified, re-checked, and no marker-set" \
        "state $G|verify reverse $NEW|state $G" "$SEQ"
    same "$label: the run went create, copy, verify, then the re-check, and stopped" \
        "lock|state|probe|volume-state|inventory|rsync-check|create|rsync|verify|state|unlock" "$OPSEQ"
    same "$label: the marker stays ready, byte for byte" "$READY" "$(cat "$LEAF/$MARKER_NAME" 2>/dev/null)"
    same "$label: no report" "" "$(grep '^rolled_back:' <<<"$OUT" || true)"
    same "$label: the lock is released last" unlock "$(tail -n 1 "$OPS")"
    expect_kept "$label"
}
rb_case stopped running
a_refused "stopped, then RUNNING after the verification" "$G" "dx-stop-container" "$NEW" "--volume" "ready"
rb_case stopped unknown
a_refused "stopped, then UNKNOWN after the verification" "$G" "$NEW" "--volume" "ready"

# =============================================================================
test_section "WP6.5b B: a failure after the new volume exists says how to remove it"

P_RSYNC_RC=23 rb_case stopped stopped
same "the copy fails: exit 1, no verification, no marker-set" "1|state $G" "$RC|$SEQ"
same "the copy fails: the marker stays ready" "$READY" "$(cat "$LEAF/$MARKER_NAME")"
expect_kept "the copy fails"

P_VERIFY_RC=1 rb_case stopped stopped
same "the copy does not verify: exit 3, no re-check, no marker-set" "3|state $G|verify reverse $NEW" "$RC|$SEQ"
same "the copy does not verify: the marker stays ready" "$READY" "$(cat "$LEAF/$MARKER_NAME")"
expect_kept "the copy does not verify"

P_CLOCK=later rb_case stopped stopped
same "an unusable clock after the verification: exit 1, no marker-set" "1|0" \
    "$RC|$(grep -c '^marker-set' "$OPS" || true)"
same "an unusable clock: the marker stays ready" "$READY" "$(cat "$LEAF/$MARKER_NAME")"
expect_kept "an unusable clock after the verification"

P_MS_RC=1 rb_case stopped stopped
same "the marker cannot be set to retired: exit 1, after the re-check" \
    "1|state $G|verify reverse $NEW|state $G|marker-set ready" "$RC|$SEQ"
same "the marker cannot be set: it stays ready" "$READY" "$(cat "$LEAF/$MARKER_NAME")"
expect_kept "the marker cannot be set to retired"

P_CREATE_RC=1 rb_case stopped stopped
same "the volume cannot be created: exit 1, one Error line, no copy" "1|1|0" \
    "$RC|$(error_lines "$ERR")|$(grep -c '^rsync ' "$OPS" || true)"
expect_no_rm "the volume cannot be created (it does not exist)"

P_TARGET=present rb_case stopped stopped
same "NAME already exists: refused (exit 1, one Error line), nothing created" "1|1|0" \
    "$RC|$(error_lines "$ERR")|$(grep -c '^create ' "$OPS" || true)"
expect_no_rm "NAME already exists (a refusal; not the rollback's volume)"

rb_case running
same "the guest is running at the start: refused (exit 1, one Error line), nothing created" "1|1|0" \
    "$RC|$(error_lines "$ERR")|$(grep -c '^create ' "$OPS" || true)"
expect_no_rm "the guest is running at the start"

print_summary
exit_with_code
