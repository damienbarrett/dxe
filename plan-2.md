# Plan 2: Fix `dx-start-container` — Bootstrap Deadlock on Standalone Use

## Finding

**File:** `bin/dx-start-container:18` (and `bin/dx-lib.sh:240`)  
**Severity:** High

The container entrypoint (defined in `dx_bootstrap_launch_command` in `dx-lib.sh`) always:
1. Removes `.dx-bootstrap-ready`
2. Creates `.dx-bootstrap-waiting`
3. Blocks in a `while` loop until `.dx-bootstrap-ready` reappears

This means every container restart requires a `dx-sync-bootstrap` call to re-deliver the payload before sshd can start. The `dx` orchestrator does this correctly (`dx-start-container` → `dx-sync-bootstrap` in sequence), but running `dx-start-container` alone — a natural thing for a user to do — leaves the container permanently blocked with no error message.

## Options

### Option A: Have `dx-start-container` call `dx-sync-bootstrap` itself (Recommended)

This makes `dx-start-container` self-contained and safe to call in isolation.

**Changes to `bin/dx-start-container`:**
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dx-lib.sh"

if ! container_exists "$DX_CONTAINER_NAME"; then
    echo "Error: Container $DX_CONTAINER_NAME does not exist. Run ./bin/dx-create-container first." >&2
    exit 1
fi

if container_is_running "$DX_CONTAINER_NAME"; then
    echo "Container $DX_CONTAINER_NAME is already running; skipping start."
    exit 0
fi

echo "Starting container $DX_CONTAINER_NAME..."
container start "$DX_CONTAINER_NAME"

"$SCRIPT_DIR/dx-sync-bootstrap"
```

The `dx` orchestrator's call to `dx-sync-bootstrap` after `dx-start-container` would then be a harmless no-op (the container is already warm), or can be removed from `bin/dx` for clarity. Test: the `dx-start-container` idempotency assertion in test_section9 must still pass.

### Option B: Print a clear warning and required next step

If keeping `dx-start-container` intentionally minimal, add a prominent warning:

```bash
echo "Starting container $DX_CONTAINER_NAME..."
container start "$DX_CONTAINER_NAME"
echo ""
echo "NOTE: The container is now waiting for its bootstrap payload."
echo "      You must run ./bin/dx-sync-bootstrap before SSH will be available."
```

This is weaker than Option A but at least avoids silent deadlocks.

### Option C: Change the entrypoint to not wait on restart

Modify `dx_bootstrap_launch_command` so that if `.dx-bootstrap-ready` already exists (from a previous sync), the container skips the wait and goes directly to `exec bootstrap.sh serve`. This is architecturally cleaner but requires changing the bootstrap protocol.

```bash
# New entrypoint logic (pseudo):
# If .dx-bootstrap-ready exists → exec bootstrap.sh serve immediately
# Otherwise → wait for the marker as before
```

This eliminates the "must sync every restart" requirement, but means the bootstrap is not re-run on every start (which may or may not be desirable).

## Recommended Approach

**Option A** — it's the smallest change and makes the sub-command safe to use in isolation, which is what users expect.

## Steps

1. Update `bin/dx-start-container` to call `dx-sync-bootstrap` at the end (Option A).
2. Decide whether to keep the explicit `dx-sync-bootstrap` call in `bin/dx` (harmless duplicate) or remove it.
3. Update `tests/test_section9_host_scripts.sh` to assert that `dx-start-container` either calls `dx-sync-bootstrap` or documents why it doesn't need to.
4. Update the README to clarify the lifecycle if users are expected to call sub-commands directly.

## Acceptance Criteria

- [ ] Running `./bin/dx-start-container` alone on a stopped container brings sshd up without requiring a separate manual step
- [ ] Running `./bin/dx` (the full orchestrator) still works correctly end-to-end
- [ ] `tests/test_section9_host_scripts.sh` passes
- [ ] If Option A: no duplicate bootstrap sync causes side effects (sync is idempotent, so this should be fine)
