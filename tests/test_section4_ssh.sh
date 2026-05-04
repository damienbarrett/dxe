#!/bin/bash
# Section 4: Harden SSH While Keeping Sudo Convenient
# Tests for: SSH config hardening, key-only auth, passwordless sudo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh"

test_section "Section 4: Harden SSH While Keeping Sudo Convenient"

# Test: bootstrap.sh does not use passwd -d dx
assert_file_not_contains "$BOOTSTRAP" "passwd -d dx" "bootstrap.sh does not enable empty password"

# Test: bootstrap.sh sets PermitRootLogin no
assert_file_contains "$BOOTSTRAP" "PermitRootLogin no" "sshd_config has PermitRootLogin no"

# Test: bootstrap.sh sets PasswordAuthentication no
assert_file_contains "$BOOTSTRAP" "PasswordAuthentication no" "sshd_config has PasswordAuthentication no"

# Test: bootstrap.sh sets PermitEmptyPasswords no
assert_file_contains "$BOOTSTRAP" "PermitEmptyPasswords no" "sshd_config has PermitEmptyPasswords no"

# Test: bootstrap.sh keeps PubkeyAuthentication yes
assert_file_contains "$BOOTSTRAP" "PubkeyAuthentication yes" "sshd_config has PubkeyAuthentication yes"

# Test: bootstrap.sh keeps SSH on port 2222
assert_file_contains "$BOOTSTRAP" "Port 2222" "sshd_config has Port 2222"

# Test: authorized keys are configurable (not hardcoded personal key)
# Check for env var or file reference
if grep -q "AUTHORIZED_KEY\|AUTHORIZED_KEYS\|SSH_PUBLIC_KEY" "$BOOTSTRAP" || \
   grep -q '\$1\|\$2\|environment' "$BOOTSTRAP"; then
    test_pass "authorized keys are configurable"
else
    # Check if the key is still hardcoded
    if grep -q "ssh-ed25519.*damien@" "$BOOTSTRAP"; then
        test_fail "authorized keys are configurable (still hardcoded)"
    else
        test_pass "authorized keys are not hardcoded"
    fi
fi

# Test: dx-create keeps host publishing limited to 127.0.0.1
DX_CREATE="$BASE_DIR/bin/dx-create"
assert_file_contains "$DX_CREATE" "127.0.0.1:\$DX_SSH_PORT:2222" "dx-create limits SSH to localhost"

# Test: passwordless sudo is preserved
assert_file_contains "$BOOTSTRAP" "dx ALL=(ALL) NOPASSWD:ALL" "passwordless sudo preserved for dx"

print_summary
exit_with_code
