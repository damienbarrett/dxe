{ config, lib, pkgs, testImage, ... }:

{
  imports = [ ./home/shell.nix ./home/tools.nix ./home/theme.nix ];
  home.username = "dx";
  home.homeDirectory = "/home/dx";
  home.stateVersion = "26.05";
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

  home.file.".local/lib/dx/dx-keyring.sh".source = ./scripts/lib/dx-keyring.sh;

  # Declaratively place the test image in the home directory
  home.file."test-image.png".source = testImage;
}
