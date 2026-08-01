#!/bin/bash
# The DX_* plan values below are read by dx_mount_manifest_load_plan_values from
# the sourced planner, which ShellCheck cannot follow through "$BASE_DIR".
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
MOUNT="$BASE_DIR/bin/dx-mount"
test_section "Section 18: Mount Plans And Manifests"

help="$($MOUNT --help 2>&1)"
for option in '--container NAME' '--print-env' '--destroy' '--print-destroy-plan' '--audit-manifests' '--migrate-manifests' '--apply'; do
    if printf '%s\n' "$help" | grep -q -- "$option"; then test_pass "dx-mount help documents $option"; else test_fail "dx-mount help documents $option"; fi
done
if "$MOUNT" --print-env --destroy >/dev/null 2>&1; then test_fail "mount modes are mutually exclusive"; else test_pass "mount modes are mutually exclusive"; fi
if "$MOUNT" --container ../unsafe --print-env >/dev/null 2>&1; then test_fail "unsafe container names are rejected before path construction"; else test_pass "unsafe container names are rejected before path construction"; fi

repo="$(mktemp -d "${TMPDIR:-/tmp}/dxe-mount-repo.XXXXXX")"
state="$(mktemp -d "${TMPDIR:-/tmp}/dxe-mount-state.XXXXXX")"
trap 'rm -rf "$repo" "$state"' EXIT
git -C "$repo" init -q; mkdir -p "$repo/sub dir"
env_out="$(env -u DX_CONTAINER_NAME -u DX_NIX_VOLUME -u DX_PERSIST_VOLUME -u DX_BOOTSTRAP_VOLUME -u DX_SSH_KEY -u DX_SSH_KEY_PUB -u DX_SSH_PORT \
    -u DXE_CONFIG_RESOLVED -u DXE_CONFIG_SNAPSHOT_VERSION "$MOUNT" "$repo/sub dir" --print-env)"
name="$(printf '%s\n' "$env_out" | sed -n 's/^export DX_CONTAINER_NAME=//p')"
if printf '%s\n' "$env_out" | grep -q '^export DX_GIT_MOUNT_SOURCE=' && printf '%s\n' "$env_out" | grep -q 'DX_GUEST_WORKDIR=/workspace/sub\\ dir'; then test_pass "planner canonicalizes repository source and guest workdir"; else test_fail "planner canonicalizes repository source and guest workdir"; fi
for suffix in nix persist bootstrap; do printf '%s\n' "$env_out" | grep -q "export DX_.*VOLUME=${name}-${suffix}" && test_pass "planner derives private $suffix volume" || test_fail "planner derives private $suffix volume"; done

source "$BASE_DIR/bin/lib/dx-mount-plan.sh"
legacy="$state/legacy.env"
{
    printf 'DX_MARKER_VERSION=1\n'
    printf 'DX_RECORDED_CONTAINER_NAME=%q\n' dx-side-codec
    printf 'DX_RECORDED_GIT_MOUNT_SOURCE=%q\n' '/tmp/source with spaces'
    printf 'DX_RECORDED_GIT_MOUNT_TARGET=%q\n' /workspace
    printf 'DX_RECORDED_IMAGE=%q\n' dx-nixos-26.05
    printf 'DX_RECORDED_NIX_VOLUME=%q\n' dx-side-codec-nix
    printf 'DX_RECORDED_PERSIST_VOLUME=%q\n' dx-side-codec-persist
    printf 'DX_RECORDED_BOOTSTRAP_VOLUME=%q\n' dx-side-codec-bootstrap
    printf 'DX_RECORDED_SSH_KEY=%q\n' '/tmp/key with spaces'
    printf 'DX_RECORDED_SSH_KEY_PUB=%q\n' '/tmp/key with spaces.pub'
    printf 'DX_RECORDED_SSH_PORT=%q\n' 2301
} > "$legacy"
if dx_mount_manifest_read "$legacy" && [ "$DX_MOUNT_MANIFEST_FORMAT" = 1 ] && [ "$DX_MOUNT_MANIFEST_COMPLETE" = true ] && [ "$DX_RECORDED_GIT_MOUNT_SOURCE" = '/tmp/source with spaces' ]; then test_pass "bounded legacy decoder accepts supported Bash 3.2 %q records"; else test_fail "bounded legacy decoder accepts supported Bash 3.2 %q records"; fi

printf '%s\n' 'DX_RECORDED_CONTAINER_NAME=$(touch /tmp/dxe-never)' > "$state/hostile.env"
if dx_mount_manifest_read "$state/hostile.env" >/dev/null 2>&1; then test_fail "hostile legacy manifest is rejected"; else test_pass "hostile legacy manifest is rejected without evaluation"; fi
[ ! -e /tmp/dxe-never ] && test_pass "manifest text never executes" || test_fail "manifest text never executes"

DX_CONTAINER_NAME=dx-side-codec DX_GIT_MOUNT_SOURCE='/tmp/source with spaces' DX_GIT_MOUNT_TARGET=/workspace DX_IMAGE=dx-nixos-26.05
DX_NIX_VOLUME=dx-side-codec-nix DX_PERSIST_VOLUME=dx-side-codec-persist DX_BOOTSTRAP_VOLUME=dx-side-codec-bootstrap
DX_SSH_KEY='/tmp/key with spaces' DX_SSH_KEY_PUB='/tmp/key with spaces.pub' DX_SSH_PORT=2301
dx_mount_manifest_load_plan_values
v2="$state/v2.env"
if dx_mount_manifest_publish_new "$v2" && dx_mount_manifest_read "$v2" && [ "$DX_MOUNT_MANIFEST_FORMAT" = 2 ] && [ "$DX_RECORDED_SSH_KEY" = '/tmp/key with spaces' ]; then test_pass "v2 manifest round-trips through canonical base64 data records"; else test_fail "v2 manifest round-trips through canonical base64 data records"; fi
[ "$(dx_path_mode "$state")" = 700 ] && test_pass "identity directory is private" || test_fail "identity directory is private"
[ "$(dx_path_mode "$v2")" = 600 ] && test_pass "manifest is private" || test_fail "manifest is private"
before="$(shasum -a 256 "$v2")"
if dx_mount_manifest_publish_new "$v2" >/dev/null 2>&1; then test_fail "first publication is semantically write-once"; else test_pass "first publication is semantically write-once"; fi
[ "$before" = "$(shasum -a 256 "$v2")" ] && test_pass "failed publication preserves authoritative manifest" || test_fail "failed publication preserves authoritative manifest"

audit="$(DX_MOUNT_IDENTITY_DIR="$state" "$MOUNT" --audit-manifests)"
if printf '%s\n' "$audit" | grep -q 'v2.env format=v2 complete=true'; then test_pass "manifest audit reports v2 completeness"; else test_fail "manifest audit reports v2 completeness"; fi
assert_file_not_contains "$MOUNT" 'DX_MOUNT_TEST_MODE' "dx-mount has no production test seam"
assert_file_not_contains "$MOUNT" 'source "$identity_file"' "dx-mount never sources persisted identity data"

print_summary
exit_with_code
