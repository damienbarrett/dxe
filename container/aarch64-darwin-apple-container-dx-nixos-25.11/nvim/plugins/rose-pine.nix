{ pkgs, ... }:

{
  # Keep Rose Pine packaged as a manual fallback, but let tinted-nvim select
  # the runtime Tinty scheme on startup.
  extraPlugins = [
    pkgs.vimPlugins.rose-pine
  ];
}
