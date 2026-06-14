# Tmux Configuration Improvement Plan

## Status / Progress Log

- **2026-06-14 — Slice 1 (typed options cleanup): DONE (automated gates green;
  user manual-validation gate still open).**
  - Migrated the option-shaped `extraConfig` settings to typed Home Manager
    options in `home/tools.nix`: `keyMode = "vi"`, `baseIndex = 1`,
    `escapeTime = 0`, `focusEvents = true`, `mouse = true`,
    `historyLimit = 50000`, `terminal = "tmux-256color"`. Removed the now-dead
    raw duplicates (`set -g base-index`, `setw -g pane-base-index`,
    `set -s escape-time`, `set -g focus-events`, `set -g mouse`,
    `set -g history-limit`, `set -g default-terminal`, `setw -g mode-keys vi`).
    Confirmed at runtime that the typed `baseIndex` sets **both** `base-index`
    and `pane-base-index`, so both raw lines were safe to drop.
  - Kept the `status-keys emacs` override in `extraConfig` (with a comment),
    because `keyMode = "vi"` emits both `mode-keys vi` and `status-keys vi`.
  - **Behavior test harness** added to `tests/test_helpers.sh`
    (`tmux_guest_probe`, `probe_value`, `assert_tmux_runtime`): starts a
    throwaway tmux server on a private `-L` socket **inside the guest**, dumps
    live runtime option values, and tears it down. It reads the activated
    `~/.config/tmux/tmux.conf` exactly as a real server would, so it validates
    behaviour, not config strings. It never touches the macOS host and never
    touches the user's interactive `dx-host` session (separate socket/server).
  - **TDD trail actually observed (not just asserted):**
    1. Red (source wiring): the new `baseIndex = 1;` / `keyMode = "vi";` /
       `status-keys emacs` source assertions failed before the migration.
    2. Red (runtime): after adding `keyMode = "vi"` *without* the override and
       activating in the guest, the live probe caught `status-keys` flip to
       `vi` (`expected status-keys=emacs, got 'vi'`) — a regression a
       string-grep test could never have seen.
    3. Green: adding `set -g status-keys emacs` restored `status-keys=emacs`.
    4. Refactor: duplicates already removed; section 6 (95 passed) and
       section 14 theming (118 passed) both green.
  - **Validation loop used** (against the running `dx-host`): edit
    `home/tools.nix` → `./bin/dx-sync-bootstrap` → in guest
    `USER=dx HOME=/home/dx nix run --extra-experimental-features 'nix-command flakes' /guest-bootstrap#homeConfigurations.dx.activationPackage`
    → `tests/run_all_tests.sh --section=6`. The `USER`/`HOME` exports are
    required for manual activation under `container exec -u dx` (the bootstrap's
    `run_as_dx` sets them itself).
  - Activation only rewrites the on-disk `~/.config/tmux/tmux.conf` symlink;
    the user's already-running tmux server keeps its old config until a reload
    or a new server. So the live `dx-host` session was not disrupted. **Manual
    gate for the user:** in `dx-host`, start a fresh tmux (or reload) and
    confirm 1-based indexing, mouse, vi copy-mode, and emacs command-prompt
    editing all behave as expected.
  - Test files touched: `tests/test_helpers.sh`, `tests/test_section6_tools.sh`.
  - Not committed yet.

