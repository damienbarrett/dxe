{ config, lib, pkgs, ... }:

let
  # Single source of truth for dx-theme aliases. Each key is the alias the
  # user types (e.g. `dx-theme catppuccin-mocha`); each value is the base16
  # scheme name tinty applies. dx-theme.sh reads this via jq from
  # ~/.config/dx/themes.json — adding a theme is a one-place edit.
  dxThemes = {
    # Existing aliases — unchanged behavior.
    dark                 = "base16-gruvbox-dark-hard";
    light                = "base16-gruvbox-light-medium";
    rose-pine            = "base16-rose-pine";
    rose-pine-moon       = "base16-rose-pine-moon";
    rose-pine-dawn       = "base16-rose-pine-dawn";

    # Everforest — explicit dark/light variants.
    everforest-dark      = "base16-everforest-dark-hard";
    everforest-light     = "base16-everforest-light-medium";

    # Catppuccin — bare alias defaults to mocha (most popular dark variant).
    catppuccin           = "base16-catppuccin-mocha";
    catppuccin-latte     = "base16-catppuccin-latte";
    catppuccin-frappe    = "base16-catppuccin-frappe";
    catppuccin-macchiato = "base16-catppuccin-macchiato";
    catppuccin-mocha     = "base16-catppuccin-mocha";

    # Solarized — explicit light/dark, matches upstream naming.
    solarized-light      = "base16-solarized-light";
    solarized-dark       = "base16-solarized-dark";
  };

  # Alias used at fresh-init when the user has no recorded theme yet.
  dxDefault = "dark";

  # Schemes kept in tinty's preferred-schemes list but intentionally NOT
  # exposed as dx-theme aliases. Useful for back-compat with raw scheme ids
  # users may have invoked via `dx-theme apply`.
  extraPreferredSchemes = [ "base16-mocha" ];

  preferredSchemes = lib.unique (lib.attrValues dxThemes ++ extraPreferredSchemes);
  preferredSchemesRendered =
    lib.concatMapStringsSep ",\n      " (s: ''"${s}"'') preferredSchemes;
in
{
  xdg.configFile."tinted-theming/tinty/config.toml".text = ''
    # DXE Tinty experiment.
    # Verified against Tinty 0.29.0 from the pinned nixpkgs input:
    # - preferred-schemes is supported.
    # - hooks receive TINTY_THEME_FILE_PATH and TINTY_SCHEME_PALETTE_*.
    # - runtime templates are managed by `tinty install` / `tinty sync`.
    shell = "bash -c '{}'"
    default-scheme = "${dxThemes.${dxDefault}}"
    preferred-schemes = [
      ${preferredSchemesRendered},
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

  # JSON registry consumed by dx-theme.sh.
  xdg.configFile."dx/themes.json".text = builtins.toJSON dxThemes;

  # Plain-text default alias — read by the activation hook below.
  xdg.configFile."dx/themes-default".text = dxDefault;

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
      default_alias="$(cat "$HOME/.config/dx/themes-default" 2>/dev/null || echo dark)"
      "$HOME/.local/bin/dx-theme" "$default_alias" >/dev/null 2>&1 || true
    elif [ -x "$HOME/.local/bin/dx-theme-write-tool-themes" ] \
      && [ -x "$HOME/.nix-profile/bin/tinty" ]; then
      current="$("$HOME/.nix-profile/bin/tinty" current 2>/dev/null || true)"
      if [ -n "$current" ]; then
        "$HOME/.local/bin/dx-theme-write-tool-themes" "$current" >/dev/null 2>&1 || true
      fi
    fi
  '';
}
