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

BASE16_SLOTS=(00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F)
TEST_PALETTE=(
    000000 111111 222222 333333 444444 555555 666666 777777
    aa0000 bb6600 ccaa00 00aa66 00aaaa 5599ff cc66ff 663300
)
GRUVBOX_DARK_HARD_PALETTE=(
    1d2021 282828 3c3836 504945 665c54 d5c4a1 ebdbb2 fbf1c7
    fb4934 fe8019 fabd2f b8bb26 8ec07c 83a598 d3869b d65d0e
)

base16_env_args() {
    local i slot color
    for i in "${!BASE16_SLOTS[@]}"; do
        slot="${BASE16_SLOTS[$i]}"
        color="${TEST_PALETTE[$i]}"
        printf 'TINTY_SCHEME_PALETTE_BASE%s_HEX_R=%s\n' "$slot" "${color:0:2}"
        printf 'TINTY_SCHEME_PALETTE_BASE%s_HEX_G=%s\n' "$slot" "${color:2:2}"
        printf 'TINTY_SCHEME_PALETTE_BASE%s_HEX_B=%s\n' "$slot" "${color:4:2}"
    done
}

run_tool_theme_writer() {
    local home="$1"
    shift
    HOME="$home" bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "$@"
}

assert_file_exists "$FLAKE_NIX" "flake.nix exists"
assert_file_exists "$HOME_NIX" "home.nix exists"
assert_file_exists "$NIXVIM_PLUGIN" "tinted-nvim plugin module exists"

assert_file_contains "$FLAKE_NIX" "tinty" "flake.nix includes tinty"
assert_file_contains "$FLAKE_NIX" "lazygit" "flake.nix includes lazygit for CLI theming"
assert_file_contains "$FLAKE_NIX" "btop" "flake.nix includes btop"

assert_file_contains "$HOME_THEME_NIX" "tinted-theming/tinty/config.toml" "home.nix declares Tinty config"
assert_file_contains "$HOME_THEME_NIX" "preferred-schemes" "Tinty config uses preferred-schemes schema"
assert_file_contains "$HOME_THEME_NIX" "base16-mocha" "Tinty config includes dark scheme"
assert_grep_in_file "$HOME_THEME_NIX" 'dark[[:space:]]*=[[:space:]]*"base16-mocha"' "dark alias uses warm Mocha background"
assert_file_contains "$HOME_THEME_NIX" "base16-gruvbox-light-medium" "Tinty config includes light scheme"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine" "Tinty config includes Rose Pine"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine-moon" "Tinty config includes Rose Pine Moon"
assert_file_contains "$HOME_THEME_NIX" "base16-rose-pine-dawn" "Tinty config includes Rose Pine Dawn"

# SRP guards: theme aliases live in a single declarative attrset that
# generates a JSON registry consumed by dx-theme.sh. If anyone ever
# re-introduces a per-alias bash variable in the script or a parallel
# alias list in another file, these asserts fire.
assert_file_contains "$HOME_THEME_NIX" "dxThemes" "theme.nix declares dxThemes alias registry"
assert_file_contains "$HOME_THEME_NIX" "dx/themes.json" "theme.nix emits dx/themes.json runtime registry"
assert_file_not_contains "$SCRIPT_DX_THEME" "DX_THEME_DARK=" "dx-theme.sh does not hardcode per-alias variables"
assert_file_not_contains "$SCRIPT_DX_THEME" "dark|light|rose-pine|rose-pine-moon|rose-pine-dawn" "dx-theme.sh dispatch is not alias-enumerating"
assert_file_contains "$HOME_THEME_NIX" "base16-catppuccin-mocha" "theme registry includes catppuccin-mocha"
assert_file_contains "$HOME_THEME_NIX" "gruvbox-dark" "theme registry includes explicit gruvbox-dark alias"
assert_file_contains "$HOME_THEME_NIX" "base16-everforest-dark-hard" "theme registry includes everforest-dark"
assert_file_contains "$HOME_THEME_NIX" "base16-solarized-light" "theme registry includes solarized-light"
assert_file_contains "$HOME_THEME_NIX" "base16-solarized-dark" "theme registry includes solarized-dark"
assert_file_contains "$HOME_THEME_NIX" "base16-shades-of-purple" "theme registry includes Shades of Purple"

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
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "tinty info" "tool theme writer reads Tinty palette independently"
assert_file_contains "$SCRIPT_DX_THEME" 'refresh_tool_themes "$scheme"' "dx-theme refreshes tool themes after every apply"
assert_file_contains "$HOME_THEME_NIX" 'dx-theme-write-tool-themes" "$current"' "activation refreshes tool themes for existing theme"
assert_file_contains "$SCRIPT_DX_THEME_RESTORE" 'emit_osc 10 "$base05"' "login restore emits foreground OSC"
assert_file_contains "$SCRIPT_DX_THEME_RESTORE" 'emit_osc 11 "$base00"' "login restore emits background OSC"
assert_file_contains "$HOME_SHELL_NIX" 'try { ^/home/dx/.local/bin/dx-theme-restore }' "Nushell runs Tinty login restore"

