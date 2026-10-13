#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# Unit cases for bin/lib/dx-nix-gc.sh (fix/gc-temproots) beyond the locked
# acceptance suite, tests/test_nix_gc_temproots.sh:
#
#   - an unlink that fails is never counted or hidden: the guest program
#     still tries every other stale file, reports what it did remove, and
#     exits non-zero, so the host warns and prints no Cleared line;
#   - the guest program runs `rm` with the root essentials profile first on
#     PATH (the same GC-rooted profile bin/dx-reclaim's guest programs use),
#     because `bash -c` is not a login shell and gets only the exec's bare
#     PATH.
#
# Every case runs the guest program against this run's own temporary fixture
# with a recording `rm` stub first on PATH: the stub never removes anything,
# and no path outside this run's temporary directory is ever passed to it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-nix-gc.sh
source "$BASE_DIR/bin/lib/dx-nix-gc.sh"
test_section "Nix GC temp-roots clear: unit cases"

UT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-nix-gc-unit.XXXXXX")"
ut_cleanup() {
    case "$UT_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-nix-gc-unit.?*) rm -rf "$UT_ROOT" ;;
    esac
}
trap ut_cleanup EXIT

UT_ESSENTIALS_BIN=/nix/var/nix/profiles/per-user/root/profile/bin
FAKE_DIR="$(fake_tool_dir_create "$UT_ROOT")"

# A recording `rm`: logs its argv (one call per line) and the PATH it was
# found under, removes nothing, and fails for any path ending in /545.
fake_tool_write "$FAKE_DIR" rm '
printf "%s\n" "$PATH" > "$UT_RM_PATH_LOG"
printf "%s\n" "$*" >> "$UT_RM_LOG"
case "$*" in
    */545) exit 1 ;;
esac
exit 0'

# Apple runtime fake: the clear call's exact argv runs the guest program
# with the guest paths remapped to this case's fixture.
fake_tool_write "$FAKE_DIR" container '
[ "${1:-}" = exec ] || exit 1
shift
if [ "$#" -eq 9 ] && [ "$1 $2 $4 $5" = "-u dx bash -c" ] && [ "$7 $8 $9" = "bash /nix/var/nix/temproots /proc" ]; then
    exec bash -c "$6" "$7" "$UT_TEMPROOTS" "$UT_PROC"
fi
echo "unexpected exec: $*" >&2
exit 98'

ut_new_case() {
    UT_CASE="$(mktemp -d "$UT_ROOT/case.XXXXXX")"
    UT_TEMPROOTS="$UT_CASE/temproots"
    UT_PROC="$UT_CASE/proc"
    UT_RM_LOG="$UT_CASE/rm.log"
    UT_RM_PATH_LOG="$UT_CASE/rm-path.log"
    : > "$UT_RM_LOG"
    mkdir -p "$UT_TEMPROOTS" "$UT_PROC/1" "$UT_PROC/4242"
    printf 'live\n' > "$UT_TEMPROOTS/4242"
    printf 'stale\n' > "$UT_TEMPROOTS/110"
    printf 'stale\n' > "$UT_TEMPROOTS/545"
    printf 'stale\n' > "$UT_TEMPROOTS/546"
    export UT_TEMPROOTS UT_PROC UT_RM_LOG UT_RM_PATH_LOG
}

ut_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $ut_rc"
        echo "    stdout: $(cat "$UT_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$UT_CASE/err" 2>/dev/null)"
        echo "    rm calls: $(tr '\n' '|' < "$UT_RM_LOG")"
    fi
}

ut_rm_calls_are() { [ "$(LC_ALL=C sort "$UT_RM_LOG")" = "$1" ]; }
ut_out_is() { [ "$(cat "$UT_CASE/out")" = "$1" ]; }

# The guest program puts the essentials profile first on PATH; on a host
# that really has that directory with an `rm` in it, the stub could not
# stand in for it, so these cases would not be measuring the program.
if [ -e "$UT_ESSENTIALS_BIN/rm" ]; then
    test_skip "guest program unit cases: this host has $UT_ESSENTIALS_BIN/rm, which would shadow the recording stub"
    print_summary
    exit_with_code
fi

# --- The guest program itself --------------------------------------------
ut_new_case
ut_rc=0
(
    PATH="$FAKE_DIR:$PATH"
    export PATH
    # shellcheck disable=SC2154 # assigned by bin/lib/dx-nix-gc.sh (sourced above), which ShellCheck cannot see
    bash -c "$dx_nix_gc_clear_temproots_program" bash "$UT_TEMPROOTS" "$UT_PROC"
) > "$UT_CASE/out" 2> "$UT_CASE/err" || ut_rc=$?
ut_check "program: tries every stale file once with a non-recursive rm -f, never the live pid's file" \
    ut_rm_calls_are "-f -- $UT_TEMPROOTS/110
-f -- $UT_TEMPROOTS/545
-f -- $UT_TEMPROOTS/546"
ut_check "program: an unlink that fails makes it exit non-zero" \
    [ "$ut_rc" -ne 0 ]
ut_check "program: the count it prints is the files it really removed (the failed one is not counted)" \
    ut_out_is 2
ut_check "program: runs rm with the root essentials profile first on PATH (bash -c is not a login shell)" \
    eval 'case "$(cat "$UT_RM_PATH_LOG")" in "$UT_ESSENTIALS_BIN:"*) true ;; *) false ;; esac'

# --- Host side: a partial failure is a failed clear ------------------------
ut_new_case
ut_rc=0
(
    PATH="$FAKE_DIR:$PATH"
    HOME="$UT_CASE/home"
    DX_RUNTIME=apple
    export PATH HOME DX_RUNTIME
    dx_nix_gc_clear_stale_temproots dxe-gc-unit
) > "$UT_CASE/out" 2> "$UT_CASE/err" || ut_rc=$?
ut_check "clear (one unlink fails): returns 1 and prints nothing on stdout (no Cleared line for a partial clear)" \
    eval '[ "$ut_rc" -eq 1 ] && [ ! -s "$UT_CASE/out" ]'
ut_check "clear (one unlink fails): warns on stderr with the guest program's status" \
    eval 'grep -F "Warning: could not clear stale Nix temporary roots" "$UT_CASE/err" | grep -F "(exit 1)" >/dev/null'

print_summary
exit_with_code
