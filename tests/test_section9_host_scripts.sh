#!/bin/bash
# Section 9: Host Script Architecture
# Tests for: set -euo pipefail, configurable constants, idempotence,
# layer separation, error handling, consistent logging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"

test_section "Section 9: Host Script Architecture"

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

# Test: dx-create-container uses configurable constants
DX_CREATE_CONTAINER="$BIN_DIR/dx-create-container"
if grep -q "DX_CONTAINER_NAME\|DX_IMAGE\|DX_SSH_PORT\|DX_SSH_KEY" "$DX_CREATE_CONTAINER"; then
    test_pass "dx-create-container uses environment variables for constants"
else
    test_fail "dx-create-container uses environment variables for constants"
fi

# Test: dx-status uses container list (not ls if unreliable)
DX_STATUS="$BIN_DIR/dx-status"
if grep -q "container list\|container ls" "$DX_STATUS"; then
    test_pass "dx-status uses container list/ls"
else
    test_fail "dx-status uses container list/ls"
fi

# Test: Bash syntax check for all scripts
SYNTAX_FAILED=0
for script in "$BIN_DIR"/dx-*; do
    if [ -f "$script" ]; then
        if ! bash -n "$script" 2>/dev/null; then
            SYNTAX_FAILED=$((SYNTAX_FAILED + 1))
            test_fail "$(basename "$script") passes bash -n syntax check"
        fi
    fi
done
if [ "$SYNTAX_FAILED" -eq 0 ]; then
    test_pass "All scripts pass bash -n syntax check"
fi

# Test: bootstrap.sh also passes syntax check
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash -n syntax check"
else
    test_fail "bootstrap.sh passes bash -n syntax check"
fi

# -----------------------------------------------------------------------------
# dx-ssh assertions
# -----------------------------------------------------------------------------

DX_SSH="$BIN_DIR/dx-ssh"
if grep -q "if.*DX_SSH_KEY\|if.*dx_key" "$DX_SSH" || grep -q "test -f.*DX_SSH_KEY\|\[ -f.*DX_SSH_KEY" "$DX_SSH" || grep -q "\[ ! -f \"\$DX_SSH_KEY\" \]" "$DX_SSH"; then
    test_pass "dx-ssh checks if SSH key file exists"
else
    test_fail "dx-ssh checks if SSH key file exists"
fi

if grep -q "command -v tmux" "$DX_SSH" && grep -q "tmux is not available yet" "$DX_SSH"; then
    test_pass "dx-ssh checks tmux before attaching"
else
    test_fail "dx-ssh checks tmux before attaching"
fi

if grep -q "dx-theme-restore" "$DX_SSH"; then
    test_pass "dx-ssh restores theme before tmux attach"
else
    test_fail "dx-ssh restores theme before tmux attach"
fi

if grep -q '\.nix-profile/bin' "$DX_SSH"; then
    test_pass "dx-ssh adds guest Nix profile to PATH"
else
    test_fail "dx-ssh adds guest Nix profile to PATH"
fi

assert_file_contains "$DX_SSH" "LogLevel=ERROR" "dx-ssh suppresses noisy known-host warnings"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_SSH_CONNECT_TIMEOUT=.*15" "dx-lib exposes 15s SSH connect timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_BOOTSTRAP_WAIT_TIMEOUT=.*30" "dx-lib exposes bootstrap marker wait timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_TIMEOUT=.*600" "dx-lib exposes guest activation timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_ATTEMPTS=.*2" "dx-lib exposes guest activation attempts"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GUEST_ACTIVATION_RETRY_DELAY=.*5" "dx-lib exposes guest activation retry delay"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GIT_MOUNT_SOURCE=.*:-" "dx-lib defaults git mount source to empty"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_GIT_MOUNT_TARGET=.*workspace" "dx-lib exposes git mount target"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_CONTAINER_MEMORY" "dx-lib exposes configurable container memory"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_CONTAINER_CPUS" "dx-lib exposes configurable container CPU count"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_derived_name" "dx-lib provides derived side-container names"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_require_non_reserved_container_name" "dx-lib reserves dx-host centrally"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_port_in_use" "dx-lib provides a loopback port probe"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_get_host_timezone" "dx-lib centralizes host timezone detection"
assert_file_contains "$BIN_DIR/dx-lib.sh" "defaulting guest timezone to UTC" "dx-lib defaults timezone detection to UTC instead of empty"
assert_file_contains "$DX_CREATE_CONTAINER" "HOST_TZ=\"UTC\"" "dx-create-container guards against an empty host timezone"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_TIMEOUT" "dx-create-container passes activation timeout into the guest"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_ATTEMPTS" "dx-create-container passes activation attempts into the guest"
assert_file_contains "$DX_CREATE_CONTAINER" "DX_GUEST_ACTIVATION_RETRY_DELAY" "dx-create-container passes activation retry delay into the guest"
HOST_TZ_PROBE="$(dx_get_host_timezone 2>/dev/null || true)"
if [ -n "$HOST_TZ_PROBE" ]; then
    test_pass "dx_get_host_timezone returns a non-empty timezone"
