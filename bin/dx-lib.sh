#!/bin/bash
set -euo pipefail
# dx-lib.sh
# Shared library for DX Experience scripts

# Locate the project root
export DX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DX_PROJECT_ROOT="$(cd "$DX_LIB_DIR/.." && pwd)"

# Load .env file if it exists
if [ -f "$DX_PROJECT_ROOT/.env" ]; then
    # Load .env file safely ignoring comments
    set -a
    source <(grep -v '^#' "$DX_PROJECT_ROOT/.env" | sed -e '/^$/d')
    set +a
fi

# Set defaults for common variables
export DX_CONTAINER_NAME="${DX_CONTAINER_NAME:-dx-host}"
export DX_IMAGE="${DX_IMAGE:-dx-nixos-25.11}"
export DX_SSH_PORT="${DX_SSH_PORT:-2222}"
export DX_SSH_KEY="${DX_SSH_KEY:-$DX_PROJECT_ROOT/dx_key}"
export DX_SSH_KEY_PUB="${DX_SSH_KEY_PUB:-$DX_PROJECT_ROOT/dx_key.pub}"
export DX_CONTEXT_DIR="${DX_CONTEXT_DIR:-$DX_PROJECT_ROOT/container/aarch64-darwin-apple-container-dx-nixos-25.11}"
export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"


# Helper function to check if a container exists (exact match)
container_exists() {
    local name="$1"
    # use -a to include stopped containers, awk to match the exact name
    container list -a | awk '{print $1}' | grep -x -q "$name"
}

# Helper function to check if a container is running (exact match)
container_is_running() {
    local name="$1"
    # Check if container is in the list of running containers
    container list | awk '{print $1}' | grep -x -q "$name"
}

# Helper function to check if a container image exists (exact match)
container_image_exists() {
    local name="$1"
    container image list | awk '{print $1}' | grep -x -q "$name"
}