TOOL_THEME_TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TOOL_THEME_TEST_HOME"' EXIT
if run_tool_theme_writer "$TOOL_THEME_TEST_HOME" "${TEST_PALETTE[@]}"; then
    test_pass "tool theme writer accepts a direct Base16 palette"
else
    test_fail "tool theme writer accepts a direct Base16 palette"
fi
assert_file_contains_literal \
    "$TOOL_THEME_TEST_HOME/.config/btop/themes/dx-tinty.theme" \
    'theme[title]="#cc66ff"' \
    "btop generated theme uses base0E title accent"
assert_file_contains_literal \
    "$TOOL_THEME_TEST_HOME/.config/yazi/theme.toml" \
    'normal_main = { fg = "#000000", bg = "#cc66ff", bold = true }' \
    "Yazi generated theme uses base0E normal-mode accent"
assert_file_contains_literal \
    "$TOOL_THEME_TEST_HOME/.config/starship.toml" \
    'success_symbol = "[>](bold fg:base0E)"' \
    "Starship generated theme uses base0E success prompt"

# --- Theme-aware tmux pills (feature/tmux-theme-pills) -------------------
# tmux.conf statically pins the status bar to the top of the window so the
# layout is correct even before the dynamic writer has had a chance to run.
assert_file_contains "$HOME_TOOLS_NIX" "set -g status-position top" \
    "tmux config sets status-position top at bootstrap"

# At tmux server start, fire the writer in the background. The if-shell
# guard makes the call a no-op until the script is actually installed.
assert_file_contains_literal "$HOME_TOOLS_NIX" \
    "if-shell 'test -x ~/.local/bin/dx-theme-write-tool-themes' 'run-shell -b ~/.local/bin/dx-theme-write-tool-themes'" \
    "tmux config invokes the tool-theme writer (gated on the script existing)"

# `bind S` toggles synchronize-panes, which the writer renders as a SYNC
# pill in status-right. The `refresh-client -S` between the toggle and
# the display-message is load-bearing: without it the SYNC pill would
# only appear at the next status-interval tick (every 5s in
# apply_tmux_pills), making the toggle feel laggy. Locking it in here
# prevents a future "cleanup" from regressing the snap-on-toggle UX.
assert_file_contains_literal "$HOME_TOOLS_NIX" \
    'bind -N "Toggle synchronize-panes for this window" S setw synchronize-panes' \
    "tmux config binds S to the synchronize-panes toggle"
assert_file_contains "$HOME_TOOLS_NIX" "refresh-client -S" \
    "synchronize-panes toggle forces an immediate status-bar redraw"

# The writer applies pill-style options to the live tmux server via a
# single source-file invocation. The behavioral capture below verifies
# the rendered status config without pinning internal helper names.
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "tmux source-file" \
    "apply_tmux_pills batches options through a single tmux source-file call"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "set-option -gq status-position top" \
    "apply_tmux_pills pins tmux status-position to top"
assert_file_contains_literal "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" \
    'set-option -gq status-style "fg=#$base05,bg=#$base00"' \
    "apply_tmux_pills derives status-style from the Base16 palette"
# Activity/bell style overrides: without these, tmux's default `reverse`
# attribute flips fg/bg on the Powerline cap glyphs, turning rounded pills
# into square-edged blocks whenever a window has unseen activity or a bell.
assert_file_contains_literal "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" \
    'window-status-activity-style' \
    "apply_tmux_pills sets window-status-activity-style (prevents reverse breaking pill caps)"
