# NixOS 26.05 Upgrade & Code-Review Fixes Plan

> **Scope.** This document covers two independent workstreams against the same repo:
>
> - **Part A — Release upgrade:** moving the dev container from NixOS 25.11 to 26.05 (the bulk of this plan).
> - **Part B — Code-review fixes:** eight standalone correctness/quality fixes (originally `plan-3.md`…`plan-10.md`; there were no `plan-1`/`plan-2`) against the *current* 25.11 codebase. They are independent of the version bump and are sequenced into **Phase 1** so they land before promotion.
>
> Every fix was re-verified against the working tree on 2026-06-04 and again on 2026-06-12 (file:line references below are current as of the latter). One (P3) is already implemented, one (P4) was dropped after external review, and the rest (P5–P10) remain open. See the [Codebase Assessment](#codebase-assessment-2026-06-04) for the full delta, including two inaccuracies found in the original fix files.

**Contents**

- **Part A — Release Upgrade:** [Strategy](#reusable-release-upgrade-strategy) · [Phases & Gates](#phases--gates) · [Summary](#summary) · [Implementation Changes](#implementation-changes) · [Test Harness Changes](#test-harness-changes) · [Public Interfaces](#public-interfaces) · [Staging & Rollback](#staging--rollback) · [Command Reference](#command-reference) · [Assumptions](#assumptions)
- **Part B — Code-Review Fixes:** [Consolidated Code-Review Fixes](#consolidated-code-review-fixes)

# Part A — Release Upgrade

## Reusable Release Upgrade Strategy

Use this section as the playbook for future NixOS release bumps, such as 26.05 -> 26.11. For each upgrade, define:

- `OLD_RELEASE` / `NEW_RELEASE`: the current and target NixOS releases, for example `25.11` and `26.05`.
- `OLD_IMAGE` / `NEW_IMAGE`: the current and target image names, for example `dx-nixos-25.11` and `dx-nixos-26.05`.
- `OLD_CONTEXT_DIR` / `NEW_CONTEXT_DIR`: the versioned container context paths under `container/` (e.g. `container/aarch64-darwin-apple-container-dx-nixos-26.05`).

Principles:

- The base image is the official, digest-pinned `nixos/nix` image (see [nix-base-plan.md](nix-base-plan.md)); it is versioned by Nix release, not NixOS release, so it no longer gates the release bump on a third-party per-release tag. What still gates the bump: `NEW_RELEASE`'s flake input branches (`nixpkgs`, `home-manager`, `nixvim`) must exist and resolve, and the base-image alignment rule (README.md, "Release and Pin Maintenance") must be rechecked — a release bump can change which Nix image tag/digest is correct. Do not substitute `latest` for any pin.
- Keep the stable flake inputs aligned: `nixpkgs`, `home-manager`, and `nixvim` should all move to the same target release together. Keep intentionally independent inputs, such as `nixpkgs-unstable` for optional AI tooling, on their documented track.
- Separate routine drift from the release jump. If desired, first do a same-release lockfile update on `OLD_RELEASE`; then do the branch bump to `NEW_RELEASE` in a separate commit so the lock diff has one cause.
- Keep image and context names versioned. This allows old and new images to coexist, makes rollback easier, and keeps upgrade state visible in `DX_IMAGE` and `DX_CONTEXT_DIR`.
- Validate the target release in an isolated profile before making it the default instance. Namespace `DX_CONTAINER_NAME`, `DX_IMAGE`, `DX_SSH_PORT`, `DX_NIX_VOLUME`, `DX_PERSIST_VOLUME`, `DX_BOOTSTRAP_VOLUME`, and SSH key paths so the new release cannot touch the current default instance.
- Prefer `git mv` for the context directory rename so history and rollback stay clean.
- Centralize versioned test paths in shared helpers before changing release strings. Future upgrades should mostly change helpers and release assertions, not repeated literal paths spread through tests.
- Prefer behavior tests against a live guest for runtime behavior. Keep static source assertions for pinning, safety invariants, and documentation, but validate shells, tools, theming, persistence, SSH, and optional AI installation inside a running profiled guest.
- Run stale-reference checks after the new lockfile is generated. Before lock regeneration, `flake.lock` is expected to still contain old release refs.
- Treat rollback as source-driven. The Home Manager-managed user environment comes from the synced flake payload and committed lockfile; switching only the base image does not roll packages back. (Detail in [Staging & Rollback](#staging--rollback).)
- Do not garbage-collect old Nix generations or delete the old image until the target release has passed runtime validation.

## Phases & Gates

These phases apply to this upgrade and to future release bumps. Do not treat this as "OS first, apps later" in the traditional distro sense: the Home Manager-managed guest environment is flake-driven, so package rollback is source/lock driven rather than base-image driven. For the release bump itself, move the base image, stable `nixpkgs` branch, Home Manager, NixVim, and default tool packages together by choice so the repo never ships a transient mixed-release combination. Phase the work by risk and validation surface.

0. **Phase 0 — preflight and baseline.**
   - Confirm the target Docker image tag and release branches exist.
   - On the current 25.11 checkout, run `tests/run_all_tests.sh --skip-integration` and any available live tests against the existing `dx-host`.
   - **Gate:** no known baseline failures except explicitly documented pre-existing failures being fixed in Phase 1.

1. **Phase 1 — test harness cleanup, still on 25.11.**
   - Apply the [Test Harness Changes](#test-harness-changes): centralize test paths, remove the obsolete `todo.txt` check, and make live tests profile-aware. (Done and committed as of 2026-06-12 — shared path helpers exist in `tests/test_helpers.sh:23-27`, the `todo.txt` check is gone, `requires_container`/`wait_for_ssh` are profile-aware, and the runner help text now says `0-18`. Only the 26.05-specific release-string updates remain for Phase 2.) **Status (2026-07-04):** those release-string updates landed with the Phase 2 channel-bump commit below.
   - Convert or extend tests toward live guest behavior where appropriate: SSH, Home Manager activation, shells, tmux, NixVim, Yazi, theming, persist storage, and optional AI tooling should be exercised in a running guest rather than only by grepping source.
   - Land the open [Consolidated Code-Review Fixes](#consolidated-code-review-fixes) (P5–P10) here, since they fix current 25.11 code that carries forward into 26.05. P3 is already done; P4 was dropped after review.
   - **Gate:** `tests/run_all_tests.sh --skip-integration` passes; live tests pass against the current 25.11 instance when Apple Container is available.

2. **Phase 2 — isolated 26.05 source and build.**
   - In a branch or separate `git worktree`, apply the 26.05 context rename, flake input updates, lockfile regeneration, `stateVersion` review/bump, profile addition, docs, and release-string test updates (see [Implementation Changes](#implementation-changes)).
   - If doing the optional same-release lockfile drift refresh, complete and validate that before this phase as described in [Staging & Rollback](#staging--rollback).
   - **Gate:** stale-reference grep passes after lock regeneration; `nix flake check --no-write-lock-file` passes; the aarch64 build check passes on an aarch64 host or builder.
   - **Status (2026-07-04):** executed in a dedicated worktree — context rename, flake input bump (`nixpkgs`/`nixvim`/`home-manager` → the `26.05`/`release-26.05` branches), targeted lockfile regeneration, `home.stateVersion` bump, the base-image alignment-rule Containerfile bump (`nixos/nix` `2.31.5` → `2.34.7`, re-verified digest), host defaults, and the doc/test release-string sweep all landed in one channel-bump commit. A pre-existing-in-26.05 packaging break (`neofetch` removed from nixpkgs) was resolved by replacing the `neofetch` entry in `flake.nix:65` with its maintained successor `fastfetch` (version 2.63.1 verified available at locked 26.05 revs); `nix flake check` now passes at the locked 26.05 revs. Phase 3 (isolated live-guest validation) has not been run yet.

3. **Phase 3 — isolated 26.05 live guest validation.**
   - Launch and exercise the isolated `nixos-2605` instance with unique image, container, port, volumes, and keys, then run the profile-aware full suite against it **before** touching the default instance. Commands: see [Parallel validation instance](#parallel-validation-instance).
   - **Gate:** all non-skipped tests pass against the isolated 26.05 guest. Any skipped test must have a clear host-capability reason, not a release failure.
   - **Rollback gate:** before promotion, run a rollback smoke test in a disposable profiled instance that has an actual 25.11 generation. The cleanest path is to launch the disposable profile once from 25.11 source with its own volumes, repoint that same profile/source to 26.05, activate the upgrade, then switch the Home Manager profile back with `nix-env --rollback -p ~/.local/state/nix/profiles/home-manager` and run its `activate`. Confirm the rollback changes the guest as expected, then re-activate 26.05 and rerun smoke tests. Also rehearse source revert + `dx-recreate` in that disposable profile and confirm the guest returns to the 25.11 source and runtime baseline.

4. **Phase 4 — compatibility fixes on 26.05, if needed.**
   - Make targeted fixes for package, NixVim, shell, theming, persistence, or optional AI behavior discovered in Phase 3.
   - Keep these commits separate from the raw release bump where practical.
   - **Gate:** repeat the Phase 2 static/build checks and Phase 3 live guest tests after each fix commit.

5. **Phase 5 — promote to default.**
   - Only after the isolated 26.05 instance passes, update or merge the default branch/worktree so `dx-host` uses 26.05 defaults.
   - Keep the 25.11 image and volumes available until the default 26.05 instance has passed runtime validation.
   - **Gate:** `tests/run_all_tests.sh --skip-integration` and the full Apple Container suite pass against the promoted default instance.

## Summary

This plan describes how to update the repo from NixOS 25.11 to NixOS 26.05. It is intentionally documentation-only until the target release's flake inputs are available.

**Superseded gate (2026-07-04):** this plan previously waited on a third-party, per-release Docker Hub tag before the release bump could start. [nix-base-plan.md](nix-base-plan.md) replaced the base image outright with the official, digest-pinned `nixos/nix` image, which is versioned by Nix release rather than NixOS release — that availability gate is **gone**. As of 2026-05-31, the 26.05 flake branches (`nixpkgs`, `home-manager`, `nixvim`) resolve; the remaining preflight gate is simply that those branches exist and resolve (see [Implementation Changes](#implementation-changes)) plus a recheck of the base-image alignment rule, since a release bump can change the correct Nix image tag. Do not use `latest` for any pin in this migration.

References:

- NixOS 26.05 release notes: https://nixos.org/manual/nixos/stable/release-notes
- NixOS 26.05 release announcement: https://discourse.nixos.org/t/nixos-26-05-released/77930
- Home Manager 26.05 notes: https://raw.githubusercontent.com/nix-community/home-manager/release-26.05/docs/release-notes/rl-2605.md

## Implementation Changes

- Preflight gate:
  - Verify these inputs resolve:
    - `github:nixos/nixpkgs/nixos-26.05`
    - `github:nix-community/nixvim/nixos-26.05`
    - `github:nix-community/home-manager/release-26.05`
  - If `home-manager/release-26.05` or `nixvim/nixos-26.05` is not published yet, wait by default. Temporary explicit rev pins are acceptable only for isolated exploration and must be removed before promotion; do not promote a mixed stable/unstable release combination.
  - Recheck the base-image alignment rule (README.md, "Release and Pin Maintenance"): confirm the currently pinned Nix image tag still matches the major.minor of `NEW_RELEASE`'s default Nix (`nixpkgs#nix.version` at the newly locked revision). If not, that is a separate, procedure-gated Nix-image-pin bump (see the same README section) — do not fold an undeclared base-image change into the release bump.
- Rename the container context directory from `container/aarch64-darwin-apple-container-dx-nixos-25.11` to `container/aarch64-darwin-apple-container-dx-nixos-26.05` (use `git mv`).
- The `Containerfile` itself does **not** change for a release bump by default — the base image is release-agnostic (see [nix-base-plan.md](nix-base-plan.md)). Only touch it if the alignment-rule recheck above calls for a new Nix image tag/digest, and treat that as the same procedure-gated Nix-image-pin bump documented in README.md, not an implicit part of this rename.

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
- Update host defaults in `bin/dx-lib.sh`:
  - `DX_IMAGE`: `dx-nixos-25.11` -> `dx-nixos-26.05`.
  - `DX_CONTEXT_DIR`: the versioned 25.11 container path -> the versioned 26.05 container path.
- Update README defaults and links from `25.11` to `26.05`, including the `container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh` Markdown link so it does not point at the renamed 25.11 directory.
- Update `tests/profiles/default.env` comments and active tests from `25.11` to `26.05`.
- Add `tests/profiles/nixos-2605.env` for isolated validation before promoting 26.05 to the default instance:

  ```bash
  export DX_CONTAINER_NAME=dx-2605
  export DX_IMAGE=dx-nixos-26.05
  export DX_EXPECTED_NIXOS_RELEASE=26.05      # else test_helpers.sh:28 defaults these to 25.11
  export DX_EXPECTED_NIXOS_BRANCH=nixos-26.05
  export DX_SSH_PORT=2223
  export DX_NIX_VOLUME=dx-2605-nix
  export DX_PERSIST_VOLUME=dx-2605-persist
  export DX_BOOTSTRAP_VOLUME=dx-2605-bootstrap
  export DX_SSH_KEY="$DX_PROJECT_ROOT/dx-2605_key"
  export DX_SSH_KEY_PUB="$DX_PROJECT_ROOT/dx-2605_key.pub"
  export DX_CONTEXT_DIR="${DX_2605_PROJECT_ROOT:-$DX_PROJECT_ROOT}/container/aarch64-darwin-apple-container-dx-nixos-26.05"
  ```

  Port, image, volumes, and keys are isolated so this container can run alongside the default 25.11 instance. The `DX_EXPECTED_NIXOS_*` exports are required, not cosmetic: `tests/test_helpers.sh:28-29` defaults them to `25.11`/`nixos-25.11`, so without overrides the section 5 release-identity checks (`test_section5_nix.sh:38,58,64`) would assert 25.11 against the 26.05 guest. For how to invoke the profile (and the `DX_2605_PROJECT_ROOT` worktree rule), see [Parallel validation instance](#parallel-validation-instance) — the single canonical recipe.
- Update the test suite for the rename and for live-guest behavior — see [Test Harness Changes](#test-harness-changes).

## Test Harness Changes

These are the Phase 1 edits to the test suite. New assertions should use the shared path helpers (below) rather than re-deriving literal paths.

**Status 2026-06-12:** the path centralization, `todo.txt` removal, profile-aware live helpers, and runner help-text fix are implemented and committed. The lists below are retained as the spec for the release-string parts (asserting `nixos-26.05`, `dx-nixos-26.05`, etc.), which can only land with the Phase 2 rename. **Status (2026-07-04):** the Phase 2 rename and release-string updates below have now landed in the channel-bump commit.

**Centralize repeated test paths in `tests/test_helpers.sh` before updating release references:**

- Keep using the existing `CONTAINER_DIR`, `FLAKE_NIX`, and `NIXVIM_NIX` helpers.
- Add `BOOTSTRAP="$CONTAINER_DIR/bootstrap.sh"`, `CONTAINERFILE="$CONTAINER_DIR/Containerfile"`, `FLAKE_LOCK="$CONTAINER_DIR/flake.lock"`, and `SHELL_NIX="$CONTAINER_DIR/home/shell.nix"`.
- Replace repeated hard-coded `bootstrap.sh`, `Containerfile`, `flake.nix`, `flake.lock`, and `home/shell.nix` paths in active tests with those helpers:
  - `test_section2_containerfile.sh` → shared `CONTAINERFILE`.
  - `test_section3_bootstrap.sh` → shared `BOOTSTRAP`, `FLAKE_NIX`, `SHELL_NIX` (the only `SHELL_NIX` edit required for the rename, since the current value is a literal 25.11 path).
  - `test_section4_ssh.sh` → shared `BOOTSTRAP`.
  - `test_section5_nix.sh` → shared `FLAKE_NIX` and `FLAKE_LOCK`; use `CONTAINER_DIR` for `nix flake check`; assert `nixos-26.05`; update the adjacent comment from `nixos-25.11` to `nixos-26.05`.
  - `test_section6_tools.sh` → the tracked `dx-ai.sh` check uses the new container path, not a literal 25.11 path.
  - `test_section7_lazyvim.sh` → shared `FLAKE_NIX`.
  - `test_section9_host_scripts.sh` → shared `BOOTSTRAP`.
  - `test_section10_docs.sh` → README default-image assertion expects `dx-nixos-26.05`.
  - `test_section12_validate_linux.sh` → shared `BOOTSTRAP` and `CONTAINER_DIR` instead of local `BOOTSTRAP` / `FLAKE_DIR` definitions.
  - `test_section13_final_review.sh` → shared `CONTAINERFILE`, `BOOTSTRAP`, `FLAKE_LOCK`; remove the obsolete `todo.txt` verification block (`todo.txt` is no longer in the repo and the current check can crash the suite under `set -e`).
- As DRY cleanup, update the existing local `SHELL_NIX` definitions in sections 6, 15, and 16 to use the shared helper. Leave section 14's `HOME_SHELL_NIX="$CONTAINER_DIR/home/shell.nix"` unchanged because it already tracks the renamed directory and is part of that file's local `HOME_*` path family.

**Make live guest tests profile-aware** so the same behavior tests run against either the default 25.11 instance or the isolated 26.05 instance:

- Update `tests/test_helpers.sh` so `requires_container` checks `DX_CONTAINER_NAME`, `wait_for_ssh` probes `DX_SSH_PORT`, and guest helpers route through `bin/dx-ssh` or `container exec "$DX_CONTAINER_NAME"`.
- Update direct live-test literals in sections 11 and 14 so container existence checks and `container exec` calls use the active `DX_*` profile values.
- Sections 15, 16, and 17 should become profile-aware through the shared helper changes; avoid unnecessary per-file churn there unless a live assertion still bypasses the helpers.
- Leave static `dx-host` references in sections 1, 9, and 10 unchanged where they assert ignore patterns, comments, or documented default values rather than live runtime state.
- Keep literal guest SSH port `2222` checks only where they assert the in-container sshd configuration or host port forwarding contract.
- Where a runtime behavior can be tested directly in the guest, prefer that over adding or extending grep-only assertions.

**Add concrete live behavior targets where they reduce upgrade risk:**

- Section 4 SSH: prove key auth works and password-only auth is refused against the live guest, while keeping source assertions for sshd port `2222` and host forwarding.
- Section 5 Nix/release identity: in the live guest, verify the base release identity and that `/guest-bootstrap/flake.lock` points stable inputs at the target release. **Caveat (found during the 2026-06 workspace-persist closeout):** the live guest has no `/etc/os-release`, so the existing section-5 live release-identity assertion cannot pass against a real guest; the live check needs a different source of truth (e.g. `flake.lock` inputs or a `nix eval` of the pinned release) or the guest needs an os-release file written during bootstrap.
- Section 6 tools: execute representative tools in the guest (`nix --version`, `git --version`, `gh --version`, `tmux -V`, `yazi --version`, `lazygit --version`, `nvim --headless +q`) instead of relying only on source package-list assertions.
- Sections 7 and 8 NixVim: keep structural config checks, but also validate the built `nvim` starts headlessly inside the live guest.
- Section 14 theming, section 15 Nushell, section 16 persistence, and section 17 `dx-ai`: keep these as live behavior tests and make them profile-aware.

**Clarify the runner surface (`tests/run_all_tests.sh`) — from the 2026-06-05 review:**

- `--skip-integration` only skips sections 11–12. Sections 13–17 still run; 14 (theming), 16 (persistence), and 17 (`dx-ai`) self-skip their *live* checks when no guest is present. So a phase gate that says "`--skip-integration` passes" means "static + self-skipping suite," not "zero live tests."
- ~~The `--help` text advertises `--section=N` as `0-16`, but section 17 exists and runs.~~ Fixed: the help text now says `0-18` and sections 17 (dx-ai runtime) and 18 (mount-git) are reachable.
- Section 13 (final review) fails on a dirty tracked worktree (`git -C … status -uno --short`, excluding `README.md`; `test_section13_final_review.sh:13`) and runs even under `--skip-integration`. During in-flight work, either scope around it (`--section`, or commit/stash first) or treat a section-13 dirty-tree failure as expected rather than a release regression. Consider splitting its in-flight checks from the final-only clean-tree check so mid-work runs are not blocked.

## Public Interfaces

- CLI command names and flags should not change.
- SSH defaults, volume defaults, bootstrap paths, and lifecycle script behavior should not change.
- The public default image name changes to `dx-nixos-26.05`.
- The public default container context path changes to the renamed 26.05 directory.
- Existing 25.11 images and containers may remain on a user's machine until manually destroyed.

## Staging & Rollback

Rollback is **source-driven**: the Home Manager-managed environment is reproduced from the committed source (`flake.nix` + `flake.lock`), which `bootstrap.sh` re-syncs and activates on every recreate, so pointing `DX_IMAGE` at the old base image does **not** roll packages back on its own. The mechanics are detailed under [Rollback](#rollback) below.

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

Validate 26.05 in `tests/profiles/nixos-2605.env` (defined in [Implementation Changes](#implementation-changes)) before switching the default `dx-host` instance. **Canonical invocation** — referenced from Phase 3 and the [Command Reference](#command-reference):

```bash
# Run from the 26.05 worktree. If invoking from another checkout that also has
# tests/profiles/nixos-2605.env, first point DX_2605_PROJECT_ROOT at the 26.05 worktree
# so the profile syncs the correct source:
#   export DX_2605_PROJECT_ROOT=/path/to/dxe-2605-worktree
./bin/dx-profile nixos-2605 ./bin/dx                  # build + launch the isolated instance
./bin/dx-profile nixos-2605 ./bin/dx-ssh              # shell into it
./bin/dx-profile nixos-2605 tests/run_all_tests.sh    # full profile-aware suite
```

Isolation rules for the profile:

- Keep every stateful resource unique. In particular, never mount the default `dx-nix`,
  `dx-persist`, or `dx-bootstrap` volumes into the 26.05 validation container while
  25.11 may still use them. Concurrent containers must not share named volume images.
- The isolated 26.05 store starts empty and will repopulate `/nix` on first bootstrap.
  If avoiding that cost matters, stop both instances and copy the old Apple Container
  volume image to the new `dx-2605-nix` volume before first launch; this is optional and
  should be done only while neither volume is mounted.
- For source isolation, use a `git worktree` or dedicated branch checkout for the 26.05
  bump, and prefer invoking `dx-profile` from that worktree. Invoking from another
  checkout requires that checkout to also contain `tests/profiles/nixos-2605.env` and the
  `DX_2605_PROJECT_ROOT` override above, so the default 25.11 checkout can keep running
  unchanged.

### Rollback

- **Primary — source revert + rebuild.** `git revert <channel-bump-sha>` (or check out
  the pre-bump commit, or run from a `git worktree`) restores `flake.nix`, `flake.lock`,
  `Containerfile`, the `dx-lib.sh` defaults, `home.nix` `stateVersion`, and the renamed
  directory in one step. The committed `flake.lock` makes this reproducible. Only once
  the source tree is back on 25.11 — so `DX_IMAGE`/`DX_CONTEXT_DIR` resolve to the 25.11
  values again and the 25.11 context directory exists — run `dx-recreate` to rebuild.
  `/nix` and `/persist` are preserved.
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
- `/persist` is never rolled back in either direction; hand-migrated data is not
  reversed.
- `stateVersion` reverts cleanly here because no configured service persists
  version-specific stateful data; the general no-auto-downgrade caution does not apply to
  this config.
- Optional belt-and-suspenders: snapshot the Apple Container named volume backing image
  for `DX_NIX_VOLUME` before the bump for a GC-independent instant restore.

## Command Reference

The commands each phase gate depends on. Phases own *when* to run them (see [Phases & Gates](#phases--gates)); this section is the *how*.

- **Stale-reference grep** (Phase 2 gate, after `flake.lock` regeneration):

  ```bash
  rg "25\\.11" README.md bin tests container   # only intentional historical refs should remain
  ```

  Also confirm no active test redefines versioned `BOOTSTRAP`, `CONTAINERFILE`, `FLAKE_NIX`, or `FLAKE_LOCK` outside `test_helpers.sh`; that local `SHELL_NIX` definitions in sections 3, 6, 15, and 16 are gone; and that `test_section13_final_review.sh` no longer references `todo.txt`. Run `bash -n` on changed shell scripts.

- **Base-image stale-reference grep** (this plan's own acceptance criterion, added by [nix-base-plan.md](nix-base-plan.md)'s doc sweep; re-run after any edit to this file):

  ```bash
  grep -rn 'nix-flakes' README.md plan.md mount-git.md tests bin container
  ```

  Any hit must be inside a design-history document (`flakes-to-nix.md`, or `nix-base-plan.md`'s own history/rollback sections) — never in this file, `README.md`, `mount-git.md`, or active test/bin/container sources. This file additionally must not reword the now-removed docker-nixpkgs release-tag availability gate as a live requirement anywhere (the base image is release-agnostic; see the Principles and Summary sections above).

- **Flake evaluation check** (Phase 2 gate):

  ```bash
  nix flake check --no-write-lock-file container/aarch64-darwin-apple-container-dx-nixos-26.05
  ```

- **Aarch64 build check** (Phase 2 gate; needs an `aarch64-linux` host or remote builder/emulation):

  ```bash
  nix build container/aarch64-darwin-apple-container-dx-nixos-26.05#packages.aarch64-linux.default --no-link
  ```

- **Repo test suite** (Phase 0/1/5 gates):

  ```bash
  tests/run_all_tests.sh --skip-integration
  ```

  `--skip-integration` skips only the Apple-Container integration sections 11–12; sections 13–17 still run (their live checks self-skip without a guest). Section 13 also enforces a clean tracked worktree, so run the full suite only after committing/stashing or scope it with `--section`. See [Test Harness Changes](#test-harness-changes).

- **Isolated runtime validation** (Phase 3 gate): build, launch, and test the `nixos-2605` instance using the canonical recipe in [Parallel validation instance](#parallel-validation-instance). Keep the default 25.11 instance available until this passes. Optionally build an isolated lifecycle test image/container with the existing `dx-test` profile.

- **Post-promotion full suite** (Phase 5 gate; host with Apple Container available):

  ```bash
  tests/run_all_tests.sh
  ```

  Then confirm SSH bootstrap, Home Manager activation, core tools, Neovim/NixVim, Yazi, tmux, theming, and optional `dx-ai` behavior still work.

## Assumptions

- The base image (official, digest-pinned `nixos/nix`) is decoupled from the NixOS release; the upgrade does not wait on a base-image tag (see [nix-base-plan.md](nix-base-plan.md)). It does still recheck the base-image alignment rule, and never switches to `latest`.
- The target architecture remains `aarch64-linux` for Apple Container on Apple silicon hosts.
- The persistent Nix, persist, and bootstrap volume model remains unchanged.
- `nixpkgs-unstable` stays on `master` because it is intentionally scoped to the optional AI tools bundle.

# Part B — Code-Review Fixes

## Consolidated Code-Review Fixes

These eight items came from a code review of the current `dx-nixos-25.11` codebase (originally `plan-3.md`…`plan-10.md`). They are folded into **Phase 1** because they fix code that exists today and carries forward unchanged into 26.05. All file/line references were re-verified against the working tree on 2026-06-04. Paths shown as `…/` are under the active container context dir, `container/aarch64-darwin-apple-container-dx-nixos-25.11/`. New test assertions should use the shared path helpers from [Test Harness Changes](#test-harness-changes) (`$BOOTSTRAP`, `$CONTAINERFILE`, `$FLAKE_NIX`, `$FLAKE_LOCK`, `$SHELL_NIX`) rather than re-deriving literal paths.

**Decisions (2026-06-04; updated 2026-06-05 after external review):**

- **Delivery — deferred.** Kept as plan only for now; whether to ship P5–P10 as a standalone PR on 25.11 or bundle them into the 26.05 upgrade is decided later. No implementation yet.
- **P4 — dropped** after external review: the partial-hook-env "bug" is intentional race-avoidance behavior (see the P4 entry).
- **P10 — wire it through, canonical default `64G`** (Option A; alternatives recorded in the P10 entry).

| ID  | Fix | Primary file | Severity | Status (2026-06-04) |
|-----|-----|--------------|----------|---------------------|
| P3  | `dx-sync-bootstrap` post-loop ready guard + configurable wait timeout | `bin/dx-sync-bootstrap` | Medium-High | ✅ Already implemented — no action |
| P4  | ~~`load_palette` fall back to `tinty current` on partial hook env~~ | `…/scripts/dx-theme-write-tool-themes.sh:42` | Medium | ❌ Dropped — behavior is intentional (see entry) |
| P5  | `dx_get_host_timezone` returns `UTC` + warns instead of an empty string | `bin/dx-lib.sh:322` | Medium | ⛔ Open |
| P6  | `configure_timezone` resolves zoneinfo from the store and runs after tool verify | `…/bootstrap.sh:129` | Medium | ⛔ Open (step 3 corrected) |
| P7  | `setup_nix_volume` uses exact FSTYPE match, not substring grep | `…/bootstrap.sh:43` | Low | ⛔ Open |
| P8  | Remove dead `start_ssh` function | `…/bootstrap.sh:448` | Low | ⛔ Open |
| P9  | D-Bus address passed via environment, not interpolated into the command string | `…/bootstrap.sh:379` | Low | ⛔ Open (`dx-ai.sh` part already fixed) |
| P10 | Honour `DX_NIX_DISK_SIZE` (or remove it) and reconcile the 20G/64G mismatch | `bin/dx-lib.sh:40`, `…/bootstrap.sh:77` | Low | ⛔ Open |

### P3 — `dx-sync-bootstrap` post-loop guard

**Already implemented**, recorded only to close it out. `bin/dx-sync-bootstrap:44-50` re-runs the marker check after the wait loop and exits non-zero with `entrypoint never became ready after ${DX_BOOTSTRAP_WAIT_TIMEOUT}s` plus a `container logs` hint. The loop is driven by `DX_BOOTSTRAP_WAIT_TIMEOUT` (`bin/dx-lib.sh:29`, default 30, used at `dx-sync-bootstrap:35`). Both test assertions exist (`tests/test_section9_host_scripts.sh:96` for the timeout var, `:126` for the `never became ready` message). No further work; `plan-3.md` is obsolete.

### P4 — `load_palette` partial-env behavior (dropped after review)

**Re-evaluated and dropped.** `plan-4.md` treated the zero-arg `load_palette_from_env || return 0` path — silent exit with no write when the hook palette env is present but incomplete — as a bug, and proposed falling back to `tinty current`. The external review (2026-06-05) correctly flagged this as a conflict: that fallback is **deliberately** avoided. `tests/test_section14_tinty_theming.sh:256-257` asserts that partial hook env must *not* fall back to `tinty current`, because re-querying mid-switch reintroduces the switch-time race the script is built to avoid (design comment at `:197-211`; TOCTOU guard at `:211` and `:473-492`). Partial hook env is also not a real Tinty state — all 48 slots are set together — so the "stale theme files" concern does not arise in normal operation, and brief staleness is the intended race-free trade-off.

**No code change; the original `plan-4.md` fix is rejected.** If the silent partial-env exit were ever deemed worth surfacing, the only safe option is a `>&2` diagnostic that still neither writes nor re-queries `tinty current` — not currently warranted.

### P5 — `dx_get_host_timezone` empty result

`bin/dx-lib.sh:322-324` is still the one-liner `readlink /etc/localtime | sed 's#^.*/zoneinfo/##'`, which yields an empty string (silently baked into `HOST_TZ=`) when `/etc/localtime` is absent, a regular file, or lacks `zoneinfo/`. Fix: add a `systemsetup -gettimezone` fallback and an `/etc/timezone` fallback, then default to `UTC` with a stderr warning rather than empty. Add a use-site guard in `bin/dx-create-container` that warns if `HOST_TZ` is empty before `container create`. Tests: assert a non-empty return in `tests/test_section9_host_scripts.sh`; add a commented `HOST_TZ` doc line to `tests/profiles/default.env` (it currently has none). Related: P6.

### P6 — `configure_timezone` ordering / profile dependency

`…/bootstrap.sh:129-144` still asks the dx login shell for `TZDIR` (`run_as_dx 'printf %s "${TZDIR:-}"'` at `:133`) and is called at `bootstrap.sh:463` — after `configure_guest` but before `verify_guest_tools`. (It has since gained a `~/.nix-profile/share/zoneinfo` fallback when `TZDIR` comes back empty, which softens but does not remove the shell-init timing dependency; the store-direct primary lookup and the reorder are still open.) On a fresh boot the dx profile may not be fully settled, so `TZDIR` comes back empty and the guest silently stays UTC. Fix: resolve the zoneinfo directory directly, in order — nix store (`find /nix/store … zoneinfo | grep tzdata`) → `~/.nix-profile/share/zoneinfo/$HOST_TZ` → `run_as_dx TZDIR` as last resort — and move the call to **after** `verify_guest_tools` so the profile is proven available first.

**Correction to plan-6 step 3.** The original file said "ensure `tzdata` is in `home/tools.nix`." That is inaccurate: `tzdata` is already an unconditional entry in `flake.nix:67` (`dxPackages`), and `home/shell.nix` already exports `TZDIR=${pkgs.tzdata}/share/zoneinfo` (lines 127 and 146). The package is present — the bug is purely shell-init timing, which the store-direct lookup plus the reorder eliminate. So **drop** the "add to `tools.nix`" step and instead just assert `tzdata` stays in `flake.nix` `dxPackages`. Related: P5.

**Test update (required; from the 2026-06-05 review).** `tests/test_section3_bootstrap.sh:83` asserts `run_as_dx 'printf %s "${TZDIR:-}"'` as bootstrap's timezone lookup. Once P6 demotes that to a last-resort fallback (store-direct lookup becomes primary), update this assertion to check the new store-direct resolution; keep a softened TZDIR assertion only if the `run_as_dx TZDIR` fallback line is retained. The `shell.nix` TZDIR assertions at `:85,87` stay — they corroborate that `tzdata` is already wired. The sshd-ordering assertion at `:70-78` is unaffected by moving `configure_timezone` after `verify_guest_tools`.

### P7 — `setup_nix_volume` unanchored `findmnt`

`…/bootstrap.sh:43` still uses `findmnt -n -o TARGET,FSTYPE /nix | grep -q "$fs_type"`, an unanchored substring match. Recommended fix is an exact string compare, which also lets us warn on an unexpected existing type before re-formatting:

```bash
local current_fstype
current_fstype="$(findmnt -n -o FSTYPE /nix 2>/dev/null || true)"
if [ "$current_fstype" = "$fs_type" ]; then
    echo "/nix is already a $fs_type mount. Skipping setup."
    return 0
elif [ -n "$current_fstype" ]; then
    echo "Warning: /nix is mounted as $current_fstype, expected $fs_type; proceeding with re-format." >&2
fi
```

Test: `assert_file_not_contains "$BOOTSTRAP" 'grep -q "$fs_type"'` in the bootstrap section.

### P8 — dead `start_ssh`

`start_ssh()` is defined at `…/bootstrap.sh:448-453` and never called — the main section `exec`s sshd directly at `:467-468`. Fix: delete the function (the `exec "$SSHD_BIN" -D -e -p 2222` block is authoritative). Test: `assert_file_not_contains "$BOOTSTRAP" "^start_ssh()"` in `tests/test_section9_host_scripts.sh`; `bash -n bootstrap.sh` must still pass.

**Test update (required; from the 2026-06-05 review).** `tests/test_section3_bootstrap.sh:36-40` asserts bootstrap "checks if sshd is already running" via `grep -q 'sshd.*running\|pgrep.*sshd\|ps.*sshd'`. That pattern matches *only* the dead `start_ssh` body (`pgrep -x sshd`), so deleting the function makes the assertion fail. Remove that test — the authoritative `exec sshd` entrypoint performs no pre-start running-check and needs none (sshd is the container's main process); the assertion currently validates dead behavior.

### P9 — D-Bus address quoting

`…/bootstrap.sh:379` interpolates the bus address into a `run_as_dx` command string (`DBUS_SESSION_BUS_ADDRESS='$bus_addr' echo -n '' | gnome-keyring-daemon …`), which `run_as_dx` then re-evaluates via `bash -l -c`. With an unexpected address (e.g. containing spaces) this splits mid-token and fails silently (`2>/dev/null`). Fix: pass the address through the environment — have `run_as_dx` forward `DBUS_SESSION_BUS_ADDRESS` — or `printf '%q'` it before interpolation; add a warning when `bus_addr` is empty. The `scripts/dx-ai.sh` half of this fix is **already done**: the agy persistence work rewrote its keyring block to validate the bus socket (`dbus_address_is_live`) and `export` the address rather than interpolating it into a command string. Only the `bootstrap.sh` site remains. `bash -n` after the change.

### P10 — `DX_NIX_DISK_SIZE` ignored + 20G/64G mismatch

`bin/dx-lib.sh:40` exports `DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"`, but `…/bootstrap.sh:77` hardcodes `truncate -s 64G`, and `bin/dx-create-container` (`CREATE_FLAGS`, from line 31) does **not** forward the variable into the container. So the variable is inert *and* its advertised default (20G) does not even match real behaviour (64G). **Chosen approach — Option A, wire it through** (decided 2026-06-04):

- Add `-e "DX_NIX_DISK_SIZE=$DX_NIX_DISK_SIZE"` to `CREATE_FLAGS` in `bin/dx-create-container`.
- In `setup_nix_volume`, replace `64G` with `"${DX_NIX_DISK_SIZE:-64G}"` (and reflect the size in the echo).
- **Reconcile the default to a single value:** set `dx-lib.sh` to `:-64G` so the documented default matches today's real allocation, and document `64G` in `tests/profiles/default.env`.
- `DX_NIX_DISK` (`dx-lib.sh:39`) remains unused in the normal flow; keep it only if `dx-nix-disk` is still intended, otherwise drop both `DX_NIX_DISK*` exports in a follow-up.
- Tests: `assert_file_contains "$BIN_DIR/dx-create-container" "DX_NIX_DISK_SIZE"` and `assert_file_not_contains "$BOOTSTRAP" 'truncate -s 64G'`.

Alternatives considered and rejected: **Option B** — delete the `DX_NIX_DISK*` exports entirely (less surface, but discards a usable knob); **Option C** — document the fixed-64G limitation only (leaves the variable inert). Option A was chosen because it makes the already-exported, user-settable variable behave as documented.

### Codebase Assessment (2026-06-04)

What the verification against the working tree turned up:

- **P3 is already fully implemented** — code plus both test assertions. `plan-3.md` is obsolete; the consolidated table records it as done.
- **P5–P10 remain open** and were each confirmed present at the cited file:line. **P4 was dropped** after the 2026-06-05 external review — its partial-hook-env fix conflicts with the intentional race-avoidance behavior asserted by `test_section14:256-257`.
- **plan-6 step 3 was wrong:** `tzdata` lives in `flake.nix` `dxPackages` (line 67) and is wired via `home/shell.nix` `TZDIR` (lines 127, 146), not `home/tools.nix`. The merged P6 corrects this.
- **P10 carries a latent inconsistency** between the documented `20G` default and the hardcoded `64G`. The merged P10 resolves it to a single `64G` default.
- **`tests/profiles/default.env` has no `HOST_TZ` or `DX_NIX_DISK_SIZE` entries today** (and still references `25.11`), so the P5/P10 doc steps are additions, not edits; the `25.11` reference is handled by the upgrade rename.
- **Phase 1 harness work is done and committed (2026-06-12):** `tests/test_helpers.sh` defines the shared `CONTAINER_DIR/FLAKE_NIX/FLAKE_LOCK/NIXVIM_NIX/BOOTSTRAP/CONTAINERFILE/SHELL_NIX` paths, `tests/test_section13_final_review.sh` no longer references `todo.txt`, live helpers are profile-aware, and the suite has since grown sections 17 (dx-ai runtime) and 18 (mount-git). Land P5–P10 on top of this rather than re-deriving paths.
- **Line numbers in the original fix files have drifted slightly** (e.g. P10's `truncate` is now `bootstrap.sh:77`, not the `:76` cited in `plan-10.md`); the references in this section are current.

### External Review Reconciliation (2026-06-05)

An external review (`review.md`) checked this plan against the working tree. All five findings were verified against the code and accepted:

1. **P4 conflicts with intended behavior** → **accepted; P4 dropped.** The proposed `tinty current` fallback is exactly what `test_section14:256-257` forbids (switch-time race). See the P4 entry.
2. **P6/P8 need test updates** → **accepted.** Added "Test update (required)" steps to P6 (`test_section3:83` TZDIR assertion) and P8 (`test_section3:36-40` pgrep-sshd assertion, which only the dead `start_ssh` satisfies).
3. **Isolated profile missing expected-release env** → **accepted.** Added `DX_EXPECTED_NIXOS_RELEASE=26.05` / `DX_EXPECTED_NIXOS_BRANCH=nixos-26.05` to the `nixos-2605.env` block; otherwise `test_helpers.sh:28-29` runs 25.11 assertions against the 26.05 guest.
4. **`--skip-integration` wording fuzzy + stale `--help`** → **accepted.** Documented the real runner surface (skips only 11–12; section 17 runs; help says `0-16`) in [Test Harness Changes](#test-harness-changes) and the [Command Reference](#command-reference).
5. **Final-review gate fails on a dirty tree** → **accepted.** The section-13 clean-tree requirement (`git status -uno --short`, excluding `README.md`) is now called out in both sections above, with guidance to scope around it during in-flight work.

The review's Confirmed Observations also align with this plan: the repo still defaults to 25.11; the `nixos-26.05` / `release-26.05` branches exist; P3 is implemented and P5–P10 remain open. **Note (2026-07-04):** the base-image release-tag gate this paragraph originally described as unchanged has since been removed entirely — [nix-base-plan.md](nix-base-plan.md) replaced the base with the official, digest-pinned `nixos/nix` image, which does not carry a per-NixOS-release tag.
