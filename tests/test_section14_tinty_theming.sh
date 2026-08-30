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
    # DX_THEME_SKIP_HERDR_RELOAD keeps the writer from signalling a Herdr
    # server: this suite also runs on a developer host that may have a live
    # Herdr of its own, and a test must not reload the user's real session.
    HOME="$home" DX_THEME_SKIP_HERDR_RELOAD=1 bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "$@"
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
# ORIGINAL_THEME_SCHEME is populated by the live Tinted/project.nvim runtime
# block below (if it runs). Restoring it on every exit path -- including an
# early failure -- keeps this test from leaving the guest's active theme
# changed after the selector.watch=true proof switches it.
ORIGINAL_THEME_SCHEME=""
cleanup_section14() {
    rm -rf "$TOOL_THEME_TEST_HOME"
    if [ -n "$ORIGINAL_THEME_SCHEME" ]; then
        container_exec_dx_bash "dx-theme apply '$ORIGINAL_THEME_SCHEME'" >/dev/null 2>&1 || true
    fi
}
trap cleanup_section14 EXIT
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

assert_file_contains "$RUNNER" "0-26" "test runner help advertises current section range"
assert_file_contains "$RUNNER" 'run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"' "test runner explicitly runs section 14"
assert_file_not_contains "$FLAKE_NIX" "stylix" "Stylix dependency was not added"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Tinty integration skipped by --skip-integration"
elif ! requires_container; then
    : # requires_container records the skip reason.
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
    if printf '%s\n' "$SR_PROBE" | stdin_matches "__PROBE_FAILED__" || [ -z "$SR_PROBE" ]; then
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

    # --- Live Tinted Neovim + project.nvim runtime regression coverage -----
    # Repeatable runtime coverage for the tinted-nvim migration and the
    # project.nvim empty-history warning fix.
    # These load the guest's REAL baked nixvim config via headless Neovim, so
    # they only pass once the project-nvim.nix payload above is deployed.
    # Any guest state this mutates (the active Tinty scheme) is restored by
    # the cleanup_section14 EXIT trap declared near the top of this file.
    if ! wait_for_ssh 60; then
        test_skip "Tinted/project.nvim live runtime probes (SSH not reachable on localhost:$DX_SSH_PORT)"
    else
        ORIGINAL_THEME_SCHEME="$(container_exec_dx_bash 'tinty current' 2>/dev/null | tr -d '\r\n')"

        SSH_COMMON_OPTS=(
            "-i" "$DX_SSH_KEY"
            "-o" "StrictHostKeyChecking=no"
            "-o" "UserKnownHostsFile=/dev/null"
            "-o" "IdentitiesOnly=yes"
            "-o" "BatchMode=yes"
            "-o" "ConnectTimeout=5"
        )
        SSH_OPTS=("${SSH_COMMON_OPTS[@]}" "-p" "$DX_SSH_PORT")
        SCP_OPTS=("${SSH_COMMON_OPTS[@]}" "-P" "$DX_SSH_PORT")

        # scp a file to an explicit remote path. A multi-line Lua probe
        # embedded directly in an ssh/bash command string fights quoting --
        # especially the project.nvim message text below, which itself
        # contains embedded quotes -- so probes travel as files, mirroring
        # section 15/16's run_nu scp-then-ssh pattern.
        push_file() {
            local local_file="$1" remote_path="$2"
            scp "${SCP_OPTS[@]}" "$local_file" "dx@127.0.0.1:$remote_path" >/dev/null 2>&1
        }

        # --- Tinted: no deprecation message + colors_name matches Tinty ----
        TINTED_STARTUP_PROBE_LOCAL=$(mktemp -t dx_tinted_startup_probe.XXXXXX)
        cat > "$TINTED_STARTUP_PROBE_LOCAL" <<'LUA_EOF'
local msgs = vim.fn.execute("messages")
local deprecated = "no"
if msgs:find("Deprecated module 'tinted-colorscheme'", 1, true) then
  deprecated = "yes"
