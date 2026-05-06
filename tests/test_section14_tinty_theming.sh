#!/bin/bash
# Section 14: Tinty Theming
# Tests for: Tinty package/config, dx-theme wrapper, Neovim integration, and safe runtime assumptions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
set +e

HOME_NIX="$CONTAINER_DIR/home.nix"
HOME_SHELL_NIX="$CONTAINER_DIR/home/shell.nix"
HOME_TOOLS_NIX="$CONTAINER_DIR/home/tools.nix"
HOME_THEME_NIX="$CONTAINER_DIR/home/theme.nix"
SCRIPT_DX_THEME="$CONTAINER_DIR/scripts/dx-theme.sh"
SCRIPT_DX_THEME_COPY_HOOK="$CONTAINER_DIR/scripts/dx-theme-copy-hook.sh"
SCRIPT_DX_THEME_OSC_HOOK="$CONTAINER_DIR/scripts/dx-theme-osc-hook.sh"
SCRIPT_DX_THEME_RESTORE="$CONTAINER_DIR/scripts/dx-theme-restore.sh"
SCRIPT_DX_THEME_WRITE_TOOL_THEMES="$CONTAINER_DIR/scripts/dx-theme-write-tool-themes.sh"
NIXVIM_PLUGIN="$CONTAINER_DIR/nvim/plugins/tinted-nvim.nix"
LUALINE_NIX="$CONTAINER_DIR/nvim/plugins/lualine.nix"
ROSE_PINE_NIX="$CONTAINER_DIR/nvim/plugins/rose-pine.nix"
RUNNER="$SCRIPT_DIR/run_all_tests.sh"

test_section "Section 14: Tinty Theming"

assert_file_exists "$FLAKE_NIX" "flake.nix exists"
assert_file_exists "$HOME_NIX" "home.nix exists"
assert_file_exists "$NIXVIM_PLUGIN" "tinted-nvim plugin module exists"

assert_file_contains "$FLAKE_NIX" "tinty" "flake.nix includes tinty"
assert_file_contains "$FLAKE_NIX" "lazygit" "flake.nix includes lazygit for CLI theming"
assert_file_contains "$FLAKE_NIX" "btop" "flake.nix includes btop"

assert_file_contains "$HOME_THEME_NIX" "tinted-theming/tinty/config.toml" "home.nix declares Tinty config"
assert_file_contains "$HOME_THEME_NIX" "preferred-schemes" "Tinty config uses preferred-schemes schema"
assert_file_contains "$HOME_THEME_NIX" "base16-mocha" "Tinty config includes dark scheme"
assert_file_contains "$HOME_THEME_NIX" "base16-gruvbox-light-medium" "Tinty config includes light scheme"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine" "Tinty config includes Rose Pine"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine-moon" "Tinty config includes Rose Pine Moon"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine-dawn" "Tinty config includes Rose Pine Dawn"

assert_file_contains "$HOME_THEME_NIX" "dx-theme" "home/theme.nix declares dx-theme"
assert_file_contains "$HOME_THEME_NIX" "dx-theme-copy-hook" "home.nix declares Tinty copy hook"
assert_file_contains "$HOME_THEME_NIX" "dx-theme-osc-hook" "home.nix declares Tinty OSC hook"
assert_file_contains "$HOME_THEME_NIX" "dx-theme-restore" "home.nix declares Tinty login restore"
assert_file_contains "$SCRIPT_DX_THEME_COPY_HOOK" "TINTY_THEME_FILE_PATH" "hooks use TINTY_THEME_FILE_PATH"
assert_file_contains "$SCRIPT_DX_THEME_OSC_HOOK" "TINTY_SCHEME_PALETTE_BASE00_HEX_R" "OSC hook reads hook palette environment"
assert_file_contains "$SCRIPT_DX_THEME" "tinty current" "dx-theme current reads Tinty's native state"
assert_file_contains "$SCRIPT_DX_THEME" ".config/dx/theme-current" "dx-theme writes optional DX theme mirror"
assert_file_contains "$SCRIPT_DX_THEME" "tinty install || tinty sync" "dx-theme explicitly manages runtime Tinty repos"

assert_file_not_contains "$SCRIPT_DX_THEME" ".local/share/tinted-theming/tinty/tinted-shell/scripts/base16-" "no guessed generated tinted-shell script path"
assert_file_not_contains "$HOME_SHELL_NIX" "programs.zsh" "zsh is not added for Tinty"
assert_file_contains "$HOME_SHELL_NIX" "Nushell Tinted-shell startup support is intentionally not enabled" "Nushell support is documented as unproven"
assert_file_contains "$HOME_TOOLS_NIX" "set -g allow-passthrough on" "tmux passthrough remains enabled"
assert_file_contains "$HOME_THEME_NIX" "tinted-tmux" "Tinty tmux item is configured"
assert_file_contains "$HOME_THEME_NIX" "tinted-lazygit" "Tinty lazygit item is configured"
assert_file_contains "$HOME_TOOLS_NIX" "btop/btop.conf" "btop config is declared"
assert_file_contains "$HOME_TOOLS_NIX" 'color_theme = "dx-tinty"' "btop uses generated Tinty theme"
assert_file_contains "$HOME_THEME_NIX" "dx-theme-write-tool-themes" "tool theme writer is installed"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "btop/themes/dx-tinty.theme" "tool theme writer writes btop theme"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "yazi/theme.toml" "tool theme writer writes Yazi theme"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "starship.toml" "tool theme writer writes Starship theme"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" 'base0D=.*palette\[13\]' "tool theme writer maps Base16 blue slot"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" 'tinty info "$1"' "tool theme writer reads Tinty palette independently"
assert_file_contains "$SCRIPT_DX_THEME" 'refresh_tool_themes "$scheme"' "dx-theme refreshes tool themes after every apply"
assert_file_contains "$HOME_THEME_NIX" 'dx-theme-write-tool-themes" "$current"' "activation refreshes tool themes for existing theme"
assert_file_contains "$SCRIPT_DX_THEME_RESTORE" 'emit_osc 10 "$base05"' "login restore emits foreground OSC"
assert_file_contains "$SCRIPT_DX_THEME_RESTORE" 'emit_osc 11 "$base00"' "login restore emits background OSC"
assert_file_contains "$HOME_SHELL_NIX" 'try { ^/home/dx/.local/bin/dx-theme-restore }' "Nushell runs Tinty login restore"

