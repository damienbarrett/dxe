# NixOS 26.05 Upgrade Plan

## Reusable Release Upgrade Strategy

Use this section as the playbook for future NixOS release bumps, such as 26.05 -> 26.11. For each upgrade, define:

- `OLD_RELEASE`: the current NixOS release, for example `25.11`.
- `NEW_RELEASE`: the target NixOS release, for example `26.05`.
- `OLD_IMAGE`: the current image name, for example `dx-nixos-25.11`.
- `NEW_IMAGE`: the target image name, for example `dx-nixos-26.05`.
- `OLD_CONTEXT_DIR` and `NEW_CONTEXT_DIR`: the versioned container context paths under `container/`.

Principles:

- Treat the official base image as a hard gate. Do not start the release bump until `nixpkgs/nix-flakes:nixos-$NEW_RELEASE-aarch64-linux` exists and has a `linux/arm64` image. Do not substitute `latest`.
- Keep the stable flake inputs aligned: `nixpkgs`, `home-manager`, and `nixvim` should all move to the same target release together. Keep intentionally independent inputs, such as `nixpkgs-unstable` for optional AI tooling, on their documented track.
- Separate routine drift from the release jump. If desired, first do a same-release lockfile update on `OLD_RELEASE`; then do the branch bump to `NEW_RELEASE` in a separate commit so the lock diff has one cause.
- Keep image and context names versioned. This allows old and new images to coexist, makes rollback easier, and keeps upgrade state visible in `DX_IMAGE` and `DX_CONTEXT_DIR`.
- Validate the target release in an isolated profile before making it the default instance. Namespace `DX_CONTAINER_NAME`, `DX_IMAGE`, `DX_SSH_PORT`, `DX_NIX_VOLUME`, `DX_WORKSPACE_VOLUME`, `DX_BOOTSTRAP_VOLUME`, and SSH key paths so the new release cannot touch the current default instance.
- Prefer `git mv` for the context directory rename so history and rollback stay clean.
- Centralize versioned test paths in shared helpers before changing release strings. Future upgrades should mostly change helpers and release assertions, not repeated literal paths spread through tests.
- Prefer behavior tests against a live guest for runtime behavior. Keep static source assertions for pinning, safety invariants, and documentation, but validate shells, tools, theming, persistence, SSH, and optional AI installation inside a running profiled guest.
- Run stale-reference checks after the new lockfile is generated. Before lock regeneration, `flake.lock` is expected to still contain old release refs.
- Treat rollback as source-driven. The Home Manager-managed user environment comes from the synced flake payload and committed lockfile; switching only the base image does not roll packages back.
- Do not garbage-collect old Nix generations or delete the old image until the target release has passed runtime validation.

## Phase Overview

Use these phases for this upgrade and future release bumps:

0. **Preflight and baseline:** verify the target release artifacts exist, then prove the current release is green or document known pre-existing failures.
1. **Test harness cleanup on the old release:** make tests profile-aware and behavior-oriented while still running against the known-good current guest.
2. **Target release source/build:** apply the release bump in an isolated branch or worktree, regenerate the lockfile, and pass static, flake, and aarch64 build checks.
3. **Target release live validation:** launch the new release through an isolated profile with separate image, container, port, volumes, and keys; run the profile-aware full test suite there first.
4. **Compatibility fixes:** make any package, shell, editor, theming, persistence, or optional AI fixes discovered in the isolated target guest; rerun the same gates after each fix.
5. **Promote to default:** only after isolated validation passes, move the default `dx-host` workflow to the new release and keep the old image/volumes until default runtime validation passes.

## Summary

This plan describes how to update the repo from NixOS 25.11 to NixOS 26.05. It is intentionally documentation-only until the official 26.05 base container image is available.

The upgrade should wait for `nixpkgs/nix-flakes:nixos-26.05-aarch64-linux` to exist for `linux/arm64`. As of 2026-05-31, the 26.05 flake branches resolve, but Docker Hub does not expose that base image tag. Do not use `latest` as the release base for this migration.

References:

- NixOS 26.05 release notes: https://nixos.org/manual/nixos/stable/release-notes
- NixOS 26.05 release announcement: https://discourse.nixos.org/t/nixos-26-05-released/77930
- Home Manager 26.05 notes: https://raw.githubusercontent.com/nix-community/home-manager/release-26.05/docs/release-notes/rl-2605.md

## Implementation Changes

- Preflight gate:
  - Verify `nixpkgs/nix-flakes:nixos-26.05-aarch64-linux` exists and includes a `linux/arm64` image.
  - Verify these inputs resolve:
    - `github:nixos/nixpkgs/nixos-26.05`
    - `github:nix-community/nixvim/nixos-26.05`
    - `github:nix-community/home-manager/release-26.05`
  - If `home-manager/release-26.05` or `nixvim/nixos-26.05` is not published yet, wait by default. Temporary explicit rev pins are acceptable only for isolated exploration and must be removed before promotion; do not promote a mixed stable/unstable release combination.
- Rename the container context directory from `container/aarch64-darwin-apple-container-dx-nixos-25.11` to `container/aarch64-darwin-apple-container-dx-nixos-26.05`.
- Update `Containerfile` to:

  ```Dockerfile
  FROM nixpkgs/nix-flakes:nixos-26.05-aarch64-linux
  ```

- Update `flake.nix` inputs:
  - `nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";`
  - `nixvim.url = "github:nix-community/nixvim/nixos-26.05";`
  - `home-manager.url = "github:nix-community/home-manager/release-26.05";`
  - Leave `nixpkgs-unstable.url = "github:nixos/nixpkgs/master";` unchanged for the optional AI tools bundle.
- Regenerate the lockfile from the renamed container directory:

  ```bash
  nix flake update nixpkgs nixvim home-manager --flake container/aarch64-darwin-apple-container-dx-nixos-26.05
  ```

- Bump `home.stateVersion` from `25.11` to `26.05` after reviewing the Home Manager 26.05 state-version notes. This repo does not currently configure the listed GTK, zsh, xdg userDirs, Firefox, Hyprland, or Home Manager Yazi wrapper options directly.
- Update host defaults:
  - In `bin/dx-lib.sh`, update `DX_IMAGE`: `dx-nixos-25.11` -> `dx-nixos-26.05`.
  - In `bin/dx-lib.sh`, update `DX_CONTEXT_DIR`: the versioned 25.11 container path -> the versioned 26.05 container path.
- Update README defaults and links from `25.11` to `26.05`, including the `container/.../bootstrap.sh` Markdown link so it does not point at the renamed 25.11 directory.
- Update `tests/profiles/default.env` comments and active tests from `25.11` to `26.05`.
- Add `tests/profiles/nixos-2605.env` for isolated validation before promoting 26.05 to the default instance:

  ```bash
  export DX_CONTAINER_NAME=dx-2605
  export DX_IMAGE=dx-nixos-26.05
  export DX_SSH_PORT=2223
  export DX_NIX_VOLUME=dx-2605-nix
  export DX_WORKSPACE_VOLUME=dx-2605-workspace
  export DX_BOOTSTRAP_VOLUME=dx-2605-bootstrap
  export DX_SSH_KEY="$DX_PROJECT_ROOT/dx-2605_key"
  export DX_SSH_KEY_PUB="$DX_PROJECT_ROOT/dx-2605_key.pub"
  export DX_CONTEXT_DIR="${DX_2605_PROJECT_ROOT:-$DX_PROJECT_ROOT}/container/aarch64-darwin-apple-container-dx-nixos-26.05"
  ```

  Prefer running this from the 26.05 worktree with `./bin/dx-profile nixos-2605 ./bin/dx` and `./bin/dx-profile nixos-2605 ./bin/dx-ssh`. This lets the 26.05 container run alongside the default 25.11 instance because the port, image, volumes, and keys are isolated. If invoking `dx-profile` from a different checkout, that checkout must also contain `tests/profiles/nixos-2605.env`; set `DX_2605_PROJECT_ROOT` to the 26.05 worktree so the profile syncs the correct source.
