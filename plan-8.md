# Plan 8: Remove Dead Code — `start_ssh` in `bootstrap.sh`

## Finding

**File:** `container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh:421`  
**Severity:** Low (code quality)

`start_ssh()` is defined but never called. The main section starts sshd directly via `exec`:

```bash
echo "Guest bootstrap complete. Starting sshd in foreground..."
SSHD_BIN=$(command -v sshd)
exec "$SSHD_BIN" -D -e -p 2222
```

The `exec` approach is correct: it replaces the bootstrap shell process with sshd, making sshd PID 1 (or the direct child of the entrypoint). `start_ssh` is dead code that will silently rot — any logic added to it in the future will not run.

**Dead function (`bootstrap.sh:421-426`):**
```bash
start_ssh() {
    if ! pgrep -x sshd >/dev/null; then
        echo "Starting sshd..."
        "$(command -v sshd)"
    fi
}
```

## Steps

### 1. Delete the `start_ssh` function

Remove lines 421-426 from `bootstrap.sh`. The `exec` block in the main section is the authoritative sshd start mechanism and does not need a function wrapper.

```bash
# DELETE this block:
start_ssh() {
    if ! pgrep -x sshd >/dev/null; then
        echo "Starting sshd..."
        "$(command -v sshd)"
    fi
}
```

### 2. Verify the exec block is sufficient

Confirm the `exec` at the end of the main section correctly replaces the shell with sshd:

```bash
echo "Guest bootstrap complete. Starting sshd in foreground..."
SSHD_BIN=$(command -v sshd)
exec "$SSHD_BIN" -D -e -p 2222
```

- `-D` keeps sshd in the foreground (required for it to be the persistent process)
- `-e` logs to stderr
- `-p 2222` uses the expected port

This is correct and complete. No wrapper function is needed.

### 3. Add a test assertion to catch future reintroduction

In `tests/test_section9_host_scripts.sh`, add an assertion that `start_ssh` is not present in `bootstrap.sh` (or that if it is present, it is called):

```bash
if grep -q "^start_ssh()" "$BOOTSTRAP"; then
    if ! grep -q "start_ssh$\|start_ssh " "$BOOTSTRAP" | grep -v "^start_ssh()"; then
        test_fail "bootstrap.sh defines start_ssh() but never calls it (dead code)"
    fi
fi
```

Or more simply, assert the function is absent:

```bash
assert_file_not_contains "$BOOTSTRAP" "^start_ssh()" \
    "bootstrap.sh has no dead start_ssh function"
```

### 4. (Optional) Extract sshd startup into a named block if future logic is anticipated

If there is intent to add pre-flight sshd checks in the future, a cleaner pattern would be an inline comment block rather than a dead function:

```bash
# Start sshd in the foreground as the container's main process.
echo "Guest bootstrap complete. Starting sshd in foreground..."
SSHD_BIN="$(command -v sshd)"
exec "$SSHD_BIN" -D -e -p 2222
```

## Acceptance Criteria

- [ ] `start_ssh()` function is removed from `bootstrap.sh`
- [ ] `bootstrap.sh` still starts sshd correctly via `exec` at the end of the main section
- [ ] `bash -n bootstrap.sh` passes syntax check
- [ ] New test assertion (or existing tests) confirm no dead start_ssh function exists
