#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.4b acceptance: safety hardening of the /persist migration path, from the
# WP6.4 verifier's findings (plans/do plan.md D-3, D-10 and the 2026-10-12
# progress log: the bare nixos/nix $DX_IMAGE has no sed and no awk; a stdin
# that the transport swallowed (WP-T1) reached a `docker run -i` marker write
# as nothing, and the marker step wrote an EMPTY marker and reported success).
# It extends, and never contradicts, WP4.4's tests/test_persist_dir_create.sh
# (establish, contract C) and WP6.4's tests/test_persist_migrate.sh (the
# command, contract E; marker_set, contract J2).
#
# Interface contract (pinned by this file; the implementation must match):
#
# A. The marker step shared by the NAS directory scripts
#    (DX_RUNTIME_DOCKER_HOST_DIR_MARKER_TAIL: the last part of the establish
#    and marker-set container scripts and of WP4.2's create and marker-write
#    NAS scripts) checks the marker bytes it received on stdin BEFORE the one
#    mv. It refuses -- non-zero, a `dx:` line on stderr, nothing on stdout,
#    the marker slot exactly as it was (no marker created, an existing one
#    byte-for-byte unchanged), and its temp file removed -- when:
#      - the bytes are empty (every script: establish, marker-set, create,
#        marker-write);
#      - establish and marker-set: the bytes do not hold exactly one line
#        starting `guest=`, the exact line `guest=GUEST` (GUEST is the
#        script's $2; another guest, a name that only shares a prefix, a
#        repeated or an extra guest line, or none at all is refused);
#      - marker-set: the bytes do not hold exactly one line starting
#        `state=`, the exact line `state=NEXT`, where NEXT is the state that
#        follows EXPECTED_STATE ($3): copying -> ready, ready -> retired.
#        Nothing follows retired, so EXPECTED_STATE=retired is refused before
#        anything is read or written.
#    For establish a refusal comes after the leaf exists, as WP4.4's crash
#    case: create leaves an empty, unmarked leaf (which the next run adopts);
#    adopt and fresh-start leave the empty leaf empty.
#    Every script stays ONE constant line of POSIX sh with no single quote,
#    passes `sh -n` (and `dash -n` where dash exists) and runs with ONLY the
#    bare image's tools: here the establish, create and marker-write scripts
#    run with PATH holding only sh, mkdir, ls, chown, chmod, mktemp, cat, mv
#    and rm, and the marker-set script with only sh, mktemp, cat, chmod, mv
#    and rm (no sed, awk or grep).
#
# B. End to end through the adapters: when the transport delivers an empty
#    stdin to the root one-off container (the WP-T1 failure),
#    dx_runtime_host_dir_marker_set and dx_runtime_host_dir_establish return
#    non-zero and leave no marker of those empty bytes; and
#    dx_persist_dir_establish (WP4.4 D) then fails with one Error line and
#    writes NO D-7 record.
#
# C. dx_persist_migrate_main re-checks the guest after the verification:
#    once the manifest verify has passed and before the marker-set to ready,
#    it calls dx_runtime_container_state "$DX_CONTAINER_NAME" (J1) a second
#    time. stopped or absent -> on (marker ready, record, report, exit 0);
#    running or unknown -> exit 1 with exactly ONE stderr line starting
#    "Error:" (naming the guest and "copying"; for running also
#    "dx-stop-container"), no marker-set (the directory's marker stays
#    copying), no D-7 record, no report, and the lock released last.
#
# D. dx_runtime_host_dir_marker_set refuses before any call (status 1,
#    nothing on stdout, a `dx:` reason on stderr and no line starting
#    "Error:", no transport, ssh or docker call) a ROOT of "/" in any
#    spelling ("/", "//", "/.", "/..", "/./") or any ROOT that is not in the
#    canonical form `pwd -P` prints (an empty, ".", ".." or trailing
#    component), as well as every ROOT the establish op refuses (empty, "-",
#    relative, holding "," or a newline). A canonical root other than "/"
#    -- even one whose names hold dots -- still gets its one call.
#
# Test-only conventions. Everything lives under one scratch area made by the
# WP0.2 fixtures; every fixture share is a directory this file created there.
# Section A runs the extracted scripts directly (the share root is the
# script's $1, as the bind target is in the container). Sections B and D
# replace dx_runtime_docker_cli, the adapter's transport to the NAS's docker,
# with an in-process stand-in: B's maps the bind target to its source and
# runs the script with the bare tools (optionally with an empty stdin); D's
# only records and never runs anything, and D runs with recording stubs for
# rm, chmod, chown, mv and find first on PATH (the "/" guard is in front of
# a root container that writes). Section C replaces the migration's runtime
# operations with in-process recorders that act on a fixture share (the
# WP6.4 unit suite's shape) and the lifecycle lock with a recorder.

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

