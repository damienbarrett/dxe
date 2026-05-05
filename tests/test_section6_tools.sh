#!/bin/bash
# Section 6: Improve Guest Tooling
# Tests for: diagnostic tools, basic utilities in flake.nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 6: Improve Guest Tooling"

HOME_NIX="$CONTAINER_DIR/home.nix"

# Test: flake.nix exists
assert_file_exists "$FLAKE_NIX" "flake.nix exists"

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
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?direnv" "direnv preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?nix-direnv" "nix-direnv preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?just" "just preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?go-task" "go-task preserved in flake.nix"
assert_grep_in_file "$FLAKE_NIX" "(pkgs\.)?yazi" "yazi preserved in flake.nix"

# Test: shell startup guards optional prompt/environment hooks
assert_file_contains "$HOME_NIX" "command -v direnv" "bash direnv hook is guarded"
assert_file_contains "$HOME_NIX" "command -v starship" "bash starship hook is guarded"
assert_file_contains "$HOME_NIX" "type -q direnv" "fish direnv hook is guarded"
assert_file_contains "$HOME_NIX" "type -q starship" "fish starship hook is guarded"

print_summary
exit_with_code
