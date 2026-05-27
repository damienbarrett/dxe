# Plan 5: Fix `dx_get_host_timezone` — Silent Empty Timezone

## Finding

**File:** `bin/dx-lib.sh:244`  
**Severity:** Medium

`dx_get_host_timezone` relies on `readlink /etc/localtime` to extract the timezone name. On any macOS where `/etc/localtime` is absent, is a regular file (not a symlink), or the symlink does not contain the string `zoneinfo/`, the function silently returns an empty string. `HOST_TZ=""` is then baked into the container's environment at create time. In `bootstrap.sh`, `configure_timezone` is guarded by `if [ -n "${HOST_TZ:-}" ]`, so it silently skips — the guest runs UTC with no warning.

**Current code (`bin/dx-lib.sh:243-245`):**
```bash
dx_get_host_timezone() {
    readlink /etc/localtime | sed 's#^.*/zoneinfo/##'
}
```

## Steps

### 1. Add a fallback for non-symlink `/etc/localtime`

On macOS, `/etc/localtime` is almost always a symlink into `/var/db/timezone/zoneinfo/`, but on some setups it may be a copy. A `systemsetup -gettimezone` fallback covers both cases:

```bash
dx_get_host_timezone() {
    local tz

    # Primary: follow the /etc/localtime symlink
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')"

    # Fallback: use macOS systemsetup when /etc/localtime is absent or a regular file
    if [ -z "$tz" ] && command -v systemsetup >/dev/null 2>&1; then
        tz="$(systemsetup -gettimezone 2>/dev/null | sed 's/^Time Zone: //')"
    fi

    # Second fallback: read /etc/timezone (Linux-style, present in some VMs)
    if [ -z "$tz" ] && [ -f /etc/timezone ]; then
        tz="$(cat /etc/timezone)"
    fi

    if [ -z "$tz" ]; then
        echo "Warning: Could not determine host timezone; defaulting to UTC." >&2
        tz="UTC"
    fi

    printf '%s\n' "$tz"
}
```

### 2. Emit a warning at the use-site if HOST_TZ is empty

Even with the improved function, add a guard in `bin/dx-create-container` so that an unexpected empty value is visible:

```bash
HOST_TZ="$(dx_get_host_timezone)"
if [ -z "$HOST_TZ" ]; then
    echo "Warning: HOST_TZ is empty; container will run in UTC." >&2
fi
```

### 3. Add a unit test in the test suite

In `tests/test_section11_validate_fresh.sh` or a new `test_section9_host_scripts.sh` assertion, verify that `dx_get_host_timezone` returns a non-empty string on the current host:

```bash
source "$BIN_DIR/dx-lib.sh"
TZ="$(dx_get_host_timezone)"
if [ -n "$TZ" ]; then
    test_pass "dx_get_host_timezone returns non-empty timezone: $TZ"
else
    test_fail "dx_get_host_timezone returned empty string"
fi
```

### 4. Document the variable in `default.env`

Update `tests/profiles/default.env` to include a commented-out `HOST_TZ` entry explaining that it is auto-detected:

```bash
# export HOST_TZ=""  # Auto-detected from host via dx_get_host_timezone.
#                    # Override only if auto-detection is wrong on your system.
```

## Acceptance Criteria

- [ ] `dx_get_host_timezone` returns a non-empty IANA timezone string on a standard macOS install
- [ ] `dx_get_host_timezone` returns `UTC` (with a warning) rather than an empty string on an unusual host
- [ ] `bin/dx-create-container` logs a warning if `HOST_TZ` is empty before container creation
- [ ] Test assertion for non-empty return value passes in CI
