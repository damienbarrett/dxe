#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$SCRIPT_DIR/coverage/out"
SCOPE="$ROOT/bin/lib,$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap,$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib"

if [ "${DXE_COVERAGE_ISOLATED:-}" != 1 ]; then
    provider=""
    command -v docker >/dev/null 2>&1 && provider=docker
    command -v podman >/dev/null 2>&1 && provider=podman
    [ -n "$provider" ] || { echo "Error: coverage needs Docker or Podman for the isolated pinned runner." >&2; exit 1; }
    "$provider" build -t dxe-kcov:ubuntu-24.04 -f "$SCRIPT_DIR/coverage/Dockerfile" "$ROOT"
    exec "$provider" run --rm -e DXE_COVERAGE_ISOLATED=1 -v "$ROOT:/work" -w /work dxe-kcov:ubuntu-24.04 tests/run-coverage-linux.sh
fi
[ "$(uname -s)" = Linux ] && command -v kcov >/dev/null 2>&1 || { echo "Error: isolated coverage image is missing Linux kcov." >&2; exit 1; }

mkdir -p "$OUT"
DXE_COVERAGE_ISOLATED=1 kcov --clean --include-path="$SCOPE" "$OUT" "$SCRIPT_DIR/run-coverage-contracts.sh"
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
    *) echo "Error: sourceable scope line coverage is ${covered:-unknown}%, expected 100%." >&2; exit 1 ;;
esac

scope_lines="$(find "$ROOT/bin/lib" "$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap" "$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib" -type f -name '*.sh' -exec wc -l {} + | awk 'END {print $1}')"
total_lines="$(find "$ROOT/bin" "$ROOT/tests" "$ROOT/container" -type f \( -name '*.sh' -o -path "$ROOT/bin/dx*" \) -exec wc -l {} + | awk 'END {print $1}')"
share=$((scope_lines * 10000 / total_lines))
baseline="$(sed -n 's/^scope_share_basis_points=//p' "$SCRIPT_DIR/coverage/ratchet.env")"
[ "$share" -ge "$baseline" ] || { echo "Error: covered shell scope share regressed from $baseline to $share basis points." >&2; exit 1; }
printf 'covered=100%% scope_share=%d.%02d%%\n' "$((share / 100))" "$((share % 100))"
