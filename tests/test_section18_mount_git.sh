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

if printf '%s\n' "$repo_env" | grep -qx "export DX_IMAGE=dx-nixos-26.05"; then
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

# --- Section 18b: destroy-only --container path, write-once manifest markers,
# --print-destroy-plan, and unsafe-name rejection (nix-base-plan.md change 5).
# All of these use a logging container stub and a private identity dir; never
# the real Apple container runtime.

if help_out2="$(dx_mount_clean --help 2>&1)" \
    && printf '%s\n' "$help_out2" | grep -q -- '--print-destroy-plan'; then
    test_pass "dx-mount --help describes --print-destroy-plan"
else
    test_fail "dx-mount --help describes --print-destroy-plan"
fi

if dx_mount_clean --print-destroy-plan --destroy >/dev/null 2>&1; then
    test_fail "dx-mount rejects combining --print-destroy-plan with --destroy"
else
    test_pass "dx-mount rejects combining --print-destroy-plan with --destroy"
fi

if dx_mount_clean --print-destroy-plan --print-env >/dev/null 2>&1; then
    test_fail "dx-mount rejects combining --print-destroy-plan with --print-env"
else
    test_pass "dx-mount rejects combining --print-destroy-plan with --print-env"
fi

mnt_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-stub-log.XXXXXX")"
cat > "$mnt_stub_dir/container" <<'STUBEOF'
#!/usr/bin/env bash
echo "$@" >> "${DX_MOUNT_STUB_LOG:?stub log path not set}"
if [ "${1:-}" = "list" ] && [ -n "${DX_MOUNT_STUB_EXISTS_NAME:-}" ]; then
    echo "$DX_MOUNT_STUB_EXISTS_NAME  running  irrelevant"
fi
exit 0
STUBEOF
chmod +x "$mnt_stub_dir/container"

write_legacy_marker() {
    local file="$1" source_dir="$2" target="${3:-/workspace}"
    {
        printf 'DX_RECORDED_GIT_MOUNT_SOURCE=%q\n' "$source_dir"
        printf 'DX_RECORDED_GIT_MOUNT_TARGET=%q\n' "$target"
    } > "$file"
}

write_manifest_marker() {
    local file="$1" name="$2" source_dir="$3" image="$4" nixvol="$5" \
        persistvol="$6" bootvol="$7" sshkey="$8" sshkeypub="$9" target="${10:-/workspace}"
    {
        printf 'DX_RECORDED_CONTAINER_NAME=%q\n' "$name"
        printf 'DX_RECORDED_GIT_MOUNT_SOURCE=%q\n' "$source_dir"
        printf 'DX_RECORDED_GIT_MOUNT_TARGET=%q\n' "$target"
        printf 'DX_RECORDED_IMAGE=%q\n' "$image"
        printf 'DX_RECORDED_NIX_VOLUME=%q\n' "$nixvol"
        printf 'DX_RECORDED_PERSIST_VOLUME=%q\n' "$persistvol"
        printf 'DX_RECORDED_BOOTSTRAP_VOLUME=%q\n' "$bootvol"
        printf 'DX_RECORDED_SSH_KEY=%q\n' "$sshkey"
        printf 'DX_RECORDED_SSH_KEY_PUB=%q\n' "$sshkeypub"
    } > "$file"
}

# Usage: mnt_run <stub_log_file> <identity_dir> [EXTRA_ENV=VAL ...] -- ARGS...
mnt_run() {
    local log="$1" idir="$2"
    shift 2
    local extra_envs=()
    while [ "$1" != "--" ]; do
        extra_envs+=("$1")
        shift
    done
    shift
    env \
        -u DX_CONTAINER_NAME -u DX_IMAGE -u DX_SSH_PORT \
        -u DX_SSH_KEY -u DX_SSH_KEY_PUB \
        -u DX_NIX_VOLUME -u DX_PERSIST_VOLUME -u DX_BOOTSTRAP_VOLUME \
        -u DX_GIT_MOUNT_SOURCE -u DX_GIT_MOUNT_TARGET -u DX_GUEST_WORKDIR \
        -u DX_CONTAINER_MEMORY -u DX_CONTAINER_CPUS \
        -u DX_MOUNT_STUB_EXISTS_NAME \
        DX_MOUNT_STUB_LOG="$log" \
        DX_MOUNT_IDENTITY_DIR="$idir" \
        PATH="$mnt_stub_dir:$PATH" \
        "${extra_envs[@]+"${extra_envs[@]}"}" \
        "$DX_MOUNT" "$@"
}

