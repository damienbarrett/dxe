#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# Unit cases for the root-owned paths hand-back's guest program
# (bin/lib/dx-nix-gc.sh, fix/gc-rootpaths) beyond the locked acceptance
# suite, tests/test_nix_gc_rootpaths.sh, whose real-ownership cases need the
# root coverage runner. These run anywhere, as any user:
#
#   - the program runs the tools the exec's own PATH provides; the root
#     essentials profile and the image's default profile are only APPENDED
#     to that PATH, as fallbacks for an exec whose PATH lacks a tool;
#   - a missing tool is a failed hand-back (exit 127, no count, no chown),
#     never a silent "nothing to hand back";
#   - a chown that fails is not counted: the program reports what it really
#     handed back and exits non-zero after trying every other entry.
#
# No case can change an owner: `chown` is a recording stub that changes
# nothing, `stat` a stub that reports a scripted owner, and `find` a stub
# that runs the host's real find over this run's own fixture with `-uid 0`
# replaced by `-name 'r-*'` (a non-root user cannot create root-owned
# files, so here "root-owned" means "named r-*").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-nix-gc.sh
source "$BASE_DIR/bin/lib/dx-nix-gc.sh"
test_section "Nix GC root-owned paths hand-back: guest program unit cases"

RU_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-nix-gc-rootpaths-unit.XXXXXX")"
ru_cleanup() {
    case "$RU_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-nix-gc-rootpaths-unit.?*) rm -rf "$RU_ROOT" ;;
    esac
}
trap ru_cleanup EXIT

RU_FALLBACKS="/nix/var/nix/profiles/per-user/root/profile/bin:/nix/var/nix/profiles/default/bin"
RU_REAL_FIND="$(command -v find)"
FAKE_DIR="$(fake_tool_dir_create "$RU_ROOT")"
# The tools a "find is missing" exec has: stat and chown only.
NOFIND_DIR="$RU_ROOT/nofind"
export RU_REAL_FIND

# Recording chown: logs its argv (one call per line) and the PATH it was
# found under, changes nothing, and fails for an operand containing
# $RU_CHOWN_FAIL (when set).
ru_write_chown() {
    fake_tool_write "$1" chown '
printf "%s\n" "$PATH" > "$RU_CHOWN_PATH_LOG"
printf "%s\n" "$*" >> "$RU_CHOWN_LOG"
if [ -n "${RU_CHOWN_FAIL:-}" ]; then
    case "$*" in *"$RU_CHOWN_FAIL"*) exit 1 ;; esac
fi
exit 0'
}
# stat: reports $RU_STORE_OWNER for any operand.
ru_write_stat() {
    fake_tool_write "$1" stat '
printf "%s\n" "$RU_STORE_OWNER"'
}
ru_write_chown "$FAKE_DIR"
ru_write_stat "$FAKE_DIR"
mkdir -p "$NOFIND_DIR"
# The fakes run under `/usr/bin/env bash`, so this PATH still needs bash.
ln -s "$BASH" "$NOFIND_DIR/bash"
ru_write_chown "$NOFIND_DIR"
ru_write_stat "$NOFIND_DIR"
# find: the host's real find over the fixture, entries named r-* standing in
# for root-owned ones.
fake_tool_write "$FAKE_DIR" find '
args=()
while [ "$#" -gt 0 ]; do
    if [ "$1" = -uid ] && [ "${2:-}" = 0 ]; then
        args+=(-name "r-*")
        shift 2
        continue
    fi
    args+=("$1")
    shift
done
exec "$RU_REAL_FIND" "${args[@]}"'

ru_new_case() {
    RU_CASE="$(mktemp -d "$RU_ROOT/case.XXXXXX")"
    RU_STORE="$RU_CASE/nix/store"
    RU_LOG="$RU_CASE/nix/var/log/nix"
    RU_CHOWN_LOG="$RU_CASE/chown.log"
    RU_CHOWN_PATH_LOG="$RU_CASE/chown-path.log"
    RU_STORE_OWNER=4242:4243
    unset RU_CHOWN_FAIL
    : > "$RU_CHOWN_LOG"
    mkdir -p "$RU_STORE/r-aaaa-profile" "$RU_STORE/bbbb-dx-own" "$RU_STORE/r-cccc-source" "$RU_LOG/drvs/r-sy"
    printf 'drv\n' > "$RU_STORE/r-dddd.drv"
    printf 'log\n' > "$RU_LOG/drvs/r-sy/r-x.drv.bz2"
    export RU_CHOWN_LOG RU_CHOWN_PATH_LOG RU_STORE_OWNER
}

