{ config, pkgs, ... }:

let
  # Generic AI tools often installed via npm
  aiTools = with pkgs; [
    nodejs
    # We could add more here if they were in nixpkgs, 
    # otherwise we install them via home.activation or shell aliases.
  ];
in
{
  home.username = "dx";
  home.homeDirectory = "/home/dx";
  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    starship
    fish
    nushell
    # Other tools
  ] ++ aiTools;

  # Shell configurations
  programs.bash = {
    enable = true;
    initExtra = ''
      export PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH
      eval "$(direnv hook bash)"
      eval "$(starship init bash)"
    '';
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting
      starship init fish | source
      direnv hook fish | source
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
    '';
  };

  programs.starship = {
    enable = true;
    # Custom settings can go here
  };

  programs.tmux = {
    enable = true;
    extraConfig = ''
      set -g default-terminal "tmux-256color"
      set -as terminal-features ",xterm-256color:RGB"
      set -ga terminal-overrides ",xterm-256color:Tc"
      set -s escape-time 0
      set -g mouse on
      set -g history-limit 50000
      
      # Yazi image support (Ghostty/Kitty protocol)
      set -g allow-passthrough on
      set -ga update-environment TERM
      set -ga update-environment TERM_PROGRAM
    '';
  };

  # Activation script to install AI tools via npm if not already present
  home.activation = {
    installAiTools = config.lib.dag.entryAfter ["writeBoundary"] ''
      export PATH="${pkgs.nodejs}/bin:$PATH"
      # Claude Code
      if ! command -v claude >/dev/null 2>&1; then
        echo "Installing Claude Code..."
        ${pkgs.nodejs}/bin/npm install -g @anthropic-ai/claude-code --prefix $HOME/.local
      fi
      # Gemini CLI
      if ! command -v gemini >/dev/null 2>&1; then
        echo "Installing Gemini CLI..."
        ${pkgs.nodejs}/bin/npm install -g @google/gemini-cli --prefix $HOME/.local
      fi
      # OpenAI Codex (using common alternative if official is generic)
      if ! command -v codex >/dev/null 2>&1; then
         echo "Installing OpenAI Codex CLI..."
         ${pkgs.nodejs}/bin/npm install -g @openai/codex --prefix $HOME/.local
      fi
      # OpenCode
      if ! command -v opencode >/dev/null 2>&1; then
         echo "Installing OpenCode CLI..."
         ${pkgs.nodejs}/bin/npm install -g opencode-ai --prefix $HOME/.local
      fi
    '';
  };

  # Ensure .local/bin is in PATH for npm -g --prefix
  home.sessionVariables = {
    PATH = "$HOME/.local/bin:$PATH";
  };
}
