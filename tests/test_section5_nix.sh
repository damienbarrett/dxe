#!/bin/bash
# Section 5: Pin Nix Inputs
# Tests for: flake.lock exists, inputs pinned

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 5: Pin Nix Inputs"

# Test: flake.lock exists
assert_file_exists "$FLAKE_LOCK" "flake.lock exists"

# Test: flake.lock is not ignored by git
if git -C "$BASE_DIR" check-ignore "$FLAKE_LOCK" >/dev/null 2>&1; then
    test_fail "flake.lock is ignored by git"
else
    test_pass "flake.lock is not ignored by git"
fi

# Test: nixpkgs is pinned to exact revision in flake.lock
if [ -f "$FLAKE_LOCK" ]; then
    assert_file_contains "$FLAKE_LOCK" '"nixpkgs"' "nixpkgs entry in flake.lock"
    assert_file_contains "$FLAKE_LOCK" '"rev"' "nixpkgs has revision pinned"
else
    test_skip "flake.lock not found, skipping rev check"
fi

# Test: nixvim is pinned to exact revision in flake.lock
if [ -f "$FLAKE_LOCK" ]; then
    assert_file_contains "$FLAKE_LOCK" '"nixvim"' "nixvim entry in flake.lock"
else
    test_skip "flake.lock not found, skipping nixvim check"
fi

# Test: flake.nix references the expected NixOS branch
assert_file_contains "$FLAKE_NIX" "$DX_EXPECTED_NIXOS_BRANCH" "flake.nix uses $DX_EXPECTED_NIXOS_BRANCH"

# Test: bash syntax check for flake.nix (if nix is available)
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-write-lock-file "$CONTAINER_DIR" 2>/dev/null; then
        test_pass "nix flake check passes"
    else
        test_fail "nix flake check passes"
    fi
else
    test_skip "nix not available, skipping flake check"
fi

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Nix release identity live checks skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
else
    if guest_bash "grep -q '^VERSION_ID=\"$DX_EXPECTED_NIXOS_RELEASE\"' /etc/os-release"; then
        test_pass "live guest reports NixOS $DX_EXPECTED_NIXOS_RELEASE in /etc/os-release"
    else
        test_fail "live guest reports NixOS $DX_EXPECTED_NIXOS_RELEASE in /etc/os-release"
    fi

    if guest_bash "grep -q '$DX_EXPECTED_NIXOS_BRANCH' /guest-bootstrap/flake.lock"; then
        test_pass "live guest bootstrap flake.lock points stable inputs at $DX_EXPECTED_NIXOS_BRANCH"
    else
        test_fail "live guest bootstrap flake.lock points stable inputs at $DX_EXPECTED_NIXOS_BRANCH"
    fi
fi

print_summary
exit_with_code