else
    test_fail "dx_get_host_timezone returns a non-empty timezone"
fi
assert_file_contains "$DX_SSH" "ConnectTimeout=\$DX_SSH_CONNECT_TIMEOUT" "dx-ssh uses a bounded connect timeout"
assert_file_contains "$DX_SSH" "DX_GUEST_WORKDIR" "dx-ssh supports optional profile workdir"

DX_WAIT_SSH="$BIN_DIR/dx-wait-ssh"
assert_file_contains "$DX_WAIT_SSH" "container_is_running" "dx-wait-ssh detects bootstrap container exits"
assert_file_contains "$DX_WAIT_SSH" "Last 80 container log lines" "dx-wait-ssh prints recent container logs on SSH wait failure"

if grep -q "base64 -d | bash -l" "$DX_SSH"; then
    test_pass "dx-ssh wraps non-interactive commands for bash"
else
    test_fail "dx-ssh wraps non-interactive commands for bash"
fi

# Test: dx-ai is a guest command, not a host wrapper
assert_file_not_exists "$BIN_DIR/dx-ai" "dx-ai is not installed as a host script"

# -----------------------------------------------------------------------------
# dx-put / dx-sync-bootstrap
# -----------------------------------------------------------------------------

DX_PUT="$BIN_DIR/dx-put"
if grep -q "if.*-z.*SOURCE\|if.*!\$.*1" "$DX_PUT"; then
    test_pass "dx-put handles missing arguments"
else
    test_fail "dx-put handles missing arguments"
fi

DX_SYNC_BOOTSTRAP="$BIN_DIR/dx-sync-bootstrap"
assert_file_exists "$DX_SYNC_BOOTSTRAP" "dx-sync-bootstrap exists"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_SOURCE" "dx-sync-bootstrap reads from configurable source"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_PATH" "dx-sync-bootstrap writes to configurable guest path"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-ready" "dx-sync-bootstrap marks payload ready after copy"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "Unsafe DX_BOOTSTRAP_PATH" "dx-sync-bootstrap rejects unsafe guest paths"
assert_file_contains "$DX_SYNC_BOOTSTRAP" ".dx-bootstrap-waiting" "dx-sync-bootstrap waits for guest readiness marker"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "never became ready" "dx-sync-bootstrap exits with error if container entrypoint never becomes ready"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "container logs" "dx-sync-bootstrap points to container logs when entrypoint readiness times out"
assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_WAIT_FOR_GUEST" "dx-sync-bootstrap self-detects wait state without env-var coupling"
assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "find \"\$dest\"" "dx-sync-bootstrap avoids nonessential guest dependencies"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "COPYFILE_DISABLE=1" "dx-sync-bootstrap suppresses macOS tar metadata"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "no-xattrs" "dx-sync-bootstrap omits tar xattrs"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "tar_create_args" "dx-sync-bootstrap probes optional tar flags"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "chmod -R a+rX" "dx-sync-bootstrap normalizes payload permissions"
assert_file_contains "$DX_SYNC_BOOTSTRAP" "id -u dx" "dx-sync-bootstrap chowns payload when dx exists"

# -----------------------------------------------------------------------------
# dx-reclaim
# -----------------------------------------------------------------------------

