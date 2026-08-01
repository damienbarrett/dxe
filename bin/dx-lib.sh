#!/bin/bash
# Compatibility facade for host commands that have not yet migrated to
# individual libraries. It initializes configuration but intentionally does not
# require or start Apple Container merely because it was sourced.

DX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DX_PROJECT_ROOT="$(cd "$DX_LIB_DIR/.." && pwd)"
export DX_LIB_DIR DX_PROJECT_ROOT

# shellcheck source=lib/dx-config.sh
source "$DX_LIB_DIR/lib/dx-config.sh"
# shellcheck source=lib/dx-host-util.sh
source "$DX_LIB_DIR/lib/dx-host-util.sh"
# shellcheck source=lib/dx-container.sh
source "$DX_LIB_DIR/lib/dx-container.sh"
# shellcheck source=lib/dx-ssh-common.sh
source "$DX_LIB_DIR/lib/dx-ssh-common.sh"
# shellcheck source=lib/dx-mount-plan.sh
source "$DX_LIB_DIR/lib/dx-mount-plan.sh"
# shellcheck source=lib/dx-tunnel.sh
source "$DX_LIB_DIR/lib/dx-tunnel.sh"

dx_init_config "$DX_PROJECT_ROOT"