- Centralize repeated test paths in `tests/test_helpers.sh` before updating release references:
  - Keep using the existing `CONTAINER_DIR`, `FLAKE_NIX`, and `NIXVIM_NIX` helpers.
  - Add `BOOTSTRAP="$CONTAINER_DIR/bootstrap.sh"`, `CONTAINERFILE="$CONTAINER_DIR/Containerfile"`, `FLAKE_LOCK="$CONTAINER_DIR/flake.lock"`, and `SHELL_NIX="$CONTAINER_DIR/home/shell.nix"`.
  - Replace repeated hard-coded `bootstrap.sh`, `Containerfile`, `flake.nix`, `flake.lock`, and `home/shell.nix` paths in active tests with those helpers.
  - Update `tests/test_section2_containerfile.sh` to use the shared `CONTAINERFILE`.
  - Update `tests/test_section3_bootstrap.sh` to use shared `BOOTSTRAP`, `FLAKE_NIX`, and `SHELL_NIX`; this is the only `SHELL_NIX` edit required for the directory rename because the current value is a literal 25.11 path.
  - Update `tests/test_section4_ssh.sh` to use the shared `BOOTSTRAP`.
  - Update `tests/test_section5_nix.sh` to use shared `FLAKE_NIX` and `FLAKE_LOCK`, use `CONTAINER_DIR` for `nix flake check`, assert `nixos-26.05`, and update the adjacent comment from `nixos-25.11` to `nixos-26.05`.
  - Update `tests/test_section6_tools.sh` so the tracked `dx-ai.sh` check uses the new container path rather than a literal 25.11 path.
  - Update `tests/test_section7_lazyvim.sh` to use the shared `FLAKE_NIX`.
  - Update `tests/test_section9_host_scripts.sh` to use the shared `BOOTSTRAP`.
  - Update `tests/test_section10_docs.sh` so the README default-image assertion expects `dx-nixos-26.05`.
  - Update `tests/test_section12_validate_linux.sh` to use shared `BOOTSTRAP` and `CONTAINER_DIR` instead of local `BOOTSTRAP` and `FLAKE_DIR` definitions.
  - Update `tests/test_section13_final_review.sh` to use shared `CONTAINERFILE`, `BOOTSTRAP`, and `FLAKE_LOCK`; remove the obsolete `todo.txt` verification block because `todo.txt` is no longer part of the repo and the current check can crash the suite under `set -e`.
  - As DRY cleanup, update the existing local `SHELL_NIX` definitions in sections 6, 15, and 16 to use the shared helper. Leave section 14's `HOME_SHELL_NIX="$CONTAINER_DIR/home/shell.nix"` unchanged because it already tracks the renamed directory and is part of that file's local `HOME_*` path family.
- Make live guest tests profile-aware so the same behavior tests can run against either the default 25.11 instance or the isolated 26.05 instance:
  - Update `tests/test_helpers.sh` so `requires_container` checks `DX_CONTAINER_NAME`, `wait_for_ssh` probes `DX_SSH_PORT`, and guest helpers route through `bin/dx-ssh` or `container exec "$DX_CONTAINER_NAME"`.
  - Update direct live-test literals in sections 11 and 14 so container existence checks and `container exec` calls use the active `DX_*` profile values.
  - Sections 15, 16, and 17 should become profile-aware through the shared helper changes; avoid unnecessary per-file churn there unless a live assertion still bypasses the helpers.
  - Leave static `dx-host` references in sections 1, 9, and 10 unchanged where they assert ignore patterns, comments, or documented default values rather than live runtime state.
  - Keep literal guest SSH port `2222` checks only where they assert the in-container sshd configuration or host port forwarding contract.
  - Where a runtime behavior can be tested directly in the guest, prefer that over adding or extending grep-only assertions.
  - Add concrete live behavior targets where they reduce upgrade risk:
    - Section 4 SSH: prove key auth works and password-only auth is refused against the live guest, while keeping source assertions for sshd port `2222` and host forwarding.
    - Section 5 Nix/release identity: in the live guest, verify `/etc/os-release` reports the target base release and `/guest-bootstrap/flake.lock` points stable inputs at the target release.
    - Section 6 tools: execute representative tools in the guest (`nix --version`, `git --version`, `gh --version`, `tmux -V`, `yazi --version`, `lazygit --version`, `nvim --headless +q`) instead of relying only on source package-list assertions.
    - Sections 7 and 8 NixVim: keep structural config checks, but also validate the built `nvim` starts headlessly inside the live guest.
    - Section 14 theming, section 15 Nushell, section 16 persistence, and section 17 `dx-ai`: keep these as live behavior tests and make them profile-aware.
