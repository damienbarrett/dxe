#!/bin/bash
# tier: unit
# bash32: no
# Section 13: Final Review
# Tests for: all final checks before completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 13: Final Review"

# Test: no private keys are tracked
if git -C "$BASE_DIR" ls-files | stdin_matches "dx_key\|private.*key\|id_rsa\|id_ed25519"; then
    test_fail "no private keys are tracked by git"
else
    test_pass "no private keys are tracked by git"
fi

# Test: no .DS_Store files are tracked
if git -C "$BASE_DIR" ls-files | stdin_matches "\.DS_Store"; then
    test_fail "no .DS_Store files are tracked by git"
else
    test_pass "no .DS_Store files are tracked by git"
fi

# Test: flake.lock exists and is not ignored
if [ -f "$FLAKE_LOCK" ] && ! git -C "$BASE_DIR" check-ignore -q "$FLAKE_LOCK"; then
    test_pass "flake.lock is present and not ignored"
else
    test_fail "flake.lock is present and not ignored"
fi

# Test: nvim/ lazy.nvim runtime config removed or quarantined
if git -C "$BASE_DIR" ls-files | stdin_matches "nvim/lua/core/lazy.lua\|nvim/lazy-lock.json"; then
    test_fail "nvim/ lazy.nvim runtime config removed or quarantined"
else
    test_pass "nvim/ lazy.nvim runtime config removed or quarantined"
fi

# Test: Containerfile does not install tools
assert_file_not_contains "$CONTAINERFILE" "RUN nix profile install" "Containerfile does not install tools"

# Fable D7 item 6: SSH-is-key-only and passwordless-sudo used to be
# re-asserted here as four literal greps of bootstrap/system.sh, byte-for-
# byte duplicating tests/test_section4_ssh.sh's own checks of the same
# settings. Section 4 now proves the sshd_config settings behaviourally
# (rendering configure_ssh's real heredoc through the installed `sshd -T`
# parser) and still keeps the passwordless-sudo literal check, so this
# duplicate is deleted rather than converted a second time; see
# tests/test_section4_ssh.sh for the one remaining copy of each.

print_summary
exit_with_code
