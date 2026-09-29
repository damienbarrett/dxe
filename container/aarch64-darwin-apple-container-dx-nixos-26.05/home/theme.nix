{ config, lib, pkgs, ... }:

let
  dxThemeScript = import ./dx-scripts.nix { inherit pkgs; };

  # Single source of truth for dx-theme aliases. Each key is the alias the
  # user types (e.g. `dx-theme catppuccin-mocha`); each value is the base16
  # scheme name tinty applies. dx-theme.sh reads this via jq from
  # ~/.config/dx/themes.json — adding a theme is a one-place edit.
  dxThemes = {
    # Existing aliases — unchanged behavior. `dark` intentionally stays on
    # Mocha: its warm base00 avoids the near-black Gruvbox hard background.
    dark                 = "base16-mocha";
    light                = "base16-gruvbox-light-medium";
    rose-pine            = "base16-rose-pine";
    rose-pine-moon       = "base16-rose-pine-moon";
    rose-pine-dawn       = "base16-rose-pine-dawn";

    # Gruvbox — explicit alias for users who want the darker hard variant.
    gruvbox-dark         = "base16-gruvbox-dark-hard";

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

    # Shades of Purple — matches the Tinted/Base16 scheme name.
    shades-of-purple     = "base16-shades-of-purple";
  };

  # Alias used at fresh-init when the user has no recorded theme yet.
  dxDefault = "dark";

  preferredSchemes = lib.unique (lib.attrValues dxThemes);

  # Tinty TOML config rendered from a pure Nix attrset via nixpkgs' TOML
  # formatter. Verified against Tinty 0.29.0 from the pinned nixpkgs input:
  # - preferred-schemes is supported.
  # - hooks receive TINTY_THEME_FILE_PATH and TINTY_SCHEME_PALETTE_*.
  # - runtime templates are managed by `tinty install` / `tinty sync`.
  tomlFormat = pkgs.formats.toml { };
  tintyConfig = {
    shell = "bash -c '{}'";
    default-scheme = dxThemes.${dxDefault};
    preferred-schemes = preferredSchemes;
    hooks = [ "dx-theme-osc-hook" ];
    items = [
      {
        name = "tinted-shell";
        path = "https://github.com/tinted-theming/tinted-shell";
        themes-dir = "scripts";
        supported-systems = [ "base16" "base24" ];
        hook = "dx-theme-copy-hook shell";
      }
      {
        name = "tinted-tmux";
        path = "https://github.com/tinted-theming/tinted-tmux";
        themes-dir = "colors";
        supported-systems = [ "base16" "base24" ];
        hook = "dx-theme-copy-hook tmux";
      }
      {
        name = "tinted-lazygit";
        path = "https://github.com/tinted-theming/tinted-lazygit";
        themes-dir = "themes";
        supported-systems = [ "base16" ];
        hook = "dx-theme-copy-hook lazygit";
      }
    ];
  };
in
{
  xdg.configFile."tinted-theming/tinty/config.toml".source =
    tomlFormat.generate "tinty-config.toml" tintyConfig;

  # JSON registry consumed by dx-theme.sh.
  xdg.configFile."dx/themes.json".text = builtins.toJSON dxThemes;

  # Plain-text default alias — read by the activation hook below.
  xdg.configFile."dx/themes-default".text = dxDefault;

  # WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): each installed
  # theme command is a `pkgs.writeShellApplication` wrapper over the raw
  # script (still the source of truth, still loadable directly for tests),
  # with exactly the runtime dependencies that script actually calls listed
  # as `deps` -- see dx-scripts.nix. `checks.<system>.scripts-hermetic`
  # (flake.nix) proves the restore/copy-hook pair no longer depends on an
  # ambient PATH.
  home.file = lib.mapAttrs'
    (name: spec: lib.nameValuePair ".local/bin/${name}" {
      source = "${dxThemeScript name spec.file spec.deps (spec.extra or { })}/bin/${name}";
    })
    {
      dx-theme-copy-hook = {
        file = ../scripts/dx-theme-copy-hook.sh;
        deps = [ pkgs.coreutils ]; # mkdir/cp; tmux stays ambient (optional, guarded)
      };
      dx-theme-write-tool-themes = {
        file = ../scripts/dx-theme-write-tool-themes.sh;
        deps = [ pkgs.tinty pkgs.coreutils ]; # tinty info; mkdir/cat/mktemp/chmod/mv/dirname/stat
        extra.excludeShellChecks = [
          # The `\033\\` pairs in the OSC/DCS escape sequences this writes
          # (write_herdr_host_terminals) are literal backslash-backslash
          # bytes ending a single-quoted string, not an attempt to escape
          # the closing quote -- SC1003 is an info-level false positive on
          # this pattern (also excluded below for dx-theme-restore and
          # dx-theme-osc-hook, which build the same sequences).
          "SC1003"
          # `[ -r "$proc/comm" ] && read ... || continue`
          # (write_herdr_host_terminals): both the `[ -r ]` failure and the
          # `read` failure are meant to `continue`, so the A&&B||C ambiguity
          # SC2015 warns about does not apply -- there is no distinct
          # else-only-for-B branch here.
          "SC2015"
        ];
      };
      dx-theme-osc-hook = {
        file = ../scripts/dx-theme-osc-hook.sh;
        deps = [ ]; # printf only; delegates to dx-theme-write-tool-themes for everything else
        extra.excludeShellChecks = [ "SC1003" ]; # see dx-theme-write-tool-themes above
      };
      dx-theme-restore = {
        file = ../scripts/dx-theme-restore.sh;
        deps = [ pkgs.tinty pkgs.gnused pkgs.coreutils ]; # tinty current/info; sed; cat
        extra.excludeShellChecks = [ "SC1003" ]; # see dx-theme-write-tool-themes above
      };
      dx-theme = {
        file = ../scripts/dx-theme.sh;
        deps = [ pkgs.tinty pkgs.jq pkgs.gnused pkgs.util-linux pkgs.coreutils ]; # tinty; themes.json; sed; column; cat/mkdir
        extra.excludeShellChecks = [
          # `$k` inside the single-quoted jq filters (resolve_scheme,
          # is_alias) is a jq variable bound by `--arg k`, not a shell
          # variable -- SC2016 is an info-level false positive for jq/awk
          # filter strings written this way.
          "SC2016"
        ];
      };
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
