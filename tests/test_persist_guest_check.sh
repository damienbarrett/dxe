#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -euo pipefail

# WP4.5 acceptance: the guest's own /persist mount and marker check (spec
# R17 "In the guest too"; spec section 3 "Guest bootstrap and /persist";
# plan D-9). Docker's restart policy can start a host-path guest after a NAS
# reboot without any host-side check, so the guest bootstrap itself must
# refuse to touch a /persist that is not the guest's own mounted, `ready`
# directory.
#
# Interface contract (container/dx-nixos-26.05/bootstrap/persistence.sh):
#
#   setup_persist [PERSIST_ROOT]        unchanged signature, default /persist.
#     The mode reaches the guest as environment variables, exactly as
#     dx-create-container passes them in host-path mode (WP3.3):
#     DX_PERSIST_STORAGE=host-path and DX_PERSIST_DIR_GUEST=<container name>.
#
#   Volume mode -- DX_PERSIST_STORAGE unset, empty or "volume": unchanged.
#     No mount-point probe (no `mountpoint` / `findmnt` call), no marker read
#     (no dx_persist_marker_parse call), no output, the same chown / chmod /
#     install / mkdir sequence as before, and a missing PERSIST_ROOT is still
#     skipped silently (the "No persist volume mounted" path: the guest boots
#     on its own filesystem).
#
#   Any other DX_PERSIST_STORAGE value fails closed, as DX_NIX_STORAGE_MODE
#     does in base-and-storage.sh: non-zero, with the one Error line below
#     containing  unknown DX_PERSIST_STORAGE '<value>'
#
#   Host-path mode -- DX_PERSIST_STORAGE=host-path. Before ANY mutating
#     command (chown, chmod, chgrp, install, mkdir, mv, rm, ln, touch, cp:
#     none at all, anywhere), setup_persist checks, on PERSIST_ROOT as passed
#     (never a hard-coded /persist):
#       a. DX_PERSIST_DIR_GUEST is non-empty (unset counts as empty);
#       b. PERSIST_ROOT is a mount point;
#       c. PERSIST_ROOT/.dxe-persist-dir ($DX_PERSIST_MARKER_NAME) exists;
#       d. it parses with the SHARED parser dx_persist_marker_parse from
#          container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh, which
#          persistence.sh sources (sibling-relative, as it already sources
#          ../scripts/lib/dx-persist-relocate.sh) and never copies. The file
#          is fed on stdin (`dx_persist_marker_parse < "$marker"`, not at the
#          end of a pipe) and the verdict is read from DX_PERSIST_MARKER_GUEST
#          and DX_PERSIST_MARKER_STATE. A marker the parser rejects (including
#          an unknown state) is "malformed";
#       e. DX_PERSIST_MARKER_GUEST equals DX_PERSIST_DIR_GUEST;
#       f. DX_PERSIST_MARKER_STATE is "ready".
#     The order of a-f is free; every case below breaks exactly one.
#     On the first failure setup_persist RETURNS (does not exit, and does
#     not rely on errexit) non-zero, having printed nothing on stdout and
#     exactly ONE line on stderr. That line starts with "Error: " and
#     contains the fixed string for its check, where R is PERSIST_ROOT as
#     passed and M is R/.dxe-persist-dir:
#       a. DX_PERSIST_DIR_GUEST is empty
#       b. R is not a mount point
#       c. M is missing
#       d. M is malformed          (the parser's own "dx-persist-marker: ..."
#                                   stderr line must not appear as a second
#                                   line: fold it in or discard it)
#       e. M names guest <marker guest>, not <DX_PERSIST_DIR_GUEST>
#       f. M has state <state>, not ready
#     and none of the other checks' phrases. The rest of the line (a prefix,
#     a hint naming the fix) is free.
#     On success the check writes nothing (the marker is never rewritten),
#     prints no "Error:" line, and setup_persist continues into exactly the
#     volume-mode sequence, starting with `chown dx:dx R` and
#     `chmod 0755 R`. Because bootstrap.sh runs bootstrap_phases under
#     `set -e`, a refusal stops the boot at setup_persist: configure_ssh and
#     every later phase never run.
#
#   Mount-point probe: `mountpoint` (for example `mountpoint -q R`) or
#     `findmnt` (for example the established `findmnt -n -o TARGET R`,
#     compared with R exactly, as prepare_nix_volume_direct_impl does for
#     /nix), called by plain command name so that a shell-function stub
#     replaces it -- the seam tests/test_section3_bootstrap.sh already uses
#     for findmnt. The stubs below model both tools over a fixture mount
#     table in which "/" and the listed directories are mount points:
#       - `mountpoint [-q|--quiet] [--nofollow] R` succeeds only for a listed
#         path (exit 32 otherwise, like util-linux);
#       - `findmnt R` and `findmnt -M|--mountpoint R` print a row only for a
#         listed path and exit 1 otherwise;
#       - `findmnt -T|--target R` prints the nearest mounted ancestor-or-self,
#         so its exit status alone does not prove R is a mount point;
#       - findmnt options -n -r -l -f -k, -o/--output with TARGET, SOURCE,
#         FSTYPE, OPTIONS, and combined short flags (-rn, -no, -rno TARGET).
#     Paths are canonicalised (symlinks resolved) as the real tools do. Any
#     other probe (stat device numbers, /proc/self/mountinfo) is invisible to
#     the stubs and fails the happy path.
#
# Test seams: setup_persist's PERSIST_ROOT argument (fixture directories
# under one canonical temporary root); shell-function RECORDING stubs for
# every mutating command (plus the same names as recording executables first
# on PATH, for `command chown` and the like); an `id` stub that reports no
# dx account, so the volume-mode sequence is the fixed seven calls in
# pg_baseline. All file activity stays inside $TMP_ROOT.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "WP4.5: guest /persist mount and marker check"

BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
MARKER_LIB="$CONTAINER_DIR/scripts/lib/dx-persist-marker.sh"

# One canonical temporary root (symlinks resolved, so a probe that
# canonicalises the path sees the same string the test passed). Removed on
# exit only when it is provably the directory this run created.
TMP_RAW="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-guest-check.XXXXXX")" || exit 1
TMP_ROOT="$(cd "$TMP_RAW" && pwd -P)" || exit 1
pg_cleanup() {
    case "$TMP_ROOT" in
        */dxe-persist-guest-check.??????)
            if [ -d "$TMP_ROOT" ] && [ ! -L "$TMP_ROOT" ]; then
                rm -rf -- "$TMP_ROOT"
            fi
            ;;
    esac
}
trap pg_cleanup EXIT

# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$BOOTSTRAP_DIR/common.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/persistence.sh
source "$BOOTSTRAP_DIR/persistence.sh"

GUEST=dx-unit
OTHER=dx-intruder
PG_MUTATORS="chown chmod chgrp install mkdir mv rm ln touch cp"

# Recording executables for the mutating commands, first on PATH inside every
# stubbed run: they only append "<name> <args>" to $PG_CALLS.
PG_STUB_BIN="$TMP_ROOT/stub-bin"
for pg_name in $PG_MUTATORS; do
    fake_tool_write "$PG_STUB_BIN" "$pg_name" 'printf "%s %s\n" "${0##*/}" "$*" >>"$PG_CALLS"
exit 0'
done

# --- Fixture mount table -------------------------------------------------

pg_canon() {
    local p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
    else
        printf '%s\n' "$p"
    fi
}

# "/" is always mounted; $PG_MOUNTS lists the other mount points, one per line.
pg_is_mounted() {
    local c m
    c="$(pg_canon "$1")"
    [ "$c" != / ] || return 0
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        if [ "$(pg_canon "$m")" = "$c" ]; then return 0; fi
    done <<EOF
${PG_MOUNTS:-}
EOF
    return 1
}

pg_stub_mountpoint() {
    printf 'mountpoint %s\n' "$*" >>"$PG_PROBES"
    local quiet=0 path="" arg
    for arg in "$@"; do
        case "$arg" in
            -q | --quiet) quiet=1 ;;
            --nofollow) : ;;
            -*) echo "test stub: unsupported mountpoint option $arg" >&2; return 2 ;;
            *) path="$arg" ;;
        esac
    done
    if [ -z "$path" ]; then
        echo "test stub: mountpoint needs a path" >&2
        return 2
    fi
    if pg_is_mounted "$path"; then
        [ "$quiet" -eq 1 ] || printf '%s is a mountpoint\n' "$path"
        return 0
    fi
    [ "$quiet" -eq 1 ] || printf '%s is not a mountpoint\n' "$path"
    return 32
}

