# Plan: Implement and Validate Tinty Theming for DXE

## Execution Status

- [x] Step 0: Verified Tinty prerequisites from the running guest. Pinned nixpkgs provides `tinty-0.29.0`, which supports `preferred-schemes`, hook environment variables, and the selected Rose Pine scheme IDs after `tinty install`.
- [x] Step 1: Added `tinty` to the DXE package set.
- [x] Step 2: Added declarative Home Manager Tinty config using the verified `preferred-schemes` schema and explicit runtime-managed template repos.
- [x] Step 3: Added `dx-theme`, `dx-theme-copy-hook`, `dx-theme-osc-hook`, and `dx-theme-restore`.
- [ ] Step 4: Raw non-tmux OSC visual validation is still manual. Non-interactive `./bin/dx-ssh '<command>'` now works, but the remaining check is a host-terminal visual confirmation of OSC 10/11.
- [ ] Step 5: tmux OSC visual validation is still manual. The hook emits tmux passthrough-wrapped OSC 10/11, but the remaining check is visible host-terminal behavior inside the default tmux session.
- [x] Step 6: Implemented Tinty hook-based OSC foreground/background emission using `TINTY_SCHEME_PALETTE_*`.
- [x] Step 7: Integrated Neovim with `tinted-nvim`; headless validation shows Neovim follows `tinty current` on startup.
- [x] Step 8: Integrated tmux status theme sourcing from the Tinty-generated file cache.
- [x] Step 9: Added representative CLI theming through `tinted-lazygit`, generated btop `dx-tinty`, generated Yazi `theme.toml`, and generated Starship `starship.toml`. Generated tool themes are refreshed from independently read Tinty palette data after every `dx-theme apply`, including same-scheme reapply and activation upgrades.
- [x] Step 10: Added section 14 Tinty tests and explicit `tests/run_all_tests.sh` wiring.
- [x] Step 11: Documented experimental theming behavior and manual OSC validation in `README.md`.

Validation completed:

- [x] `tests/run_all_tests.sh --section=14 --skip-integration`
- [x] `tests/run_all_tests.sh --section=14` against the activated running container
- [x] Guest `nix flake check --no-write-lock-file` on a temporary copy of the current worktree
- [x] Guest build of `.#packages.aarch64-linux.default`
- [x] Guest build and activation of `.#homeConfigurations.dx.activationPackage`
- [x] Runtime `dx-theme dark`, `light`, `rose-pine`, `rose-pine-moon`, `rose-pine-dawn`, and `test`
- [x] Headless Neovim startup confirmed it follows Tinty current state, including `base16-mocha` with `background=dark`.
- [x] btop, Yazi, and Starship light-theme refresh confirmed after corrupting generated theme files and reapplying `dx-theme light`.
- [x] Login/session restore added so `dx-ssh` and shell startup re-emit the selected terminal palette without changing the selected theme.
- [x] `tests/run_all_tests.sh --section=9`
- [ ] Full `tests/run_all_tests.sh --skip-integration` is not clean because pre-existing sections 3 and 8 fail, and section 13 fails while the worktree has tracked edits.

## Context

The DXE repository defines a reproducible terminal-first development environment. The current implementation is a macOS-hosted Apple `container` guest with most developer tooling installed and configured inside the Linux guest via Nix.

The theming question to answer is whether **Tinty and the Tinted Theming ecosystem** can provide a cohesive, runtime-switchable theme for the terminal-only DXE without requiring host terminal configuration changes.

The most important requirement to validate is:

> The DXE must support foreground/background color changes from inside the guest without changing terminal emulator configuration on the host.

This plan intentionally treats Tinty as an experiment with a clear pass/fail result. If it cannot control the terminal background reliably through SSH and tmux, document that limitation and stop short of forcing a partial theming system into the DXE.

## Current Repository Facts

- Main DXE guest config lives in `container/aarch64-darwin-apple-container-dx-nixos-25.11/`.
- Guest package selection is in `container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix`.
- Home Manager config is in `container/aarch64-darwin-apple-container-dx-nixos-25.11/home.nix`.
- NixVim config is in `container/aarch64-darwin-apple-container-dx-nixos-25.11/nixvim.nix` and `container/.../nvim/`.
- tmux is already configured in `home.nix`.
- Neovim now uses `tinted-nvim` for the runtime Tinty scheme; `nvim/plugins/rose-pine.nix` keeps Rose Pine packaged as a manual fallback.
- Existing tests live in `tests/` and are run with `./tests/run_all_tests.sh`.

