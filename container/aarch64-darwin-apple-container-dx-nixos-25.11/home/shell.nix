{ config, pkgs, ... }:

{
  programs.bash = {
    enable = true;
    profileExtra = ''
      export PATH=$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH
    '';
    initExtra = ''
      set -o vi
      
      if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook bash)"
      fi
      if command -v starship >/dev/null 2>&1; then
        eval "$(starship init bash)"
      fi
      if [ -f "$HOME/.cache/dx/tinty/lazygit.yml" ]; then
        export LG_CONFIG_FILE="$HOME/.config/lazygit/config.yml,$HOME/.cache/dx/tinty/lazygit.yml"
      else
        export LG_CONFIG_FILE="$HOME/.config/lazygit/config.yml"
      fi
      if [ -f "$HOME/.cache/dx/tinty/shell.sh" ]; then
        # shellcheck disable=SC1090
        . "$HOME/.cache/dx/tinty/shell.sh"
      fi
      if [ -x "$HOME/.local/bin/dx-theme-restore" ]; then
        "$HOME/.local/bin/dx-theme-restore" 2>/dev/null || true
      fi
    '';
  };

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set -g fish_greeting
      fish_vi_key_bindings
      
      if type -q starship
        starship init fish | source
      end
      if type -q direnv
        direnv hook fish | source
      end
      if test -f "$HOME/.cache/dx/tinty/lazygit.yml"
        set -gx LG_CONFIG_FILE "$HOME/.config/lazygit/config.yml,$HOME/.cache/dx/tinty/lazygit.yml"
      else
        set -gx LG_CONFIG_FILE "$HOME/.config/lazygit/config.yml"
      end
      if test -f "$HOME/.cache/dx/tinty/shell.sh"
        sh "$HOME/.cache/dx/tinty/shell.sh"
      end
      if test -x "$HOME/.local/bin/dx-theme-restore"
        "$HOME/.local/bin/dx-theme-restore" 2>/dev/null
      end
    '';
  };

  programs.nushell = {
    enable = true;
    configFile.text = ''
      # Nushell Tinted-shell startup support is intentionally not enabled.
      # It has not been proven for the selected Tinty template version.
      $env.config = {
        show_banner: false
        edit_mode: "vi"
      }
      try { ^/home/dx/.local/bin/dx-theme-restore }
    '';
    envFile.text = ''
      $env.PATH = ($env.PATH | split row (char esep) | append $"($nu.home-path)/.local/bin" | append $"($nu.home-path)/.nix-profile/bin")
      $env.EDITOR = "nvim"
      $env.VISUAL = "nvim"
      $env.SSL_CERT_FILE = $"($nu.home-path)/.nix-profile/etc/ssl/certs/ca-bundle.crt"
      $env.NIX_SSL_CERT_FILE = $"($nu.home-path)/.nix-profile/etc/ssl/certs/ca-bundle.crt"
      $env.WORKSPACE = "/workspace"
      let lazygit_config = $"($nu.home-path)/.config/lazygit/config.yml"
      let lazygit_theme = $"($nu.home-path)/.cache/dx/tinty/lazygit.yml"
      $env.LG_CONFIG_FILE = if ($lazygit_theme | path exists) {
        $"($lazygit_config),($lazygit_theme)"
      } else {
        $lazygit_config
      }
    '';
  };

  home.sessionVariables = {
    PATH = "$HOME/.nix-profile/bin:$HOME/.local/bin:$PATH";
    EDITOR = "nvim";
    VISUAL = "nvim";
    SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    WORKSPACE = "/workspace";
  };
}
