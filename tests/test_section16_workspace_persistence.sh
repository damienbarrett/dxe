#!/bin/bash
# Section 16: Workspace Persistence Across Destroy
# /workspace lives on its own named volume (dx-workspace) so files survive
# dx-destroy-container + dx-create-container. Volume name and mount path are declared in
# dx-lib.sh; mount is wired in dx-create-container; $WORKSPACE env var is declared
# in home/shell.nix for both POSIX shells (home.sessionVariables) and
# nushell (envFile).
#
# Set DX_TEST_DESTRUCTIVE=1 to enable the end-to-end persistence test that
# actually runs dx-destroy-container and dx-create-container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

LIB_SH="$BASE_DIR/bin/dx-lib.sh"
DX_CREATE="$BASE_DIR/bin/dx-create-container"
DX_CREATE_VOLUMES="$BASE_DIR/bin/dx-create-volumes"
SHELL_NIX="$CONTAINER_DIR/home/shell.nix"

test_section "Section 16: Workspace Persistence"

# ---------- Static checks ----------

assert_file_exists "$LIB_SH" "bin/dx-lib.sh exists"
assert_file_exists "$DX_CREATE" "bin/dx-create-container exists"
assert_file_exists "$SHELL_NIX" "home/shell.nix exists"

assert_grep_in_file "$LIB_SH" \
    "DX_WORKSPACE_VOLUME=.*dx-workspace" \
    "dx-lib.sh declares DX_WORKSPACE_VOLUME (default dx-workspace)"
assert_grep_in_file "$LIB_SH" \
    "DX_WORKSPACE_PATH=.*/workspace" \
    "dx-lib.sh declares DX_WORKSPACE_PATH (default /workspace)"
assert_grep_in_file "$LIB_SH" \
    "DX_NIX_VOLUME=.*dx-nix" \
    "dx-lib.sh declares DX_NIX_VOLUME (default dx-nix)"

assert_grep_in_file "$DX_CREATE" \
    "DX_WORKSPACE_VOLUME" \
    "dx-create-container references DX_WORKSPACE_VOLUME"
assert_grep_in_file "$DX_CREATE" \
    "DX_WORKSPACE_PATH" \
    "dx-create-container references DX_WORKSPACE_PATH"
assert_file_exists "$DX_CREATE_VOLUMES" "bin/dx-create-volumes exists"
assert_grep_in_file "$DX_CREATE_VOLUMES" \
    "container_ensure_volume.*DX_WORKSPACE_VOLUME" \
    "dx-create-volumes ensures the workspace volume exists"
assert_grep_in_file "$DX_CREATE" \
    "DX_NIX_VOLUME" \
    "dx-create-container references DX_NIX_VOLUME"
assert_grep_in_file "$DX_CREATE_VOLUMES" \
    "container_ensure_volume.*DX_NIX_VOLUME" \
    "dx-create-volumes ensures the nix volume exists"
assert_grep_in_file "$DX_CREATE" \
    "[-]-volume[= ].*DX_NIX_VOLUME" \
    "dx-create-container mounts the nix volume"
assert_grep_in_file "$DX_CREATE" \
    "[-]-volume[= ].*DX_WORKSPACE_VOLUME" \
    "dx-create-container mounts the workspace volume"
assert_grep_in_file "$LIB_SH" \
    "DX_BOOTSTRAP_VOLUME=.*dx-bootstrap" \
    "dx-lib.sh declares DX_BOOTSTRAP_VOLUME (default dx-bootstrap)"
assert_grep_in_file "$DX_CREATE" \
    "DX_BOOTSTRAP_VOLUME" \
    "dx-create-container references DX_BOOTSTRAP_VOLUME"
assert_grep_in_file "$DX_CREATE" \
    "[-]-volume[= ].*DX_BOOTSTRAP_VOLUME" \
    "dx-create-container mounts the bootstrap volume"

assert_grep_in_file "$SHELL_NIX" \
    "home\.sessionVariables.*=" \
    "shell.nix has home.sessionVariables"
assert_grep_in_file "$SHELL_NIX" \
    "WORKSPACE[[:space:]]*=" \
    "shell.nix declares WORKSPACE env var (POSIX shells)"
assert_grep_in_file "$SHELL_NIX" \
    '\$env\.WORKSPACE[[:space:]]*=' \
    "shell.nix declares \$env.WORKSPACE in nushell envFile"

# ---------- Runtime checks (require running container + implementation) ----------

# If the static phase is failing because dx-lib.sh hasn't declared the new
# constants yet, runtime checks would just blow up referencing them. Skip.
if [ -z "${DX_WORKSPACE_VOLUME:-}" ] || [ -z "${DX_WORKSPACE_PATH:-}" ]; then
    test_skip "runtime checks (DX_WORKSPACE_VOLUME/PATH not yet declared in dx-lib.sh)"
    print_summary
    exit_with_code
fi

if ! requires_container; then
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

# Volume exists on host
if container volume inspect "$DX_WORKSPACE_VOLUME" >/dev/null 2>&1; then
    test_pass "host has $DX_WORKSPACE_VOLUME volume"
