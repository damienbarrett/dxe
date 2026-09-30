#!/bin/bash
# Run all DX Experience tests
# Usage: ./run_all_tests.sh [--section=N] [--skip-integration]
#
# WP1.4 (Fable D2): this file is now a wrapper over tests/run.sh, which
# selects suites by their own `# tier:` header instead of a second,
# hand-maintained copy of the table below. Every invocation execs into
# tests/run.sh before ever reaching the KNOWN_SECTIONS/run_test dispatch
# table further down, so that table is no longer actually run from here --
# it is kept, unchanged, as DATA ONLY: tests/run.sh's own --section
# resolution reads a section number's file straight out of this file's
# text, and tests/test_refactor_contracts.sh's B2 contract still parses it
# directly to prove every section number has exactly one entry naming a
# real file, and vice versa. Deleting this table is deferred until the
# header contract alone is proven to cover everything B2 does (Fable D2's
# own Refactor step).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
SECTION=""
SKIP_INTEGRATION=false

# Every section this runner can dispatch. Read (not executed) by
# tests/test_refactor_contracts.sh's B2 contract, which is why it stays
# even though nothing in THIS file's own control flow references it any
# more (every path below execs into tests/run.sh first).
# shellcheck disable=SC2034
KNOWN_SECTIONS="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36"

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
            echo "  --section=N         Run only section N (0-36)"
            echo "  --skip-integration  Skip integration tests and live checks"
            echo "  --help              Show this help message"
            exit 0
            ;;
    esac
done

# tests/run.sh validates the section number against its own reading of the
# dispatch table below (the same data KNOWN_SECTIONS names) and rejects an
# unknown one loudly, so this wrapper does not duplicate that check.
if [ -n "$SECTION" ]; then
    if [ "$SKIP_INTEGRATION" = true ]; then
        exec "$SCRIPT_DIR/run.sh" --tier unit --section "$SECTION"
    else
        exec "$SCRIPT_DIR/run.sh" --section "$SECTION"
    fi
fi

if [ "$SKIP_INTEGRATION" = true ]; then
    exec "$SCRIPT_DIR/run.sh" --tier unit
fi

# No --section, no --skip-integration: the historical "everything" run.
# tests/run.sh has no single tier spanning both container-free and live
# suites (WP1.4 splits that exactly along the SKIP_INTEGRATION-gated
# sections 11/12 the table below always singled out: "unit" for everything
# else, "live" for those two), so this runs both tiers in turn and reports
# failure if either did.
unit_status=0
"$SCRIPT_DIR/run.sh" --tier unit || unit_status=$?
live_status=0
"$SCRIPT_DIR/run.sh" --tier live || live_status=$?
if [ "$unit_status" -eq 0 ] && [ "$live_status" -eq 0 ]; then
    exit 0
fi
exit 1

# --- Dispatch table (DATA ONLY past this point; see the file header) -----
#
# Never actually executed any more (every branch above already exited),
# kept verbatim as the one place a section number maps to a file.
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
        # shellcheck disable=SC2034
        OVERALL_SUCCESS=1
    fi
}

# Unit tests (no container required)
run_test "$SCRIPT_DIR/test_section0_lint.sh" "0"
run_test "$SCRIPT_DIR/test_section1_secrets.sh" "1"
run_test "$SCRIPT_DIR/test_section2_containerfile.sh" "2"
run_test "$SCRIPT_DIR/test_section3_bootstrap.sh" "3"
run_test "$SCRIPT_DIR/test_section26_audit_flake_lock.sh" "26"
run_test "$SCRIPT_DIR/test_section27_qnap_scripts.sh" "27"

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
# WP1.1 / Fable D1: tests/lib/harness.sh's own Red, container-free.
run_test "$SCRIPT_DIR/test_harness.sh" "34"
# WP1.5 / Fable D3: the two-number coverage metric, fixture-driven, no kcov.
run_test "$SCRIPT_DIR/test_coverage_metric.sh" "35"
# WP4.2 / Fable A6: dx_wait_until with an injectable clock.
run_test "$SCRIPT_DIR/test_host_util.sh" "36"

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
run_test "$SCRIPT_DIR/test_nix_store_import.sh" "25"
run_test "$SCRIPT_DIR/test_section18_mount_git.sh" "18"
run_test "$SCRIPT_DIR/test_section19_reverse_forward.sh" "19"

# Persist backup (Branch 10, feat/persist-backup): selection rules against
# fixture trees, and dx-backup/dx-restore over the fake-container boundary.
# No real container needed for any of these.
run_test "$SCRIPT_DIR/test_persist_backup_select.sh" "28"
run_test "$SCRIPT_DIR/test_dx_backup.sh" "29"
run_test "$SCRIPT_DIR/test_dx_restore.sh" "30"

# Branch 11 / Phase 1 (qnap-dxe-plan.md DQ2): characterisation tests for the
# runtime-boundary extraction. Fake-container only, no real container needed.
run_test "$SCRIPT_DIR/test_runtime_boundary_characterisation.sh" "31"
# Branch 11 / Phase 1 item 6: the automated source audit (no raw `container`
# lifecycle verb outside bin/lib/dx-runtime-apple.sh).
run_test "$SCRIPT_DIR/test_runtime_boundary_audit.sh" "32"
run_test "$SCRIPT_DIR/test_docker_runtime_adapter.sh" "33"
