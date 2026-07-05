#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/bin/dx-lib.sh"

# --- Destructive test safety guard -----------------------------------------
# Sourcing dx-lib.sh above defaults DX_CONTAINER_NAME/DX_*_VOLUME/DX_SSH_KEY
# to the primary dx-host resources. This script then CREATES that
# environment and irreversibly DESTROYS it via dx-factory-reset --force.
# Running it directly with no guard would wipe the primary /persist volume
# and SSH keys with no confirmation. Mirrors dx-mount's refuse_default_destroy
# and the DX_TEST_DESTRUCTIVE opt-in gating used by test_section11/16.

if [ "${DX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    echo "Skipping standalone factory-reset test: set DX_TEST_DESTRUCTIVE=1 to enable." >&2
    echo "This test creates, then irreversibly destroys, whatever environment" >&2
    echo "DX_CONTAINER_NAME/DX_*_VOLUME/DX_SSH_KEY resolve to. Run it only under an" >&2
    echo "isolated profile, e.g.:" >&2
    echo "  DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test bash tests/standalone_test_factory_reset.sh" >&2
    exit 0
fi

refuse_default_destroy() {
    local var="$1" value="$2" default_value="$3"
    if [ "$value" = "$default_value" ]; then
        echo "Error: refusing to run the factory-reset test against the default $var=$value." >&2
        echo "This test creates, then irreversibly destroys, whatever environment it" >&2
        echo "resolves to; running it against a default/primary resource would wipe" >&2
        echo "the real dx-host environment. Run it under an isolated profile instead," >&2
        echo "e.g.:" >&2
        echo "  DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test bash tests/standalone_test_factory_reset.sh" >&2
        exit 1
    fi
}

refuse_default_destroy DX_CONTAINER_NAME "$DX_CONTAINER_NAME" dx-host
refuse_default_destroy DX_NIX_VOLUME "$DX_NIX_VOLUME" dx-nix
refuse_default_destroy DX_PERSIST_VOLUME "$DX_PERSIST_VOLUME" dx-persist
refuse_default_destroy DX_BOOTSTRAP_VOLUME "$DX_BOOTSTRAP_VOLUME" dx-bootstrap
refuse_default_destroy DX_SSH_KEY "$DX_SSH_KEY" "$PROJECT_ROOT/dx_key"

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
