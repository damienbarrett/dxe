{ config, lib, pkgs, ... }:

let
  dxScript = import ./dx-scripts.nix { inherit pkgs; };
in
{
  # WP2.2 (docs/reviews/2026-09-29-fable.md finding C2): userName, userEmail
  # and extraConfig are renamed options as of this Home Manager release --
  # userName/userEmail fold into settings.user.name/settings.user.email, and
  # extraConfig's whole shape moves under settings unchanged (per the
  # rename warning) -- kept here for one release before they are removed.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Damien Barrett";
        email = "damienbarrett@users.noreply.github.com";
      };
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
    keyMode = "vi";
    baseIndex = 1;
    escapeTime = 0;
    focusEvents = true;
    mouse = true;
    historyLimit = 50000;
    terminal = "tmux-256color";
    customPaneNavigationAndResize = true;
    disableConfirmationPrompt = true;
    sensibleOnTop = true;
    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = resurrect;
        extraConfig = ''
          # Save data must live on /persist (created by bootstrap), not the
          # ephemeral container home, so sessions survive container rebuilds.
          set -g @resurrect-dir '/persist/home/dx/.local/share/tmux/resurrect'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          # Auto-save on an interval and auto-restore on server start. continuum
          # drives its interval save by injecting a #(continuum_save.sh) token
          # into status-right; dx-theme-write-tool-themes.sh preserves that
          # token when it rebuilds the status bar so auto-save keeps firing.
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '15'
        '';
      }
      # Prefix-less Ctrl-h/j/k/l navigation across tmux panes and Neovim splits.
      # The Neovim half is nvim/plugins/vim-tmux-navigator.nix. Remove this entry
      # and that file to revert. Binds Ctrl-h/j/k/l/\ in the root key table.
      vim-tmux-navigator
    ];
    extraConfig = ''
      # keyMode = "vi" emits both mode-keys vi and status-keys vi. Keep the
      # command prompt on emacs editing; Home Manager models these together.
      set -g status-keys emacs
      set -as terminal-features ",xterm-256color:RGB"
      set -as terminal-features ",xterm-256color:clipboard"
      set -ga terminal-overrides ",xterm-256color:Tc"
      set -s set-clipboard on
      set -g repeat-time 1000
      set -g display-panes-time 3000
      set -g renumber-windows on
      set-option -g main-pane-width 50%
      set -g status-position top
      set -g visual-activity off
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
      bind -N "Choose window with activity or bell" b choose-tree -Zw -f "#{||:#{window_activity_flag},#{window_bell_flag}}"
      bind -N "Switch to tiled layout" + select-layout tiled
      bind -N "Promote selected pane to main pane" a select-layout main-vertical \; display-panes "swap-pane -s .%% -t .1 \; select-pane -t .1"

      # Reload the activated config without recreating the tmux server.
      bind -N "Reload tmux config" r source-file ~/.config/tmux/tmux.conf \; display-message "tmux config reloaded"

      # Vi-style copy mode with OSC52 clipboard support. mode-keys vi comes
      # from the typed keyMode option above.
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi V send-keys -X select-line
      bind -T copy-mode-vi C-v send-keys -X rectangle-toggle
      bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
      bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel

      # hjkl pane switching and HJKL resizing come from the typed
      # customPaneNavigationAndResize option above. The pinned Home Manager
      # module emits switching without -r (non-repeatable) and only resizing
      # with -r, which matches the prior hand-written behaviour.
    '';
  };

  # WP7.4 (docs/reviews/2026-09-29-fable.md finding C4): replaces a raw
  # xdg.configFile."lazygit/config.yml".text block with the typed option;
  # programs.lazygit.enable also supplies the lazygit package itself, so it
  # is no longer a guest-tools.nix/dxPackages entry (see that file).
  programs.lazygit = {
    enable = true;
    settings.gui.nerdFontsVersion = "3";
  };

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

  # WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): the installed
  # commands below (everything except dx-ai) are `pkgs.writeShellApplication`
  # wrappers over the raw scripts (still the source of truth), each `deps`
  # list being exactly what that script calls -- see dx-scripts.nix. dx-ai
  # stays a plain `home.file` copy: it must keep working loaded straight off
  # the bootstrap volume before any generation (hence any wrapped profile)
  # exists. The three `.local/lib/dx/*.sh` entries are source-only libraries
  # (sourced, never executed directly), so they stay plain `home.file`
  # copies too.
  home.file = lib.mapAttrs'
    (name: spec: lib.nameValuePair ".local/bin/${name}" {
      source = "${dxScript name spec.file spec.deps { }}/bin/${name}";
    })
    {
      dx-keyring = {
        file = ../scripts/dx-keyring.sh;
        deps = [ pkgs.coreutils ]; # dirname, in the bootstrap-volume/HOME library-candidate search
      };
      dx-verify-inventory = {
        file = ../scripts/dx-verify-inventory.sh;
        deps = [ ]; # command -v/printf only
      };
      dx-claude-statusline = {
        file = ../scripts/dx-claude-statusline.sh;
        deps = [ pkgs.coreutils pkgs.jq ]; # cat/mkdir/mv/cut; jq
      };
      dx-herdr-navigate = {
        file = ../scripts/dx-herdr-navigate.sh;
        deps = [ pkgs.jq ]; # herdr itself stays ambient (optional, via HERDR_BIN_PATH/command -v)
      };
    }
  // {
    ".local/bin/dx-ai" = {
      executable = true;
      source = ../scripts/dx-ai.sh;
    };

    # dx-ai loads this at runtime (it is a source-only library, not a
    # command); see scripts/dx-ai.sh's dx_ai_load_opencode_persistence for
    # why it also looks for a copy on the bootstrap volume.
    ".local/lib/dx/dx-opencode-persistence.sh".source =
      ../scripts/lib/dx-opencode-persistence.sh;

    # Shared guest-system detection (Branch 11 / Phase 4, DQ7), used by both
    # dx-ai (dx_ai_load_guest_system, same three-candidate shape as
    # dx-opencode-persistence.sh above) and bootstrap.sh (which sources it
    # directly from the bootstrap volume, since it never runs
    # post-activation).
    ".local/lib/dx/dx-guest-system.sh".source =
      ../scripts/lib/dx-guest-system.sh;

    # Guest keyring ownership lives entirely in the AI-tools layer
    # (Branch 16): dx-ai's dx_ai_ensure_keyring and the dx-keyring command
    # above are both thin wrappers over this shared library (source-only,
    # like dx-opencode-persistence.sh above), and home/shell.nix's
    # profileExtra reads the recorded bus address through it too. Bootstrap
    # keeps none of this.
    ".local/lib/dx/dx-keyring.sh".source =
      ../scripts/lib/dx-keyring.sh;

    ".local/share/nvim/site/after/plugin/dx-herdr-navigator.lua".source =
      ../nvim/extra_plugins/herdr-navigator.lua;
  };
}
