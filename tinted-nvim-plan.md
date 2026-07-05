# Plan: Migrate Neovim theming to the new `tinted-nvim` API

> **Status (2026-07-05):** the tinted-nvim migration (Changes 1–2) was
> **implemented in commit `37efce9`** and deployed to `dx-host`; committed
> *repeatable* runtime coverage is being added with the nvim payload-polish
> slice. Change 3 (the `project.nvim` warning) is now owned by finding
> **R-13** in `complete-bump-review.md` / the "Remove project.nvim's
> empty-history warning" section of `complete-bump-plan.md` — see there, not
> this document, for the accepted fix. Retained as implemented design history.

## Problem

Launching `nvim` in the `dx` guest prints, on the intro screen:

```
Deprecated module 'tinted-colorscheme' was loaded.
This plugin was rewritten and renamed to 'tinted-nvim', and its API has changed.
Please review the documentation to learn about the new features and configuration.
(project.util.history.write_history): No data available to write!
Press ENTER or type command to continue
```

Two independent issues: a **tinted-theming** deprecation (primary) and a
**project.nvim** history notice (secondary, benign).

## Root cause (verified against the shipped plugin, `tinted-nvim 1.0.0-unstable-2026-05-04`)

**Issue 1 — the theming config is a silent no-op, not just a warning.**
`nvim/plugins/tinted-nvim.nix` installs the correctly-renamed package
(`pkgs.vimPlugins.tinted-nvim`) but its Lua still calls the **old** module:

```lua
require("tinted-colorscheme").setup(nil, { supports = {...}, highlights = {...} })
```

In the current plugin, `lua/tinted-colorscheme.lua` is only a
backward-compat shim: it emits the deprecation warning once and its
`setup()` is **an empty function** (`function M.setup() end`). So the entire
theming configuration — the Tinty integration and the telescope/cmp/LSP
highlight options — is **discarded**. The visible warning is the least of
it; nvim currently applies no Tinty-driven colours at all through this path.

**Issue 2 — project.nvim exit notice.** `project-nvim` calls
`history.write_history()` on exit; when no project was detected during the
session it `vim.notify`s "No data available to write!" at WARN level. It is
cosmetic and stops once a recognised project (e.g. a Git repo) has been
opened. Independent of Issue 1.

## Facts that shape the fix (all verified live on the 26.05 guest)

- Tinty writes the active scheme name to
  `~/.local/share/tinted-theming/tinty/current_scheme` (a symlink into
  `artifacts/`; currently contains `base16-gruvbox-light-medium`). This is
  **exactly** the new plugin's default selector file — the integration is a
  direct wiring, no glue needed.
- The new API is a single-table `require("tinted-nvim").setup(opts)`. Config
  schema (read from `lua/tinted-nvim/config.lua`): `default_scheme`,
  `apply_scheme_on_startup`, `compile`, `capabilities{ truecolor, undercurl,
  terminal_colors }`, `ui`, `styles`, `highlights{ integrations =
  table<telescope|notify|cmp|blink|dapui|lualine>, use_lazy_specs, overrides
  }`, `schemes`, `selector{ enabled, mode = "file"|"env"|"cmd", watch, path,
  env, cmd }`.
- **End-to-end proof (headless, read-only):** prepending the plugin to
  `runtimepath` and calling the new `setup()` succeeds and applies Tinty's
  live scheme —
  `require ok=true / setup ok=true / vim.g.colors_name=base16-gruvbox-light-medium /
  get_scheme()=base16-gruvbox-light-medium`. The migration below is confirmed
  to work, not hypothetical.

## Change 1 — `nvim/plugins/tinted-nvim.nix` (the fix)

Replace the deprecated call with the new API:

```lua
vim.opt.termguicolors = true

require("tinted-nvim").setup({
  -- Fallback only; the selector below normally resolves the live scheme.
  -- Tracks dx-theme's `dark` default (home/theme.nix: dxThemes.dark).
  default_scheme = "base16-mocha",
  apply_scheme_on_startup = true,
  selector = {
    enabled = true,               -- was supports.tinty = true
    mode = "file",
    path = vim.fn.expand("~/.local/share/tinted-theming/tinty/current_scheme"),
    watch = true,                 -- live-reload a running nvim on `dx-theme <x>`
  },
  highlights = {
    integrations = { telescope = true, cmp = true },
  },
})
```

Old → new mapping:

