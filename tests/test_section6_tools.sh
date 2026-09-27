#!/bin/bash
# Section 6: Improve Guest Tooling
# Tests for: diagnostic tools, basic utilities in flake.nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 6: Improve Guest Tooling"

TOOLS_NIX="$CONTAINER_DIR/home/tools.nix"
DX_AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
DX_HERDR_NAV_SCRIPT="$CONTAINER_DIR/scripts/dx-herdr-navigate.sh"

# Test: flake.nix exists
assert_file_exists "$FLAKE_NIX" "flake.nix exists"

# Test: the guest flake must not fetch unpinned mutable URLs -- the
# testImage fixture pulled a GitHub avatar (a URL whose bytes change behind
# the same address) and broke Home Manager evaluation the moment upstream
# re-rendered it. Guard against reintroducing that shape rather than banning
# `fetchurl` outright: agy's derivation above also calls `pkgs.fetchurl`, but
# against a versioned release tarball URL pinned via pins/agy.json, which is
# not a mutable resource. Evaluation (home.file has no test-image.png) and
# the fresh-guest build are the actual behaviour checks; this is a
# source-shape regression guard only.
assert_file_not_contains "$FLAKE_NIX" "avatars.githubusercontent.com" "guest flake does not fetch the mutable GitHub avatar URL"

# Test: nixpkgs-unstable tracks the cached nixpkgs-unstable channel branch, not
# master. Master is ahead of Hydra's binary cache, so an AI-tools refresh
# staged from a master revision can land on packages that are not yet cached
# for the guest's architecture, and Nix silently builds them from source
# instead (found on Branch 6, 2026-09-26: codex-core/codex-tui OOM-killed at
# the profile's default 12 GB). The nixpkgs-unstable branch only advances
# after Hydra has built it, so it is cached on cache.nixos.org for both
# aarch64-linux and x86_64-linux.
assert_file_contains_literal "$FLAKE_NIX" 'nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable"' "nixpkgs-unstable input tracks the cached channel branch, not master"
assert_file_not_contains "$FLAKE_NIX" 'nixpkgs-unstable.url = "github:nixos/nixpkgs/master"' "nixpkgs-unstable input no longer tracks nixpkgs master"

DX_PACKAGES_BLOCK="$(awk '
    /dxPackages =/ { in_block = 1 }
    in_block { print }
    in_block && /^[[:space:]]*\];[[:space:]]*$/ { exit }
' "$FLAKE_NIX")"

# Test: coreutils in flake.nix
assert_file_contains "$FLAKE_NIX" "coreutils" "coreutils in flake.nix"

# Test: gnused in flake.nix
assert_file_contains "$FLAKE_NIX" "gnused" "gnused in flake.nix"

# Test: gnugrep in flake.nix
assert_file_contains "$FLAKE_NIX" "gnugrep" "gnugrep in flake.nix"

# Test: findutils in flake.nix
assert_file_contains "$FLAKE_NIX" "findutils" "findutils in flake.nix"

# Test: procps in flake.nix
assert_file_contains "$FLAKE_NIX" "procps" "procps in flake.nix"

# Test: util-linux in flake.nix
assert_file_contains "$FLAKE_NIX" "util-linux" "util-linux in flake.nix"

# Test: less in flake.nix (optional)
if grep -q "less" "$FLAKE_NIX"; then
    test_pass "less in flake.nix"
else
    test_skip "less not in flake.nix (optional)"
fi

# Test: man-db in flake.nix (optional)
if grep -q "man-db" "$FLAKE_NIX"; then
    test_pass "man-db in flake.nix"
else
    test_skip "man-db not in flake.nix (optional)"
fi

# Test: file in flake.nix (optional)
if grep -q "file" "$FLAKE_NIX"; then
    test_pass "file in flake.nix"
else
    test_skip "file not in flake.nix (optional)"
fi

