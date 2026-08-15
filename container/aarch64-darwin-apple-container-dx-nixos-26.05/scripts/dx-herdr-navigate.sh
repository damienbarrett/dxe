#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: dx-herdr-navigate <left|down|up|right> <key>" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
direction="$1"
key="$2"

case "$direction" in
    left|down|up|right) ;;
    *) usage ;;
esac

herdr_bin="${HERDR_BIN_PATH:-}"
if [ -z "$herdr_bin" ]; then
    herdr_bin="$(command -v herdr)" || {
        echo "Error: herdr is not available on PATH." >&2
        exit 127
    }
fi

pane_id="${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}"
if [ -z "$pane_id" ]; then
    echo "Error: no active Herdr pane ID is available." >&2
    exit 1
fi

# Match vim-tmux-navigator's important behavior: fullscreen editors and fzf
# receive the key so they can navigate internally; other foreground processes
# cause Herdr itself to focus the neighboring pane.
process_info="$("$herdr_bin" pane process-info --pane "$pane_id")"
if printf '%s\n' "$process_info" | jq -e '
    .result.process_info.foreground_processes
    | any(.[]?; (.name // "")
        | test("^\\.?(g?view|g?vim|g?nvim|lvim|fzf)(diff)?(-wrapped)?$"; "i"))
' >/dev/null; then
    exec "$herdr_bin" pane send-keys "$pane_id" "$key"
fi

exec "$herdr_bin" pane focus --pane "$pane_id" --direction "$direction"
