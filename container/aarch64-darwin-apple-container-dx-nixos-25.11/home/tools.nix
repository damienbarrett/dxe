{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName = "Damien Barrett";
    userEmail = "damienbarrett@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      credential."https://github.com".helper = "!gh auth git-credential";
      credential."https://gist.github.com".helper = "!gh auth git-credential";
    };
  };

  programs.tmux = {
    enable = true;
    shortcut = "space";
    extraConfig = ''
      set -g default-terminal "tmux-256color"
      set -as terminal-features ",xterm-256color:RGB"
      set -as terminal-features ",xterm-256color:clipboard"
      set -ga terminal-overrides ",xterm-256color:Tc"
      set -s escape-time 0
      set -s set-clipboard on
      set -g repeat-time 1000
      set -g display-panes-time 3000
      set -g focus-events on
      set -g mouse on
      set -g history-limit 50000
      set -g base-index 1
      set -g renumber-windows on
      set -g status-position top
      set -g visual-activity off
      setw -g pane-base-index 1
      setw -g monitor-activity on
      setw -g monitor-bell on
      
      # Yazi image support (Ghostty/Kitty protocol)
      set -g allow-passthrough on
      set -ga update-environment TERM
      set -ga update-environment TERM_PROGRAM

      # Tinty status colors are generated at runtime by dx-theme.
      if-shell 'test -f ~/.cache/dx/tinty/tmux.conf' 'source-file ~/.cache/dx/tinty/tmux.conf'

      # Pill-style status bar, rendered from the active Tinty/Base16 palette.
      if-shell 'test -x ~/.local/bin/dx-theme-write-tool-themes' 'run-shell -b ~/.local/bin/dx-theme-write-tool-themes'

      # Swap split-window mappings
      bind -N "New window in current directory" c new-window -c "#{pane_current_path}"
      bind -N "Split pane vertically in current directory" % split-window -v -c "#{pane_current_path}"
      bind -N "Split pane horizontally in current directory" '"' split-window -h -c "#{pane_current_path}"

      # Workflow helpers.
      bind -N "Toggle synchronize-panes for this window" S setw synchronize-panes \; refresh-client -S \; display-message "synchronize-panes #{?synchronize-panes,on,off}"
      bind -N "Open scratch shell popup" P display-popup -E -w 80% -h 80% -d "#{pane_current_path}" -T "scratch"
      bind -N "Open lazygit popup" g if-shell 'command -v lazygit >/dev/null 2>&1' 'display-popup -E -w 90% -h 90% -d "#{pane_current_path}" -T "lazygit" lazygit' 'display-message "lazygit not found"'
      bind -N "Choose session, window, or pane" w choose-tree -Zw
      bind -N "Choose window with activity or bell" a choose-tree -Zw -f "#{||:#{window_activity_flag},#{window_bell_flag}}"

      # Vi-style copy mode with OSC52 clipboard support.
      setw -g mode-keys vi
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi V send-keys -X select-line
      bind -T copy-mode-vi C-v send-keys -X rectangle-toggle
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
      bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel

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

  home.file.".local/bin/dx-claude-statusline" = {
    executable = true;
    source = ../scripts/dx-claude-statusline.sh;
  };
}