pg_stub_findmnt() {
    printf 'findmnt %s\n' "$*" >>"$PG_PROBES"
    local mode=exact path="" cols=TARGET,SOURCE,FSTYPE,OPTIONS heading=1
    local arg flags ch value target col line sep
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            --) if [ "$#" -gt 0 ]; then path="$1"; shift; fi ;;
            -o | --output) cols="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi ;;
            --output=*) cols="${arg#*=}" ;;
            -M | --mountpoint) mode=exact; path="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi ;;
            --mountpoint=*) mode=exact; path="${arg#*=}" ;;
            -T | --target) mode=target; path="${1:-}"; if [ "$#" -gt 0 ]; then shift; fi ;;
            --target=*) mode=target; path="${arg#*=}" ;;
            -n | --noheadings) heading=0 ;;
            -r | --raw | -l | --list | -f | --first-only | -k | --kernel) : ;;
            -[A-Za-z]*)
                flags="${arg#-}"
                while [ -n "$flags" ]; do
                    ch="${flags:0:1}"
                    flags="${flags:1}"
                    case "$ch" in
                        n) heading=0 ;;
                        r | l | f | k) : ;;
                        o | M | T)
                            if [ -n "$flags" ]; then
                                value="$flags"
                                flags=""
                            else
                                value="${1:-}"
                                if [ "$#" -gt 0 ]; then shift; fi
                            fi
                            case "$ch" in
                                o) cols="$value" ;;
                                M) mode=exact; path="$value" ;;
                                *) mode=target; path="$value" ;;
                            esac
                            ;;
                        *) echo "test stub: unsupported findmnt option -$ch" >&2; return 2 ;;
                    esac
                done
                ;;
            -*) echo "test stub: unsupported findmnt option $arg" >&2; return 2 ;;
            *) path="$arg" ;;
        esac
    done
    if [ -z "$path" ]; then
        echo "test stub: findmnt without a path is not modelled" >&2
        return 2
    fi
    path="$(pg_canon "$path")"
    if [ "$mode" = exact ]; then
        pg_is_mounted "$path" || return 1
        target="$path"
    else
        target="$path"
        while ! pg_is_mounted "$target"; do
            target="${target%/*}"
            [ -n "$target" ] || target=/
        done
    fi
    cols="$(printf '%s' "$cols" | tr '[:lower:]' '[:upper:]')"
    if [ "$heading" -eq 1 ]; then
        printf '%s\n' "$(printf '%s' "$cols" | tr ',' ' ')"
    fi
    line=""
    sep=""
    local IFS=,
    for col in $cols; do
        case "$col" in
            TARGET) value="$target" ;;
            SOURCE) if [ "$target" = / ]; then value=overlay; else value=/dev/dxe-fixture-persist; fi ;;
            FSTYPE) if [ "$target" = / ]; then value=overlay; else value=ext4; fi ;;
            OPTIONS) value=rw,relatime ;;
            *) echo "test stub: unsupported findmnt column $col" >&2; return 2 ;;
        esac
        line="$line$sep$value"
        sep=" "
    done
    printf '%s\n' "$line"
}

# Called inside a subshell (or the bootstrap probe) only: shadows every
# mutating command with a recorder, reports no dx account, and routes the two
# mount-point tools to the fixture mount table.
pg_define_stubs() {
    chown() { printf 'chown %s\n' "$*" >>"$PG_CALLS"; }
    chmod() { printf 'chmod %s\n' "$*" >>"$PG_CALLS"; }
    chgrp() { printf 'chgrp %s\n' "$*" >>"$PG_CALLS"; }
    install() { printf 'install %s\n' "$*" >>"$PG_CALLS"; }
    mkdir() { printf 'mkdir %s\n' "$*" >>"$PG_CALLS"; }
    mv() { printf 'mv %s\n' "$*" >>"$PG_CALLS"; }
    rm() { printf 'rm %s\n' "$*" >>"$PG_CALLS"; }
    ln() { printf 'ln %s\n' "$*" >>"$PG_CALLS"; }
    touch() { printf 'touch %s\n' "$*" >>"$PG_CALLS"; }
    cp() { printf 'cp %s\n' "$*" >>"$PG_CALLS"; }
    id() {
        case " $* " in
            *" dx "*) return 1 ;;
        esac
        command id "$@"
    }
    mountpoint() { pg_stub_mountpoint "$@"; }
    findmnt() { pg_stub_findmnt "$@"; }
}

# Shadows of the shared parser, for the "sourced, not copied" cases.
# shellcheck disable=SC2034 # the DX_PERSIST_MARKER_* results are read by setup_persist
pg_define_parse_accept() {
    dx_persist_marker_parse() {
        printf 'dx_persist_marker_parse %s\n' "$*" >>"$PG_PARSE_LOG"
        cat >"$PG_PARSE_LOG.stdin"
        DX_PERSIST_MARKER_GUEST=dx-unit
        DX_PERSIST_MARKER_STATE=ready
        DX_PERSIST_MARKER_SOURCE_VOLUME=
        DX_PERSIST_MARKER_CREATED_AT=
        DX_PERSIST_MARKER_MIGRATED_AT=
        DX_PERSIST_MARKER_RETIRED_AT=
        return 0
    }
}
# shellcheck disable=SC2034 # the DX_PERSIST_MARKER_* results are read by setup_persist
pg_define_parse_reject() {
    dx_persist_marker_parse() {
        printf 'dx_persist_marker_parse %s\n' "$*" >>"$PG_PARSE_LOG"
        cat >"$PG_PARSE_LOG.stdin"
        DX_PERSIST_MARKER_GUEST=
        DX_PERSIST_MARKER_STATE=
        DX_PERSIST_MARKER_SOURCE_VOLUME=
        DX_PERSIST_MARKER_CREATED_AT=
        DX_PERSIST_MARKER_MIGRATED_AT=
        DX_PERSIST_MARKER_RETIRED_AT=
        echo "dx-persist-marker: unknown key" >&2
        return 1
    }
}

