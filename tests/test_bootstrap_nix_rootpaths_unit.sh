#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# Unit cases for the bootstrap's root-owned paths hand-back,
# hand_back_root_nix_paths (container/dx-nixos-26.05/bootstrap/common.sh,
# fix/gc-rootpaths), beyond the locked acceptance suite,
# tests/test_bootstrap_nix_rootpaths.sh, whose real-ownership cases need the
# root coverage runner. These run anywhere, as any user:
#
#   - a chown that fails is not counted: the Handed line reports what was
#     really handed back, then the warning, and it returns non-zero;
#   - a missing tool (find) or an unreadable store owner is a failed
#     hand-back -- a warning and a non-zero status, no chown -- never a
#     silent "nothing to hand back";
#   - run_root_nix still returns nix's own status when the hand-back fails.
#
# No case can change an owner: `chown` is a recording stub that changes
# nothing, `stat` a stub that reports a scripted owner (or fails), and
# `find` a stub that runs the host's real find over this run's own fixture
# with `-uid 0` replaced by `-name 'r-*'` (a non-root user cannot create
# root-owned files, so here "root-owned" means "named r-*").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
test_section "Bootstrap root-owned paths hand-back: unit cases"

dxe_test_mktemp_dir BR_ROOT "${TMPDIR:-/tmp}/dxe-bootstrap-rootpaths-unit.XXXXXX"
br_cleanup() {
    case "$BR_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-bootstrap-rootpaths-unit.?*) rm -rf "$BR_ROOT" ;;
    esac
}
trap br_cleanup EXIT

BR_REAL_FIND="$(command -v find)"
FAKE_DIR="$(fake_tool_dir_create "$BR_ROOT")" || exit 1
# The tools a "find is missing" bootstrap has: bash (the fakes run under
# `/usr/bin/env bash`), stat and chown only.
NOFIND_DIR="$BR_ROOT/nofind"
export BR_REAL_FIND

# Recording chown: logs its argv (one call per line), changes nothing, and
# fails for an operand containing $BR_CHOWN_FAIL (when set).
br_write_chown() {
    fake_tool_write "$1" chown '
printf "%s\n" "$*" >> "$BR_CHOWN_LOG"
if [ -n "${BR_CHOWN_FAIL:-}" ]; then
    case "$*" in *"$BR_CHOWN_FAIL"*) exit 1 ;; esac
fi
exit 0'
}
# stat: reports $BR_STORE_OWNER for any operand, or fails when
# $BR_STAT_FAIL is set.
br_write_stat() {
    fake_tool_write "$1" stat '
[ -z "${BR_STAT_FAIL:-}" ] || { echo "stat: cannot stat" >&2; exit 1; }
printf "%s\n" "$BR_STORE_OWNER"'
}
br_write_chown "$FAKE_DIR"
br_write_stat "$FAKE_DIR"
mkdir -p "$NOFIND_DIR"
ln -s "$BASH" "$NOFIND_DIR/bash"
br_write_chown "$NOFIND_DIR"
br_write_stat "$NOFIND_DIR"
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
exec "$BR_REAL_FIND" "${args[@]}"'
# A fake root nix that leaves one stand-in root-owned store entry and exits
# with $BR_NIX_RC.
fake_tool_write "$FAKE_DIR" nix '
mkdir -p "$BR_CASE/nix/store/r-new-profile"
exit "${BR_NIX_RC:-0}"'

br_new_case() {
    dxe_test_mktemp_dir BR_CASE "$BR_ROOT/case.XXXXXX"
    BR_CHOWN_LOG="$BR_CASE/chown.log"
    BR_STORE_OWNER=4242:4243
    unset BR_CHOWN_FAIL BR_STAT_FAIL BR_NIX_RC
    : > "$BR_CHOWN_LOG"
    mkdir -p "$BR_CASE/nix/store/r-aaaa-profile" "$BR_CASE/nix/store/bbbb-dx-own" "$BR_CASE/nix/store/r-cccc-source" \
        "$BR_CASE/nix/var/log/nix/drvs/r-sy" "$BR_CASE/nix/var/nix/temproots"
    printf 'log\n' > "$BR_CASE/nix/var/log/nix/drvs/r-sy/r-x.drv.bz2"
    export BR_CASE BR_CHOWN_LOG BR_STORE_OWNER
}

