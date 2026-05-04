#!/bin/bash
# Section 7: Remove lazy.nvim
# Tests for: NixVim is canonical, lazy.nvim removed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLAKE_NIX="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix"
NVIM_DIR="$BASE_DIR/nvim"

test_section "Section 7: Remove lazy.nvim"

# Test: flake.nix is the canonical editor configuration
assert_file_exists "$FLAKE_NIX" "flake.nix is the canonical editor configuration"

# Test: nvim/lua/core/lazy.lua not in committed source tree
if git -C "$BASE_DIR" ls-files --error-unmatch "$NVIM_DIR/lua/core/lazy.lua" >/dev/null 2>&1; then
    test_fail "nvim/lua/core/lazy.lua not in committed source tree"
else
    test_pass "nvim/lua/core/lazy.lua not in committed source tree"
fi

# Test: lazy-lock.json not in committed source tree
if git -C "$BASE_DIR" ls-files --error-unmatch "$NVIM_DIR/lazy-lock.json" >/dev/null 2>&1; then
    test_fail "nvim/lazy-lock.json not in committed source tree"
else
    test_pass "nvim/lazy-lock.json not in committed source tree"
fi

# Test: no committed file bootstraps plugins with Git at Neovim startup
# Check for packer, lazy, or other git-based plugin managers in committed files
if git -C "$BASE_DIR" ls-files | grep -E "\.(lua|vim|sh)$" | xargs grep -l "lazy.nvim\|folke/lazy.nvim\|require.*lazy" 2>/dev/null | grep -v "tests/"; then
    test_fail "no committed file bootstraps plugins with lazy.nvim"
else
    test_pass "no committed file bootstraps plugins with lazy.nvim"
fi

# Test: rg search for lazy.nvim returns no active runtime config
if grep -r "lazy.nvim\|require(\"lazy\")\|folke/lazy.nvim" "$BASE_DIR" \
    --include="*.lua" --include="*.vim" 2>/dev/null | \
    grep -v "tests/" | grep -v ".git"; then
    test_fail "rg -n lazy.nvim returns no active runtime config"
else
    test_pass "rg -n lazy.nvim returns no active runtime config"
fi

# Test: nvim directory quarantined or removed
if [ -d "$NVIM_DIR" ]; then
    # Check if it's quarantined (e.g., renamed with _disabled, .bak, etc.)
    if [[ "$NVIM_DIR" == *.disabled ]] || [[ "$NVIM_DIR" == *.bak ]] || \
       [ -f "$NVIM_DIR/.quarantined" ]; then
        test_pass "nvim/ directory is quarantined"
    else
        test_fail "nvim/ directory should be removed or quarantined"
    fi
else
    test_pass "nvim/ directory removed"
fi

print_summary
exit_with_code