# --- Fixture helpers -----------------------------------------------------

pg_marker_text() { # STATE [GUEST]
    printf 'schema=1\nguest=%s\nstate=%s\ncreated-at=2026-10-11T00:00:00Z\n' "${2:-$GUEST}" "$1"
}

# pg_new_case NAME: a fresh case directory with an (unmounted) persist root.
pg_new_case() {
    PG_DIR="$TMP_ROOT/cases/$1"
    PG_ROOT="$PG_DIR/persist"
    PG_MARKER="$PG_ROOT/.dxe-persist-dir"
    mkdir -p "$PG_ROOT" "$PG_DIR/log"
}

pg_snapshot() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        echo absent
        return 0
    fi
    find "$1" -exec ls -ldn {} + | LC_ALL=C sort
}

# pg_run DIR ROOT MODE GUEST MOUNTS [accept|reject]
#   MODE and GUEST are a value or "-" for unset. Runs setup_persist ROOT in a
#   subshell with errexit OFF (the refusal must be an explicit return) and
#   nounset ON (as in bootstrap.sh), every stub in place.
pg_run() {
    local dir="$1" root="$2" mode="$3" guest="$4" mounts="$5" parse="${6:-}"
    : >"$dir/log/calls"
    : >"$dir/log/probes"
    : >"$dir/log/parse"
    pg_snapshot "$root" >"$dir/log/before"
    (
        set +e
        if [ "$mode" = - ]; then unset DX_PERSIST_STORAGE; else export DX_PERSIST_STORAGE="$mode"; fi
        if [ "$guest" = - ]; then unset DX_PERSIST_DIR_GUEST; else export DX_PERSIST_DIR_GUEST="$guest"; fi
        export PG_CALLS="$dir/log/calls" PG_PROBES="$dir/log/probes" PG_PARSE_LOG="$dir/log/parse"
        export PG_MOUNTS="$mounts"
        pg_define_stubs
        case "$parse" in
            accept) pg_define_parse_accept ;;
            reject) pg_define_parse_reject ;;
        esac
        PATH="$PG_STUB_BIN:$PATH"
        setup_persist "$root" </dev/null >"$dir/log/out" 2>"$dir/log/err"
        printf '%s\n' "$?" >"$dir/log/rc"
    ) || true
    pg_snapshot "$root" >"$dir/log/after"
}

# The volume-mode sequence (no dx account in the fixture) for root $1.
pg_baseline() {
    printf '%s\n' \
        "chown dx:dx $1" \
        "chmod 0755 $1" \
        "install -d -o dx -g dx -m 0755 $1/home $1/home/dx" \
        "mkdir -p $1/home/dx" \
        "mkdir -p $1/home/dx/.local" \
        "mkdir -p $1/home/dx/.local/state" \
        "mkdir -p $1/home/dx/.local/share"
}

pg_phrase_for() {
    case "$1" in
        guest) printf '%s' 'DX_PERSIST_DIR_GUEST is empty' ;;
        mount) printf '%s' ' is not a mount point' ;;
        missing) printf '%s' '.dxe-persist-dir is missing' ;;
        malformed) printf '%s' '.dxe-persist-dir is malformed' ;;
        other) printf '%s' '.dxe-persist-dir names guest ' ;;
        state) printf '%s' '.dxe-persist-dir has state ' ;;
        mode) printf '%s' 'unknown DX_PERSIST_STORAGE' ;;
    esac
}

pg_report() { # LABEL DIR PROBLEMS
    if [ -z "$3" ]; then
        test_pass "$1"
    else
        test_fail "$1 [$3] (stderr: $(cat "$2/log/err" 2>/dev/null); calls: $(tr '\n' ';' <"$2/log/calls"))"
    fi
}

# pg_expect_refusal LABEL DIR KIND PHRASE
#   KIND is a check name from pg_phrase_for, or "any" (no wording pinned).
pg_expect_refusal() {
    local label="$1" dir="$2" kind="$3" phrase="${4:-}" problems="" rc line lines other own
    if [ ! -f "$dir/log/rc" ]; then
        problems="$problems setup_persist did not return (it exited or aborted);"
    else
        rc="$(cat "$dir/log/rc")"
        [ "$rc" != 0 ] || problems="$problems returned 0;"
    fi
    [ ! -s "$dir/log/out" ] || problems="$problems stdout not empty: $(cat "$dir/log/out");"
    lines="$(awk 'END { print NR }' "$dir/log/err")"
    [ "$lines" = 1 ] || problems="$problems stderr has $lines lines, not exactly 1;"
    line="$(head -n 1 "$dir/log/err")"
    case "$line" in
        "Error: "*) : ;;
        *) problems="$problems first stderr line does not start with 'Error: ';" ;;
    esac
    if [ "$kind" != any ]; then
        case "$line" in
            *"$phrase"*) : ;;
            *) problems="$problems missing the phrase '$phrase';" ;;
        esac
        own="$(pg_phrase_for "$kind")"
        for other in guest mount missing malformed other state mode; do
            [ "$other" != "$kind" ] || continue
            case "$line" in
                *"$(pg_phrase_for "$other")"*)
                    problems="$problems also names the '$other' check;" ;;
            esac
        done
        case "$line" in
            *"$own"*) : ;;
            *) problems="$problems does not name the '$kind' check;" ;;
        esac
    fi
    [ ! -s "$dir/log/calls" ] || problems="$problems a mutating command ran;"
    cmp -s "$dir/log/before" "$dir/log/after" || problems="$problems the persist root changed;"
    pg_report "$label" "$dir" "$problems"
}

