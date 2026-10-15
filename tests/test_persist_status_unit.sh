#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.4: in-process coverage for the /persist storage helpers in
# bin/lib/dx-container.sh and the Apple inspect parser's edge cases.
# tests/test_persist_status_mounts.sh drives dx-status/dx-start-container from
# `env -i` probes, which kcov cannot trace; this suite calls the functions here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-runtime-apple.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"

test_section "WP3.4: /persist storage helpers (in-process)"

fixture="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fixture "${TMPDIR:-/tmp}/dxe-persist-status-unit.XXXXXX"
trap 'rm -rf "$fixture"' EXIT

# Fakes for the runtime-touching functions the helpers call.
P_EXISTS=1; P_MOUNTS=''; P_MOUNTS_RC=0
container_exists() { [ "$P_EXISTS" = 1 ]; }
dx_runtime_container_mounts() { [ "$P_MOUNTS_RC" = 0 ] || return "$P_MOUNTS_RC"; printf '%b' "$P_MOUNTS"; }
DX_CONTAINER_NAME=dx-u DX_PERSIST_VOLUME=dx-u-persist DX_PERSIST_HOST_ROOT=/root-x

DX_PERSIST_STORAGE=volume
[ "$(dx_persist_configured_source)" = dx-u-persist ] && test_pass "configured source: volume mode is the volume name" || test_fail "configured source: volume mode"
DX_PERSIST_STORAGE=host-path
[ "$(dx_persist_configured_source)" = /root-x/dxe/dx-u/persist ] && test_pass "configured source: host-path mode is the derived directory" || test_fail "configured source: host-path mode"

P_MOUNTS='bind|/a|/data|rw\nvolume|v1|/persist|rw\n'
[ "$(dx_persist_actual_source dx-u)" = v1 ] && test_pass "actual source: the /persist mount's source" || test_fail "actual source"
P_MOUNTS='bind|/a|/data|rw\n'
[ "$(dx_persist_actual_source dx-u)" = '(no /persist mount)' ] && test_pass "actual source: none when there is no /persist mount" || test_fail "actual source: no mount"
P_MOUNTS_RC=1
if dx_persist_actual_source dx-u >/dev/null; then test_fail "actual source: unreadable mounts is non-zero"; else test_pass "actual source: unreadable mounts is non-zero"; fi

P_MOUNTS_RC=1 DX_PERSIST_STORAGE=volume
out="$(dx_persist_status_report)"
grep -Fxq 'actual: (unavailable)' <<<"$out" && ! grep -Fq mismatch <<<"$out" && test_pass "status report: unreadable mounts says unavailable, no mismatch" || test_fail "status report unavailable: $out"
P_MOUNTS_RC=0 P_EXISTS=0
out="$(dx_persist_status_report)"
grep -Fxq 'actual: (container not present)' <<<"$out" && test_pass "status report: absent container" || test_fail "status report absent: $out"
P_EXISTS=1 P_MOUNTS='volume|dx-u-persist|/persist|rw\n'
out="$(dx_persist_status_report)"
grep -Fxq 'actual: dx-u-persist' <<<"$out" && ! grep -Fq mismatch <<<"$out" && test_pass "status report: matching has no mismatch" || test_fail "status report match: $out"
P_MOUNTS='volume|other|/persist|rw\n'
out="$(dx_persist_status_report)"
grep -Fq mismatch <<<"$out" && test_pass "status report: differing source is a mismatch" || test_fail "status report mismatch: $out"

err="$(dx_persist_warn_mismatch 2>&1 >/dev/null)"
[ "$(grep -Fc dx-recreate <<<"$err")" = 1 ] && grep -Fq 'Warning:' <<<"$err" && test_pass "warn: one dx-recreate warning on mismatch" || test_fail "warn mismatch: $err"
P_MOUNTS='volume|dx-u-persist|/persist|rw\n'
[ -z "$(dx_persist_warn_mismatch 2>&1)" ] && test_pass "warn: silent when matching" || test_fail "warn: silent when matching"
P_MOUNTS_RC=1
[ -z "$(dx_persist_warn_mismatch 2>&1)" ] && test_pass "warn: silent when mounts are unreadable" || test_fail "warn: silent when unreadable"

# Apple parser edge cases: escaped slashes, other types, empty and stray arrays.
ATOOLS="$(fake_tool_dir_create "$fixture")" || exit 1
fake_tool_write "$ATOOLS" container "cat '$fixture/inspect.json'"
apple() { PATH="$ATOOLS:/usr/bin:/bin" dx_runtime_apple_container_mounts x; }
printf '%s\n' '[{"configuration":{"mounts":[{"destination":"\/persist","options":["rw","ro"],"source":"\/p\\q\"r","type":{"tmpfs":{}}},{"destination":"\/n","options":[],"source":"\/s","type":{"volume":{"name":"nm"}}},{"destination":"\/o","options":[],"source":"\/s\n"}]},"other":{"mounts":[]}}]' > "$fixture/inspect.json"
want="$(printf 'tmpfs|/p\\q"r|/persist|ro\nvolume|nm|/n|rw\nunknown|/s\\n|/o|rw')"
[ "$(apple)" = "$want" ] && test_pass "apple: escaped slashes/quotes unescaped, other type names passed through, missing type unknown" || test_fail "apple edge cases: $(apple)"
printf '%s\n' '[{"configuration":{"mounts":[]}}]' > "$fixture/inspect.json"
[ -z "$(apple)" ] && test_pass "apple: no mounts gives no output" || test_fail "apple: no mounts"

print_summary
exit_with_code
