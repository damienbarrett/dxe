# Plan 6: Fix `configure_timezone` — Runs Before tzdata Is Available

## Finding

**File:** `container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh:129`  
**Severity:** Medium

`configure_timezone` is called after `configure_guest`, which runs Home Manager activation and installs the nix profile (including `tzdata`). However, on first boot, the profile activation may not have fully settled by the time `configure_timezone` runs — or the order means `configure_timezone` runs within `configure_guest` before Home Manager completes. The function calls `run_as_dx 'printf %s "${TZDIR:-}"'` which requires a fully initialised dx login shell with the nix profile available. If `tzdata` is not yet on the path, `TZDIR` is empty, the fallback path `/home/dx/.nix-profile/share/zoneinfo` may also not exist, and the guest silently stays in UTC.

**Call order in main section:**
```
install_essentials
setup_nix_volume
configure_nix_daemon
create_user
setup_workspace
configure_ssh
configure_guest        ← Home Manager runs here
configure_timezone     ← Called after, but may still be too early on fresh boot
verify_guest_tools
```

**Current `configure_timezone` (`bootstrap.sh:124-140`):**
```bash
configure_timezone() {
    if [ -n "${HOST_TZ:-}" ]; then
        local tz_dir
        tz_dir="$(run_as_dx 'printf %s "${TZDIR:-}"')"
        if [ -z "$tz_dir" ]; then
            tz_dir="/home/dx/.nix-profile/share/zoneinfo"
        fi
        local tz_file="$tz_dir/$HOST_TZ"
        if [ -f "$tz_file" ]; then
            ln -sf "$tz_file" /etc/localtime
        else
            echo "Warning: Timezone file $tz_file not found. Is tzdata in dxPackages?"
        fi
    fi
}
```

## Steps

### 1. Resolve `TZDIR` from the nix store directly, not from the user profile

Instead of asking the dx user shell for `TZDIR`, locate `tzdata` in the nix store directly. This removes the dependency on the login shell being fully initialised:

```bash
configure_timezone() {
    if [ -z "${HOST_TZ:-}" ]; then
        return 0
    fi

    local tz_file=""

    # 1. Try the nix store tzdata share path (most reliable — no profile needed)
    local nix_tzdata_dir
    nix_tzdata_dir="$(find /nix/store -maxdepth 2 -name "zoneinfo" -type d 2>/dev/null | \
        grep tzdata | head -1)"
    if [ -n "$nix_tzdata_dir" ] && [ -f "$nix_tzdata_dir/$HOST_TZ" ]; then
        tz_file="$nix_tzdata_dir/$HOST_TZ"
    fi

    # 2. Try the dx nix-profile path (available once Home Manager has activated)
    if [ -z "$tz_file" ] && [ -f "/home/dx/.nix-profile/share/zoneinfo/$HOST_TZ" ]; then
        tz_file="/home/dx/.nix-profile/share/zoneinfo/$HOST_TZ"
    fi

    # 3. Try asking the dx login shell for TZDIR (original approach, last resort)
    if [ -z "$tz_file" ]; then
        local tz_dir
        tz_dir="$(run_as_dx 'printf %s "${TZDIR:-}"' 2>/dev/null || true)"
        if [ -n "$tz_dir" ] && [ -f "$tz_dir/$HOST_TZ" ]; then
            tz_file="$tz_dir/$HOST_TZ"
        fi
    fi

    if [ -n "$tz_file" ]; then
        echo "Configuring timezone to $HOST_TZ..."
        ln -sf "$tz_file" /etc/localtime
    else
        echo "Warning: Timezone file for $HOST_TZ not found. Guest will run in UTC." >&2
        echo "  Ensure tzdata is in dxPackages in home/tools.nix." >&2
    fi
}
```

### 2. Move `configure_timezone` to after `verify_guest_tools`

By placing it after `verify_guest_tools`, the nix profile is confirmed to be working before the timezone is set:

```bash
# Main
install_essentials
setup_nix_volume
configure_nix_daemon
create_user
setup_workspace
configure_ssh
configure_guest
verify_guest_tools
configure_timezone   # ← Moved here: profile is guaranteed available
```

This is a minor ordering change with no functional impact on the other steps.

### 3. Ensure `tzdata` is explicitly in `home/tools.nix`

Verify that `tzdata` is an unconditional entry in `home/tools.nix` (not behind any optional flag), so the nix store approach in step 1 reliably finds it:

```nix
# In home/tools.nix — ensure this is present unconditionally
pkgs.tzdata
```

### 4. Add a test assertion

In `tests/test_section3_bootstrap.sh` or `test_section6_tools.sh`, verify that after bootstrap the guest timezone matches the host:

```bash
# HOST_TZ should be set in the container env
GUEST_TZ=$(ssh ... "cat /etc/localtime | md5sum" 2>/dev/null || true)
# Compare to the host timezone file md5
```

## Acceptance Criteria

- [ ] On first-boot factory-reset container, `/etc/localtime` is correctly set to the host timezone
- [ ] `configure_timezone` does not depend on the dx login shell being initialised to find zoneinfo files
- [ ] Warning is printed (not a silent skip) if the timezone file genuinely cannot be found
- [ ] `tzdata` is confirmed to be an unconditional nix package dependency
