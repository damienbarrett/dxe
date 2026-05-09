#!/bin/bash
# Section 9: Improve Host Scripts
# Tests for: set -euo pipefail, configurable constants, no-op behavior, error handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"

test_section "Section 9: Improve Host Scripts"

# Test: All scripts have set -euo pipefail
for script in "$BIN_DIR"/dx-*; do
    if [ -f "$script" ]; then
        script_name=$(basename "$script")
        if grep -q "set -euo pipefail" "$script"; then
            test_pass "$script_name has set -euo pipefail"
        else
            test_fail "$script_name has set -euo pipefail"
        fi
    fi
done

# Test: Scripts use environment variables for constants
# Check if DX_CONTAINER_NAME, DX_IMAGE, etc. are used
DX_CREATE="$BIN_DIR/dx-create"
if grep -q "DX_CONTAINER_NAME\|DX_IMAGE\|DX_SSH_PORT\|DX_SSH_KEY" "$DX_CREATE"; then
    test_pass "dx-create uses environment variables for constants"
else
    test_fail "dx-create uses environment variables for constants"
fi

# Test: dx-status uses container list (not ls if unreliable)
DX_STATUS="$BIN_DIR/dx-status"
if grep -q "container list\|container ls" "$DX_STATUS"; then
    test_pass "dx-status uses container list/ls"
else
    test_fail "dx-status uses container list/ls"
fi

# Test: Bash syntax check for all scripts
SYNTAX_PASSED=0
SYNTAX_FAILED=0
for script in "$BIN_DIR"/dx-*; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            ((SYNTAX_PASSED++))
        else
            ((SYNTAX_FAILED++))
            test_fail "$(basename "$script") passes bash -n syntax check"
        fi
    fi
done
if [ $SYNTAX_FAILED -eq 0 ]; then
    test_pass "All scripts pass bash -n syntax check"
fi

# Test: bootstrap.sh also passes syntax check
BOOTSTRAP="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh"
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash -n syntax check"
else
    test_fail "bootstrap.sh passes bash -n syntax check"
fi

# Test: dx-ssh fails clearly if SSH key does not exist
DX_SSH="$BIN_DIR/dx-ssh"
if grep -q "if.*DX_SSH_KEY\|if.*dx_key" "$DX_SSH" || grep -q "test -f.*DX_SSH_KEY\|\[ -f.*DX_SSH_KEY" "$DX_SSH" || grep -q "\[ ! -f \"\$DX_SSH_KEY\" \]" "$DX_SSH"; then
    test_pass "dx-ssh checks if SSH key file exists"
else
    test_fail "dx-ssh checks if SSH key file exists"
fi

# Test: dx-ssh checks tmux availability before interactive attach
if grep -q "command -v tmux" "$DX_SSH" && grep -q "tmux is not available yet" "$DX_SSH"; then
    test_pass "dx-ssh checks tmux before attaching"
else
    test_fail "dx-ssh checks tmux before attaching"
fi

# Test: dx-ssh restores the selected Tinty theme before interactive tmux attach
if grep -q "dx-theme-restore" "$DX_SSH"; then
    test_pass "dx-ssh restores theme before tmux attach"
else
    test_fail "dx-ssh restores theme before tmux attach"
fi

# Test: dx-ssh exposes the guest Nix profile path for non-interactive SSH commands
if grep -q '\.nix-profile/bin' "$DX_SSH"; then
    test_pass "dx-ssh adds guest Nix profile to PATH"
else
    test_fail "dx-ssh adds guest Nix profile to PATH"
fi

# Test: dx-ssh forces non-interactive commands through bash even when the guest login shell differs
if grep -q "base64 -d | bash -l" "$DX_SSH"; then
    test_pass "dx-ssh wraps non-interactive commands for bash"
else
    test_fail "dx-ssh wraps non-interactive commands for bash"
fi

# Test: dx-ai is a guest command installed through Home Manager, not a host wrapper
assert_file_not_exists "$BIN_DIR/dx-ai" "dx-ai is not installed as a host script"

# Test: dx-put handles missing arguments
DX_PUT="$BIN_DIR/dx-put"
if grep -q "if.*-z.*SOURCE\|if.*!\$.*1" "$DX_PUT"; then
    test_pass "dx-put handles missing arguments"
else
    test_fail "dx-put handles missing arguments"
fi

# Test: dx-sync-bootstrap copies the bootstrap payload after container creation
DX_SYNC_BOOTSTRAP="$BIN_DIR/dx-sync-bootstrap"
assert_file_exists "$DX_SYNC_BOOTSTRAP" "dx-sync-bootstrap exists"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_SOURCE" "dx-sync-bootstrap reads from configurable source"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_PATH" "dx-sync-bootstrap writes to configurable guest path"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-ready" "dx-sync-bootstrap marks payload ready after copy"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "unsafe DX_BOOTSTRAP_PATH" "dx-sync-bootstrap rejects unsafe guest paths"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-waiting" "dx-sync-bootstrap can wait for guest readiness marker"
assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "find \"\$dest\"" "dx-sync-bootstrap avoids nonessential guest dependencies"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "COPYFILE_DISABLE=1" "dx-sync-bootstrap suppresses macOS tar metadata"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "no-xattrs" "dx-sync-bootstrap omits tar xattrs"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "tar_create_args" "dx-sync-bootstrap probes optional tar flags"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "chmod -R a+rX" "dx-sync-bootstrap normalizes payload permissions"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "id -u dx" "dx-sync-bootstrap chowns payload when dx exists"

# Test: dx-start syncs bootstrap payload after starting the container
DX_START="$BIN_DIR/dx-start"
assert_file_contains "$DX_START" "dx-sync-bootstrap" "dx-start syncs bootstrap payload after start"
assert_file_contains "$DX_START" "already running.*syncing bootstrap payload" "dx-start syncs bootstrap payload when already running"

# Test: dx entrypoint syncs bootstrap payload even when the container is already running
DX="$BIN_DIR/dx"
assert_file_contains "$DX" "dx-sync-bootstrap" "dx syncs bootstrap payload for already-running containers"

# Test: dx entrypoint checks for Apple Container installation
assert_file_contains "$DX" "command -v container" "dx checks for Apple Container installation"

# Test: dx-create owns the runtime bootstrap launcher, keeping Containerfile minimal
assert_file_contains "$DX_CREATE" "entrypoint sh" "dx-create sets a shell entrypoint"
assert_file_contains "$DX_CREATE" "dx_bootstrap_launch_command" "dx-create uses shared bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_bootstrap_launch_command" "dx-lib owns bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-waiting" "dx-lib installs bootstrap wait command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-ready" "dx-lib waits for bootstrap ready marker"

print_summary
exit_with_code