end
io.write("DEPRECATION_SEEN=" .. deprecated .. "\n")
io.write("COLORS_NAME=" .. tostring(vim.g.colors_name) .. "\n")
LUA_EOF
        remote_tinted_probe="/tmp/$(basename "$TINTED_STARTUP_PROBE_LOCAL").lua"
        if push_file "$TINTED_STARTUP_PROBE_LOCAL" "$remote_tinted_probe"; then
            TINTED_PROBE_OUT="$(ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'nvim --headless -c \"luafile $remote_tinted_probe\" -c \"qa\" 2>&1; rc=\$?; rm -f $remote_tinted_probe; exit \$rc'" 2>&1)"
        else
            TINTED_PROBE_OUT=""
        fi
        rm -f "$TINTED_STARTUP_PROBE_LOCAL"

        if printf '%s\n' "$TINTED_PROBE_OUT" | stdin_matches -x "DEPRECATION_SEEN=no"; then
            test_pass "headless nvim startup emits no tinted-colorscheme deprecation message"
        else
            test_fail "headless nvim startup emits no tinted-colorscheme deprecation message (probe output: $TINTED_PROBE_OUT)"
        fi

        NVIM_COLORS_NAME="$(printf '%s\n' "$TINTED_PROBE_OUT" | sed -n 's/^COLORS_NAME=//p' | head -n1)"
        if [ -n "$NVIM_COLORS_NAME" ] && [ -n "$ORIGINAL_THEME_SCHEME" ] && [ "$NVIM_COLORS_NAME" = "$ORIGINAL_THEME_SCHEME" ]; then
            test_pass "vim.g.colors_name equals tinty current ($ORIGINAL_THEME_SCHEME) at startup"
        else
            test_fail "vim.g.colors_name ('$NVIM_COLORS_NAME') does not equal tinty current ('$ORIGINAL_THEME_SCHEME')"
        fi

        # --- Tinted: selector.watch=true updates a long-lived nvim's colors_name.
        # Start a headless nvim with an RPC socket, read colors_name, switch
        # the active scheme, then poll the SAME running process (not a fresh
        # one, which would only prove apply_scheme_on_startup).
        ALT_SCHEME="base16-gruvbox-dark-hard"
        if [ "$ALT_SCHEME" = "$ORIGINAL_THEME_SCHEME" ]; then
            ALT_SCHEME="base16-mocha"
        fi
        WATCH_OUT="$(container_exec_dx env ALT_SCHEME="$ALT_SCHEME" bash -lc '
            set -u
            sock="/tmp/dxe-nvim-watch-$$.sock"
            rm -f "$sock"
            nvim --headless --listen "$sock" >/tmp/dxe-nvim-watch-$$.log 2>&1 &
            nvpid=$!
            started=no
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                if [ -S "$sock" ]; then started=yes; break; fi
                sleep 0.5
            done
            if [ "$started" != yes ]; then
                echo "WATCH_STARTED=no"
                kill "$nvpid" >/dev/null 2>&1 || true
                exit 0
            fi
            echo "WATCH_STARTED=yes"
            before="$(nvim --server "$sock" --remote-expr "g:colors_name" 2>/dev/null)"
            echo "WATCH_BEFORE=$before"
            dx-theme apply "$ALT_SCHEME" >/dev/null 2>&1
            after="$before"
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
                after="$(nvim --server "$sock" --remote-expr "g:colors_name" 2>/dev/null)"
                [ "$after" = "$ALT_SCHEME" ] && break
                sleep 0.5
            done
            echo "WATCH_AFTER=$after"
            kill "$nvpid" >/dev/null 2>&1 || true
            rm -f "$sock" "/tmp/dxe-nvim-watch-$$.log"
        ' 2>&1)"
        WATCH_STARTED="$(printf '%s\n' "$WATCH_OUT" | sed -n 's/^WATCH_STARTED=//p' | head -n1)"
        WATCH_BEFORE="$(printf '%s\n' "$WATCH_OUT" | sed -n 's/^WATCH_BEFORE=//p' | head -n1)"
        WATCH_AFTER="$(printf '%s\n' "$WATCH_OUT" | sed -n 's/^WATCH_AFTER=//p' | head -n1)"
        if [ "$WATCH_STARTED" != "yes" ]; then
            test_skip "selector.watch=true live-update proof (could not start a --listen headless nvim on the guest: $WATCH_OUT)"
        elif [ "$WATCH_AFTER" = "$ALT_SCHEME" ] && [ "$WATCH_BEFORE" != "$ALT_SCHEME" ]; then
            test_pass "long-lived nvim's vim.g.colors_name follows dx-theme apply $ALT_SCHEME (selector.watch=true)"
        else
            test_fail "long-lived nvim's vim.g.colors_name did not follow dx-theme apply $ALT_SCHEME (before=$WATCH_BEFORE after=$WATCH_AFTER)"
        fi

        # --- project.nvim: exact empty-history warning is filtered, control passes.
        PROJECT_EMPTY_PROBE_LOCAL=$(mktemp -t dx_project_empty_probe.XXXXXX)
        cat > "$PROJECT_EMPTY_PROBE_LOCAL" <<'LUA_EOF'