assert_file_contains_literal "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" \
    'window-status-bell-style' \
    "apply_tmux_pills sets window-status-bell-style (prevents reverse breaking pill caps)"
# After the rename, only `accent_*` names should appear; `purple_*` was
# a misleading carry-over from the original gruvbox-only color palette.
assert_file_not_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "purple_primary" \
    "writer no longer uses purple_primary (renamed to accent_primary)"
assert_file_not_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "purple_secondary" \
    "writer no longer uses purple_secondary (renamed to accent_secondary)"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "accent_primary" \
    "writer uses accent_primary as the base0E (theme accent) hex alias"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "starship_accent_primary" \
    "writer uses starship_accent_primary as the base0E palette-ref alias"

# PATH fallback so the writer can find tinty when invoked from tmux's
# run-shell -b (which may inherit a minimal PATH that excludes
# ~/.nix-profile/bin).
assert_file_contains_literal "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" \
    'PATH="$HOME/.nix-profile/bin:$PATH"' \
    "writer prepends ~/.nix-profile/bin to PATH when tinty is not found"

# Zero-arg mode prefers Tinty's hook env vars over `tinty current` so the
# copy-hook applies the *incoming* palette without racing tinty's state
# pointer.
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "TINTY_SCHEME_PALETTE_BASE00_HEX_R" \
    "writer reads TINTY_SCHEME_PALETTE_* hook env vars in 0-arg mode"

# Copy-hook now just calls the writer with no args — the env-var-to-palette
# translation lives in one place (the writer), not duplicated in every hook.
assert_file_contains "$SCRIPT_DX_THEME_COPY_HOOK" "dx-theme-write-tool-themes" \
    "copy-hook invokes the tool-theme writer after sourcing tmux.conf"
assert_file_not_contains "$SCRIPT_DX_THEME_COPY_HOOK" "TINTY_SCHEME_PALETTE_BASE0F_HEX_B" \
    "copy-hook does not duplicate the env-var-to-palette expansion"

# Behavioral: 0-arg + TINTY env vars should produce themes from those vars
# rather than from `tinty current` (which would TOCTOU during apply).
ENV_PALETTE_HOME="$TOOL_THEME_TEST_HOME/env-mode"
mkdir -p "$ENV_PALETTE_HOME"
env_palette_args=()
while IFS= read -r assignment; do
    env_palette_args+=( "$assignment" )
done < <(base16_env_args)
if env -i HOME="$ENV_PALETTE_HOME" PATH="$PATH" "${env_palette_args[@]}" \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES"; then
    test_pass "writer accepts zero-arg invocation driven by TINTY_SCHEME_PALETTE_* env vars"
else
    test_fail "writer accepts zero-arg invocation driven by TINTY_SCHEME_PALETTE_* env vars"
fi
assert_file_contains_literal \
    "$ENV_PALETTE_HOME/.config/btop/themes/dx-tinty.theme" \
    'theme[title]="#cc66ff"' \
    "env-var mode: btop theme uses palette base0E for title accent"
assert_file_contains_literal \
    "$ENV_PALETTE_HOME/.config/yazi/theme.toml" \
    'normal_main = { fg = "#000000", bg = "#cc66ff", bold = true }' \
    "env-var mode: Yazi theme uses palette base0E for normal-mode accent"
assert_file_contains_literal \
    "$ENV_PALETTE_HOME/.config/starship.toml" \
    'success_symbol = "[>](bold fg:base0E)"' \
    "env-var mode: Starship theme uses palette base0E for success prompt"

# Graceful degradation: 0 args, no env palette, no tinty on PATH → exit 0
# silently with no theme files written (the size guard catches an empty
# palette before any file is touched).
NO_PALETTE_HOME="$TOOL_THEME_TEST_HOME/no-palette"
mkdir -p "$NO_PALETTE_HOME"
if env -i HOME="$NO_PALETTE_HOME" PATH="/usr/bin:/bin" \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES"; then
    test_pass "writer exits 0 when 0-arg + no env palette + no tinty"
else
    test_fail "writer exits 0 when 0-arg + no env palette + no tinty"
