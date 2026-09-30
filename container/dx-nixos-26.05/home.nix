{ config, lib, pkgs, ... }:

{
  imports = [ ./home/shell.nix ./home/tools.nix ./home/theme.nix ];
  home.username = "dx";
  home.homeDirectory = "/home/dx";
  home.stateVersion = "26.05";
  # WP7.3/WP7.4 (docs/reviews/2026-09-29-fable.md findings C3, C4): fish,
  # nushell and starship used to be listed here too, duplicating the
  # packages programs.fish, programs.nushell and programs.starship
  # (home/shell.nix) already add -- proven with `nix eval
  # .../config.home.packages`, which showed fish and nushell twice (starship
  # was not yet duplicated only because programs.starship did not exist).
  # nodejs stays: it is deliberately outside the dx-tooling set
  # guest-tools.nix maps.
  home.packages = with pkgs; [
    nodejs # Still keep nodejs for other tasks if needed
  ];

  # Declaratively ensure Neovim directories exist
  xdg.enable = true;
  xdg.dataFile."nvim/.keep".text = "";
  xdg.stateFile."nvim/.keep".text = "";
  xdg.cacheFile."nvim/.keep".text = "";

  # dx-keyring.sh is installed once, by home/tools.nix (alongside the
  # dx-keyring command it backs). This file used to define the same
  # home.file path a second time (harmless only because both resolved to
  # the identical store path -- WP7.3, Fable C3).
}
