#!/bin/bash
# tier: unit
# bash32: yes
set -euo pipefail

# Red for WP4.2 / Fable A6: dx_wait_until <timeout> <interval> <cmd...>, the
# single injectable-clock bounded-wait primitive that every hand-written
# polling loop in bin/lib/dx-host-util.sh, bin/lib/dx-container.sh,
# bin/dx-sync-bootstrap and bin/dx-wait-ssh migrates onto. Today
# bin/lib/dx-host-util.sh defines no such function, so every case below
# fails with "command not found".
#
# ${DX_SLEEP:-sleep} is the seam: production code never sets DX_SLEEP, so it
# keeps calling the real `sleep`; a test overrides DX_SLEEP with a function
# that records its argument (and, where a case needs the wait to eventually
# succeed, advances the fixture instead of real time) so the suite never
# pays a real sleep and never races this host's load.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
test_section "Host Util: dx_wait_until"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-host-util.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# (1) A predicate that never succeeds waits out the full bound: exactly
# `timeout / interval` sleeps, each recorded by the fake clock, then fails.
sleep_log_1="$fixture/sleep-1.log"
fake_sleep_1() { printf '%s\n' "$1" >> "$sleep_log_1"; }
status=0
DX_SLEEP=fake_sleep_1 dx_wait_until 3 1 false || status=$?
if [ "$status" -eq 1 ]; then test_pass "a predicate that never succeeds returns 1"; else test_fail "a predicate that never succeeds returns 1 (got $status)"; fi
if [ -f "$sleep_log_1" ] && [ "$(wc -l < "$sleep_log_1" | tr -d ' ')" -eq 3 ]; then
    test_pass "a predicate that never succeeds sleeps exactly three times"
else
    test_fail "a predicate that never succeeds sleeps exactly three times (log: $(cat "$sleep_log_1" 2>/dev/null | tr '\n' ','))"
fi

# (2) A predicate that succeeds on its second call returns success after
# exactly one sleep -- the loop checks before it waits, not after.
sleep_log_2="$fixture/sleep-2.log"
fake_sleep_2() { printf '%s\n' "$1" >> "$sleep_log_2"; }
pred_calls=0
pred() { pred_calls=$((pred_calls + 1)); [ "$pred_calls" -ge 2 ]; }
status=0
DX_SLEEP=fake_sleep_2 dx_wait_until 3 1 pred || status=$?
if [ "$status" -eq 0 ]; then test_pass "a predicate that succeeds on its second call returns 0"; else test_fail "a predicate that succeeds on its second call returns 0 (got $status)"; fi
if [ -f "$sleep_log_2" ] && [ "$(wc -l < "$sleep_log_2" | tr -d ' ')" -eq 1 ]; then
    test_pass "a predicate that succeeds on its second call sleeps exactly once"
else
    test_fail "a predicate that succeeds on its second call sleeps exactly once (log: $(cat "$sleep_log_2" 2>/dev/null | tr '\n' ','))"
fi

# (3) A zero timeout still checks the predicate once (so an already-true
# condition is never reported false), but never sleeps.
sleep_log_3="$fixture/sleep-3.log"
fake_sleep_3() { printf '%s\n' "$1" >> "$sleep_log_3"; }
status=0
DX_SLEEP=fake_sleep_3 dx_wait_until 0 1 false || status=$?
if [ "$status" -eq 1 ]; then test_pass "a zero timeout with a failing predicate returns 1"; else test_fail "a zero timeout with a failing predicate returns 1 (got $status)"; fi
if [ ! -e "$sleep_log_3" ]; then test_pass "a zero timeout never sleeps"; else test_fail "a zero timeout never sleeps (log: $(cat "$sleep_log_3" | tr '\n' ','))"; fi

# (4) Extra argv words reach the predicate verbatim: `test -e "$file"` only
# passes once the fixture file actually exists, and the fake sleep is what
# creates it -- proving both that "-e" and the path arrived intact at
# `test`, and that dx_wait_until re-checks after each wait.
argfile="$fixture/argfile"
rm -f "$argfile"
sleep_log_4="$fixture/sleep-4.log"
fake_sleep_4() { printf '%s\n' "$1" >> "$sleep_log_4"; : > "$argfile"; }
status=0
DX_SLEEP=fake_sleep_4 dx_wait_until 2 1 test -e "$argfile" || status=$?
if [ "$status" -eq 0 ]; then test_pass "the predicate receives its extra arguments (test -e \$file)"; else test_fail "the predicate receives its extra arguments (test -e \$file) (got $status)"; fi
if [ -f "$sleep_log_4" ] && [ "$(wc -l < "$sleep_log_4" | tr -d ' ')" -eq 1 ]; then
    test_pass "the predicate is re-checked once after the file appears"
else
    test_fail "the predicate is re-checked once after the file appears (log: $(cat "$sleep_log_4" 2>/dev/null | tr '\n' ','))"
fi

# (5) The interval argument reaches sleep byte-for-byte, not rescaled or
# reformatted -- three failed checks against a 5s bound with a 2s interval
# sleep three times (0, 2, 4 all still under 5; 6 is not), each call
# recording exactly "2".
sleep_log_5="$fixture/sleep-5.log"
fake_sleep_5() { printf '%s\n' "$1" >> "$sleep_log_5"; }
status=0
DX_SLEEP=fake_sleep_5 dx_wait_until 5 2 false || status=$?
if [ "$status" -eq 1 ]; then test_pass "a non-1 interval still fails once its bound is exceeded"; else test_fail "a non-1 interval still fails once its bound is exceeded (got $status)"; fi
if [ -f "$sleep_log_5" ] && [ "$(wc -l < "$sleep_log_5" | tr -d ' ')" -eq 3 ] && [ "$(sort -u "$sleep_log_5" | tr -d '\n')" = 2 ]; then
    test_pass "the interval is passed to sleep verbatim"
else
    test_fail "the interval is passed to sleep verbatim (log: $(cat "$sleep_log_5" 2>/dev/null | tr '\n' ','))"
fi

print_summary
exit_with_code
