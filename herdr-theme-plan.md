# Plan — make `herdr` work with `dx-theme`

Drafted 2026-08-11. Findings were probed against the live `dx-host` guest
running `herdr 0.7.5` from nixpkgs, not inferred from upstream documentation.

**Implemented 2026-08-16. Both layers shipped, and Layer 2's central finding
below turned out to be wrong — see the correction before relying on any of it.**

## Status

| Layer | What it covers | Verdict |
| --- | --- | --- |
| 1 — pane colors | Everything *inside* a pane: shell, editors, `ls` colors, agent output | **Done.** The restore prefix is shared by `dx-ssh` and `dx-herdr` in `bin/lib/dx-ssh-common.sh` |
| 2 — herdr chrome | Herdr's own tabs, status bar, borders | **Done, and matched exactly.** The "no palette" finding was wrong |

### Correction: Herdr does accept a full custom palette

This plan concluded that `[theme]` took exactly one key, `name`, restricted to
eight built-in themes, so exact base16 matching was "impossible" and four of
sixteen aliases — including the default `dark` — had no match at all. That
elimination sweep missed the mechanism: with

```toml
[theme]
name = "terminal"

[theme.custom]
accent = "#a89bb9"
panel_bg = "#3B3228"
…
```

Herdr honours a complete 16-slot palette. Re-probed on herdr 0.7.5 with the
same `herdr config check` oracle this plan established: the live config
validates `config: ok` with no warnings, while planting an unknown key in that
same table *is* reported as `unknown config key theme.custom.<key>; ignoring
key`. So the keys being written are ones Herdr honours, not ones it silently
drops.

Everything downstream of the old finding is therefore obsolete: the
nearest-neighbour mapping table, the three-way product decision, and the
recommendation to do nothing or map only exact matches. No mapping exists in
the code, because none is needed — `dx-theme` hands Herdr the same base16
palette it hands every other tool. Retained below as the record of what was
probed and why the wrong conclusion was reached.

The `[theme] name` mapping table is kept for reference only. It describes an
approximation that was never built.

### Where it landed

- **Layer 1:** `dx_guest_theme_restore_prefix` in `bin/lib/dx-ssh-common.sh`,
  used by both `bin/dx-ssh` and `bin/dx-herdr`. Open question 3 below is
  answered: the prefix *is* shared, because leaving it inline in one caller is
  precisely how this defect shipped.
- **Layer 2:** `write_herdr_theme` and `write_herdr_host_terminals` in
  `container/…/scripts/dx-theme-write-tool-themes.sh`, beside `apply_tmux_pills`
  as this plan proposed.
- **Mid-session switching, listed below as unsolvable without upstream
  passthrough support:** solved. Herdr treats OSC from inside a pane as a
  transient child override and undoes it on exit, so `dx-theme-restore` and
  `dx-theme-osc-hook` detect a Herdr pane and hand off to the writer, which
  writes the palette to each attached client's real host TTY (found by walking
  `/proc` for non-server `herdr` processes) and queries the new defaults back so
  Herdr updates its cached host theme. No Herdr passthrough sequence is needed,
  which is why open questions 1 and 2 no longer block anything.

## Layer 1 — `dx-herdr` never restores the theme

`bin/dx-ssh:17` restores the theme before starting tmux:

```bash
REMOTE_TMUX_CMD="if [ -x /home/dx/.local/bin/dx-theme-restore ]; then /home/dx/.local/bin/dx-theme-restore 2>/dev/null || true; fi; …; tmux attach -t dx || tmux new-session -s dx"
```

`bin/dx-herdr:130` does not:

```bash
dx_run_interactive_ssh "herdr"
```

So a Herdr session inherits whatever palette the terminal happened to be
carrying. This was missed because the two entry points were unified at the SSH
transport layer (F10) while the theme restore stayed inline in `dx-ssh`'s
command body, where it is invisible from `dx-herdr`.

### Fix

```bash
REMOTE_HERDR_CMD="if [ -x /home/dx/.local/bin/dx-theme-restore ]; then /home/dx/.local/bin/dx-theme-restore 2>/dev/null || true; fi; herdr"
dx_run_interactive_ssh "$REMOTE_HERDR_CMD"
```

