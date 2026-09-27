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
# Branch 11 / Phase 5 (qnap-dxe-plan.md DQ5): the guest SSH publish spec
# itself carries no bind address any more -- each runtime adapter prepends
# its own (Apple a fixed 127.0.0.1 literal, so host forwarding really is
# still loopback-only there; docker-ssh the NAS's own discovered Tailscale
# address, so it is emphatically NOT loopback-only for that runtime, which
# is the entire point of this phase). The Apple-side byte-for-byte proof
# lives in tests/test_runtime_boundary_characterisation.sh; this checks
# only that bin/dx-create-container itself never hardcodes a bind address
# in the --publish VALUE it passes (a prose comment nearby is allowed to
# mention 127.0.0.1 -- it names what the Apple ADAPTER does elsewhere).
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '--publish "$DX_SSH_PORT:2222"' "guest SSH publish spec carries no bind address (each runtime adapter supplies its own)"

# The guest's host identity is persisted on the dx-persist volume rather than
# regenerated onto the ephemeral rootfs each boot. Behavior for restore, the
# root-ownership trust boundary, and the symlink guards is covered by the
# section 3 bootstrap tests.
assert_file_contains_literal "$SYSTEM" '/persist/etc/ssh' "SSH host keys are persisted across rebuilds"
assert_file_contains_literal "$SYSTEM" 'dx_persist_host_keys' "configure_ssh restores or persists the host identity"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then test_skip "SSH live behavior skipped by --skip-integration"; else
    # requires_container already records its own SKIP and returns 1 when no
    # guest is running; short-circuiting `requires_container && dx-ssh` into
    # the same pass/fail branch as a real command failure turned that skip
    # into skip-plus-spurious-FAIL. Branch on requires_container first so the
    # no-guest case is exactly one SKIP and nothing else.
    if ! requires_container; then
        :
    elif "$BASE_DIR/bin/dx-ssh" true; then
        test_pass "key-only SSH live probe succeeds"
    else
        test_fail "key-only SSH live probe succeeds"
    fi
fi
print_summary
exit_with_code