## External Facts to Verify During Implementation

Before implementation, confirm these assumptions against the pinned Nix inputs or the current package set available in the guest:

- `pkgs.tinty` exists for `aarch64-linux`.
- The pinned Tinty version and config schema are known from `tinty --version` and a minimal config test.
- Tinty uses `~/.config/tinted-theming/tinty/config.toml` by default.
- `tinty apply <scheme>` applies a selected scheme.
- Tinty hooks expose palette environment variables such as `TINTY_THEME_FILE_PATH`, `TINTY_SCHEME_PALETTE_BASE00_HEX_R`, and `TINTY_SCHEME_VARIANT` only while hook code is running.

Open design question:

- The preferred implementation is to fetch template repositories through pinned Nix inputs and expose them to Tinty as local paths. This must be proven before committing to a no-sync design.
- If local, Nix-managed template paths do not work cleanly with Tinty, allow `tinty sync` as an explicit runtime step and document the resulting network/runtime mutability trade-off.

Useful upstream references:

- Tinty: `https://github.com/tinted-theming/tinty`
- Tinted Theming: `https://github.com/tinted-theming`
- Tinted shell templates: `https://github.com/tinted-theming/tinted-shell`
- Tinted tmux templates: `https://github.com/tinted-theming/tinted-tmux`
- Tinted terminal templates: `https://github.com/tinted-theming/tinted-terminal`
- Tinted nvim: `https://github.com/tinted-theming/tinted-nvim`
- Tinted vim fallback reference: `https://github.com/tinted-theming/tinted-vim`

## Decision Target

At the end of this work, the repository should answer:

1. Can Tinty be installed declaratively in the DXE guest with Nix?
2. Can the guest switch between one dark theme and one light theme at runtime?
3. Can the switch update shell, tmux, Neovim, and representative CLI tools without rebuilding the container?
4. Can the switch update terminal foreground/background color from inside the guest over SSH and through tmux?
5. If full terminal background switching is not possible, is Tinty still worth keeping for tool-level theming?

## Non-Goals

- Do not make ANY host changes. This is a mandatory requirement.
- Do not configure host terminal themes as part of this experiment.
- Do not add Stylix.
- Do not build a general theming abstraction until the validation proves Tinty is viable.
- Do not support every installed CLI tool in the first pass.
- Do not replace the terminal emulator or container host tooling.
- Do not require GUI desktop services inside the guest.

## Proposed User Experience

Add guest commands:

- `dx-theme dark` applies the selected dark Tinty scheme.
- `dx-theme light` applies the selected light Tinty scheme.
- `dx-theme rose-pine` applies the Rose Pine dark theme across the DXE.
- `dx-theme rose-pine-moon` applies the Rose Pine Moon dark theme across the DXE.
- `dx-theme rose-pine-dawn` applies the Rose Pine Dawn light theme across the DXE.
- `dx-theme list` prints the configured theme aliases and their Tinty scheme ids.
- `dx-theme current` prints the current Tinty scheme.
- `dx-theme test` prints color swatches and the expected foreground/background values.

Recommended initial theme aliases:

- Dark: `base16-mocha`
- Light: `base16-gruvbox-light-medium`
- Rose Pine: `base16-rose-pine`
- Rose Pine Moon: `base16-rose-pine-moon`
- Rose Pine Dawn: `base16-rose-pine-dawn`

These exact scheme ids must be verified with `tinty list`. If any Rose Pine scheme id differs in the selected Tinted scheme source, update the alias mapping to the available id and document the change. The implementation must keep at least one non-Rose-Pine dark scheme, one non-Rose-Pine light scheme, and the Rose Pine family configured declaratively.

Important:

- Rose Pine is a DXE-wide theme family in this plan, not a Neovim-only option.
- Selecting any Rose Pine alias must go through the same `dx-theme`/Tinty path as every other theme so terminal colors, shell colors, tmux, Neovim, and supported CLI tools all receive the same palette.
- The existing Neovim `rose-pine` plugin may remain as a fallback implementation detail, but it must not be the only Rose Pine integration.