test_section "WP6.4b: migration path hardening"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
SCRATCH_PHYS="$(cd -P "$SCRATCH" && pwd -P)"

G=dx-h
V=dx-h-persist
T_C=2026-10-01T10:00:00Z
T_M=2026-10-01T11:00:00Z
T_R=2026-10-02T09:00:00Z
MARKER_NAME=.dxe-persist-dir
OWNER="$(id -u):$(id -g)"
NL=$'\n'

DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST" DX_CONTAINER_NAME="$G" DX_GUEST_SYSTEM=x86_64-linux
DX_PERSIST_VOLUME="$V" DX_NIX_VOLUME=dx-h-nix DX_PERSIST_HOST_ROOT="$SCRATCH_PHYS/dxe-unused-root"
DX_PERSIST_HOST_MOUNT_SENTINEL=flag DX_IMAGE=img-h DXE_RUNTIME_DOCKER_BIN=docker
XDG_STATE_HOME="$SCRATCH_PHYS/dxe-state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_PERSIST_VOLUME DX_NIX_VOLUME
export DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL DX_IMAGE DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")"
CALLS="$SCRATCH/calls"
: >"$CALLS"
for t in ssh docker container; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$CALLS'; exit 99"
done
PATH="$BIN:$PATH"
export PATH

# Recording stubs that do nothing, put first on PATH whenever a dangerous
# path ("/") is handed to the code under test (common brief, safety rules).
STUBS="$SCRATCH/dxe-stub-bin"
STUBLOG="$SCRATCH/stublog"
: >"$STUBLOG"
for t in rm chmod chown mv find; do
    fake_tool_write "$STUBS" "$t" "printf '%s %s\n' $t \"\$*\" >>'$STUBLOG'
exit 0"
done

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
dx_lines() { grep -c '^dx: ' <<<"$1" || true; }
nonzero() { [ "$1" -ne 0 ]; }
mode_of() { file_mode "$1" 2>/dev/null; }
entries_of() { # DIR: its entries, one per line, sorted ("" when empty)
    (cd "$1" 2>/dev/null && ls -A | LC_ALL=C sort)
}

# The marker texts (WP4.1's format).
COPYING="$(dx_persist_marker_format "$G" copying "$V" "$T_C")"
READY="$(dx_persist_marker_format "$G" ready "$V" "$T_C" "$T_M")"
RETIRED="$(dx_persist_marker_format "$G" retired "$V" "$T_C" "$T_M" "$T_R")"

# bytes NAME TEXT: a stdin file holding TEXT plus one newline; `bytes NAME`
# alone makes an EMPTY one.
BYTES="$SCRATCH/dxe-bytes"
mkdir -p "$BYTES"
bytes() {
    if [ "$#" -eq 1 ]; then : >"$BYTES/$1"; else printf '%s\n' "$2" >"$BYTES/$1"; fi
}
bytes empty
printf '\n' >"$BYTES/newline"
bytes copying "$COPYING"
bytes ready "$READY"
bytes retired "$RETIRED"
bytes ready-other "$(dx_persist_marker_format dx-other ready "$V" "$T_C" "$T_M")"
bytes ready-prefix-long "$(dx_persist_marker_format "${G}2" ready "$V" "$T_C" "$T_M")"
bytes ready-prefix-short "$(dx_persist_marker_format dx ready "$V" "$T_C" "$T_M")"
bytes copying-other "$(dx_persist_marker_format dx-other copying "$V" "$T_C")"
bytes no-guest "$(printf 'schema=1\nstate=ready\nsource-volume=%s\ncreated-at=%s' "$V" "$T_C")"
bytes two-guests "$(printf 'schema=1\nguest=%s\nguest=%s\nstate=ready\nsource-volume=%s' "$G" "$G" "$V")"
bytes extra-guest "$(printf 'schema=1\nguest=%s\nguest=dx-other\nstate=ready\nsource-volume=%s' "$G" "$V")"
bytes guest-space "$(printf 'schema=1\nguest=%s \nstate=ready\nsource-volume=%s' "$G" "$V")"
bytes no-state "$(printf 'schema=1\nguest=%s\nsource-volume=%s\ncreated-at=%s' "$G" "$V" "$T_C")"
bytes two-states "$(printf 'schema=1\nguest=%s\nstate=ready\nstate=ready\nsource-volume=%s' "$G" "$V")"
bytes ready-and-copying "$(printf 'schema=1\nguest=%s\nstate=ready\nstate=copying\nsource-volume=%s' "$G" "$V")"

