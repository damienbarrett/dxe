#!/bin/bash
# Section 13: Final Review
# Tests for: all final checks before completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINERFILE="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/Containerfile"
BOOTSTRAP="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh"

test_section "Section 13: Final Review"

# Test: git status --short shows clean state for tracked files (excluding untracked and README.md)
GIT_STATUS=$(git -C "$BASE_DIR" status -uno --short 2>/dev/null | grep -v "README.md" || echo "")
if [ -z "$GIT_STATUS" ]; then
    test_pass "git working tree is clean for tracked files"
else
    test_fail "git working tree is clean for tracked files (status: $GIT_STATUS)"
fi

# Test: no private keys are tracked
if git -C "$BASE_DIR" ls-files | grep -q "dx_key\|private.*key\|id_rsa\|id_ed25519"; then
    test_fail "no private keys are tracked by git"
else
    test_pass "no private keys are tracked by git"
fi

# Test: no .DS_Store files are tracked
if git -C "$BASE_DIR" ls-files | grep -q "\.DS_Store"; then
    test_fail "no .DS_Store files are tracked by git"
else
    test_pass "no .DS_Store files are tracked by git"
fi

# Test: flake.lock exists and is not ignored
FLAKE_LOCK="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.lock"
if [ -f "$FLAKE_LOCK" ] && ! git -C "$BASE_DIR" check-ignore -q "$FLAKE_LOCK"; then
    test_pass "flake.lock is present and not ignored"
else
    test_fail "flake.lock is present and not ignored"
fi

# Test: nvim/ lazy.nvim runtime config removed or quarantined
if git -C "$BASE_DIR" ls-files | grep -q "nvim/lua/core/lazy.lua\|nvim/lazy-lock.json"; then
    test_fail "nvim/ lazy.nvim runtime config removed or quarantined"
else
    test_pass "nvim/ lazy.nvim runtime config removed or quarantined"
fi

# Test: Containerfile does not install tools
assert_file_not_contains "$CONTAINERFILE" "RUN nix profile install" "Containerfile does not install tools"

# Test: SSH is key-only
assert_file_contains "$BOOTSTRAP" "PubkeyAuthentication yes" "SSH has PubkeyAuthentication yes"
assert_file_contains "$BOOTSTRAP" "PasswordAuthentication no" "SSH has PasswordAuthentication no"
assert_file_contains "$BOOTSTRAP" "PermitEmptyPasswords no" "SSH has PermitEmptyPasswords no"

# Test: passwordless sudo still works for dx
assert_file_contains "$BOOTSTRAP" "dx ALL=(ALL) NOPASSWD:ALL" "passwordless sudo works for dx"

# Test: all completed tasks in todo.txt are marked with - [x]
TODO_FILE="$BASE_DIR/todo.txt"
UNMARKED=0
while IFS= read -r line; do
    if [[ "$line" =~ ^"- \[ \]" ]]; then
        # This is an unmarked checkbox - check if it should be marked
        ((UNMARKED++))
    fi
done < "$TODO_FILE"

if [ $UNMARKED -eq 0 ]; then
    test_pass "all tasks in todo.txt are marked complete"
else
    test_fail "all tasks in todo.txt are marked complete ($UNMARKED unmarked)"
fi

print_summary
exit_with_code
