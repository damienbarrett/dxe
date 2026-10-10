#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.2 (plans/do D-5; R20, R23): the runtime capability
# `runtime_host_directories`.
#
# Interface contract (pinned by this file; the implementation must match):
#   * `dx_runtime_capability runtime_host_directories` returns 0 when
#     DX_RUNTIME=docker-ssh and 1 when DX_RUNTIME=apple (default runtime).
#     It prints nothing in either case and makes no runtime call (a pure
#     local-table lookup, like the other capabilities).
#   * `bind_mounts` is unchanged: 1 for docker-ssh, 0 for apple.
#   * Unknown capability names still print "unknown runtime capability" and
#     return 2.
#   * bin/dx-mount under docker-ssh is still refused with
#     "dx-mount is not supported under DX_RUNTIME=docker-ssh", non-zero, and
#     no ssh/docker/container/tailscale call is recorded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "WP3.2: runtime_host_directories capability"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-capability.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home"

# Recording, fail-closed fakes: every network/runtime tool logs its argv to
# the transcript and exits 99, so any call is both visible and fatal.
transcript="$fixture/transcript"
: > "$transcript"
tools="$(fake_tool_dir_create "$fixture")"
for tool in ssh scp sftp docker tailscale container nix curl; do
    fake_tool_write "$tools" "$tool" "printf '%s %s\\n' '$tool' \"\$*\" >> '$transcript'
echo 'fake-tools: $tool must not be called' >&2
exit 99"
done

# cap RUNTIME NAME -> prints "rc=<n>|<stdout+stderr>" (runtime as set in a subshell).
cap() {
    local runtime="$1" name="$2" out rc
    out="$(
        if [ -n "$runtime" ]; then DX_RUNTIME="$runtime"; else unset DX_RUNTIME; fi
        PATH="$tools:/usr/bin:/bin"
        dx_runtime_capability "$name" 2>&1
        echo "rc=$?"
    )"
    printf '%s' "$out"
}
rc_of() { sed -n 's/.*rc=\([0-9]*\)$/\1/p' <<<"$1"; }
body_of() { sed '$d' <<<"$1"; }

check() { # label runtime name expected-rc
    local label="$1" out
    out="$(cap "$2" "$3")"
    if [ "$(rc_of "$out")" = "$4" ] && [ -z "$(body_of "$out")" ]; then
        test_pass "$label"
    else
        test_fail "$label"
        printf '%s\n' "$out" | tail -n 4
    fi
}

check "docker-ssh answers 0 for runtime_host_directories" docker-ssh runtime_host_directories 0
check "apple answers 1 for runtime_host_directories" apple runtime_host_directories 1
check "the default runtime (apple) answers 1 for runtime_host_directories" "" runtime_host_directories 1

# Unchanged neighbours (R23): bind_mounts stays off for docker-ssh, on for apple.
check "docker-ssh still answers 1 for bind_mounts" docker-ssh bind_mounts 1
check "apple still answers 0 for bind_mounts" apple bind_mounts 0
check "docker-ssh still answers 0 for direct_named_volume_mounts" docker-ssh direct_named_volume_mounts 0
check "apple still answers 0 for direct_named_volume_mounts" apple direct_named_volume_mounts 0

# The two capabilities are independent: docker has host directories but not
# bind mounts; apple the reverse.
d_hd="$(rc_of "$(cap docker-ssh runtime_host_directories)")"; d_bm="$(rc_of "$(cap docker-ssh bind_mounts)")"
a_hd="$(rc_of "$(cap apple runtime_host_directories)")"; a_bm="$(rc_of "$(cap apple bind_mounts)")"
if [ "$d_hd" = 0 ] && [ "$d_bm" = 1 ] && [ "$a_hd" = 1 ] && [ "$a_bm" = 0 ]; then
    test_pass "runtime_host_directories and bind_mounts are independent answers per runtime"
else test_fail "runtime_host_directories and bind_mounts are independent answers per runtime ($d_hd $d_bm $a_hd $a_bm)"; fi

# Unknown names are still an error, and a near-miss name is not accepted.
for rt in docker-ssh apple; do
    out="$(cap "$rt" runtime_host_directory)"
    if [ "$(rc_of "$out")" = 2 ] && grep -Fq "unknown runtime capability" <<<"$out"; then
        test_pass "$rt: a near-miss capability name (runtime_host_directory) is still unknown"
    else test_fail "$rt: a near-miss capability name (runtime_host_directory) is still unknown"; printf '%s\n' "$out" | tail -n 3; fi
done

# No capability query reaches a runtime.
if [ ! -s "$transcript" ]; then test_pass "capability queries record no ssh/docker/container call"
else test_fail "capability queries record no ssh/docker/container call"; cat "$transcript"; fi

# bin/dx-mount stays refused under docker-ssh, before any runtime call (R23).
: > "$transcript"
out="$(env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" \
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux \
    DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap-persist-cap \
    "$BASE_DIR/bin/dx-mount" "$fixture/home" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "dx-mount is not supported under DX_RUNTIME=docker-ssh" <<<"$out"; then
    test_pass "bin/dx-mount under docker-ssh is refused with the unsupported message"
else test_fail "bin/dx-mount under docker-ssh is refused with the unsupported message (rc=$rc)"; printf '%s\n' "$out" | tail -n 4; fi
if [ ! -s "$transcript" ] && ! grep -Fq "must not be called" <<<"$out"; then
    test_pass "bin/dx-mount under docker-ssh records no ssh, docker, container or tailscale call"
else test_fail "bin/dx-mount under docker-ssh records no ssh, docker, container or tailscale call"; cat "$transcript"; fi

# Even with host-path persistence selected, dx-mount stays refused (the new
# capability must not be mistaken for bind_mounts).
: > "$transcript"
out="$(env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" \
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux \
    DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap-persist-cap \
    DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/example-root \
    "$BASE_DIR/bin/dx-mount" "$fixture/home" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$transcript" ] && grep -Fq "not supported under DX_RUNTIME=docker-ssh" <<<"$out" \
    && ! grep -Fq "must not be called" <<<"$out"; then
    test_pass "bin/dx-mount stays refused under docker-ssh with host-path persistence, no runtime call"
else test_fail "bin/dx-mount stays refused under docker-ssh with host-path persistence, no runtime call (rc=$rc)"; printf '%s\n' "$out" | tail -n 4; cat "$transcript"; fi

print_summary
exit_with_code
