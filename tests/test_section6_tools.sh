#!/bin/bash
# Section 6: Improve Guest Tooling
# Tests for: diagnostic tools, basic utilities in flake.nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 6: Improve Guest Tooling"

TOOLS_NIX="$CONTAINER_DIR/home/tools.nix"
DX_AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"

# Test: flake.nix exists
assert_file_exists "$FLAKE_NIX" "flake.nix exists"

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
if printf '%s\n' "$DX_PACKAGES_BLOCK" | grep -Eq "^[[:space:]]*(pkgs\.)?gh[[:space:]]*$"; then
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
if printf '%s\n' "$DX_PACKAGES_BLOCK" | grep -Eq "codex|gemini-cli|claude-code|antigravity-cli"; then
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
assert_file_contains "$DX_AI_SCRIPT" "sed -i -E" "guest dx-ai rewrites the local agy derivation pin"

assert_file_not_contains "$DX_AI_SCRIPT" "touch /persist/home/dx/.claude.json" "guest dx-ai does not create empty Claude JSON config"
assert_file_contains "$DX_AI_SCRIPT" "printf '%s\\\\n' '{}' > \"\$persist_home/.claude.json\"" "guest dx-ai initializes empty Claude config as JSON"
assert_file_contains_literal "$FLAKE_NIX" 'version = "1.0.5";' "agy derivation is pinned to a version with OAuth persistence fixes"
assert_file_contains_literal "$FLAKE_NIX" "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.5-5009297080451072/linux-arm/cli_linux_arm64.tar.gz" "agy derivation uses the 1.0.5 Linux arm64 tarball"
assert_file_contains_literal "$FLAKE_NIX" "sha512-j5LtbiYWbdq1lbOXXkfpH90cC/c7OTviUodjHMrgcCpjcuvqJej71Jl6v22budIzaIaKW/oMeifL0hEJgcUBmA==" "agy derivation has the expected 1.0.5 SRI hash"
assert_file_not_contains "$FLAKE_NIX" 'version = "1.0.0";' "agy derivation is not pinned to the OAuth persistence bug version"
assert_file_contains_literal "$DX_AI_SCRIPT" '$persist_home/.gemini/antigravity-cli' "guest dx-ai prepares persisted agy state directory"
assert_file_contains "$BOOTSTRAP" "/persist/home/dx/.gemini/antigravity-cli" "bootstrap prepares persisted agy state directory"

if printf '%s\n' "$AI_PACKAGES_BLOCK" | grep -Eq "codex"; then
    test_pass "codex is in aiPackages"
else
    test_fail "codex is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | grep -Eq "gemini-cli"; then
    test_pass "gemini-cli is in aiPackages"
else
    test_fail "gemini-cli is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | grep -Eq "claude-code"; then
    test_pass "claude-code is in aiPackages"
else
    test_fail "claude-code is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | grep -Eq "\bagy\b"; then
    test_pass "agy (Antigravity CLI) is in aiPackages"
else
    test_fail "agy (Antigravity CLI) is in aiPackages"
fi

# Test: shell startup guards optional prompt/environment hooks
assert_file_contains "$SHELL_NIX" "command -v direnv" "bash direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "command -v starship" "bash starship hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q direnv" "fish direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q starship" "fish starship hook is guarded"

assert_file_contains "$SHELL_NIX" "agy = \\\"agy --dangerously-skip-permissions\\\"" "shell.nix configures agy with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "claude = \\\"claude --dangerously-skip-permissions\\\"" "shell.nix configures claude with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "codex = \\\"codex --dangerously-bypass-approvals-and-sandbox\\\"" "shell.nix configures codex with --dangerously-bypass-approvals-and-sandbox"
assert_file_contains "$SHELL_NIX" "gemini = \\\"gemini --yolo\\\"" "shell.nix configures gemini with --yolo"

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
    if printf '%s\n' "$TMUX_PROBE" | grep -q "__PROBE_FAILED__" || [ -z "$TMUX_PROBE" ]; then
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
fi

print_summary
exit_with_code