## Implementation Steps

### 0. Verify Prerequisites

Before touching feature code, confirm these facts from the host:

```bash
# Confirm tinty is available in the repo's pinned nixpkgs input for aarch64-linux.
# Do not use plain `nix search nixpkgs#tinty` as proof; that can query a different nixpkgs.
nix eval --raw --impure --expr '
let
  flake = builtins.getFlake ("path:" + toString ./container/aarch64-darwin-apple-container-dx-nixos-25.11);
  pkgs = import flake.inputs.nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  };
in pkgs.tinty.name
'
```

Record the result:
- If `pkgs.tinty` is present: proceed to Step 1.
- If absent: decide on a Rust/Nix-appropriate fallback:
  - use a newer pinned `nixpkgs-unstable` package if it evaluates for `aarch64-linux`,
  - consume `inputs.tinty.packages.${system}.default` if upstream exposes a usable flake package,
  - or add a small Rust package derivation from source.
- Do not use a Go-specific package builder for Tinty.
- Document the chosen fallback before touching `flake.nix`.

Confirm the tinted-theming template repos are reachable from the guest network if the fallback path requires `tinty sync`:
- `https://github.com/tinted-theming/schemes`
- `https://github.com/tinted-theming/tinted-shell`
- `https://github.com/tinted-theming/tinted-tmux`
- `https://github.com/tinted-theming/tinted-nvim` if it is needed as a runtime-managed source
- `https://github.com/tinted-theming/tinted-vim` only if it is used as a fallback

Before writing the Home Manager config, run the pinned Tinty binary and determine the supported config schema:

```bash
tinty --version
tinty config --help
tinty config --data-dir-path
```

Then prove whether this version accepts the newer `preferred-schemes` style or requires the older `[[rings]]` plus `default-cycle-ring` style. Write the DXE config using the schema that the pinned version actually accepts.

Before adding full tool integrations, create a minimal throwaway Tinty config and prove one of these data-dir strategies:

- Preferred: local Nix-managed template paths work without `tinty sync`.
- Fallback: Tinty requires `tinty sync`, and the implementation documents that templates are runtime-managed under the data directory reported by `tinty config --data-dir-path`.
- Verify generated file locations from Tinty itself. In hooks, use `TINTY_THEME_FILE_PATH` instead of assuming a generated output path.

Definition of done:
- `pkgs.tinty` availability is confirmed (or a fallback is chosen).
- `tinty --version` is recorded.
- The supported config schema is proven, including whether the implementation must use `preferred-schemes` or `[[rings]]` / `default-cycle-ring`.
- The Tinty data-dir strategy is proven with `tinty list` and `tinty apply base16-mocha`.
- `tinty config --data-dir-path` is recorded and any generated path references are derived from it or from `TINTY_THEME_FILE_PATH`.
- `tinty list` is checked for the Rose Pine family:
  - `base16-rose-pine`
  - `base16-rose-pine-moon`
  - `base16-rose-pine-dawn`
- If the Rose Pine ids differ, the available ids are recorded and used in the alias map.
- If `tinty sync` is required, network reachability of template repos is confirmed from the guest.
- Results are noted in `README.md`, the PR description, or an implementation note near the Tinty config.

### 1. Add Tinty to the DXE Package Set

Edit `container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix`.

Add `tinty` to `dxPackages`.

Definition of done:

- `tinty` is available in the guest PATH after bootstrap/home-manager activation.
- `nix flake check --no-write-lock-file container/aarch64-darwin-apple-container-dx-nixos-25.11` passes or any failure is documented as unrelated.
- Existing package tests still pass.

### 2. Add Declarative Tinty Configuration

Edit `container/aarch64-darwin-apple-container-dx-nixos-25.11/home.nix`.

Create the file `~/.config/tinted-theming/tinty/config.toml` via Home Manager using `xdg.configFile`.

The config should:

- Set a default dark scheme.
- Declare the preferred schemes using the schema proven in Step 0:
  - use `preferred-schemes` if the pinned Tinty version supports it,
  - otherwise use `[[rings]]` and `default-cycle-ring`.