# pg_expect_proceeds LABEL DIR ROOT [quiet]
#   setup_persist returned 0, printed no Error line (with "quiet": printed
#   nothing at all), ran exactly the volume-mode sequence, and changed nothing
#   on disk itself.
pg_expect_proceeds() {
    local label="$1" dir="$2" root="$3" quiet="${4:-}" problems=""
    if [ ! -f "$dir/log/rc" ]; then
        problems="$problems setup_persist did not return (it exited or aborted);"
    elif [ "$(cat "$dir/log/rc")" != 0 ]; then
        problems="$problems returned $(cat "$dir/log/rc");"
    fi
    if grep -Fq 'Error:' "$dir/log/out" "$dir/log/err"; then
        problems="$problems printed an Error line;"
    fi
    if [ "$quiet" = quiet ] && { [ -s "$dir/log/out" ] || [ -s "$dir/log/err" ]; }; then
        problems="$problems printed output in volume mode: $(cat "$dir/log/out" "$dir/log/err");"
    fi
    pg_baseline "$root" >"$dir/log/expected-calls"
    cmp -s "$dir/log/expected-calls" "$dir/log/calls" \
        || problems="$problems the call sequence is not the volume-mode sequence;"
    cmp -s "$dir/log/before" "$dir/log/after" || problems="$problems the persist root changed;"
    pg_report "$label" "$dir" "$problems"
}

pg_probe_named_root() { # DIR ROOT -> the mount-point probe ran against ROOT
    [ -s "$1/log/probes" ] || return 1
    case "$(cat "$1/log/probes")" in
        *"$2"*) return 0 ;;
    esac
    return 1
}

# --- Host-path mode: every refusal stops before any mutation -------------

pg_new_case not-a-mount-point
pg_marker_text ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_DIR"
pg_expect_refusal "host-path: /persist is not a mount point (only its parent is) -> one Error line, no chown, non-zero" \
    "$PG_DIR" mount "$PG_ROOT is not a mount point"

pg_new_case absent-root
rmdir "$PG_ROOT"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" ""
pg_expect_refusal "host-path: a missing /persist is refused as not a mount point (never silently skipped), nothing created" \
    "$PG_DIR" mount "$PG_ROOT is not a mount point"

pg_new_case marker-missing
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: mounted /persist without .dxe-persist-dir -> 'is missing', no chown, non-zero" \
    "$PG_DIR" missing "$PG_MARKER is missing"

pg_new_case other-guest
pg_marker_text ready "$OTHER" >"$PG_MARKER"
cp "$PG_MARKER" "$PG_DIR/marker.orig"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: a ready marker naming another guest -> 'names guest $OTHER, not $GUEST', no chown, non-zero" \
    "$PG_DIR" other "$PG_MARKER names guest $OTHER, not $GUEST"

pg_new_case state-copying
pg_marker_text copying >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: this guest's marker in state copying -> 'has state copying, not ready', no chown, non-zero" \
    "$PG_DIR" state "$PG_MARKER has state copying, not ready"

pg_new_case state-retired
printf '%s\n' schema=1 "guest=$GUEST" state=retired source-volume=dx-unit-persist \
    created-at=2026-10-01T08:00:00Z migrated-at=2026-10-01T09:30:00Z \
    retired-at=2026-10-05T12:00:00Z >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: this guest's marker in state retired (after a rollback) -> 'has state retired, not ready', no chown, non-zero" \
    "$PG_DIR" state "$PG_MARKER has state retired, not ready"