checksum_of() {
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# A free port for resolve-mode attach tests, so the derived-port probe can
# never collide with something already listening on this machine.
resolve_free_port=41417
rfp_attempts=0
while dx_port_in_use "$resolve_free_port" 2>/dev/null && [ "$rfp_attempts" -lt 50 ]; do
    resolve_free_port=$((resolve_free_port + 1))
    rfp_attempts=$((rfp_attempts + 1))
done

# 1. Destroy-only: --container NAME --destroy succeeds without the recorded
#    source directory present; a legacy marker falls back to derived-from-NAME
#    resources; the marker is removed afterward.
t1_missing_dir="${TMPDIR:-/tmp}/dx-mount-missing-src-$$"
rm -rf "$t1_missing_dir"
t1_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir1.XXXXXX")"
t1_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log1.XXXXXX")"
t1_name="dx-side-orphan1"
write_legacy_marker "$t1_idir/$t1_name.env" "$t1_missing_dir"

if out1="$(mnt_run "$t1_log" "$t1_idir" -- --container "$t1_name" --destroy 2>&1)"; then
    t1_ok=true
else
    t1_ok=false
fi

if [ "$t1_ok" = true ] && [ ! -f "$t1_idir/$t1_name.env" ] && grep -qF "${t1_name}-nix" "$t1_log"; then
    test_pass "dx-mount --container --destroy works without the recorded source directory and derives legacy resources from NAME"
else
    test_fail "dx-mount --container --destroy works without the recorded source directory and derives legacy resources from NAME (out: $out1)"
fi

# 2. Manifest resolution: overridden (non-derived) volume/key names in a
#    manifest marker are what gets destroyed, never name-derived or
#    env-leaked values.
t2_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir2.XXXXXX")"
t2_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log2.XXXXXX")"
t2_name="dx-side-manifest1"
t2_custom_nix="custom-nix-vol-$$"
t2_key="${TMPDIR:-/tmp}/custom_key_$$"
write_manifest_marker "$t2_idir/$t2_name.env" "$t2_name" "/tmp/whatever-source-$$" \
    dx-nixos-25.11 "$t2_custom_nix" "custom-persist-vol-$$" "custom-boot-vol-$$" \
    "$t2_key" "${t2_key}.pub"

if out2="$(mnt_run "$t2_log" "$t2_idir" DX_NIX_VOLUME=leaked-nix-should-not-be-used \
    -- --container "$t2_name" --destroy 2>&1)"; then
    t2_ok=true
else
    t2_ok=false
fi

if [ "$t2_ok" = true ] \
    && grep -qF "$t2_custom_nix" "$t2_log" \
    && ! grep -qF "leaked-nix-should-not-be-used" "$t2_log" \
    && ! grep -qF "${t2_name}-nix" "$t2_log" \
    && [ ! -f "$t2_idir/$t2_name.env" ]; then
    test_pass "dx-mount --container --destroy resolves overridden resources from the manifest, ignoring inherited env and name-derived defaults"
else
    test_fail "dx-mount --container --destroy resolves overridden resources from the manifest (out: $out2)"
fi

# 3a. --print-destroy-plan on a manifest marker: prints the plan, deletes
#     nothing, marker byte-identical, stub never invoked.
t3_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir3.XXXXXX")"
t3_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log3.XXXXXX")"
t3_name="dx-side-plan-manifest1"
t3_nix="plan-nix-$$"
t3_key="${TMPDIR:-/tmp}/plan_key_$$"
write_manifest_marker "$t3_idir/$t3_name.env" "$t3_name" "/tmp/plan-source-$$" \
    dx-nixos-25.11 "$t3_nix" "plan-persist-$$" "plan-boot-$$" "$t3_key" "${t3_key}.pub"
before3="$(checksum_of "$t3_idir/$t3_name.env")"

if out3="$(mnt_run "$t3_log" "$t3_idir" -- --container "$t3_name" --print-destroy-plan 2>&1)"; then
    t3_ok=true
else
    t3_ok=false
fi
after3="$(checksum_of "$t3_idir/$t3_name.env")"

if [ "$t3_ok" = true ] \
    && printf '%s\n' "$out3" | grep -qi "manifest" \
    && printf '%s\n' "$out3" | grep -qF "$t3_nix" \
    && printf '%s\n' "$out3" | grep -qF "$t3_idir/$t3_name.env" \
    && [ "$before3" = "$after3" ] \
    && [ ! -s "$t3_log" ]; then
    test_pass "dx-mount --print-destroy-plan prints the manifest-resolved plan and deletes/writes nothing"
else
    test_fail "dx-mount --print-destroy-plan prints the manifest-resolved plan (out: $out3)"
fi

# 3b. --print-destroy-plan on a legacy marker: same guarantees, name-derived
#     resources shown.
t3b_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir3b.XXXXXX")"
t3b_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log3b.XXXXXX")"
t3b_name="dx-side-plan-legacy1"
write_legacy_marker "$t3b_idir/$t3b_name.env" "/tmp/legacy-plan-source-$$"
before3b="$(checksum_of "$t3b_idir/$t3b_name.env")"

if out3b="$(mnt_run "$t3b_log" "$t3b_idir" -- --container "$t3b_name" --print-destroy-plan 2>&1)"; then
    t3b_ok=true
else
    t3b_ok=false
fi
after3b="$(checksum_of "$t3b_idir/$t3b_name.env")"

if [ "$t3b_ok" = true ] \
    && printf '%s\n' "$out3b" | grep -qi "legacy" \
    && printf '%s\n' "$out3b" | grep -qF "${t3b_name}-nix" \
    && [ "$before3b" = "$after3b" ] \
    && [ ! -s "$t3b_log" ]; then
    test_pass "dx-mount --print-destroy-plan prints the legacy name-derived plan and deletes/writes nothing"
else
    test_fail "dx-mount --print-destroy-plan prints the legacy name-derived plan (out: $out3b)"
fi

# 4. Attach (resolve mode) without the original overrides against a manifest
#    marker: refused, and the marker stays byte-identical.
t4_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-attach-src.XXXXXX")"
t4_resolved="$(cd "$t4_dir" && pwd -P)"
t4_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir4.XXXXXX")"
t4_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log4.XXXXXX")"
t4_name="dx-side-attach-mismatch1"
t4_key="${TMPDIR:-/tmp}/attach_custom_key_$$"
write_manifest_marker "$t4_idir/$t4_name.env" "$t4_name" "$t4_resolved" \
    dx-nixos-25.11 "custom-attach-nix-$$" "${t4_name}-persist" "${t4_name}-bootstrap" \
    "$t4_key" "${t4_key}.pub"
before4="$(checksum_of "$t4_idir/$t4_name.env")"

if out4="$(mnt_run "$t4_log" "$t4_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t4_name" "$t4_dir" 2>&1)"; then
    t4_ok=true
else
    t4_ok=false
fi
after4="$(checksum_of "$t4_idir/$t4_name.env")"

if [ "$t4_ok" = false ] && [ "$before4" = "$after4" ]; then
    test_pass "dx-mount refuses to attach when resolved resources mismatch the recorded manifest, marker untouched"
else
    test_fail "dx-mount refuses to attach on manifest mismatch (out: $out4)"
fi

# 5. Attach (resolve mode) WITH matching values: succeeds and does not
#    rewrite the marker.
t5_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-attach-match.XXXXXX")"
t5_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir5.XXXXXX")"
t5_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log5.XXXXXX")"
t5_name="dx-side-attach-match1"

if out5a="$(mnt_run "$t5_log" "$t5_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t5_name" "$t5_dir" 2>&1)"; then
    t5a_ok=true
else
    t5a_ok=false
fi
before5="$(checksum_of "$t5_idir/$t5_name.env")"

if out5b="$(mnt_run "$t5_log" "$t5_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t5_name" "$t5_dir" 2>&1)"; then
    t5b_ok=true
else
    t5b_ok=false
fi
after5="$(checksum_of "$t5_idir/$t5_name.env")"

if [ "$t5a_ok" = true ] && [ "$t5b_ok" = true ] && [ -n "$before5" ] && [ "$before5" = "$after5" ]; then
    test_pass "dx-mount re-attach with matching resolution succeeds and never rewrites the manifest marker"
else
    test_fail "dx-mount re-attach with matching resolution (out5a: $out5a) (out5b: $out5b)"
fi

# 6. Fresh creation (resolve mode, no marker): marker created with the full
#    manifest.
t6_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-fresh.XXXXXX")"
t6_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir6.XXXXXX")"
t6_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log6.XXXXXX")"
t6_name="dx-side-fresh1"

if out6="$(mnt_run "$t6_log" "$t6_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t6_name" "$t6_dir" 2>&1)"; then
    t6_ok=true
else
    t6_ok=false
fi

if [ "$t6_ok" = true ] \
    && [ -f "$t6_idir/$t6_name.env" ] \
    && grep -qF "DX_RECORDED_CONTAINER_NAME=$t6_name" "$t6_idir/$t6_name.env" \
    && grep -qF "DX_RECORDED_NIX_VOLUME=${t6_name}-nix" "$t6_idir/$t6_name.env" \
    && grep -qF "DX_RECORDED_PERSIST_VOLUME=${t6_name}-persist" "$t6_idir/$t6_name.env" \
    && grep -qF "DX_RECORDED_BOOTSTRAP_VOLUME=${t6_name}-bootstrap" "$t6_idir/$t6_name.env" \
    && grep -qF "DX_RECORDED_IMAGE=dx-nixos-26.05" "$t6_idir/$t6_name.env" \
    && grep -q "DX_RECORDED_SSH_KEY=" "$t6_idir/$t6_name.env"; then
    test_pass "dx-mount creates a full resource manifest on first attach"
else
    test_fail "dx-mount creates a full resource manifest on first attach (out: $out6)"
fi

# 7. Legacy marker + plain re-attach (resolve mode, matching source): still
#    works and is never auto-upgraded to a manifest.
t7_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-legacy-plain.XXXXXX")"
t7_resolved="$(cd "$t7_dir" && pwd -P)"
t7_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir7.XXXXXX")"
t7_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log7.XXXXXX")"
t7_env="$(dx_mount_clean "$t7_dir" --print-env)"
t7_name="$(printf '%s\n' "$t7_env" | sed -n 's/^export DX_CONTAINER_NAME=//p')"
write_legacy_marker "$t7_idir/$t7_name.env" "$t7_resolved"
before7="$(checksum_of "$t7_idir/$t7_name.env")"

if out7="$(mnt_run "$t7_log" "$t7_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- "$t7_dir" 2>&1)"; then
    t7_ok=true
