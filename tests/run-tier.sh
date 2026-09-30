#!/bin/bash
# WP1.4 (Fable D2): each case is now a one-line wrapper over tests/run.sh,
# which selects suites by their own `# tier:` header instead of the
# `for section in 1 2 3 5 ...` hand list this file used to carry directly
# -- the exact list Muse D1 / Astra R2 found already silently omitting
# sections 0, 4, 19, 24 and 33 (all container-free, all run by CI).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tier="${1:-}"
case "$tier" in
    unit/static)
        if [ "$(uname -s)" != Linux ]; then
            echo "NOTE: Section 25 Nix-store importer behavior requires the isolated Linux runner; run tests/run-coverage-linux.sh for that gate."
        fi
        "$SCRIPT_DIR/run.sh" --tier unit
        ;;
    host-contract)
        # Sections 9 and 18 need no running guest (both already pass in
        # CI's container-free job unconditionally) -- WP1.4 tags them
        # `# tier: unit` rather than adding a tier value only these two
        # suites would ever use, and keeps this case name working by
        # naming them directly instead of by tier.
        "$SCRIPT_DIR/run.sh" --tier unit --section 9
        "$SCRIPT_DIR/run.sh" --tier unit --section 18
        ;;
    live)
        "$SCRIPT_DIR/run.sh" --tier live
        ;;
    destructive)
        [ "${DX_TEST_DESTRUCTIVE:-}" = 1 ] || { echo "Error: destructive tier requires DX_TEST_DESTRUCTIVE=1." >&2; exit 1; }
        case "${DX_CONTAINER_NAME:-dx-host}" in dx-host|'') echo "Error: destructive tier refuses default container resources." >&2; exit 1 ;; esac
        "$SCRIPT_DIR/standalone_test_factory_reset.sh"
        ;;
    *) echo "Usage: $(basename "$0") {unit/static|host-contract|live|destructive}" >&2; exit 2 ;;
esac
