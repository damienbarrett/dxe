#!/usr/bin/env bash
set -eo pipefail

DX_THEME_DARK="base16-gruvbox-dark-hard"
DX_THEME_LIGHT="base16-gruvbox-light-medium"
DX_THEME_ROSE_PINE="base16-rose-pine"
DX_THEME_ROSE_PINE_MOON="base16-rose-pine-moon"
DX_THEME_ROSE_PINE_DAWN="base16-rose-pine-dawn"

usage() {
  cat <<'EOF'
Usage: dx-theme <command>

Commands:
  dark                         Apply base16-mocha
  light                        Apply base16-gruvbox-light-medium
  rose-pine                    Apply base16-rose-pine
  rose-pine-moon               Apply base16-rose-pine-moon
  rose-pine-dawn               Apply base16-rose-pine-dawn
  apply <alias-or-scheme-id>   Apply a configured alias or raw Tinty scheme id
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

ensure_tinty_data() {
  dir="$(data_dir)"
  dir="${dir%/}"
  if have_scheme "$DX_THEME_DARK" \
    && [ -d "$dir/repos/tinted-shell" ] \
    && [ -d "$dir/repos/tinted-tmux" ] \
    && [ -d "$dir/repos/tinted-lazygit" ]; then
    return 0
  fi

  echo "Preparing Tinty schemes and templates..." >&2
  tinty install || tinty sync
}

resolve_scheme() {
  value="$1"
  case "$value" in
    dark) echo "$DX_THEME_DARK" ;;
    light) echo "$DX_THEME_LIGHT" ;;
    rose-pine) echo "$DX_THEME_ROSE_PINE" ;;
    rose-pine-moon) echo "$DX_THEME_ROSE_PINE_MOON" ;;
    rose-pine-dawn) echo "$DX_THEME_ROSE_PINE_DAWN" ;;
    *) echo "$value" ;;
  esac
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
  cat <<EOF
dark            $DX_THEME_DARK
light           $DX_THEME_LIGHT
rose-pine       $DX_THEME_ROSE_PINE
rose-pine-moon  $DX_THEME_ROSE_PINE_MOON
rose-pine-dawn  $DX_THEME_ROSE_PINE_DAWN
EOF
}

print_test() {
  ensure_tinty_data
  current="$(print_current)"
  if [ -z "$current" ]; then
    current="$DX_THEME_DARK"
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
  dark|light|rose-pine|rose-pine-moon|rose-pine-dawn)
    apply_scheme "$command_name"
    ;;
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
    usage
    exit 2
    ;;
esac