else
    t7_ok=false
fi
after7="$(checksum_of "$t7_idir/$t7_name.env")"

if [ "$t7_ok" = true ] && [ "$before7" = "$after7" ] && ! grep -q "DX_RECORDED_CONTAINER_NAME" "$t7_idir/$t7_name.env"; then
    test_pass "dx-mount plain re-attach against a legacy marker succeeds without auto-upgrading it"
else
    test_fail "dx-mount plain re-attach against a legacy marker (out: $out7)"
fi

# 8. --container NAME --destroy with no marker: refused with the
#    marker-missing error.
t8_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir8.XXXXXX")"
t8_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log8.XXXXXX")"
t8_name="dx-side-nomarker1"

if out8="$(mnt_run "$t8_log" "$t8_idir" -- --container "$t8_name" --destroy 2>&1)"; then
    t8_ok=true
else
    t8_ok=false
fi

if [ "$t8_ok" = false ] && printf '%s\n' "$out8" | grep -qi "marker"; then
    test_pass "dx-mount --container --destroy refuses without an identity marker"
else
    test_fail "dx-mount --container --destroy refuses without an identity marker (out: $out8)"
fi

# 9. Unsafe names are rejected before any path use, for both --destroy and
#    --print-destroy-plan.
t9_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir9.XXXXXX")"
t9_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log9.XXXXXX")"