- **2026-06-14 — Slice 2 (pane navigation + native binds): DONE (automated
  gates green; user manual-validation gate still open).**
  - Enabled typed `customPaneNavigationAndResize = true` and
    `disableConfirmationPrompt = true`; added a `bind r source-file
    ~/.config/tmux/tmux.conf \; display-message` reload bind; removed the
    hand-written hjkl/HJKL block from `extraConfig` (the typed option emits it,
    and an extraConfig copy would override the generated binds via `mkAfter`).
  - **Plan correction (found by behaviour testing, not assumed):** Section 3 of
    this plan claimed the pinned Home Manager module emits *all eight* nav+resize
    binds with `-r`, making pane switching newly repeatable. That is **false**
    for the pinned module: it emits pane **switch** (`h/j/k/l`) *without* `-r`
    and only pane **resize** (`H/J/K/L`) *with* `-r`. So there is **no** repeat
    behaviour change — switching stays non-repeatable, matching the prior
    hand-written binds and existing muscle memory. The "repeatable pane-switch is
    a conscious behaviour change" caveat in section 3 does not apply to this
    module version; no override was needed. Tests assert the real
    (non-repeatable switch, repeatable resize) state.
  - **Behaviour test harness extended** (`tests/test_helpers.sh`):
    `tmux_guest_keys_probe` starts a throwaway guest server and reports the
    *parsed* prefix key table (`<key>.repeat`, `<key>.cmd` for h j k l H J K L
    r x), plus real pane-navigation effects (`select-pane -R/-L` moves the
    active pane) and `reload-sources-ok` (sourcing the activated config — what
    the reload bind does — succeeds). Added `assert_tmux_runtime_contains` /
    `assert_tmux_runtime_not_contains`. These read the live key table, not
    tools.nix strings.
  - **TDD trail observed:** before the change the probe showed
    `r.cmd=refresh-client` (red → now `source-file`),
    `x.cmd=confirm-before … kill-pane` (red → now bare `kill-pane`), and the
    typed-option source assertions red. A first harness pass also exposed a
    *test* bug — tmux pads the missing `-r` slot with spaces, so the original
    regex silently failed to match non-repeatable lines; fixed to tolerate
    variable whitespace and re-verified against the live `list-keys` format.
  - Section 6 (116 passed) and section 14 theming (118 passed) green against
    the running guest. Files: `tests/test_helpers.sh`,
    `tests/test_section6_tools.sh`, `home/tools.nix`.
  - **Manual gate for the user:** in a real `dx-host` tmux, exercise
    `prefix h/j/k/l` selection, `prefix H/J/K/L` resize, `prefix r` reload
    (expect "tmux config reloaded"), and `prefix x` kill-pane (expect no y/n
    confirmation). Deferred decision: the optional `bind C-space last-window`
    from plan section 4 was **not** added — it needs the nested-tmux
    passthrough check called out there; raise it if you want it.

- **2026-06-14 — Slice 3 (resurrect + sensibleOnTop): automated gates green on
  an isolated profile; user manual-validation gate open.**
  - `home/tools.nix`: added `sensibleOnTop = true` and the `resurrect` plugin
    with `@resurrect-dir = /persist/home/dx/.local/share/tmux/resurrect`.
    Confirmed the Nix config builds (resurrect + sensible plugins fetched) and
    that `sensibleOnTop` loads *beneath* the typed options — the runtime probe
    still reports `escape-time=0`, `history-limit=50000`,
    `default-terminal=tmux-256color`, `base-index=1`, so sensible does not win.
  - `bootstrap.sh`: new `setup_tmux_persistence` runs
    `install -d -o dx -g dx -m 0755 …/tmux/resurrect`, called unconditionally
    from `configure_guest` (Prerequisite A). Home Manager cannot create it
    because `/persist` is a runtime mount.
  - **Validated on a fresh isolated `dx-test` profile (cold bootstrap), per the
    chosen strategy — `dx-host` was left untouched:**
    - `DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test tests/run_all_tests.sh
      --section=6` → 128 passed, 0 failed, including a real save→kill-server→
      restore round trip (`save-file=yes`, `restored=yes`).
    - Section 3 (26) and section 14 theming (118) green on `dx-test`.
    - Resurrect dir created by bootstrap, owned `dx:dx`, writable.
  - **Behaviour harness added** (`tests/test_helpers.sh`):
    `tmux_guest_resurrect_probe` (dir exists/writable, `@resurrect-dir`,
    C-s/C-r bindings) and `tmux_guest_resurrect_roundtrip` (extracts the bound
    save/restore scripts from the live key table and runs a true save/restore
    cycle on a private socket). The round trip writes to `/persist` and restarts
    servers, so section 6 gates it behind `DX_TEST_DESTRUCTIVE=1` and self-skips
    otherwise.
  - **TDD trail observed:** against `dx-host` (pre-resurrect active config) all
    seven runtime resurrect checks were red (no dir, no `@resurrect-dir`, no
    C-s/C-r, no save/restore) while source-wiring passed; all green on the
    freshly-bootstrapped `dx-test`.
  - **Container-rebuild persistence: CONFIRMED.** Saved a uniquely-named marker
    session, ran `dx-destroy-container + dx-create-container +
    dx-start-container` on `dx-test` (preserving `/persist`), and the marker
    save file survived. Restoring it into a fresh server after the rebuild
    brought the `dxe-rebuild-marker-7788` session back, and bootstrap
    re-created the resurrect dir (still `dx:dx`). End-to-end persistence proven.
  - **Manual gate for the user:** in a real tmux, `prefix Ctrl-s` to save and
    `prefix Ctrl-r` to restore after a server restart; confirm sessions/windows
    return. Note: `dx-host` will only gain the resurrect dir + plugin on its
    next `dx-recreate` (or an explicit re-bootstrap); until then its
    `--section=6` resurrect checks will report red, which is expected.

