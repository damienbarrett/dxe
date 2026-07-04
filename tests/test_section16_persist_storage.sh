#!/bin/bash
# Section 16: Persist Storage Across Destroy
# /persist lives on its own named volume (dx-persist) so files survive
# dx-destroy-container + dx-create-container. The volume name is configurable
# through DX_PERSIST_VOLUME; the guest path is fixed at /persist.
#
# Set DX_TEST_DESTRUCTIVE=1 to enable the end-to-end persistence test that
# actually runs dx-destroy-container and dx-create-container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

LIB_SH="$BASE_DIR/bin/dx-lib.sh"
DX_CREATE="$BASE_DIR/bin/dx-create-container"
DX_CREATE_VOLUMES="$BASE_DIR/bin/dx-create-volumes"
DX_MIGRATE="$BASE_DIR/bin/dx-migrate-persist"

test_section "Section 16: Persist Storage"

# ---------- Static checks ----------

assert_file_exists "$LIB_SH" "bin/dx-lib.sh exists"
assert_file_exists "$DX_CREATE" "bin/dx-create-container exists"
assert_file_exists "$DX_CREATE_VOLUMES" "bin/dx-create-volumes exists"
assert_file_exists "$DX_MIGRATE" "bin/dx-migrate-persist exists"
assert_file_exists "$SHELL_NIX" "home/shell.nix exists"

assert_grep_in_file "$LIB_SH" \
    "DX_PERSIST_VOLUME=.*dx-persist" \
    "dx-lib.sh declares DX_PERSIST_VOLUME (default dx-persist)"
assert_file_not_contains "$LIB_SH" \
    "DX_PERSIST_PATH" \
    "dx-lib.sh does not declare DX_PERSIST_PATH"
assert_grep_in_file "$LIB_SH" \
    "DX_WORKSPACE_VOLUME" \
    "dx-lib.sh rejects DX_WORKSPACE_VOLUME"
assert_grep_in_file "$LIB_SH" \
    "DX_WORKSPACE_PATH" \
    "dx-lib.sh rejects DX_WORKSPACE_PATH"
assert_grep_in_file "$LIB_SH" \
    "mkdir -p /persist" \
    "bootstrap launch command creates fixed /persist path"

assert_grep_in_file "$DX_CREATE" \
    "DX_PERSIST_VOLUME" \
    "dx-create-container references DX_PERSIST_VOLUME"
assert_grep_in_file "$DX_CREATE" \
    "[-]-volume[= ].*DX_PERSIST_VOLUME:/persist:rw" \
    "dx-create-container mounts the persist volume at /persist"
assert_file_not_contains "$DX_CREATE" \
    "DX_PERSIST_PATH" \
    "dx-create-container does not consume DX_PERSIST_PATH"
assert_grep_in_file "$DX_CREATE_VOLUMES" \
    "container_ensure_volume.*DX_PERSIST_VOLUME" \
    "dx-create-volumes ensures the persist volume exists"
assert_grep_in_file "$DX_CREATE_VOLUMES" \
    "DX_LEGACY_WORKSPACE_VOLUME" \
    "dx-create-volumes checks legacy migration source"
assert_grep_in_file "$DX_CREATE_VOLUMES" \
    "bin/dx-migrate-persist" \
    "dx-create-volumes tells users to run the migration helper"

assert_grep_in_file "$SHELL_NIX" \
    "PERSIST[[:space:]]*=" \
    "shell.nix declares PERSIST env var (POSIX shells)"
assert_grep_in_file "$SHELL_NIX" \
    '\$env\.PERSIST[[:space:]]*=' \
    "shell.nix declares \$env.PERSIST in nushell envFile"
assert_file_not_contains "$SHELL_NIX" \
    "WORKSPACE[[:space:]]*=" \
    "shell.nix does not declare WORKSPACE"
assert_grep_in_file "$BOOTSTRAP" \
    "ln -sfnT /persist /home/dx/persist" \
    "bootstrap creates /home/dx/persist"
assert_file_not_contains "$BOOTSTRAP" \
    "/home/dx/workspace" \
    "bootstrap does not create /home/dx/workspace"

assert_grep_in_file "$DX_MIGRATE" \
    "DX_LEGACY_WORKSPACE_VOLUME.*dx-workspace" \
    "migration helper defaults the legacy source to dx-workspace"
assert_grep_in_file "$DX_MIGRATE" \
    "cp -a /old/. /new/" \
    "migration helper preserves copied filesystem contents"
assert_grep_in_file "$DX_MIGRATE" \
    ".dxe-persist-migrated-from" \
    "migration helper writes an idempotency sentinel"