# =============================================================================
# A. The shared marker step, in the extracted scripts, with the bare tools.

# restricted DIR TOOL...: DIR holds a symlink to each TOOL (found on the
# normal PATH) and nothing else.
restricted() {
    local dir="$1" t p
    shift
    mkdir -p "$dir"
    for t in "$@"; do
        p="$(command -v "$t")" || { echo "restricted: no $t on this host" >&2; return 1; }
        ln -s "$p" "$dir/$t"
    done
}
ENV_BIN="$(command -v env)"
in_bare() { # DIR CMD ARG...: CMD from the scratch area, with an empty environment and PATH=DIR
    local dir="$1"
    shift
    (cd "$SCRATCH" && "$ENV_BIN" -i PATH="$dir" HOME="$SCRATCH" TMPDIR="$SCRATCH" "$@")
}
EST_TOOLS="$SCRATCH/dxe-bare-establish"
MS_TOOLS="$SCRATCH/dxe-bare-marker-set"
restricted "$EST_TOOLS" sh mkdir ls chown chmod mktemp cat mv rm
restricted "$MS_TOOLS" sh mktemp cat chmod mv rm
for tool_dir in "$EST_TOOLS" "$MS_TOOLS"; do
    for absent in sed awk grep; do
        in_bare "$tool_dir" "$tool_dir/sh" -c "$absent --version </dev/null" >/dev/null 2>&1
        check "bare PATH ${tool_dir##*/}: $absent is not reachable (the restriction is real)" nonzero "$?"
    done
done

# The scripts' shape: one constant line, POSIX, no single quote.
SH_BIN="$(command -v sh)"
DASH_BIN="$(command -v dash 2>/dev/null || true)"
for var in DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT \
    DX_RUNTIME_DOCKER_HOST_DIR_CREATE_SCRIPT DX_RUNTIME_DOCKER_HOST_DIR_MARKER_WRITE_SCRIPT; do
    text="${!var}"
    case "$text" in
        "" | *"$NL"* | *"'"*) test_fail "$var is one non-empty line without a single quote" ;;
        *) test_pass "$var is one non-empty line without a single quote" ;;
    esac
    printf '%s\n' "$text" >"$SCRATCH/script.sh"
    check "$var passes sh -n" "$SH_BIN" -n "$SCRATCH/script.sh"
    if [ -n "$DASH_BIN" ]; then check "$var passes dash -n" "$DASH_BIN" -n "$SCRATCH/script.sh"; fi
done

# share: a new fixture share root (with its sentinel "flag"); prints its path.
share() {
    local d
    d="$(mktemp -d "$SCRATCH_PHYS/dxe-share.XXXXXX")" || return 1
    : >"$d/flag"
    printf '%s\n' "$d"
}

# est_run ROOT MODE BYTES: the establish script as the root container runs it,
# with stdin from the named bytes file. Sets RC OUT ERR.
est_run() {
    OUT="$(in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT" sh \
        "${1:?}" "$G" "$2" "$OWNER" flag <"$BYTES/$3" 2>"$SCRATCH/err")"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
}
# est_refused LABEL ROOT: a refusal after the leaf exists: non-zero, one dx:
# line, nothing on stdout, the leaf an empty directory (no marker, no temp).
est_refused() {
    local label="$1" leaf="$2/dxe/$G/persist"
    check "$label: non-zero" nonzero "$RC"
    same "$label: nothing on stdout" "" "$OUT"
    same "$label: one dx: line on stderr says why" 1 "$(dx_lines "$ERR")"
    check "$label: the leaf is a directory" test -d "$leaf"
    same "$label: the leaf is left empty and unmarked (no marker, no temp file)" "" "$(entries_of "$leaf")"
}

