#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP-T1: the docker-ssh adapter's own non-stdin ssh calls (docker binary
# discovery, the reachability probe, guest-address discovery) must never read
# the caller's stdin. Found by the live NAS trial: with DXE_RUNTIME_DOCKER_BIN
# unset, `printf bytes | dx_runtime_docker_cli run --rm -i ...` discovers the
# binary inside a command substitution first, and that bare ssh swallowed the
# bytes meant for the container (a marker written via a root container came
# out empty).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "Docker transport: non-stdin ssh calls never consume the caller's stdin (WP-T1)"

dxe_test_mktemp_dir SCRATCH "${TMPDIR:-/tmp}/dxe-docker-stdin.XXXXXX"
trap 'rm -rf "$SCRATCH"' EXIT
TOOLS="$(fake_tool_dir_create "$SCRATCH")" || exit 1
LOG="$SCRATCH/calls"
mkdir -p "$LOG"
# A fake ssh that records each call's command string and, separately, every
# byte of that call's stdin; it answers the discovery and probe scripts.
fake_tool_write "$TOOLS" ssh 'n=$(ls "$DXE_FAKE_CALLS" | wc -l | tr -d " ")
last=""; for a in "$@"; do last="$a"; done
printf "%s" "$last" > "$DXE_FAKE_CALLS/c$n.cmd"
cat > "$DXE_FAKE_CALLS/c$n.stdin"
case "$last" in
    *"command -v docker"*) echo /fake/docker ;;
esac'
source "$BASE_DIR/bin/lib/dx-runtime-docker.sh"

reset_calls() { rm -f "$LOG"/*; }
call_with() { # file-prefix pattern -> prints the stdin of the call whose cmd matches
    local f
    for f in "$LOG"/*.cmd; do
        if grep -Fq -- "$1" "$f"; then cat "${f%.cmd}.stdin"; return 0; fi
    done
    return 1
}

export DXE_FAKE_CALLS="$LOG" DX_REMOTE_HOST=dxe-fixture-nas.invalid
export PATH="$TOOLS:$PATH"
unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_GUEST_SSH_ADDRESS

reset_calls
printf 'marker-bytes' | dx_runtime_docker_cli run --rm -i busybox >/dev/null 2>&1
run_stdin="$(call_with ' run ' ; printf x)"; run_stdin="${run_stdin%x}"
disc_stdin="$(call_with 'command -v docker' ; printf x)"; disc_stdin="${disc_stdin%x}"
if [ "$run_stdin" = "marker-bytes" ]; then
    test_pass "docker run -i receives exactly the caller's stdin after a fresh discovery"
else
    test_fail "docker run -i stdin was '$run_stdin', expected 'marker-bytes'"
fi
if [ -z "$disc_stdin" ]; then
    test_pass "the discovery ssh call reads no stdin"
else
    test_fail "the discovery ssh call consumed '$disc_stdin'"
fi

reset_calls
unset DXE_RUNTIME_DOCKER_BIN
printf 'probe-bytes' | dx_runtime_docker_host_reachable >/dev/null 2>&1
probe_stdin="$(cat "$LOG"/c0.stdin; printf x)"; probe_stdin="${probe_stdin%x}"
if [ -z "$probe_stdin" ]; then
    test_pass "the reachability probe reads no stdin"
else
    test_fail "the reachability probe consumed '$probe_stdin'"
fi

reset_calls
unset DXE_RUNTIME_GUEST_SSH_ADDRESS
printf 'addr-bytes' | dx_runtime_docker_discover_guest_ssh_address >/dev/null 2>&1
addr_stdin="$(call_with 'tailscale'; printf x)"; addr_stdin="${addr_stdin%x}"
if [ -z "$addr_stdin" ]; then
    test_pass "guest SSH address discovery reads no stdin"
else
    test_fail "guest SSH address discovery consumed '$addr_stdin'"
fi

print_summary
exit_with_code