pg_new_case malformed-garbage
printf '%s\n' 'this is not a marker' >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: an unparseable marker -> 'is malformed' (one line; the parser's own reason line does not leak), no chown" \
    "$PG_DIR" malformed "$PG_MARKER is malformed"

pg_new_case malformed-schema
printf '%s\n' schema=2 "guest=$GUEST" state=ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: a marker with an unknown schema -> 'is malformed', no chown, non-zero" \
    "$PG_DIR" malformed "$PG_MARKER is malformed"

pg_new_case malformed-empty
: >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: an empty marker file is malformed, not missing; no chown, non-zero" \
    "$PG_DIR" malformed "$PG_MARKER is malformed"

pg_new_case malformed-state
printf '%s\n' schema=1 "guest=$GUEST" state=paused >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_refusal "host-path: a state the shared parser rejects (paused) -> 'is malformed', no chown, non-zero" \
    "$PG_DIR" malformed "$PG_MARKER is malformed"

pg_new_case guest-empty
pg_marker_text ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "" "$PG_ROOT"
pg_expect_refusal "host-path: DX_PERSIST_DIR_GUEST set but empty -> 'DX_PERSIST_DIR_GUEST is empty', no chown, non-zero" \
    "$PG_DIR" guest "DX_PERSIST_DIR_GUEST is empty"

pg_new_case guest-unset
pg_marker_text ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path - "$PG_ROOT"
pg_expect_refusal "host-path: DX_PERSIST_DIR_GUEST unset (nounset on) -> 'DX_PERSIST_DIR_GUEST is empty', no chown, non-zero" \
    "$PG_DIR" guest "DX_PERSIST_DIR_GUEST is empty"

pg_new_case unknown-mode
pg_marker_text ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" bogus "$GUEST" "$PG_ROOT"
pg_expect_refusal "an unknown DX_PERSIST_STORAGE value fails closed (\"unknown DX_PERSIST_STORAGE 'bogus'\"), no chown, non-zero" \
    "$PG_DIR" mode "unknown DX_PERSIST_STORAGE 'bogus'"

pg_new_case symlinked-root
rmdir "$PG_ROOT"
mkdir -p "$PG_DIR/real-persist"
pg_marker_text ready >"$PG_DIR/real-persist/.dxe-persist-dir"
ln -s "$PG_DIR/real-persist" "$PG_ROOT"
pg_snapshot "$PG_DIR/real-persist" >"$PG_DIR/log/target-before"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_DIR/real-persist"
pg_snapshot "$PG_DIR/real-persist" >"$PG_DIR/log/target-after"
if cmp -s "$PG_DIR/log/target-before" "$PG_DIR/log/target-after"; then
    pg_expect_refusal "host-path: a symlinked /persist (to a mounted, ready directory) is still refused with one Error line, no chown" \
        "$PG_DIR" any
else
    test_fail "host-path: a symlinked /persist (to a mounted, ready directory) is still refused with one Error line, no chown [the symlink target changed]"
fi

# The other-guest case also proves the guest never rewrites a marker it
# refuses.
if cmp -s "$TMP_ROOT/cases/other-guest/marker.orig" "$TMP_ROOT/cases/other-guest/persist/.dxe-persist-dir"; then
    test_pass "host-path: a refused marker is left byte-for-byte unchanged"
else
    test_fail "host-path: a refused marker is left byte-for-byte unchanged"
fi

# --- Host-path mode: the happy path proceeds to the usual chown -----------

pg_new_case happy-ready
pg_marker_text ready >"$PG_MARKER"
cp "$PG_MARKER" "$PG_DIR/marker.orig"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_proceeds "host-path: mounted /persist with this guest's ready marker proceeds to exactly the usual chown dx:dx / chmod 0755 / install sequence" \
    "$PG_DIR" "$PG_ROOT"
if pg_probe_named_root "$PG_DIR" "$PG_ROOT" && cmp -s "$PG_DIR/marker.orig" "$PG_MARKER"; then
    test_pass "host-path: the happy path asked mountpoint/findmnt about the persist root itself and left the marker unchanged"
else
    test_fail "host-path: the happy path asked mountpoint/findmnt about the persist root itself and left the marker unchanged (probes: $(tr '\n' ';' <"$PG_DIR/log/probes"))"
fi

pg_new_case happy-migrated
printf '%s\n' schema=1 "guest=$GUEST" state=ready source-volume=dx-unit-persist \
    created-at=2026-10-01T08:00:00Z migrated-at=2026-10-01T09:30:00Z >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT"
pg_expect_proceeds "host-path: a ready marker written by a verified migration (source-volume, migrated-at) proceeds to the usual sequence" \
    "$PG_DIR" "$PG_ROOT"
if pg_probe_named_root "$PG_DIR" "$PG_ROOT"; then
    test_pass "host-path: the migrated-marker path also ran the mount-point probe on the persist root"
else
    test_fail "host-path: the migrated-marker path also ran the mount-point probe on the persist root (probes: $(tr '\n' ';' <"$PG_DIR/log/probes"))"
fi

# --- Volume mode: unchanged, no mount or marker check ---------------------

# Each volume-mode root is NOT a mount point and carries a marker that names
# another guest in state retired: any mount or marker check would refuse.
for pg_variant in unset empty volume; do
    pg_new_case "volume-$pg_variant"
    pg_marker_text retired "$OTHER" >"$PG_MARKER"
    case "$pg_variant" in
        unset) pg_run "$PG_DIR" "$PG_ROOT" - - "" reject ;;
        empty) pg_run "$PG_DIR" "$PG_ROOT" "" - "" reject ;;
        volume) pg_run "$PG_DIR" "$PG_ROOT" volume "$GUEST" "" reject ;;
    esac
    pg_expect_proceeds "volume mode (DX_PERSIST_STORAGE $pg_variant): the same silent chown/chmod/install sequence as before" \
        "$PG_DIR" "$PG_ROOT" quiet
    if [ ! -s "$PG_DIR/log/probes" ] && [ ! -s "$PG_DIR/log/parse" ]; then
        test_pass "volume mode (DX_PERSIST_STORAGE $pg_variant): no mount-point probe and no marker parse"
    else
        test_fail "volume mode (DX_PERSIST_STORAGE $pg_variant): no mount-point probe and no marker parse (probes: $(tr '\n' ';' <"$PG_DIR/log/probes"); parse: $(tr '\n' ';' <"$PG_DIR/log/parse"))"
    fi
