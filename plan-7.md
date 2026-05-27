# Plan 7: Fix `setup_nix_volume` — Unanchored `findmnt` Idempotency Check

## Finding

**File:** `container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh:43`  
**Severity:** Low

The idempotency guard for the Nix volume setup uses:

```bash
if findmnt -n -o TARGET,FSTYPE /nix | grep -q "$fs_type"; then
    echo "/nix is already a $fs_type mount. Skipping setup."
    return 0
fi
```

`grep -q "$fs_type"` matches `fs_type` as an unanchored substring. If `fs_type="ext4"` and the mount output contains a string like `btrfs_ext4_compat` or any other type that happens to contain the pattern, the guard could spuriously skip setup. More concretely: if the kernel falls back to `ext4` but the volume is already formatted as `btrfs`, the grep would correctly not match and re-formatting would be attempted on a live mount — a data-loss risk.

## Steps

### 1. Anchor the grep to match the exact FSTYPE field

`findmnt -n -o TARGET,FSTYPE /nix` produces output like:
```
/nix    btrfs
```

Match the filesystem type as an exact word at the end of the line:

```bash
if findmnt -n -o FSTYPE /nix 2>/dev/null | grep -qx "$fs_type"; then
    echo "/nix is already a $fs_type mount. Skipping setup."
    return 0
fi
```

Using `-o FSTYPE` (not `TARGET,FSTYPE`) and `grep -x` (match the entire line exactly) eliminates substring ambiguity.

### 2. Alternatively, use `findmnt --output FSTYPE --noheadings` with direct comparison

```bash
local current_fstype
current_fstype="$(findmnt -n -o FSTYPE /nix 2>/dev/null || true)"
if [ "$current_fstype" = "$fs_type" ]; then
    echo "/nix is already a $fs_type mount. Skipping setup."
    return 0
fi
```

String equality is more explicit than grep pattern matching and has no substring-match risk. **This is the recommended approach.**

### 3. Also guard against /nix being mounted with an unexpected type

If `/nix` is mounted but with a *different* type than what we want (e.g. `btrfs` is wanted but `ext4` is present), the current code falls through and attempts re-formatting — which requires `/nix` to be unmounted first. Add an explicit check and error:

```bash
local current_fstype
current_fstype="$(findmnt -n -o FSTYPE /nix 2>/dev/null || true)"

if [ "$current_fstype" = "$fs_type" ]; then
    echo "/nix is already a $fs_type mount. Skipping setup."
    return 0
elif [ -n "$current_fstype" ]; then
    echo "Warning: /nix is mounted as $current_fstype, expected $fs_type. Proceeding with re-format." >&2
    echo "  If this is unexpected, check that the dx-nix volume was not manually formatted." >&2
fi
```

### 4. Update the test

In `tests/test_section14_tinty_theming.sh` or the bootstrap test section, add a lint check that `setup_nix_volume` uses exact FSTYPE comparison rather than a bare `grep -q`:

```bash
assert_file_not_contains "$BOOTSTRAP" 'grep -q "$fs_type"' \
    "setup_nix_volume uses exact FSTYPE match, not substring grep"
```

## Acceptance Criteria

- [ ] `setup_nix_volume` correctly skips setup when `/nix` is already mounted with the expected filesystem type
- [ ] `setup_nix_volume` does not skip setup when `/nix` is mounted with a *different* type
- [ ] No substring-match false positive is possible with any valid FSTYPE string
- [ ] Behaviour on first boot (no `/nix` mount) is unchanged
