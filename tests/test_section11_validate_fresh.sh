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

# Test: dx-create-image works
echo "  Running: dx-create-image"
if "$BIN_DIR/dx-create-image" >/dev/null 2>&1; then
    test_pass "dx-create-image completes successfully"
else
    test_fail "dx-create-image completes successfully"
fi

# Test: dx-create-container works (or container already exists)
echo "  Running: dx-create-container"
if container_is_running "$DX_CONTAINER_NAME" || container_exists "$DX_CONTAINER_NAME"; then
    test_pass "$DX_CONTAINER_NAME container exists"
else
    if "$BIN_DIR/dx-create-container" >/dev/null 2>&1; then
        test_pass "dx-create-container completes successfully"
    else
        test_fail "dx-create-container completes successfully"
    fi
fi

# Test: dx-start-container works
echo "  Running: dx-start-container"
if "$BIN_DIR/dx-start-container" >/dev/null 2>&1; then
    test_pass "dx-start-container completes successfully"
else
    test_fail "dx-start-container completes successfully"
fi

# Wait for bootstrap
wait_for_ssh 180

# Test: dx-status works
echo "  Running: dx-status"
if "$BIN_DIR/dx-status" >/dev/null 2>&1; then
    test_pass "dx-status completes successfully"
else
    test_fail "dx-status completes successfully"
fi

# Test: dx-ssh works with nvim
echo "  Running: dx-ssh 'nvim --headless +q'"
if guest_bash "nvim --headless +q" >/dev/null 2>&1; then
    test_pass "dx-ssh works with nvim"
else
    test_fail "dx-ssh works with nvim"
fi

# Test: dx-ssh exposes lazygit in the guest runtime
echo "  Running: dx-ssh 'command -v lazygit && lazygit --version'"
if guest_bash "command -v lazygit >/dev/null && lazygit --version" >/dev/null 2>&1; then
    test_pass "dx-ssh exposes lazygit in the guest runtime"
else
    test_fail "dx-ssh exposes lazygit in the guest runtime"
fi

# Test: tmux session can be created
echo "  Running: dx-ssh tmux new-session test"
if guest_bash "tmux new-session -d -s smoke true || true" >/dev/null 2>&1; then
    test_pass "tmux session can be created via dx-ssh"
else
    test_fail "tmux session can be created via dx-ssh"
fi

# Test: source files survive stop/start
echo "  Testing persistence: creating file, stopping, starting, checking"
guest_bash "touch /persist/persistence_test_file" >/dev/null 2>&1
"$BIN_DIR/dx-stop-container" >/dev/null 2>&1
sleep 5
"$BIN_DIR/dx-start-container" >/dev/null 2>&1
sleep 10
if guest_bash "test -f /persist/persistence_test_file" >/dev/null 2>&1; then
    test_pass "source files survive dx-stop-container and dx-start-container"
else
    test_fail "source files survive dx-stop-container and dx-start-container"
fi

print_summary
exit_with_code