fi
if [ ! -f "$NO_PALETTE_HOME/.config/btop/themes/dx-tinty.theme" ] \
   && [ ! -f "$NO_PALETTE_HOME/.config/yazi/theme.toml" ] \
   && [ ! -f "$NO_PALETTE_HOME/.config/starship.toml" ]; then
    test_pass "writer leaves theme files untouched when it cannot resolve a palette"
else
    test_fail "writer leaves theme files untouched when it cannot resolve a palette"
fi

# Partial hook env should not create malformed colors or fall back to
# `tinty current`, because that would reintroduce the switch-time race.
PARTIAL_ENV_HOME="$TOOL_THEME_TEST_HOME/partial-env"
mkdir -p "$PARTIAL_ENV_HOME"
if env -i HOME="$PARTIAL_ENV_HOME" PATH="$PATH" \
    TINTY_SCHEME_PALETTE_BASE00_HEX_R=00 \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES"; then
    test_pass "writer exits 0 for incomplete TINTY_SCHEME_PALETTE_* env"
else
    test_fail "writer exits 0 for incomplete TINTY_SCHEME_PALETTE_* env"
fi
if [ ! -f "$PARTIAL_ENV_HOME/.config/btop/themes/dx-tinty.theme" ] \
   && [ ! -f "$PARTIAL_ENV_HOME/.config/yazi/theme.toml" ] \
   && [ ! -f "$PARTIAL_ENV_HOME/.config/starship.toml" ]; then
    test_pass "writer leaves theme files untouched for incomplete hook env"
else
    test_fail "writer leaves theme files untouched for incomplete hook env"
fi

# Behavioral: stub tmux to capture what apply_tmux_pills would source-file,
# then assert the captured config covers the expected pills. This is the
# behavioral counterpart to the file-content assertions above — without
# this, a future refactor could silently drop the SYNC pill or end-caps.
PILL_PROBE_HOME="$TOOL_THEME_TEST_HOME/pill-probe"
PILL_PROBE_STUB="$TOOL_THEME_TEST_HOME/pill-probe-stub"
mkdir -p "$PILL_PROBE_HOME" "$PILL_PROBE_STUB"
cat > "$PILL_PROBE_STUB/tmux" <<'STUB_EOF'
#!/usr/bin/env bash
# Liveness probe: always succeed.
[ "$1" = "set-option" ] && [ "$3" = "status" ] && [ "$4" = "on" ] && exit 0
# Capture the heredoc fed to source-file.
[ "$1" = "source-file" ] && cp "$2" "$DX_PILL_PROBE_OUT" && exit 0
exit 0
STUB_EOF
chmod +x "$PILL_PROBE_STUB/tmux"
DX_PILL_PROBE_OUT="$PILL_PROBE_HOME/captured.tmux.conf"
export DX_PILL_PROBE_OUT
if PATH="$PILL_PROBE_STUB:$PATH" \
    run_tool_theme_writer "$PILL_PROBE_HOME" "${GRUVBOX_DARK_HARD_PALETTE[@]}"; then
    test_pass "writer drives apply_tmux_pills when tmux is reachable"
else
    test_fail "writer drives apply_tmux_pills when tmux is reachable"
fi
assert_file_exists "$DX_PILL_PROBE_OUT" "apply_tmux_pills issues a tmux source-file call"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'set-option -gq pane-border-status bottom' \
    "sourced config sets pane-border-status to bottom"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'pane-border-format "#[align=right]#{?pane_active,' \
    "pane-border-format right-aligns pill and uses conditional for active/inactive"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'bg=#fabd2f bold]' \
    "active pane label uses space-separated attrs (comma-safe for #{?} conditionals)"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'pane-active-border-style "fg=#fabd2f,bg=#1d2021,bold"' \
    "pane-active-border-style sets bg to base00 so pill caps blend correctly"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'pane-border-style "fg=#' \
    "pane-border-style is set (inactive pane border uses palette fg)"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'pane-border-style "fg=#504945,bg=#1d2021"' \
    "pane-border-style sets bg to base00 so pill caps blend on inactive panes"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'set-option -gq status-position top' \
    "sourced config pins status-position top"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'set-option -gq status-style "fg=#d5c4a1,bg=#1d2021"' \
    "sourced config derives status-style from the Base16 palette"