for combo in "../x:--destroy" "../x:--print-destroy-plan" "a/b:--destroy" "a/b:--print-destroy-plan"; do
    bad_name="${combo%%:*}"
    bad_flag="${combo#*:}"
    if out9="$(mnt_run "$t9_log" "$t9_idir" -- --container "$bad_name" "$bad_flag" 2>&1)"; then
        test_fail "dx-mount rejects unsafe container name '$bad_name' with $bad_flag (out: $out9)"
    elif [ -z "$(ls -A "$t9_idir" 2>/dev/null)" ]; then
        test_pass "dx-mount rejects unsafe container name '$bad_name' with $bad_flag before touching any path"
    else
        test_fail "dx-mount rejects unsafe container name '$bad_name' with $bad_flag but left files: $(ls -A "$t9_idir")"
    fi
done

if [ ! -s "$t9_log" ]; then
    test_pass "dx-mount never invokes container for a rejected unsafe name"
else
    test_fail "dx-mount never invokes container for a rejected unsafe name"
fi

# 10. Copied/renamed marker: recorded name mismatching NAME is refused for
#     destroy.
t10_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir10.XXXXXX")"
t10_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log10.XXXXXX")"
t10_name="dx-side-renamed1"
write_manifest_marker "$t10_idir/$t10_name.env" "some-other-container-name" "/tmp/renamed-source-$$" \
    dx-nixos-25.11 "${t10_name}-nix" "${t10_name}-persist" "${t10_name}-bootstrap" \
    "${TMPDIR:-/tmp}/renamed_key_$$" "${TMPDIR:-/tmp}/renamed_key_$$.pub"