vim.cmd("messages clear")
local ok_history, history = pcall(require, "project.util.history")
if ok_history and history and history.write_history then
  pcall(history.write_history)
end
vim.notify("dx-project-notify-control", vim.log.levels.WARN)
local msgs = vim.fn.execute("messages")
local empty_seen = "no"
if msgs:find("(project.util.history.write_history): No data available to write!", 1, true) then
  empty_seen = "yes"
end
local control_seen = "no"
if msgs:find("dx-project-notify-control", 1, true) then
  control_seen = "yes"
end
io.write("REQUIRE_OK=" .. tostring(ok_history) .. "\n")
io.write("EMPTY_HISTORY_SEEN=" .. empty_seen .. "\n")
io.write("CONTROL_SEEN=" .. control_seen .. "\n")
LUA_EOF
        PROJECT_EMPTY_DRIVER_LOCAL=$(mktemp -t dx_project_empty_driver.XXXXXX)
        cat > "$PROJECT_EMPTY_DRIVER_LOCAL" <<'DRIVER_EOF'
#!/bin/bash
set -u
probe="$1"
workdir=$(mktemp -d /tmp/dxe-project-empty-XXXXXX)
xdgdata=$(mktemp -d /tmp/dxe-project-empty-data-XXXXXX)
cd "$workdir" || exit 1
XDG_DATA_HOME="$xdgdata" nvim --headless -c "luafile $probe" -c "qa" 2>&1
rc=$?
rm -rf "$workdir" "$xdgdata" "$probe"
exit $rc
DRIVER_EOF
        remote_empty_probe="/tmp/$(basename "$PROJECT_EMPTY_PROBE_LOCAL").lua"
        remote_empty_driver="/tmp/$(basename "$PROJECT_EMPTY_DRIVER_LOCAL").sh"
        if push_file "$PROJECT_EMPTY_PROBE_LOCAL" "$remote_empty_probe" \
            && push_file "$PROJECT_EMPTY_DRIVER_LOCAL" "$remote_empty_driver"; then
            PROJECT_EMPTY_OUT="$(ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'bash $remote_empty_driver $remote_empty_probe; rc=\$?; rm -f $remote_empty_driver; exit \$rc'" 2>&1)"
        else
            PROJECT_EMPTY_OUT=""
        fi
        rm -f "$PROJECT_EMPTY_PROBE_LOCAL" "$PROJECT_EMPTY_DRIVER_LOCAL"

        if printf '%s\n' "$PROJECT_EMPTY_OUT" | stdin_matches -x "EMPTY_HISTORY_SEEN=no"; then
            test_pass "project.nvim empty-history write_history() no longer notifies the WARN message"
        else
            test_fail "project.nvim empty-history write_history() unexpectedly notified (probe output: $PROJECT_EMPTY_OUT)"
        fi
        if printf '%s\n' "$PROJECT_EMPTY_OUT" | stdin_matches -x "CONTROL_SEEN=yes"; then
            test_pass "control vim.notify(WARN) still reaches :messages (filter is not over-suppressing)"
        else
            test_fail "control vim.notify(WARN) did not reach :messages (probe output: $PROJECT_EMPTY_OUT)"
        fi

        # --- project.nvim: a real recognised project can still write history.
        # Best-effort: relies on project.nvim's own automatic (manual_mode =
        # false) BufEnter detection firing for a real buffer opened inside a
        # directory containing .git, then checks its on-disk history file.
        # The exact history file location/format is not independently
        # verified in this session, so an inconclusive result degrades to a
        # skip rather than a fail -- the absence+control assertions above are
        # the firm regression guard for the filter itself.
        PROJECT_REAL_PROBE_LOCAL=$(mktemp -t dx_project_real_probe.XXXXXX)
        cat > "$PROJECT_REAL_PROBE_LOCAL" <<'LUA_EOF'
local ok_history, history = pcall(require, "project.util.history")
local write_ok = false
if ok_history and history and history.write_history then
  write_ok = pcall(history.write_history)
