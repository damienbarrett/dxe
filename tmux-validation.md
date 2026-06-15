# Tmux Improvements — Manual Validation Guide

Hands-on checks for the five tmux slices (see [tmux-plan.md](tmux-plan.md) for
the implementation log). The automated behaviour tests already cover the wiring;
this guide is for the manual gates — the things that need a real terminal,
real keypresses, or a human eye.

## Setup

Run everything inside the **dx-test** isolated profile, which has all five
slices active. The default `dx-host` only has slices 1–2 until you
`dx-recreate` it.

```bash
./bin/dx-profile dx-test ./bin/dx-ssh
```

That lands you in a tmux session. The tmux prefix is **`Ctrl-Space`** throughout
(press and release it, then the next key). To see every binding at any time:
`Ctrl-Space ?`.

When you are done, tear the test environment down:

```bash
./bin/dx-profile dx-test bash -c './bin/dx-destroy && ./bin/dx-destroy-volumes --force'
```

---

## Slice 1 — Typed options migration

The core tmux options moved to typed Home Manager options. Runtime behaviour is
unchanged on purpose, so the check is "nothing regressed."

Query the live values:

```bash
tmux show -g base-index        # 1
tmux showw -g pane-base-index  # 1
tmux show -g mouse             # on
tmux show -g history-limit     # 50000
tmux show -s escape-time       # 0
tmux showw -g mode-keys        # vi
tmux show -g status-keys       # emacs   <- the subtle one (vi keyMode, emacs prompt)
```

- Windows and panes number from **1** (check the status bar).
- Mouse-click between panes to confirm mouse mode is on.
- `Ctrl-Space [` enters copy mode; `v` starts a selection, `y` yanks (vi-style).

---

## Slice 2 — Pane navigation + native binds

First make some panes: `Ctrl-Space "` (side-by-side) or `Ctrl-Space %`
(stacked), a couple of times.

- **Switch panes:** `Ctrl-Space` then `h` / `j` / `k` / `l` (one move per
  prefix press).
- **Resize panes:** `Ctrl-Space` then `Shift+H` / `J` / `K` / `L`. These are
  *repeatable* — keep tapping `H` within ~1s without re-pressing the prefix.
- **Reload config:** `Ctrl-Space r` → a **"tmux config reloaded"** message
  appears.
- **Kill pane, no confirmation:** `Ctrl-Space x` → the pane closes immediately
  (no `y/n` prompt).

---

## Slice 3 — tmux-resurrect (manual save / restore, persisted)

Saves your whole session layout to `/persist`, surviving a container rebuild.

1. Make a couple of windows/panes and `cd` somewhere distinctive in each.
2. **Save:** `Ctrl-Space Ctrl-s` → brief "saved" message.
3. Confirm it landed on persistent storage:
   ```bash
   ls -t /persist/home/dx/.local/share/tmux/resurrect | head
   ```
4. **Restore across a server restart:** `tmux kill-server` (this drops your SSH
   session), reconnect with `./bin/dx-profile dx-test ./bin/dx-ssh`, then
   `Ctrl-Space Ctrl-r` → windows, panes, and working directories come back.

The container-rebuild survival (destroy + recreate the container, save still
restores) is already automated-verified, so you do not need to rebuild to trust
it.

---

## Slice 4 — tmux-continuum (automatic save) + theme-pill coexistence

Auto-saves every 15 minutes and auto-restores on a fresh server start — and
keeps working even when the dynamic theme pill rewrites the status bar.

Fast path (don't wait 15 minutes), with the session attached:

```bash
tmux set -g @continuum-save-interval 1                      # 1-minute interval for testing
ls /persist/home/dx/.local/share/tmux/resurrect | wc -l     # note the count
# wait ~60-90s, then:
ls /persist/home/dx/.local/share/tmux/resurrect | wc -l     # count went up = auto-save fired
tmux set -g @continuum-save-interval 15                      # put it back
```

Coexistence with theming: run `dx-theme light` then `dx-theme dark`. The status
bar pill should re-render each time, and the continuum save token should survive:

```bash
tmux show -g status-right | grep -o 'continuum_save.sh'      # still present after a theme switch
```

---

## Slice 5 — vim-tmux-navigator (prefix-less Ctrl-hjkl)

`Ctrl-h/j/k/l` with **no prefix** moves between tmux panes *and* Neovim splits
seamlessly.

1. Side-by-side panes: `Ctrl-Space "`.
2. In a shell pane, just press **`Ctrl-l` / `Ctrl-h`** (no prefix) — focus jumps
   between tmux panes.
3. The seamless part: open Neovim in the left pane (`nvim`), split it with
   `:vsplit`. `Ctrl-h` / `Ctrl-l` move between the Neovim splits; at the **edge**
   the same key crosses out into the adjacent **tmux** pane, and back in.
4. Scrolling still works: in Neovim, `Ctrl-d` / `Ctrl-u` still scroll (those
   replaced the old `Ctrl-j` / `Ctrl-k` scroll aliases that the navigator now
   owns).

To revert just this slice: `git revert dbbb411` (or follow the steps in the
header of `container/.../nvim/plugins/vim-tmux-navigator.nix`).

---

## Promoting to dx-host

Once you're happy, the default `dx-host` picks up slices 3–5 on its next
recreate (slices 1–2 are already active there):

```bash
./bin/dx-recreate
```

`/nix` and `/persist` are preserved across a recreate.
