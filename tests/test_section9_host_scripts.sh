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

assert_file_contains "$DX_SSH" "LogLevel=ERROR" "dx-ssh suppresses noisy known-host warnings"

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
assert_file_contains "$DX_START" "Starting DX container: .*\\.\\.\\." "dx-start feedback ends with ellipsis"

# Test: dx-wait-ssh checks readiness through bash, regardless of login shell
DX_WAIT_SSH="$BIN_DIR/dx-wait-ssh"
assert_file_contains "$DX_WAIT_SSH" "bash -lc 'true'" "dx-wait-ssh avoids nushell printing boolean true"
assert_file_contains "$DX_WAIT_SSH" "Phase 4: Waiting for guest environment to be ready\\.\\.\\." "dx-wait-ssh prints phase 4 with ellipsis"
assert_file_contains "$DX_WAIT_SSH" "Guest is ready\\.\\.\\." "dx-wait-ssh readiness feedback ends with ellipsis"

# Test: stop/destroy lifecycle commands are bounded and have a force fallback
DX_STOP="$BIN_DIR/dx-stop"
DX_DESTROY="$BIN_DIR/dx-destroy"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_STOP_COMMAND_TIMEOUT" "dx-lib exposes stop command timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_stop_bounded" "dx-lib provides bounded container stop helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container kill" "dx-lib escalates stuck stops through container kill"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_runtime_pids" "dx-lib can find the host runtime process for one container"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_kill_runtime_process" "dx-lib has a targeted runtime-process fallback"
assert_file_contains "$DX_STOP" "container_stop_bounded" "dx-stop uses bounded stop helper"
assert_file_contains "$DX_DESTROY" "container_stop_bounded" "dx-destroy uses bounded stop helper"
assert_file_contains "$DX_DESTROY" "container delete --force" "dx-destroy force deletes when stop cannot complete"

# Test: dx entrypoint is state-driven but never builds images
DX="$BIN_DIR/dx"
DX_INIT_KEYS="$BIN_DIR/dx-init-keys"
assert_file_contains "$DX" "dx-start" "dx calls dx-start"
assert_file_contains "$DX" "container_is_running" "dx handles already-running containers"
assert_file_contains "$DX" "container_exists" "dx handles stopped existing containers"
assert_file_contains "$DX" "container_image_exists" "dx checks for a prebuilt image before creating a missing container"
assert_file_not_contains "$DX" "dx-build" "dx never builds the image"
assert_file_contains "$DX" "dx-sync-bootstrap" "dx syncs bootstrap directly for already-running containers"
assert_file_contains "$DX" "Run ./bin/dx-recreate" "dx tells the user how to build a missing image"
assert_file_contains "$DX_INIT_KEYS" "Phase 0: SSH keys already exist\\.\\.\\." "dx-init-keys prints phase 0 with ellipsis"
assert_file_contains "$DX" "Phase 1: Checking prebuilt image" "dx prints phase 1 feedback"
assert_file_contains "$DX" "Phase 1: Checking prebuilt image .*\\.\\.\\." "dx phase 1 feedback ends with ellipsis"
assert_file_contains "$DX" "Phase 2: Resolving container .*\\.\\.\\." "dx phase 2 feedback ends with ellipsis"
assert_file_contains "$DX" "Phase 3: Preparing running container\\.\\.\\." "dx phase 3 feedback ends with ellipsis"
assert_file_contains "$DX" "Phase 5: Entering developer environment\\.\\.\\." "dx phase 5 feedback ends with ellipsis"

# Test: bootstrap sync feedback follows lifecycle output style
assert_file_contains "$DX_SYNC_BOOTSTRAP" "Syncing bootstrap payload .*\\.\\.\\." "dx-sync-bootstrap sync feedback ends with ellipsis"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "Bootstrap payload is ready\\.\\.\\." "dx-sync-bootstrap ready feedback ends with ellipsis"

# Test: dx-recreate rebuilds the image before replacing the container
DX_RECREATE="$BIN_DIR/dx-recreate"
assert_file_not_contains "$DX_RECREATE" 'exec "$SCRIPT_DIR/dx"' "dx-recreate does not delegate to full dx entrypoint"
assert_file_contains "$DX_RECREATE" "dx-build" "dx-recreate rebuilds the image from current configuration"
assert_file_not_contains "$DX_RECREATE" "container_image_exists" "dx-recreate does not skip image builds"
assert_file_contains "$DX_RECREATE" "dx-create" "dx-recreate creates the replacement container"
assert_file_contains "$DX_RECREATE" "dx-start" "dx-recreate starts the replacement container"
assert_file_contains "$DX_RECREATE" "dx-wait-ssh" "dx-recreate waits for SSH after replacement"
assert_file_contains "$DX_RECREATE" "dx-ssh" "dx-recreate connects after replacement"

# Test: dx-lib checks for Apple Container installation
assert_file_contains "$BIN_DIR/dx-lib.sh" "command -v container" "dx-lib checks for Apple Container installation"

# Test: dx-create owns the runtime bootstrap launcher, keeping Containerfile minimal
assert_file_contains "$DX_CREATE" "entrypoint sh" "dx-create sets a shell entrypoint"
assert_file_contains "$DX_CREATE" "dx_bootstrap_launch_command" "dx-create uses shared bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_bootstrap_launch_command" "dx-lib owns bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-waiting" "dx-lib installs bootstrap wait command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-ready" "dx-lib waits for bootstrap ready marker"

print_summary
exit_with_code