assert_file_contains "$NIXVIM_NIX" "tinted-nvim.nix" "nixvim imports tinted-nvim plugin"
assert_file_contains "$NIXVIM_PLUGIN" "pkgs.vimPlugins.tinted-nvim" "Neovim uses packaged tinted-nvim first"
assert_file_contains "$NIXVIM_PLUGIN" "tinty = true" "tinted-nvim reads Tinty's current scheme"
assert_file_contains "$NIXVIM_PLUGIN" "live_reload = false" "Neovim avoids unrequired live reload"
assert_file_contains "$LUALINE_NIX" 'theme = "tinted"' "lualine uses tinted theme"
assert_file_not_contains "$LUALINE_NIX" 'theme = "rose-pine"' "lualine no longer hard-codes rose-pine"
assert_file_contains "$ROSE_PINE_NIX" "pkgs.vimPlugins.rose-pine" "Rose Pine remains packaged as fallback"

assert_file_contains "$RUNNER" "0-14" "test runner help includes section 14"
assert_file_contains "$RUNNER" 'run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"' "test runner explicitly runs section 14"
assert_file_not_contains "$FLAKE_NIX" "stylix" "Stylix dependency was not added"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Tinty integration skipped by --skip-integration"
elif ! command -v container >/dev/null 2>&1; then
    test_skip "container CLI not available, skipping Tinty integration"
elif ! container list | awk '{print $1}' | grep -x -q "dx-host"; then
    test_skip "Container 'dx-host' is not running, skipping Tinty integration"
elif ! container exec -u dx dx-host bash -lc 'command -v tinty >/dev/null 2>&1 && command -v dx-theme >/dev/null 2>&1'; then
    test_skip "running container has not been rebuilt or activated with Tinty yet"
else
    if container exec -u dx dx-host bash -lc 'command -v tinty && command -v dx-theme'; then
        test_pass "tinty and dx-theme are installed in running container"
    else
        test_fail "tinty and dx-theme are installed in running container"
    fi

    if container exec -u dx dx-host bash -lc 'tinty config >/dev/null && dx-theme list >/dev/null'; then
        test_pass "Tinty config and dx-theme list work in running container"
    else
        test_fail "Tinty config and dx-theme list work in running container"
    fi

    if container exec -u dx dx-host bash -lc 'dx-theme dark >/dev/null && test "$(dx-theme current)" = "$(tinty current)"'; then
        test_pass "dx-theme dark applies and matches Tinty current state"
    else
        test_fail "dx-theme dark applies and matches Tinty current state"
    fi

    if container exec -u dx dx-host bash -lc 'if [ -f ~/.config/dx/theme-current ]; then test "$(cat ~/.config/dx/theme-current)" = "$(tinty current)"; fi'; then
        test_pass "optional DX theme mirror matches Tinty current state"
    else
        test_fail "optional DX theme mirror matches Tinty current state"
    fi

    if container exec -u dx dx-host bash -lc 'dx-theme light >/dev/null && printf stale > ~/.config/btop/themes/dx-tinty.theme && printf stale > ~/.config/yazi/theme.toml && printf stale > ~/.config/starship.toml && dx-theme light >/dev/null && restore_output="$(dx-theme-restore)" && case "$restore_output" in *"$(printf "\033]10;#")"* ) true ;; *) false ;; esac && case "$restore_output" in *"$(printf "\033]11;#")"* ) true ;; *) false ;; esac && grep -q "#fbf1c7" ~/.config/btop/themes/dx-tinty.theme && grep -q "#fbf1c7" ~/.config/yazi/theme.toml && grep -q "palette = \"dx-tinty\"" ~/.config/starship.toml && grep -q "#fbf1c7" ~/.config/starship.toml && yazi --debug >/tmp/dx-yazi-debug.out 2>/tmp/dx-yazi-debug.err && test ! -s /tmp/dx-yazi-debug.err && starship print-config >/tmp/dx-starship-config.out 2>/tmp/dx-starship-config.err && test ! -s /tmp/dx-starship-config.err && dx-theme rose-pine >/dev/null && dx-theme rose-pine-moon >/dev/null && dx-theme rose-pine-dawn >/dev/null && dx-theme test >/dev/null'; then
        test_pass "light and Rose Pine dx-theme commands work"
    else
        test_fail "light and Rose Pine dx-theme commands work"
    fi
fi

print_summary
exit_with_code