DX_RECLAIM="$BIN_DIR/dx-reclaim"
assert_file_exists "$DX_RECLAIM" "dx-reclaim exists"
assert_file_contains "$DX_RECLAIM" "source \"\$SCRIPT_DIR/dx-lib.sh\"" "dx-reclaim uses shared script library"
assert_file_contains "$DX_RECLAIM" "container_is_running \"\$DX_CONTAINER_NAME\"" "dx-reclaim requires the configured container to be running"
assert_file_contains "$DX_RECLAIM" "DX_CONTAINER_VOLUME_DIR" "dx-reclaim uses configurable host volume directory"
assert_file_contains "$DX_RECLAIM" "DX_NIX_VOLUME" "dx-reclaim uses configured Nix volume name"
assert_file_contains "$DX_RECLAIM" "DX_PERSIST_VOLUME" "dx-reclaim uses configured persist volume name"
assert_file_contains "$DX_RECLAIM" "DX_NIX_MOUNT" "dx-reclaim trims the configured Nix mount"
assert_file_contains "$DX_RECLAIM" "trim_mount /persist" "dx-reclaim trims the fixed persist mount"
assert_file_not_contains "$DX_RECLAIM" "DX_PERSIST_PATH" "dx-reclaim does not consume DX_PERSIST_PATH"
assert_file_contains "$DX_RECLAIM" "nix-collect-garbage -d" "dx-reclaim deletes old Nix generations"
assert_file_contains "$DX_RECLAIM" "fstrim -v" "dx-reclaim returns free blocks to sparse host images"
assert_file_contains "$DX_RECLAIM" "du -sh" "dx-reclaim reports host sparse image usage"

# -----------------------------------------------------------------------------
# Layer model: every layer has a create/destroy pair, every create is idempotent
# -----------------------------------------------------------------------------

# Layer 1: keys
assert_file_exists "$BIN_DIR/dx-create-keys" "dx-create-keys exists"
assert_file_exists "$BIN_DIR/dx-destroy-keys" "dx-destroy-keys exists"
assert_file_contains "$BIN_DIR/dx-create-keys" "already exists; skipping" "dx-create-keys is idempotent"

# Layer 2: volumes
assert_file_exists "$BIN_DIR/dx-create-volumes" "dx-create-volumes exists"
assert_file_exists "$BIN_DIR/dx-destroy-volumes" "dx-destroy-volumes exists"
assert_file_contains "$BIN_DIR/dx-create-volumes" "container_ensure_volume" "dx-create-volumes uses idempotent volume ensure helper"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "Type \"destroy\" to confirm" "dx-destroy-volumes prompts for typed confirmation"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "force" "dx-destroy-volumes accepts --force to skip prompt"
assert_file_contains "$BIN_DIR/dx-destroy-volumes" "stdin is not a tty" "dx-destroy-volumes refuses non-interactive runs without --force"

# Layer 3: image
assert_file_exists "$BIN_DIR/dx-create-image" "dx-create-image exists"
assert_file_exists "$BIN_DIR/dx-destroy-image" "dx-destroy-image exists"
assert_file_contains "$BIN_DIR/dx-create-image" "container_image_exists" "dx-create-image is idempotent"
assert_file_contains "$BIN_DIR/dx-create-image" "already exists; skipping" "dx-create-image announces skip"

# Layer 4: container
assert_file_exists "$BIN_DIR/dx-create-container" "dx-create-container exists"
assert_file_exists "$BIN_DIR/dx-destroy-container" "dx-destroy-container exists"
assert_file_contains "$BIN_DIR/dx-create-container" "container_exists" "dx-create-container is idempotent"
assert_file_contains "$BIN_DIR/dx-create-container" "already exists; skipping" "dx-create-container announces skip"
assert_file_contains "$BIN_DIR/dx-create-container" "entrypoint sh" "dx-create-container sets a shell entrypoint"
assert_file_contains "$BIN_DIR/dx-create-container" "dx_bootstrap_launch_command" "dx-create-container uses shared bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_GIT_MOUNT_SOURCE" "dx-create-container supports explicit git mount source"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_GIT_MOUNT_TARGET" "dx-create-container mounts git source at configurable target"
assert_file_contains "$BIN_DIR/dx-create-container" "refusing to bind-mount.*dx-host" "dx-create-container refuses host mounts on dx-host"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_CONTAINER_MEMORY" "dx-create-container uses configurable memory"
assert_file_contains "$BIN_DIR/dx-create-container" "DX_CONTAINER_CPUS" "dx-create-container uses configurable CPU count"

