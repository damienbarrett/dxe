# Plan 1: Fix `container_runtime_pids` — UUID vs Name Mismatch

## Finding

**File:** `bin/dx-lib.sh:154`  
**Severity:** High

`container_runtime_pids` searches the host process table for `--uuid <container-name>` (e.g. `--uuid dx-host`). Apple Container's internal runtime process (`container-runtime-linux`) almost certainly receives an internal UUID4, not the human-readable container name. If that is the case, the entire SIGTERM→SIGKILL escalation path inside `container_stop_bounded` is permanently broken. When a container hangs and neither `container stop` nor `container kill` succeeds, the fallback `container_kill_runtime_process` call will always return "No host runtime process found" and the stuck container can only be killed manually.

## Steps

### 1. Confirm the actual process command line

Run a container and inspect what arguments the runtime process actually receives:

```bash
./bin/dx-start-container
ps -axo pid=,command= | grep container-runtime-linux
```

Capture the exact flags — specifically whether `--uuid` receives the container name (`dx-host`) or a UUID4 (`550e8400-e29b-41d4-a716-...`).

### 2. Update the awk search pattern

**Current code (`bin/dx-lib.sh:153-155`):**
```bash
ps -axo pid=,command= | awk -v name="$name" '
    $0 ~ /container-runtime-linux/ && index($0, "--uuid " name) { print $1 }
'
```

**If the runtime uses the container name as-is** — no change needed, current code is correct.

**If the runtime uses a UUID4** — the pattern must be updated. One option: search by the container name appearing in a different flag (e.g. `--name`, `--bundle`, or a path containing the name). Determine the correct flag from step 1 and update accordingly. Example if `--name <name>` is the right flag:

```bash
ps -axo pid=,command= | awk -v name="$name" '
    $0 ~ /container-runtime-linux/ && index($0, "--name " name) { print $1 }
'
```

**If no reliable textual flag exists** — consider an alternative approach: query the Apple Container API for the container's internal UUID, then search for that UUID in ps output:

```bash
container_runtime_pids() {
    local name="$1"
    local uuid
    uuid="$(container inspect "$name" 2>/dev/null | grep -i '"id"' | head -1 | sed 's/.*"id": *"\([^"]*\)".*/\1/')"
    if [ -z "$uuid" ]; then
        return 0
    fi
    ps -axo pid=,command= | awk -v u="$uuid" '
        $0 ~ /container-runtime-linux/ && index($0, u) { print $1 }
    '
}
```

### 3. Add diagnostic logging

Regardless of the fix, add a debug log so future failures are easier to diagnose:

```bash
container_kill_runtime_process() {
    local name="$1"
    local pids
    pids="$(container_runtime_pids "$name")"

    if [ -z "$pids" ]; then
        echo "No host runtime process found for container $name." >&2
        echo "  (searched: ps -axo pid=,command= | grep container-runtime-linux)" >&2
        return 1
    fi
    ...
}
```

### 4. Add a test assertion

In `tests/test_section9_host_scripts.sh`, add an assertion that verifies the awk search term used is consistent with what Apple Container actually puts in the process command line. At a minimum, document the expected process signature in a comment near the function.

## Acceptance Criteria

- [ ] `ps -axo pid=,command=` output inspected against a running container to confirm the correct search term
- [ ] `container_runtime_pids` returns the correct PID(s) for a running container
- [ ] When a container is deliberately stuck, `container_stop_bounded` successfully terminates it via the runtime-process fallback
- [ ] Diagnostic output makes it clear what was searched if no PID is found
