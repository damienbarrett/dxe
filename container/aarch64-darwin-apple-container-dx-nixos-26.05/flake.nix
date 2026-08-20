{
  description = "DX Experience Guest Tools";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Pinned to master (not the nixos-unstable channel) so the AI CLI bundle tracks the freshest packaged versions; feeds ONLY aiPackages/packages.ai-tools.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/master";
    nixvim = {
      url = "github:nix-community/nixvim/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
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
      agyPin = builtins.fromJSON (builtins.readFile ./pins/agy.json);

      # Shared package list for devShell and default tools profile
      dxPackages = with pkgs; [
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
        gh
        nix
        openssh
        tmux
        tinty
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
        lazygit
        yazi
        btop
        fastfetch
        tzdata
      ];

      # The tools required before Home Manager starts are one locked flake
      # output. Keeping this list here prevents bootstrap from resolving
      # nixpkgs through the mutable global registry.
      #
      # This is a bootstrap closure, not a subset of dxPackages: it is
      # deliberately kept separate so that editing the guest toolset above can
      # never silently change what the guest needs to reach sshd. One package
      # per line, matching dxPackages -- test_refactor_contracts.sh parses this
      # list line-by-line to check it still covers the pre-sshd binaries.
      bootstrapEssentials = with pkgs; [
        bashInteractive
        shadow
        openssh
        gnutar
        gzip
        sudo
        coreutils
        gnused
        gnugrep
        which
        procps
        util-linux
        btrfs-progs
        e2fsprogs
      ];

      # Antigravity CLI (`agy`) — Google's agentic coding tool. The nixpkgs
      # `antigravity` package is the Electron editor, which is unusable in a
      # headless guest; the real CLI is a separate Go binary distributed by
      # Google. Mirrors what `curl -fsSL https://antigravity.google/cli/install.sh
      # | bash` would do, but pinned and autoPatchelf'd for NixOS.
      agy = pkgs.stdenv.mkDerivation rec {
        pname = "antigravity-cli";
        version = agyPin.version;

        src = pkgs.fetchurl {
          url = agyPin.url;
          hash = agyPin.hash;
        };

        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc ];

        unpackPhase = ''
          runHook preUnpack
          tar -xzf $src
          runHook postUnpack
        '';

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          install -Dm755 antigravity $out/bin/agy
          runHook postInstall
        '';
      };

      # Optional AI CLI tools kept out of the default install.
      # `agy` is the locally-defined Antigravity CLI derivation above; let-bound
      # names take precedence over `with unstable;`, so it resolves correctly.
      aiPackages = with unstable; [
        gemini-cli
        claude-code
        codex
        agy
        herdr
        # agy stores its known CLI state under ~/.gemini/antigravity-cli, which
        # DXE persists via ~/.gemini. Keep D-Bus + gnome-keyring available for
        # Secret Service compatibility in auth flows that still request it.
        pkgs.dbus
        pkgs.gnome-keyring
      ];

      # Imported NixVim configuration
      nvim = import ./nixvim.nix { inherit pkgs nixvim system; };

      # Test image from NixOS GitHub
      testImage = pkgs.fetchurl {
        url = "https://avatars.githubusercontent.com/u/487568?s=200&v=4";
        hash = "sha256-4lDgsPtttAiM8b8d9vWZj4PbbhLPxANen+KwmYuLC3k=";
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = dxPackages ++ [ nvim ];
      };

      packages.${system} = {
        default = pkgs.buildEnv {
          name = "dx-tools";
          paths = dxPackages ++ [ nvim ];
        };

        "ai-tools" = pkgs.buildEnv {
          name = "dx-ai-tools";
          paths = aiPackages;
        };

        bootstrap-essentials = pkgs.buildEnv {
          name = "dx-bootstrap-essentials";
          paths = bootstrapEssentials;
        };
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