# Captured activity/bell styles must use explicit palette colors (not the
# default tmux `reverse`) so Powerline pill caps render correctly.
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'window-status-activity-style "fg=#d5c4a1,bg=#1d2021"' \
    "sourced config sets window-status-activity-style to bar palette (not reverse)"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'window-status-bell-style "fg=#fb4934,bg=#1d2021"' \
    "sourced config sets window-status-bell-style to base08 accent on bar bg"
# SYNC pill: gated on tmux's synchronize-panes predicate, colored from
# base08 (red slot). Asserting the predicate name keeps a future
# refactor from quietly flipping the condition.
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    '#{?synchronize-panes,' \
    "sourced status-right gates the SYNC pill on synchronize-panes"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    ' SYNC ' \
    "sourced status-right contains a SYNC label"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'bg=#fb4934,bold] SYNC ' \
    "SYNC pill uses base08 (red) as accent against the bar bg"
# PREFIX pill: same conditional pattern, base09 (orange) accent.
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    '#{?client_prefix,' \
    "sourced status-right gates the PREFIX pill on client_prefix"
assert_file_contains_literal "$DX_PILL_PROBE_OUT" \
    'bg=#fe8019,bold] PREFIX ' \
    "PREFIX pill uses base09 (orange) as accent against the bar bg"
# tmux-continuum coexistence (static): the pill generator overwrites
# status-right, so it must carry continuum's #(continuum_save.sh) save token
# across the rewrite. Runtime behaviour is asserted in the live block below.
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "continuum_save" "pill generator preserves continuum auto-save token in status-right"

# End-cap glyphs: U+E0B6 (left, ) and U+E0B4 (right, ). These come
# from the pill() helper; if a refactor drops them, all pills go
# square-edged. Bytes asserted via grep for portability.
if LC_ALL=C grep -q $'\xee\x82\xb6' "$DX_PILL_PROBE_OUT"; then
    test_pass "sourced pills include U+E0B6 left end-cap glyph"
else
    test_fail "sourced pills include U+E0B6 left end-cap glyph"
fi
if LC_ALL=C grep -q $'\xee\x82\xb4' "$DX_PILL_PROBE_OUT"; then
    test_pass "sourced pills include U+E0B4 right end-cap glyph"
else
    test_fail "sourced pills include U+E0B4 right end-cap glyph"
fi

assert_file_contains "$NIXVIM_NIX" "tinted-nvim.nix" "nixvim imports tinted-nvim plugin"
assert_file_contains "$NIXVIM_PLUGIN" "pkgs.vimPlugins.tinted-nvim" "Neovim uses packaged tinted-nvim first"
assert_file_not_contains "$NIXVIM_PLUGIN" "tinted-colorscheme" "Neovim theming no longer uses the deprecated tinted-colorscheme module"
assert_file_contains_literal "$NIXVIM_PLUGIN" 'require("tinted-nvim").setup' "Neovim uses the new tinted-nvim setup API"
assert_file_contains_literal "$NIXVIM_PLUGIN" 'tinted-theming/tinty/current_scheme' "tinted-nvim selector reads Tinty's current scheme file"
assert_file_contains_literal "$NIXVIM_PLUGIN" "watch = true" "tinted-nvim selector watches for live theme changes"
assert_file_contains "$LUALINE_NIX" 'theme = "tinted"' "lualine uses tinted theme"
assert_file_not_contains "$LUALINE_NIX" 'theme = "rose-pine"' "lualine no longer hard-codes rose-pine"
assert_file_contains "$ROSE_PINE_NIX" "pkgs.vimPlugins.rose-pine" "Rose Pine remains packaged as fallback"

assert_file_contains "$RUNNER" "0-20" "test runner help advertises current section range"
assert_file_contains "$RUNNER" 'run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"' "test runner explicitly runs section 14"
assert_file_not_contains "$FLAKE_NIX" "stylix" "Stylix dependency was not added"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Tinty integration skipped by --skip-integration"
elif ! command -v container >/dev/null 2>&1; then
    test_skip "container CLI not available, skipping Tinty integration"
elif ! container_is_running "$DX_CONTAINER_NAME"; then
    test_skip "Container '$DX_CONTAINER_NAME' is not running, skipping Tinty integration"
elif ! container_exec_dx_bash 'command -v tinty >/dev/null 2>&1 && command -v dx-theme >/dev/null 2>&1'; then
    test_skip "running container has not been rebuilt or activated with Tinty yet"
