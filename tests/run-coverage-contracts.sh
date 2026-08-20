#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/test_refactor_contracts.sh"
"$SCRIPT_DIR/test_refactor_state_machines.sh"
"$SCRIPT_DIR/test_bootstrap_publication.sh"
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section3_bootstrap.sh"
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section17_dx_ai_runtime.sh"
if [ "${DXE_COVERAGE_ISOLATED:-}" = 1 ]; then "$SCRIPT_DIR/test_sourceable_coverage.sh"; fi
if [ "${DXE_COVERAGE_ISOLATED:-}" = 1 ]; then bash "$SCRIPT_DIR/test_nix_store_import.sh"; fi
