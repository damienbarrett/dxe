#!/bin/bash
# Run all DX Experience tests
# Usage: ./run_all_tests.sh [--section=N] [--skip-integration]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test helpers for exit_with_code function
source "$SCRIPT_DIR/test_helpers.sh"

# Parse arguments
SECTION=""
SKIP_INTEGRATION=false

# Every section this runner can dispatch. An unknown --section= must fail rather
# than report success over an empty run: tests/run-tier.sh selects whole tiers by
# section number, so a silent no-op would shrink a tier without failing CI.
KNOWN_SECTIONS="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24"

for arg in "$@"; do
    case $arg in
        --section=*)
            SECTION="${arg#*=}"
            ;;
        --skip-integration)
            SKIP_INTEGRATION=true
            ;;
        --help)
            echo "Usage: $0 [--section=N] [--skip-integration]"
            echo ""
            echo "Options:"
            echo "  --section=N         Run only section N (0-24)"
            echo "  --skip-integration  Skip integration tests and live checks"
            echo "  --help              Show this help message"
            exit 0
            ;;
    esac
done

if [ -n "$SECTION" ]; then
    case " $KNOWN_SECTIONS " in
        *" $SECTION "*) ;;
        *) echo "Error: unknown section '$SECTION'. Known sections: $KNOWN_SECTIONS" >&2; exit 2 ;;
    esac
fi

export SKIP_INTEGRATION

echo "======================================"
echo "DX Experience Test Suite"
echo "======================================"
echo ""

# Track overall success
OVERALL_SUCCESS=0

# Run tests based on section filter
run_test() {
    local test_file="$1"
    local section_num="$2"
    
    if [ -n "$SECTION" ] && [ "$SECTION" != "$section_num" ]; then
        return
    fi
    
    echo ""
    echo "Running: $(basename "$test_file")"
    echo "---"
    if ! bash "$test_file"; then
        echo "FAIL: $(basename "$test_file") failed."
        OVERALL_SUCCESS=1
    fi
}

# Unit tests (no container required)
run_test "$SCRIPT_DIR/test_section0_lint.sh" "0"
run_test "$SCRIPT_DIR/test_section1_secrets.sh" "1"
run_test "$SCRIPT_DIR/test_section2_containerfile.sh" "2"
run_test "$SCRIPT_DIR/test_section3_bootstrap.sh" "3"

# Bring the selected isolated guest to a validated running state before any
# later section performs live probes against it.
if [ "$SKIP_INTEGRATION" = false ]; then
    run_test "$SCRIPT_DIR/test_section11_validate_fresh.sh" "11"
fi

run_test "$SCRIPT_DIR/test_section4_ssh.sh" "4"
run_test "$SCRIPT_DIR/test_section5_nix.sh" "5"
run_test "$SCRIPT_DIR/test_section6_tools.sh" "6"
run_test "$SCRIPT_DIR/test_section7_lazyvim.sh" "7"
run_test "$SCRIPT_DIR/test_section8_nixvim_config.sh" "8"
run_test "$SCRIPT_DIR/test_section9_host_scripts.sh" "9"
run_test "$SCRIPT_DIR/test_section10_docs.sh" "10"
run_test "$SCRIPT_DIR/test_section20_skip_integration.sh" "20"
run_test "$SCRIPT_DIR/test_refactor_state_machines.sh" "21"
run_test "$SCRIPT_DIR/test_bootstrap_publication.sh" "22"

# Remaining integration tests (require the running guest or Linux)
if [ "$SKIP_INTEGRATION" = false ]; then
    run_test "$SCRIPT_DIR/test_section12_validate_linux.sh" "12"
fi

# Final review (always run)
run_test "$SCRIPT_DIR/test_section13_final_review.sh" "13"
run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"
run_test "$SCRIPT_DIR/test_section15_nushell_env.sh" "15"
run_test "$SCRIPT_DIR/test_section16_persist_storage.sh" "16"
run_test "$SCRIPT_DIR/test_section17_dx_ai_runtime.sh" "17"
# Herdr's live block probes for an installed herdr; it must run after section 17
# installs the AI tools bundle, or the live probe is doomed to skip.
run_test "$SCRIPT_DIR/test_section23_herdr.sh" "23"
run_test "$SCRIPT_DIR/test_herdr_config_persistence.sh" "24"
run_test "$SCRIPT_DIR/test_section18_mount_git.sh" "18"
run_test "$SCRIPT_DIR/test_section19_reverse_forward.sh" "19"

echo ""
echo "======================================"
if [ $OVERALL_SUCCESS -eq 0 ]; then
    echo "All tests PASSED!"
else
    echo "Some tests FAILED."
fi
echo "======================================"

exit $OVERALL_SUCCESS