- **Observation (out of scope, do not fix in this plan):** HM activation prints
  deprecation warnings for `programs.git.userName` / `userEmail` / `extraConfig`
  (renamed to `programs.git.settings.*` in this Home Manager). Same file
  (`home/tools.nix`), unrelated to tmux. Worth a separate cleanup.

- **Next:** Slice 3 (resurrect + sensibleOnTop). This one has real new
  behaviour to drive test-first: Prerequisite A (bootstrap must create
  `/persist/home/dx/.local/share/tmux/resurrect`) and a manual resurrect
  save/restore across a tmux server restart. Use an isolated profile for the
  save/restore + container-rebuild persistence checks per the plan's discipline,
  since those mutate persist/HM state.

## Context

Tmux is already managed by Home Manager. The source of truth is
`programs.tmux` in
`container/aarch64-darwin-apple-container-dx-nixos-25.11/home/tools.nix`;
`~/.config/tmux/tmux.conf` is generated into the Nix store.

The duplicate-looking settings in the generated config are real, but they are a
Home Manager layering issue: module defaults are emitted first, then the current
raw `extraConfig` overrides them later. The fix is not to edit the generated
file. The fix is to move option-shaped settings into typed Home Manager options
and leave only genuinely bespoke tmux commands in `extraConfig`.

The pinned Home Manager module supports the options this plan uses:
`baseIndex`, `keyMode`, `escapeTime`, `mouse`, `historyLimit`, `terminal`,
`customPaneNavigationAndResize`, `disableConfirmationPrompt`, `focusEvents`,
`sensibleOnTop`, and `plugins`. The pinned nixpkgs input also has the relevant
plugin attributes: `tmuxPlugins.resurrect`, `tmuxPlugins.continuum`,
`tmuxPlugins.tmux-fzf`, and `tmuxPlugins.vim-tmux-navigator`.

## Implementation Discipline: TDD Red > Green > Refactor

Implement every behavior-changing phase test-first:

1. **Red:** add or update the narrowest test that proves the desired behavior is
   currently missing or would regress. Run that targeted section and confirm it
   fails for the expected reason.
2. **Green:** make the smallest config/bootstrap/script change needed for that
   test to pass. Run the targeted test again.
3. **Refactor:** clean up `extraConfig`, comments, and test structure only after
   the behavior is green. Run the targeted section plus the nearby regression
   sections before moving to the next phase.

Follow the established test patterns:

- Use existing section files where the behavior already belongs:
  `tests/test_section6_tools.sh` for packaged tool/Home Manager tmux settings,
  `tests/test_section14_tinty_theming.sh` for Tinty/status-bar behavior, and
  live guest sections such as `tests/test_section11_validate_fresh.sh` or focused
  integration checks for SSH/tmux runtime behavior.