# Test: existing tools preserved - use regex to match with or without pkgs. prefix
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?git" "git preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "^[[:space:]]*(pkgs\.)?nix[[:space:]]*$" "nix preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?openssh" "openssh preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?tmux" "tmux preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "nixvim" "nixvim preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?ripgrep" "ripgrep preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?fd" "fd preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?curl" "curl preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?jq" "jq preserved in flake.nix"
if printf '%s\n' "$DX_PACKAGES_BLOCK" | stdin_matches -E "^[[:space:]]*(pkgs\.)?gh[[:space:]]*$"; then
    test_pass "GitHub CLI is in default dxPackages"
else
    test_fail "GitHub CLI is in default dxPackages"
fi
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?direnv" "direnv preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?nix-direnv" "nix-direnv preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?just" "just preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?go-task" "go-task preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?lazygit" "lazygit preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?yazi" "yazi preserved in flake.nix"
assert_file_contains "$TOOLS_NIX" "set -g display-panes-time 3000" "tmux display panes timeout is 3s"
# base-index migrated from a raw `set -g base-index 1` string to the typed
# Home Manager option. Runtime behaviour is asserted in the live block below.
assert_file_contains "$TOOLS_NIX" "baseIndex = 1;" "tmux base-index is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" 'keyMode = "vi";' "tmux key mode is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" "set -g status-keys emacs" "tmux keeps emacs status-keys despite vi keyMode"
assert_file_contains "$TOOLS_NIX" "customPaneNavigationAndResize = true;" "tmux pane navigation/resize is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" "disableConfirmationPrompt = true;" "tmux kill-pane/window skip the confirmation prompt via typed option"
assert_file_contains "$TOOLS_NIX" "sensibleOnTop = true;" "tmux loads tmux-sensible defaults beneath the typed options"
assert_file_contains "$TOOLS_NIX" "plugin = resurrect;" "tmux-resurrect is declared as a Home Manager tmux plugin"
assert_file_contains "$TOOLS_NIX" "@resurrect-dir '/persist/home/dx/.local/share/tmux/resurrect'" "tmux-resurrect saves to the persisted directory"
assert_file_contains "$TOOLS_NIX" "plugin = continuum;" "tmux-continuum is declared as a Home Manager tmux plugin"
assert_file_contains "$TOOLS_NIX" "@continuum-restore 'on'" "tmux-continuum restores sessions on server start"
assert_file_contains "$TOOLS_NIX" "@continuum-save-interval" "tmux-continuum auto-saves on an interval"

# vim-tmux-navigator: prefix-less Ctrl-h/j/k/l across tmux panes and nvim splits.
NAV_NVIM_NIX="$CONTAINER_DIR/nvim/plugins/vim-tmux-navigator.nix"
NIXVIM_NIX="$CONTAINER_DIR/nixvim.nix"
assert_file_contains "$TOOLS_NIX" "vim-tmux-navigator" "tmux side of vim-tmux-navigator is declared in tmux plugins"
assert_file_exists "$NAV_NVIM_NIX" "Neovim side of vim-tmux-navigator is a self-contained module"
assert_file_contains "$NAV_NVIM_NIX" "TmuxNavigateLeft" "Neovim navigator maps Ctrl-h to TmuxNavigateLeft"
assert_file_contains "$NIXVIM_NIX" "vim-tmux-navigator.nix" "Neovim navigator module is imported by nixvim"
assert_file_exists "$DX_HERDR_NAV_SCRIPT" "Herdr pane navigator helper exists"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane process-info" "Herdr navigator inspects the foreground pane process"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane send-keys" "Herdr navigator forwards Ctrl navigation into Neovim"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane focus" "Herdr navigator focuses adjacent Herdr panes"
assert_file_contains "$TOOLS_NIX" ".local/bin/dx-herdr-navigate" "Herdr navigator helper is installed by Home Manager"
assert_file_contains "$TOOLS_NIX" "dx-herdr-navigator.lua" "Herdr-aware Neovim edge navigation is installed by Home Manager"
if bash -n "$DX_HERDR_NAV_SCRIPT" 2>/dev/null; then
    test_pass "Herdr navigator helper passes bash syntax check"
else
    test_fail "Herdr navigator helper passes bash syntax check"
