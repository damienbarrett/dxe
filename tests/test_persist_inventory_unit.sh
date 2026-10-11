#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.3 implementer cases the acceptance suite (test_persist_inventory.sh) does
# not pin: dx_persist_inventory_main with the three runtime operations replaced
# by in-process stubs, to reach the refusals that need a malformed answer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP6.3: malformed answers are failed reads with one Error line"

GOOD_VOL="df_avail_kb=900
size_kb=100
entries=5
hardlinks=0
appledouble=0
special=0
acl=0
xattr=0
status=ok"
VOL_ANSWER="$GOOD_VOL"
FREE_ANSWER="fs=/dev/x
total_kb=1000
avail_kb=500"
FREE_RC=0
RSYNC_ERR=""
RSYNC_RC=0
RSYNC_FLAGS="${TMPDIR:-/tmp}/dxe-inv-unit.flags.$$"
trap 'rm -f "$RSYNC_FLAGS"' EXIT
dx_runtime_volume_inventory() { printf '%s\n' "$VOL_ANSWER"; }
dx_runtime_host_dir_free() { printf '%s\n' "$FREE_ANSWER"; return "$FREE_RC"; }
dx_runtime_host_rsync_check() {
    printf "%s" "$*" >"$RSYNC_FLAGS"
    if [ -n "$RSYNC_ERR" ]; then echo "$RSYNC_ERR" >&2; fi
    if [ "$RSYNC_RC" = 0 ]; then echo version=3.3.0; fi
    return "$RSYNC_RC"
}
export DX_RUNTIME=docker-ssh DX_PERSIST_VOLUME=vol DX_PERSIST_HOST_ROOT=/share

run() { # sets OUT ERR RC
    OUT="$(dx_persist_inventory_main 2>"${TMPDIR:-/tmp}/dxe-inv-unit.err.$$")"
    RC=$?
    ERR="$(cat "${TMPDIR:-/tmp}/dxe-inv-unit.err.$$")"
    rm -f "${TMPDIR:-/tmp}/dxe-inv-unit.err.$$"
}
check() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}

run
check "baseline: exit 0" 0 "$RC"

VOL_ANSWER="$(printf '%s\n' "$GOOD_VOL" | sed 's/^acl=0$/acl=lots/')"
run
check "a garbled acl value: exit 1" 1 "$RC"
check "a garbled acl value: no report" "" "$OUT"
check "a garbled acl value: one Error line" 1 "$(grep -c '^Error:' <<<"$ERR")"

VOL_ANSWER="$GOOD_VOL"
FREE_ANSWER="fs=/dev/x
avail_kb=lots"
run
check "a garbled avail_kb: exit 1" 1 "$RC"
check "a garbled avail_kb: no report" "" "$OUT"

FREE_ANSWER="fs=/dev/x
total_kb=1000
avail_kb=500"
FREE_RC=1
run
check "a failing free-space read: exit 1" 1 "$RC"
FREE_RC=0

RSYNC_RC=1
run
check "rsync check fails without a message: exit 3" 3 "$RC"
case "$OUT" in
    *"rsync_check: refused: rsync check failed"*) test_pass "the fallback message is named" ;;
    *) test_fail "the fallback message is named ($OUT)" ;;
esac
RSYNC_RC=0

VOL_ANSWER="$(printf '%s\n' "$GOOD_VOL" | sed 's/^acl=0$/acl=2/; s/^xattr=0$/xattr=unknown/')"
run
check "needed capabilities are passed as -A and -X" "-A -X" "$(cat "$RSYNC_FLAGS")"

print_summary
exit_with_code