**Ordering is what makes this correct, and it is the whole design.** The restore
runs *before* `herdr` starts, while the outer terminal is still directly
attached to the SSH pty. The OSC sequences therefore reach the terminal with no
multiplexer in the path, so no passthrough support is required from Herdr at
all. Verified over the real boundary with `$TMUX` unset — `dx-theme-restore`
emits bare `ESC ] 4 ; 0 ; rgb:3B/32/28 ESC \`, which is exactly the form a
directly-attached terminal expects.

### Known limitation this does *not* fix

Running `dx-theme <alias>` **inside** a Herdr pane will very likely not
repaint the outer terminal. `dx-theme-restore.sh:44-51` wraps OSC in a tmux DCS
passthrough only when `$TMUX` is set:

```bash
if [ -n "${TMUX:-}" ]; then
  printf '\033Ptmux;\033\033]%s\033\\\033\\' "$payload"
else
  printf '\033]%s\033\\' "$payload"
fi
```

Inside Herdr, `$TMUX` is unset, so the bare branch is taken and Herdr's terminal
emulator is free to consume the sequence. Herdr exposes **no OSC passthrough
control**: the only `passthrough` string in the binary is
`right_click_passthrough_modifier` (a mouse setting), and the `[terminal]`
config section has no forwarding key — every candidate probed
(`passthrough`, `allow_osc`, `osc_passthrough`, `color_protocol`,
`kitty_color_protocol`, `truecolor`, …) was rejected as unknown.

**Not tested:** whether Herdr forwards, swallows, or internally applies OSC
4/10/11 from a pane. It clearly parses OSC (`osc_dispatch` symbol, plus a full
kitty color protocol implementation with its own diagnostics). Settling this
needs one interactive session; until then, treat mid-session theme switching as
requiring a Herdr restart.

If it turns out Herdr does swallow them, the equivalent of the tmux DCS branch
would be needed in `dx-theme-restore.sh` — but only if Herdr defines a
passthrough sequence at all, which on current evidence it does not.

## Layer 2 — Herdr's chrome cannot match a base16 scheme

Probed directly against the guest using `herdr config check` as an oracle: it
reports `unknown config key <section>.<key>; ignoring key`, so a key that is
*not* reported is valid.

**`[theme]` accepts exactly one key: `name`.** Established by elimination over
40 candidates — `palette`, `colors`, `color`, `background`, `foreground`,
`accent`, `border`, `cursor`, `selection`, `base00`, `base16`, `scheme`,
`mode`, `dark`, `light`, `style`, `variant`, `preset`, `highlight`, `primary`,
`surface`, `tab_active`, `status_bar`, … all rejected. Only `name` survived.

Its accepted values are 8 built-in themes:

```
ayu  catppuccin  dracula  gruvbox  nord  one-dark  rose-pine  solarized
```

There is no custom theme directory and no way to inject a palette, so the
tinty-driven approach used for tmux pills (`dx-theme-write-tool-themes.sh:321`,
`apply_tmux_pills`) has no analogue here. `herdr config check` does not validate
the value, so an unknown name fails at runtime rather than at check time.

Herdr's full config surface, for reference: `theme`, `keybinding`, `terminal`,
`session`, `update`, `ui`, `advanced`, `worktree`, `experimental`.

### The best achievable mapping

| dx-theme alias | Nearest `[theme] name` |
| --- | --- |
| `catppuccin`, `catppuccin-latte/frappe/macchiato/mocha` | `catppuccin` |
| `gruvbox-dark`, `light` (`base16-gruvbox-light-medium`) | `gruvbox` |
| `rose-pine`, `rose-pine-moon`, `rose-pine-dawn` | `rose-pine` |
| `solarized-dark`, `solarized-light` | `solarized` |
| `dark` (`base16-mocha`) | **no equivalent** |
| `everforest-dark`, `everforest-light` | **no equivalent** |
| `shades-of-purple` | **no equivalent** |

Four of sixteen aliases have no match, and one of them is `dark` — the default
(`theme.nix:40`) and the guest's current scheme (`base16-mocha`). So the most
common case is exactly the one the mapping cannot serve.

Herdr also has no light/dark distinction within a built-in name, so
`catppuccin-latte` (light) and `catppuccin-mocha` (dark) both collapse to
`catppuccin` and would render identically.

### Decision required before implementing Layer 2

1. **Do nothing.** Pane contents are themed by Layer 1; chrome stays on Herdr's
   default. Zero maintenance, no wrong-looking approximations.
2. **Map only exact matches** (`catppuccin`, `gruvbox`, `rose-pine`,
   `solarized`), leave the rest on Herdr's default.
3. **Map everything to a nearest neighbour**, accepting that `dark`,
   `everforest-*`, and `shades-of-purple` render as something they are not.

Recommendation: **option 2 at most**, and option 1 is defensible. An
approximation that is visibly wrong next to correctly-themed pane contents is
worse than an obvious default, and the alias that matters most has no match.

## Where the code goes

- **Layer 1:** `bin/dx-herdr:130`.
- **Layer 2, if built:** an `apply_herdr_theme` beside `apply_tmux_pills` in
  `dx-theme-write-tool-themes.sh` (defined at :321, invoked at :419) — the
  established pattern for per-tool theme application. Herdr reloads live via
  `herdr server reload-config`, so no session restart is needed for chrome.
- **The mapping itself:** `home/theme.nix` alongside `dxThemes` (:8), preserving
  the file's stated "adding a theme is a one-place edit" property. Do **not**
  hardcode the mapping in the shell script.

### Do not route Layer 2 through `dx_seed_herdr_config`

The seeder deliberately only *adds* missing keys and preserves any explicit user
value (F7 in `herdr-refactor.md`). That is correct for seeding and wrong for
theme switching: it would never update an existing `[theme] name`. Theme
application needs a writer that overwrites that one key, which is a different
operation with different safety requirements — it must still fail closed on TOML
it cannot parse, and must not clobber unrelated user config.

## Testing

Per `constitution.md`: Red → Green → Refactor, behavior over configuration
parsing.

**Layer 1** — a fake `ssh` fixture asserting the remote command body invokes
`dx-theme-restore` *before* `herdr`, ordering included. `tests/lib/fake-tools.sh`
now provides `fake_ssh_write`, which exposes the decoded body as
`DX_FAKE_GUEST_CMD`, so the assertion can match the real body rather than the
transport wrapper. Section 23 is the right home; Section 14 owns tinty theming
and Section 9 owns host-script contracts.

**Coverage note:** neither `bin/dx-herdr` nor
`container/.../scripts/dx-theme-write-tool-themes.sh` is inside the coverage
gate's scope (`bin/lib`, `bootstrap/`, `scripts/lib` — see
`tests/run-coverage-linux.sh:7`). So neither layer is protected by the 100%
ratchet, and both need deliberate behavior tests rather than relying on the
gate. This is the same blind spot recorded for `dx-ai.sh` in
`herdr-refactor.md`.

**Live acceptance** (needs one interactive session, cannot be automated here):

1. `dx-herdr` on a guest whose scheme is not the terminal default → pane colors
   match `dx-theme current`.
2. `dx-theme light` run inside a Herdr pane → record whether the outer terminal
   repaints. This settles the open passthrough question.
3. Detach and reattach → colors survive.

## Open questions

1. Does Herdr forward, swallow, or internally apply OSC 4/10/11 from a pane?
   Determines whether mid-session switching can ever work.
2. Does Herdr define any DCS passthrough sequence (the tmux `\033Ptmux;`
   analogue)? No evidence in the binary; worth confirming against upstream
   before concluding it cannot be done.
3. Should `dx-ssh`'s inline theme-restore snippet and `dx-herdr`'s move into a
   shared helper in `bin/lib/dx-ssh-common.sh`? It is the same duplication F10
   set out to remove, and this defect is a direct consequence of it — but the
   two bodies differ (tmux guard vs none), so the shared piece is just the
   restore prefix.

## Related

- `herdr-refactor.md` — F10 (the SSH boundary unification that left this gap),
  F7 (the seeder's preserve-user-values contract).
- `bin/dx-ssh:17`, `bin/dx-herdr:130`,
  `container/…/scripts/dx-theme-restore.sh:44-51`,
  `container/…/scripts/dx-theme-write-tool-themes.sh:321,419`,
  `container/…/home/theme.nix:8,40`.
