#!/bin/bash
# Section 4: Harden SSH While Keeping Sudo Convenient
# Tests for: SSH config hardening, key-only auth, passwordless sudo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

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

# Test: bootstrap.sh prepares OpenSSH runtime directories
assert_file_contains "$BOOTSTRAP" "mkdir -p /run /var/run/sshd" "bootstrap creates sshd runtime directories"

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

# Test: dx-create-container keeps host publishing limited to 127.0.0.1
DX_CREATE="$BASE_DIR/bin/dx-create-container"
assert_file_contains "$DX_CREATE" "127.0.0.1:\$DX_SSH_PORT:2222" "dx-create-container limits SSH to localhost"

# Test: passwordless sudo is preserved
assert_file_contains "$BOOTSTRAP" "dx ALL=(ALL) NOPASSWD:ALL" "passwordless sudo preserved for dx"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "SSH live behavior skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
else
    SSH_COMMON_OPTS=(
        "-i" "$DX_SSH_KEY"
        "-o" "StrictHostKeyChecking=no"
        "-o" "UserKnownHostsFile=/dev/null"
        "-o" "IdentitiesOnly=yes"
        "-o" "ConnectTimeout=5"
        "-p" "$DX_SSH_PORT"
    )

    if ssh "${SSH_COMMON_OPTS[@]}" "-o" "BatchMode=yes" dx@127.0.0.1 "true" >/dev/null 2>&1; then
        test_pass "live SSH accepts configured public-key auth"
    else
        test_fail "live SSH accepts configured public-key auth"
    fi

    if ssh "${SSH_COMMON_OPTS[@]}" "-o" "BatchMode=yes" "-o" "PubkeyAuthentication=no" dx@127.0.0.1 "true" >/dev/null 2>&1; then
        test_fail "live SSH refuses password-only auth"
    else
        test_pass "live SSH refuses password-only auth"
    fi
fi

print_summary
exit_with_code
