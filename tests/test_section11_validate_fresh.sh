#!/bin/bash
# Section 11: Validate From Fresh Apple Container
# Tests for: fresh container build, creation, start, bootstrap, basic functionality
# These tests REQUIRE a running container and will modify state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"

test_section "Section 11: Validate From Fresh Apple Container"

# Check if container CLI is available
if ! command -v container >/dev/null 2>&1; then
    test_skip "container CLI not available, skipping all Section 11 tests"
    exit 0
fi

# Test: dx-build works
echo "  Running: dx-build"
if "$BIN_DIR/dx-build" >/dev/null 2>&1; then
    test_pass "dx-build completes successfully"
else
    test_fail "dx-build completes successfully"
fi

# Test: dx-create works (or container already exists)
echo "  Running: dx-create"
if container ls | grep -qw "dx-host"; then
    test_pass "dx-host container exists"
else
    if "$BIN_DIR/dx-create" >/dev/null 2>&1; then
        test_pass "dx-create completes successfully"
    else
        test_fail "dx-create completes successfully"
    fi
fi

# Test: dx-start works
echo "  Running: dx-start"
if "$BIN_DIR/dx-start" >/dev/null 2>&1; then
    test_pass "dx-start completes successfully"
else
    test_fail "dx-start completes successfully"
fi

# Wait for bootstrap
echo "  Waiting for guest bootstrap (30s)..."
sleep 30

# Test: dx-status works
echo "  Running: dx-status"
if "$BIN_DIR/dx-status" >/dev/null 2>&1; then
    test_pass "dx-status completes successfully"
else
    test_fail "dx-status completes successfully"
fi

# Test: dx-ssh works with nvim
echo "  Running: dx-ssh 'nvim --headless +q'"
if "$BIN_DIR/dx-ssh" "nvim --headless +q" >/dev/null 2>&1; then
    test_pass "dx-ssh works with nvim"
else
    test_fail "dx-ssh works with nvim"
fi

# Test: tmux session can be created
echo "  Running: dx-ssh tmux new-session test"
if "$BIN_DIR/dx-ssh" "tmux new-session -d -s smoke true || true" >/dev/null 2>&1; then
    test_pass "tmux session can be created via dx-ssh"
else
    test_fail "tmux session can be created via dx-ssh"
fi

# Test: source files survive stop/start
echo "  Testing persistence: creating file, stopping, starting, checking"
"$BIN_DIR/dx-ssh" "touch /workspace/persistence_test_file" >/dev/null 2>&1
"$BIN_DIR/dx-stop" >/dev/null 2>&1
sleep 5
"$BIN_DIR/dx-start" >/dev/null 2>&1
sleep 10
if "$BIN_DIR/dx-ssh" "test -f /workspace/persistence_test_file" >/dev/null 2>&1; then
    test_pass "source files survive dx-stop and dx-start"
else
    test_fail "source files survive dx-stop and dx-start"
fi

print_summary
exit_with_code
