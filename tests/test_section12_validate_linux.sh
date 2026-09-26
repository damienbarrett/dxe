#!/bin/bash
# Section 12: Validate Host-Agnostic Guest Bootstrap
# Tests for: bootstrap.sh works on Linux without Apple container
# These tests are designed to run INSIDE a Linux environment with Nix.
#
# The live tier runs on macOS, so this file used to just skip here and never
# actually execute anywhere (no gate ran it: not the host, which isn't
# Linux; not CI, which is container-free; not the kcov runner, same reason).
# On a non-Linux host with a guest running, it now instead ships a clean
# snapshot of the repository into the guest and relays this same script's
# guest-side run (bin/dx-put + bin/dx-ssh, the way Step 4 validated it by
# hand), reporting the guest's own pass/fail/skip lines plus one host-side
# assertion from its exit status. The in-guest path below (reached directly
# when this already runs with uname -s = Linux, i.e. inside the guest after
# the relay, or on a real Linux CI runner) is unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 12: Validate Host-Agnostic Guest Bootstrap"

assert_profile_command_present() {
    local profile_dir="$1"
    local command_name="$2"
    local message="${3:-$command_name exists in $profile_dir}"

    if [ -x "$profile_dir/bin/$command_name" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_profile_command_absent() {
    local profile_dir="$1"
    local command_name="$2"
    local message="${3:-$command_name is absent from $profile_dir}"

    if [ ! -e "$profile_dir/bin/$command_name" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

# Non-Linux host: relay this same script into a running guest instead of
# skipping outright.
if [ "$(uname -s)" != "Linux" ]; then
    # No guest running: requires_container already records its own SKIP and
    # returns 1 -- keep that as the only outcome, the same shape Section 4's
    # probe now uses.
    if ! requires_container; then
        print_summary
        exit_with_code
    fi

    SNAPSHOT_PARENT="$(mktemp -d -t dxe-section12-snapshot.XXXXXX)"
    SNAPSHOT_DIR="$SNAPSHOT_PARENT/repo"
    mkdir -p "$SNAPSHOT_DIR"
    if git -C "$BASE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$BASE_DIR" archive HEAD | tar -x -C "$SNAPSHOT_DIR"
    else
        # Not a git checkout (shouldn't happen for this repository, but keep
        # the relay working over a plain export too): copy the working tree,
        # excluding VCS metadata and macOS AppleDouble sidecar files.
        (cd "$BASE_DIR" && COPYFILE_DISABLE=1 tar --exclude '._*' --exclude '.git' -cf - .) | tar -x -C "$SNAPSHOT_DIR"
    fi

    REMOTE_PARENT="/tmp/dxe-section12-$$"
    REMOTE_DIR="$REMOTE_PARENT/repo"

    set +e
    GUEST_RC=1
    if "$BASE_DIR/bin/dx-put" "$SNAPSHOT_DIR" "$REMOTE_PARENT/" >/dev/null; then
        GUEST_OUTPUT="$(guest_ssh "cd $REMOTE_DIR && bash tests/test_section12_validate_linux.sh" 2>&1)"
        GUEST_RC=$?
        printf '%s\n' "$GUEST_OUTPUT"
        guest_ssh "rm -rf $REMOTE_PARENT" >/dev/null 2>&1
    else
        echo "  Failed to copy the repository snapshot into the guest (dx-put)." >&2
    fi
    set -e
    rm -rf "$SNAPSHOT_PARENT"

    if [ "$GUEST_RC" -eq 0 ]; then
        test_pass "Section 12 passed inside the guest"
    else
        test_fail "Section 12 passed inside the guest"
    fi

    print_summary
    exit_with_code
fi

# --- Everything below runs INSIDE a Linux guest with Nix (unchanged path,
# reached either directly on a Linux CI runner or by the relay above). ---

# Check if Nix is available
if ! command -v nix >/dev/null 2>&1; then
    test_skip "Nix not available, skipping Section 12 tests"
    exit 0
fi

# Test: bootstrap.sh can be run from Linux
echo "  Testing: bootstrap.sh runs on Linux"
if [ -f "$BOOTSTRAP" ]; then
    # Copy bootstrap to /tmp and run (would need sudo for user creation)
    test_pass "bootstrap.sh exists for Linux validation"
else
    test_fail "bootstrap.sh exists for Linux validation"
fi

# Test: Nix tools install through flake
echo "  Testing: nix profile add from flake"
rm -rf /tmp/test-dx-profile /tmp/test-dx-ai-profile
if nix profile add --profile /tmp/test-dx-profile "$CONTAINER_DIR#default" \
    --extra-experimental-features "nix-command flakes" --accept-flake-config >/dev/null 2>&1; then
    test_pass "Nix tools install through flake"
else
    test_fail "Nix tools install through flake"
fi

# Test: AI CLI tools are not installed in the default profile
assert_profile_command_absent /tmp/test-dx-profile codex "codex absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile gemini "gemini absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile claude "claude absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile agy "agy absent from default profile"
assert_profile_command_absent /tmp/test-dx-profile herdr "herdr absent from default profile"

# Test: AI CLI tools install through the opt-in package output
echo "  Testing: nix profile add from ai-tools output"
if nix profile add --profile /tmp/test-dx-ai-profile "$CONTAINER_DIR#ai-tools" \
    --extra-experimental-features "nix-command flakes" --accept-flake-config >/dev/null 2>&1; then
    test_pass "Nix AI tools install through flake"
else
    test_fail "Nix AI tools install through flake"
fi

assert_profile_command_present /tmp/test-dx-ai-profile codex "codex present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile gemini "gemini present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile claude "claude present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile agy "agy (Antigravity CLI) present in ai-tools profile"
assert_profile_command_present /tmp/test-dx-ai-profile herdr "herdr present in ai-tools profile"

# Test: NixVim launches
echo "  Testing: nvim --headless +q"
if [ -f /tmp/test-dx-profile/bin/nvim ]; then
    if /tmp/test-dx-profile/bin/nvim --headless +q >/dev/null 2>&1; then
        test_pass "NixVim launches with nvim --headless +q"
    else
        test_fail "NixVim launches with nvim --headless +q"
    fi
else
    test_fail "NixVim binary exists after install"
fi

# Bootstrap idempotency (rerun without duplicating shell config/state) is not
# checked here by a source-text heuristic: the previous version of this
# check grepped bootstrap.sh for a pattern from before bootstrap was split
# into modules, so it no longer matched anything meaningful and was failing
# on unmodified `main` (Step 4 finding). Actually rerunning bootstrap twice
# in this fixture would need root/user-creation privileges this environment
# doesn't have. The live tier's own container restart -- Section 11 stopping
# and starting dx-test on its retained volumes, then re-validating -- is a
# real repeat activation of bootstrap against existing state, and is the
# behavioural idempotency evidence for this repository.

# Cleanup
rm -rf /tmp/test-dx-profile /tmp/test-dx-ai-profile

print_summary
exit_with_code