test_section "WP6.4b A: establish refuses marker bytes that are empty or not for GUEST"
R="$(share)"
est_run "$R" create copying
same "establish create, the copying marker: status 0, nothing on stderr" "0|" "$RC|$ERR"
same "establish create: the marker holds exactly the bytes sent" "$COPYING" "$(cat "$R/dxe/$G/persist/$MARKER_NAME" 2>/dev/null)"
same "establish create: leaf 0755, marker 0644, no temp file" "755|644|$MARKER_NAME" \
    "$(mode_of "$R/dxe/$G/persist")|$(mode_of "$R/dxe/$G/persist/$MARKER_NAME")|$(entries_of "$R/dxe/$G/persist")"

R="$(share)"
est_run "$R" create empty
est_refused "establish create, EMPTY stdin (the bytes were lost in transport)" "$R"
check "establish create, empty stdin: no marker file at all" test ! -e "$R/dxe/$G/persist/$MARKER_NAME"
R="$(share)"
mkdir -p "$R/dxe/$G/persist"
est_run "$R" adopt empty
est_refused "establish adopt, empty stdin" "$R"
R="$(share)"
mkdir -p "$R/dxe/$G/persist"
est_run "$R" fresh-start empty
est_refused "establish fresh-start, empty stdin" "$R"
R="$(share)"
est_run "$R" create newline
est_refused "establish create, a lone newline" "$R"
for case_ in "ready-other:a marker for another guest" \
    "ready-prefix-long:a guest that only shares a prefix ($G is a prefix of it)" \
    "ready-prefix-short:a guest that is a prefix of $G" \
    "no-guest:no guest line" \
    "two-guests:the guest line twice" \
    "extra-guest:a second, other guest line" \
    "guest-space:a guest line with a trailing space (not exact)"; do
    R="$(share)"
    est_run "$R" create "${case_%%:*}"
    est_refused "establish create, ${case_#*:}" "$R"
done
R="$(share)"
mkdir -p "$R/dxe/$G/persist"
est_run "$R" adopt ready-other
est_refused "establish adopt, a marker for another guest" "$R"
R="$(share)"
mkdir -p "$R/dxe/$G/persist"
est_run "$R" adopt ready
same "establish adopt, this guest's ready marker: status 0 (any state is accepted)" "0|$READY" \
    "$RC|$(cat "$R/dxe/$G/persist/$MARKER_NAME" 2>/dev/null)"

test_section "WP6.4b A: marker-set refuses bytes that are empty, not for GUEST or not the next state"
# ms_world CURRENT: a share whose leaf holds the marker CURRENT and one data
# file. Sets R and LEAF.
ms_world() {
    R="$(share)"
    LEAF="$R/dxe/$G/persist"
    mkdir -p "$LEAF"
    printf '%s\n' "$1" >"$LEAF/$MARKER_NAME"
    printf 'data\n' >"$LEAF/plain.txt"
}
# ms_run EXPECTED BYTES: the marker-set script with the bare marker-set tools.
ms_run() {
    OUT="$(in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT" sh \
        "${R:?}" "$G" "$1" "$V" <"$BYTES/$2" 2>"$SCRATCH/err")"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
}
# ms_refused LABEL CURRENT: non-zero, one dx: line, nothing on stdout, the
# marker byte-for-byte CURRENT, no temp file left.
ms_refused() {
    local label="$1"
    check "$label: non-zero" nonzero "$RC"
    same "$label: nothing on stdout" "" "$OUT"
    same "$label: one dx: line on stderr says why" 1 "$(dx_lines "$ERR")"
    same "$label: the marker is unchanged" "$2" "$(cat "$LEAF/$MARKER_NAME" 2>/dev/null)"
    same "$label: no temp file is left (only the marker and the data)" "$(printf '%s\n%s' "$MARKER_NAME" plain.txt)" "$(entries_of "$LEAF")"
}

