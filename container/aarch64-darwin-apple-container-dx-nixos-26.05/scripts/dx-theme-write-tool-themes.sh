#!/usr/bin/env bash
set -eo pipefail

base16_slots=(00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F)

ensure_tinty_on_path() {
  # tmux `run-shell -b` may spawn us with a minimal PATH that excludes
  # ~/.nix-profile/bin.
  if ! command -v tinty >/dev/null 2>&1 && [ -x "$HOME/.nix-profile/bin/tinty" ]; then
    PATH="$HOME/.nix-profile/bin:$PATH"
  fi
}

load_palette_from_tinty_info() {
  local scheme="$1"
  mapfile -t palette < <(tinty info "$scheme" 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p')
}

load_palette_from_env() {
  local slot component var value color
  palette=()
  for slot in "${base16_slots[@]}"; do
    color=""
    for component in R G B; do
      var="TINTY_SCHEME_PALETTE_BASE${slot}_HEX_${component}"
      value="${!var:-}"
      if ! [[ "$value" =~ ^[0-9A-Fa-f]{2}$ ]]; then
        palette=()
        return 1
      fi
      color="${color}${value}"
    done
    palette+=( "$color" )
  done
}

load_palette() {
  if [ "$#" -eq 0 ]; then
    # Prefer Tinty's hook env vars when present. They are the authoritative
    # incoming palette and avoid a TOCTOU against `tinty current` mid-switch.
    if [ -n "${TINTY_SCHEME_PALETTE_BASE00_HEX_R:-}" ]; then
      load_palette_from_env || return 0
    else
      local current
      current="$(tinty current 2>/dev/null || true)"
      if [ -n "$current" ]; then
        load_palette_from_tinty_info "$current"
      fi
    fi
  elif [ "$#" -eq 1 ]; then
    load_palette_from_tinty_info "$1"
  elif [ "$#" -eq 16 ]; then
    palette=( "$@" )
  else
    exit 2
  fi
}

validate_palette() {
  local color
  if [ "${#palette[@]}" -lt 16 ]; then
    return 1
  fi
  for color in "${palette[@]:0:16}"; do
    if ! [[ "$color" =~ ^[0-9A-Fa-f]{6}$ ]]; then
      return 1
    fi
  done
}

ensure_tinty_on_path
palette=()
load_palette "$@"

if ! validate_palette; then
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

accent_primary="$base0E"
accent_secondary="$base0D"
starship_accent_primary="base0E"
starship_accent_secondary="base0D"

home_dir="$HOME"
if [ -z "$home_dir" ]; then
  home_dir="/home/dx"
fi

write_btop_theme() {
  mkdir -p "$home_dir/.config/btop/themes"
  cat > "$home_dir/.config/btop/themes/dx-tinty.theme" <<EOF
theme[main_bg]="#$base00"
theme[main_fg]="#$base05"
theme[title]="#$accent_primary"
theme[hi_fg]="#$accent_primary"
theme[selected_bg]="#$accent_primary"
theme[selected_fg]="#$base00"
theme[inactive_fg]="#$base03"
theme[graph_text]="#$accent_secondary"
theme[proc_misc]="#$base0B"
theme[cpu_box]="#$accent_primary"
theme[mem_box]="#$accent_secondary"
theme[net_box]="#$base08"
theme[proc_box]="#$base0C"
theme[div_line]="#$base01"
theme[temp_start]="#$base0B"
theme[temp_mid]="#$accent_primary"
theme[temp_end]="#$base08"
theme[cpu_start]="#$base0B"
theme[cpu_mid]="#$accent_primary"
theme[cpu_end]="#$base08"
theme[free_start]="#$base08"
theme[free_mid]="#$accent_secondary"
theme[free_end]="#$base0B"
theme[cached_start]="#$base0B"
theme[cached_mid]="#$accent_secondary"
theme[cached_end]="#$base08"
theme[available_start]="#$base0B"
theme[available_mid]="#$accent_secondary"
theme[available_end]="#$base08"
theme[used_start]="#$base0B"
theme[used_mid]="#$accent_primary"
theme[used_end]="#$base08"
theme[download_start]="#$base0B"
theme[download_mid]="#$accent_secondary"
theme[download_end]="#$base08"
theme[upload_start]="#$base0B"
theme[upload_mid]="#$accent_primary"
theme[upload_end]="#$base08"
EOF
}

write_yazi_theme() {
  mkdir -p "$home_dir/.config/yazi"
  cat > "$home_dir/.config/yazi/theme.toml" <<EOF
[app]
overall = { bg = "#$base00" }

[mgr]
cwd = { fg = "#$base0D", bold = true }
find_keyword = { fg = "#$base0A", italic = true }
find_position = { fg = "#$base0E", bg = "#$base01" }
symlink_target = { fg = "#$base0C" }
marker_copied = { fg = "#$base0B", bg = "#$base01" }
marker_cut = { fg = "#$base08", bg = "#$base01" }
marker_marked = { fg = "#$base0E", bg = "#$base01" }
marker_selected = { fg = "#$accent_primary", bg = "#$base01" }
count_copied = { fg = "#$base0B", bold = true }
count_cut = { fg = "#$base08", bold = true }
count_selected = { fg = "#$accent_primary", bold = true }
border_style = { fg = "#$accent_primary" }

[tabs]
active = { fg = "#$base00", bg = "#$accent_primary", bold = true }
inactive = { fg = "#$base05", bg = "#$base01" }

[mode]
normal_main = { fg = "#$base00", bg = "#$accent_primary", bold = true }
normal_alt = { fg = "#$base05", bg = "#$base01" }
select_main = { fg = "#$base00", bg = "#$base0B", bold = true }
select_alt = { fg = "#$base05", bg = "#$base01" }
unset_main = { fg = "#$base00", bg = "#$base0E", bold = true }
unset_alt = { fg = "#$base05", bg = "#$base01" }

[status]
overall = { fg = "#$base05", bg = "#$base00" }
perm_type = { fg = "#$base0E" }
perm_read = { fg = "#$base0B" }
perm_write = { fg = "#$base0A" }
perm_exec = { fg = "#$base08" }
perm_sep = { fg = "#$base03" }
progress_label = { fg = "#$base05", bold = true }
progress_normal = { fg = "#$base0E", bg = "#$base01" }
progress_error = { fg = "#$base08", bg = "#$base01" }

[which]
mask = { bg = "#$base01" }
cand = { fg = "#$base0E", bold = true }
rest = { fg = "#$base03" }
desc = { fg = "#$base05" }
separator_style = { fg = "#$base03" }

[confirm]
border = { fg = "#$base0E" }
title = { fg = "#$base0E", bold = true }
body = { fg = "#$base05" }
list = { fg = "#$base05" }
btn_yes = { fg = "#$base00", bg = "#$base0B", bold = true }
btn_no = { fg = "#$base00", bg = "#$base08", bold = true }

[spot]
border = { fg = "#$base0D" }
title = { fg = "#$base0D", bold = true }
tbl_col = { fg = "#$base0A" }
tbl_cell = { fg = "#$base05" }

[notify]
title_info = { fg = "#$base0D", bold = true }
title_warn = { fg = "#$base0A", bold = true }
title_error = { fg = "#$base08", bold = true }

[pick]
border = { fg = "#$base0E" }
active = { fg = "#$base0E", bold = true }
inactive = { fg = "#$base05" }

[input]
border = { fg = "#$base0E" }
title = { fg = "#$base0E", bold = true }
value = { fg = "#$base05" }
selected = { fg = "#$base00", bg = "#$base0E", bold = true }

[cmp]
border = { fg = "#$base0E" }
active = { fg = "#$base0E", bold = true }
inactive = { fg = "#$base05" }

[tasks]
border = { fg = "#$base0E" }
title = { fg = "#$base0E", bold = true }
hovered = { fg = "#$base00", bg = "#$base0E", bold = true }

[help]
on = { fg = "#$base0E", bold = true }
run = { fg = "#$base0B" }
desc = { fg = "#$base05" }
hovered = { fg = "#$base00", bg = "#$base0E", bold = true }
footer = { fg = "#$base03" }

[filetype]
rules = [
  { mime = "image/*", fg = "#$base0A" },
  { mime = "{audio,video}/*", fg = "#$base0E" },
  { mime = "inode/empty", fg = "#$base03" },
  { url = "*", is = "orphan", fg = "#$base08" },
  { url = "*/", fg = "#$base0D" },
  { url = "*", fg = "#$base05" },
]
EOF
}

write_starship_theme() {
  starship_config="$home_dir/.config/starship.toml"
  if [ -n "${STARSHIP_CONFIG:-}" ]; then
    starship_config="$STARSHIP_CONFIG"
  fi

  mkdir -p "$(dirname "$starship_config")"
  cat > "$starship_config" <<EOF
"\$schema" = "https://starship.rs/config-schema.json"
add_newline = true
palette = "dx-tinty"
format = "\$directory\$git_branch\$git_status\$cmd_duration\$line_break\$character"

[directory]
style = "bold fg:$starship_accent_primary"
read_only_style = "fg:base08"

[git_branch]
style = "bold fg:$starship_accent_secondary"

[git_status]
style = "bold fg:base08"

[cmd_duration]
style = "bold fg:base0A"

[nix_shell]
style = "bold fg:$starship_accent_primary"

[direnv]
style = "bold fg:base0B"

[package]
style = "bold fg:base0A"

[nodejs]
style = "bold fg:base0B"

[character]
success_symbol = "[>](bold fg:$starship_accent_primary)"
error_symbol = "[>](bold fg:base08)"

[palettes.dx-tinty]
base00 = "#$base00"
base01 = "#$base01"
base02 = "#$base02"
base03 = "#$base03"
base04 = "#$base04"
base05 = "#$base05"
base06 = "#$base06"
base07 = "#$base07"
base08 = "#$base08"
base09 = "#$base09"
base0A = "#$base0A"
base0B = "#$base0B"
base0C = "#$base0C"
base0D = "#$base0D"
base0E = "#$base0E"
base0F = "#$base0F"
EOF
}

apply_tmux_pills() {
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  # Probe a live tmux server. `-gq` only suppresses unknown-option errors;
  # the redirect catches "no server running" connection errors so the
  # function exits cleanly when invoked outside a tmux session.
  tmux set-option -gq status on >/dev/null 2>&1 || return 0

  # Powerline-extra rounded end-caps. U+E0B6 (left cap) and U+E0B4 (right
  # cap) render as filled half-circles in the accent color on the bar bg.
  local cap_l=$''
  local cap_r=$''

  # A "pill" is a label rendered bold with bar-bg fg on an accent bg,
  # framed by zero-width color transitions to/from the bar background.
  # The framing matters when status segments butt up against each other:
  # without it, tmux carries the last applied color into the next pill.
  pill() {
    printf '#[fg=#%s,bg=#%s]%s#[fg=#%s,bg=#%s,bold]%s#[fg=#%s,bg=#%s,nobold,noitalics,nounderscore]%s' \
      "$1" "$base00" "$cap_l" "$base00" "$1" "$2" "$1" "$base00" "$cap_r"
  }
  # Dim variant — same frame, but content uses $base06 fg (not inverted)
  # and is not bold. Used for inactive window-status items.
  dim_pill() {
    printf '#[fg=#%s,bg=#%s]%s#[fg=#%s,bg=#%s]%s#[fg=#%s,bg=#%s,nobold,noitalics,nounderscore]%s' \
      "$1" "$base00" "$cap_l" "$base06" "$1" "$2" "$1" "$base00" "$cap_r"
  }
  # State pill + trailing space separator, hidden when COND is false.
  # COND is a tmux format predicate (e.g. client_prefix, synchronize-panes).
  conditional_pill() {
    printf '#{?%s,%s ,}' "$1" "$(pill "$2" "$3")"
  }
  # Like pill but uses spaces instead of commas in #[] attribute blocks.
  # Safe to embed inside #{?cond,TRUE,FALSE} — commas there are delimiters.
  safe_pill() {
    printf '#[fg=#%s bg=#%s]%s#[fg=#%s bg=#%s bold]%s#[fg=#%s bg=#%s nobold noitalics nounderscore]%s' \
      "$1" "$base00" "$cap_l" "$base00" "$1" "$2" "$1" "$base00" "$cap_r"
  }

  local session_pill sync_pill prefix_pill time_pill date_pill
  session_pill="$(pill "$base0D" ' #S ')"
  sync_pill="$(conditional_pill synchronize-panes "$base08" ' SYNC ')"
  prefix_pill="$(conditional_pill client_prefix "$base09" ' PREFIX ')"
  time_pill="$(pill "$base0B" ' %H:%M ')"
  date_pill="$(pill "$base0E" ' %d %b ')"

  # Preserve tmux-continuum's interval auto-save token. continuum injects
  # #(.../continuum_save.sh) into status-right so its save hook runs on each
  # status refresh; we overwrite status-right below, so carry the token across
  # or interval auto-save silently stops after the first theme apply.
  local continuum_interp
  continuum_interp="$(tmux show-option -gqv status-right 2>/dev/null | grep -oE '#\([^)]*continuum_save\.sh\)' | head -n1 || true)"

  local window_label=' #I:#W#{?window_flags,#{window_flags},} '
  local inactive_window active_window
  inactive_window="$(dim_pill "$base01" "$window_label")"
  active_window="$(pill "$base0A" "$window_label")"

  local active_pane_status inactive_pane_status
  active_pane_status="$(safe_pill "$base0A" ' #{b:pane_current_path} ')"
  inactive_pane_status="$(safe_pill "$base0C" ' #{b:pane_current_path} ')"

  # Apply every option in one tmux IPC round-trip via source-file.
  # Sixteen separate `tmux set-option` calls collapse to one.
  local conf
  conf="$(mktemp)"
  trap 'rm -f "$conf"; trap - RETURN' RETURN
  cat > "$conf" <<EOF
set-option -gq status-position top
set-option -gq status-interval 5
set-option -gq status-justify centre
set-option -gq status-style "fg=#$base05,bg=#$base00"
set-option -gq status-left-style none
set-option -gq status-right-style none
set-option -gq status-left-length 80
set-option -gq status-right-length 120
set-option -gq status-left "$session_pill"
set-option -gq status-right "${continuum_interp}${sync_pill}${prefix_pill}${time_pill} ${date_pill}"
set-window-option -gq window-status-style "fg=#$base05,bg=#$base00"
set-window-option -gq window-status-current-style "fg=#$base0A,bg=#$base00"
set-window-option -gq window-status-separator " "
set-window-option -gq window-status-activity-style "fg=#$base05,bg=#$base00"
set-window-option -gq window-status-bell-style "fg=#$base08,bg=#$base00"
set-window-option -gq window-status-format "$inactive_window"
set-window-option -gq window-status-current-format "$active_window"
set-option -gq pane-border-status bottom
set-option -gq pane-border-format "#[align=right]#{?pane_active,$active_pane_status,$inactive_pane_status}"
set-option -gq pane-active-border-style "fg=#$base0A,bg=#$base00,bold"
set-option -gq pane-border-style "fg=#$base03,bg=#$base00"
EOF
  tmux source-file "$conf" >/dev/null 2>&1 || true
}

write_btop_theme
write_yazi_theme
write_starship_theme
apply_tmux_pills
