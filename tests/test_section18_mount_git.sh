#!/bin/bash
# Section 18: Mount Git Side Containers
# Tests for explicit, isolated host-directory mount profiles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"
DX_MOUNT="$BIN_DIR/dx-mount"
DX_CREATE_CONTAINER="$BIN_DIR/dx-create-container"

test_section "Section 18: Mount Git Side Containers"

assert_file_exists "$DX_MOUNT" "dx-mount exists"

dx_mount_clean() {
    env \
        -u DX_CONTAINER_NAME \
        -u DX_IMAGE \
        -u DX_SSH_PORT \
        -u DX_SSH_KEY \
        -u DX_SSH_KEY_PUB \
        -u DX_NIX_VOLUME \
        -u DX_PERSIST_VOLUME \
        -u DX_BOOTSTRAP_VOLUME \
        -u DX_GIT_MOUNT_SOURCE \
        -u DX_GIT_MOUNT_TARGET \
        -u DX_GUEST_WORKDIR \
        -u DX_CONTAINER_MEMORY \
        -u DX_CONTAINER_CPUS \
        -u DX_MOUNT_IDENTITY_DIR \
        "$DX_MOUNT" "$@"
}

if help_out="$(dx_mount_clean --help 2>&1)" \
    && printf '%s\n' "$help_out" | grep -q -- '--container NAME' \
    && printf '%s\n' "$help_out" | grep -qi -- '--print-env.*without creating' \
    && printf '%s\n' "$help_out" | grep -q -- '--destroy'; then
    test_pass "dx-mount --help describes each supported flag"
else
    test_fail "dx-mount --help describes each supported flag"
fi

if dx_mount_clean --bogus-flag >/dev/null 2>&1; then
    test_fail "dx-mount rejects unknown options"
else
    test_pass "dx-mount rejects unknown options"
fi

if dx_mount_clean --container dx-host --print-env >/dev/null 2>&1; then
    test_fail "dx-mount rejects explicit dx-host container"
else
    test_pass "dx-mount rejects explicit dx-host container"
fi

repo_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx mount git repo.XXXXXX")"
mkdir -p "$repo_dir/sub dir" "$repo_dir/other"
git -C "$repo_dir" init >/dev/null 2>&1

repo_env="$(dx_mount_clean "$repo_dir" --print-env)"
sub_env="$(dx_mount_clean "$repo_dir/sub dir" --print-env)"
other_env="$(dx_mount_clean "$repo_dir/other" --print-env)"

repo_name="$(printf '%s\n' "$repo_env" | sed -n 's/^export DX_CONTAINER_NAME=//p')"
sub_name="$(printf '%s\n' "$sub_env" | sed -n 's/^export DX_CONTAINER_NAME=//p')"
other_name="$(printf '%s\n' "$other_env" | sed -n 's/^export DX_CONTAINER_NAME=//p')"

if [ -n "$repo_name" ] && [ "$repo_name" = "$sub_name" ] && [ "$repo_name" = "$other_name" ]; then
    test_pass "dx-mount derives one container name for subdirectories of the same repo"
else
    test_fail "dx-mount derives one container name for subdirectories of the same repo"
fi

if printf '%s\n' "$repo_env" | grep -q '^export DX_CONTAINER_NAME=dx-mount-'; then
    test_pass "dx-mount uses typed dx-mount container prefix"
else
    test_fail "dx-mount uses typed dx-mount container prefix"
fi

resolved_repo_dir="$(cd "$repo_dir" && pwd -P)"
expected_source="$(printf '%q' "$resolved_repo_dir")"
if printf '%s\n' "$sub_env" | grep -Fxq "export DX_GIT_MOUNT_SOURCE=$expected_source"; then
    test_pass "dx-mount uses git repo top-level as mount identity"
else
    test_fail "dx-mount uses git repo top-level as mount identity"
fi