if out10="$(mnt_run "$t10_log" "$t10_idir" -- --container "$t10_name" --destroy 2>&1)"; then
    t10_ok=true
else
    t10_ok=false
fi

if [ "$t10_ok" = false ] && [ -f "$t10_idir/$t10_name.env" ] && [ ! -s "$t10_log" ]; then
    test_pass "dx-mount refuses to destroy using a marker whose recorded container name does not match"
else
    test_fail "dx-mount refuses to destroy using a mismatched-name marker (out: $out10)"
fi

# 11. Default-resource guard still holds on the manifest path.
t11_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir11.XXXXXX")"
t11_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log11.XXXXXX")"
t11_name="dx-side-defaultguard1"
write_manifest_marker "$t11_idir/$t11_name.env" "$t11_name" "/tmp/defaultguard-source-$$" \
    dx-nixos-25.11 dx-nix "${t11_name}-persist" "${t11_name}-bootstrap" \
    "${TMPDIR:-/tmp}/dg_key_$$" "${TMPDIR:-/tmp}/dg_key_$$.pub"

if out11="$(mnt_run "$t11_log" "$t11_idir" -- --container "$t11_name" --destroy 2>&1)"; then
    t11_ok=true
else
    t11_ok=false
fi

if [ "$t11_ok" = false ] && printf '%s\n' "$out11" | grep -qi "default dx-host resource" && [ ! -s "$t11_log" ]; then
    test_pass "dx-mount --container --destroy refuses a manifest recording a default resource (dx-nix)"
else
    test_fail "dx-mount --container --destroy refuses a manifest recording dx-nix (out: $out11)"
fi

# 12. Legacy marker + existing container (stubbed) + mismatched source: the
#     preserved today's-semantics refusal still fires.
t12_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir12.XXXXXX")"
t12_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log12.XXXXXX")"
t12_name="dx-side-legacyexists1"
t12_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-legacyexists.XXXXXX")"
write_legacy_marker "$t12_idir/$t12_name.env" "/tmp/completely-different-source-$$"

if out12="$(mnt_run "$t12_log" "$t12_idir" DX_MOUNT_STUB_EXISTS_NAME="$t12_name" \
    DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t12_name" "$t12_dir" 2>&1)"; then
    t12_ok=true
else
    t12_ok=false
fi