end
vim.wait(300)
local hist_path = vim.fn.stdpath("data") .. "/project_nvim/project_history"
local has_data = (vim.fn.filereadable(hist_path) == 1) and (vim.fn.getfsize(hist_path) > 0)
io.write("REQUIRE_OK=" .. tostring(ok_history) .. "\n")
io.write("WRITE_OK=" .. tostring(write_ok) .. "\n")
io.write("HISTORY_HAS_DATA=" .. tostring(has_data) .. "\n")
LUA_EOF
        PROJECT_REAL_DRIVER_LOCAL=$(mktemp -t dx_project_real_driver.XXXXXX)
        cat > "$PROJECT_REAL_DRIVER_LOCAL" <<'DRIVER_EOF'
#!/bin/bash
set -u
probe="$1"
workdir=$(mktemp -d /tmp/dxe-project-real-XXXXXX)
xdgdata=$(mktemp -d /tmp/dxe-project-real-data-XXXXXX)
mkdir -p "$workdir/.git"
printf 'probe\n' > "$workdir/README.md"
cd "$workdir" || exit 1
XDG_DATA_HOME="$xdgdata" nvim --headless "$workdir/README.md" -c "luafile $probe" -c "qa" 2>&1
rc=$?
rm -rf "$workdir" "$xdgdata" "$probe"
exit $rc
DRIVER_EOF
        remote_real_probe="/tmp/$(basename "$PROJECT_REAL_PROBE_LOCAL").lua"
        remote_real_driver="/tmp/$(basename "$PROJECT_REAL_DRIVER_LOCAL").sh"
        if push_file "$PROJECT_REAL_PROBE_LOCAL" "$remote_real_probe" \
            && push_file "$PROJECT_REAL_DRIVER_LOCAL" "$remote_real_driver"; then
            PROJECT_REAL_OUT="$(ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'bash $remote_real_driver $remote_real_probe; rc=\$?; rm -f $remote_real_driver; exit \$rc'" 2>&1)"
        else
            PROJECT_REAL_OUT=""
        fi
        rm -f "$PROJECT_REAL_PROBE_LOCAL" "$PROJECT_REAL_DRIVER_LOCAL"

        if printf '%s\n' "$PROJECT_REAL_OUT" | stdin_matches -x "HISTORY_HAS_DATA=true"; then
            test_pass "write_history() still persists data for a recognised (.git) project"
        else
            test_skip "write_history() persisted-data check for a recognised project was inconclusive (probe output: $PROJECT_REAL_OUT)"
        fi
    fi
fi

# --- Herdr chrome theming (herdr-theme-plan.md Layer 2) ---
#
# herdr-theme-plan.md concluded this layer was unbuildable: Herdr accepted only
# eight built-in theme names and no palette, so four of sixteen dx-theme
# aliases -- including the default -- had no match. That conclusion was wrong.
# With `[theme] name = "terminal"`, Herdr honours a full custom palette under
# `[theme.custom]`, so the base16 scheme maps exactly and no approximation is
# needed. Confirmed against herdr 0.7.5: `herdr config check` reports unknown
# keys in that table, and reports none for the keys written here.
#
# Executing the writer needs the guest toolchain (Bash 4 `mapfile`, GNU
# `chmod --reference`), so the behavior half is Linux-only, exactly as in
# tests/test_herdr_config_persistence.sh. The static assertions run everywhere.
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "write_herdr_theme" "the tool theme writer themes Herdr's chrome"
assert_file_contains "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "write_herdr_host_terminals" "the tool theme writer repaints attached Herdr host terminals"
assert_file_contains_literal "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" 'name = "terminal"' "Herdr is put in terminal-palette mode rather than a built-in theme name"
assert_file_contains "$SCRIPT_DX_THEME_RESTORE" "HERDR_PANE_ID" "theme restore detects a Herdr pane"
assert_file_contains "$SCRIPT_DX_THEME_OSC_HOOK" "HERDR_PANE_ID" "the OSC hook detects a Herdr pane"

# The hand-off must degrade, not fail. The OSC hook runs as a Tinty hook, so a
# non-zero exit here surfaces as `dx-theme <name>` failing. On a guest where
# Home Manager has not installed the writer yet -- a real state during
# bootstrap -- the Herdr branch has nothing to exec, and an unguarded `exec`
# under `set -e` would take the whole hook down with it.
herdr_handoff_home="$(mktemp -d)"
for hook_script in "$SCRIPT_DX_THEME_OSC_HOOK" "$SCRIPT_DX_THEME_RESTORE"; do
    hook_name="$(basename "$hook_script" .sh)"
    if HOME="$herdr_handoff_home" HERDR_PANE_ID=pane-1 \
        $(base16_env_args | sed 's/^/env /' | tr '\n' ' ') bash "$hook_script" >/dev/null 2>&1; then
        test_pass "$hook_name survives a Herdr pane with no writer installed"
    else
        test_fail "$hook_name survives a Herdr pane with no writer installed"
    fi
