#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$SCRIPT_DIR/coverage/out"
SCOPE="$ROOT/bin/lib,$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap,$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib"

if [ "${DXE_COVERAGE_ISOLATED:-}" != 1 ]; then
    # Pick the first runtime that is actually usable, not merely installed. An
    # installed docker whose daemon is down used to be selected and then fail
    # at the build, reporting a missing socket instead of trying the next
    # candidate -- which is how the gate came to look unrunnable on a machine
    # that had a working runtime all along. Apple's `container` is included
    # because this repo targets it: it accepts the same build/run flags used
    # below and produces an identical result.
    provider=""
    for candidate in docker podman container; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        case "$candidate" in
            container) container system status >/dev/null 2>&1 || continue ;;
            *) "$candidate" info >/dev/null 2>&1 || continue ;;
        esac
        provider="$candidate"
        break
    done
    [ -n "$provider" ] || { echo "Error: coverage needs a usable Docker, Podman, or Apple container runtime for the isolated pinned runner." >&2; exit 1; }
    echo "Using $provider for the isolated coverage runner."
    "$provider" build -t dxe-kcov:ubuntu-24.04 -f "$SCRIPT_DIR/coverage/Dockerfile" "$ROOT"
    # kcov keeps every instrumented process's line table in memory; with the
    # header-derived contracts list (twenty suites) the runtime's default
    # allocation (1 GB under Apple's container) is OOM-killed (exit 137).
    exec "$provider" run --rm --memory 4g -e DXE_COVERAGE_ISOLATED=1 -v "$ROOT:/work" -w /work dxe-kcov:ubuntu-24.04 tests/run-coverage-linux.sh
fi
[ "$(uname -s)" = Linux ] && command -v kcov >/dev/null 2>&1 || { echo "Error: isolated coverage image is missing Linux kcov." >&2; exit 1; }

mkdir -p "$OUT"
# A `done < "$file"` line likewise carries no command of its own -- the
# redirection belongs to the compound `while` whose first line is the one
# bash traces -- so such lines are marked KCOV_LOOP_TERMINATOR and excluded
# for the same reason.
# A standalone `)` only terminates a Bash subshell compound command; it has no
# executable instruction for kcov to probe. Keep multiline subshell helpers
# readable while measuring every executable source line.
DXE_COVERAGE_ISOLATED=1 kcov --clean --exclude-line=KCOV_SUBSHELL_TERMINATOR,KCOV_LOOP_TERMINATOR --include-path="$SCOPE" "$OUT" "$SCRIPT_DIR/run-coverage-contracts.sh"
summary="$OUT/run-coverage-contracts.sh/coverage.json"
[ -f "$summary" ] || summary="$(find "$OUT" -name coverage.json -print -quit)"
while IFS= read -r source; do
    grep -Fq "\"file\": \"$source\"" "$summary" || {
        echo "Error: sourceable coverage report omitted $source." >&2
        exit 1
    }
done < <(find \
    "$ROOT/bin/lib" \
    "$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap" \
    "$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib" \
    -type f -name '*.sh' -print | sort)
covered="$(sed -n 's/.*"percent_covered"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9.]*\).*/\1/p' "$summary" | tail -1)"
case "$covered" in
    100|100.0|100.00) ;;
    *)
        echo "Error: sourceable scope line coverage is ${covered:-unknown}%, expected 100%." >&2
        # Name the shortfall. A bare percentage is not actionable on a runner
        # whose report artifact may not survive the failed step.
        echo "Files below 100%:" >&2
        grep '"file":' "$summary" | grep -v '"percent_covered": "100.00"' | sed 's/^[[:space:]]*/  /' >&2
        exit 1
        ;;
esac

# shellcheck source=lib/coverage-metric.sh
source "$SCRIPT_DIR/lib/coverage-metric.sh"
metric_out="$OUT/coverage-metric.env"
dx_coverage_metric "$ROOT" "$summary" > "$metric_out"
dx_coverage_ratchet_check "$metric_out" "$SCRIPT_DIR/coverage/ratchet.env"
scope_exec_lines="$(sed -n 's/^scope_exec_lines=//p' "$metric_out")"
unscoped_prod_exec_lines="$(sed -n 's/^unscoped_prod_exec_lines=//p' "$metric_out")"
printf 'covered=100%% scope_exec_lines=%s unscoped_prod_exec_lines=%s\n' "$scope_exec_lines" "$unscoped_prod_exec_lines"