else
    test_fail "host has $DX_WORKSPACE_VOLUME volume"
fi

SSH_BASE_OPTS=(
    "-i" "$DX_SSH_KEY"
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "IdentitiesOnly=yes"
    "-o" "BatchMode=yes"
    "-o" "ConnectTimeout=5"
)
SSH_OPTS=("${SSH_BASE_OPTS[@]}" "-p" "$DX_SSH_PORT")

guest() {
    ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "$@"
}

# /workspace is a separate mount from /
ROOT_FS=$(guest 'bash -lc "stat -c %d /"' 2>/dev/null || echo "")
WS_FS=$(guest 'bash -lc "stat -c %d /workspace"' 2>/dev/null || echo "")
if [ -n "$ROOT_FS" ] && [ -n "$WS_FS" ] && [ "$ROOT_FS" != "$WS_FS" ]; then
    test_pass "/workspace is on a different filesystem from / (mounted from volume)"
else
    test_fail "/workspace is on a different filesystem from / (root_dev=$ROOT_FS ws_dev=$WS_FS)"
fi

# /workspace is writable by dx
if guest 'bash -lc "touch /workspace/.dxe-write-probe && rm -f /workspace/.dxe-write-probe"' 2>/dev/null; then
    test_pass "dx user can write to /workspace"
else
    test_fail "dx user can write to /workspace"
fi

# GitHub CLI config/auth should live on the persistent workspace volume.
if guest 'bash -lc "test -L ~/.config/gh && test \"$(readlink ~/.config/gh)\" = /workspace/home/dx/.config/gh && test -d /workspace/home/dx/.config/gh"' 2>/dev/null; then
    test_pass "GitHub CLI config is linked to persistent workspace storage"
else
    test_fail "GitHub CLI config is linked to persistent workspace storage"
fi

# $WORKSPACE env var is set in nushell after sourcing env.nu
NU_PROBE='source ~/.config/nushell/env.nu
let w = ($env.WORKSPACE? | default "")
print $"WORKSPACE=($w)"'
local_tmp=$(mktemp -t dx_ws_probe.XXXXXX)
remote_path="/tmp/$(basename "$local_tmp").nu"
printf '%s\n' "$NU_PROBE" > "$local_tmp"
SCP_OPTS=("${SSH_BASE_OPTS[@]}" "-P" "$DX_SSH_PORT")
scp "${SCP_OPTS[@]}" "$local_tmp" "dx@127.0.0.1:$remote_path" >/dev/null 2>&1
rm -f "$local_tmp"
NU_OUT=$(ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'nu $remote_path; rc=\$?; rm -f $remote_path; exit \$rc'" 2>&1 || true)
if echo "$NU_OUT" | grep -qx "WORKSPACE=/workspace"; then
    test_pass "nushell exposes \$env.WORKSPACE=/workspace"
else
    test_fail "nushell exposes \$env.WORKSPACE=/workspace (got: $(echo "$NU_OUT" | grep -E "^WORKSPACE=" | head -1))"
fi

# ---------- Destructive E2E (opt-in) ----------

if [ "${DX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    test_skip "E2E destroy/create persistence test (set DX_TEST_DESTRUCTIVE=1 to enable)"
    print_summary
    exit_with_code
fi

MARKER="/workspace/.dxe-persistence-test-$$"
GH_MARKER="/home/dx/.config/gh/.dxe-gh-persistence-test-$$"
guest "bash -lc 'echo persisted > $MARKER && cat $MARKER'" >/dev/null 2>&1
guest "bash -lc 'echo persisted > $GH_MARKER && cat $GH_MARKER'" >/dev/null 2>&1
echo "  Running dx-destroy-container..."
"$BASE_DIR/bin/dx-destroy-container" >/dev/null 2>&1
echo "  Running dx-create-container..."
"$BASE_DIR/bin/dx-create-container" >/dev/null 2>&1
echo "  Running dx-start-container..."
"$BASE_DIR/bin/dx-start-container" >/dev/null 2>&1
wait_for_ssh 180 >/dev/null
# Need to wait a bit longer for sshd to be reachable
for _ in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "true" 2>/dev/null; then
        break
    fi
    sleep 2
done

if guest "bash -lc 'test -f $MARKER && grep -qx persisted $MARKER'" 2>/dev/null; then
    test_pass "/workspace contents survive dx-destroy-container + dx-create-container + dx-start-container"
    guest "bash -lc 'rm -f $MARKER'" >/dev/null 2>&1
else
    test_fail "/workspace contents survive dx-destroy-container + dx-create-container + dx-start-container"
fi

if guest "bash -lc 'test -L ~/.config/gh && test -f $GH_MARKER && grep -qx persisted $GH_MARKER'" 2>/dev/null; then
    test_pass "GitHub CLI config survives dx-destroy-container + dx-create-container + dx-start-container"
    guest "bash -lc 'rm -f $GH_MARKER'" >/dev/null 2>&1
else
    test_fail "GitHub CLI config survives dx-destroy-container + dx-create-container + dx-start-container"
fi

print_summary
exit_with_code