| Old (`tinted-colorscheme`)        | New (`tinted-nvim`)                                   |
| --------------------------------- | ---------------------------------------------------- |
| `supports.tinty = true`           | `selector.enabled = true, mode = "file", path = …current_scheme` |
| `supports.live_reload = false`    | `selector.watch` (recommend **true** — improves on the old fixed-at-startup behaviour; set `false` to match old exactly) |
| `supports.tinted_shell = false`   | no equivalent; terminal colours are handled by `capabilities.terminal_colors` and, for running shells, already by `dx-theme-restore`'s OSC hook |
| `highlights.telescope`, `telescope_borders` | `highlights.integrations.telescope` (borders folded in) |
| `highlights.cmp`                  | `highlights.integrations.cmp`                        |
| `highlights.lsp_semantic`         | dropped — LSP highlights are covered by the default groups now |

`vim.opt.termguicolors = true` is kept (harmless; also derivable from
`capabilities.truecolor`, which defaults on).

## Change 2 — `tests/test_section14_tinty_theming.sh` (TDD, red → green)

The current suite encodes the **old** API and would keep passing against the
broken config:

- Line ~372 asserts `tinty = true` — remove; replace with assertions for the
  new wiring:
  - `assert_file_contains "$NIXVIM_PLUGIN" 'require("tinted-nvim").setup'`
  - `assert_file_not_contains "$NIXVIM_PLUGIN" 'tinted-colorscheme'` (no
    deprecated module reference — this is the assertion that fails first,
    driving the fix)
  - `assert_file_contains "$NIXVIM_PLUGIN" 'tinted-theming/tinty/current_scheme'`
    (selector points at Tinty's file)
- Keep line ~371 (`pkgs.vimPlugins.tinted-nvim`) and ~374/375 (lualine
  `theme = "tinted"`).
- **Behavioural check (the real test):** at the canary (below), launch nvim
  headless and assert (a) **no** `Deprecated module 'tinted-colorscheme'`
  text appears in `:messages`, and (b) `vim.g.colors_name` equals Tinty's
  `current_scheme` — i.e. the theme is genuinely applied, not merely
  configured. A stubbed/static grep alone would not have caught that the old
  `setup()` was a no-op.

## Change 3 — project.nvim history notice → moved to R-13

The `(project.util.history.write_history): No data available to write!` notice
is **no longer tracked here.** It is diagnosed and fixed as finding **R-13**
(`complete-bump-review.md`) and scoped in the "Remove project.nvim's
empty-history warning" section of `complete-bump-plan.md`: `project.nvim`
emits it via an unconditional `vim.notify(..., WARN)` that bypasses its own
`log.enabled` gate, suppressed by a minimal exact-message filter in
`nvim/plugins/project-nvim.nix`. See those documents for the accepted fix and
its regression test.

## Validation

Per the constitution (TDD, behaviour over config-parsing):

1. **Static:** section 14 green with the updated assertions;
   `nix flake check` in a **≥ 8 GB** container (buildEnv/eval errors surface
   here — see the README "Upgrade / Bump" gotchas).
2. **Canary (non-destructive):** rebuild the isolated `dx-test` profile
   (`dx-profile dx-test dx-destroy … && dx`), then headless-verify inside the
   guest:
   - no `tinted-colorscheme` deprecation in `:messages`;
   - `vim.g.colors_name` == `~/.local/share/tinted-theming/tinty/current_scheme`;
   - with `watch = true`, running `dx-theme <alias>` live-updates a running
     nvim's colours.
   Full `run_all_tests.sh` green under the profile.
3. **Apply to the primary:** this is a **guest-payload / Home Manager change
   only** — no `Containerfile` or Nix-pin change. Deploy it by re-activation:
   `./bin/dx-stop-container` → `./bin/dx-start-container` → `./bin/dx-wait-ssh`
   (the container restart re-runs Home Manager activation with the synced
   payload). **Not** `./bin/dx-recreate` — that runs `dx-destroy`, removing the
   container *and* image (a needless rebuild for a payload-only change; it
   preserves only volumes and keys). **No destructive base changeover is
   involved.**

## Notes / scope

- Package name is already correct (`pkgs.vimPlugins.tinted-nvim`); only the
  Lua module name and the `setup` schema change.
- No base image, digest, or release pin is touched — unrelated to the
  changeover/upgrade runbooks.
- Everything above was verified against the plugin that ships at the current
  26.05 pin; a future release bump could move the plugin version and should
  re-confirm the `setup` schema (the API is young — `1.0.0-unstable`).
