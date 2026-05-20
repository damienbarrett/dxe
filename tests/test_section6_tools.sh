#!/bin/bash
# Section 6: Improve Guest Tooling
# Tests for: diagnostic tools, basic utilities in flake.nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 6: Improve Guest Tooling"

SHELL_NIX="$CONTAINER_DIR/home/shell.nix"
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

# Test: Yazi cwd helpers are configured for interactive container shells
assert_file_contains "$SHELL_NIX" "function y()" "bash yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" "command yazi \"\$@\" --cwd-file=\"\$tmp\"" "bash yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" "function y" "fish yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" "command yazi \$argv --cwd-file=\"\$tmp\"" "fish yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" "def --env y" "nushell yazi cwd helper is configured"
assert_file_contains "$SHELL_NIX" '\^yazi ...$args --cwd-file $tmp' "nushell yazi cwd helper writes cwd file"
assert_file_contains "$SHELL_NIX" 'str replace --all (char nul) ""' "nushell yazi cwd helper strips cwd file NUL terminator"

# Test: AI CLI tools are excluded from the default dxPackages list
if printf '%s\n' "$DX_PACKAGES_BLOCK" | grep -Eq "codex|gemini-cli|claude-code|antigravity"; then
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
if git -C "$BASE_DIR" ls-files --error-unmatch "container/aarch64-darwin-apple-container-dx-nixos-25.11/scripts/dx-ai.sh" >/dev/null 2>&1; then
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

assert_file_not_contains "$DX_AI_SCRIPT" "touch /workspace/home/dx/.claude.json" "guest dx-ai does not create empty Claude JSON config"
assert_file_contains "$DX_AI_SCRIPT" "printf '%s\\\\n' '{}' > /workspace/home/dx/.claude.json" "guest dx-ai initializes empty Claude config as JSON"

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

if printf '%s\n' "$AI_PACKAGES_BLOCK" | grep -Eq "antigravity"; then
    test_pass "antigravity is in aiPackages"
else
    test_fail "antigravity is in aiPackages"
fi

# Test: shell startup guards optional prompt/environment hooks
assert_file_contains "$SHELL_NIX" "command -v direnv" "bash direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "command -v starship" "bash starship hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q direnv" "fish direnv hook is guarded"
assert_file_contains "$SHELL_NIX" "type -q starship" "fish starship hook is guarded"

print_summary
exit_with_code