- Include this scheme set:
  - one non-Rose-Pine dark scheme
  - one non-Rose-Pine light scheme
  - `base16-rose-pine` or the verified equivalent
  - `base16-rose-pine-moon` or the verified equivalent
  - `base16-rose-pine-dawn` or the verified equivalent
- Use Tinty items for the minimum viable set of tools:
  - shell/terminal color escape support using Tinted shell, wired into the configured guest shells
  - tmux using Tinted tmux if practical
  - Neovim via `tinted-nvim` if it can be packaged cleanly in NixVim (see Step 7)
- Wire Tinted-shell output into the configured shells via `home.nix`:
  - **bash**: `programs.bash.initExtra`
  - **fish**: `programs.fish.interactiveShellInit`
  - **nushell**: only add startup integration after proving Tinted-shell has usable Nushell support for the selected template version.
  - Add a guard so startup integration is a no-op if the generated file does not exist yet.
  - Do not hard-code a guessed generated script path. Derive startup paths from `tinty config --data-dir-path` and the files actually generated by the pinned Tinty version.
  - Inside Tinty hooks, use `TINTY_THEME_FILE_PATH` when copying, sourcing, or recording generated Tinted-shell output.
- Do not add zsh for this feature. zsh is not currently configured in the DXE.
- Use hooks only where needed to copy generated files or trigger reload commands.

Important implementation note:

- Prefer declarative file placement in `home.nix`.
- Avoid imperative bootstrap changes unless there is no Home Manager alternative.
- If Step 0 proves local template paths work, fetch template repos at build time via Nix. Add the following as flake inputs and expose them via `xdg.dataFile` or use the Nix store paths directly in Tinty `[[items]].path`:
  - `tinted-theming/schemes` → `"tinted-theming/tinty/schemes/tinted-theming".source`
  - `tinted-theming/tinted-shell` → `"tinted-theming/tinty/tinted-shell".source`
  - `tinted-theming/tinted-tmux` → `"tinted-theming/tinty/tinted-tmux".source`
  - `tinted-theming/tinted-nvim` only if the chosen Neovim integration consumes it as a local source.
- If Step 0 proves Tinty cannot use local read-only template paths without cloning/updating them, use `tinty sync` explicitly and document that this part of the experiment is runtime-managed rather than fully pinned by Nix.
- Do not assume `tinty apply` can write generated output alongside Nix-managed read-only template directories. Prove the exact input/output paths in Step 0 and document them in the implementation.

Definition of done:

- `~/.config/tinted-theming/tinty/config.toml` exists in the guest.
- `tinty config` shows the expected config.
- The config uses the Tinty schema proven in Step 0.
- Template repos are either present as pinned local paths or installed by an explicit `tinty sync` step, matching the strategy chosen in Step 0.
- `tinty list` includes the selected dark, light, and Rose Pine schemes.
- No generated Tinty file path is assumed without proof from `tinty config --data-dir-path` or `TINTY_THEME_FILE_PATH`.
- Nushell startup integration is either proven and implemented, or explicitly documented as not supported in the first pass.

### 3. Add `dx-theme` Wrapper

Add a small executable script through Home Manager, preferably with `home.file.".local/bin/dx-theme"` or `pkgs.writeShellScriptBin`.

The script should support:

- `dx-theme dark`
- `dx-theme light`
- `dx-theme rose-pine`
- `dx-theme rose-pine-moon`
- `dx-theme rose-pine-dawn`
- `dx-theme apply <alias-or-scheme-id>`
- `dx-theme list`
- `dx-theme current`
- `dx-theme test`
- `dx-theme help`

Expected behavior:

- `dark` runs `tinty apply <dark-scheme>`.
- `light` runs `tinty apply <light-scheme>`.
- `rose-pine`, `rose-pine-moon`, and `rose-pine-dawn` run `tinty apply <verified-rose-pine-scheme>`.
- `apply <alias-or-scheme-id>` accepts either a configured alias or a raw Tinty scheme id.
- `list` prints aliases and scheme ids, including all Rose Pine aliases.
- `current` reports Tinty's native current scheme state, normally by running `tinty current`.
- After a successful apply, the wrapper may write the selected scheme id to `~/.config/dx/theme-current`.
  - This file is an optional DX mirror for integrations that cannot read Tinty's native state cheaply.
  - It must not be the only canonical state. Prefer Tinty's native current scheme state where integrations support it.
  - Do not rely on `dx-theme` changing parent-shell environment variables; an executable script cannot mutate the environment of the shell that launched it.
