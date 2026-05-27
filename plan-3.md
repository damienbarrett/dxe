# Plan 3: Fix `dx-sync-bootstrap` — Missing Post-Loop Error Check

## Finding

**File:** `bin/dx-sync-bootstrap:42`  
**Severity:** Medium-High

After the 30-second polling loop that waits for `.dx-bootstrap-waiting` or `.dx-bootstrap-ready`, there is no check for whether `break` was hit or the loop simply timed out. If the container's entrypoint crashes before writing either marker, the script silently proceeds: it pushes a tar payload into an unresponsive container, then `dx-wait-ssh` hangs for up to ~10 minutes with no actionable error.

**Current code (`bin/dx-sync-bootstrap:35-42`):**
```bash
for _ in {1..30}; do
    if container exec "$DX_CONTAINER_NAME" sh -c \
        'test -f "$1/.dx-bootstrap-waiting" || test -f "$1/.dx-bootstrap-ready"' \
        -- "$DX_BOOTSTRAP_PATH" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
# ← No check here. Script continues regardless of loop outcome.
```

## Steps

### 1. Add a post-loop guard

After the loop, run the same marker check one final time and exit with a clear error if neither marker is present:

```bash
for _ in {1..30}; do
    if container exec "$DX_CONTAINER_NAME" sh -c \
        'test -f "$1/.dx-bootstrap-waiting" || test -f "$1/.dx-bootstrap-ready"' \
        -- "$DX_BOOTSTRAP_PATH" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! container exec "$DX_CONTAINER_NAME" sh -c \
    'test -f "$1/.dx-bootstrap-waiting" || test -f "$1/.dx-bootstrap-ready"' \
    -- "$DX_BOOTSTRAP_PATH" >/dev/null 2>&1; then
    echo "Error: Container $DX_CONTAINER_NAME entrypoint never became ready after 30s." >&2
    echo "  The container may have crashed. Check with: container logs $DX_CONTAINER_NAME" >&2
    exit 1
fi
```


### 3. Update the test assertion

In `tests/test_section9_host_scripts.sh`, the existing assertion only checks that the wait loop exists. Add an assertion that the script also handles the timeout case:

```bash
assert_file_contains "$DX_SYNC_BOOTSTRAP" "never became ready" \
    "dx-sync-bootstrap exits with error if container entrypoint never becomes ready"
```

### 4. Consider a configurable timeout

The 30-second wait is currently hardcoded. Consider adding a `DX_BOOTSTRAP_WAIT_TIMEOUT` variable in `dx-lib.sh` (defaulting to 30) so it can be increased for slow machines or CI environments:

```bash
# In dx-lib.sh
export DX_BOOTSTRAP_WAIT_TIMEOUT="${DX_BOOTSTRAP_WAIT_TIMEOUT:-30}"
```

```bash
# In dx-sync-bootstrap
for _ in $(seq 1 "$DX_BOOTSTRAP_WAIT_TIMEOUT"); do
    ...
done
```

Note: The existing test asserts `assert_file_not_contains "$DX_SYNC_BOOTSTRAP" "DX_BOOTSTRAP_WAIT_FOR_GUEST"` — a new timeout variable with a different name is fine.

## Acceptance Criteria

- [ ] If the container entrypoint crashes before writing either marker, `dx-sync-bootstrap` exits non-zero within 31 seconds with a clear error message naming the container and suggesting `container logs`
- [ ] Normal operation (marker written before timeout) is unaffected
- [ ] `tests/test_section9_host_scripts.sh` assertions pass, including the new one
