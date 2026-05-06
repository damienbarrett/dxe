{ config, lib, pkgs, ... }:

{
  xdg.configFile."tinted-theming/tinty/config.toml".text = ''
    # DXE Tinty experiment.
    # Verified against Tinty 0.29.0 from the pinned nixpkgs input:
    # - preferred-schemes is supported.
    # - hooks receive TINTY_THEME_FILE_PATH and TINTY_SCHEME_PALETTE_*.
    # - runtime templates are managed by `tinty install` / `tinty sync`.
    shell = "bash -c '{}'"
    default-scheme = "base16-mocha"
    preferred-schemes = [
      "base16-mocha",
      "base16-gruvbox-light-medium",
      "base16-rose-pine",
      "base16-rose-pine-moon",
      "base16-rose-pine-dawn",
    ]
    hooks = ["dx-theme-osc-hook"]

    [[items]]
    name = "tinted-shell"
    path = "https://github.com/tinted-theming/tinted-shell"
    themes-dir = "scripts"
    supported-systems = ["base16", "base24"]
    hook = "dx-theme-copy-hook shell"

    [[items]]
    name = "tinted-tmux"
    path = "https://github.com/tinted-theming/tinted-tmux"
    themes-dir = "colors"
    supported-systems = ["base16", "base24"]
    hook = "dx-theme-copy-hook tmux"

    [[items]]
    name = "tinted-lazygit"
    path = "https://github.com/tinted-theming/tinted-lazygit"
    themes-dir = "themes"
    supported-systems = ["base16"]
    hook = "dx-theme-copy-hook lazygit"
  '';

  home.file.".local/bin/dx-theme-copy-hook" = {
    executable = true;
    source = ../scripts/dx-theme-copy-hook.sh;
  };

  home.file.".local/bin/dx-theme-write-tool-themes" = {
    executable = true;
    source = ../scripts/dx-theme-write-tool-themes.sh;
  };

  home.file.".local/bin/dx-theme-osc-hook" = {
    executable = true;
    source = ../scripts/dx-theme-osc-hook.sh;
  };

  home.file.".local/bin/dx-theme-restore" = {
    executable = true;
    source = ../scripts/dx-theme-restore.sh;
  };

  home.file.".local/bin/dx-theme" = {
    executable = true;
    source = ../scripts/dx-theme.sh;
  };

  home.activation.tintyDefaultTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ ! -s "$HOME/.config/dx/theme-current" ] \
      && [ -x "$HOME/.local/bin/dx-theme" ] \
      && [ -x "$HOME/.nix-profile/bin/tinty" ]; then
      "$HOME/.local/bin/dx-theme" dark >/dev/null 2>&1 || true
    elif [ -x "$HOME/.local/bin/dx-theme-write-tool-themes" ] \
      && [ -x "$HOME/.nix-profile/bin/tinty" ]; then
      current="$("$HOME/.nix-profile/bin/tinty" current 2>/dev/null || true)"
      if [ -n "$current" ]; then
        "$HOME/.local/bin/dx-theme-write-tool-themes" "$current" >/dev/null 2>&1 || true
      fi
    fi
  '';
}
