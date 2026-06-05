#!/bin/bash
# Section 3: Split Bootstrap From Runtime
# Tests for: bootstrap.sh structure, idempotency, functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

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

# Test: bootstrap repairs Nix store ownership for older persistent volumes
assert_file_contains "$BOOTSTRAP" "ensure_nix_ownership" "bootstrap centralizes Nix ownership repair"
assert_file_contains "$BOOTSTRAP" "stat -c '%u:%g'" "bootstrap verifies Nix ownership marker owner"
assert_file_contains "$BOOTSTRAP" "chown dx:dx \"\$sentinel\"" "bootstrap marks repaired Nix ownership as dx-owned"

# Test: bootstrap initializes persisted Claude config as valid JSON
assert_file_not_contains "$BOOTSTRAP" "touch /persist/home/dx/.claude.json" "bootstrap does not create empty Claude JSON config"
assert_file_contains "$BOOTSTRAP" "printf '%s\\\\n' '{}' > /persist/home/dx/.claude.json" "bootstrap initializes empty Claude config as JSON"

# Test: bootstrap persists GitHub CLI auth/config across rebuilds
assert_file_contains "$BOOTSTRAP" "/persist/home/dx/.config/gh" "bootstrap persists GitHub CLI config under persist storage"
assert_file_contains "$BOOTSTRAP" "ln -sfnT /persist/home/dx/.config/gh /home/dx/.config/gh" "bootstrap links GitHub CLI config into home"
GH_PERSIST_LINE=$(grep -n "^[[:space:]]*setup_gh_persistence$" "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")
AI_GATE_LINE=$(grep -n "dx-ai-tools" "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")
if [ -n "$GH_PERSIST_LINE" ] && { [ -z "$AI_GATE_LINE" ] || [ "$GH_PERSIST_LINE" -lt "$AI_GATE_LINE" ]; }; then
    test_pass "GitHub CLI persistence is not gated by optional AI tools"
else
    test_fail "GitHub CLI persistence is not gated by optional AI tools"
fi

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

# Test: declarative timezone configuration exists
assert_file_contains "$FLAKE_NIX" "tzdata" "flake.nix includes tzdata"
assert_file_contains "$BOOTSTRAP" "run_as_dx 'printf %s \"\${TZDIR:-}\"'" "bootstrap reads timezone data directory from guest shell env"
assert_file_contains "$SHELL_NIX" "TZ = \"\$HOST_TZ\"" "shell.nix sets TZ for Bash/Fish"
assert_file_contains "$SHELL_NIX" "TZDIR = \"\${pkgs.tzdata}/share/zoneinfo\"" "shell.nix sets TZDIR for Bash/Fish"
assert_file_contains "$SHELL_NIX" "\$env.TZ = \$env.HOST_TZ?" "shell.nix sets TZ for Nushell"
assert_file_contains "$SHELL_NIX" "\$env.TZDIR = \"\${pkgs.tzdata}/share/zoneinfo\"" "shell.nix sets TZDIR for Nushell"

# Test: bash syntax check
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash syntax check"
else
    test_fail "bootstrap.sh passes bash syntax check"
fi

print_summary
exit_with_code