ms_world "$COPYING"
ms_run copying ready
same "marker-set copying -> ready, this guest's ready bytes: status 0" "0|" "$RC|$ERR"
same "marker-set copying -> ready: the marker holds exactly the bytes sent" "$READY" "$(cat "$LEAF/$MARKER_NAME")"
same "marker-set copying -> ready: marker 0644, no temp file" "644|$(printf '%s\n%s' "$MARKER_NAME" plain.txt)" \
    "$(mode_of "$LEAF/$MARKER_NAME")|$(entries_of "$LEAF")"
for case_ in "empty:EMPTY stdin (the bytes were lost in transport)" \
    "newline:a lone newline" \
    "ready-other:ready bytes for another guest" \
    "ready-prefix-long:ready bytes for a guest that only shares a prefix" \
    "no-guest:bytes without a guest line" \
    "two-guests:bytes with the guest line twice" \
    "extra-guest:bytes with a second, other guest line" \
    "copying:bytes still in state copying (no transition)" \
    "retired:bytes in state retired (copying cannot jump to retired)" \
    "no-state:bytes without a state line" \
    "two-states:bytes with the state line twice" \
    "ready-and-copying:bytes with a second, other state line"; do
    ms_world "$COPYING"
    ms_run copying "${case_%%:*}"
    ms_refused "marker-set copying, ${case_#*:}" "$COPYING"
done

ms_world "$READY"
ms_run ready retired
same "marker-set ready -> retired, this guest's retired bytes: status 0" "0|$RETIRED" "$RC|$(cat "$LEAF/$MARKER_NAME")"
for case_ in "empty:EMPTY stdin" "ready:bytes still in state ready" "copying:bytes in state copying (no way back)"; do
    ms_world "$READY"
    ms_run ready "${case_%%:*}"
    ms_refused "marker-set ready, ${case_#*:}" "$READY"
done
for b in retired ready copying; do
    ms_world "$RETIRED"
    ms_run retired "$b"
    ms_refused "marker-set from retired ($b bytes): nothing follows retired" "$RETIRED"
done

test_section "WP6.4b A: WP4.2's create and marker-write scripts refuse empty marker bytes"
R="$(share)"
OUT="$(in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_CREATE_SCRIPT" sh "$R" "$G" \
    <"$BYTES/empty" 2>"$SCRATCH/err")"
RC=$?
ERR="$(cat "$SCRATCH/err")"
check "create, empty stdin: non-zero" nonzero "$RC"
same "create, empty stdin: one dx: line on stderr" 1 "$(dx_lines "$ERR")"
same "create, empty stdin: no marker and no temp file in the new leaf" "" "$(entries_of "$R/dxe/$G/persist")"
R="$(share)"
OUT="$(in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_CREATE_SCRIPT" sh "$R" "$G" \
    <"$BYTES/ready" 2>"$SCRATCH/err")"
same "create, the ready marker: status 0, the marker holds it" "0|$READY" "$?|$(cat "$R/dxe/$G/persist/$MARKER_NAME" 2>/dev/null)"
ms_world "$READY"
OUT="$(in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_WRITE_SCRIPT" sh "$LEAF" \
    <"$BYTES/empty" 2>"$SCRATCH/err")"
RC=$?
ERR="$(cat "$SCRATCH/err")"
ms_refused "marker-write, empty stdin" "$READY"
OUT="$(in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_WRITE_SCRIPT" sh "$LEAF" \
    <"$BYTES/retired" 2>"$SCRATCH/err")"
same "marker-write, a marker: status 0, the marker holds it" "0|$RETIRED" "$?|$(cat "$LEAF/$MARKER_NAME")"

# =============================================================================
# B. Through the adapters, with the container's stdin lost in transport.