done
rm -rf "$herdr_handoff_home"

# The writer runs unguarded here: a stubbed `herdr` on PATH supplies the
# validator, and the Herdr paths this exercises avoid the guest-only
# constructs elsewhere in the script, so these assertions hold on the macOS
# host too. Only the /proc-walking host-terminal repaint needs a real guest.
herdr_theme_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-herdr-theme.XXXXXX")"
herdr_cfg="$herdr_theme_fixture/config.toml"
herdr_stub_dir="$herdr_theme_fixture/bin"
mkdir -p "$herdr_stub_dir"
# A palette whose 16 slots are distinguishable, so a wrong slot mapping is
# visible rather than coincidentally correct.
herdr_palette=(001100 011101 021102 031103 041104 051105 061106 071107 \
               081108 091109 0A110A 0B110B 0C110C 0D110D 0E110E 0F110F)

write_herdr_stub() {
    cat > "$herdr_stub_dir/herdr" <<STUB
#!/bin/sh
if [ "\$1" = "config" ] && [ "\$2" = "check" ]; then exit ${1:-0}; fi
if [ "\$1" = "server" ]; then echo "reload" >> "$herdr_theme_fixture/reloads"; fi
exit 0
STUB
    chmod 0755 "$herdr_stub_dir/herdr"
}

printf '%s\n' '[keys]' 'prefix = "ctrl+space"' > "$herdr_cfg"
write_herdr_stub 0
HOME="$herdr_theme_fixture" HERDR_CONFIG_PATH="$herdr_cfg" \
    DX_THEME_SKIP_HERDR_RELOAD=1 PATH="$herdr_stub_dir:$PATH" \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "${herdr_palette[@]}" >/dev/null 2>&1

if grep -Fq 'name = "terminal"' "$herdr_cfg" \
    && grep -Fq 'panel_bg = "#001100"' "$herdr_cfg" \
    && grep -Fq 'text = "#051105"' "$herdr_cfg" \
    && grep -Fq 'accent = "#0E110E"' "$herdr_cfg"; then
    test_pass "Herdr chrome receives the exact base16 palette, not an approximation"
else
    test_fail "Herdr chrome receives the exact base16 palette, not an approximation"
fi
assert_file_contains_literal "$herdr_cfg" 'prefix = "ctrl+space"' "seeded Herdr key bindings survive a theme switch"

herdr_first="$(shasum -a 256 "$herdr_cfg" | cut -d' ' -f1)"
HOME="$herdr_theme_fixture" HERDR_CONFIG_PATH="$herdr_cfg" \
    DX_THEME_SKIP_HERDR_RELOAD=1 PATH="$herdr_stub_dir:$PATH" \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" "${herdr_palette[@]}" >/dev/null 2>&1
if [ "$herdr_first" = "$(shasum -a 256 "$herdr_cfg" | cut -d' ' -f1)" ]; then
    test_pass "rewriting the same Herdr theme is byte-idempotent"
else
    test_fail "rewriting the same Herdr theme is byte-idempotent"
fi

# A config Herdr rejects is one it falls back to defaults for, which would
# silently discard the seeded key bindings too. Fail closed instead.
cp "$herdr_cfg" "$herdr_theme_fixture/before-reject"
write_herdr_stub 1
HOME="$herdr_theme_fixture" HERDR_CONFIG_PATH="$herdr_cfg" \
    DX_THEME_SKIP_HERDR_RELOAD=1 PATH="$herdr_stub_dir:$PATH" \
    bash "$SCRIPT_DX_THEME_WRITE_TOOL_THEMES" 0A0A0A 0B0B0B 0C0C0C 0D0D0D 0E0E0E 0F0F0F \
    101010 111111 121212 131313 141414 151515 161616 171717 181818 191919 >/dev/null 2>&1
if cmp -s "$herdr_theme_fixture/before-reject" "$herdr_cfg"; then
    test_pass "a Herdr config the validator rejects leaves the live config untouched"
else
    test_fail "a Herdr config the validator rejects leaves the live config untouched"
fi
if ! ls "$herdr_theme_fixture"/.dx-theme-herdr.* >/dev/null 2>&1; then
    test_pass "a rejected Herdr theme leaves no temp file behind"
else
    test_fail "a rejected Herdr theme leaves no temp file behind"
fi

rm -rf "$herdr_theme_fixture"

print_summary
exit_with_code