fi
assert_file_contains "$CONTAINER_DIR/bootstrap/persistence.sh" "/persist/home/dx/.local/share/tmux/resurrect" "bootstrap creates the persisted resurrect directory"
assert_file_contains "$TOOLS_NIX" "set -g renumber-windows on" "tmux renumbers windows on close"
assert_file_contains "$TOOLS_NIX" "set-option -g main-pane-width 50%" "tmux main pane width is 50 percent"
assert_file_contains "$TOOLS_NIX" 'bind -N "Switch to tiled layout" + select-layout tiled' "tmux prefix plus selects tiled layout"
assert_file_contains "$TOOLS_NIX" 'bind -N "Promote selected pane to main pane" a select-layout main-vertical' "tmux prefix a selects main-vertical layout"
assert_file_contains "$TOOLS_NIX" "display-panes \"swap-pane -s .%% -t .1" "tmux prefix-a shows pane picker that swaps into the main pane"
assert_file_contains_literal "$TOOLS_NIX" \
    'bind -N "Choose window with activity or bell" b choose-tree -Zw -f "#{||:#{window_activity_flag},#{window_bell_flag}}"' \
    "tmux activity picker remains bound on prefix-b"

# Test: Yazi cwd helpers are configured for interactive container shells
assert_file_contains "$SHELL_NIX" "function y()" "bash yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" "command yazi \"\$@\" --cwd-file=\"\$tmp\"" "bash yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" "function y" "fish yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" "command yazi \$argv --cwd-file=\"\$tmp\"" "fish yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" "def --env y" "nushell yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" '\^yazi ...$args --cwd-file $tmp' "nushell yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" 'str replace --all (char nul) ""' "nushell yazi cwd helper strips cwd file NUL terminator"

# Test: AI CLI tools are excluded from the default dxPackages list
if printf '%s\n' "$DX_PACKAGES_BLOCK" | stdin_matches -E "codex|gemini-cli|claude-code|antigravity-cli|opencode"; then
    test_fail "AI CLI tools excluded from default dxPackages"
else
    test_pass "AI CLI tools excluded from default dxPackages"
fi

# Test: AI CLI tools are available through an opt-in package output
AI_PACKAGES_BLOCK="$(awk '
    /aiPackages =/ { in_block = 1 }
    in_block { print }
    in_block && /^[[:space:]]*\];[[:space:]]*$/ { exit }
' "$FLAKE_NIX")"

assert_file_contains "$FLAKE_NIX" "aiPackages =" "aiPackages list exists"
assert_file_contains "$FLAKE_NIX" '"ai-tools"' "ai-tools package output exists"
assert_grep_in_file "$FLAKE_NIX" "paths = aiPackages;" "ai-tools package uses aiPackages"
assert_grep_in_file "$FLAKE_NIX" "aiPackages = with unstable;" "aiPackages use unstable package set"
assert_file_exists "$DX_AI_SCRIPT" "guest dx-ai script exists"
if git -C "$BASE_DIR" ls-files --error-unmatch "${DX_AI_SCRIPT#$BASE_DIR/}" >/dev/null 2>&1; then
    test_pass "guest dx-ai script is tracked for flake source inclusion"
else
    test_fail "guest dx-ai script is tracked for flake source inclusion"
fi
assert_file_contains "$TOOLS_NIX" ".local/bin/dx-ai" "guest dx-ai command is installed by Home Manager"

if bash -n "$DX_AI_SCRIPT" 2>/dev/null; then
    test_pass "guest dx-ai script passes bash syntax check"
else
    test_fail "guest dx-ai script passes bash syntax check"
fi

if grep -q "nix flake update" "$DX_AI_SCRIPT" && grep -q "nixpkgs-unstable" "$DX_AI_SCRIPT"; then
    test_pass "guest dx-ai updates nixpkgs-unstable"
else
    test_fail "guest dx-ai updates nixpkgs-unstable"
fi
assert_file_contains "$DX_AI_SCRIPT" "AGY_MANIFEST_URL=" "guest dx-ai has an agy updater manifest URL"
assert_file_contains "$DX_AI_SCRIPT" "Refreshing Antigravity CLI manifest" "guest dx-ai refreshes the agy manifest before install"
assert_file_contains "$DX_AI_SCRIPT" "nix hash convert --hash-algo sha512 --to sri" "guest dx-ai converts agy manifest hash to Nix SRI"
assert_file_contains_literal "$DX_AI_SCRIPT" "pins/agy.json" "guest dx-ai updates the structured agy pin"
assert_file_not_contains "$DX_AI_SCRIPT" "sed -i" "guest dx-ai does not rewrite Nix source ranges"