- Every alias, including Rose Pine aliases, must call the same post-apply path so all supported utilities are updated consistently.
- `test` prints:
  - current scheme id
  - current variant (dark/light)
  - base00 (background) and base05 (foreground) hex values if available from `tinty info`, the current scheme file, or another independently read source
  - Do not rely on `TINTY_SCHEME_PALETTE_*` variables in `dx-theme test`; those variables are only guaranteed inside Tinty hooks.
  - a 16-color swatch using ANSI escape codes (no external dependencies):
    ```bash
    for i in 0 1 2 3 4 5 6 7; do printf "\033[3${i}m  \033[0m"; done; printf "\n"
    for i in 0 1 2 3 4 5 6 7; do printf "\033[9${i}m  \033[0m"; done; printf "\n"
    ```

Definition of done:

- `command -v dx-theme` succeeds in the guest.
- `dx-theme help` explains the commands in plain text.
- `dx-theme dark` and `dx-theme light` both exit successfully.
- `dx-theme rose-pine`, `dx-theme rose-pine-moon`, and `dx-theme rose-pine-dawn` exit successfully.
- `dx-theme list` prints the dark, light, and Rose Pine aliases.
- `dx-theme current` reports the selected scheme after each switch.
- If `~/.config/dx/theme-current` is used, it contains the selected scheme id after each switch and matches `tinty current`.

### 4. Validate Raw Terminal Background Switching Outside tmux

Before debugging tmux, validate the simplest case over SSH without tmux.

Use non-interactive `./bin/dx-ssh '<command>'`, or plain SSH if needed, to run a guest shell command that emits OSC 10/11 sequences for foreground/background colors. Do not use interactive `./bin/dx-ssh` for this check because the normal interactive path attaches or creates the default tmux session.

Test commands inside the guest:

```bash
printf '\033]10;#f8f8f2\033\\'
printf '\033]11;#1e1e2e\033\\'
```

Then switch to a visibly light background:

```bash
printf '\033]10;#282828\033\\'
printf '\033]11;#fbf1c7\033\\'
```

Definition of done:

- Record whether the host terminal visibly changes foreground/background when OSC 10/11 is emitted from the guest.
- Record the terminal emulator used for the test.
- Record whether this works through SSH when tmux is not involved.

Pass/fail meaning:

- If this fails outside tmux, Tinty cannot satisfy the strongest theming requirement without host terminal support/configuration.
- If this passes outside tmux, continue to tmux passthrough validation.

### 5. Validate Background Switching Through tmux

Current tmux config already sets:

- `set -g allow-passthrough on`
- true-color-related terminal settings

Test whether OSC 10/11 sequences work inside the default `dx` tmux session.

If direct OSC sequences are blocked, test tmux passthrough wrapping:

```bash
printf '\033Ptmux;\033\033]11;#1e1e2e\033\\\033\\'
printf '\033Ptmux;\033\033]11;#fbf1c7\033\\\033\\'
```

Definition of done:

- Record whether direct OSC works inside tmux.
- Record whether tmux passthrough OSC works inside tmux.
- If passthrough is required, encode it in the `dx-theme`/Tinty hook path rather than expecting users to type it manually.

### 6. Wire Tinty Hooks to Terminal Background Changes

If OSC background switching works, add a Tinty hook that emits OSC 10/11 using Tinty palette values.

Important boundary:

- `TINTY_SCHEME_PALETTE_*` values are hook-time environment variables. Code that needs those values must run inside a Tinty hook.
- A `dx-theme` post-apply helper can emit OSC only if it independently reads the palette from Tinty's current scheme metadata, `tinty info`, or another verified source. It cannot assume the Tinty hook environment is still available after `tinty apply` exits.
- Prefer keeping OSC emission in a Tinty hook and keeping `dx-theme` responsible for alias resolution and user-facing commands.