# br_run PATH FUNCTION [ARG...] -- runs a bootstrap function with PATH and
# DX_ESSENTIALS_ROOT at this case; captures stdout, stderr and status.
br_run() {
    local path_dirs="$1"
    shift
    br_rc=0
    (
        PATH="$path_dirs"
        DX_ESSENTIALS_ROOT="$BR_CASE"
        DX_BOOTSTRAP_ROOT=/guest-bootstrap
        export PATH DX_ESSENTIALS_ROOT DX_BOOTSTRAP_ROOT
        # Fail closed: never reach the code under test unless `chown` is a
        # recording stub.
        case "$(command -v chown)" in "$FAKE_DIR/chown" | "$NOFIND_DIR/chown") ;; *) exit 96 ;; esac
        "$@"
    ) > "$BR_CASE/out" 2> "$BR_CASE/err" || br_rc=$?
}

br_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $br_rc"
        echo "    stdout: $(cat "$BR_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$BR_CASE/err" 2>/dev/null)"
        echo "    chown calls: $(tr '\n' '|' < "$BR_CHOWN_LOG")"
    fi
}

br_out_is() { [ "$(cat "$BR_CASE/out")" = "$1" ]; }
br_chown_count() { wc -l < "$BR_CHOWN_LOG" | tr -d ' '; }
br_warning_given() { grep -F -- 'Warning: could not hand root-owned Nix paths back to the store owner' "$BR_CASE/err" >/dev/null; }
BR_PATH="$FAKE_DIR:$PATH"

if ! declare -F hand_back_root_nix_paths >/dev/null; then
    test_fail "bootstrap/common.sh defines hand_back_root_nix_paths"
    print_summary
    exit_with_code
fi

# --- A chown that fails is not counted ---------------------------------------
br_new_case
br_run "$BR_PATH" hand_back_root_nix_paths
br_check "every stand-in root-owned entry is handed back and counted (the fakes work)" \
    eval '[ "$br_rc" -eq 0 ] && br_out_is "Handed 4 root-owned Nix path(s) back to the store owner 4242:4243." && [ "$(br_chown_count)" -eq 4 ]'

br_new_case
BR_CHOWN_FAIL=r-cccc-source
export BR_CHOWN_FAIL
br_run "$BR_PATH" hand_back_root_nix_paths
br_check "one chown fails: every other entry is still tried, the Handed line counts only the real hand-backs, then it warns and returns non-zero" \
    eval '[ "$br_rc" -ne 0 ] && br_out_is "Handed 3 root-owned Nix path(s) back to the store owner 4242:4243." && [ "$(br_chown_count)" -eq 4 ] && br_warning_given'

br_new_case
BR_CHOWN_FAIL=r-x.drv.bz2
export BR_CHOWN_FAIL
br_run "$BR_PATH" hand_back_root_nix_paths
br_check "one log entry's chown fails: the same -- every other entry handed back and counted, then the warning, non-zero" \
    eval '[ "$br_rc" -ne 0 ] && br_out_is "Handed 3 root-owned Nix path(s) back to the store owner 4242:4243." && [ "$(br_chown_count)" -eq 4 ] && br_warning_given'

# --- Missing tools and an unreadable owner are failures ---------------------
br_new_case
br_run "$NOFIND_DIR" hand_back_root_nix_paths
br_check "find missing: warns, returns non-zero, runs no chown, prints no Handed line" \
    eval '[ "$br_rc" -ne 0 ] && [ "$br_rc" -ne 96 ] && br_warning_given && [ "$(br_chown_count)" -eq 0 ] && [ ! -s "$BR_CASE/out" ]'

br_new_case
BR_STAT_FAIL=1
export BR_STAT_FAIL
br_run "$BR_PATH" hand_back_root_nix_paths
br_check "the store owner cannot be read: warns, returns non-zero, runs no chown, prints no Handed line" \
    eval '[ "$br_rc" -ne 0 ] && [ "$br_rc" -ne 96 ] && br_warning_given && [ "$(br_chown_count)" -eq 0 ] && [ ! -s "$BR_CASE/out" ]'

# --- run_root_nix keeps nix's status ------------------------------------------
br_new_case
BR_NIX_RC=7
BR_STAT_FAIL=1
export BR_NIX_RC BR_STAT_FAIL
br_run "$BR_PATH" run_root_nix profile install x
br_check "run_root_nix: nix fails with 7 and the hand-back fails too -- returns nix's 7, and the hand-back's warning is shown" \
    eval '[ "$br_rc" -eq 7 ] && br_warning_given'

br_new_case
br_run "$BR_PATH" run_root_nix profile install x
br_check "run_root_nix: the hand-back runs after nix has exited, so it sees and hands back what nix left" \
    eval '[ "$br_rc" -eq 0 ] && br_out_is "Handed 5 root-owned Nix path(s) back to the store owner 4242:4243." && grep -F r-new-profile "$BR_CHOWN_LOG" >/dev/null'

print_summary
exit_with_code
