{
  description = "DX Experience Guest Tools";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixvim = {
      url = "github:nix-community/nixvim/nixos-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixvim, home-manager, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };
      
      # Shared package list for devShell and tools profile
      dxPackages = with pkgs; [
        coreutils
        gnused
        gnugrep
        findutils
        procps
        util-linux
        less
        man-db
        file
        git
        openssh
        tmux
        ncurses
        bash-completion
        ripgrep
        fd
        curl
        jq
        direnv
        nix-direnv
        just
        go-task
        yazi
      ];

      # Imported NixVim configuration
      nvim = import ./nixvim.nix { inherit pkgs nixvim system; };
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
        modules = [ 
          ./home.nix
          {
            home.packages = [ nvim ];
          }
        ];
      };
    };
}