- Leave historical `plan-*.md` references alone unless a separate cleanup is requested.

## Public Interfaces

- CLI command names and flags should not change.
- SSH defaults, volume defaults, bootstrap paths, and lifecycle script behavior should not change.
- The public default image name changes to `dx-nixos-26.05`.
- The public default container context path changes to the renamed 26.05 directory.
- Existing 25.11 images and containers may remain on a user's machine until manually destroyed.

## Phased Execution & Gates

Do not treat this as "OS first, apps later" in the traditional distro sense. The
Home Manager-managed guest environment is flake-driven, which means package rollback is
source/lock driven rather than base-image driven. For the release bump itself, move the
base image, stable `nixpkgs` branch, Home Manager, NixVim, and default tool packages
together by choice so the repo does not ship a transient mixed-release combination.
Phase the work by risk and validation surface:

0. **Phase 0 — preflight and baseline.**
   - Confirm the target Docker image tag and release branches exist.
   - On the current 25.11 checkout, run `tests/run_all_tests.sh --skip-integration` and any available live tests against the existing `dx-host`.
   - Gate: no known baseline failures except explicitly documented pre-existing failures being fixed in Phase 1.

1. **Phase 1 — test harness cleanup, still on 25.11.**
   - Centralize test paths, remove the obsolete `todo.txt` check, and make live tests profile-aware.
   - Convert or extend tests toward live guest behavior where appropriate: SSH, Home Manager activation, shells, tmux, NixVim, Yazi, theming, workspace persistence, and optional AI tooling should be exercised in a running guest rather than only by grepping source.
   - Gate: `tests/run_all_tests.sh --skip-integration` passes; live tests pass against the current 25.11 instance when Apple Container is available.

2. **Phase 2 — isolated 26.05 source and build.**
   - In a branch or separate `git worktree`, apply the 26.05 context rename, flake input updates, lockfile regeneration, `stateVersion` review/bump, profile addition, docs, and release-string test updates.
   - If doing the optional same-release lockfile drift refresh, complete and validate that before this phase as described in the Staging section.
   - Gate: stale-reference grep passes after lock regeneration; `nix flake check --no-write-lock-file` passes; the aarch64 build check passes on an aarch64 host or builder.

3. **Phase 3 — isolated 26.05 live guest validation.**
   - Launch `tests/profiles/nixos-2605.env` with unique image, container, port, volumes, and keys.
   - Run the profile-aware full test suite against the isolated 26.05 guest before touching the default instance:

     ```bash
     # Preferred: run from the 26.05 worktree.
     # If invoking from another checkout that also has tests/profiles/nixos-2605.env:
     #   export DX_2605_PROJECT_ROOT=/path/to/dxe-2605-worktree
     ./bin/dx-profile nixos-2605 ./bin/dx
     ./bin/dx-profile nixos-2605 tests/run_all_tests.sh
     ```

   - Gate: all non-skipped tests pass against the isolated 26.05 guest. Any skipped test must have a clear host-capability reason, not a release failure.
   - Rollback gate: before promotion, run a rollback smoke test in a disposable profiled instance that has an actual 25.11 generation. The cleanest path is to launch the disposable profile once from 25.11 source with its own volumes, repoint that same profile/source to 26.05, activate the upgrade, then switch the Home Manager profile back with `nix-env --rollback -p ~/.local/state/nix/profiles/home-manager` and run its `activate`. Confirm the rollback changes the guest as expected, then re-activate 26.05 and rerun smoke tests. Also rehearse source revert + `dx-recreate` in that disposable profile and confirm the guest returns to the 25.11 source and runtime baseline.

4. **Phase 4 — compatibility fixes on 26.05, if needed.**
   - Make targeted fixes for package, NixVim, shell, theming, persistence, or optional AI behavior discovered in Phase 3.
   - Keep these commits separate from the raw release bump where practical.
   - Gate: repeat Phase 2 static/build checks and Phase 3 live guest tests after each fix commit.