Use Base16 values as follows unless testing proves a better mapping:

- Background: `base00`
- Foreground: `base05`

The hook/script must support both:

- normal shell over SSH
- shell inside tmux

Implementation guidance:

- Detect tmux using `if [ -n "$TMUX" ]; then ... fi`.
- Use regular OSC outside tmux.
- Use tmux passthrough OSC inside tmux if required.
- Use `TINTY_THEME_FILE_PATH` in hooks when a generated template file must be copied or sourced.
- Keep this code in one helper script/function so it is easy to test.

Definition of done:

- `dx-theme dark` visibly changes the terminal background to the dark scheme.
- `dx-theme light` visibly changes the terminal background to the light scheme.
- The change works from inside the normal `dx-ssh` tmux session.
- No host terminal configuration file is edited.

### 7. Integrate Neovim With the Runtime Theme

Keep `rose-pine` available while validating Tinty. The first pass should prove whether Neovim can follow the active Tinty scheme; it should not remove a known working colorscheme until the Tinted/Base16 path is validated.

Do not confuse these two concepts:

- Rose Pine as a Tinty/Base16 scheme family is a DXE-wide selectable theme and must update every supported utility.
- The existing Neovim `rose-pine` plugin is only an optional fallback while Neovim integration is still incomplete. Falling back to it does not count as a fully successful Tinty implementation.

Implementation:

- Add a new NixVim plugin module, preferably `nvim/plugins/tinted-nvim.nix`.
- First candidate: package and configure `tinted-theming/tinted-nvim` through NixVim's `extraPlugins`, `pkgs.vimUtils.buildVimPlugin`, or an existing nixpkgs `vimPlugins` package if one is available.
- Fall back to `RRethy/nvim-base16` or `tinted-vim` only if `tinted-nvim` cannot be packaged cleanly in NixVim, and document the reason.
- Update `container/aarch64-darwin-apple-container-dx-nixos-25.11/nixvim.nix` to import the new Tinted/Base16 plugin file.
- Keep `nvim/plugins/rose-pine.nix` in the repository unless the final implementation deliberately removes it after validation. Keeping this file does not satisfy the Rose Pine DXE-wide theme requirement by itself.
- Update `nvim/plugins/lualine.nix`; it previously hard-coded `theme = "rose-pine"`. Choose one of:
  - let lualine auto-detect the active colorscheme,
  - set a Base16-compatible lualine theme,
  - or keep rose-pine as the explicit fallback when no Tinty theme is active.
- On Neovim startup, prefer Tinty's native current scheme state if the chosen plugin supports it.
  - Use `~/.config/dx/theme-current` only as an optional synchronized DX mirror/cache, not as the only canonical state.
  - If a small glue script must translate Tinty scheme ids to Neovim colorscheme names, keep that mapping declarative and covered by tests.
  - Do not rely on `BASE16_THEME` being set by `dx-theme`; an executable wrapper cannot update the parent shell environment.
  - If Tinted-shell sets useful variables for new shells, they can be used as an optimization, not as the only source of truth.
- Live switching inside a running Neovim instance is not required for the first pass. Fresh startup must pick up the current theme.

Definition of done:

- A Tinted/Base16 Neovim plugin module exists and is imported by `nixvim.nix`.
- `tinted-nvim` was attempted first; any fallback is documented with the packaging issue that forced it.
- `nvim/plugins/rose-pine.nix` remains available as a fallback option unless there is a documented final decision to remove it.
- `nvim/plugins/lualine.nix` no longer hard-codes an incompatible stale theme when Base16 is active.
- Opening `nvim` after `dx-theme rose-pine`, `dx-theme rose-pine-moon`, or `dx-theme rose-pine-dawn` uses the corresponding Tinty/Tinted Rose Pine palette.
- Opening `nvim` after `dx-theme dark` uses the selected dark Tinty/Tinted palette.
- Opening `nvim` after `dx-theme light` uses the selected light Tinty/Tinted palette.
- If Neovim cannot follow the active runtime theme, document the fallback clearly and mark the Tinty experiment incomplete rather than successful.
- NixVim still builds.
- Existing NixVim tests still pass.

### 8. Integrate tmux Status Theme

Use Tinty-generated tmux theme files if practical.

