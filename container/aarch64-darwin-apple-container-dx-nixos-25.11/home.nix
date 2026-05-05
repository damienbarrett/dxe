{ config, pkgs, testImage, ... }:

{
  home.username = "dx";
  home.homeDirectory = "/home/dx";
  home.stateVersion = "25.11";
home.packages = with pkgs; [
  starship
  fish
  nushell
  nodejs # Still keep nodejs for other tasks if needed
];


  # Declaratively ensure Neovim directories exist
  xdg.enable = true;
  xdg.dataFile."nvim/.keep".text = "";
  xdg.stateFile."nvim/.keep".text = "";
  xdg.cacheFile."nvim/.keep".text = "";

  # Declaratively place the test image in the home directory
  home.file."test-image.png".source = testImage;

  # Shell configurations
  programs.bash = {
    enable = true;
    profileExtra = ''
      export PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH
    '';
    initExtra = ''
      if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook bash)"
      fi
      if command -v starship >/dev/null 2>&1; then
        eval "$(starship init bash)"
      fi
    '';
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting
      if type -q starship
        starship init fish | source
      end
      if type -q direnv
        direnv hook fish | source
      end
    '';
  };

  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }
    '';
    envFile.text = ''
      $env.PATH = ($env.PATH | split row (char esep) | append '($home)/.nix-profile/bin')
      $env.EDITOR = "nvim"
      $env.VISUAL = "nvim"
    '';
  };

  programs.starship = {
    enable = true;
  };

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

  # Ensure .local/bin is in PATH (though AI tools are now in nix-profile)
  home.sessionVariables = {
    PATH = "$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH";
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
