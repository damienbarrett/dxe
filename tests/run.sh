#!/bin/bash
# tests/run.sh -- the single test runner (WP1.4 / Fable D2, corrects Muse D1
# / Astra R2).
#
# Before this file, registering one test touched up to seven places
# (KNOWN_SECTIONS and run_test in run_all_tests.sh, run-tier.sh's own
# section-number list, run-bash32-tests.sh's file list,
# run-coverage-contracts.sh's file list, tests/test_refactor_contracts.sh's
# B2 literal list, and the paragraph a new test forces into ratchet.env),
# and the hand-maintained lists had already drifted from each other and
# from what CI actually runs (run-tier.sh's `unit/static` tier silently
# omitted sections 0, 4, 19, 24 and 33, all container-free, all run by CI
# unconditionally). This file selects suites by reading the `# tier:` and
# `# bash32:` headers every tests/test_*.sh now carries (WP1.4's Green
# step; tests/test_refactor_contracts.sh's WP1.4 contract enforces that
# every one of them has exactly one of each) instead of any list that can
# drift out from under it. run_all_tests.sh, run-tier.sh,
# run-bash32-tests.sh and run-coverage-contracts.sh are now one-line
# wrappers over this file.
#
# Usage: tests/run.sh --tier TIER [--bash32] [--section N | --file PATH]
#
#   --tier TIER     unit | host-contract | live | destructive. With no
#                   --section/--file, runs every tests/test_*.sh whose own
#                   `# tier:` header is exactly TIER, each once in its own
#                   process. `# coverage: yes` (today: eleven suites, plus
#                   test_sourceable_coverage.sh) is a SEPARATE, orthogonal
#                   marker read only by run-coverage-contracts.sh's own
#                   selection -- it plays no part in this runner's own
#                   sweep. test_sourceable_coverage.sh needs the isolated,
#                   disposable root/kcov coverage environment
#                   (tests/run-coverage-linux.sh) and exits 1 outside it by
#                   its own design, which is exactly why it is tagged
#                   `# tier: host-contract` rather than `unit`: a bare
#                   `--tier unit` sweep never selects it at all, by tier,
#                   the same way it never selects a live-tier suite.
#                   --file/--section still reach it explicitly regardless.
#   --bash32        Run each selected suite under /bin/bash instead of
#                   bash. In a bare --tier sweep this also requires
#                   `# bash32: yes`; combined with --section/--file, the
#                   resolved suite must itself carry `# bash32: yes` or the
#                   run is refused.
#   --section N     Run only the suite run_all_tests.sh's own dispatch
#                   table names for section N (that table is the one place
#                   left that maps a section number to a file; this file
#                   reads it rather than keeping a second copy). --tier, if
#                   also given, only sets SKIP_INTEGRATION (see below) --
#                   it does not filter which file --section resolves to.
#   --file PATH     Run only PATH directly.
#
# Every suite runs with SKIP_INTEGRATION=true when --tier unit is in
# effect (matching run_all_tests.sh --skip-integration's long-standing
# meaning: unit tier is container-free by construction, proven behaviourally
# by tests/test_section20_skip_integration.sh) and SKIP_INTEGRATION=false
# otherwise, so a --tier live sweep (or a bare --section/--file with no
# --tier) still performs real guest work. DXE_SKIP_SLOW_TESTS and every
# other already-set environment variable pass through unchanged: each suite
# is a real child process that inherits this shell's environment exactly
# as tests/run_all_tests.sh's own `bash "$test_file"` always has.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
Usage: tests/run.sh --tier unit|host-contract|live|destructive [--bash32] [--section N|--file PATH]

  --tier TIER     Run every tests/test_*.sh whose `# tier:` header is
                  exactly TIER (unit|host-contract|live|destructive).
  --bash32        Run each selected suite under /bin/bash instead of bash;
                  in a bare --tier sweep, also requires `# bash32: yes`.
  --section N     Run only the suite run_all_tests.sh dispatches as
                  section N.
  --file PATH     Run only PATH directly.

--section and --file are mutually exclusive. Exactly one of --tier,
--section or --file is required.
USAGE
}

TIER=""
BASH32=false
SECTION=""
FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)
            TIER="${2:-}"
            shift 2
            ;;
        --tier=*)
            TIER="${1#*=}"
            shift
            ;;
        --bash32)
            BASH32=true
            shift
            ;;
        --section)
            SECTION="${2:-}"
            shift 2
            ;;
        --section=*)
            SECTION="${1#*=}"
            shift
            ;;
        --file)
            FILE="${2:-}"
            shift 2
            ;;
        --file=*)
            FILE="${1#*=}"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$SECTION" ] && [ -n "$FILE" ]; then
    echo "Error: --section and --file are mutually exclusive." >&2
    exit 2
fi

case "$TIER" in
    ""|unit|host-contract|live|destructive) ;;
    *)
        echo "Error: unknown tier '$TIER'. Known tiers: unit host-contract live destructive" >&2
        exit 2
        ;;
esac

if [ -z "$TIER" ] && [ -z "$SECTION" ] && [ -z "$FILE" ]; then
    echo "Error: one of --tier, --section or --file is required." >&2
    usage >&2
    exit 2
fi

# Headers live near the top of the file by convention -- normally right
# after the shebang, but as late as line 35 in the five
# test_docker_adapter_*.sh parts (after their shared fixture-prelude
# comment block) -- never searched for over a WHOLE file: at least one
# suite (tests/test_refactor_contracts.sh) legitimately writes literal
# `# tier: ...`/`# bash32: ...` lines hundreds of lines into its own body,
# as fixture text proving its OWN header contract can tell a valid header
# from an invalid one. 40 lines comfortably covers every real header
# (line <= 35 today) while staying well short of that fixture text (first
# occurrence past line 700), so a whole-file scan never reads fixture data
# as this runner's own header and silently drops the file from every sweep.
SUITE_HEADER_WINDOW=40

