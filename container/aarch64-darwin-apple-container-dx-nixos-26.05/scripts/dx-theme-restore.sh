#!/usr/bin/env bash
set -eo pipefail

# Inside a Herdr pane, emitting OSC on our own stdout would only create a
# pane-local override that Herdr discards the moment this helper exits. Hand
# off to the writer, which updates Herdr's own chrome and writes the palette to
# each attached client's real host TTY. See write_herdr_host_terminals.
if { [ "${HERDR_ENV:-}" = 1 ] || [ -n "${HERDR_PANE_ID:-}" ]; } \
  && [ -x "$HOME/.local/bin/dx-theme-write-tool-themes" ]; then
  exec "$HOME/.local/bin/dx-theme-write-tool-themes"
fi

current="$(tinty current 2>/dev/null || true)"
if [ -z "$current" ] && [ -s "$HOME/.config/dx/theme-current" ]; then
  current="$(cat "$HOME/.config/dx/theme-current")"
fi

if [ -z "$current" ]; then
  exit 0
fi

mapfile -t palette < <(tinty info "$current" 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p')
if [ "${#palette[@]}" -lt 16 ]; then
  exit 0
fi

base00="${palette[0]}"
base01="${palette[1]}"
base02="${palette[2]}"
base03="${palette[3]}"
base04="${palette[4]}"
base05="${palette[5]}"
base06="${palette[6]}"
base07="${palette[7]}"
base08="${palette[8]}"
base09="${palette[9]}"
base0A="${palette[10]}"
base0B="${palette[11]}"
base0C="${palette[12]}"
base0D="${palette[13]}"
base0E="${palette[14]}"
base0F="${palette[15]}"

if [ -x "$HOME/.local/bin/dx-theme-write-tool-themes" ]; then
  "$HOME/.local/bin/dx-theme-write-tool-themes" "$current" >/dev/null 2>&1 || true
fi

rgb() {
  color="$1"
  printf 'rgb:%s/%s/%s' "${color:0:2}" "${color:2:2}" "${color:4:2}"
}

emit_payload() {
  payload="$1"
  if [ -n "${TMUX:-}" ]; then
    printf '\033Ptmux;\033\033]%s\033\\\033\\' "$payload"
  else
    printf '\033]%s\033\\' "$payload"
  fi
}

emit_indexed_color() {
  index="$1"
  color="$2"
  emit_payload "4;$index;$(rgb "$color")"
}

emit_osc() {
  code="$1"
  color="$2"
  emit_payload "$code;#$color"
}

emit_indexed_color 0 "$base00"
emit_indexed_color 1 "$base08"
emit_indexed_color 2 "$base0B"
emit_indexed_color 3 "$base0A"
emit_indexed_color 4 "$base0D"
emit_indexed_color 5 "$base0E"
emit_indexed_color 6 "$base0C"
emit_indexed_color 7 "$base05"
emit_indexed_color 8 "$base03"
emit_indexed_color 9 "$base08"
emit_indexed_color 10 "$base0B"
emit_indexed_color 11 "$base0A"
emit_indexed_color 12 "$base0D"
emit_indexed_color 13 "$base0E"
emit_indexed_color 14 "$base0C"
emit_indexed_color 15 "$base07"
emit_indexed_color 16 "$base09"
emit_indexed_color 17 "$base0F"
emit_indexed_color 18 "$base01"
emit_indexed_color 19 "$base02"
emit_indexed_color 20 "$base04"
emit_indexed_color 21 "$base06"

emit_osc 10 "$base05"
emit_osc 11 "$base00"
emit_osc 12 "$base05"