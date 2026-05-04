{ pkgs, nixvim, system }:

let
  lib = pkgs.lib;
  options = import ./nvim/options.nix;
  plugins = import ./nvim/plugins.nix;
  keymaps = import ./nvim/keymaps.nix { inherit lib; };
  extra = import ./nvim/extra.nix { inherit pkgs; };
in
nixvim.legacyPackages.${system}.makeNixvim (
  lib.foldl' lib.recursiveUpdate {} [
    options
    plugins
    keymaps
    extra
  ]
)