else
    if container_exec_dx_bash 'command -v tinty && command -v dx-theme'; then
        test_pass "tinty and dx-theme are installed in running container"
    else
        test_fail "tinty and dx-theme are installed in running container"
    fi

    if container_exec_dx_bash 'tinty config >/dev/null && dx-theme list >/dev/null'; then
        test_pass "Tinty config and dx-theme list work in running container"
    else
        test_fail "Tinty config and dx-theme list work in running container"
    fi

    if container_exec_dx_bash 'dx-theme dark >/dev/null && test "$(tinty current)" = "base16-mocha" && dx-theme test | grep -qi "base00/background: #3B3228"'; then
        test_pass "dx-theme dark applies the warm Mocha palette"
    else
        test_fail "dx-theme dark applies the warm Mocha palette"
    fi

    if container_exec_dx_bash 'if [ -f ~/.config/dx/theme-current ]; then test "$(cat ~/.config/dx/theme-current)" = "$(tinty current)"; fi'; then
        test_pass "optional DX theme mirror matches Tinty current state"
    else
        test_fail "optional DX theme mirror matches Tinty current state"
    fi

    if container_exec_dx_bash 'dx-theme light >/dev/null && printf stale > ~/.config/btop/themes/dx-tinty.theme && printf stale > ~/.config/yazi/theme.toml && printf stale > ~/.config/starship.toml && dx-theme light >/dev/null && restore_output="$(dx-theme-restore)" && case "$restore_output" in *"$(printf "\033]10;#")"* ) true ;; *) false ;; esac && case "$restore_output" in *"$(printf "\033]11;#")"* ) true ;; *) false ;; esac && grep -q "#fbf1c7" ~/.config/btop/themes/dx-tinty.theme && grep -q "#fbf1c7" ~/.config/yazi/theme.toml && grep -q "palette = \"dx-tinty\"" ~/.config/starship.toml && grep -q "#fbf1c7" ~/.config/starship.toml && yazi --debug >/tmp/dx-yazi-debug.out 2>/tmp/dx-yazi-debug.err && test ! -s /tmp/dx-yazi-debug.err && starship print-config >/tmp/dx-starship-config.out 2>/tmp/dx-starship-config.err && test ! -s /tmp/dx-starship-config.err && dx-theme rose-pine >/dev/null && dx-theme rose-pine-moon >/dev/null && dx-theme rose-pine-dawn >/dev/null && dx-theme test >/dev/null'; then
        test_pass "light and Rose Pine dx-theme commands work"
    else
        test_fail "light and Rose Pine dx-theme commands work"
    fi

    # Each new alias resolves to its expected base16 scheme. The pairs
    # below mirror dxThemes in home/theme.nix; if that registry changes,
    # update this list.
    new_alias_pairs='gruvbox-dark=base16-gruvbox-dark-hard
