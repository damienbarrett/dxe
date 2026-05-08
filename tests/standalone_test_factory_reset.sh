#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test helpers
source "$SCRIPT_DIR/test_helpers.sh"
source "$PROJECT_ROOT/bin/dx-lib.sh"

echo "================================================="
echo "Running Standalone Test: Factory Reset"
echo "================================================="

echo "Step 1: Ensuring environment exists..."
# Start the environment but pass a command so it doesn't open an interactive SSH session
"$PROJECT_ROOT/bin/dx" "echo 'Environment is up'" || exit_with_code 1 "Failed to start environment for test"

# Verify things exist
if ! container_exists "$DX_CONTAINER_NAME"; then
    exit_with_code 1 "Setup failed: container $DX_CONTAINER_NAME does not exist"
fi

echo "Step 2: Running factory reset..."
if ! "$PROJECT_ROOT/bin/dx-factory-reset"; then
   exit_with_code 1 "dx-factory-reset failed to execute"
fi

echo "Step 3: Asserting destruction..."

if container_exists "$DX_CONTAINER_NAME"; then
    exit_with_code 1 "Assert failed: container $DX_CONTAINER_NAME still exists"
fi

if container volume inspect dx-nix >/dev/null 2>&1; then
    exit_with_code 1 "Assert failed: volume dx-nix still exists"
fi

if container volume inspect "$DX_WORKSPACE_VOLUME" >/dev/null 2>&1; then
    exit_with_code 1 "Assert failed: volume $DX_WORKSPACE_VOLUME still exists"
fi

if [ -f "$DX_SSH_KEY" ]; then
    exit_with_code 1 "Assert failed: SSH key $DX_SSH_KEY still exists"
fi

if [ -f "$DX_SSH_KEY_PUB" ]; then
    exit_with_code 1 "Assert failed: SSH public key $DX_SSH_KEY_PUB still exists"
fi

echo "Step 4: Ensuring environment can be rebuilt from scratch..."
"$PROJECT_ROOT/bin/dx" "echo 'Environment successfully rebuilt'" || exit_with_code 1 "Failed to rebuild environment after reset"

echo "================================================="
echo "Factory Reset Test PASSED"
echo "================================================="