assert_grep_in_file "$DX_MIGRATE" \
    "destination volume.*not empty" \
    "migration helper rejects non-empty destination without sentinel"

STALE_MATCHES=$(rg -n '/workspace|DX_WORKSPACE|WORKSPACE|~/workspace|DX_PERSIST_PATH' \
    --hidden -g '!.git' -g '!workspace-persist.md' "$BASE_DIR" 2>/dev/null || true)
UNEXPECTED_STALE=$(printf '%s\n' "$STALE_MATCHES" | grep -vE \
    'bin/dx-lib.sh|bin/dx-create-volumes|bin/dx-migrate-persist|bin/dx-mount|README.md|mount-git.md|tests/test_section9_host_scripts.sh|tests/test_section10_docs.sh|tests/test_section16_persist_storage.sh|tests/test_section18_mount_git.sh' || true)
if [ -z "$UNEXPECTED_STALE" ]; then
    test_pass "no stale workspace runtime references outside explicit legacy docs/tests"
else
    test_fail "unexpected stale workspace references: $(printf '%s' "$UNEXPECTED_STALE" | head -1)"
fi

# ---------- Migration helper integration checks ----------

run_migration_helper_tests() {
    local old="dx-test-legacy-workspace-$$"
    local new="dx-test-persist-$$"
    local collision_old="dx-test-legacy-workspace-collision-$$"
    local collision_new="dx-test-persist-collision-$$"
    local temp_container="dx-migrate-test-$$"
    local cleanup_volumes=("$old" "$new" "$collision_old" "$collision_new")

    cleanup_migration_volumes() {
        local vol
        for vol in "${cleanup_volumes[@]}"; do
            container volume rm "$vol" >/dev/null 2>&1 || true
        done
    }
    trap cleanup_migration_volumes RETURN

    if ! container_image_exists "$DX_IMAGE"; then
        test_skip "migration helper integration checks (image $DX_IMAGE is missing)"
        return
    fi

    container_ensure_volume "$old"
    if ! container run --rm --volume "$old:/old:rw" --entrypoint sh "$DX_IMAGE" -lc \
        "mkdir -p /old/nested/empty && printf data > /old/regular && printf dot > /old/.dotfile && printf nested > /old/nested/file && ln -s regular /old/link"; then
        test_fail "migration fixture can seed legacy volume"
        return
    fi

    if DX_CONTAINER_NAME="$temp_container" DX_LEGACY_WORKSPACE_VOLUME="$old" DX_PERSIST_VOLUME="$new" "$DX_MIGRATE" >/dev/null 2>&1 \
        && container run --rm --volume "$new:/new:ro" --entrypoint sh "$DX_IMAGE" -lc \
            "test \"\$(cat /new/regular)\" = data && test \"\$(cat /new/.dotfile)\" = dot && test \"\$(cat /new/nested/file)\" = nested && test -d /new/nested/empty && test \"\$(readlink /new/link)\" = regular && test \"\$(cat /new/.dxe-persist-migrated-from)\" = '$old'" \
        && container volume inspect "$old" >/dev/null 2>&1; then
        test_pass "migration helper copies files, dotfiles, symlinks, empty dirs, and preserves legacy volume"
    else
        test_fail "migration helper copies files, dotfiles, symlinks, empty dirs, and preserves legacy volume"
    fi

    if DX_CONTAINER_NAME="$temp_container" DX_LEGACY_WORKSPACE_VOLUME="$old" DX_PERSIST_VOLUME="$new" "$DX_MIGRATE" >/dev/null 2>&1; then
        test_pass "migration helper is idempotent when sentinel matches"
    else
        test_fail "migration helper is idempotent when sentinel matches"
    fi

    container_ensure_volume "$collision_old"
    container_ensure_volume "$collision_new"
    container run --rm --volume "$collision_old:/old:rw" --entrypoint sh "$DX_IMAGE" -lc "printf source > /old/file" >/dev/null 2>&1
    container run --rm --volume "$collision_new:/new:rw" --entrypoint sh "$DX_IMAGE" -lc "printf existing > /new/file" >/dev/null 2>&1
    if DX_CONTAINER_NAME="$temp_container" DX_LEGACY_WORKSPACE_VOLUME="$collision_old" DX_PERSIST_VOLUME="$collision_new" "$DX_MIGRATE" >/dev/null 2>&1; then
        test_fail "migration helper rejects non-empty destination without sentinel"
    else
        test_pass "migration helper rejects non-empty destination without sentinel"
    fi
}

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "migration helper integration checks (--skip-integration)"
else
    run_migration_helper_tests
fi

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "live persistence guest runtime checks (--skip-integration)"
    print_summary
    exit_with_code
fi