# suite_header NAME FILE -- the single value of FILE's own `# NAME: ...`
# header line (within the header window above), or empty if absent. This is
# a convenience reader, not a validity check: a caller that needs "exactly
# one, and a recognised value" (a bare --tier sweep, or refusing to run an
# unheaded file) checks that itself, below -- tests/test_refactor_contracts.sh's
# WP1.4 contract is what actually enforces "exactly one" repo-wide, over the
# same window.
suite_header() {
    local name="$1" file="$2"
    head -n "$SUITE_HEADER_WINDOW" "$file" 2>/dev/null | sed -n "s/^# $name: //p" | head -n1
}

# suite_has_valid_tier FILE -- true if FILE carries exactly one `# tier:`
# header (within the header window) with a recognised value.
suite_has_valid_tier() {
    local file="$1"
    [ "$(head -n "$SUITE_HEADER_WINDOW" "$file" 2>/dev/null | grep -c '^# tier: ')" -eq 1 ] || return 1
    case "$(suite_header tier "$file")" in
        unit|host-contract|live|destructive) return 0 ;;
        *) return 1 ;;
    esac
}

# resolve_section_file N -- the file run_all_tests.sh's own dispatch table
# names for section N, read from its `run_test "$SCRIPT_DIR/FILE" "N"`
# lines (the one place left that maps a section number to a file; see
# tests/test_refactor_contracts.sh's B2 contract, which still polices that
# table directly). Prints nothing and returns 1 if N is not dispatched.
resolve_section_file() {
    local n="$1" runner="$SCRIPT_DIR/run_all_tests.sh" match
    match="$(grep -E "run_test[[:space:]]+\"\\\$SCRIPT_DIR/[^\"]+\"[[:space:]]+\"$n\"" "$runner" 2>/dev/null | head -n1)"
    [ -n "$match" ] || return 1
    printf '%s' "$match" | sed -E 's/.*\$SCRIPT_DIR\/([^"]+)".*/\1/'
}

OVERALL_SUCCESS=0

run_suite() {
    local file="$1" interpreter=bash
    if [ "$BASH32" = true ]; then
        interpreter=/bin/bash
        if [ "$(suite_header bash32 "$file")" != yes ]; then
            echo "Error: $(basename "$file") is not tagged \`# bash32: yes\`; refusing to run it under --bash32." >&2
            exit 2
        fi
    fi
    echo ""
    echo "Running: $(basename "$file")"
    echo "---"
    local status=0
    SKIP_INTEGRATION="$RUN_SKIP_INTEGRATION" "$interpreter" "$file" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $(basename "$file") failed."
        OVERALL_SUCCESS=1
    fi
}

# A tier explicitly forces SKIP_INTEGRATION; a bare --section/--file with
# no --tier (e.g. run_all_tests.sh delegating its own --section=N with no
# --skip-integration) instead inherits whatever the caller's shell already
# has, defaulting to false -- the same default run_all_tests.sh's own
# SKIP_INTEGRATION=false always had before any flag was parsed.
if [ "$TIER" = unit ]; then
    RUN_SKIP_INTEGRATION=true
elif [ -n "$TIER" ]; then
    RUN_SKIP_INTEGRATION=false
else
    RUN_SKIP_INTEGRATION="${SKIP_INTEGRATION:-false}"
fi

SELECTED=()

if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || { echo "Error: no such file '$FILE'." >&2; exit 2; }
    SELECTED=("$FILE")
elif [ -n "$SECTION" ]; then
    case "$SECTION" in
        ''|*[!0-9]*)
            echo "Error: --section must be a number, got '$SECTION'." >&2
            exit 2
            ;;
    esac
    resolved_name="$(resolve_section_file "$SECTION")" || {
        echo "Error: unknown section '$SECTION' (run_all_tests.sh does not dispatch it)." >&2
        exit 2
    }
    resolved_file="$SCRIPT_DIR/$resolved_name"
    [ -f "$resolved_file" ] || { echo "Error: section '$SECTION' names '$resolved_name', which does not exist." >&2; exit 2; }
    SELECTED=("$resolved_file")
else
    for candidate in "$SCRIPT_DIR"/test_*.sh; do
        [ -f "$candidate" ] || continue
        suite_has_valid_tier "$candidate" || continue
        [ "$(suite_header tier "$candidate")" = "$TIER" ] || continue
        if [ "$BASH32" = true ] && [ "$(suite_header bash32 "$candidate")" != yes ]; then
            continue
        fi
        SELECTED+=("$candidate")
    done
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
    echo "Error: no suite selected." >&2
    exit 2
fi

for selected_file in "${SELECTED[@]}"; do
    suite_has_valid_tier "$selected_file" || {
        echo "Error: refusing to run $(basename "$selected_file"): no valid \`# tier:\` header." >&2
        exit 2
    }
done

echo "======================================"
echo "DX Experience Test Suite"
echo "======================================"

for selected_file in "${SELECTED[@]}"; do
    run_suite "$selected_file"
done

echo ""
echo "======================================"
if [ "$OVERALL_SUCCESS" -eq 0 ]; then
    echo "All tests PASSED!"
else
    echo "Some tests FAILED."
fi
echo "======================================"

exit "$OVERALL_SUCCESS"
