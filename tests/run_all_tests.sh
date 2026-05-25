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
            echo "  --section=N         Run only section N (0-16)"
            echo "  --skip-integration  Skip integration tests (sections 11-12)"
            echo "  --help              Show this help message"
            exit 0
            ;;
    esac
done

export SKIP_INTEGRATION

echo "======================================"
echo "DX Experience Test Suite"
echo "======================================"
echo ""

# Make all test scripts executable
chmod +x "$SCRIPT_DIR"/test_*.sh
chmod +x "$SCRIPT_DIR"/run_all_tests.sh

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
run_test "$SCRIPT_DIR/test_section4_ssh.sh" "4"
run_test "$SCRIPT_DIR/test_section5_nix.sh" "5"
run_test "$SCRIPT_DIR/test_section6_tools.sh" "6"
run_test "$SCRIPT_DIR/test_section7_lazyvim.sh" "7"
run_test "$SCRIPT_DIR/test_section8_nixvim_config.sh" "8"
run_test "$SCRIPT_DIR/test_section9_host_scripts.sh" "9"
run_test "$SCRIPT_DIR/test_section10_docs.sh" "10"

# Integration tests (require container or Linux)
if [ "$SKIP_INTEGRATION" = false ]; then
    run_test "$SCRIPT_DIR/test_section11_validate_fresh.sh" "11"
    run_test "$SCRIPT_DIR/test_section12_validate_linux.sh" "12"
fi

# Final review (always run)
run_test "$SCRIPT_DIR/test_section13_final_review.sh" "13"
run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"
run_test "$SCRIPT_DIR/test_section15_nushell_env.sh" "15"
run_test "$SCRIPT_DIR/test_section16_workspace_persistence.sh" "16"
run_test "$SCRIPT_DIR/test_section17_dx_ai_runtime.sh" "17"

echo ""
echo "======================================"
if [ $OVERALL_SUCCESS -eq 0 ]; then
    echo "All tests PASSED!"
else
    echo "Some tests FAILED."
fi
echo "======================================"

exit $OVERALL_SUCCESS