catppuccin=base16-catppuccin-mocha
catppuccin-latte=base16-catppuccin-latte
catppuccin-frappe=base16-catppuccin-frappe
catppuccin-macchiato=base16-catppuccin-macchiato
catppuccin-mocha=base16-catppuccin-mocha
everforest-dark=base16-everforest-dark-hard
everforest-light=base16-everforest-light-medium
solarized-dark=base16-solarized-dark
solarized-light=base16-solarized-light
shades-of-purple=base16-shades-of-purple'
    if container_exec_dx_bash "
        set -e
        printf '%s\n' '$new_alias_pairs' | while IFS='=' read -r alias scheme; do
            dx-theme \"\$alias\" >/dev/null
            actual=\"\$(tinty current)\"
            if [ \"\$actual\" != \"\$scheme\" ]; then
                echo \"FAIL: dx-theme \$alias -> \$actual (expected \$scheme)\" >&2
                exit 1
            fi
        done
    "; then
        test_pass "new theme aliases (gruvbox/catppuccin/everforest/solarized/shades-of-purple) apply correctly"
    else
        test_fail "new theme aliases (gruvbox/catppuccin/everforest/solarized/shades-of-purple) apply correctly"
    fi

    # Live tmux pill verification: applying a theme should set tmux's
    # status options from the active Base16 palette. We boot an
    # ephemeral tmux server, switch theme, then probe the options.
    # This is the end-to-end proof that copy-hook → writer → apply_tmux_pills
    # actually reaches the running server (not just file generation).
    if container_exec_dx_bash '
        set -e
        export TMUX_TMPDIR="$(mktemp -d)"
        trap "tmux -L dx-pill-test kill-server >/dev/null 2>&1 || true; rm -rf \"$TMUX_TMPDIR\"" EXIT
        tmux -f /dev/null -L dx-pill-test new-session -d -s pill-probe
        export TMUX="$(tmux -L dx-pill-test display-message -p "#{socket_path},#{pid},#{pane_id}")"
        dx-theme dark >/dev/null
        # status-position must be top after the writer runs.
        pos="$(tmux -L dx-pill-test show-options -gv status-position)"
        # status-style must carry the Base16 bg (base00 from the active palette).
        style="$(tmux -L dx-pill-test show-options -gv status-style)"
        # status-left must reference the session name placeholder (#S).
        sleft="$(tmux -L dx-pill-test show-options -gv status-left)"
        [ "$pos" = "top" ] \
            && printf "%s" "$style" | grep -q "bg=#" \
            && printf "%s" "$sleft" | grep -q "#S"
    '; then
        test_pass "applying a theme sets tmux pill options on the live server"
    else
        test_fail "applying a theme sets tmux pill options on the live server"
    fi

    # TOCTOU guard: switching themes back-to-back must leave the pill
    # status-style matching the *most recent* palette, not a stale one.
    # If the copy-hook re-queried `tinty current` mid-apply, the second
    # switch could lag one theme behind.
    if container_exec_dx_bash '
        set -e
        export TMUX_TMPDIR="$(mktemp -d)"
        trap "tmux -L dx-toctou-test kill-server >/dev/null 2>&1 || true; rm -rf \"$TMUX_TMPDIR\"" EXIT
        tmux -f /dev/null -L dx-toctou-test new-session -d -s pill-toctou
        export TMUX="$(tmux -L dx-toctou-test display-message -p "#{socket_path},#{pid},#{pane_id}")"
        dx-theme dark >/dev/null
        dx-theme light >/dev/null
        # Light scheme bg should now be in status-style; the dark bg should not.
        light_bg="$(grep "^base00" ~/.config/starship.toml | cut -d"\"" -f2 | tr -d "#" | head -n1)"
        style="$(tmux -L dx-toctou-test show-options -gv status-style)"
        printf "%s" "$style" | grep -qi "bg=#$light_bg"
    '; then
        test_pass "back-to-back theme switches leave tmux pills on the latest palette (no TOCTOU)"
    else
        test_fail "back-to-back theme switches leave tmux pills on the latest palette (no TOCTOU)"
    fi

    # tmux-continuum coexistence: the pill generator overwrites status-right,
    # so it must preserve continuum's #(continuum_save.sh) save token or
    # interval auto-save dies after any theme apply. Behaviour-check the live
    # status-right after a real server start.
    SR_PROBE="$(tmux_guest_statusright_probe || true)"
    if printf '%s\n' "$SR_PROBE" | grep -q "__PROBE_FAILED__" || [ -z "$SR_PROBE" ]; then
        test_fail "status-right probe started a server in the guest"
    else
        test_pass "status-right probe started a server in the guest"
        assert_tmux_runtime "$SR_PROBE" sync-pill yes "status-right keeps the SYNC pill alongside continuum"
        assert_tmux_runtime "$SR_PROBE" prefix-pill yes "status-right keeps the PREFIX pill alongside continuum"
        assert_tmux_runtime "$SR_PROBE" continuum-interp yes "status-right preserves continuum's auto-save token after the pill generator runs"
    fi

    # Prove interval auto-save actually fires (gated: ~80s and writes /persist).
    if [ "${DX_TEST_DESTRUCTIVE:-0}" = "1" ]; then
        CONT_AUTOSAVE="$(tmux_guest_continuum_autosave || true)"
        assert_tmux_runtime "$CONT_AUTOSAVE" autosave-fired yes "continuum interval auto-save writes a fresh resurrect save"
    else
        test_skip "continuum interval auto-save behaviour (set DX_TEST_DESTRUCTIVE=1 to run)"
    fi
fi

print_summary
exit_with_code
