#!/bin/bash
# Test helper functions for DX Experience tests

set -uo pipefail

# Match stdin against a pattern without short-circuiting the writer.
#
# `writer | grep -q PATTERN` is unsafe in any script with `set -o pipefail`:
# grep -q exits at its *first* match, closing the pipe while the writer is
# still writing, so the writer dies of SIGPIPE (141) and pipefail promotes
# that to the pipeline's exit status. A *successful* match is then reported
# as failure. Whether it fires depends on the race between writer and reader,
# so the construct can pass for months and then fail deterministically after
# an unrelated environment change -- which is exactly what happened here,
# taking 16 assertions across four sections with it on an unmodified tree.
#
# Dropping -q keeps the exit status identical while making grep consume all
# of its input, so the writer is never signalled. Output is discarded here so
# callers need no redirection of their own and the fix is a drop-in rename.
#
# Guest-side probe scripts (tests/lib/tmux-probes.sh, container_exec_dx_bash
# blocks, run_guest strings) deliberately keep plain `grep -q`: they run in a
# fresh guest shell under `set -u` with no pipefail, so they are immune, and
# this helper does not exist over there.
stdin_matches() { grep "$@" >/dev/null; }

# Octal permission bits of a file, on either host. GNU coreutils and BSD stat
# disagree on both the flag and the format specifier, and these tests run on
# macOS locally and Ubuntu in CI, so neither spelling can be hardcoded.
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# A listing of every path under the REAL SSH known-hosts pin tree
# (dx_ssh_known_hosts_dir in bin/lib/dx-ssh-common.sh writes under
# "${XDG_STATE_HOME:-$HOME/.local/state}/dxe"), computed with THIS SHELL's
# own ambient HOME/XDG_STATE_HOME -- never call this from inside a subshell
# that has already overridden either variable to a fixture, or it silently
# snapshots the fixture instead of the real directory it exists to protect.
#
# Any test that drives dx_ssh_common_options/dx_ssh_known_hosts_prepare
# under DX_RUNTIME=docker-ssh MUST isolate HOME (or XDG_STATE_HOME) to its
# own fixture before doing so, AND call this helper once in the outer,
# unisolated shell before and once after, asserting the two listings are
# identical -- a fixture that fails to isolate still writes somewhere, and
# without this check it silently lands in the real directory instead of
# failing the test (exactly the incident this helper exists to catch).
dx_real_ssh_known_hosts_snapshot() {
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/dxe"
    # An absent directory is a legitimate, empty snapshot (the normal state
    # on a fresh runner/container/CI, before anything has ever pinned a
    # known-hosts file there) -- not an error. Without this guard, `find` on
    # a nonexistent path exits 1, and under a caller's `set -e` (several of
    # this function's callers have their own), the "$(...)" assignment
    # aborts the whole script instead of yielding an empty listing. Guarding
    # on the directory's existence, rather than swallowing find's own exit
    # status with `|| true`, still lets a real find error (e.g. a
    # permission problem on a directory that DOES exist) propagate.
    [ -d "$dir" ] || return 0
    find "$dir" -mindepth 1 2>/dev/null | sort
}

# Test counters. Kept and updated for backward compatibility (some suites
# or ad-hoc debugging may read them directly), but they are no longer the
# source of truth for print_summary/exit_with_code below: a test_pass/
# test_fail/test_skip call made inside a `( ... )` subshell or a background
# job still increments these in whatever shell made the call, and that
# increment dies with the subshell exactly as it always has. The results
# file tests/lib/harness.sh records to (WP1.1, Fable D1) does not have that
# problem -- an append survives the subshell -- which is why the actual
# pass/fail decision below is read from it instead.
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTAINER_DIR="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"
FLAKE_NIX="$CONTAINER_DIR/flake.nix"
FLAKE_LOCK="$CONTAINER_DIR/flake.lock"
NIXVIM_NIX="$CONTAINER_DIR/nixvim.nix"
BOOTSTRAP="$CONTAINER_DIR/bootstrap.sh"
CONTAINERFILE="$CONTAINER_DIR/Containerfile"
SHELL_NIX="$CONTAINER_DIR/home/shell.nix"
export FLAKE_NIX FLAKE_LOCK NIXVIM_NIX BOOTSTRAP CONTAINERFILE SHELL_NIX
DX_EXPECTED_NIXOS_RELEASE="${DX_EXPECTED_NIXOS_RELEASE:-26.05}"
DX_EXPECTED_NIXOS_BRANCH="${DX_EXPECTED_NIXOS_BRANCH:-nixos-$DX_EXPECTED_NIXOS_RELEASE}"
DX_CONTAINER_NAME="${DX_CONTAINER_NAME:-dx-host}"
DX_SSH_PORT="${DX_SSH_PORT:-2222}"
# Pure host helpers are safe on machines without Apple Container.
source "$BASE_DIR/bin/lib/dx-host-util.sh"

