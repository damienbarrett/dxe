#!/usr/bin/env bash
set -eo pipefail

kind="$1"
theme_file="$TINTY_THEME_FILE_PATH"
home_dir="$HOME"

if [ -z "$home_dir" ]; then
  home_dir="/home/dx"
fi

if [ -z "$theme_file" ] || [ ! -f "$theme_file" ]; then
  exit 0
fi

case "$kind" in
  shell)
    mkdir -p "$home_dir/.cache/dx/tinty"
    cp -f "$theme_file" "$home_dir/.cache/dx/tinty/shell.sh"
    ;;
  tmux)
    mkdir -p "$home_dir/.cache/dx/tinty"
    cp -f "$theme_file" "$home_dir/.cache/dx/tinty/tmux.conf"
    if command -v tmux >/dev/null 2>&1; then
      tmux source-file "$home_dir/.cache/dx/tinty/tmux.conf" >/dev/null 2>&1 || true
    fi
    ;;
  lazygit)
    mkdir -p "$home_dir/.cache/dx/tinty"
    cp -f "$theme_file" "$home_dir/.cache/dx/tinty/lazygit.yml"
    ;;
  *)
    exit 0
    ;;
esac