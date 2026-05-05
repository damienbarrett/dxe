{
  description = "DX Experience Guest Tools";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixvim = {
      url = "github:nix-community/nixvim/nixos-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixvim, home-manager, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { 
        inherit system; 
        config.allowUnfree = true;
      };
      
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

      # Shared package list for devShell and tools profile
      dxPackages = (with pkgs; [
        coreutils
        gnused
        gnugrep
        findutils
        procps
        util-linux
        btrfs-progs
        e2fsprogs
        less
        man-db
        file
        git
        nix
        openssh
        tmux
        ncurses
        bash-completion
        which
        ripgrep
        fd
        curl
        cacert
        jq
        direnv
        nix-direnv
        just
        go-task
        yazi
        btop
        ghostty.terminfo
        gemini-cli
      ]) ++ [
        unstable.claude-code
        unstable.codex
      ];

      # Imported NixVim configuration
      nvim = import ./nixvim.nix { inherit pkgs nixvim system; };

      # Test image from NixOS GitHub
      testImage = pkgs.fetchurl {
        url = "https://avatars.githubusercontent.com/u/487568?s=200&v=4";
        hash = "sha256-kVAx6WRUiS0fJIat/ymUVwj+2dp2ewgIx1LkCIuwFW4=";
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = dxPackages ++ [ nvim ];
      };

      packages.${system}.default = pkgs.buildEnv {
        name = "dx-tools";
        paths = dxPackages ++ [ nvim ];
      };

      homeConfigurations.dx = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit testImage; };
        modules = [ 
          ./home.nix
          {
            home.packages = dxPackages ++ [ nvim ];
          }
        ];
      };
    };
}