5. **Phase 5 — promote to default.**
   - Only after the isolated 26.05 instance passes, update or merge the default branch/worktree so `dx-host` uses 26.05 defaults.
   - Keep the 25.11 image and volumes available until the default 26.05 instance has passed runtime validation.
   - Gate: `tests/run_all_tests.sh --skip-integration` and the full Apple Container suite pass against the promoted default instance.

## Staging & Rollback

Rollback is **source-driven**: the Home Manager-managed user environment comes from the
flake payload, not the base image. `bootstrap.sh` activates the environment with
`nix run /guest-bootstrap#homeConfigurations.dx.activationPackage`, and that payload is
re-synced from the source tree on every recreate. So the unit of rollback is the
committed source (`flake.nix` + `flake.lock`), which reproduces the old environment
bit-for-bit. `dx-recreate` preserves `/nix` and `/workspace`, so a rollback never touches
user data. Note: pointing `DX_IMAGE` at the old base image does **not** roll back
packages on its own — with a 26.05 source tree it would just rebuild 26.05 packages on a
25.11 base layer.

### Staging (separate the package jump from routine drift)

- A channel bump always rewrites `flake.lock`, because the lock pins revisions on a
  specific branch; moving from `nixos-25.11` to `nixos-26.05` is the package jump. It
  cannot be done without a lock update.
- To keep each lock diff single-cause, split the work into separate commits:
  1. (Optional, on 25.11) A routine `nix flake update` to absorb current within-channel
     drift, tested on its own.
  2. The channel bump (URLs → 26.05, base image, `nix flake update nixpkgs nixvim
     home-manager`, `stateVersion`). This commit's lock diff then represents only the
     25.11 → 26.05 jump.
- Use `git mv` for the directory rename so the bump lands as one revertible commit.
- Keep the stable set (`nixpkgs`, `home-manager`, `nixvim`) on the same release; do not
  mix releases across these three. `nixpkgs-unstable` is a separate axis and stays on
  `master`.

### Parallel validation instance

- Validate 26.05 in `tests/profiles/nixos-2605.env` before switching the default
  `dx-host` instance. Run `./bin/dx-profile nixos-2605 ./bin/dx` from the 26.05 source
  tree to build and launch the isolated instance.
- Keep every stateful resource unique in the profile. In particular, never mount the
  default `dx-nix`, `dx-workspace`, or `dx-bootstrap` volumes into the 26.05 validation
  container while 25.11 may still use them. Concurrent containers must not share named
  volume images.
- The isolated 26.05 store starts empty and will repopulate `/nix` on first bootstrap.
  If avoiding that cost matters, stop both instances and copy the old Apple Container
  volume image to the new `dx-2605-nix` volume before first launch; this is optional and
  should be done only while neither volume is mounted.
- For source isolation, use a `git worktree` or dedicated branch checkout for the 26.05
  bump. Prefer invoking `dx-profile` from that 26.05 worktree. If invoking from another
  checkout instead, that checkout must also contain `tests/profiles/nixos-2605.env`; set
  `DX_2605_PROJECT_ROOT` so `DX_CONTEXT_DIR` points at the 26.05 source while the default
  25.11 checkout can continue running unchanged.

### Rollback

- **Primary — source revert + rebuild.** `git revert <channel-bump-sha>` (or check out
  the pre-bump commit, or run from a `git worktree`) restores `flake.nix`, `flake.lock`,
  `Containerfile`, the `dx-lib.sh` defaults, `home.nix` `stateVersion`, and the renamed
  directory in one step. The committed `flake.lock` makes this reproducible. Only once
  the source tree is back on 25.11 — so `DX_IMAGE`/`DX_CONTEXT_DIR` resolve to the 25.11
  values again and the 25.11 context directory exists — run `dx-recreate` to rebuild.
  `/nix` and `/workspace` are preserved.
