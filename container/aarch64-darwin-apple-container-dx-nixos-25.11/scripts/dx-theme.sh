#!/usr/bin/env bash
set -eo pipefail

# Single source of truth for theme aliases is ~/.config/dx/themes.json,
# which is generated declaratively from home/theme.nix. Adding or renaming
# an alias is a one-place edit in Nix; this script never hardcodes them.
themes_json="$HOME/.config/dx/themes.json"
themes_default_file="$HOME/.config/dx/themes-default"

usage() {
  cat <<'EOF'
Usage: dx-theme <command>

Commands:
  <alias>                      Apply an alias defined in the registry (see `list`)
  apply <alias-or-scheme-id>   Apply an alias or raw Tinty scheme id
  list                         List configured aliases
  current                      Print Tinty's current scheme
  test                         Print current theme values and ANSI swatches
  sync                         Install or update Tinty runtime templates
  help                         Show this help
EOF
}

data_dir() {
  tinty config --data-dir-path 2>/dev/null || printf '%s\n' "$HOME/.local/share/tinted-theming/tinty/"
}

have_scheme() {
  tinty list 2>/dev/null | grep -qx "$1"
}

# Read the alias registry; tolerate missing/broken JSON without aborting.
themes_jq() {
  if [ -f "$themes_json" ]; then
    jq "$@" "$themes_json" 2>/dev/null
  else
    return 1
  fi
}

default_alias() {
  if [ -s "$themes_default_file" ]; then
    cat "$themes_default_file"
  else
    echo dark
  fi
}

default_scheme() {
  resolve_scheme "$(default_alias)"
}

ensure_tinty_data() {
  dir="$(data_dir)"
  dir="${dir%/}"
  if have_scheme "$(default_scheme)" \
    && [ -d "$dir/repos/tinted-shell" ] \
    && [ -d "$dir/repos/tinted-tmux" ] \
    && [ -d "$dir/repos/tinted-lazygit" ]; then
    return 0
  fi

  echo "Preparing Tinty schemes and templates..." >&2
  tinty install || tinty sync
}

# Resolve an alias to a scheme id. Unknown keys pass through unchanged so
# `apply <raw-scheme-id>` still works.
resolve_scheme() {
  value="$1"
  resolved="$(themes_jq -r --arg k "$value" '.[$k] // $k')" || resolved="$value"
  echo "$resolved"
}

is_alias() {
  themes_jq -e --arg k "$1" 'has($k)' >/dev/null
}

refresh_tool_themes() {
  writer="$HOME/.local/bin/dx-theme-write-tool-themes"
  if [ -x "$writer" ]; then
    "$writer" "$1" >/dev/null 2>&1 || true
  fi
}

apply_scheme() {
  scheme="$(resolve_scheme "$1")"
  ensure_tinty_data
  if ! have_scheme "$scheme"; then
    echo "Unknown Tinty scheme: $scheme" >&2
    exit 1
  fi

  tinty apply "$scheme"
  refresh_tool_themes "$scheme"
  mkdir -p "$HOME/.config/dx"
  printf '%s\n' "$scheme" > "$HOME/.config/dx/theme-current"
}

print_current() {
  tinty current 2>/dev/null || true
}

print_list() {
  if rendered="$(themes_jq -r 'to_entries|sort_by(.key)|.[]|"\(.key)\t\(.value)"')" && [ -n "$rendered" ]; then
    printf '%s\n' "$rendered" | column -t -s "$(printf '\t')"
  else
    echo "No theme registry found at $themes_json" >&2
    return 1
  fi
}

print_test() {
  ensure_tinty_data
  current="$(print_current)"
  if [ -z "$current" ]; then
    current="$(default_scheme)"
  fi

  variant="$(tinty current variant 2>/dev/null || true)"
  colors="$(tinty info "$current" 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/#\1/p' || true)"
  base00="$(printf '%s\n' "$colors" | sed -n '1p')"
  base05="$(printf '%s\n' "$colors" | sed -n '6p')"

  printf 'scheme: %s\n' "$current"
  printf 'variant: %s\n' "$variant"
  printf 'base00/background: %s\n' "$base00"
  printf 'base05/foreground: %s\n' "$base05"
  for i in 0 1 2 3 4 5 6 7; do printf "\033[3%sm  \033[0m" "$i"; done; printf "\n"
  for i in 0 1 2 3 4 5 6 7; do printf "\033[9%sm  \033[0m" "$i"; done; printf "\n"
}

command_name="help"
if [ $# -gt 0 ]; then
  command_name="$1"
  shift
fi

case "$command_name" in
  apply)
    if [ $# -ne 1 ]; then
      usage
      exit 2
    fi
    apply_scheme "$1"
    ;;
  list)
    print_list
    ;;
  current)
    print_current
    ;;
  test)
    print_test
    ;;
  sync)
    tinty install || tinty sync
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    if is_alias "$command_name"; then
      apply_scheme "$command_name"
    else
      usage
      exit 2
    fi
    ;;
esac
