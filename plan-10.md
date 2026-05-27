# Plan 10: Fix `DX_NIX_DISK_SIZE` — Exported Variable Silently Ignored

## Finding

**File:** `bin/dx-lib.sh:30-31`  
**Severity:** Low

`DX_NIX_DISK_SIZE` is exported as a configurable default in `dx-lib.sh`:

```bash
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"
```

However, `bootstrap.sh` hardcodes `64G` when creating the sparse image file for the Nix store:

```bash
# bootstrap.sh:76
truncate -s 64G "$dev"
```

`dx-nix-disk` (the host script that would consume `DX_NIX_DISK_SIZE`) is never called from the `dx` lifecycle or any other script. The result: a user who sets `DX_NIX_DISK_SIZE=100G` in `.env` sees no effect whatsoever — bootstrap always allocates 64 GB regardless.

Additionally, `DX_NIX_DISK` is exported but similarly unused in the normal flow:

```bash
export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
```

## Options

### Option A: Wire `DX_NIX_DISK_SIZE` through to `bootstrap.sh` (Recommended)

Pass `DX_NIX_DISK_SIZE` as an environment variable when creating the container, so `bootstrap.sh` can read it:

**In `bin/dx-create-container`**, add to `CREATE_FLAGS`:
```bash
CREATE_FLAGS=(
    ...
    -e "DX_NIX_DISK_SIZE=$DX_NIX_DISK_SIZE"
    ...
)
```

**In `bootstrap.sh` `setup_nix_volume`**, replace the hardcoded `64G`:
```bash
local disk_size="${DX_NIX_DISK_SIZE:-64G}"
...
echo "Creating ${disk_size} sparse image file at $dev..."
truncate -s "$disk_size" "$dev"
```

This makes the variable actually do what it documents.

### Option B: Remove `DX_NIX_DISK_SIZE` and `DX_NIX_DISK` from `dx-lib.sh`

If `dx-nix-disk` is not part of the normal workflow and the sparse image size is intentionally fixed at 64 GB, remove the misleading exports to avoid false expectations:

```bash
# Remove from dx-lib.sh:
# export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
# export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"
```

Update `tests/profiles/default.env` to remove the commented-out references.

### Option C: Document the limitation clearly

If neither of the above is immediately desirable, at minimum add a comment in `dx-lib.sh`:

```bash
# DX_NIX_DISK_SIZE: target size for the Nix store image.
# NOTE: This value is not currently passed to bootstrap.sh, which hardcodes 64G.
# To change the image size, edit bootstrap.sh setup_nix_volume directly.
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-64G}"
```

And update `default.env` to match the hardcoded 64G default.

## Recommended Approach

**Option A** — honour the variable the user can already set. The change is small (one `-e` flag in `dx-create-container`, one variable substitution in `bootstrap.sh`) and makes the configuration surface consistent.

## Steps

1. Add `-e "DX_NIX_DISK_SIZE=$DX_NIX_DISK_SIZE"` to `CREATE_FLAGS` in `bin/dx-create-container`.
2. Update `setup_nix_volume` in `bootstrap.sh` to use `"${DX_NIX_DISK_SIZE:-64G}"` instead of the hardcoded `64G`.
3. Update `default.env` comment to show `DX_NIX_DISK_SIZE=64G` as the effective default.
4. Add a test assertion in `tests/test_section9_host_scripts.sh`:
   ```bash
   assert_file_contains "$BIN_DIR/dx-create-container" "DX_NIX_DISK_SIZE" \
       "dx-create-container passes DX_NIX_DISK_SIZE into container environment"
   ```
5. Add a test assertion that `bootstrap.sh` does not hardcode the image size:
   ```bash
   assert_file_not_contains "$BOOTSTRAP" 'truncate -s 64G' \
       "bootstrap.sh uses configurable disk size, not hardcoded 64G"
   ```

## Acceptance Criteria

- [ ] Setting `DX_NIX_DISK_SIZE=100G` in `.env` results in a 100 GB sparse image being created in `setup_nix_volume`
- [ ] Default behaviour (no `DX_NIX_DISK_SIZE` set) still creates a 64 GB image
- [ ] `default.env` accurately documents the default value
- [ ] Test assertions for both `dx-create-container` and `bootstrap.sh` pass
