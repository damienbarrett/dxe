#!/bin/bash
# Section 5: Pin Nix Inputs
# Tests for: flake.lock exists, inputs pinned

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLAKE_LOCK="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.lock"
FLAKE_NIX="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix"

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

# Test: flake.nix references nixos-25.11
assert_file_contains "$FLAKE_NIX" "nixos-25.11" "flake.nix uses nixos-25.11"

# Test: bash syntax check for flake.nix (if nix is available)
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-write-lock-file "$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11" 2>/dev/null; then
        test_pass "nix flake check passes"
    else
        test_fail "nix flake check passes"
    fi
else
    test_skip "nix not available, skipping flake check"
fi

print_summary
exit_with_code