assert_file_not_contains "$DX_AI_SCRIPT" "touch /persist/home/dx/.claude.json" "guest dx-ai does not create empty Claude JSON config"
assert_file_contains "$DX_AI_SCRIPT" "printf '%s\\\\n' '{}' > \"\$persist_home/.claude.json\"" "guest dx-ai initializes empty Claude config as JSON"
AGY_PIN="$CONTAINER_DIR/pins/agy.json"
assert_file_contains_literal "$AGY_PIN" '"version": "1.0.5"' "agy pin uses a version with OAuth persistence fixes"
assert_file_contains_literal "$AGY_PIN" "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.5-5009297080451072/linux-arm/cli_linux_arm64.tar.gz" "agy pin uses the 1.0.5 Linux arm64 tarball"
assert_file_contains_literal "$AGY_PIN" "sha512-j5LtbiYWbdq1lbOXXkfpH90cC/c7OTviUodjHMrgcCpjcuvqJej71Jl6v22budIzaIaKW/oMeifL0hEJgcUBmA==" "agy pin has the expected 1.0.5 SRI hash"
assert_file_not_contains "$FLAKE_NIX" 'version = "1.0.0";' "agy derivation is not pinned to the OAuth persistence bug version"
assert_file_contains_literal "$DX_AI_SCRIPT" '$persist_home/.gemini/antigravity-cli' "guest dx-ai prepares persisted agy state directory"
assert_file_contains "$CONTAINER_DIR/bootstrap/activation.sh" "/persist/home/dx/.gemini/antigravity-cli" "bootstrap prepares persisted agy state directory"

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "codex"; then
    test_pass "codex is in aiPackages"
else
    test_fail "codex is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "gemini-cli"; then
    test_pass "gemini-cli is in aiPackages"
else
    test_fail "gemini-cli is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "claude-code"; then
    test_pass "claude-code is in aiPackages"
else
    test_fail "claude-code is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bagy\b"; then
    test_pass "agy (Antigravity CLI) is in aiPackages"
else
    test_fail "agy (Antigravity CLI) is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bherdr\b"; then
    test_pass "herdr is in aiPackages"
else
    test_fail "herdr is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bopencode\b"; then
    test_pass "opencode is in aiPackages"
else
    test_fail "opencode is in aiPackages"
fi

# OpenCode persistence (migration, symlinks, ownership repair) is covered
# behaviorally by Section 17 and the dx-opencode-persistence.sh unit tests in
# test_sourceable_coverage.sh. A literal source-text assertion here would not
# exercise the real behaviour once that logic lives in the shared helper
# (scripts/lib/dx-opencode-persistence.sh) rather than inline in dx-ai.sh and
# activation.sh, so it is intentionally not duplicated as a text check.

# Test: shell startup guards optional prompt/environment hooks
assert_file_contains "$SHELL_NIX" "command -v direnv" "bash direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "command -v starship" "bash starship hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q direnv" "fish direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q starship" "fish starship hook is guarded"

assert_file_contains "$SHELL_NIX" "agy = \\\"agy --dangerously-skip-permissions\\\"" "shell.nix configures agy with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "claude = \\\"claude --dangerously-skip-permissions\\\"" "shell.nix configures claude with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "codex = \\\"codex --dangerously-bypass-approvals-and-sandbox\\\"" "shell.nix configures codex with --dangerously-bypass-approvals-and-sandbox"
assert_file_contains "$SHELL_NIX" "gemini = \\\"gemini --yolo\\\"" "shell.nix configures gemini with --yolo"