# tests/lib/harness.sh (WP1.1, Fable D1): the results-file recorder
# test_pass/test_fail/test_skip/print_summary/exit_with_code below are now
# shims over. Also supplies RED/GREEN/YELLOW/NC, so this file no longer
# defines its own copies.
# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# Test assertion functions
assert_file_exists() {
    local file="$1"
    local message="${2:-File $file exists}"
    if [ -f "$file" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_not_exists() {
    local file="$1"
    local message="${2:-File $file does not exist}"
    if [ ! -f "$file" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File $file contains '$pattern'}"
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_contains_literal() {
    local file="$1"
    local literal="$2"
    local message="${3:-File $file contains literal '$literal'}"
    if grep -Fq -- "$literal" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File $file does not contain '$pattern'}"
    if ! grep -q -- "$pattern" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_grep_in_file() {
    local file="$1"
    local pattern="$2"
    local message="${3:-Pattern found in $file}"
    if [ -f "$file" ] && grep -Eq "$pattern" "$file"; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_git_not_tracked() {
    local file="$1"
    local message="${2:-$file is not tracked by git}"
    if ! git -C "$BASE_DIR" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

# Test result functions -- shims over tests/lib/harness.sh (WP1.1, Fable
# D1). Each one still prints the exact colored line it always has (other
# tooling and humans read these) and still updates the TESTS_PASSED/
# TESTS_FAILED/TESTS_SKIPPED counters in the calling shell for backward
# compatibility, but the call this file's own print_summary/exit_with_code
# actually trust is _dxe_harness_record/skip's append to $DXE_TEST_RESULTS,
# which -- unlike these counters -- is still there to read even when the
# call was made inside a `( ... )` subshell or a background job.
test_pass() {
    local message="$1"
    echo -e "  ${GREEN}✓ PASS${NC}: $message"
    _dxe_harness_record pass "$message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local message="$1"
    echo -e "  ${RED}✗ FAIL${NC}: $message"
    _dxe_harness_record fail "$message"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_skip() {
    local message="$1"
    echo -e "  ${YELLOW}○ SKIP${NC}: $message"
    skip "$message"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

test_section() {
    local title="$1"
    echo ""
    echo -e "${YELLOW}=== $title ===${NC}"
}

# Requires running container
#
# Uses stdin_matches (this file's own read-all idiom, see its comment above)
# rather than `grep -F -x -q` directly: this file sets `set -uo pipefail` at
# its own top, and a `grep -q` pipeline can read a real match as absent under
# pipefail the same way bin/lib/dx-container.sh's container_is_running/
# container_exists did before their fix (tests/test_section20_skip_integration.sh).
requires_container() {
    if ! command -v container >/dev/null 2>&1 || ! container list --quiet 2>/dev/null | stdin_matches -F -x -- "$DX_CONTAINER_NAME"; then
        test_skip "Container '$DX_CONTAINER_NAME' is not running"
        return 1
    fi
    return 0
}

# Global failure tracker
GLOBAL_FAILED=0

# Wait for SSH to be available on the active profile port.
wait_for_ssh() {
    local timeout="${1:-180}"
    echo "  Waiting for guest bootstrap on localhost:$DX_SSH_PORT (up to ${timeout}s)..."
    if DX_SSH_WAIT_TIMEOUT="$timeout" "$BASE_DIR/bin/dx-wait-ssh"; then
        echo "  Guest bootstrap complete (authenticated SSH is responsive)."
        return 0
    fi
    echo "  Timeout waiting for authenticated SSH."
    return 1
}

guest_ssh() {
    "$BASE_DIR/bin/dx-ssh" "$@"
}

guest_bash() {
    guest_ssh "$1"
}

container_exec_dx() {
    container exec -u dx "$DX_CONTAINER_NAME" "$@"
}

container_exec_dx_bash() {
    container_exec_dx bash -lc "$1"
}
# shellcheck source=lib/tmux-probes.sh
source "$SCRIPT_DIR/lib/tmux-probes.sh"

# Extract one value from a captured tmux_guest_probe blob.
#   probe_value "$blob" status-keys
probe_value() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Assert a probed runtime value equals an expected value.
#   assert_tmux_runtime "$blob" status-keys emacs "tmux status-keys is emacs"
assert_tmux_runtime() {
    local blob="$1" key="$2" expected="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if [ "$got" = "$expected" ]; then
        test_pass "$message (runtime $key=$got)"
    else
        test_fail "$message (expected $key=$expected, got '$got')"
    fi
    return 0
}

# Assert a probed runtime value contains a substring.
assert_tmux_runtime_contains() {
    local blob="$1" key="$2" needle="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if printf '%s' "$got" | stdin_matches -F "$needle"; then
        test_pass "$message (runtime $key=$got)"
    else
        test_fail "$message (expected $key to contain '$needle', got '$got')"
    fi
    return 0
}

# Assert a probed runtime value does NOT contain a substring.
assert_tmux_runtime_not_contains() {
    local blob="$1" key="$2" needle="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if printf '%s' "$got" | stdin_matches -F "$needle"; then
        test_fail "$message (expected $key to omit '$needle', got '$got')"
    else
        test_pass "$message (runtime $key=$got)"
    fi
    return 0
}

# Summary. Prints the byte-identical line print_summary always has, but the
# counts come from $DXE_TEST_RESULTS (tests/lib/harness.sh), not from
# $TESTS_PASSED/$TESTS_FAILED/$TESTS_SKIPPED -- see the comment above
# test_pass for why.
print_summary() {
    _dxe_harness_results_file
    local passed failed skipped
    passed="$(_dxe_harness_count pass)"
    failed="$(_dxe_harness_count fail)"
    skipped="$(_dxe_harness_count skip)"
    echo ""
    echo "=============================="
    echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
    echo "=============================="

    if [ "$failed" -gt 0 ]; then
        GLOBAL_FAILED=1
    fi
}

# Exit with proper code after all tests. Non-zero if $DXE_TEST_RESULTS has
# any fail line (not just if GLOBAL_FAILED was already set by a preceding
# print_summary call, so a suite that calls exit_with_code without ever
# calling print_summary still exits correctly). Deliberately does NOT apply
# tests/lib/harness.sh finish's "zero recorded cases is itself a failure"
# rule: several existing suites legitimately record only skips when no
# container is present (e.g. test_section19_reverse_forward.sh: 0 passed,
# 1 skipped) and must keep exiting 0. Removes the results file as its own
# last step, explicitly, rather than via a trap: many suites install their
# own `trap ... EXIT` for fixture cleanup (test_dx_backup.sh,
# test_docker_runtime_adapter.sh, ...), and a trap installed here would
# either clobber theirs or be clobbered by them depending on source order.
# Since every call site in this suite immediately exits afterward (grep
# confirms print_summary is always followed by exit_with_code, and
# exit_with_code always calls `exit`), there is no later reader of the file
# left to break by removing it here.
exit_with_code() {
    _dxe_harness_results_file
    local failed
    failed="$(_dxe_harness_count fail)"
    if [ "$failed" -gt 0 ]; then
        GLOBAL_FAILED=1
    fi
    rm -f "${DXE_TEST_RESULTS:-}"
    exit $GLOBAL_FAILED
}
