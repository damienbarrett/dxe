#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.2 (implementer unit cases): host-side refusals and NAS-script edge
# arms the acceptance suite (tests/test_persist_dir_ops.sh) does not reach.
# Everything runs against the NAS fake on a fixture root under TMPDIR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.2: NAS directory operation edge arms"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
unset DX_PERSIST_HOST_MOUNT_SENTINEL
GUEST="dx-fix"
TEXT="$(dx_persist_marker_format "$GUEST" ready "" 2026-10-11T08:00:00Z)"

ROOT="$(persist_fixture_root_create "$SCRATCH")"
TOOLS="$(persist_fixture_nas_create "$ROOT" "$SCRATCH")"
export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
PATH="$TOOLS:$PATH"
export PATH
tree_of() { find . | LC_ALL=C sort; }

fails() { # LABEL CMD...  (non-zero status expected)
    local label="$1"
    shift
    if "$@" </dev/null >/dev/null 2>"$SCRATCH/err"; then test_fail "$label"; else test_pass "$label"; fi
}

# Invalid guest names never reach the NAS (they are path components).
fails "probe refuses a guest with a slash" dx_runtime_host_dir_probe "$ROOT" "a/b"
fails "probe refuses a dotdot guest" dx_runtime_host_dir_probe "$ROOT" ".."
fails "create refuses a guest with a slash" dx_runtime_host_dir_create "$ROOT" "../x" "$TEXT"
if grep -Fq "invalid guest name" "$SCRATCH/err"; then test_pass "the refusal names the guest"; else test_fail "the refusal names the guest"; fi
(cd "$ROOT" && [ "$(tree_of)" = "." ]) && test_pass "nothing was created for bad guests" || test_fail "nothing was created for bad guests"

# A regular file where the persist directory should be: not a directory.
mkdir -p "$ROOT/dxe/$GUEST"
: >"$ROOT/dxe/$GUEST/persist"
fails "probe: a file at the persist path is refused" dx_runtime_host_dir_probe "$ROOT" "$GUEST"
if grep -Fq "not a directory" "$SCRATCH/err"; then test_pass "probe: the file case says not a directory"; else test_fail "probe: the file case says not a directory"; fi
fails "create: a file at the persist path is refused" dx_runtime_host_dir_create "$ROOT" "$GUEST" "$TEXT"
rm -f "$ROOT/dxe/$GUEST/persist"

# A symlink in the marker slot is not read through.
mkdir -p "$ROOT/dxe/$GUEST/persist"
: >"$ROOT/target"
ln -s ../../../target "$ROOT/dxe/$GUEST/persist/.dxe-persist-dir"
out="$(dx_runtime_host_dir_probe "$ROOT" "$GUEST" </dev/null 2>/dev/null)"
if grep -Fq "marker=absent" <<<"$out"; then test_pass "probe: a symlinked marker reads as absent"; else test_fail "probe: a symlinked marker reads as absent"; fi

# A symlinked dxe or guest level is refused by create, nothing written through.
ROOT2="$(persist_fixture_root_create "$SCRATCH")"
TOOLS="$(persist_fixture_nas_create "$ROOT2" "$SCRATCH")"
PATH="$TOOLS:$PATH"
mkdir "$ROOT2/elsewhere"
ln -s elsewhere "$ROOT2/dxe"
fails "create: a symlinked dxe is refused" dx_runtime_host_dir_create "$ROOT2" "$GUEST" "$TEXT"
if [ -z "$(find "$ROOT2/elsewhere" -mindepth 1 | head -n1)" ]; then test_pass "create: nothing was written through the symlink"; else test_fail "create: nothing was written through the symlink"; fi
rm -f "$ROOT2/dxe"
mkdir "$ROOT2/dxe"
ln -s ../elsewhere "$ROOT2/dxe/$GUEST"
fails "create: a symlinked guest level is refused" dx_runtime_host_dir_create "$ROOT2" "$GUEST" "$TEXT"

# marker_write refuses a symlinked persist directory and a failing cat/mv path.
mkdir -p "$ROOT2/real"
ln -s real "$ROOT2/linked"
fails "marker_write: a symlinked directory is refused" dx_runtime_host_dir_marker_write "$ROOT2/linked" "$TEXT"
if [ -z "$(find "$ROOT2/real" -mindepth 1 | head -n1)" ]; then test_pass "marker_write: nothing written through the symlink"; else test_fail "marker_write: nothing written through the symlink"; fi

# create: a failing mv leaves no half-built directory behind.
ROOT3="$(persist_fixture_root_create "$SCRATCH")"
TOOLS="$(persist_fixture_nas_create "$ROOT3" "$SCRATCH")"
PATH="$TOOLS:$PATH"
STUBS="$SCRATCH/stub-bin"
mkdir -p "$STUBS"
fake_tool_write "$STUBS" mv 'exit 1'
(
    export DXE_FAKE_SSH_REMOTE_PATH="$STUBS:$PATH"
    fails "create: a failing mv is non-zero" dx_runtime_host_dir_create "$ROOT3" "$GUEST" "$TEXT"
)
if [ -z "$(find "$ROOT3/dxe/$GUEST" -mindepth 1 2>/dev/null | head -n1)" ]; then test_pass "create: a failing mv leaves no persist directory or temp directory"; else test_fail "create: a failing mv leaves no persist directory or temp directory"; fi

print_summary
exit_with_code
