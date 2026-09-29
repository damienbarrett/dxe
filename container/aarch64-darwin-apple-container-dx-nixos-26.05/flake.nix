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
            config = {
              allowUnfree = true;
            };
          };

          # WP7.3 (docs/reviews/2026-09-29-fable.md finding C3, Muse B4):
          # guest-tools.nix is the one mapping from nixpkgs attribute to the
          # user-facing command(s) it must provide. dxPackages is generated
          # from its keys, and requiredInventory below (consumed by
          # checks.inventory and checks.inventory-list) from its values, so
          # the two can no longer drift the way the hand-synced dxPackages
          # list and scripts/dx-verify-inventory.sh's hand-synced literal
          # had (reverse-direction gap: man, starship, node, fish, nu,
          # tput/clear were installed but never verified).
          guestTools = import ./guest-tools.nix;
          dxPackages = map (n: pkgs.${n}) (pkgs.lib.attrNames guestTools);

          # Packages already installed through a typed `programs.*` option
          # (or a Home Manager default, for man-db) or another list, so they
          # are not in guest-tools.nix -- see that file's header -- but
          # their commands are still part of the inventory contract.
          dxVerifyInventoryScript = ./scripts/dx-verify-inventory.sh;
          requiredInventory = pkgs.lib.concatLists (pkgs.lib.attrValues guestTools) ++ [
            "nvim" # nixvim.legacyPackages.${system}.makeNixvimWithModule, below
            "man" # manual.manpages.enable (Home Manager default)
            "git" # programs.git, home/tools.nix
            "tmux" # programs.tmux, home/tools.nix
            "fish" # programs.fish, home/shell.nix
            "nu" # programs.nushell, home/shell.nix
            "starship" # programs.starship, home/shell.nix (WP7.4)
            "direnv" # programs.direnv, home/shell.nix (WP7.4)
            "yazi" # programs.yazi, home/shell.nix (WP7.4)
            "lazygit" # programs.lazygit, home/tools.nix (WP7.4)
            "node" # home.nix's own home.packages (nodejs)
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
          # Branch 11 / Phase 4, Increment 2 (qnap-dxe-plan.md DQ7,
          # docs/refactor/arch-neutral-guest.md section 3): pins/agy.json is
          # a per-system keyed map. A missing/unsupported system's entry is
          # JSON `null`, and this whole derivation becomes `null` for that
          # system -- so aiPackages below can only ever include a genuinely
          # native agy build; it is never possible for a foreign-
          # architecture binary to reach the closure by construction, not by
          # a runtime check.
          agySystemPin = agyPin.${system} or null;
          # WP7.6 (docs/reviews/2026-09-29-fable.md finding C6, corrects
          # Muse B6): built with `unstable` (not `pkgs`) so its `meta.license
          # = unfree` below falls under the SAME allowUnfreePredicate as the
          # rest of aiPackages (WP7.8) -- it is unconditionally part of that
          # closure anyway (`with unstable; [ ... agy ... ]` below), so this
          # is not a new dependency, just naming the one it already had.
          agy =
            if agySystemPin == null then null else unstable.stdenv.mkDerivation {
              pname = "antigravity-cli";
              version = agySystemPin.version;

              src = unstable.fetchurl {
                # An explicit name keeps this derivation's store-path name stable
                # (antigravity-cli-src) across pin refreshes, independent of
                # whatever filename Google's manifest happens to use -- dx-ai.sh's
                # dx_ai_check_cached allow-lists this exact name as agy's own
                # trivial, always-local fetch step (fetchurl otherwise defaults the
                # name to the URL's basename, which is not under our control).
                name = "antigravity-cli-src";
                url = agySystemPin.url;
                hash = agySystemPin.hash;
              };

              nativeBuildInputs = [ unstable.autoPatchelfHook ];
              buildInputs = [ unstable.stdenv.cc.cc.lib ];

              # Not stdenv's default unpackPhase in disguise: `src`'s `name`
              # above deliberately drops the `.tar.gz` suffix (for a stable
              # store path across pin refreshes), and stdenv's own unpack
              # dispatches purely on that suffix. Without it, a `.tar.gz`
              # with no recognisable extension is copied into the build
              # directory verbatim, still compressed -- this has to unpack
              # it explicitly.
              unpackPhase = ''
                runHook preUnpack
                tar -xzf $src
                runHook postUnpack
              '';
              sourceRoot = ".";

              dontConfigure = true;
              dontBuild = true;

              installPhase = ''
                runHook preInstall
                install -Dm755 antigravity $out/bin/agy
                runHook postInstall
              '';

              meta = {
                mainProgram = "agy";
                license = nixpkgs.lib.licenses.unfree;
                sourceProvenance = [ nixpkgs.lib.sourceTypes.binaryNativeCode ];
                # Every key of pins/agy.json except the human-readable "note"
                # (WP7.6) is a system this derivation can be native for; a
                # system missing from this list is an evaluation error even
                # if the `agySystemPin == null` guard above were bypassed,
                # not just a runtime check.
                platforms = nixpkgs.lib.attrNames
                  (nixpkgs.lib.filterAttrs (k: v: k != "note" && v != null) agyPin);
              };
            };

          # Optional AI CLI tools kept out of the default install.
          # `agy` is the locally-defined Antigravity CLI derivation above (or
          # `null` when this system has no native artifact -- omitted below,
          # never substituted); let-bound names take precedence over
          # `with unstable;`, so it resolves correctly.
          aiPackages = with unstable; [
            claude-code
            codex
          ] ++ nixpkgs.lib.optionals (agy != null) [
            agy
          ] ++ [
            herdr
            opencode
            # agy stores its known CLI state under ~/.gemini/antigravity-cli, which
            # DXE persists via ~/.gemini. Keep D-Bus + gnome-keyring available for
            # Secret Service compatibility in auth flows that still request it.
            pkgs.dbus
            pkgs.gnome-keyring
          ];

          # Imported NixVim configuration. `makeNixvimWithModule` (rather
          # than `makeNixvim`) is what takes an explicit `pkgs`; see
          # nixvim.nix for why.
          nvim = nixvim.legacyPackages.${system}.makeNixvimWithModule {
            inherit pkgs;
            module = ./nixvim.nix;
          };
        in
        rec {
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

          # WP2.1 (docs/reviews/2026-09-29-fable.md finding C1, Astra F11):
          # `nix flake check` never walked `homeConfigurations` (a custom,
          # non-standard flake output), so a broken Home Manager module or a
          # missing x86_64-linux package was only ever discovered on a live
          # guest boot. Exposing the same evaluations as flake `checks`
          # per system makes `nix flake check --all-systems` the CI gate that
          # actually forces them.
          checks = {
            # Forces the full Home Manager module evaluation for this
            # system, including every package in `dxPackages` (home.packages
            # above), which is why the separate `packages.<system>.default`
            # evaluation this replaced was redundant.
            home-activation = homeConfiguration.activationPackage;

            # bootstrap-essentials is not a subset of dxPackages (see its
            # own comment above), so it is not already forced by
            # home-activation the way packages.<system>.default was --
            # without its own check, a package present only for
            # aarch64-linux would go undetected on x86_64-linux until the
            # QNAP's bootstrap ran it for real.
            inherit (packages) ai-tools bootstrap-essentials;

            # homeConfigurations.dx is meant to be the SAME derivation as
            # homeConfigurations."dx-aarch64-linux" (a real alias, not a
            # second definition that could drift) -- see the top-level
            # `homeConfigurations` binding below. A failing `assert` is an
            # evaluation error, which is what actually proves it; comparing
            # two possibly-empty strings does not. Meaningful only once per
            # flake, but harmless (cheap: no build) to evaluate per system.
            alias-is-identity =
              assert self.homeConfigurations.dx.activationPackage.drvPath
                  == self.homeConfigurations."dx-aarch64-linux".activationPackage.drvPath;
              pkgs.emptyFile;

            # WP7.6 (docs/reviews/2026-09-29-fable.md finding C6, corrects
            # Muse B6): a pure-Nix shape contract over EVERY per-system pin
            # entry (pins/agy.json, ignoring its "note" key), replacing
            # test_section6_tools.sh's old literal assertion of the
            # aarch64-linux version/URL/hash, which asserted nothing about
            # x86_64-linux -- so a `dx-ai update` that moved the x86_64 pin
            # was free to write any shape at all there. This does not
            # assert the two systems' versions match (WP7.6's "note" key
            # records that today's skew is expected, not a bug); it asserts
            # every pin present is at least well-formed: an SRI sha512
            # hash, and a URL that actually names its own version and
            # architecture rather than, say, one pin's URL pasted under the
            # other system's key.
            agy-pin-shape =
              let
                archTag = {
                  aarch64-linux = "linux-arm";
                  x86_64-linux = "linux-x64";
                };
                systemPins = nixpkgs.lib.filterAttrs (k: _: k != "note") agyPin;
                pinShapeOk = system': pin:
                  pin == null || (
                    nixpkgs.lib.hasPrefix "sha512-" pin.hash
                    && nixpkgs.lib.hasInfix pin.version pin.url
                    && nixpkgs.lib.hasInfix (archTag.${system'} or "\x00unsupported") pin.url
                  );
              in
              assert nixpkgs.lib.all
                (system': pinShapeOk system' (agyPin.${system'} or null))
                supportedSystems;
              assert nixpkgs.lib.all
                (system': nixpkgs.lib.elem system' supportedSystems)
                (nixpkgs.lib.attrNames systemPins);
              pkgs.emptyFile;

            # WP7.3 (docs/reviews/2026-09-29-fable.md finding C3, Muse B4):
            # the reverse-direction inventory contract -- every user-facing
            # command this flake installs (guest-tools.nix's values, plus
            # the hand-listed extras that come from `programs.*` or another
            # list) must actually be present in the activated Home Manager
            # profile. `config.home.path` is the real aggregate environment
            # Home Manager builds from home.packages *and* every enabled
            # `programs.*` module, which is why this is checked against it
            # rather than packages.default (a bare buildEnv of dxPackages
            # alone, missing anything -- fish, nushell, starship, git, tmux,
            # man -- that only a `programs.*` module or another home.nix
            # list installs).
            inventory = pkgs.runCommand "dx-inventory"
              { homeEnv = homeConfiguration.config.home.path; } ''
              for t in ${pkgs.lib.escapeShellArgs requiredInventory}; do
                [ -x "$homeEnv/bin/$t" ] || { echo "missing: $t" >&2; exit 1; }
              done
              touch $out
            '';

            # scripts/dx-verify-inventory.sh must stay loadable raw (the
            # coordinating session sources/execs it on the live guest, and
            # tests source it directly), so it keeps its own literal
            # DX_REQUIRED_INVENTORY rather than being templated from this
            # flake. This check is the contract that stops the two literals
            # (the script's, and this file's requiredInventory) from
            # drifting apart again the way the script's list drifted from
            # the packages actually installed.
            inventory-list = pkgs.runCommand "dx-inventory-list-contract"
              { } ''
              script_list=$(bash ${dxVerifyInventoryScript} --print-inventory | tr ' ' '\n' | sort -u)
              nix_list=$(printf '%s\n' ${pkgs.lib.escapeShellArgs requiredInventory} | sort -u)
              if [ "$script_list" != "$nix_list" ]; then
                echo "scripts/dx-verify-inventory.sh's DX_REQUIRED_INVENTORY has drifted from flake.nix's requiredInventory:" >&2
                diff <(printf '%s\n' "$script_list") <(printf '%s\n' "$nix_list") >&2 || true
                exit 1
              fi
              touch $out
            '';

            # WP7.4 (docs/reviews/2026-09-29-fable.md finding C4): the
            # behavioural proof that programs.starship / programs.direnv /
            # programs.yazi actually wire up per shell -- built, not just
            # evaluated, over the SAME home-files this flake ships (not a
            # hand-written fixture), copied into a throwaway $HOME. Function
            # names below were confirmed against the actual generated
            # ~/.bashrc, fish functions and nushell config.nu on this pin
            # (`nix build .#checks.aarch64-linux.home-files` and grep), not
            # guessed: bash's yazi wrapper is a top-level `function y()`,
            # fish's direnv hook function is `__direnv_export_eval`, and
            # nushell's yazi wrapper is `def --env y` in config.nu (not
            # env.nu). $STARSHIP_SHELL is set at *runtime* by `starship
            # init`, so it is not visible by grepping the static rc files --
            # only running the shell proves it.
            bash-integration = pkgs.runCommand "bash-integration"
              {
                nativeBuildInputs = [ pkgs.bashInteractive pkgs.direnv pkgs.starship pkgs.yazi ];
                homeFiles = homeConfiguration.config.home-files;
              } ''
              set -euo pipefail
              export HOME=$(mktemp -d)
              cp -r "$homeFiles"/. "$HOME/"
              chmod -R u+w "$HOME"
              bash -ic 'declare -F y >/dev/null && [ "$STARSHIP_SHELL" = bash ]'
              touch $out
            '';

            fish-integration = pkgs.runCommand "fish-integration"
              {
                nativeBuildInputs = [ pkgs.fish pkgs.direnv pkgs.starship pkgs.yazi ];
                homeFiles = homeConfiguration.config.home-files;
              } ''
              set -euo pipefail
              export HOME=$(mktemp -d)
              cp -r "$homeFiles"/. "$HOME/"
              chmod -R u+w "$HOME"
              fish -i -c 'functions -q y; and functions -q __direnv_export_eval; and test "$STARSHIP_SHELL" = fish'
              touch $out
            '';

            # nu -c (unlike `bash -i -c`/`fish -i -c` above) does not load
            # env.nu/config.nu on its own -- confirmed by running it without
            # the two flags below: y_defined/starship_ok/direnv_wired were
            # all false. --env-config/--config make it read the same files
            # an interactive session would.
            nushell-integration = pkgs.runCommand "nushell-integration"
              {
                nativeBuildInputs = [ pkgs.nushell pkgs.direnv pkgs.starship pkgs.yazi ];
                homeFiles = homeConfiguration.config.home-files;
              } ''
              set -euo pipefail
              export HOME=$(mktemp -d)
              cp -r "$homeFiles"/. "$HOME/"
              chmod -R u+w "$HOME"
              nu --env-config "$HOME/.config/nushell/env.nu" --config "$HOME/.config/nushell/config.nu" -c '
                let y_defined = ((scope commands | where name == "y" | length) > 0)
                let starship_ok = ($env.STARSHIP_SHELL? == "nu")
                let direnv_wired = (($env.config.hooks.pre_prompt? | default []) | length) > 0
                print $"y_defined=($y_defined) starship_ok=($starship_ok) direnv_wired=($direnv_wired)"
                if $y_defined and $starship_ok and $direnv_wired { exit 0 } else { exit 1 }
              '
              touch $out
            '';

            # WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): every
            # installed guest command used to be a plain `home.file` copy of
            # a script whose PATH resolution depended on whatever happened
            # to be ambient at invocation time -- fragile exactly when a
            # caller supplies a minimal PATH (tmux's `run-shell -b`, a Tinty
            # hook). `pkgs.writeShellApplication`'s `runtimeInputs` bakes an
            # absolute PATH prefix into the script itself, so its real
            # dependencies resolve no matter what the caller's PATH is. This
            # check proves that for the two entry points whose PATH-fragility
            # was the concrete, previously-worked-around symptom
            # (dx-theme-write-tool-themes.sh's now-deleted `ensure_tinty_on_path`
            # hand rolled probe): running them with PATH=/var/empty must
            # neither fail nor print a "command not found" diagnostic.
            scripts-hermetic = pkgs.runCommand "scripts-hermetic"
              { homeFiles = homeConfiguration.config.home-files; } ''
              set -euo pipefail
              export HOME=$(mktemp -d)
              mkdir -p "$HOME/.config/dx"
              printf '%s\n' base16-mocha > "$HOME/.config/dx/theme-current"

              assert_clean() {
                local label="$1"; shift
                local result rc=0
                result="$(HOME="$HOME" PATH=/var/empty "$@" 2>&1)" || rc=$?
                if [ "$rc" -ne 0 ]; then
                  echo "$label exited $rc under an isolated PATH:" >&2
                  printf '%s\n' "$result" >&2
                  exit 1
                fi
                case "$result" in
                  *"not found"*)
                    echo "$label leaked an ambient-PATH dependency:" >&2
                    printf '%s\n' "$result" >&2
                    exit 1
                    ;;
                esac
              }

              assert_clean dx-theme-restore "$homeFiles/.local/bin/dx-theme-restore"

              theme_file="$HOME/incoming-theme.sh"
              printf '# theme\n' > "$theme_file"
              export TINTY_THEME_FILE_PATH="$theme_file"
              assert_clean dx-theme-copy-hook "$homeFiles/.local/bin/dx-theme-copy-hook" shell

              touch $out
            '';

            # WP7.7 (docs/reviews/2026-09-29-fable.md finding C7): NixVim's
            # own test harness launches a real, headless Neovim and fails
            # the build if it prints anything to stderr (nixvim's
            # modules/top-level/test.nix). `pre_hook` used to be set by a
            # raw second `require('Comment').setup(...)` call in the
            # now-deleted nvim/extra_plugins/ts-context-commentstring.nix,
            # which silently won over whatever `plugins.comment.enable`
            # alone produced; this proves the typed
            # `plugins.comment.settings.pre_hook` (nvim/plugins/comment.nix)
            # actually reaches the running config instead of a source-text
            # assertion that can't tell "set" from "set and then lost".
            # Only the two plugins under test are imported (not the whole
            # of nixvim.nix): several of the other plugins (project-nvim,
            # for one -- see its own comment) print unrelated startup
            # chatter to stderr under a from-scratch $HOME, which this
            # harness would otherwise misreport as a pre_hook regression.
            nvim = nixvim.lib.${system}.check.mkTestDerivationFromNixvimModule {
              inherit pkgs;
              module = {
                imports = [
                  ./nvim/plugins/comment.nix
                  ./nvim/plugins/ts-context-commentstring.nix
                  ./nvim/plugins/treesitter.nix # ts-context-commentstring needs it to function
                ];
                extraConfigLua = ''
                  assert(require('Comment.config'):get().pre_hook, 'pre_hook lost')
                '';
              };
            };
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

      checks = nixpkgs.lib.mapAttrs (_: out: out.checks) perSystemOutputs;

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