# transport DOCKER-ARGV...: stands in for dx_runtime_docker_cli. It records
# the call, then runs `run ... --mount type=bind,source=SRC,target=TGT
# --entrypoint sh IMAGE -c SCRIPT ARG...` as the root one-off container
# would: TGT is mapped to SRC in the arguments and SCRIPT runs under sh with
# only the bare tools. With P_LOSE_STDIN=1 the container's stdin arrives
# empty, as when the transport swallowed it (WP-T1).
transport() {
    local src="" tgt="" rest a mapped=()
    echo "cli ${1:-}" >>"$CALLS"
    [ "${1:-}" = run ] || return 99
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rm | -i) shift ;;
            --network | --user | --pull | --entrypoint) shift 2 ;;
            --mount)
                rest="${2#type=bind,source=}"
                src="${rest%%,target=*}"
                tgt="${rest#*,target=}"
                shift 2 ;;
            *) break ;;
        esac
    done
    shift
    case "$src" in
        "$SCRATCH_PHYS"/dxe-share.*) : ;;
        *) echo "transport: refusing a bind source outside the fixture shares: [$src]" >&2; return 99 ;;
    esac
    for a in "$@"; do
        if [ -n "$tgt" ] && [ "$a" = "$tgt" ]; then mapped+=("$src"); else mapped+=("$a"); fi
    done
    if [ "${P_LOSE_STDIN:-0}" = 1 ]; then
        cat >/dev/null
        in_bare "$EST_TOOLS" "$EST_TOOLS/sh" "${mapped[@]}" </dev/null
    else
        in_bare "$EST_TOOLS" "$EST_TOOLS/sh" "${mapped[@]}"
    fi
}
# via FN ARG...: FN in a subshell whose transport is the stand-in. Sets RC OUT ERR CALLED.
via() {
    : >"$CALLS"
    OUT="$( (
        dx_runtime_docker_cli() { transport "$@"; }
        "$@"
    ) 2>"$SCRATCH/err" )"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    CALLED="$(cat "$CALLS")"
}

test_section "WP6.4b B: a lost stdin no longer writes an empty marker"
ms_world "$COPYING"
via dx_runtime_host_dir_marker_set "$R" "$G" copying "$READY"
same "marker_set, stdin delivered: status 0, one call, the marker is ready (the stand-in is faithful)" \
    "0|cli run|$READY" "$RC|$CALLED|$(cat "$LEAF/$MARKER_NAME")"
ms_world "$COPYING"
P_LOSE_STDIN=1 via dx_runtime_host_dir_marker_set "$R" "$G" copying "$READY"
check "marker_set, stdin lost: non-zero" nonzero "$RC"
same "marker_set, stdin lost: the one call was made" "cli run" "$CALLED"
same "marker_set, stdin lost: nothing on stdout" "" "$OUT"
same "marker_set, stdin lost: the marker is still exactly copying" "$COPYING" "$(cat "$LEAF/$MARKER_NAME")"
same "marker_set, stdin lost: no temp file is left" "$(printf '%s\n%s' "$MARKER_NAME" plain.txt)" "$(entries_of "$LEAF")"

R="$(share)"
via dx_runtime_host_dir_establish create "$R" "$G" "$OWNER" "$COPYING"
same "establish, stdin delivered: status 0, the marker is copying" "0|$COPYING" \
    "$RC|$(cat "$R/dxe/$G/persist/$MARKER_NAME" 2>/dev/null)"
R="$(share)"
P_LOSE_STDIN=1 via dx_runtime_host_dir_establish create "$R" "$G" "$OWNER" "$COPYING"
check "establish, stdin lost: non-zero" nonzero "$RC"
same "establish, stdin lost: the leaf is left empty and unmarked" "" "$(entries_of "$R/dxe/$G/persist")"

R="$(share)"
# A state directory of its own, so no earlier case's record can be mistaken
# for this one's.
REC="$(XDG_STATE_HOME="$R-state" dx_persist_dir_record_path)"
XDG_STATE_HOME="$R-state" DX_PERSIST_HOST_ROOT="$R" DX_PERSIST_DIR_OWNER="$OWNER" P_LOSE_STDIN=1 \
    via dx_persist_dir_establish create
same "dx_persist_dir_establish, stdin lost: status 1 with one Error line" "1|1" "$RC|$(error_lines "$ERR")"
check "dx_persist_dir_establish, stdin lost: no D-7 record is written" test ! -e "$REC"
check "dx_persist_dir_establish, stdin lost: no marker in the leaf" test ! -e "$R/dxe/$G/persist/$MARKER_NAME"

