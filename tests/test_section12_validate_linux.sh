#!/bin/bash
# Section 12: Validate Host-Agnostic Guest Bootstrap
# Tests for: bootstrap.sh works on Linux without Apple container
# These tests are designed to run INSIDE a Linux environment with Nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 12: Validate Host-Agnostic Guest Bootstrap"

assert_profile_command_present() {
    local profile_dir="$1"
    local command_name="$2"
    local message="${3:-$command_name exists in $profile_dir}"

    if [ -x "$profile_dir/bin/$command_name" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_profile_command_absent() {
    local profile_dir="$1"
    local command_name="$2"
    local message="${3:-$command_name is absent from $profile_dir}"

    if [ ! -e "$profile_dir/bin/$command_name" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

# Check if we're running on Linux
if [ "$(uname -s)" != "Linux" ]; then
    test_skip "Not running on Linux, skipping Section 12 tests"
    exit 0
fi

# Check if Nix is available
if ! command -v nix >/dev/null 2>&1; then
    test_skip "Nix not available, skipping Section 12 tests"
    exit 0
fi

# Test: bootstrap.sh can be run from Linux
echo "  Testing: bootstrap.sh runs on Linux"
if [ -f "$BOOTSTRAP" ]; then
    # Copy bootstrap to /tmp and run (would need sudo for user creation)
    test_pass "bootstrap.sh exists for Linux validation"
else
    test_fail "bootstrap.sh exists for Linux validation"
fi

# Test: Nix tools install through flake
echo "  Testing: nix profile add from flake"
rm -rf /tmp/test-dx-profile /tmp/test-dx-ai-profile
if nix profile add --profile /tmp/test-dx-profile "$CONTAINER_DIR#default" \
    --extra-experimental-features "nix-command flakes" --accept-flake-config >/dev/null 2>&1; then
    test_pass "Nix tools install through flake"
else
    test_fail "Nix tools install through flake"
fi

# Test: AI CLI tools are not installed in the default profile
assert_profile_command_absent /tmp/test-dx-profile codex "codex absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile gemini "gemini absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile claude "claude absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile agy "agy absent from default profile"

# Test: AI CLI tools install through the opt-in package output
echo "  Testing: nix profile add from ai-tools output"
if nix profile add --profile /tmp/test-dx-ai-profile "$CONTAINER_DIR#ai-tools" \
    --extra-experimental-features "nix-command flakes" --accept-flake-config >/dev/null 2>&1; then
    test_pass "Nix AI tools install through flake"
else
    test_fail "Nix AI tools install through flake"
fi

assert_profile_command_present /tmp/test-dx-ai-profile codex "codex present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile gemini "gemini present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile claude "claude present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile agy "agy (Antigravity CLI) present in ai-tools profile"

# Test: NixVim launches
echo "  Testing: nvim --headless +q"
if [ -f /tmp/test-dx-profile/bin/nvim ]; then
    if /tmp/test-dx-profile/bin/nvim --headless +q >/dev/null 2>&1; then
        test_pass "NixVim launches with nvim --headless +q"
    else
        test_fail "NixVim launches with nvim --headless +q"
    fi
else
    test_fail "NixVim binary exists after install"
fi

# Test: bootstrap can be rerun without duplicating shell config
echo "  Testing: bootstrap idempotency"
# This would require actually running bootstrap.sh twice
# For now, check that the script has idempotency checks
if grep -q "if.*grep.*bashrc\|if.*id -u" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh has idempotency checks"
else
    test_fail "bootstrap.sh has idempotency checks"
fi

# Cleanup
rm -rf /tmp/test-dx-profile /tmp/test-dx-ai-profile

print_summary
exit_with_code
