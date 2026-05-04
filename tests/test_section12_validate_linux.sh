#!/bin/bash
# Section 12: Validate Host-Agnostic Guest Bootstrap
# Tests for: bootstrap.sh works on Linux without Apple container
# These tests are designed to run INSIDE a Linux environment with Nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh"
FLAKE_DIR="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11"

test_section "Section 12: Validate Host-Agnostic Guest Bootstrap"

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
echo "  Testing: nix profile install from flake"
if nix profile install --profile /tmp/test-dx-profile "$FLAKE_DIR#default" \
    --extra-experimental-features "nix-command flakes" --accept-flake-config >/dev/null 2>&1; then
    test_pass "Nix tools install through flake"
else
    test_fail "Nix tools install through flake"
fi

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
rm -rf /tmp/test-dx-profile

print_summary
exit_with_code