# =============================================================================
# C. dx_persist_migrate_main: the guest is checked again after the verification.

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
# mig_case STATE...: one dx_persist_migrate_main run on a new fixture share;
# the guest's state answers are STATE... in call order (unknown = the
# operation's non-zero "unknown"). Each case has a state directory of its own
# (the D-7 record's path does not depend on the share). Sets RC OUT ERR SEQ
# LEAF REC.
mig_case() {
    R="$(share)"
    LEAF="$R/dxe/$G/persist"
    : >"$OPS"
    printf '%s\n' "$@" >"$STATES"
    echo 0 >"$STATE_N"
    REC="$(XDG_STATE_HOME="$R-state" dx_persist_dir_record_path)"
    OUT="$( (
        DX_PERSIST_HOST_ROOT="$R"
        XDG_STATE_HOME="$R-state"
        dx_lifecycle_lock_hold() { echo lock >>"$OPS"; }
        dx_lifecycle_lock_drop() { echo unlock >>"$OPS"; }
        dx_runtime_container_state() {
            local n s
            n=$(($(cat "$STATE_N") + 1))
            echo "$n" >"$STATE_N"
            s="$(sed -n "${n}p" "$STATES")"
            echo "state $1" >>"$OPS"
            echo "${s:-unknown}"
            [ "${s:-unknown}" != unknown ]
        }
        dx_runtime_volume_owned() { echo "owned $1" >>"$OPS"; }
        dx_runtime_host_dir_probe() { echo "probe" >>"$OPS"; printf 'root=%s\nmounted=yes\nstate=absent\nmarker=absent\n' "$1"; }
        dx_runtime_volume_inventory() { echo "inventory" >>"$OPS"; printf '%s\n' "$INV_OK"; }
        dx_runtime_host_rsync_check() { echo "rsync-check" >>"$OPS"; echo version=3.3.0; }
        dx_runtime_host_dir_establish() {
            echo "establish $1" >>"$OPS"
            mkdir -p "$2/dxe/$3/persist" && printf '%s\n' "$5" >"$2/dxe/$3/persist/$MARKER_NAME"
        }
        dx_runtime_host_rsync() { echo "rsync $1" >>"$OPS"; }
        dx_runtime_host_manifest_verify() { echo "verify $1" >>"$OPS"; }
        dx_runtime_host_dir_marker_set() {
            echo "marker-set $3" >>"$OPS"
            printf '%s\n' "$4" >"$1/dxe/$2/persist/$MARKER_NAME"
        }
        dx_persist_migrate_main
    ) 2>"$SCRATCH/err" )"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    SEQ="$(grep -e '^state ' -e '^verify ' -e '^marker-set ' "$OPS" | tr '\n' '|' | sed 's/|$//')"
}
marker_state() { sed -n 's/^state=//p' "$LEAF/$MARKER_NAME" 2>/dev/null; }

test_section "WP6.4b C: the guest is re-checked after the verification, before the ready marker"
mig_case stopped stopped
same "stopped, then stopped: exit 0" 0 "$RC"
same "stopped, then stopped: the state is checked first and again between the verification and the marker-set" \
    "state $G|verify forward|state $G|marker-set copying" "$SEQ"
same "stopped, then stopped: the marker is ready" ready "$(marker_state)"
check "stopped, then stopped: the D-7 record is written" test -f "$REC"
check "stopped, then stopped: the report is printed" has "$OUT" "migrated: $LEAF"

mig_case stopped absent
same "stopped, then absent (removed meanwhile): exit 0, marker ready, record written" "0|ready|yes" \
    "$RC|$(marker_state)|$([ -f "$REC" ] && echo yes)"