expected_workdir="$(printf '%q' "/workspace/sub dir")"
if printf '%s\n' "$sub_env" | grep -Fxq "export DX_GUEST_WORKDIR=$expected_workdir"; then
    test_pass "dx-mount maps original repo subdirectory to guest workdir"
else
    test_fail "dx-mount maps original repo subdirectory to guest workdir"
fi

if printf '%s\n' "$repo_env" | grep -qx "export DX_IMAGE=dx-nixos-25.11"; then
    test_pass "dx-mount shares the default immutable image"
else
    test_fail "dx-mount shares the default immutable image"
fi

if printf '%s\n' "$repo_env" | grep -q '^export DX_NIX_VOLUME=dx-mount-.*-nix$' \
    && printf '%s\n' "$repo_env" | grep -q '^export DX_PERSIST_VOLUME=dx-mount-.*-persist$' \
    && printf '%s\n' "$repo_env" | grep -q '^export DX_BOOTSTRAP_VOLUME=dx-mount-.*-bootstrap$'; then
    test_pass "dx-mount defaults to private side-container volumes"
else
    test_fail "dx-mount defaults to private side-container volumes"
fi

if printf '%s\n' "$repo_env" | grep -q '^export DX_SSH_KEY=.*/dx-mount-.*_key$' \
    && printf '%s\n' "$repo_env" | grep -q '^export DX_SSH_KEY_PUB=.*/dx-mount-.*_key\.pub$'; then
    test_pass "dx-mount print-env emits private side-container keypair paths"
else
    test_fail "dx-mount print-env emits private side-container keypair paths"
fi

if printf '%s\n' "$repo_env" | grep -qx "export DX_CONTAINER_MEMORY=6G" \
    && printf '%s\n' "$repo_env" | grep -qx "export DX_CONTAINER_CPUS=2"; then
    test_pass "dx-mount defaults to smaller side-container resources"
else
    test_fail "dx-mount defaults to smaller side-container resources"
fi

port="$(printf '%s\n' "$repo_env" | sed -n 's/^export DX_SSH_PORT=//p')"
if [ "$port" -ge 2300 ] 2>/dev/null && [ "$port" -ne 2222 ] && [ "$port" -ne 2299 ]; then
    test_pass "dx-mount derives non-default SSH port"
else
    test_fail "dx-mount derives non-default SSH port"
fi

plain_env="$(dx_mount_clean "$repo_dir" --container dx-side-explicit --print-env)"
if printf '%s\n' "$plain_env" | grep -qx "export DX_CONTAINER_NAME=dx-side-explicit"; then
    test_pass "dx-mount accepts explicit non-reserved container name"
else
    test_fail "dx-mount accepts explicit non-reserved container name"
fi

non_git_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx mount plain dir.XXXXXX")"
plain_dir_env="$(dx_mount_clean "$non_git_dir" --print-env)"
resolved_non_git_dir="$(cd "$non_git_dir" && pwd -P)"
expected_plain_source="$(printf '%q' "$resolved_non_git_dir")"
if printf '%s\n' "$plain_dir_env" | grep -Fxq "export DX_GIT_MOUNT_SOURCE=$expected_plain_source"; then
    test_pass "dx-mount uses non-git directory itself as mount source"
else
    test_fail "dx-mount uses non-git directory itself as mount source"
fi

if dx_mount_clean "$repo_dir" --print-env --destroy >/dev/null 2>&1; then
    test_fail "dx-mount rejects combining --print-env with --destroy"
else
    test_pass "dx-mount rejects combining --print-env with --destroy"
fi

# Behavioral: dx_port_in_use must detect a live loopback listener and a free
# port. Probe with the helper itself to find a free port, then occupy it.
probe_port=29183
attempts=0
while dx_port_in_use "$probe_port" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    probe_port=$((probe_port + 1))
    attempts=$((attempts + 1))