Expected behavior:

- `dx-theme dark` updates tmux status colors.
- `dx-theme light` updates tmux status colors.
- `dx-theme rose-pine`, `dx-theme rose-pine-moon`, and `dx-theme rose-pine-dawn` update tmux status colors.
- Existing tmux keybindings and true-color settings remain intact.

Implementation guidance:

- Source a generated tmux theme file from `.tmux.conf` if it exists.
- After applying a theme, run `tmux source-file ~/.tmux.conf` or source only the generated theme file.
- Do not break the existing `dx-ssh` attach behavior.

Definition of done:

- Existing tmux config remains present.
- tmux status line visibly changes between dark and light schemes.
- tmux status line visibly changes when switching to each Rose Pine alias.
- `./bin/dx-ssh` still attaches or creates the `dx` session.

### 9. Add Representative CLI Tool Theming

Add only low-risk CLI tool theming in the first pass.

Recommended targets:

- `bat`, if added to packages
- `lazygit`, if configuration can be generated cleanly
- `btop`, via a generated theme file
- `yazi`, via a generated `theme.toml`
- shell prompt colors through Starship if it supports a generated palette config without excessive custom config

Definition of done:

- At least one non-editor, non-tmux CLI tool demonstrates Tinty-generated colors.
- The implementation does not add large handwritten theme files.
- The plan documents which tools are intentionally not themed yet.

### 10. Add Tests

Add a new test file:

`tests/test_section14_tinty_theming.sh`

Update `tests/run_all_tests.sh` to run section 14:
- Confirm the section range is `0-14`.
- Add an explicit runner call after section 13:
  ```bash
  run_test "$SCRIPT_DIR/test_section14_tinty_theming.sh" "14"
  ```
- Keep this consistent with the script's current explicit `run_test` structure; do not rely on globbing or automatic discovery unless the runner is deliberately refactored.

Unit/static tests should check:

- `flake.nix` includes `tinty`.
- `home.nix` declares `tinted-theming/tinty/config.toml`.
- The Tinty config uses the schema proven in Step 0, either `preferred-schemes` or `[[rings]]` / `default-cycle-ring`.
- `home.nix` or generated script declares `dx-theme`.
- `dx-theme current` reads Tinty's native current state.
- If the implementation declares `~/.config/dx/theme-current`, tests treat it as an optional DX mirror and verify it is synchronized with `tinty current`.
- The selected dark, light, and Rose Pine scheme ids appear in config.
- `dx-theme` declares aliases for `rose-pine`, `rose-pine-moon`, and `rose-pine-dawn`.
- Generated Tinty file references use `TINTY_THEME_FILE_PATH` in hooks or paths verified from `tinty config --data-dir-path`; no test should bless a guessed `tinted-shell/scripts/base16-<scheme>.sh` path.
- tmux passthrough settings remain enabled.
- zsh is not added for this feature.
- Nushell Tinted-shell startup integration is either proven by implementation-specific tests or absent/documented.
- If Base16 Neovim integration is enabled, `nixvim.nix` imports the Tinted/Base16 plugin and `lualine.nix` no longer assumes `rose-pine` is always active.
- The Neovim integration attempts `tinted-nvim` first, or documents why a fallback was necessary.
- No Stylix dependency was added.

Integration tests should check when a container is running:

- `command -v tinty`
- `command -v dx-theme`
- `tinty config`
- `dx-theme list`
- `dx-theme dark`
- `dx-theme current`
- `test "$(dx-theme current)" = "$(tinty current)"`
- `if [ -f ~/.config/dx/theme-current ]; then test "$(cat ~/.config/dx/theme-current)" = "$(tinty current)"; fi`
- `dx-theme light`
- `dx-theme rose-pine`
- `dx-theme rose-pine-moon`
- `dx-theme rose-pine-dawn`
- `dx-theme test`

Definition of done:

- Static tests pass without requiring a running container.
- Integration tests skip cleanly when no container is running.
- Integration tests pass when a freshly bootstrapped container is running.

### 11. Document Results

Update `README.md` with a short "Theming" section after validation.

Include:

- How to run `dx-theme dark`, `dx-theme light`, and the Rose Pine aliases.
- Which components are themed.
- Whether Neovim follows the selected runtime Tinty theme on fresh startup. If it falls back to the Neovim `rose-pine` plugin, document that as an incomplete part of the experiment.
- That Rose Pine is available as a DXE-wide theme family, not just as a Neovim colorscheme.
- Which host terminal was tested.
- Whether OSC foreground/background switching works:
  - outside tmux
  - inside tmux
- Any known terminal emulator limitations.

Definition of done:

- A new contributor can reproduce the validation without needing private context.
- The documentation clearly says whether Tinty satisfies the must-have background color requirement.

## Validation Checklist

Run these commands from the repository root unless noted otherwise.

### Static Validation

```bash
./tests/run_all_tests.sh --skip-integration
```

Expected result:

- All non-integration tests pass.
- Section 14 Tinty static tests pass.

### Nix Validation

```bash
nix flake check --no-write-lock-file container/aarch64-darwin-apple-container-dx-nixos-25.11
```

Expected result:

- The flake evaluates and checks successfully.

### Fresh Guest Validation

```bash
./bin/dx-build
./bin/dx-create
./bin/dx-start
./bin/dx-ssh 'command -v tinty && command -v dx-theme'
./bin/dx-ssh 'tinty config'
./bin/dx-ssh 'dx-theme list'
./bin/dx-ssh 'dx-theme dark && dx-theme current'
./bin/dx-ssh 'test "$(dx-theme current)" = "$(tinty current)"'
./bin/dx-ssh 'if [ -f ~/.config/dx/theme-current ]; then test "$(cat ~/.config/dx/theme-current)" = "$(tinty current)"; fi'
./bin/dx-ssh 'dx-theme light && dx-theme current'
./bin/dx-ssh 'dx-theme rose-pine && dx-theme current'
./bin/dx-ssh 'dx-theme rose-pine-moon && dx-theme current'
./bin/dx-ssh 'dx-theme rose-pine-dawn && dx-theme current'
./bin/dx-ssh 'dx-theme test'
```

Expected result:

- `tinty` is installed.
- `dx-theme` is installed.
- Tinty config is present.
- Dark, light, and Rose Pine theme commands succeed.
- Current scheme matches the last applied theme.
- If `~/.config/dx/theme-current` exists, it matches `tinty current`.

### Manual Visual Validation

1. Open the normal host terminal.
2. Connect with `./bin/dx-ssh`.
3. Run `dx-theme dark`.
4. Confirm the terminal background becomes dark.
5. Run `dx-theme light`.
6. Confirm the terminal background becomes light.
7. Run `dx-theme rose-pine`.
8. Confirm terminal, tmux, and supported CLI colors change to the Rose Pine palette.
9. Run `dx-theme rose-pine-dawn`.
10. Confirm terminal, tmux, and supported CLI colors change to the Rose Pine Dawn palette.
11. Open `nvim`.
12. Confirm Neovim matches the selected runtime theme. If it falls back to the documented `rose-pine` plugin, mark Neovim integration incomplete.
13. Confirm no host terminal configuration was edited.

## Final Acceptance Criteria

Tinty is considered successful for this DXE if all of these are true:

- Tinty is installed through Nix.
- Tinty configuration is declared through Home Manager.
- A user can switch between dark, light, and Rose Pine themes at runtime using `dx-theme`.
- The switch works in the default `dx-ssh` tmux session.
- The terminal foreground/background changes without editing host terminal configuration.
- tmux visually follows the selected theme.
- Neovim visually follows the selected runtime theme on fresh startup.
- Tests and README documentation cover the behavior.

Tinty remains experimental, not fully successful, if Neovim must stay on a documented `rose-pine` fallback while Tinted/Base16 support is incomplete.

Tinty is considered not sufficient for the must-have requirement if either is true:

- OSC foreground/background changes do not work from the guest outside tmux.
- OSC foreground/background changes work outside tmux but cannot be made to work inside the default tmux session.

If Tinty is not sufficient, leave the repo in one of these states:

- Revert the implementation and keep only documentation of the failed validation.
- Or keep Tinty behind clearly documented experimental commands if it still provides useful tool-level theming.

Do not present Tinty as the chosen DXE theming solution unless the must-have background color validation passes.