done

pg_new_case volume-absent-root
rmdir "$PG_ROOT"
pg_run "$PG_DIR" "$PG_ROOT" - - ""
if [ "$(cat "$PG_DIR/log/rc" 2>/dev/null)" = 0 ] && [ ! -s "$PG_DIR/log/calls" ] \
    && [ ! -s "$PG_DIR/log/out" ] && [ ! -s "$PG_DIR/log/err" ] \
    && [ ! -s "$PG_DIR/log/probes" ] && [ "$(cat "$PG_DIR/log/after")" = absent ]; then
    test_pass "volume mode: with nothing at /persist the guest still boots on its own filesystem (returns 0, no call, no probe)"
else
    test_fail "volume mode: with nothing at /persist the guest still boots on its own filesystem (returns 0, no call, no probe) (rc: $(cat "$PG_DIR/log/rc" 2>/dev/null); calls: $(tr '\n' ';' <"$PG_DIR/log/calls"); probes: $(tr '\n' ';' <"$PG_DIR/log/probes"))"
fi

# --- The check uses the shared marker parser, sourced, not copied ---------

PROBES="$TMP_ROOT/probes"
mkdir -p "$PROBES"
cat >"$PROBES/parser-origin.sh" <<'PROBE'
# $1: persistence.sh. Sourced on its own, as standalone callers do.
set -u
before=$-
source "$1"
if [ "$before" != "$-" ]; then echo "sourcing changed the shell options"; exit 1; fi
if ! declare -F dx_persist_marker_parse >/dev/null; then echo "dx_persist_marker_parse is not defined"; exit 1; fi
if [ "${DX_PERSIST_MARKER_NAME:-}" != .dxe-persist-dir ]; then echo "DX_PERSIST_MARKER_NAME is not .dxe-persist-dir"; exit 1; fi
shopt -s extdebug
read -r _name _line origin <<EOF
$(declare -F dx_persist_marker_parse)
EOF
printf '%s/%s\n' "$(cd "$(dirname "$origin")" && pwd -P)" "$(basename "$origin")"
PROBE
pg_origin_status=0
pg_origin="$(bash "$PROBES/parser-origin.sh" "$BOOTSTRAP_DIR/persistence.sh" 2>&1)" || pg_origin_status=$?
pg_expected_origin="$(cd "$(dirname "$MARKER_LIB")" && pwd -P)/$(basename "$MARKER_LIB")"
if [ "$pg_origin_status" -eq 0 ] && [ "$pg_origin" = "$pg_expected_origin" ]; then
    test_pass "sourcing persistence.sh alone defines dx_persist_marker_parse from scripts/lib/dx-persist-marker.sh (sourced, not copied)"
else
    test_fail "sourcing persistence.sh alone defines dx_persist_marker_parse from scripts/lib/dx-persist-marker.sh (sourced, not copied) (status $pg_origin_status: $pg_origin)"
fi

# The decision follows the shared parser's verdict: a shadow that accepts an
# opaque marker lets the boot proceed, and one that rejects a valid marker
# stops it. A private copy of the parser would ignore both shadows.
pg_new_case parser-accepts
printf '%s\n' 'opaque bytes only the shared parser judges' >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT" accept
pg_expect_proceeds "host-path: when dx_persist_marker_parse accepts the marker (guest $GUEST, ready), setup_persist proceeds to the usual sequence" \
    "$PG_DIR" "$PG_ROOT"
if [ "$(awk 'END { print NR }' "$PG_DIR/log/parse")" = 1 ] && cmp -s "$PG_MARKER" "$PG_DIR/log/parse.stdin"; then
    test_pass "host-path: dx_persist_marker_parse is called once with the marker file on stdin"
