#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
SYSTEM="$CONTAINER_DIR/bootstrap/system.sh"
test_section "Section 4: Harden SSH While Keeping Sudo Convenient"

for setting in 'PermitRootLogin no' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'PermitEmptyPasswords no' 'Port 2222'; do
    assert_file_contains_literal "$SYSTEM" "$setting" "sshd_config contains $setting"
done
assert_file_contains_literal "$SYSTEM" 'mkdir -p /run /var/run/sshd' "bootstrap creates sshd runtime directories"
assert_file_contains_literal "$SYSTEM" 'DX_PUB_KEY' "authorized keys are configurable"
assert_file_contains_literal "$SYSTEM" 'dx ALL=(ALL) NOPASSWD:ALL' "passwordless sudo is preserved for dx"
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '127.0.0.1:$DX_SSH_PORT:2222' "host SSH forwarding is loopback-only"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then test_skip "SSH live behavior skipped by --skip-integration"; else
    if requires_container && "$BASE_DIR/bin/dx-ssh" true; then test_pass "key-only SSH live probe succeeds"; else test_fail "key-only SSH live probe succeeds"; fi
fi
print_summary
exit_with_code
