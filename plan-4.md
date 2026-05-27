# Plan 4: Fix `load_palette` — Silent Empty Palette on Partial Env Vars

## Finding

**File:** `container/aarch64-darwin-apple-container-dx-nixos-25.11/scripts/dx-theme-write-tool-themes.sh:42`  
**Severity:** Medium

When Tinty's hook env vars are present but incomplete (not all 16×3 slots are set), `load_palette_from_env` clears `palette[]` and returns 1. The `|| return 0` on line 42 catches this failure and exits `load_palette` successfully with an empty palette — skipping the `tinty current` fallback that lives in the `else` branch. `validate_palette` then exits the script silently (exit 0, no writes), leaving all theme files stale.

**Current code:**
```bash
load_palette() {
  if [ "$#" -eq 0 ]; then
    if [ -n "${TINTY_SCHEME_PALETTE_BASE00_HEX_R:-}" ]; then
      load_palette_from_env || return 0   # ← Bug: swallows failure, no fallback
    else
      local current
      current="$(tinty current 2>/dev/null || true)"
      if [ -n "$current" ]; then
        load_palette_from_tinty_info "$current"
      fi
    fi
  ...
```

## Steps

### 1. Replace `|| return 0` with a fallback to `tinty current`

When env vars are present but incomplete, fall through to `tinty current` rather than silently succeeding with an empty palette:

```bash
load_palette() {
  if [ "$#" -eq 0 ]; then
    if [ -n "${TINTY_SCHEME_PALETTE_BASE00_HEX_R:-}" ]; then
      if ! load_palette_from_env; then
        # Env vars were present but incomplete — fall back to tinty current.
        local current
        current="$(tinty current 2>/dev/null || true)"
        if [ -n "$current" ]; then
          load_palette_from_tinty_info "$current"
        fi
      fi
    else
      local current
      current="$(tinty current 2>/dev/null || true)"
      if [ -n "$current" ]; then
        load_palette_from_tinty_info "$current"
      fi
    fi
  elif [ "$#" -eq 1 ]; then
    load_palette_from_tinty_info "$1"
  elif [ "$#" -eq 16 ]; then
    palette=( "$@" )
  else
    exit 2
  fi
}
```

### 2. (Optional) Extract the `tinty current` fallback to avoid duplication

```bash
_load_palette_from_tinty_current() {
  local current
  current="$(tinty current 2>/dev/null || true)"
  if [ -n "$current" ]; then
    load_palette_from_tinty_info "$current"
  fi
}

load_palette() {
  if [ "$#" -eq 0 ]; then
    if [ -n "${TINTY_SCHEME_PALETTE_BASE00_HEX_R:-}" ]; then
      load_palette_from_env || _load_palette_from_tinty_current
    else
      _load_palette_from_tinty_current
    fi
  elif [ "$#" -eq 1 ]; then
    load_palette_from_tinty_info "$1"
  elif [ "$#" -eq 16 ]; then
    palette=( "$@" )
  else
    exit 2
  fi
}
```

### 3. Verify `validate_palette` failure path is still silent exit

After the fix, when no palette can be loaded from any source, `palette[]` will be empty, `validate_palette` returns 1, and the script exits 0 (line 76: `exit 0`). This remains intentional — the script is a hook and should not error out just because no theme is available. Confirm this is still the behaviour after the change.

### 4. Add a test case in `tests/test_section14_tinty_theming.sh`

Add a test that simulates partial env vars (BASE00 set, others missing) and verifies the script still falls back to `tinty current` rather than exiting silently:

```bash
# Test: partial TINTY env vars fall back to tinty current
...
```

## Acceptance Criteria

- [ ] When `TINTY_SCHEME_PALETTE_BASE00_HEX_R` is set but the remaining slots are missing, the script falls back to `tinty current` and writes theme files if a current scheme is available
- [ ] When all 16×3 env vars are correctly set, `load_palette_from_env` succeeds as before
- [ ] When no env vars and no `tinty current` scheme is available, the script exits 0 without writing (existing silent-exit behaviour preserved)
- [ ] `tests/test_section14_tinty_theming.sh` passes including the new partial-env-var case
