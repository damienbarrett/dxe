#!/bin/bash
# tier: unit
# bash32: no
# Section 8: Clean Up NixVim Configuration
# Tests for: no duplicate plugins, proper use of NixVim modules

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
set +e

test_section "Section 8: Clean Up NixVim Configuration"

# Test: files exist
assert_file_exists "$FLAKE_NIX" "flake.nix exists"
assert_file_exists "$NIXVIM_NIX" "nixvim.nix exists"

HERDR_NAV_LUA="$CONTAINER_DIR/nvim/extra_plugins/herdr-navigator.lua"
assert_file_exists "$HERDR_NAV_LUA" "Herdr-aware Neovim navigator exists"
assert_file_contains "$HERDR_NAV_LUA" "HERDR_PANE_ID" "Neovim navigator targets its containing Herdr pane"
assert_file_contains "$HERDR_NAV_LUA" 'vim.cmd("wincmd "' "Neovim navigator tries editor splits first"
assert_file_contains "$HERDR_NAV_LUA" '"pane",' "Neovim navigator invokes the Herdr pane API at an editor edge"
assert_file_contains "$HERDR_NAV_LUA" '"focus",' "Neovim navigator focuses an adjacent Herdr pane at an editor edge"

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

# Test: Comment.nvim's pre_hook survives NixVim's module system (WP7.7,
# docs/reviews/2026-09-29-fable.md finding C7). Behavioural, not source
# text: checks.<system>.nvim launches the real, headless Neovim built from
# nixvim.nix with an extra `assert(require('Comment.config'):get().pre_hook,
# ...)`, and NixVim's own test harness fails the build if Neovim prints
# anything to stderr -- so this catches "pre_hook was set, then silently
# overridden" the way the old two-`require('Comment').setup(...)` calls
# could, which a grep counting call sites cannot.
if command -v nix >/dev/null 2>&1; then
    # The flake's checks only exist for the two Linux guest systems
    # (flake.nix's supportedSystems), never for the host's own OS, so this
    # maps the host CPU architecture straight to "<arch>-linux" -- the same
    # `uname -m` idiom scripts/lib/dx-guest-system.sh uses guest-side.
    case "$(uname -m)" in
        aarch64|arm64) NVIM_CHECK_SYSTEM=aarch64-linux ;;
        x86_64|amd64)  NVIM_CHECK_SYSTEM=x86_64-linux ;;
        *)             NVIM_CHECK_SYSTEM="" ;;
    esac
    if [ -z "$NVIM_CHECK_SYSTEM" ]; then
        test_skip "unsupported host architecture ($(uname -m)), skipping checks.<system>.nvim"
    elif nix build --no-write-lock-file --no-link "$CONTAINER_DIR#checks.$NVIM_CHECK_SYSTEM.nvim" 2>/dev/null; then
        test_pass "checks.$NVIM_CHECK_SYSTEM.nvim: Comment's pre_hook survives NixVim's module system"
    else
        test_fail "checks.$NVIM_CHECK_SYSTEM.nvim: Comment's pre_hook survives NixVim's module system"
    fi
else
    test_skip "nix not available, skipping checks.<system>.nvim"
fi

# Test: prefer NixVim modules over extraPlugins
EXTRA_COUNT=$(echo "$COMBINED_NIX" | grep -E "pkgs.vimUtils.buildVimPlugin|pkgs.vimPlugins" | wc -l | xargs)
if [ "$EXTRA_COUNT" -gt 10 ]; then
    test_fail "minimize use of extraPlugins (current: $EXTRA_COUNT)"
else
    test_pass "minimize use of extraPlugins (current: $EXTRA_COUNT)"
fi

# Test: plugins in extraPlugins pinned to commit, not main
if echo "$COMBINED_NIX" | stdin_matches 'rev = "main"'; then
    test_fail "plugins in extraPlugins pinned to commit, not main"
else
    test_pass "plugins in extraPlugins pinned to commit, not main"
fi

# Test: hashes for custom plugin sources
CUSTOM_PLUGINS=$(echo "$COMBINED_NIX" | grep -A10 "vimUtils.buildVimPlugin" || echo "")
if echo "$CUSTOM_PLUGINS" | stdin_matches "hash = "; then
    test_pass "hashes for custom plugin sources present"
else
    test_fail "hashes for custom plugin sources present"
fi

# Test: render-markdown NixVim module enabled for in-buffer markdown rendering
RENDER_MD=$(echo "$COMBINED_NIX" | grep -E "render-markdown.enable = true|render-markdown = \{" | wc -l | xargs)
if [ "$RENDER_MD" -gt 0 ]; then
    test_pass "render-markdown NixVim module is enabled for in-buffer markdown rendering"
else
    test_fail "render-markdown NixVim module is enabled for in-buffer markdown rendering"
fi

# Test: nixvim.nix imports the render-markdown plugin module
RENDER_MD_IMPORT=$(echo "$COMBINED_NIX" | grep -c "nvim/plugins/render-markdown.nix")
if [ "$RENDER_MD_IMPORT" -gt 0 ]; then
    test_pass "nixvim.nix imports nvim/plugins/render-markdown.nix"
else
    test_fail "nixvim.nix imports nvim/plugins/render-markdown.nix"
fi

# Test: NixVim flake check (if nix available)
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-build --no-write-lock-file "$CONTAINER_DIR" 2>/dev/null; then
        test_pass "NixVim flake check passes"
    else
        test_fail "NixVim flake check passes"
    fi
else
    test_skip "nix not available, skipping flake check"
fi

if ! live_tail_enabled; then
    test_skip "NixVim live launch skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on the guest (SSH port $DX_SSH_PORT)"
elif guest_bash "nvim --headless +q >/dev/null"; then
    test_pass "built NixVim starts headlessly in the live guest"
else
    test_fail "built NixVim starts headlessly in the live guest"
fi

print_summary
exit_with_code