DX_MOUNT="$BIN_DIR/dx-mount"
assert_file_exists "$DX_MOUNT" "dx-mount side-container wrapper exists"
assert_file_contains "$DX_MOUNT" "dx_derived_name \"dx-mount-\"" "dx-mount derives typed side-container names"
assert_file_contains "$DX_MOUNT" "dx_require_non_reserved_container_name" "dx-mount refuses reserved dx-host name"
assert_file_contains "$DX_MOUNT" "DX_GIT_MOUNT_SOURCE" "dx-mount exports git mount source"
assert_file_contains "$DX_MOUNT" "DX_NIX_VOLUME=\"\$DX_CONTAINER_NAME-nix\"" "dx-mount defaults to private Nix volume"
assert_file_contains "$DX_MOUNT" "DX_PERSIST_VOLUME=\"\$DX_CONTAINER_NAME-persist\"" "dx-mount defaults to private persist volume"
assert_file_contains "$DX_MOUNT" "DX_BOOTSTRAP_VOLUME=\"\$DX_CONTAINER_NAME-bootstrap\"" "dx-mount defaults to private bootstrap volume"
assert_file_contains "$DX_MOUNT" "dx_derived_port" "dx-mount derives a non-default SSH port"
assert_file_contains "$DX_MOUNT" "print_env" "dx-mount has non-destructive environment inspection"
assert_file_contains "$DX_MOUNT" "dx-destroy-container" "dx-mount destroy removes the side container"
assert_file_contains "$DX_MOUNT" "dx-destroy-volumes.*--force" "dx-mount destroy removes private side volumes"
assert_file_contains "$DX_MOUNT" "dx-destroy-keys" "dx-mount destroy removes private side keypair"
assert_file_not_contains "$DX_MOUNT" "dx-destroy-image" "dx-mount destroy does not remove the shared image"

# Layer 5: runtime state
assert_file_exists "$BIN_DIR/dx-start-container" "dx-start-container exists"
assert_file_exists "$BIN_DIR/dx-stop-container" "dx-stop-container exists"
assert_file_contains "$BIN_DIR/dx-start-container" "already running; skipping" "dx-start-container is idempotent"
assert_file_contains "$BIN_DIR/dx-start-container" "dx-sync-bootstrap" "dx-start-container syncs bootstrap payload after ensuring runtime state"
assert_file_contains "$BIN_DIR/dx-stop-container" "container_stop_bounded" "dx-stop-container uses bounded stop helper"

# -----------------------------------------------------------------------------
# dx-destroy-container: bounded stop with force fallback
# -----------------------------------------------------------------------------

DX_DESTROY_CONTAINER="$BIN_DIR/dx-destroy-container"
assert_file_contains "$BIN_DIR/dx-lib.sh" "DX_STOP_COMMAND_TIMEOUT" "dx-lib exposes stop command timeout"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_stop_bounded" "dx-lib provides bounded container stop helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container kill" "dx-lib escalates stuck stops through container kill"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_runtime_pids" "dx-lib can find the host runtime process for one container"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_kill_runtime_process" "dx-lib has a targeted runtime-process fallback"
# Observed on Apple Container 0.12.0:
# container-runtime-linux start --root .../containers/dx-host --uuid dx-host
assert_file_contains "$BIN_DIR/dx-lib.sh" "index(\$0, \"--uuid \" name)" "dx-lib searches the observed runtime --uuid container-name signature"
assert_file_contains "$BIN_DIR/dx-lib.sh" "searched: ps -axo pid=,command=" "dx-lib logs the runtime-process search when no PID is found"
assert_file_contains "$DX_DESTROY_CONTAINER" "container_stop_bounded" "dx-destroy-container uses bounded stop helper"
assert_file_contains "$DX_DESTROY_CONTAINER" "container delete --force" "dx-destroy-container force-deletes when stop cannot complete"

# -----------------------------------------------------------------------------
# Wrappers: pure orchestration only
# -----------------------------------------------------------------------------

DX="$BIN_DIR/dx"
DX_DESTROY="$BIN_DIR/dx-destroy"
DX_RECREATE="$BIN_DIR/dx-recreate"
DX_FACTORY_RESET="$BIN_DIR/dx-factory-reset"

# dx calls every lifecycle script in order; idempotence makes it safe from any state
assert_file_contains "$DX" "dx-create-keys" "dx calls dx-create-keys"
assert_file_contains "$DX" "dx-create-image" "dx calls dx-create-image (builds image on first run)"
assert_file_contains "$DX" "dx-create-volumes" "dx calls dx-create-volumes"
assert_file_contains "$DX" "dx-create-container" "dx calls dx-create-container"
assert_file_contains "$DX" "dx-start-container" "dx calls dx-start-container"
assert_file_not_contains "$DX" "dx-sync-bootstrap" "dx delegates bootstrap sync to dx-start-container"
assert_file_contains "$DX" "dx-wait-ssh" "dx waits for SSH"
assert_file_contains "$DX" "dx-ssh" "dx connects via dx-ssh"
assert_file_not_contains "$DX" "container_is_running" "dx does not branch on container state itself"
assert_file_not_contains "$DX" "container_exists" "dx does not branch on container existence itself"