# --- Item 3 (fix/test-hardening): tmux_guest_resurrect_probe's live tmux- --
# --- resurrect check was timing-flaky (found on Branch 16's live tier,    -
# --- 2026-09-27, file untouched by that branch): it read @resurrect-dir   -
# --- and the C-s/C-r bindings exactly once, immediately after             -
# --- "new-session -d" returned, trusting that return meant the CONFIG-    -
# --- derived plugin state (tmux-resurrect/continuum, sourced via TPM as  -
# --- part of session start-up) had already settled -- probing server      -
# --- start-up timing rather than a settled state. Fixed in                -
# --- tests/lib/tmux-probes.sh: a bounded poll for all three observable    -
# --- conditions together, the same shape the OTHER probes in that file    -
# --- already use for their own bounded session-start retries. This is a  -
# --- live-tier probe with no real guest here, so the proof is the         -
# --- probe's own unit-level structure: a fake "tmux" on PATH that         -
# --- answers "not yet set/bound" for its first few calls and only the     -
# --- real values from a later call onward (a counter file, the same      -
# --- idiom Section 27's nc_retry uses -- see test_section27_qnap_scripts.sh),
# --- with container_exec_dx_bash temporarily overridden (saved via        -
# --- "declare -f" and restored immediately after, so nothing later in     -
# --- this file or the live block below is affected) to run the probe's   -
# --- own guest-side script body locally instead of through a real         -
# --- container. The coordinating session proves stability across three   -
# --- live dx-test runs afterward (this test cannot: there is no guest    -
# --- here to be flaky against). ---
RESURRECT_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-resurrect-probe.XXXXXX")"
RESURRECT_COUNTER="$RESURRECT_PROBE_DIR/counter"
RESURRECT_SETTLE_AFTER=4
cat > "$RESURRECT_PROBE_DIR/tmux" <<'FAKETMUX'
#!/bin/bash
shift 2 # drop "-L" "<sock>": every call this probe makes has that shape
sub="$1"
case "$sub" in
    kill-server|new-session|set) exit 0 ;;
    show)
        n=0
        [ -f "$DXE_TEST_RESURRECT_COUNTER" ] && n="$(cat "$DXE_TEST_RESURRECT_COUNTER")"
        n=$((n + 1))
        printf "%s" "$n" > "$DXE_TEST_RESURRECT_COUNTER"
        [ "$n" -ge "$DXE_TEST_RESURRECT_SETTLE_AFTER" ] && echo "/persist/home/dx/.local/share/tmux/resurrect"
        exit 0
        ;;
    list-keys)
        n=0
        [ -f "$DXE_TEST_RESURRECT_COUNTER" ] && n="$(cat "$DXE_TEST_RESURRECT_COUNTER")"
        if [ "$n" -ge "$DXE_TEST_RESURRECT_SETTLE_AFTER" ]; then
            printf 'bind-key -T prefix C-s run-shell "resurrect_save.sh"\n'
            printf 'bind-key -T prefix C-r run-shell "resurrect_restore.sh"\n'
        fi
        exit 0
        ;;
esac
exit 0
FAKETMUX
chmod +x "$RESURRECT_PROBE_DIR/tmux"

RESURRECT_ORIG_CONTAINER_EXEC_DX_BASH="$(declare -f container_exec_dx_bash)"
container_exec_dx_bash() {
    DXE_TEST_RESURRECT_COUNTER="$RESURRECT_COUNTER" DXE_TEST_RESURRECT_SETTLE_AFTER="$RESURRECT_SETTLE_AFTER" \
        PATH="$RESURRECT_PROBE_DIR:$PATH" bash -c "$1"
}
RESURRECT_PROBE_OUT="$(tmux_guest_resurrect_probe)"
eval "$RESURRECT_ORIG_CONTAINER_EXEC_DX_BASH"
rm -rf "$RESURRECT_PROBE_DIR"

