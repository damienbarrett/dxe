#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
#
# Edges of the stale tmux socket prune (dx_usage_service_prune_tmux_sockets in
# container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh) that the acceptance
# suite (tests/test_usage_tmux_sockets.sh, real curl and real listeners) cannot
# reach: the probe's verdict per curl exit status, and a guest without curl.
# Only exit status 7 (could not connect) means dead; every other outcome keeps
# the socket. The stubs here stand in for curl only; the real curl behaviour
# against dead and live sockets is checked by the acceptance suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Stale tmux socket prune edges (guest scripts/lib/dx-usage-service.sh)"

LIB="$CONTAINER_DIR/scripts/lib/dx-usage-service.sh"
# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
source "$LIB"

fx="$(mktemp -d /tmp/dxe-tu.XXXXXX)"
cleanup() { case "$fx" in /tmp/dxe-tu.??????) rm -rf "$fx" ;; esac; }
trap cleanup EXIT

stub_curl() {
    # $1 = exit status the stub curl returns.
    mkdir -p "$fx/curl-bin"
    printf '#!/bin/bash\nexit %s\n' "$1" > "$fx/curl-bin/curl"
    chmod +x "$fx/curl-bin/curl"
}

for rc in 7 0 28 52 56; do
    stub_curl "$rc"
    verdict=0
    PATH="$fx/curl-bin:$PATH" dx_usage_service_tmux_socket_dead ./sock || verdict=$?
    if [ "$rc" -eq 7 ]; then want=0; else want=1; fi
    if [ "$verdict" -eq "$want" ]; then
        test_pass "curl exit $rc gives the dead verdict $want"
    else
        test_fail "curl exit $rc gives the dead verdict $want (got $verdict)"
    fi
done

# No curl on PATH: an error status and a message, nothing removed.
uid="$(id -u)"
d="$fx/r/workspace/tmux/tmux-$uid"
mkdir -p "$d" "$fx/nocurl"
ln -s "$(command -v id)" "$fx/nocurl/id"
: > "$d/keep"
rc=0
err="$(PATH="$fx/nocurl" dx_usage_service_prune_tmux_sockets "$d" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 1 ] && [ "${err#*curl is missing}" != "$err" ] && [ -f "$d/keep" ]; then
    test_pass "a guest without curl: status 1, a clear message, nothing removed"
else
    test_fail "a guest without curl: status 1, a clear message (rc $rc, err: $err)"
fi

print_summary
exit_with_code
