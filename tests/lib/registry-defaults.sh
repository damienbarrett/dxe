#!/bin/bash
# tier: unit
# bash32: yes
# registry_default NAME -- print NAME's default from the config registry
# (bin/lib/dx-config.sh). Runs in a subshell so sourcing the production
# library leaves the caller's shell untouched (tests/test_helpers.sh may not
# source production code itself; tests/test_refactor_contracts.sh enforces
# that). Used by live_tail_enabled so the default guest name/port are never a
# second hand-written copy.
registry_default() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    DX_PROJECT_ROOT="$root" bash -c 'source "$1/bin/lib/dx-config.sh" && dx_config_default "$2"' _ "$root" "$1"
}
