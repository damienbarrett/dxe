# WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): every installed guest
# command used to be a plain `home.file` copy with `#!/usr/bin/env bash`, so
# it depended on whatever PATH happened to be ambient at invocation time --
# fragile exactly when a caller supplies a minimal one (tmux's `run-shell -b`,
# a Tinty hook). `pkgs.writeShellApplication` bakes an absolute interpreter
# path AND an absolute PATH prefix (from `runtimeInputs`) into the built
# script, so it is self-sufficient regardless of the caller's environment --
# see checks.<system>.scripts-hermetic in flake.nix, which proves this for
# the two entry points whose PATH-fragility used to be worked around by hand
# (dx-theme-write-tool-themes.sh's now-deleted `ensure_tinty_on_path`).
#
# `scripts/*.sh` stays the source of truth and stays loadable raw: this only
# wraps the INSTALLED copy under ~/.local/bin. dx-ai.sh in particular must
# stay loadable straight off the bootstrap volume before any Home Manager
# generation exists (its own three-candidate library loader), so it is
# intentionally not part of this table -- it keeps its own plain `home.file`
# entry in tools.nix.
{ pkgs }:
name: file: runtimeInputs:
{ excludeShellChecks ? [ ] }:
pkgs.writeShellApplication {
  inherit name runtimeInputs excludeShellChecks;
  text = builtins.readFile file;
  # The scripts already carry their own `set -eo pipefail` / `set -euo
  # pipefail` line (deliberately not identical across all of them); keep
  # that the only place options are set rather than layering the wrapper's
  # own default `errexit nounset pipefail` on top.
  bashOptions = [ ];
}
