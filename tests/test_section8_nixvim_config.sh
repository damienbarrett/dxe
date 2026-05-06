#!/bin/bash
# Section 8: Clean Up NixVim Configuration
# Tests for: no duplicate plugins, proper use of NixVim modules

set -uo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
set +e

test_section "Section 8: Clean Up NixVim Configuration"

# Test: files exist
assert_file_exists "$FLAKE_NIX" "flake.nix exists"
assert_file_exists "$NIXVIM_NIX" "nixvim.nix exists"

# Combined content for easier checking
# Including nvim directory for decomposed config
COMBINED_NIX=$(find "$CONTAINER_DIR"/nvim -name "*.nix" -print0 | xargs -0 cat)
COMBINED_NIX="$(cat "$FLAKE_NIX" "$NIXVIM_NIX")${COMBINED_NIX}"

# Test: undotree not configured both as NixVim module and manually
UNDO_NIXVIM=$(echo "$COMBINED_NIX" | grep "undotree.enable = true" | wc -l | xargs)
UNDO_EXTRA=$(echo "$COMBINED_NIX" | grep -E "undotree-lua|undotree" | grep -v "enable" | wc -l | xargs)
if [ "$UNDO_NIXVIM" -gt 0 ] && [ "$UNDO_EXTRA" -gt 0 ]; then
    test_fail "undotree not configured both as NixVim module and manually"
else
    test_pass "undotree not configured both as NixVim module and manually"
fi

# Test: Comment.nvim not configured both as NixVim module and in extraConfigLua
COMMENT_MODULE=$(echo "$COMBINED_NIX" | grep "comment.enable = true" | wc -l | xargs)
COMMENT_EXTRA=$(echo "$COMBINED_NIX" | grep -E "require.*Comment.*setup|require.*ts_context_commentstring" | wc -l | xargs)
if [ "$COMMENT_MODULE" -gt 0 ] && [ "$COMMENT_EXTRA" -gt 1 ]; then
    test_fail "Comment.nvim not configured both as NixVim module and in extraConfigLua (Module: $COMMENT_MODULE, Extra: $COMMENT_EXTRA)"
else
    test_pass "Comment.nvim not configured both as NixVim module and in extraConfigLua"
fi

# Test: prefer NixVim modules over extraPlugins
EXTRA_COUNT=$(echo "$COMBINED_NIX" | grep -E "pkgs.vimUtils.buildVimPlugin|pkgs.vimPlugins" | wc -l | xargs)
if [ "$EXTRA_COUNT" -gt 10 ]; then
    test_fail "minimize use of extraPlugins (current: $EXTRA_COUNT)"
else
    test_pass "minimize use of extraPlugins (current: $EXTRA_COUNT)"
fi

# Test: plugins in extraPlugins pinned to commit, not main
if echo "$COMBINED_NIX" | grep -q 'rev = "main"'; then
    test_fail "plugins in extraPlugins pinned to commit, not main"
else
    test_pass "plugins in extraPlugins pinned to commit, not main"
fi

# Test: hashes for custom plugin sources
CUSTOM_PLUGINS=$(echo "$COMBINED_NIX" | grep -A10 "vimUtils.buildVimPlugin" || echo "")
if echo "$CUSTOM_PLUGINS" | grep -q "hash = "; then
    test_pass "hashes for custom plugin sources present"
else
    test_fail "hashes for custom plugin sources present"
fi

# Test: NixVim flake check (if nix available)
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-write-lock-file "$CONTAINER_DIR" 2>/dev/null; then
        test_pass "NixVim flake check passes"
    else
        test_fail "NixVim flake check passes"
    fi
else
    test_skip "nix not available, skipping flake check"
fi

print_summary
exit_with_code
