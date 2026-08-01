#!/bin/bash
# Section 13: Final Review
# Tests for: all final checks before completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 13: Final Review"

# Test: no private keys are tracked
if git -C "$BASE_DIR" ls-files | grep -q "dx_key\|private.*key\|id_rsa\|id_ed25519"; then
    test_fail "no private keys are tracked by git"
else
    test_pass "no private keys are tracked by git"
fi

# Test: no .DS_Store files are tracked
if git -C "$BASE_DIR" ls-files | grep -q "\.DS_Store"; then
    test_fail "no .DS_Store files are tracked by git"
else
    test_pass "no .DS_Store files are tracked by git"
fi

# Test: flake.lock exists and is not ignored
if [ -f "$FLAKE_LOCK" ] && ! git -C "$BASE_DIR" check-ignore -q "$FLAKE_LOCK"; then
    test_pass "flake.lock is present and not ignored"
else
    test_fail "flake.lock is present and not ignored"
fi

# Test: nvim/ lazy.nvim runtime config removed or quarantined
if git -C "$BASE_DIR" ls-files | grep -q "nvim/lua/core/lazy.lua\|nvim/lazy-lock.json"; then
    test_fail "nvim/ lazy.nvim runtime config removed or quarantined"
else
    test_pass "nvim/ lazy.nvim runtime config removed or quarantined"
fi

# Test: Containerfile does not install tools
assert_file_not_contains "$CONTAINERFILE" "RUN nix profile install" "Containerfile does not install tools"

# Test: SSH is key-only
assert_file_contains "$CONTAINER_DIR/bootstrap/system.sh" "PubkeyAuthentication yes" "SSH has PubkeyAuthentication yes"
assert_file_contains "$CONTAINER_DIR/bootstrap/system.sh" "PasswordAuthentication no" "SSH has PasswordAuthentication no"
assert_file_contains "$CONTAINER_DIR/bootstrap/system.sh" "PermitEmptyPasswords no" "SSH has PermitEmptyPasswords no"

# Test: passwordless sudo still works for dx
assert_file_contains "$CONTAINER_DIR/bootstrap/system.sh" "dx ALL=(ALL) NOPASSWD:ALL" "passwordless sudo works for dx"

print_summary
exit_with_code