- Reuse `tests/test_helpers.sh` helpers such as `requires_container`,
  `guest_bash`, `dx_ssh`, `assert_file_contains`, and `assert_file_contains_literal`.
  Do not invent a parallel test harness.
- Prefer behavior checks through the running guest when behavior is what matters:
  use `guest_bash`/`bin/dx-ssh` to query tmux options, create sessions, exercise
  key bindings, and validate persistence. Static string checks are acceptable for
  source wiring, but they are not sufficient for runtime behavior.
- Use isolated profiles for live validation when a test creates or mutates tmux
  sessions, persist data, or Home Manager state. Do not rely on the default
  interactive `dx-host` session for destructive or stateful tests.

Work one feature at a time:

- Treat each numbered item in "Suggested Sequencing" as a separate feature slice.
- Do not start the next feature slice until the current slice has completed Red,
  Green, and Refactor, the automated checks for that slice pass, and the user has
  had a chance to manually validate the changed behavior in a real session.
- Keep commits/PRs scoped to one slice unless the user explicitly chooses to
  batch multiple slices after manual validation.
- When a slice changes runtime behavior, provide a short manual validation script
  before closing the slice. Prefer commands that log in through `bin/dx-ssh` or
  use the active isolated profile, so manual validation exercises the same path a
  user will actually take.
- If manual validation finds a gap, stay in the same slice: add a failing test for
  the gap, make it pass, refactor, and repeat the manual validation gate.

## 1. Move Supported Settings To Typed Options

Refactor `programs.tmux` toward this shape:

```nix
programs.tmux = {
  enable = true;
  shortcut = "space";
  keyMode = "vi";
  baseIndex = 1;
  escapeTime = 0;
  focusEvents = true;
  mouse = true;
  historyLimit = 50000;
  terminal = "tmux-256color";
  customPaneNavigationAndResize = true;
  disableConfirmationPrompt = true;

  extraConfig = ''
    # Bespoke settings only; see section 2.
  '';
};
```

Important caveat: `keyMode = "vi"` emits both `mode-keys vi` and
`status-keys vi`. Current behavior is `mode-keys vi` but `status-keys emacs`.
To preserve command-prompt editing behavior, keep this explicit override in
`extraConfig`:

```tmux
set -g status-keys emacs
```

This means one generated setting is still intentionally overridden. That is
acceptable because Home Manager does not model `mode-keys` and `status-keys`
independently.

## 2. Keep Active Bespoke Settings In `extraConfig`

After the typed-option migration, keep the settings that either have no typed
option or are intentionally runtime/dynamic:

```tmux
set -g status-keys emacs
set -as terminal-features ",xterm-256color:RGB"
set -as terminal-features ",xterm-256color:clipboard"
set -ga terminal-overrides ",xterm-256color:Tc"
set -s set-clipboard on
set -g repeat-time 1000
set -g display-panes-time 3000

set -g renumber-windows on
set-option -g main-pane-width 50%
set -g status-position top
set -g visual-activity off
setw -g monitor-activity on
setw -g monitor-bell on

set -g allow-passthrough on
set -ga update-environment TERM
set -ga update-environment TERM_PROGRAM
```

Keep the Tinty hooks in `extraConfig`:

```tmux
if-shell 'test -f ~/.cache/dx/tinty/tmux.conf' 'source-file ~/.cache/dx/tinty/tmux.conf'
if-shell 'test -x ~/.local/bin/dx-theme-write-tool-themes' 'run-shell -b ~/.local/bin/dx-theme-write-tool-themes'
```

Tinty owns dynamic tmux theming. Do not replace it with a static status-bar theme
plugin. Home Manager plugin output is generated before the final `extraConfig`
(extraConfig is appended via `lib.mkAfter`), so these runtime Tinty status
settings can still win over plugin defaults.