- **Fast, no-rebuild (if `/nix` was not GC'd) — generation rollback.** The previous Home
  Manager generation persists in `/nix`, so the environment can be rolled back inside the
  guest without rebuilding. The `home-manager` CLI is **not** installed (activation is via
  `nix run …#activationPackage`), so roll back through the Home Manager profile rather
  than `home-manager generations`. The profile is `~/.local/state/nix/profiles/home-manager`
  and `nix-env` ships with the installed `nix` (both validated on a running 25.11 guest):

  ```bash
  PROFILE=~/.local/state/nix/profiles/home-manager
  nix-env --list-generations -p "$PROFILE"      # pick the pre-upgrade generation
  nix-env --rollback -p "$PROFILE"              # or: --switch-generation N
  "$PROFILE"/activate                            # apply it (each generation ships an activate script)
  ```

### Rollback gotchas

- **`dx-recreate` deletes the image for the *current* `DX_IMAGE`** (`dx-destroy` →
  `dx-destroy-image`) and then rebuilds from `DX_CONTEXT_DIR`. Never run it unless both
  `DX_IMAGE` and the source tree already point at the version you want — otherwise it
  removes the wrong image and/or rebuilds the wrong version. This is why source revert
  must come first.
- **Do not garbage-collect until 26.05 is verified.** `dx-gc` / `nix-collect-garbage`
  can prune the old 25.11 generations and store paths, which disables the generation
  rollback and forces a rebuild from the reverted lock.
- `/workspace` is never rolled back in either direction; hand-migrated data is not
  reversed.
- `stateVersion` reverts cleanly here because no configured service persists
  version-specific stateful data; the general no-auto-downgrade caution does not apply to
  this config.
- Optional belt-and-suspenders: snapshot the Apple Container named volume backing image
  for `DX_NIX_VOLUME` before the bump for a GC-independent instant restore.

## Test Plan

- Static checks after `flake.lock` regeneration:
  - Search active paths for stale release references after the `nix flake update` step has rewritten the lockfile:

    ```bash
    rg "25\\.11" README.md bin tests container
    ```

  - Confirm only intentional historical references remain.
  - Confirm active tests no longer redefine versioned `BOOTSTRAP`, `CONTAINERFILE`, `FLAKE_NIX`, or `FLAKE_LOCK` paths outside `test_helpers.sh`, and that local `SHELL_NIX` definitions in sections 3, 6, 15, and 16 have been removed.
  - Confirm `tests/test_section13_final_review.sh` no longer references `todo.txt`.
  - Run shell syntax checks on changed shell scripts.
  - Run the flake evaluation check:

    ```bash
    nix flake check --no-write-lock-file container/aarch64-darwin-apple-container-dx-nixos-26.05
    ```

- Aarch64 build check:
  - Run this on an `aarch64-linux` host or with an available aarch64 remote builder/emulation:

    ```bash
    nix build container/aarch64-darwin-apple-container-dx-nixos-26.05#packages.aarch64-linux.default --no-link
    ```

- Repo test suite:

  ```bash
  tests/run_all_tests.sh --skip-integration
  ```

- Runtime validation after the Docker tag exists:
  - Build and validate the isolated 26.05 instance first:

    ```bash
    # Preferred: run from the 26.05 worktree.
    # If invoking from another checkout that also has tests/profiles/nixos-2605.env:
    #   export DX_2605_PROJECT_ROOT=/path/to/dxe-2605-worktree
    ./bin/dx-profile nixos-2605 ./bin/dx
    ./bin/dx-profile nixos-2605 tests/run_all_tests.sh
    ```

  - Keep the default 25.11 instance available until this isolated 26.05 instance passes validation.
  - Optionally build an isolated lifecycle test image/container with the existing `dx-test` profile.
  - After promotion to the default instance, run the unprofiled full test suite on a host with Apple Container available:

    ```bash
    tests/run_all_tests.sh
    ```

  - Confirm SSH bootstrap, Home Manager activation, core tools, Neovim/NixVim, Yazi, tmux, theming, and optional `dx-ai` behavior still work.

## Assumptions

- The upgrade waits for the stable 26.05 `nixpkgs/nix-flakes` image tag and does not switch to `latest`.
- The target architecture remains `aarch64-linux` for Apple Container on Apple silicon hosts.
- The persistent Nix, workspace, and bootstrap volume model remains unchanged.
- `nixpkgs-unstable` stays on `master` because it is intentionally scoped to the optional AI tools bundle.
