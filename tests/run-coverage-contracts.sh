#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WP1.4 (Fable D2): the "regular" suites below used to be a fourth
# hand-maintained file list (this script's own); they are now every
# tests/test_*.sh tagged both `# tier: unit` and `# coverage: yes`, minus
# the suites that need special handling (kept below, unchanged) -- four
# that need SKIP_INTEGRATION=true forced regardless of this script's own
# ambient environment (their own live-guest branch is not otherwise
# self-protected the way a plain requires_container call is), and two that
# need the isolated, disposable root/kcov coverage environment
# specifically. A suite opts into this gate at the file (its own header)
# instead of a hand list here. Coverage-relevant suites WP1.4's own pass
# missed (the old hand list never ran them under kcov at all): sections 9,
# 10, 16, 18, 20, 23 and 24 -- each sources bin/lib or a guest bootstrap
# library directly, closing the last gap to 100% (section 23's cases were
# the only exercise of container/.../scripts/lib/dx-persist-relocate.sh).
for suite in "$SCRIPT_DIR"/test_*.sh; do
    [ "$(sed -n 's/^# tier: //p' "$suite" | head -n1)" = unit ] || continue
    [ "$(sed -n 's/^# coverage: //p' "$suite" | head -n1)" = yes ] || continue
    case "$(basename "$suite")" in
        test_section19_reverse_forward.sh|test_section3_bootstrap.sh|test_section17_dx_ai_runtime.sh|test_section16_persist_storage.sh|test_section23_herdr.sh|test_sourceable_coverage.sh|test_nix_store_import.sh)
            continue
            ;;
    esac
    "$suite"
done

# Section 19 became container-free for its docker-ssh identity cases (WP3.4);
# the adapter's cached-identity read path is exercised only there.
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section19_reverse_forward.sh"
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section3_bootstrap.sh"
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section17_dx_ai_runtime.sh"
# Unlike a plain requires_container call, section 16's migration-helper
# integration path only self-skips on a MISSING image (container_image_exists),
# not on a missing `container` binary outright -- forcing SKIP_INTEGRATION=true
# is what actually keeps it from attempting real container work here.
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section16_persist_storage.sh"
# Verified directly (not assumed): without SKIP_INTEGRATION=true forced,
# section 23's live block attempts a real SSH connect to localhost:2222 and
# fails loudly ("SSH not reachable") rather than self-skipping via
# requires_container -- it is container-free only WITH this forced.
SKIP_INTEGRATION=true "$SCRIPT_DIR/test_section23_herdr.sh"
if [ "${DXE_COVERAGE_ISOLATED:-}" = 1 ]; then "$SCRIPT_DIR/test_sourceable_coverage.sh"; fi
if [ "${DXE_COVERAGE_ISOLATED:-}" = 1 ]; then bash "$SCRIPT_DIR/test_nix_store_import.sh"; fi