# dx-destroy umbrella
assert_file_exists "$DX_DESTROY" "dx-destroy umbrella exists"
assert_file_contains "$DX_DESTROY" "dx-destroy-container" "dx-destroy removes the container"
assert_file_contains "$DX_DESTROY" "dx-destroy-image" "dx-destroy removes the image"
assert_file_not_contains "$DX_DESTROY" "dx-destroy-volumes" "dx-destroy does NOT touch volumes"
assert_file_not_contains "$DX_DESTROY" "dx-destroy-keys" "dx-destroy does NOT touch keys"

# dx-recreate delegates to dx
assert_file_contains "$DX_RECREATE" 'exec "$SCRIPT_DIR/dx"' "dx-recreate delegates to the standard dx entrypoint"
assert_file_contains "$DX_RECREATE" "dx-destroy" "dx-recreate uses the dx-destroy umbrella"
assert_file_not_contains "$DX_RECREATE" "dx-destroy-volumes" "dx-recreate preserves volumes"
assert_file_not_contains "$DX_RECREATE" "dx-destroy-keys" "dx-recreate preserves keys"

# dx-factory-reset destroys every layer behind a confirmation prompt
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-container" "dx-factory-reset destroys the container"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-image" "dx-factory-reset destroys the image"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-volumes" "dx-factory-reset destroys the volumes"
assert_file_contains "$DX_FACTORY_RESET" "dx-destroy-keys" "dx-factory-reset destroys the keys"
assert_file_contains "$DX_FACTORY_RESET" 'dx-destroy-volumes" --force' "dx-factory-reset passes --force to dx-destroy-volumes to avoid double-prompting"
assert_file_contains "$DX_FACTORY_RESET" "factory-reset" "dx-factory-reset requires typed confirmation"

# -----------------------------------------------------------------------------
# Logging style: no Phase labels survive in the host scripts
# -----------------------------------------------------------------------------

for script in "$BIN_DIR"/dx*; do
    if [ -f "$script" ] && [ "$(basename "$script")" != "dx-lib.sh" ]; then
        if grep -qE "Phase [0-9]" "$script"; then
            test_fail "$(basename "$script") no longer prints Phase N labels"
        fi
    fi
done
test_pass "no host script prints Phase N labels"

# -----------------------------------------------------------------------------
# dx-wait-ssh
# -----------------------------------------------------------------------------

DX_WAIT_SSH="$BIN_DIR/dx-wait-ssh"
assert_file_contains "$DX_WAIT_SSH" "bash -lc 'true'" "dx-wait-ssh avoids nushell printing boolean true"
assert_file_contains "$DX_WAIT_SSH" "Waiting for guest SSH" "dx-wait-ssh announces what it is waiting for"
assert_file_contains "$DX_WAIT_SSH" "Guest is ready" "dx-wait-ssh announces readiness"

# -----------------------------------------------------------------------------
# dx-lib
# -----------------------------------------------------------------------------

assert_file_contains "$BIN_DIR/dx-lib.sh" "command -v container" "dx-lib checks for Apple Container installation"
assert_file_contains "$BIN_DIR/dx-lib.sh" "Apple 'container' command not found" "dx-lib install error names the missing command clearly"
assert_file_contains "$BIN_DIR/dx-lib.sh" "github.com/apple/container" "dx-lib install error points to the official install source"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_system_is_running" "dx-lib exposes container_system_is_running helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container_system_ensure_started" "dx-lib exposes container_system_ensure_started helper"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container system status" "dx-lib queries container system status to detect started state"
assert_file_contains "$BIN_DIR/dx-lib.sh" "container system start" "dx-lib starts the container system when it is not running"
assert_file_contains "$BIN_DIR/dx-lib.sh" "dx_bootstrap_launch_command" "dx-lib owns bootstrap launch command"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-waiting" "dx-lib installs bootstrap wait marker"
assert_file_contains "$BIN_DIR/dx-lib.sh" ".dx-bootstrap-ready" "dx-lib waits for bootstrap ready marker"

assert_file_contains "$DX" "container_system_ensure_started" "dx ensures the container system is started before lifecycle steps"

print_summary
exit_with_code