Caveat: `scripts/dx-theme-write-tool-themes.sh` unconditionally overwrites
`status-right` (and re-runs on every Tinty theme change via
`dx-theme-copy-hook.sh`). This is the desired behavior for theming, but it
collides with `tmux-continuum`, which drives its interval-based auto-save through
`status-right`. See section 5 for the mitigation; do not adopt continuum without
addressing this.

Also keep the current bespoke binds:

- Split/new-window in current directory: `c`, `%`, and `"`.
- Workflow helpers: synchronize-panes toggle, scratch popup, lazygit popup,
  choose-tree, activity/bell chooser, tiled layout, and promote-to-main-pane.
- Copy-mode-vi bindings: `v`, `V`, `C-v`, `y`, and mouse drag.

The copy-mode bindings rely on the clipboard settings above. Dropping
`set-clipboard on` or the `xterm-256color:clipboard` feature can degrade OSC52 /
terminal clipboard behavior into tmux-buffer-only copying.

## 3. Replace Hand-Written Pane Navigation

Set:

```nix
customPaneNavigationAndResize = true;
```

Then remove the hand-written hjkl pane switching and HJKL resize block from
`extraConfig`, letting Home Manager emit it consistently.

Behavior note (corrected 2026-06-14 against the pinned module — the original
claim here was wrong): the pinned Home Manager module emits the pane **resize**
binds (HJKL) with `-r` but the pane **switch** binds (hjkl) **without** `-r`.
That is identical to the prior hand-written behaviour, so this is a pure
preservation — pane switching stays non-repeatable and no muscle memory changes.
If repeatable pane switching is ever wanted, it must be added explicitly as
`bind -r h select-pane -L` (etc.) overrides in `extraConfig`; the typed option
alone will not do it.

## 4. Add Small Native Binds

Add a config reload bind:

```tmux
bind r source-file ~/.config/tmux/tmux.conf \; display-message "Config reloaded!"
```

Under Home Manager this reloads the currently built store-backed config after an
activation (`nix run …#homeConfigurations.dx.activationPackage`, the mechanism
`bootstrap.sh` uses — the guest has no `home-manager` CLI); it does not make live
edits to the generated symlink possible.

Consider adding last-window toggle:

```tmux
bind C-space last-window
```

This is a prefixed bind, so it should not collide with the generated root-table
`C-Space send-prefix` passthrough. Still treat it as an explicit UX decision and
verify nested tmux/editor behavior before adopting it, because some nested-tmux
users may rely on prefix-prefix passthrough.

Use the typed option for skip-confirmation behavior:

```nix
disableConfirmationPrompt = true;
```

Do not manually rebind `x` for this.

## 5. Add Plugins Declaratively

Use nixpkgs plugins through `programs.tmux.plugins`. Do not use TPM or any
runtime plugin manager.

Initial plugin set, before solving the Continuum/status-right interaction:

```nix
sensibleOnTop = true;
plugins = with pkgs.tmuxPlugins; [
  {
    plugin = resurrect;
    extraConfig = ''
      # Save data must live on /persist, not the ephemeral container home.
      set -g @resurrect-dir '/persist/home/dx/.local/share/tmux/resurrect'
    '';
  }
];
```

Add Continuum only after Prerequisite B is implemented and tested. The final
plugin list should keep `resurrect` and append `continuum`:

```nix
plugins = with pkgs.tmuxPlugins; [
  {
    plugin = resurrect;
    extraConfig = ''
      set -g @resurrect-dir '/persist/home/dx/.local/share/tmux/resurrect'
    '';
  }
  {
    plugin = continuum;
    extraConfig = ''
      set -g @continuum-restore 'on'
      set -g @continuum-save-interval '15'
    '';
  }
];
```

Priority:

1. `tmux-resurrect`: highest immediate value for a disposable guest, because
   sessions, windows, panes, layouts, working directories, and supported commands
   can be restored after a manual save.
