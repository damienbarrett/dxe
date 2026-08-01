#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tier="${1:-}"
case "$tier" in
    unit/static)
        "$SCRIPT_DIR/test_refactor_contracts.sh"
        for section in 1 2 3 5 6 7 8 10 13 14 15 16 17 20 21 22; do "$SCRIPT_DIR/run_all_tests.sh" --skip-integration --section="$section"; done
        ;;
    host-contract)
        "$SCRIPT_DIR/run_all_tests.sh" --skip-integration --section=9
        "$SCRIPT_DIR/run_all_tests.sh" --skip-integration --section=18
        ;;
    live)
        "$SCRIPT_DIR/run_all_tests.sh"
        ;;
    destructive)
        [ "${DX_TEST_DESTRUCTIVE:-}" = 1 ] || { echo "Error: destructive tier requires DX_TEST_DESTRUCTIVE=1." >&2; exit 1; }
        case "${DX_CONTAINER_NAME:-dx-host}" in dx-host|'') echo "Error: destructive tier refuses default container resources." >&2; exit 1 ;; esac
        "$SCRIPT_DIR/standalone_test_factory_reset.sh"
        ;;
    *) echo "Usage: $(basename "$0") {unit/static|host-contract|live|destructive}" >&2; exit 2 ;;
esac
