#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.1: in-process coverage of the /persist host-path cross-field rules.
# tests/test_persist_storage_config.sh pins the same behaviour from `env -i`
# children, which kcov cannot trace; this suite drives the functions in this
# process so the new lines in bin/lib/dx-config.sh are measured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"

test_section "WP3.1: host-path cross-field rules (in-process)"

fixture="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fixture "${TMPDIR:-/tmp}/dxe-persist-config-unit.XXXXXX"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/root"

has() { grep -Fq -- "$2" <<<"$1"; }

# Run the cross-field check in a subshell with a docker-ssh host-path
# baseline; "$@" are VAR=value overrides applied before the check.
cross() {
    (
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
        DX_NIX_STORAGE_MODE=direct-volume
        DX_NIX_VOLUME=n DX_PERSIST_VOLUME=p DX_BOOTSTRAP_VOLUME=b
        DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/fixture
        local kv
        for kv in "$@"; do
            case "$kv" in *=*) printf -v "${kv%%=*}" '%s' "${kv#*=}" ;; esac
        done
        dx_config_validate_cross_fields
    ) 2>&1
}

out=$(cross); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && test_pass "docker-ssh host-path with a colon-free root is accepted" \
    || test_fail "docker-ssh host-path with a colon-free root is accepted"

out=$(cross DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image); rc=$?
[ "$rc" -eq 1 ] && has "$out" "DX_PERSIST_STORAGE=host-path" && has "$out" "DX_RUNTIME=docker-ssh" \
    && has "$out" "docs/guest.md" && ! has "$out" "is required" && ! has "$out" "must not contain" \
    && test_pass "apple + host-path is refused with the docs pointer" \
    || test_fail "apple + host-path is refused with the docs pointer"

out=$(cross DX_PERSIST_HOST_ROOT=); rc=$?
[ "$rc" -eq 1 ] && has "$out" "DX_PERSIST_HOST_ROOT is required when DX_PERSIST_STORAGE=host-path" \
    && ! has "$out" "docs/guest.md" && ! has "$out" "must not contain" \
    && test_pass "host-path with an empty root is refused" \
    || test_fail "host-path with an empty root is refused"

out=$(cross DX_PERSIST_HOST_ROOT=/share/a:b); rc=$?
[ "$rc" -eq 1 ] && has "$out" "DX_PERSIST_HOST_ROOT must not contain ':'" \
    && ! has "$out" "is required" && ! has "$out" "docs/guest.md" \
    && test_pass "host-path with a colon in the root is refused" \
    || test_fail "host-path with a colon in the root is refused"

out=$(cross DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT=/share/a:b); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && test_pass "volume mode ignores DX_PERSIST_HOST_ROOT" \
    || test_fail "volume mode ignores DX_PERSIST_HOST_ROOT"

# dx_init_config returns at the first invalid resolved value.
(
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    DX_PERSIST_STORAGE=bogus
    out=$(dx_init_config "$fixture/root" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && has "$out" "invalid resolved value for DX_PERSIST_STORAGE" \
        && [ "${DXE_CONFIG_RESOLVED:-}" != 1 ]
) && test_pass "dx_init_config stops on an invalid DX_PERSIST_STORAGE value" \
    || test_fail "dx_init_config stops on an invalid DX_PERSIST_STORAGE value"

print_summary
exit_with_code
