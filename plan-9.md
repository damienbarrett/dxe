# Plan 9: Fix D-Bus Address Quoting in `setup_keyring_service`

## Finding

**File:** `container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh:352`  
**Severity:** Low

`setup_keyring_service` starts gnome-keyring by passing a D-Bus address through `run_as_dx`, which wraps the command in `bash -l -c "$cmd"`. The bus address is interpolated directly into the command string:

```bash
gk_out="$(run_as_dx "DBUS_SESSION_BUS_ADDRESS='$bus_addr' echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null" || true)"
```

`run_as_dx` is defined as:
```bash
run_as_dx() {
    local cmd="$1"
    setpriv ... bash -l -c "$cmd"
}
```

If `$bus_addr` contains characters that are special to the shell (in particular spaces, which are technically valid in D-Bus addresses per the spec), the `bash -l -c "$cmd"` evaluation will split the address mid-token. In practice, standard D-Bus socket addresses do not contain spaces, but the code is fragile and will silently fail (stderr is redirected to `/dev/null`) if an unexpected address is produced.

The same pattern exists in `dx-ai.sh:94-97`, where the D-Bus session is started and the address is captured.

## Steps

### 1. Export the bus address via the environment rather than interpolating it into the command string

Instead of embedding `$bus_addr` in the shell command string, pass it as an environment variable to `run_as_dx`:

```bash
# In setup_keyring_service — replace the gk_out line:
local gk_out
gk_out="$(DBUS_SESSION_BUS_ADDRESS="$bus_addr" run_as_dx \
    "echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null" \
    || true)"
```

This requires `run_as_dx` to pass the calling environment's exports through to the inner shell. Since `setpriv ... env HOME=... bash -l -c "$cmd"` is used, prepend the variable:

```bash
run_as_dx() {
    local cmd="$1"
    setpriv --reuid=dx --regid=dx --init-groups \
        env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        bash -l -c "$cmd"
}
```

Or more simply for this specific use case, wrap the address in `printf '%q'` before interpolation:

```bash
local bus_addr_quoted
bus_addr_quoted="$(printf '%q' "$bus_addr")"
gk_out="$(run_as_dx "DBUS_SESSION_BUS_ADDRESS=$bus_addr_quoted echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null" || true)"
```

### 2. Remove the stderr redirection for debugging during development

The `2>/dev/null` on the gnome-keyring-daemon line means any failure is completely silent. During initial testing, remove it to see actual error output, then restore it (or replace with a log file redirect) once the command is confirmed to work:

```bash
gk_out="$(run_as_dx "..." 2>&1 | tee -a /tmp/dx-keyring-setup.log || true)"
```

For production: keep `2>/dev/null` but add a check on `$gk_out` and log a warning if the keyring did not start.

### 3. Apply the same fix to `dx-ai.sh`

The same quoting concern applies in `dx-ai.sh:94-98` where `DBUS_SESSION_BUS_ADDRESS` is captured and used. That script runs as the dx user so the risk is lower (no `run_as_dx` wrapper), but use `printf '%q'` or environment passing consistently.

### 4. Add a diagnostic message when keyring setup fails

Currently, keyring failure is completely invisible. Add a check on the bus address after the daemon starts:

```bash
if [ -z "$bus_addr" ]; then
    echo "Warning: D-Bus session bus did not start. agy OAuth tokens will not persist." >&2
fi
```

## Acceptance Criteria

- [ ] D-Bus address is passed to gnome-keyring-daemon without shell interpolation risk
- [ ] Keyring setup failure produces a visible warning rather than silent skip
- [ ] Fix applied consistently in both `bootstrap.sh` and `dx-ai.sh`
- [ ] `bash -n bootstrap.sh` and `bash -n dx-ai.sh` pass syntax checks