if [ "$t12_ok" = false ] && printf '%s\n' "$out12" | grep -q "different mount source"; then
    test_pass "dx-mount preserves legacy source-mismatch refusal when --container targets an existing container"
else
    test_fail "dx-mount preserves legacy source-mismatch refusal (out: $out12)"
fi

# 13. Plain dx-mount [DIR] --destroy (derived name) also resolves from the
#     manifest when one exists.
t13_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-plain-manifest.XXXXXX")"
t13_resolved="$(cd "$t13_dir" && pwd -P)"
t13_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir13.XXXXXX")"
t13_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log13.XXXXXX")"
t13_env="$(dx_mount_clean "$t13_dir" --print-env)"
t13_name="$(printf '%s\n' "$t13_env" | sed -n 's/^export DX_CONTAINER_NAME=//p')"
t13_custom_nix="plainmanifest-nix-$$"
write_manifest_marker "$t13_idir/$t13_name.env" "$t13_name" "$t13_resolved" \
    dx-nixos-25.11 "$t13_custom_nix" "${t13_name}-persist" "${t13_name}-bootstrap" \
    "${TMPDIR:-/tmp}/pm_key_$$" "${TMPDIR:-/tmp}/pm_key_$$.pub"

if out13="$(mnt_run "$t13_log" "$t13_idir" -- "$t13_dir" --destroy 2>&1)"; then
    t13_ok=true
else
    t13_ok=false
fi

if [ "$t13_ok" = true ] && grep -qF "$t13_custom_nix" "$t13_log" && ! grep -qF "${t13_name}-nix" "$t13_log"; then
    test_pass "dx-mount [DIR] --destroy (derived name) resolves from the manifest when one exists"
else
    test_fail "dx-mount [DIR] --destroy resolves from the manifest (out: $out13)"
fi

# 14. Attach refused entirely when an existing container has no marker at
#     all (preserved today's semantics).
t14_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir14.XXXXXX")"
t14_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log14.XXXXXX")"
t14_name="dx-side-attach-nomarker1"
t14_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-attach-nomarker.XXXXXX")"

if out14="$(mnt_run "$t14_log" "$t14_idir" DX_MOUNT_STUB_EXISTS_NAME="$t14_name" \
    DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t14_name" "$t14_dir" 2>&1)"; then
    t14_ok=true
else
    t14_ok=false
fi

if [ "$t14_ok" = false ] && printf '%s\n' "$out14" | grep -qi "no mount identity marker"; then
    test_pass "dx-mount refuses to attach to an existing container with no identity marker at all"
else
    test_fail "dx-mount refuses to attach with no identity marker (out: $out14)"
fi

# 15. Attach validation (not just destroy) refuses a copied/renamed manifest
#     marker.
t15_idir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-idir15.XXXXXX")"
t15_log="$(mktemp "${TMPDIR:-/tmp}/dx-mount-log15.XXXXXX")"
t15_name="dx-side-attach-renamed1"
t15_dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-mount-attach-renamed.XXXXXX")"
t15_resolved="$(cd "$t15_dir" && pwd -P)"
write_manifest_marker "$t15_idir/$t15_name.env" "some-other-name-entirely" "$t15_resolved" \
    dx-nixos-25.11 "${t15_name}-nix" "${t15_name}-persist" "${t15_name}-bootstrap" \
    "${TMPDIR:-/tmp}/renamed_attach_key_$$" "${TMPDIR:-/tmp}/renamed_attach_key_$$.pub"
before15="$(checksum_of "$t15_idir/$t15_name.env")"

if out15="$(mnt_run "$t15_log" "$t15_idir" DX_SSH_PORT="$resolve_free_port" DX_MOUNT_TEST_MODE=resolve \
    -- --container "$t15_name" "$t15_dir" 2>&1)"; then
    t15_ok=true
else
    t15_ok=false
fi
after15="$(checksum_of "$t15_idir/$t15_name.env")"

if [ "$t15_ok" = false ] && [ "$before15" = "$after15" ]; then
    test_pass "dx-mount refuses to attach using a manifest marker whose recorded container name does not match"
else
    test_fail "dx-mount refuses to attach using a mismatched-name manifest marker (out: $out15)"
fi

print_summary
exit_with_code
