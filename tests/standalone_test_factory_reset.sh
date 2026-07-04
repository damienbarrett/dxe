#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/bin/dx-lib.sh"

fail() {
    echo "Factory Reset Test FAILED: $*" >&2
    exit 1
}

echo "================================================="
echo "Running Standalone Test: Factory Reset"
echo "================================================="

echo "Step 1: Ensuring environment exists..."
# Start the environment but pass a command so it doesn't open an interactive SSH session
"$PROJECT_ROOT/bin/dx" "echo 'Environment is up'" || fail "failed to start environment for test"

# Verify things exist
if ! container_exists "$DX_CONTAINER_NAME"; then
    fail "setup did not create container $DX_CONTAINER_NAME"
fi

echo "Step 2: Running factory reset..."
if ! "$PROJECT_ROOT/bin/dx-factory-reset" --force; then
   fail "dx-factory-reset failed to execute"
fi

echo "Step 3: Asserting destruction..."

if container_exists "$DX_CONTAINER_NAME"; then
    fail "container $DX_CONTAINER_NAME still exists"
fi

if container_image_exists "$DX_IMAGE"; then
    fail "image $DX_IMAGE still exists"
fi

if container volume inspect "$DX_NIX_VOLUME" >/dev/null 2>&1; then
    fail "volume $DX_NIX_VOLUME still exists"
fi

if container volume inspect "$DX_PERSIST_VOLUME" >/dev/null 2>&1; then
    fail "volume $DX_PERSIST_VOLUME still exists"
fi

if container volume inspect "$DX_BOOTSTRAP_VOLUME" >/dev/null 2>&1; then
    fail "volume $DX_BOOTSTRAP_VOLUME still exists"
fi

if [ -f "$DX_SSH_KEY" ]; then
    fail "SSH key $DX_SSH_KEY still exists"
fi

if [ -f "$DX_SSH_KEY_PUB" ]; then
    fail "SSH public key $DX_SSH_KEY_PUB still exists"
fi

echo "Step 4: Ensuring environment can be rebuilt from scratch..."
"$PROJECT_ROOT/bin/dx" "echo 'Environment successfully rebuilt'" || fail "failed to rebuild environment after reset"

echo "Step 5: Verifying fresh persistent-home ownership..."
"$PROJECT_ROOT/bin/dx-ssh" \
    'probe=/persist/home/.dxe-write-probe-$$; mkdir "$probe" && rmdir "$probe"' \
    || fail "dx cannot create directories under /persist/home after reset"

echo "================================================="
echo "Factory Reset Test PASSED"
echo "================================================="
