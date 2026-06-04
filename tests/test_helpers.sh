#!/bin/bash
# Test helper functions for DX Experience tests

set -uo pipefail

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
source "$SCRIPT_DIR/../bin/dx-lib.sh"
BASE_DIR="$DX_PROJECT_ROOT"
CONTAINER_DIR="$DX_CONTEXT_DIR"
FLAKE_NIX="$CONTAINER_DIR/flake.nix"
FLAKE_LOCK="$CONTAINER_DIR/flake.lock"
NIXVIM_NIX="$CONTAINER_DIR/nixvim.nix"
BOOTSTRAP="$CONTAINER_DIR/bootstrap.sh"
CONTAINERFILE="$CONTAINER_DIR/Containerfile"
SHELL_NIX="$CONTAINER_DIR/home/shell.nix"
DX_EXPECTED_NIXOS_RELEASE="${DX_EXPECTED_NIXOS_RELEASE:-25.11}"
DX_EXPECTED_NIXOS_BRANCH="${DX_EXPECTED_NIXOS_BRANCH:-nixos-$DX_EXPECTED_NIXOS_RELEASE}"

# Test assertion functions
assert_true() {
    local message="${1:-Assertion failed}"
    if "$@" >/dev/null 2>&1; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_false() {
    local message="${1:-Assertion should be false}"
    if ! "$@" >/dev/null 2>&1; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

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
    if grep -q "$pattern" "$file" 2>/dev/null; then
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
    if grep -Fq "$literal" "$file" 2>/dev/null; then
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
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
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
    if ! container_is_running "$DX_CONTAINER_NAME" 2>/dev/null; then
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
    for i in $(seq 1 "$timeout"); do
        if nc -z localhost "$DX_SSH_PORT" 2>/dev/null; then
            echo "  Guest bootstrap complete (SSH port is open)."
            return 0
        fi
        sleep 1
    done
    echo "  Timeout waiting for SSH."
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