# ---------- Runtime checks (require running container + implementation) ----------

if [ -z "${DX_PERSIST_VOLUME:-}" ]; then
    test_skip "runtime checks (DX_PERSIST_VOLUME not declared in dx-lib.sh)"
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
if container volume inspect "$DX_PERSIST_VOLUME" >/dev/null 2>&1; then
    test_pass "host has $DX_PERSIST_VOLUME volume"
else
    test_fail "host has $DX_PERSIST_VOLUME volume"
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

# /persist is a separate mount from /
ROOT_FS=$(guest 'bash -lc "stat -c %d /"' 2>/dev/null || echo "")
PERSIST_FS=$(guest 'bash -lc "stat -c %d /persist"' 2>/dev/null || echo "")
if [ -n "$ROOT_FS" ] && [ -n "$PERSIST_FS" ] && [ "$ROOT_FS" != "$PERSIST_FS" ]; then
    test_pass "/persist is on a different filesystem from / (mounted from volume)"
else
    test_fail "/persist is on a different filesystem from / (root_dev=$ROOT_FS persist_dev=$PERSIST_FS)"
fi

# /persist is writable by dx
if guest 'bash -lc "touch /persist/.dxe-write-probe && rm -f /persist/.dxe-write-probe"' 2>/dev/null; then
    test_pass "dx user can write to /persist"
else
    test_fail "dx user can write to /persist"
fi

# The ~/persist/home parent is user-visible and must not remain root-owned
# after bootstrap creates /persist/home/dx.
if guest 'bash -lc "probe=/persist/home/.dxe-write-probe-\$\$; mkdir \"\$probe\" && rmdir \"\$probe\""' 2>/dev/null; then
    test_pass "dx user can create directories under /persist/home"
else
    test_fail "dx user can create directories under /persist/home"
fi

# GitHub CLI config/auth should live on the persistent volume.
if guest 'bash -lc "test -L ~/.config/gh && test \"$(readlink ~/.config/gh)\" = /persist/home/dx/.config/gh && test -d /persist/home/dx/.config/gh"' 2>/dev/null; then
    test_pass "GitHub CLI config is linked to persistent storage"
else
    test_fail "GitHub CLI config is linked to persistent storage"
fi

# $PERSIST env var is set in nushell after sourcing env.nu
NU_PROBE='source ~/.config/nushell/env.nu
let p = ($env.PERSIST? | default "")
print $"PERSIST=($p)"'
local_tmp=$(mktemp -t dx_persist_probe.XXXXXX)
remote_path="/tmp/$(basename "$local_tmp").nu"
printf '%s\n' "$NU_PROBE" > "$local_tmp"
SCP_OPTS=("${SSH_BASE_OPTS[@]}" "-P" "$DX_SSH_PORT")
scp "${SCP_OPTS[@]}" "$local_tmp" "dx@127.0.0.1:$remote_path" >/dev/null 2>&1
rm -f "$local_tmp"
NU_OUT=$(ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'nu $remote_path; rc=\$?; rm -f $remote_path; exit \$rc'" 2>&1 || true)
if echo "$NU_OUT" | grep -qx "PERSIST=/persist"; then
    test_pass "nushell exposes \$env.PERSIST=/persist"
else
    test_fail "nushell exposes \$env.PERSIST=/persist (got: $(echo "$NU_OUT" | grep -E "^PERSIST=" | head -1))"
fi

# ---------- Destructive E2E (opt-in) ----------

if [ "${DX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    test_skip "E2E destroy/create persistence test (set DX_TEST_DESTRUCTIVE=1 to enable)"
    print_summary
    exit_with_code
fi

MARKER="/persist/.dxe-persistence-test-$$"
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
for _ in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "true" 2>/dev/null; then
        break
    fi
    sleep 2
done

if guest "bash -lc 'test -f $MARKER && grep -qx persisted $MARKER'" 2>/dev/null; then
    test_pass "/persist contents survive dx-destroy-container + dx-create-container + dx-start-container"
    guest "bash -lc 'rm -f $MARKER'" >/dev/null 2>&1
else
    test_fail "/persist contents survive dx-destroy-container + dx-create-container + dx-start-container"
fi

if guest "bash -lc 'test -L ~/.config/gh && test -f $GH_MARKER && grep -qx persisted $GH_MARKER'" 2>/dev/null; then
    test_pass "GitHub CLI config survives dx-destroy-container + dx-create-container + dx-start-container"
    guest "bash -lc 'rm -f $GH_MARKER'" >/dev/null 2>&1
else
    test_fail "GitHub CLI config survives dx-destroy-container + dx-create-container + dx-start-container"
fi

print_summary
exit_with_code