assert_tmux_runtime "$RESURRECT_PROBE_OUT" resurrect-dir /persist/home/dx/.local/share/tmux/resurrect "tmux resurrect probe polls until @resurrect-dir settles instead of reading it too early"
assert_tmux_runtime "$RESURRECT_PROBE_OUT" save-bound yes "tmux resurrect probe polls until the save binding settles instead of reading it too early"
assert_tmux_runtime "$RESURRECT_PROBE_OUT" restore-bound yes "tmux resurrect probe polls until the restore binding settles instead of reading it too early"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "guest tool live checks skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
else
    for tool_check in \
        "nix --version" \
        "git --version" \
        "gh --version" \
        "tmux -V" \
        "yazi --version" \
        "lazygit --version" \
        "nvim --headless +q"
    do
        if guest_bash "$tool_check >/dev/null"; then
            test_pass "guest tool runs: $tool_check"
        else
            test_fail "guest tool runs: $tool_check"
        fi
    done

    # Behaviour: query the activated tmux config from a throwaway server inside
    # the guest, proving the typed Home Manager options actually take effect at
    # runtime (not merely that strings exist in tools.nix).
    TMUX_PROBE="$(tmux_guest_probe || true)"
    if printf '%s\n' "$TMUX_PROBE" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_PROBE" ]; then
        test_fail "tmux runtime probe started a server in the guest"
    else
        test_pass "tmux runtime probe started a server in the guest"
        assert_tmux_runtime "$TMUX_PROBE" base-index 1 "tmux windows use 1-based indexing"
        assert_tmux_runtime "$TMUX_PROBE" pane-base-index 1 "tmux panes use 1-based indexing"
        assert_tmux_runtime "$TMUX_PROBE" mouse on "tmux mouse mode is enabled"
        assert_tmux_runtime "$TMUX_PROBE" history-limit 50000 "tmux history limit is 50000"
        assert_tmux_runtime "$TMUX_PROBE" escape-time 0 "tmux escape-time is 0"
        assert_tmux_runtime "$TMUX_PROBE" focus-events on "tmux focus-events are enabled"
        assert_tmux_runtime "$TMUX_PROBE" default-terminal tmux-256color "tmux default-terminal is tmux-256color"
        assert_tmux_runtime "$TMUX_PROBE" mode-keys vi "tmux copy mode uses vi keys"
        assert_tmux_runtime "$TMUX_PROBE" status-keys emacs "tmux command prompt keeps emacs editing despite vi keyMode"
        assert_tmux_runtime "$TMUX_PROBE" set-clipboard on "tmux set-clipboard is on for OSC52 copy"
    fi

    # Behaviour: query the live prefix key table and pane-navigation effects.
    TMUX_KEYS="$(tmux_guest_keys_probe || true)"
    if printf '%s\n' "$TMUX_KEYS" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_KEYS" ]; then
        test_fail "tmux key-table probe started a server in the guest"
    else
        test_pass "tmux key-table probe started a server in the guest"
        # hjkl select panes in the right direction and are now repeatable.
        assert_tmux_runtime "$TMUX_KEYS" h.cmd "select-pane -L" "tmux prefix-h selects the left pane"
        assert_tmux_runtime "$TMUX_KEYS" j.cmd "select-pane -D" "tmux prefix-j selects the lower pane"
        assert_tmux_runtime "$TMUX_KEYS" k.cmd "select-pane -U" "tmux prefix-k selects the upper pane"
        assert_tmux_runtime "$TMUX_KEYS" l.cmd "select-pane -R" "tmux prefix-l selects the right pane"
        # The pinned Home Manager customPaneNavigationAndResize emits pane
        # SWITCH binds without -r (non-repeatable) and only the RESIZE binds
        # with -r. That preserves the prior hand-written behaviour, so assert
        # non-repeatable switching deliberately rather than the repeatable
        # switching the plan originally assumed this module would introduce.
        assert_tmux_runtime "$TMUX_KEYS" h.repeat no "tmux prefix-h pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" j.repeat no "tmux prefix-j pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" k.repeat no "tmux prefix-k pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" l.repeat no "tmux prefix-l pane switch is non-repeatable (HM module default)"
        # HJKL resize panes and stay repeatable.
        assert_tmux_runtime_contains "$TMUX_KEYS" H.cmd "resize-pane -L" "tmux prefix-H resizes left"
        assert_tmux_runtime_contains "$TMUX_KEYS" L.cmd "resize-pane -R" "tmux prefix-L resizes right"
        assert_tmux_runtime "$TMUX_KEYS" H.repeat yes "tmux prefix-H resize is repeatable"
        assert_tmux_runtime "$TMUX_KEYS" L.repeat yes "tmux prefix-L resize is repeatable"
        # select-pane direction actually moves the active pane in the guest.
        assert_tmux_runtime "$TMUX_KEYS" pane-after-right 2 "tmux select-pane -R moves to the right pane"
        assert_tmux_runtime "$TMUX_KEYS" pane-after-left 1 "tmux select-pane -L moves to the left pane"
        # reload bind rebinds prefix-r to source the config, and it reloads cleanly.
        assert_tmux_runtime_contains "$TMUX_KEYS" r.cmd "source-file" "tmux prefix-r reloads the config"
        assert_tmux_runtime "$TMUX_KEYS" reload-sources-ok yes "tmux config sources without error"
        # disableConfirmationPrompt: prefix-x kills the pane with no confirm-before wrapper.
        assert_tmux_runtime_contains "$TMUX_KEYS" x.cmd "kill-pane" "tmux prefix-x kills the pane"
        assert_tmux_runtime_not_contains "$TMUX_KEYS" x.cmd "confirm-before" "tmux prefix-x skips the kill confirmation"
    fi

    # Behaviour: tmux-resurrect wiring and a real save/restore round trip.
    TMUX_RSR="$(tmux_guest_resurrect_probe || true)"
    if printf '%s\n' "$TMUX_RSR" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_RSR" ]; then
        test_fail "tmux resurrect probe started a server in the guest"
    else
        test_pass "tmux resurrect probe started a server in the guest"
        assert_tmux_runtime "$TMUX_RSR" dir-exists yes "resurrect save directory exists under /persist"
        assert_tmux_runtime "$TMUX_RSR" dir-writable yes "resurrect save directory is writable by dx"
        assert_tmux_runtime "$TMUX_RSR" resurrect-dir /persist/home/dx/.local/share/tmux/resurrect "resurrect @resurrect-dir points at the persisted path"
        assert_tmux_runtime "$TMUX_RSR" save-bound yes "resurrect save (prefix C-s) is bound"
        assert_tmux_runtime "$TMUX_RSR" restore-bound yes "resurrect restore (prefix C-r) is bound"

        # The full save/restore round trip writes into /persist and restarts
        # tmux servers, so gate it behind DX_TEST_DESTRUCTIVE to keep routine
        # runs side-effect free. Run it with DX_TEST_DESTRUCTIVE=1 (ideally in
        # an isolated profile) to validate end-to-end resurrect behaviour.
        if [ "${DX_TEST_DESTRUCTIVE:-0}" = "1" ]; then
            TMUX_RT="$(tmux_guest_resurrect_roundtrip || true)"
            assert_tmux_runtime "$TMUX_RT" save-file yes "resurrect writes a save file under the persisted dir"
            assert_tmux_runtime "$TMUX_RT" restored yes "resurrect restores a saved session after a server restart"
        else
            test_skip "resurrect save/restore round trip (set DX_TEST_DESTRUCTIVE=1 to run)"
        fi
    fi

    # sensibleOnTop must load beneath the typed options without overriding them.
    # The typed-option runtime values asserted in the first probe block above
    # (escape-time=0, history-limit=50000, default-terminal=tmux-256color,
    # base-index=1) double as the regression check that sensible did not win.

    # Behaviour: vim-tmux-navigator binds Ctrl-h/j/k/l in the tmux root table and
    # maps them in Neovim to the TmuxNavigate commands (seamless cross-nav itself
    # is a manual gate). Reads the live key table and headless nvim maps.
    TMUX_NAV="$(tmux_guest_navigator_probe || true)"
    if printf '%s\n' "$TMUX_NAV" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_NAV" ]; then
        test_fail "tmux navigator probe started a server in the guest"
    else
        test_pass "tmux navigator probe started a server in the guest"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-h yes "tmux root table binds Ctrl-h for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-j yes "tmux root table binds Ctrl-j for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-k yes "tmux root table binds Ctrl-k for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-l yes "tmux root table binds Ctrl-l for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-h yes "Neovim Ctrl-h resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-j yes "Neovim Ctrl-j resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-k yes "Neovim Ctrl-k resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-l yes "Neovim Ctrl-l resolves to TmuxNavigate"
    fi
fi

print_summary
exit_with_code
