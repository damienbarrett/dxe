{
  description = "DX Experience Guest Tools";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Pinned to the nixpkgs-unstable channel branch (not master) so the AI CLI
    # bundle still tracks freshly packaged versions, but only ones Hydra has
    # already built -- this branch only advances once a revision is fully
    # built, so it is cached on cache.nixos.org for both aarch64-linux and
    # x86_64-linux. Tracking master instead let a refresh land on a revision
    # not yet cached for the guest's architecture, and Nix silently built the
    # miss from source inside the guest (found on Branch 6, 2026-09-26:
    # codex-core/codex-tui OOM-killed at the profile's default 12 GB). Feeds
    # ONLY aiPackages/packages.ai-tools; dx-ai.sh's dx_ai_check_cached is the
    # remaining safety net for a channel-branch package that still misses.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
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
      # Branch 11 / Phase 4 (qnap-dxe-plan.md DQ7, docs/refactor/
      # arch-neutral-guest.md section 2): the guest source tree is
      # architecture-neutral -- one flake, evaluated for every system DQ7's
      # table names, rather than a duplicated Home Manager/NixVim/bootstrap/
      # scripts tree per architecture. aarch64-linux is Apple's native
      # system and stays the default (homeConfigurations.dx below);
      # x86_64-linux is the QNAP's. No new flake input: forEachSystem is a
      # small local helper over nixpkgs.lib.
      supportedSystems = [ "aarch64-linux" "x86_64-linux" ];
      forEachSystem = f: nixpkgs.lib.genAttrs supportedSystems f;

      agyPin = builtins.fromJSON (builtins.readFile ./pins/agy.json);

      # Everything that used to be computed once for a single hardcoded
      # aarch64-linux `system` is now a function of `system`, called once
      # per supported system by forEachSystem below. Every body is
      # unchanged from before this branch except for taking `system` as a
      # parameter instead of closing over one fixed value.
      perSystem = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };

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
          #
          # Branch 11 / Phase 4, Increment 1: still reads the single flat
          # agyPin (not yet keyed per system) for every system --
          # pins/agy.json becomes a per-system keyed map, and this
          # derivation becomes conditional on that system having a native
          # artifact, in the very next increment (docs/refactor/
          # arch-neutral-guest.md section 3). This increment is per-system
          # OUTPUTS only (design point A); it does not change which bytes
          # `agy` resolves to for any system.
          agy = pkgs.stdenv.mkDerivation rec {
            pname = "antigravity-cli";
            version = agyPin.version;

            src = pkgs.fetchurl {
              # An explicit name keeps this derivation's store-path name stable
              # (antigravity-cli-src) across pin refreshes, independent of
              # whatever filename Google's manifest happens to use -- dx-ai.sh's
              # dx_ai_check_cached allow-lists this exact name as agy's own
              # trivial, always-local fetch step (fetchurl otherwise defaults the
              # name to the URL's basename, which is not under our control).
              name = "antigravity-cli-src";
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
            opencode
            # agy stores its known CLI state under ~/.gemini/antigravity-cli, which
            # DXE persists via ~/.gemini. Keep D-Bus + gnome-keyring available for
            # Secret Service compatibility in auth flows that still request it.
            pkgs.dbus
            pkgs.gnome-keyring
          ];

          # Imported NixVim configuration
          nvim = import ./nixvim.nix { inherit pkgs nixvim system; };
        in
        {
          devShells = {
            default = pkgs.mkShell {
              buildInputs = dxPackages ++ [ nvim ];
            };
          };

          packages = {
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

          homeConfiguration = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              ./home.nix
              {
                home.packages = dxPackages ++ [ nvim ];
              }
            ];
          };
        };

      perSystemOutputs = forEachSystem perSystem;

      # homeConfigurations is conventionally a flat attrset keyed by an
      # arbitrary configuration name (Home Manager does not nest it per
      # system the way packages/devShells are), so this flattens
      # forEachSystem's per-system result into flat "dx-<system>"
      # attribute names instead of nesting under perSystemOutputs.<system>.
      homeConfigurationsBySystem = nixpkgs.lib.mapAttrs'
        (system: out: nixpkgs.lib.nameValuePair "dx-${system}" out.homeConfiguration)
        perSystemOutputs;
    in
    {
      devShells = nixpkgs.lib.mapAttrs (_: out: out.devShells) perSystemOutputs;

      packages = nixpkgs.lib.mapAttrs (_: out: out.packages) perSystemOutputs;

      # homeConfigurations.dx stays a real alias -- the SAME derivation, not
      # a second definition that could drift -- of "dx-aarch64-linux", so
      # nothing that still names the bare "dx" attribute breaks. Apple's
      # guest selects "dx-<system>" explicitly from Increment 3 onward; the
      # alias is a compatibility net for anything else that still types the
      # bare name.
      homeConfigurations = homeConfigurationsBySystem // {
        dx = homeConfigurationsBySystem."dx-aarch64-linux";
      };
    };
}