c_refused() { # LABEL KEYWORD...: the re-check's refusal
    local label="$1" line k
    shift
    same "$label: exit 1" 1 "$RC"
    same "$label: exactly one Error: line, on stderr" "1|0" "$(error_lines "$ERR")|$(error_lines "$OUT")"
    line="$(grep '^Error:' <<<"$ERR" || true)"
    for k in "$@"; do
        check "$label: the Error line names [$k]" has "$line" "$k"
    done
    same "$label: verified, re-checked, and no marker-set" "state $G|verify forward|state $G" "$SEQ"
    same "$label: the marker stays exactly copying" "$(dx_persist_marker_format "$G" copying "$V" "$(sed -n 's/^created-at=//p' "$LEAF/$MARKER_NAME" 2>/dev/null)")" \
        "$(cat "$LEAF/$MARKER_NAME" 2>/dev/null)"
    same "$label: the marker's state is copying" copying "$(marker_state)"
    check "$label: no D-7 record" test ! -e "$REC"
    check "$label: no report" test -z "$(grep '^migrated:' <<<"$OUT" || true)"
    same "$label: the lock is released last" unlock "$(tail -n 1 "$OPS")"
}
mig_case stopped running
c_refused "stopped, then RUNNING after the verification" "$G" "dx-stop-container" "copying"
mig_case stopped unknown
c_refused "stopped, then UNKNOWN after the verification" "$G" "copying"

# =============================================================================
# D. dx_runtime_host_dir_marker_set refuses "/" and non-canonical roots
# before any call. A recording transport that never runs anything, and
# recording stubs for the destructive tools first on PATH.

# ms_root ROOT: dx_runtime_host_dir_marker_set ROOT GUEST copying READY.
ms_root() {
    : >"$CALLS"
    : >"$STUBLOG"
    OUT="$( (
        PATH="$STUBS:$PATH"
        dx_runtime_docker_cli() { echo "cli ${1:-}" >>"$CALLS"; cat >/dev/null; return 0; }
        dx_runtime_host_dir_marker_set "$1" "$G" copying "$READY"
    ) 2>"$SCRATCH/err" )"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    CALLED="$(cat "$CALLS")"
}
ms_root_refused() { # LABEL ROOT
    ms_root "$2"
    same "$1: status 1" 1 "$RC"
    same "$1: nothing on stdout" "" "$OUT"
    same "$1: no transport, ssh or docker call" "" "$CALLED"
    same "$1: no destructive tool ran" "" "$(cat "$STUBLOG")"
    if [ "$(dx_lines "$ERR")" -ge 1 ] && [ "$(error_lines "$ERR")" = 0 ]; then
        test_pass "$1: a dx: reason on stderr, not an Error: line"
    else
        test_fail "$1: a dx: reason on stderr, not an Error: line (stderr: $ERR)"
    fi
}

test_section "WP6.4b D: marker_set refuses / and non-canonical roots before any call"
ms_root_refused "marker_set, ROOT /" /
ms_root_refused "marker_set, ROOT //" //
ms_root_refused "marker_set, ROOT /." /.
ms_root_refused "marker_set, ROOT /.." /..
ms_root_refused "marker_set, ROOT /./" /./
ms_root_refused "marker_set, ROOT with a trailing /" "$SCRATCH_PHYS/dxe-d-share/"
ms_root_refused "marker_set, ROOT with an empty component" "$SCRATCH_PHYS//dxe-d-share"
ms_root_refused "marker_set, ROOT with a . component" "$SCRATCH_PHYS/./dxe-d-share"
ms_root_refused "marker_set, ROOT with a .. component" "$SCRATCH_PHYS/dxe-d-share/../dxe-d-share"
ms_root_refused "marker_set, ROOT ending in /.." "$SCRATCH_PHYS/dxe-d-share/.."
ms_root_refused "marker_set, empty ROOT (as establish)" ""
ms_root_refused "marker_set, ROOT - (as establish)" -
ms_root_refused "marker_set, relative ROOT (as establish)" share/root
ms_root_refused "marker_set, ROOT with a comma (as establish)" "$SCRATCH_PHYS/a,readonly=false"
ms_root_refused "marker_set, ROOT with a newline (as establish)" "$SCRATCH_PHYS/a${NL}b"
ms_root "$SCRATCH_PHYS/dxe-d-share/a..b/.c"
same "marker_set, a canonical root whose names hold dots: status 0 and its one call" "0|cli run" "$RC|$CALLED"
ms_root "$SCRATCH_PHYS/dxe-d-share"
same "marker_set, a canonical root: status 0 and its one call" "0|cli run" "$RC|$CALLED"

print_summary
exit_with_code
