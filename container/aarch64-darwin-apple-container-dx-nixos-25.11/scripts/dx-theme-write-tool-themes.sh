#!/usr/bin/env bash
set -eo pipefail

if [ "$#" -eq 1 ]; then
  mapfile -t palette < <(tinty info "$1" 2>/dev/null | sed -n 's/.*#\([0-9A-Fa-f]\{6\}\).*/\1/p')
elif [ "$#" -eq 16 ]; then
  palette=( "$@" )
else
  exit 2
fi

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

purple_primary="$base0E"
purple_secondary="$base0D"
starship_purple_primary="base0E"
starship_purple_secondary="base0D"

home_dir="$HOME"
if [ -z "$home_dir" ]; then
  home_dir="/home/dx"
fi

write_btop_theme() {
  mkdir -p "$home_dir/.config/btop/themes"
  cat > "$home_dir/.config/btop/themes/dx-tinty.theme" <<EOF
theme[main_bg]="#$base00"
theme[main_fg]="#$base05"
theme[title]="#$purple_primary"
theme[hi_fg]="#$purple_primary"
theme[selected_bg]="#$purple_primary"
theme[selected_fg]="#$base00"
theme[inactive_fg]="#$base03"
theme[graph_text]="#$purple_secondary"
theme[proc_misc]="#$base0B"
theme[cpu_box]="#$purple_primary"
theme[mem_box]="#$purple_secondary"
theme[net_box]="#$base08"
theme[proc_box]="#$base0C"
theme[div_line]="#$base01"
theme[temp_start]="#$base0B"
theme[temp_mid]="#$purple_primary"
theme[temp_end]="#$base08"
theme[cpu_start]="#$base0B"
theme[cpu_mid]="#$purple_primary"
theme[cpu_end]="#$base08"
theme[free_start]="#$base08"
theme[free_mid]="#$purple_secondary"
theme[free_end]="#$base0B"
theme[cached_start]="#$base0B"
theme[cached_mid]="#$purple_secondary"
theme[cached_end]="#$base08"
theme[available_start]="#$base0B"
theme[available_mid]="#$purple_secondary"
theme[available_end]="#$base08"
theme[used_start]="#$base0B"
theme[used_mid]="#$purple_primary"
theme[used_end]="#$base08"
theme[download_start]="#$base0B"
theme[download_mid]="#$purple_secondary"
theme[download_end]="#$base08"
theme[upload_start]="#$base0B"
theme[upload_mid]="#$purple_primary"
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
marker_selected = { fg = "#$purple_primary", bg = "#$base01" }
count_copied = { fg = "#$base0B", bold = true }
count_cut = { fg = "#$base08", bold = true }
count_selected = { fg = "#$purple_primary", bold = true }
border_style = { fg = "#$purple_primary" }

[tabs]
active = { fg = "#$base00", bg = "#$purple_primary", bold = true }
inactive = { fg = "#$base05", bg = "#$base01" }

[mode]
normal_main = { fg = "#$base00", bg = "#$purple_primary", bold = true }
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
style = "bold fg:$starship_purple_primary"
read_only_style = "fg:base08"

[git_branch]
style = "bold fg:$starship_purple_secondary"

[git_status]
style = "bold fg:base08"

[cmd_duration]
style = "bold fg:base0A"

[nix_shell]
style = "bold fg:$starship_purple_primary"

[direnv]
style = "bold fg:base0B"

[package]
style = "bold fg:base0A"

[nodejs]
style = "bold fg:base0B"

[character]
success_symbol = "[>](bold fg:$starship_purple_primary)"
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

write_btop_theme
write_yazi_theme
write_starship_theme
