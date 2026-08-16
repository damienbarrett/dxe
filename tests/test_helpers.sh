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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
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

# Test result functions
test_pass() {
    local message="$1"
    echo -e "  ${GREEN}✓ PASS${NC}: $message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local message="$1"
    echo -e "  ${RED}✗ FAIL${NC}: $message"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_skip() {
    local message="$1"
    echo -e "  ${YELLOW}○ SKIP${NC}: $message"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

test_section() {
    local title="$1"
    echo ""
    echo -e "${YELLOW}=== $title ===${NC}"
}

# Requires running container
requires_container() {
    if ! command -v container >/dev/null 2>&1 || ! container list --quiet 2>/dev/null | grep -F -x -q -- "$DX_CONTAINER_NAME"; then
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

# Summary
print_summary() {
    echo ""
    echo "=============================="
    echo -e "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}, ${YELLOW}$TESTS_SKIPPED skipped${NC}"
    echo "=============================="
    
    if [ $TESTS_FAILED -gt 0 ]; then
        GLOBAL_FAILED=1
    fi
}

# Exit with proper code after all tests
exit_with_code() {
    exit $GLOBAL_FAILED
}
