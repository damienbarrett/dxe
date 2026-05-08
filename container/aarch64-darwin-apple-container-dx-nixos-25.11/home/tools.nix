{ config, pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    shortcut = "space";
    extraConfig = ''
      set -g default-terminal "tmux-256color"
      set -as terminal-features ",xterm-256color:RGB"
      set -ga terminal-overrides ",xterm-256color:Tc"
      set -s escape-time 0
      set -g repeat-time 1000
      set -g mouse on
      set -g history-limit 50000
      
      # Yazi image support (Ghostty/Kitty protocol)
      set -g allow-passthrough on
      set -ga update-environment TERM
      set -ga update-environment TERM_PROGRAM

      # Tinty status colors are generated at runtime by dx-theme.
      if-shell 'test -f ~/.cache/dx/tinty/tmux.conf' 'source-file ~/.cache/dx/tinty/tmux.conf'

      # Swap split-window mappings
      bind % split-window -v
      bind '"' split-window -h

      # Vim-style pane switching
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      # Vim-style pane resizing
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5
    '';
  };

  xdg.configFile."lazygit/config.yml".text = ''
    gui:
      nerdFontsVersion: "3"
  '';

  xdg.configFile."btop/btop.conf" = {
    force = true;
    text = ''
      color_theme = "dx-tinty"
      theme_background = True
      truecolor = True
      vim_keys = True
      rounded_corners = True
      graph_symbol = "braille"
      shown_boxes = "cpu mem net proc"
      update_ms = 2000
    '';
  };

  home.file.".local/bin/dx-ai" = {
    executable = true;
    source = ../scripts/dx-ai.sh;
  };
}
