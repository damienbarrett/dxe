# WP7.3 (docs/reviews/2026-09-29-fable.md finding C3, Muse B4): the single
# source of truth for "which nixpkgs attribute provides which user-facing
# command". flake.nix's dxPackages is generated from this mapping's keys
# (`dxPackages = map (n: pkgs.${n}) (lib.attrNames guestTools)`);
# checks.<system>.inventory and checks.<system>.inventory-list are generated
# from its values (plus the manual additions flake.nix layers on top -- see
# below), so a package that stops providing a command it used to, or a
# command that is installed but never verified, fails CI instead of only
# being discovered on a live guest boot.
#
# Values are the BINARY names the package must provide, not the nixpkgs
# attribute name -- several differ (ripgrep -> rg, go-task -> task, e2fsprogs
# -> mkfs.ext4/fsck.ext4, openssh -> ssh, ...). `[ ]` means "library/data
# only, no standalone user-facing command to verify" (cacert, nix-direnv,
# tzdata, bash-completion, and the low-level coreutils/gnused/gnugrep/
# findutils/procps/util-linux/btrfs-progs/e2fsprogs utilities, which are
# system plumbing rather than the interactive inventory this mapping tracks
# -- scripts/dx-verify-inventory.sh's own header explains the same
# exclusion).
#
# Deliberately absent from this mapping -- each is already installed a
# different way, and adding it here would reintroduce the exact
# `config.home.packages` duplication WP7.3 found and closed (proven with
# `nix eval .../config.home.packages`, mapped to pname/name, before the fix:
# tmux, git, man-db, fish and nushell each appeared twice):
#   - git, tmux              -- programs.git / programs.tmux (home/tools.nix)
#   - man-db                 -- Home Manager's own manual.manpages.enable
#                                default (true); this flake never sets it
#   - fish, nushell           -- programs.fish / programs.nushell
#                                (home/shell.nix)
#   - starship, direnv, yazi, lazygit
#                             -- programs.starship / programs.direnv /
#                                programs.yazi / programs.lazygit (WP7.4,
#                                home/shell.nix and home/tools.nix);
#                                nix-direnv.enable brings in nix-direnv
#                                itself, so that key is gone too
#   - nvim                    -- built by nixvim's makeNixvimWithModule, not
#                                a plain pkgs attribute
#   - nodejs                  -- kept as its own home.nix home.packages
#                                entry, deliberately outside the dx-tooling
#                                set ("Still keep nodejs for other tasks")
# Their commands are still verified: flake.nix's requiredInventory appends
# them by hand, next to this mapping, with the same reasoning.
{
  coreutils = [ ];
  gnused = [ ];
  gnugrep = [ ];
  findutils = [ ];
  procps = [ ];
  util-linux = [ ];
  btrfs-progs = [ ];
  e2fsprogs = [ ];
  less = [ "less" ];
  file = [ "file" ];
  gh = [ "gh" ];
  nix = [ "nix" ];
  openssh = [ "ssh" ];
  tinty = [ "tinty" ];
  ncurses = [ "tput" "clear" ];
  bash-completion = [ ];
  which = [ "which" ];
  ripgrep = [ "rg" ];
  fd = [ "fd" ];
  curl = [ "curl" ];
  cacert = [ ];
  jq = [ "jq" ];
  just = [ "just" ];
  go-task = [ "task" ];
  btop = [ "btop" ];
  fastfetch = [ "fastfetch" ];
  tzdata = [ ];
}