# ru_program DIR... -- runs the guest program with PATH set to DIR... only
# (then the program's own fallbacks), the way the exec would.
ru_program() {
    local path_dirs="$1"
    ru_rc=0
    (
        PATH="$path_dirs"
        # shellcheck disable=SC2154 # assigned by bin/lib/dx-nix-gc.sh (sourced above), which ShellCheck cannot see
        "$BASH" -c "$dx_nix_gc_hand_back_root_paths_program" bash "$RU_STORE" "$RU_LOG"
    ) > "$RU_CASE/out" 2> "$RU_CASE/err" || ru_rc=$?
}

ru_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $ru_rc"
        echo "    stdout: $(cat "$RU_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$RU_CASE/err" 2>/dev/null)"
        echo "    chown calls: $(tr '\n' '|' < "$RU_CHOWN_LOG")"
    fi
}

ru_out_is() { [ "$(cat "$RU_CASE/out")" = "$1" ]; }
ru_chown_count() { wc -l < "$RU_CHOWN_LOG" | tr -d ' '; }

if [ -z "${dx_nix_gc_hand_back_root_paths_program:-}" ]; then
    test_fail "bin/lib/dx-nix-gc.sh defines the hand-back guest program"
    print_summary
    exit_with_code
fi

# --- PATH: the exec's own tools first, the profiles only as fallbacks -------
ru_new_case
ru_program "$FAKE_DIR:/usr/bin:/bin"
ru_check "program: hands back every stand-in root-owned entry and reports the count" \
    eval '[ "$ru_rc" -eq 0 ] && ru_out_is 5 && [ "$(ru_chown_count)" -eq 5 ]'
ru_check "program: runs the chown the exec's own PATH provides, with the essentials and default profiles appended after it, never ahead of it" \
    eval '[ "$(cat "$RU_CHOWN_PATH_LOG")" = "$FAKE_DIR:/usr/bin:/bin:$RU_FALLBACKS" ]'

# --- A chown that fails is not counted ---------------------------------------
ru_new_case
RU_CHOWN_FAIL=r-cccc-source
export RU_CHOWN_FAIL
ru_program "$FAKE_DIR:/usr/bin:/bin"
ru_check "program: one chown fails -- every other entry is still tried, only real hand-backs are counted, and it exits non-zero" \
    eval '[ "$ru_rc" -ne 0 ] && ru_out_is 4 && [ "$(ru_chown_count)" -eq 5 ]'

# --- A missing tool is a failure, not "nothing to hand back" ----------------
ru_new_case
if (PATH="$NOFIND_DIR:$RU_FALLBACKS"; command -v find >/dev/null 2>&1); then
    test_skip "program: find missing (this host's fallback profiles provide find, so it cannot be missing here)"
else
    ru_program "$NOFIND_DIR"
    ru_check "program: find missing -- exits 127 with no count on stdout, runs no chown, says what is missing" \
        eval '[ "$ru_rc" -eq 127 ] && [ ! -s "$RU_CASE/out" ] && [ "$(ru_chown_count)" -eq 0 ] && grep -F find "$RU_CASE/err" >/dev/null'
fi

# --- An empty exec PATH never makes the current directory a tool source -------
# `PATH="$PATH:..."` with an empty PATH starts with an empty element, which
# means the current directory: a root process would then run whatever stat,
# find or chown sits there. Run the program with an empty PATH from a
# directory holding the stand-in tools (and bash, for their shebang).
ru_new_case
CWD_DIR="$RU_CASE/cwd-tools"
mkdir -p "$CWD_DIR"
ln -s "$BASH" "$CWD_DIR/bash"
cp "$FAKE_DIR/stat" "$FAKE_DIR/find" "$FAKE_DIR/chown" "$CWD_DIR/"
if (PATH="$RU_FALLBACKS"; command -v stat >/dev/null 2>&1); then
    test_skip "program: empty exec PATH (this host's fallback profiles provide stat, so the tools cannot be missing here)"
else
    ru_rc=0
    (
        cd "$CWD_DIR" || exit 99
        PATH=""
        "$BASH" -c "$dx_nix_gc_hand_back_root_paths_program" bash "$RU_STORE" "$RU_LOG"
    ) > "$RU_CASE/out" 2> "$RU_CASE/err" || ru_rc=$?
    ru_check "program: an empty exec PATH leaves only the profile fallbacks -- the current directory's tools are never run (exit 127, no chown)" \
        eval '[ "$ru_rc" -eq 127 ] && [ ! -s "$RU_CASE/out" ] && [ "$(ru_chown_count)" -eq 0 ]'
fi

print_summary
exit_with_code
