#!/bin/bash
# Live tmux behavior probes. Safe to source after tests/test_helpers.sh setup.

# Start a throwaway tmux server inside the guest on a private -L socket, print
# the live runtime state as `key=value` lines, then tear it down. This reads
# the activated ~/.config/tmux/tmux.conf the same way a real server would, so
# it validates behaviour rather than config strings. It never touches the host
# and never touches the user's interactive dx-host session (separate socket +
# server). Prints `__PROBE_FAILED__` and returns non-zero if no server starts.
#
# $1: optional extra guest script appended after the standard option dump. It
#     may use the `g`/`s`/`w` helpers (global/server/window value queries) and
#     the `$sock` socket name to emit additional `key=value` lines.
tmux_guest_probe() {
    local extra="${1:-}"
    container_exec_dx_bash '
        set -u
        sock="dxe-bhv-$$-${RANDOM}"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        started=no
        for _ in 1 2 3; do
            if tmux -L "$sock" new-session -d -s probe -x 200 -y 50 >/dev/null 2>&1; then started=yes; break; fi
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true; sleep 1
        done
        if [ "$started" != yes ]; then echo "__PROBE_FAILED__"; exit 1; fi
        # Stop tmux-continuum auto-restoring the user save into throwaway probe
        # servers (a startup side effect that also races our queries).
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        g() { tmux -L "$sock" show -gv "$1" 2>/dev/null; }
        s() { tmux -L "$sock" show -sv "$1" 2>/dev/null; }
        w() { tmux -L "$sock" showw -gv "$1" 2>/dev/null; }
        printf "base-index=%s\n"       "$(g base-index)"
        printf "pane-base-index=%s\n"  "$(w pane-base-index)"
        printf "mouse=%s\n"            "$(g mouse)"
        printf "history-limit=%s\n"    "$(g history-limit)"
        printf "escape-time=%s\n"      "$(s escape-time)"
        printf "focus-events=%s\n"     "$(g focus-events)"
        printf "default-terminal=%s\n" "$(g default-terminal)"
        printf "mode-keys=%s\n"        "$(w mode-keys)"
        printf "status-keys=%s\n"      "$(g status-keys)"
        printf "set-clipboard=%s\n"    "$(s set-clipboard)"
        printf "repeat-time=%s\n"      "$(g repeat-time)"
        printf "renumber-windows=%s\n" "$(g renumber-windows)"
        printf "status-position=%s\n"  "$(g status-position)"
        '"$extra"'
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Start a throwaway tmux server inside the guest and report the live, parsed
# prefix key table plus pane-navigation effects as `key=value` lines. Like
# tmux_guest_probe this reads the activated config the way a real server does,
# so it proves the generated bindings actually parsed into the runtime key
# table (not that strings exist in tools.nix). Guest only; never touches the
# host or the user's interactive session.
#
# Emits, for each of h j k l H J K L r x: `<key>.repeat=yes|no` and
# `<key>.cmd=<command>`; plus `pane-after-right`/`pane-after-left` (active pane
# index after select-pane -R/-L in a horizontal split) and `reload-sources-ok`
# (whether sourcing the activated tmux.conf — what the reload bind does —
# succeeds).
tmux_guest_keys_probe() {
    container_exec_dx_bash '
        set -u
        sock="dxe-keys-$$-${RANDOM}"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        started=no
        for _ in 1 2 3; do
            if tmux -L "$sock" new-session -d -s probe -x 200 -y 50 >/dev/null 2>&1; then started=yes; break; fi
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true; sleep 1
        done
        if [ "$started" != yes ]; then echo "__PROBE_FAILED__"; exit 1; fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        keyfact() {
            key="$1"; label="$2"
            line="$(tmux -L "$sock" list-keys -T prefix | grep -E "^bind-key( +-r)? +-T prefix ${key} +" | head -n1)"
            if printf "%s" "$line" | grep -qE "^bind-key +-r +-T"; then
                printf "%s.repeat=yes\n" "$label"
            else
                printf "%s.repeat=no\n" "$label"
            fi
            printf "%s.cmd=%s\n" "$label" "$(printf "%s" "$line" | sed -E "s/^bind-key( +-r)? +-T prefix ${key} +//")"
        }
        keyfact h h; keyfact j j; keyfact k k; keyfact l l
        keyfact H H; keyfact J J; keyfact K K; keyfact L L
        keyfact r r; keyfact x x
        tmux -L "$sock" split-window -h >/dev/null 2>&1
        tmux -L "$sock" select-pane -t 1 >/dev/null 2>&1
        tmux -L "$sock" select-pane -R >/dev/null 2>&1
        printf "pane-after-right=%s\n" "$(tmux -L "$sock" display-message -p "#{pane_index}")"
        tmux -L "$sock" select-pane -L >/dev/null 2>&1
        printf "pane-after-left=%s\n" "$(tmux -L "$sock" display-message -p "#{pane_index}")"
        if tmux -L "$sock" source-file "$HOME/.config/tmux/tmux.conf" >/dev/null 2>&1; then
            printf "reload-sources-ok=yes\n"
        else
            printf "reload-sources-ok=no\n"
        fi
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Probe tmux-resurrect wiring from inside the guest: whether the persisted
# save directory exists/writable, the runtime @resurrect-dir value, and whether
# the save/restore key bindings parsed into the live key table. Guest only.
tmux_guest_resurrect_probe() {
    container_exec_dx_bash '
        set -u
        rdir="/persist/home/dx/.local/share/tmux/resurrect"
        [ -d "$rdir" ] && echo "dir-exists=yes" || echo "dir-exists=no"
        [ -w "$rdir" ] && echo "dir-writable=yes" || echo "dir-writable=no"
        sock="dxe-rsr-$$-${RANDOM}"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        if ! tmux -L "$sock" new-session -d -s base -x 200 -y 50 >/dev/null 2>&1; then
            echo "__PROBE_FAILED__"; exit 1
        fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        printf "resurrect-dir=%s\n" "$(tmux -L "$sock" show -gv @resurrect-dir 2>/dev/null)"
        if tmux -L "$sock" list-keys -T prefix | grep -qE "prefix C-s "; then echo "save-bound=yes"; else echo "save-bound=no"; fi
        if tmux -L "$sock" list-keys -T prefix | grep -qE "prefix C-r "; then echo "restore-bound=yes"; else echo "restore-bound=no"; fi
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Run a full tmux-resurrect save/restore round trip inside the guest and report
# whether it actually worked: create a uniquely-named session, trigger the
# resurrect save (via its bound run-shell script), assert a save file lands
# under the persisted dir, kill the server, start a fresh one, trigger restore,
# and assert the named session came back. Guest only; uses a private socket so
# it never touches the user's session. Echoes `save-file=` `restored=`.
tmux_guest_resurrect_roundtrip() {
    container_exec_dx_bash '
        set -u
        rdir="/persist/home/dx/.local/share/tmux/resurrect"
        sock="dxe-rt-$$-${RANDOM}"
        marker="dxe-restore-probe-$$-${RANDOM}"
        # Extract the path a binding run-shells, tolerating optional quoting.
        bound_path() {
            local line cmd
            line="$(tmux -L "$sock" list-keys -T prefix | grep -E "prefix $1 " | head -n1)"
            cmd="${line#*run-shell }"
            cmd="${cmd# }"
            cmd="${cmd%\"}"; cmd="${cmd#\"}"
            printf "%s" "$cmd"
        }
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        if ! tmux -L "$sock" new-session -d -s "$marker" -x 200 -y 50 >/dev/null 2>&1; then
            echo "__PROBE_FAILED__"; exit 1
        fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        tmux -L "$sock" new-window -t "$marker" >/dev/null 2>&1
        save_sh="$(bound_path C-s)"
        restore_sh="$(bound_path C-r)"
        tmux -L "$sock" run-shell "$save_sh" >/dev/null 2>&1 || true
        saved=no
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ls "$rdir"/tmux_resurrect_*.txt >/dev/null 2>&1; then saved=yes; break; fi
            sleep 1
        done
        echo "save-file=$saved"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        tmux -L "$sock" new-session -d -s placeholder -x 200 -y 50 >/dev/null 2>&1
        tmux -L "$sock" run-shell "$restore_sh" >/dev/null 2>&1 || true
        restored=no
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if tmux -L "$sock" list-sessions -F "#{session_name}" 2>/dev/null | grep -qx "$marker"; then restored=yes; break; fi
            sleep 1
        done
        echo "restored=$restored"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Probe the live status-right after a guest tmux server starts, to prove the
# dx-theme pill generator and tmux-continuum coexist. On startup continuum
# injects #(continuum_save.sh) into status-right, then the dx-theme generator
# (run-shell -b) rebuilds status-right; the generator must preserve continuum's
# token or interval auto-save stops firing. Polls until the SYNC pill appears
# (generator has run), then reports whether continuum's token and the
# SYNC/PREFIX pills are all present. Guest only.
tmux_guest_statusright_probe() {
    container_exec_dx_bash '
        set -u
        sock="dxe-sr-$$-${RANDOM}"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        started=no
        for _ in 1 2 3; do
            if tmux -L "$sock" new-session -d -s probe -x 200 -y 50 >/dev/null 2>&1; then started=yes; break; fi
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true; sleep 1
        done
        if [ "$started" != yes ]; then echo "__PROBE_FAILED__"; exit 1; fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        # continuum only injects its save token into status-right when it is the
        # sole tmux server, which is brittle in a harness (any other server,
        # incl. an interactive dx session, suppresses it). Inject a
        # representative token ourselves, then run the pill generator exactly as
        # the live hook does; it must carry the token across its status-right
        # rewrite — the actual fix under test.
        tmux -L "$sock" set -g status-right "#(/dxe-test-path/continuum_save.sh)" >/dev/null 2>&1
        tmux -L "$sock" run-shell "$HOME/.local/bin/dx-theme-write-tool-themes" >/dev/null 2>&1 || true
        sr=""
        for _ in 1 2 3 4 5 6 7 8; do
            sr="$(tmux -L "$sock" show -gv status-right 2>/dev/null)"
            case "$sr" in *SYNC*) break ;; esac
            sleep 1
        done
        case "$sr" in *continuum_save.sh*) echo "continuum-interp=yes" ;; *) echo "continuum-interp=no" ;; esac
        case "$sr" in *SYNC*) echo "sync-pill=yes" ;; *) echo "sync-pill=no" ;; esac
        case "$sr" in *PREFIX*) echo "prefix-pill=yes" ;; *) echo "prefix-pill=no" ;; esac
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Prove tmux-continuum interval auto-save actually fires (not merely that it is
# configured). continuum's status-right token simply runs continuum_save.sh on
# each status refresh, which saves via resurrect when the interval has elapsed.
# This locates continuum_save.sh from the activated config, forces the interval
# to have elapsed, and runs the script the same way a status refresh does — via
# run-shell in the server context — then checks for a fresh resurrect save. It
# does not depend on continuum injecting the token (which needs a sole server),
# so it is robust in the harness. Guest only; writes /persist, so gate behind
# DX_TEST_DESTRUCTIVE. Echoes `autosave-fired=yes|no|no-script`.
tmux_guest_continuum_autosave() {
    container_exec_dx_bash '
        set -u
        rdir="/persist/home/dx/.local/share/tmux/resurrect"
        sock="dxe-cont-$$-${RANDOM}"
        conf="$HOME/.config/tmux/tmux.conf"
        save_script="$(grep -oE "/nix/[^ ]*continuum[^ ]*/scripts/continuum_save.sh" "$conf" 2>/dev/null | head -n1)"
        if [ -z "$save_script" ]; then
            cont_tmux="$(grep -oE "/nix/[^ ]*continuum[^ ]*continuum\.tmux" "$conf" 2>/dev/null | head -n1)"
            [ -n "$cont_tmux" ] && save_script="${cont_tmux%/*}/scripts/continuum_save.sh"
        fi
        if [ -z "$save_script" ] || [ ! -x "$save_script" ]; then echo "autosave-fired=no-script"; exit 0; fi
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        started=no
        for _ in 1 2 3; do
            if tmux -L "$sock" new-session -d -s probe -x 200 -y 50 >/dev/null 2>&1; then started=yes; break; fi
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true; sleep 1
        done
        if [ "$started" != yes ]; then echo "__PROBE_FAILED__"; exit 1; fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        before="$(ls -1 "$rdir"/tmux_resurrect_*.txt 2>/dev/null | wc -l | tr -d " ")"
        tmux -L "$sock" set-option -g @continuum-save-interval 1 >/dev/null 2>&1
        tmux -L "$sock" set-option -g @continuum-save-last-timestamp 0 >/dev/null 2>&1
        tmux -L "$sock" run-shell "$save_script" >/dev/null 2>&1 || true
        fired=no
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            after="$(ls -1 "$rdir"/tmux_resurrect_*.txt 2>/dev/null | wc -l | tr -d " ")"
            if [ "$after" -gt "$before" ]; then fired=yes; break; fi
            sleep 1
        done
        echo "autosave-fired=$fired"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ' 2>/dev/null
}

# Probe vim-tmux-navigator wiring from inside the guest, both halves: the tmux
# root-table Ctrl-h/j/k/l bindings (prefix-less pane navigation) and the Neovim
# normal-mode Ctrl-h/j/k/l maps (which must resolve to the TmuxNavigate
# commands). Reads the live tmux key table and a headless nvim's resolved maps,
# not config strings. Guest only. Emits `tmux-root-C-<k>=yes|other|no` and
# `nvim-C-<k>=yes|no`.
tmux_guest_navigator_probe() {
    container_exec_dx_bash '
        set -u
        sock="dxe-nav-$$-${RANDOM}"
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        started=no
        for _ in 1 2 3; do
            if tmux -L "$sock" new-session -d -s probe -x 200 -y 50 >/dev/null 2>&1; then started=yes; break; fi
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true; sleep 1
        done
        if [ "$started" != yes ]; then echo "__PROBE_FAILED__"; exit 1; fi
        tmux -L "$sock" set -g @continuum-restore off >/dev/null 2>&1 || true
        for k in C-h C-j C-k C-l; do
            line="$(tmux -L "$sock" list-keys -T root 2>/dev/null | grep -E "^bind-key( +-r)? +-T root ${k} " | head -n1)"
            if printf "%s" "$line" | grep -qE "select-pane|TmuxNavigate|is_vim"; then
                echo "tmux-root-${k}=yes"
            elif [ -n "$line" ]; then
                echo "tmux-root-${k}=other"
            else
                echo "tmux-root-${k}=no"
            fi
        done
        tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        for key in h j k l; do
            rhs="$(nvim --headless -c "lua io.write((vim.fn.maparg(\"<C-${key}>\",\"n\") or \"\"))" -c "q" 2>/dev/null)"
            case "$rhs" in *TmuxNavigate*) echo "nvim-C-${key}=yes" ;; *) echo "nvim-C-${key}=no" ;; esac
        done
    ' 2>/dev/null
}

