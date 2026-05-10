#!/bin/bash
# Section 3: Split Bootstrap From Runtime
# Tests for: bootstrap.sh structure, idempotency, functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh"

test_section "Section 3: Split Bootstrap From Runtime"

# Test: bootstrap.sh exists
assert_file_exists "$BOOTSTRAP" "bootstrap.sh exists"

# Test: bootstrap.sh uses set -euo pipefail
assert_file_contains "$BOOTSTRAP" "set -euo pipefail" "bootstrap.sh uses set -euo pipefail"

# Test: bootstrap.sh has functions defined
if grep -q "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$BOOTSTRAP" || grep -q "^function " "$BOOTSTRAP"; then
    test_pass "bootstrap.sh has functions defined"
else
    test_fail "bootstrap.sh has functions defined"
fi

# Test: bootstrap.sh checks if dx user exists before creating
assert_file_contains "$BOOTSTRAP" "id -u dx" "bootstrap.sh checks if dx user exists"

# Test: bootstrap.sh prevents duplicate shell config
# Home Manager-managed shell files are idempotent; direct .bashrc appends must be guarded.
if grep -q "home-manager\|homeConfigurations" "$BOOTSTRAP" || grep -q "grep.*bashrc\|!.*grep.*bashrc" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh prevents duplicate shell config"
else
    test_fail "bootstrap.sh prevents duplicate shell config"
fi

# Test: bootstrap.sh checks if sshd is running before starting
if grep -q "sshd.*running\|pgrep.*sshd\|ps.*sshd" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh checks if sshd is already running"
else
    test_fail "bootstrap.sh checks if sshd is already running"
fi

# Test: bootstrap.sh preserves passwordless sudo
assert_file_contains "$BOOTSTRAP" "dx ALL=(ALL) NOPASSWD:ALL" "bootstrap.sh keeps passwordless sudo for dx"

# Test: bootstrap initializes persisted Claude config as valid JSON
assert_file_not_contains "$BOOTSTRAP" "touch /workspace/home/dx/.claude.json" "bootstrap does not create empty Claude JSON config"
assert_file_contains "$BOOTSTRAP" "printf '%s\\\\n' '{}' > /workspace/home/dx/.claude.json" "bootstrap initializes empty Claude config as JSON"

# Test: bootstrap.sh is idempotent for user creation
# Check that user creation is conditional
assert_file_contains "$BOOTSTRAP" "if.*id -u dx" "bootstrap.sh conditionally creates dx user"

# Test: sshd starts only after guest tools are installed and verified
INSTALL_CALL=$(grep -n "^configure_guest$" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
VERIFY_CALL=$(grep -n "^verify_guest_tools$" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
START_SSH_CALL=$(grep -n "^exec \\\"\$SSHD_BIN\\\"" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
if [ -n "$INSTALL_CALL" ] && [ -n "$VERIFY_CALL" ] && [ -n "$START_SSH_CALL" ] &&
    [ "$INSTALL_CALL" -lt "$VERIFY_CALL" ] && [ "$VERIFY_CALL" -lt "$START_SSH_CALL" ]; then
    test_pass "bootstrap.sh starts sshd after guest tools are verified"
else
    test_fail "bootstrap.sh starts sshd after guest tools are verified"
fi

# Test: bash syntax check
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash syntax check"
else
    test_fail "bootstrap.sh passes bash syntax check"
fi

print_summary
exit_with_code