2. `sensibleOnTop = true`: community baseline; not currently active in the
   generated config, so enable and verify it loads. It may overlap with typed
   options such as `terminal`, `escapeTime`, and `historyLimit`; do not assume
   ordering. Verify the generated/runtime values after enabling it and keep typed
   options authoritative if any conflict appears.
3. `tmux-continuum`: add only after auto-save is proven compatible with the
   dynamic Tinty status bar.
4. `tmux-fzf`: optional fuzzy session/window/pane switching after the cleanup
   and restore plugins land.

Set expectations for restore behavior: resurrect/continuum does not preserve
arbitrary process memory or application state. It restores tmux structure and
supported commands/working directories, subject to plugin strategy support.

### Prerequisite A: persist the resurrect save directory

The default resurrect save path (`~/.local/share/tmux/resurrect`) is NOT
persisted. `bootstrap.sh` only persists specific paths by symlinking them into
`/persist/home/dx/...` (gh config, `~/.local/share/keyrings`, `~/.gemini`,
etc.); there is no general persistence of `~/.local/share` or `~/.local/state`.
On a container rebuild (`dx-destroy-container + dx-create-container`, the
lifecycle exercised by the test suite's section 16), every saved session is lost,
which defeats the entire rationale for the plugin.

The `@resurrect-dir` above points the save data at `/persist`. Because `/persist`
is a runtime mount, declarative Home Manager cannot create that directory; add a
directory creation step to `bootstrap.sh`. The only thing genuinely needed is to
*create* the directory: `bootstrap.sh` already chowns this subtree to `dx:dx`
recursively in the persistence setup (it runs `chown -R dx:dx /persist/home/dx`
and `chown -R dx:dx /persist/home/dx/.local`), so ownership is handled by the
existing pattern. The `-o dx -g dx` below is belt-and-suspenders so the directory
is correct regardless of ordering relative to those chowns:

```bash
install -d -o dx -g dx -m 0755 /persist/home/dx/.local/share/tmux/resurrect
```

Restart vs rebuild: without this, restore works only across a tmux *server*
restart, not a container *rebuild*. With it, both work.

### Prerequisite B: continuum auto-save vs the dx-theme status bar

`scripts/dx-theme-write-tool-themes.sh` overwrites `status-right`, and that
overwrite is emitted/runs after the plugins (see section 2). tmux-continuum
relies on `status-right` for its interval-based auto-save, so the dx-theme pill
clobbers continuum's save hook: `@continuum-restore 'on'` may still restore, but
interval saves silently never fire, leaving nothing fresh to restore.

Resolve this before adding Continuum: either embed Continuum's save interpolation
into the pill `status-right` string built in `dx-theme-write-tool-themes.sh`, or
decide not to use Continuum and rely on manual `prefix + Ctrl-s` saves from
resurrect only.

Before implementing the auto-save path, inspect the packaged Continuum plugin and
name the exact `status-right` format/interpolation it requires. Preserve that
exact format in the pill `status-right` string rather than relying on a vague
"Continuum hook" description. If auto-save is desired, update the existing
`tests/test_section14_tinty_theming.sh` status-right assertions so the captured
rendered config still contains:

- the existing SYNC pill predicate/label,
- the existing PREFIX pill predicate/label,
- the exact Continuum save interpolation.

Then use the section-5 verification (create a session, wait past the save
interval, kill the server, confirm restore) to prove auto-save actually fires —
do not assume it.

## 6. Optional Navigation Integrations

Do not half-install `vim-tmux-navigator`.

Seamless prefix-less `C-h/j/k/l` navigation between tmux panes and Neovim splits
requires both sides:

- tmux side: `tmuxPlugins.vim-tmux-navigator`
- Neovim side: `christoomey/vim-tmux-navigator` or an equivalent nixvim plugin

There is no matching Neovim-side navigator plugin in the current nixvim config.
Add both sides together or skip it.

If choosing a `sesh + zoxide` workflow instead of `tmux-fzf`, plan explicit
package additions and bindings outside `programs.tmux.plugins`; do not treat that
as just another tmux plugin toggle.

## Suggested Sequencing

Complete exactly one numbered slice at a time. After each slice, stop at the
manual validation gate and do not begin the next slice until the user confirms
the behavior is acceptable.

1. **Typed options cleanup** — ✅ DONE 2026-06-14 (see Progress Log; automated
   gates green, user manual-validation gate open).
   - Red: update section 6 so the migrated `baseIndex` behavior is asserted as a
     typed Nix option or runtime/generated tmux behavior instead of the old raw
     `set -g base-index 1` string. Add/adjust a guest behavior check that queries
     `tmux show -g base-index` and `tmux showw -g pane-base-index` via
     `guest_bash` when a container is available.
   - Green: move option-shaped settings to typed Home Manager options while
     keeping the bespoke settings from section 2.
   - Refactor: trim only the duplicated `extraConfig` lines that now have typed
     equivalents, then rerun section 6 and the relevant live guest check.
   - Manual validation gate: activate the config in an isolated profile, log in
     through `bin/dx-ssh`, and confirm the expected tmux options and basic tmux
     session startup behavior from inside the guest.
2. **Pane navigation and native binds** — ✅ DONE 2026-06-14 (see Progress Log;
   automated gates green, user manual-validation gate open).
   - Red: add coverage proving hjkl pane selection and HJKL resizing still work,
     and either assert the new repeatable `-r` behavior or document that
     repeatable pane switching is intentionally accepted.
   - Green: enable `customPaneNavigationAndResize`, add the reload bind, and use
     `disableConfirmationPrompt`.
   - Refactor: remove the hand-written pane nav/resize block only after the
     generated/runtime key bindings pass.
   - Manual validation gate: in an SSH login tmux session, manually exercise pane
     selection, pane resizing, config reload, and kill-pane behavior before
     continuing.
3. **Resurrect and `sensibleOnTop`** — ✅ DONE 2026-06-14 (see Progress Log;
   isolated-profile gates green incl. save/restore + rebuild persistence, user
   manual-validation gate open).
   - Red: add a failing bootstrap/static check for the resurrect save directory
     and a live SSH-backed tmux behavior check for manual resurrect save/restore.
   - Green: add `resurrect`, `sensibleOnTop`, and the targeted bootstrap
     directory creation.
   - Refactor: verify plugin ordering does not override typed-option values, then
     clean up comments/tests.
   - Manual validation gate: create a real tmux session through SSH, manually save
     it with resurrect, restart the tmux server, and confirm the session restores
     before moving on.
4. **Continuum**
   - Red: inspect the packaged Continuum plugin, add a failing section 14
     assertion for the exact `status-right` save interpolation alongside the
     existing SYNC/PREFIX pills, and add a live behavior check that fails until
     interval auto-save actually creates a fresh resurrect save.
   - Green: preserve the exact Continuum interpolation inside the dynamic Tinty
     `status-right` pill string, then add Continuum.
   - Refactor: keep the status-right generation readable and rerun section 14,
     the Continuum behavior check, and the tmux runtime option checks.
   - Manual validation gate: leave an SSH tmux session running past the configured
     save interval, confirm the save timestamp advances without manual save, then
     restart tmux and confirm restore works with the Tinty status bar intact.
5. **Optional picker/navigation integrations**
   - Start only after restore behavior is verified. Use the same Red > Green >
     Refactor loop and add both tmux and Neovim sides together for
     `vim-tmux-navigator`.
   - Manual validation gate: exercise the picker or cross-Neovim/tmux navigation
     interactively before accepting the slice.

## Verification

After the option migration, activate the config the same way `bootstrap.sh` does
(the guest does not ship the `home-manager` CLI, and in-guest the flake lives at
`/guest-bootstrap`, not the repo path):

```bash
nix run --extra-experimental-features 'nix-command flakes' \
  /guest-bootstrap#homeConfigurations.dx.activationPackage
tmux source-file ~/.config/tmux/tmux.conf
tmux show -s | rg '^(default-terminal|escape-time|set-clipboard|focus-events) '
tmux show -g | rg '^(status-keys|mouse|history-limit|repeat-time|display-panes-time) '
tmux showw -g | rg '^(mode-keys|pane-base-index|monitor-activity|monitor-bell) '
tmux list-keys | rg 'select-pane|resize-pane|source-file'
```

Test migration checks:

- Update `tests/test_section6_tools.sh` only for the assertions whose lines
  actually move to typed options. Concretely, the migrated line asserted there is
  `set -g base-index 1` (becomes `baseIndex = 1`, which also removes the
  `setw -g pane-base-index 1` line); assert it as the Nix option or via
  generated/runtime tmux state instead. Do NOT touch the assertions for
  `set -g display-panes-time 3000`, `set -g renumber-windows on`,
  `set-option -g main-pane-width 50%`, or the `+`/`a`/`b` binds — those lines
  stay in `extraConfig` per section 2, so their assertions keep passing.
- Add runtime checks, gated by `requires_container`, that use `guest_bash` or
  `dx_ssh` to inspect the active guest tmux behavior after login. At minimum,
  validate:
  - `tmux show -g base-index`, `tmux showw -g pane-base-index`,
    `tmux show -g mouse`, `tmux show -s escape-time`,
    `tmux show -g history-limit`, and `tmux showw -g mode-keys`.
  - `tmux list-keys` contains the expected reload, pane navigation, resize, and
    workflow bindings.
  - A new tmux session created through SSH starts successfully and sees the
    activated config, rather than only proving that `tools.nix` contains strings.
- Add static or generated-config coverage for `customPaneNavigationAndResize`.
  The test should prove hjkl pane selection and HJKL pane resizing still exist,
  and should either assert the new repeatable `-r` behavior or document that
  repeatable pane switching is intentionally accepted.
- Add bootstrap/static coverage for the resurrect save directory: assert that
  bootstrap creates `/persist/home/dx/.local/share/tmux/resurrect`. Do not assert
  the absence of a recursive `chown` over `/persist/home/dx/.local` — bootstrap
  legitimately already runs `chown -R dx:dx /persist/home/dx/.local` (keyring
  setup) and broader `chown -R dx:dx /persist/home/dx` steps, which the persisted
  home relies on.
- Keep `tests/test_section14_tinty_theming.sh` coverage for the status pill
  writer. If Continuum is added, extend the captured `status-right` assertions so
  the existing SYNC/PREFIX pill predicates and labels remain present alongside
  the exact Continuum save interpolation.

After adding `sensibleOnTop`, repeat the runtime checks above and specifically
confirm typed-option values remain authoritative for terminal, escape time, focus
events, mouse, history limit, and base indices.

For Resurrect/Continuum, avoid false positives and false negatives:

- Through `guest_bash`/`dx_ssh`, create a named test session, windows, panes, and
  working directories in the running guest.
- For resurrect, trigger the manual save path and confirm a save appears under
  `/persist/home/dx/.local/share/tmux/resurrect`, then kill/restart the tmux
  server and verify sessions, windows, panes, layouts, working directories, and
  supported commands return.
- For Continuum, wait longer than the configured `@continuum-save-interval` and
  verify that interval auto-save updates the resurrect save before killing the
  server. Do not treat `@continuum-restore on` or a loaded key binding as proof
  that auto-save works.
- For container rebuild persistence, run the check in an isolated profile: create
  a saved session, recreate the container while preserving `/persist`, then log
  back in through SSH and verify the saved session data is still available.

After plugins land, also check:

```bash
tmux list-keys | rg 'continuum|resurrect'
```

## Out Of Scope

- Editing the generated `~/.config/tmux/tmux.conf` directly.
- TPM or any runtime plugin manager.
- Static status-bar theme plugins such as catppuccin/tmux; Tinty owns dynamic
  status theming.
