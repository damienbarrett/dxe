#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.1 (implementer unit cases): timestamp field bounds the acceptance suite
# (tests/test_persist_marker.sh) does not enumerate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "WP4.1: marker timestamp bounds"

# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$BASE_DIR/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"

for ts in 2026-10-10T00:00:00Z 2026-01-01T23:59:59Z 2026-12-31T12:00:00Z 2026-02-31T00:00:00Z; do
    if dx_persist_marker_valid_timestamp "$ts"; then test_pass "accepts $ts"; else test_fail "accepts $ts"; fi
done
for ts in 2026-00-10T00:00:00Z 2026-10-00T00:00:00Z 2026-10-32T00:00:00Z 2026-10-10T12:60:00Z 2026-10-10T12:00:60Z 2026-10-10T12:00:00 '' 26-10-10T12:00:00Z; do
    if dx_persist_marker_valid_timestamp "$ts"; then test_fail "rejects '$ts'"; else test_pass "rejects '$ts'"; fi
done

out="$(dx_persist_marker_format g ready v 2026-10-32T00:00:00Z 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$out" = "dx-persist-marker: invalid timestamp" ]; then test_pass "format names an out-of-range day"; else test_fail "format names an out-of-range day (rc=$rc out=$out)"; fi

print_summary
exit_with_code