done
nc -l 127.0.0.1 "$probe_port" >/dev/null 2>&1 &
nc_pid=$!
sleep 1
if dx_port_in_use "$probe_port" 2>/dev/null; then
    test_pass "dx_port_in_use detects an occupied loopback port"
else
    test_fail "dx_port_in_use detects an occupied loopback port"
fi
kill "$nc_pid" >/dev/null 2>&1 || true
wait "$nc_pid" 2>/dev/null || true
sleep 1
if ! dx_port_in_use "$probe_port" 2>/dev/null && command -v dx_port_in_use >/dev/null 2>&1; then
    test_pass "dx_port_in_use reports a released port as free"
else
    test_fail "dx_port_in_use reports a released port as free"
fi

# Behavioral: --destroy must refuse to touch dx-host's default durable
# resources even when a caller's environment leaks the default names. The
# container CLI is stubbed so a missing guard cannot touch real state.
stub_bin="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-stub.XXXXXX")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/container"
chmod +x "$stub_bin/container"
identity_tmp="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-identity.XXXXXX")"

dx_mount_destroy_guarded() {
    local var="$1" value="$2"
    env \
        -u DX_CONTAINER_NAME -u DX_IMAGE -u DX_SSH_PORT \
        -u DX_SSH_KEY -u DX_SSH_KEY_PUB \
        -u DX_NIX_VOLUME -u DX_PERSIST_VOLUME -u DX_BOOTSTRAP_VOLUME \
        -u DX_GIT_MOUNT_SOURCE -u DX_GIT_MOUNT_TARGET -u DX_GUEST_WORKDIR \
        -u DX_CONTAINER_MEMORY -u DX_CONTAINER_CPUS \
        "$var=$value" \
        DX_MOUNT_IDENTITY_DIR="$identity_tmp" \
        PATH="$stub_bin:$PATH" \
        "$DX_MOUNT" "$non_git_dir" --destroy
}

for guard_case in \
    "DX_NIX_VOLUME=dx-nix" \
    "DX_PERSIST_VOLUME=dx-persist" \
    "DX_BOOTSTRAP_VOLUME=dx-bootstrap"; do
    guard_var="${guard_case%%=*}"
    guard_value="${guard_case#*=}"
    if dx_mount_destroy_guarded "$guard_var" "$guard_value" >/dev/null 2>&1; then
        test_fail "dx-mount --destroy refuses default $guard_value"
    else
        test_pass "dx-mount --destroy refuses default $guard_value"
    fi
done

assert_file_contains "$DX_CREATE_CONTAINER" 'if \[ -n "\$DX_GIT_MOUNT_SOURCE" \]' "dx-create-container only mounts when source is explicit"
assert_file_contains "$DX_CREATE_CONTAINER" 'DX_CONTAINER_NAME.*dx-host' "dx-create-container guards dx-host mount attempts"
assert_file_contains "$BIN_DIR/dx" "dx-create-container" "plain dx still uses normal create-container pipeline"
assert_file_not_contains "$BIN_DIR/dx" "DX_GIT_MOUNT_SOURCE" "plain dx does not infer or set host git mounts"
assert_file_contains "$DX_MOUNT" "dx-destroy-container" "dx-mount has explicit side-container cleanup"
assert_file_contains "$DX_MOUNT" "dx-destroy-volumes.*--force" "dx-mount cleanup removes private volumes"
assert_file_not_contains "$DX_MOUNT" "dx-destroy-image" "dx-mount cleanup preserves shared image"
assert_file_contains "$DX_MOUNT" "refusing to destroy default" "dx-mount destroy guards default durable resources"
assert_file_contains "$DX_MOUNT" 'dx_key' "dx-mount destroy guards the default dx-host keypair"
assert_file_contains "$DX_MOUNT" "dx_port_in_use" "dx-mount probes for SSH port collisions"
assert_file_contains "$DX_MOUNT" "already in use" "dx-mount refuses to create a side container on a busy port"

print_summary
exit_with_code
