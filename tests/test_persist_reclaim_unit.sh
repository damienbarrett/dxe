#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP5.2: in-process coverage for the dx-reclaim persist reporting helpers in
# bin/lib/dx-container.sh. tests/test_persist_reclaim.sh drives bin/dx-reclaim
# end to end; this suite calls the helpers directly so every branch is counted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-runtime-apple.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"

test_section "WP5.2: dx-reclaim persist reporting (in-process)"

DX_CONTAINER_NAME=dx-u DX_PERSIST_VOLUME=dx-u-persist DX_PERSIST_HOST_ROOT=/root-x
DX_NIX_VOLUME=dx-u-nix

# Fakes for the runtime calls the helpers make.
CALLS_LOG="$(mktemp "${TMPDIR:-/tmp}/dxe-reclaim-calls.XXXXXX")"
trap 'rm -f "${OUTF:-}" "$CALLS_LOG"' EXIT
# The fakes run inside command substitutions, so they log their arguments.
dx_runtime_volume_usage() { echo "volume $1" >>"$CALLS_LOG"; printf '7.5GB'; }
U_RC=0; U_OUT='296	/root-x/dxe/dx-u/persist'
dx_runtime_host_dir_usage() { echo "dir $1" >>"$CALLS_LOG"; printf '%s\n' "$U_OUT"; return "$U_RC"; }

OUTF="$(mktemp "${TMPDIR:-/tmp}/dxe-reclaim-unit.XXXXXX")"
DX_PERSIST_STORAGE=volume
dx_persist_usage_line >"$OUTF"; out="$(cat "$OUTF")"
[ "$out" = "  dx-u-persist   7.5GB" ] && test_pass "usage line: volume mode prints the volume's size" || test_fail "usage line volume: [$out]"
[ "$(cat "$CALLS_LOG")" = "volume dx-u-persist" ] && test_pass "usage line: volume mode queries the persist volume" || test_fail "usage line volume query: [$(cat "$CALLS_LOG")]"
: >"$CALLS_LOG"

DX_PERSIST_STORAGE=host-path
dx_persist_usage_line >"$OUTF"; out="$(cat "$OUTF")"
[ "$out" = "  /root-x/dxe/dx-u/persist 296K" ] && test_pass "usage line: host-path prints the directory and its KiB" || test_fail "usage line host-path: [$out]"
[ "$(cat "$CALLS_LOG")" = "dir /root-x/dxe/dx-u/persist" ] && test_pass "usage line: host-path reads the derived directory" || test_fail "usage line dir arg: [$(cat "$CALLS_LOG")]"
: >"$CALLS_LOG"

U_RC=1
dx_persist_usage_line >"$OUTF" 2>/dev/null; rc=$?
out="$(cat "$OUTF")"
[ "$rc" = 0 ] && [ "$out" = "  /root-x/dxe/dx-u/persist unknown" ] && test_pass "usage line: a failed read prints unknown and exits 0" || test_fail "usage line unknown: rc=$rc [$out]"
U_RC=0

msg="$(DX_PERSIST_STORAGE=volume dx_persist_trim_skip_message)"
[ "$msg" = "Skipping filesystem trim: not supported against a Docker volume under this runtime (qnap-dxe-plan.md DQ4)." ] && test_pass "trim skip: volume mode keeps today's message" || test_fail "trim skip volume: [$msg]"
msg="$(DX_PERSIST_STORAGE=host-path dx_persist_trim_skip_message)"
case "$msg" in
    "Skipping filesystem trim:"*"host directory"*) ! grep -Fq 'Docker volume' <<<"$msg" && test_pass "trim skip: host-path says host directory, never Docker volume" || test_fail "trim skip host-path names a volume: [$msg]" ;;
    *) test_fail "trim skip host-path: [$msg]" ;;
esac

print_summary
exit_with_code
