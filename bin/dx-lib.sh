#!/bin/bash
# The fixed-order library facade every bin/dx* entrypoint sources. Each
# bin/lib/*.sh below is import-pure -- defines functions/constants only, no
# output, no command dispatch, no caller-state change when sourced (proven
# for every one of them by tests/test_refactor_contracts.sh) -- but the
# order they are sourced in below is not arbitrary: later files assume
# earlier ones are already loaded, and tests/test_refactor_state_machines.sh
# replays this exact order in its own fixture. This file also initializes
# configuration but intentionally does not require or start Apple Container
# merely because it was sourced.

DX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DX_PROJECT_ROOT="$(cd "$DX_LIB_DIR/.." && pwd)"
export DX_LIB_DIR DX_PROJECT_ROOT

# shellcheck source=lib/dx-config.sh
source "$DX_LIB_DIR/lib/dx-config.sh"
# shellcheck source=lib/dx-host-util.sh
source "$DX_LIB_DIR/lib/dx-host-util.sh"
# shellcheck source=lib/dx-runtime.sh
source "$DX_LIB_DIR/lib/dx-runtime.sh"
# shellcheck source=lib/dx-container.sh
source "$DX_LIB_DIR/lib/dx-container.sh"
# shellcheck source=lib/dx-bootstrap-protocol.sh
#
# Sourced before dx-bootstrap-sync.sh (and before dx-ssh-common.sh, which it
# must also precede): dx-bootstrap-sync.sh calls
# dx_guest_publication_protocol_snippet at SOURCE time, to build its
# dx_sync_guest_program variable, so the function has to exist already.
source "$DX_LIB_DIR/lib/dx-bootstrap-protocol.sh"
# shellcheck source=lib/dx-bootstrap-sync.sh
source "$DX_LIB_DIR/lib/dx-bootstrap-sync.sh"
# shellcheck source=lib/dx-ssh-common.sh
source "$DX_LIB_DIR/lib/dx-ssh-common.sh"
# shellcheck source=lib/dx-mount-plan.sh
source "$DX_LIB_DIR/lib/dx-mount-plan.sh"
# shellcheck source=lib/dx-tunnel.sh
source "$DX_LIB_DIR/lib/dx-tunnel.sh"

dx_init_config "$DX_PROJECT_ROOT"