else
    test_fail "host-path: dx_persist_marker_parse is called once with the marker file on stdin (parse calls: $(tr '\n' ';' <"$PG_DIR/log/parse"))"
fi

pg_new_case parser-rejects
pg_marker_text ready >"$PG_MARKER"
pg_run "$PG_DIR" "$PG_ROOT" host-path "$GUEST" "$PG_ROOT" reject
pg_expect_refusal "host-path: when dx_persist_marker_parse rejects an otherwise valid marker -> 'is malformed' (one line), no chown" \
    "$PG_DIR" malformed "$PG_MARKER is malformed"

# --- Bootstrap stops at setup_persist -------------------------------------

declare -f pg_canon pg_is_mounted pg_stub_mountpoint pg_stub_findmnt pg_define_stubs >"$TMP_ROOT/stubs.sh"
cat >"$PROBES/bootstrap-phases.sh" <<'PROBE'
# $1 container dir, $2 persist root, $3 phase log, $4 stub definitions.
# Every phase but setup_persist is a recorder; setup_persist is the real one,
# pointed at the fixture root. bootstrap.sh runs the phases under set -e.
set -euo pipefail
pg_container_dir="$1"
pg_root="$2"
pg_phase_log="$3"
source "$4"
source "$pg_container_dir/bootstrap/common.sh"
source "$pg_container_dir/bootstrap/persistence.sh"
source "$pg_container_dir/bootstrap.sh"
for pg_phase in configure_single_user_nix install_essentials link_system_bash \
    capture_nix_image_default_profile prepare_nix_volume materialize_auth_files \
    create_user populate_prepared_nix_volume verify_remount_prerequisites \
    nix_restore_image_default_profile ensure_essentials_valid \
    publish_nix_image_store_identity configure_release_identity configure_ssh \
    configure_guest verify_guest_tools configure_timezone; do
    eval "$pg_phase() { printf '%s\n' $pg_phase >>\"\$pg_phase_log\"; }"
done
eval "$(declare -f setup_persist | sed '1s/^setup_persist/pg_real_setup_persist/')"
setup_persist() {
    printf '%s\n' setup_persist >>"$pg_phase_log"
    pg_real_setup_persist "$pg_root"
}
pg_define_stubs
PATH="$PG_STUB_BIN:$PATH"
bootstrap_phases
printf '%s\n' bootstrap_phases-returned >>"$pg_phase_log"
PROBE
pg_new_case bootstrap-stops
pg_marker_text ready >"$PG_MARKER"
mkdir -p "$PG_DIR/scratch"
: >"$PG_DIR/log/calls"
: >"$PG_DIR/log/probes"
: >"$PG_DIR/log/phases"
pg_boot_status=0
pg_boot_out="$(env PG_CALLS="$PG_DIR/log/calls" PG_PROBES="$PG_DIR/log/probes" PG_MOUNTS="$PG_DIR" \
    PG_STUB_BIN="$PG_STUB_BIN" DX_BOOTSTRAP_SCRATCH_DIR="$PG_DIR/scratch" \
    DX_PERSIST_STORAGE=host-path DX_PERSIST_DIR_GUEST="$GUEST" \
    bash "$PROBES/bootstrap-phases.sh" "$CONTAINER_DIR" "$PG_ROOT" "$PG_DIR/log/phases" "$TMP_ROOT/stubs.sh" </dev/null 2>&1)" \
    || pg_boot_status=$?
pg_boot_problems=""
[ "$pg_boot_status" -ne 0 ] || pg_boot_problems="$pg_boot_problems the probe exited 0;"
[ "$(tail -n 1 "$PG_DIR/log/phases")" = setup_persist ] || pg_boot_problems="$pg_boot_problems the last phase run was not setup_persist;"
for pg_later in configure_ssh configure_guest verify_guest_tools configure_timezone bootstrap_phases-returned; do
    if grep -Fqx -- "$pg_later" "$PG_DIR/log/phases"; then
        pg_boot_problems="$pg_boot_problems $pg_later ran;"
    fi
done
case "$pg_boot_out" in
    *"Error: "*"$PG_ROOT is not a mount point"*) : ;;
    *) pg_boot_problems="$pg_boot_problems no 'is not a mount point' Error line;" ;;
esac
[ ! -s "$PG_DIR/log/calls" ] || pg_boot_problems="$pg_boot_problems a mutating command ran;"
if [ -z "$pg_boot_problems" ]; then
    test_pass "bootstrap_phases (set -e) stops at setup_persist in host-path mode when /persist is not mounted: configure_ssh never runs"
else
    test_fail "bootstrap_phases (set -e) stops at setup_persist in host-path mode when /persist is not mounted: configure_ssh never runs [$pg_boot_problems] (phases: $(tr '\n' ';' <"$PG_DIR/log/phases"); output: $pg_boot_out)"
fi

print_summary
exit_with_code
