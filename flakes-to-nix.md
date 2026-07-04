# Plan: Support Both Base Images (`nixpkgs/nix-flakes` and `nixos/nix`)

> **Superseded (2026-07-04) by [`nix-base-plan.md`](nix-base-plan.md).** Both
> of this plan's load-bearing requirements — dual-base support and in-place
> migration of existing machines — were dropped in favor of a one-way,
> single-base changeover (existing machines destroyed and rebuilt, no
> `DX_BASE` selector, no coexistence). This document is retained as design
> history: its confirmed-facts inventory and verification work are the
> factual basis for `nix-base-plan.md` (with corrections noted there), and
> its seven review passes are why that plan could stay small. Do not
> implement anything below directly; see `nix-base-plan.md` for what
> actually ships.

## Goal

Allow the DX container to be built from either base image, selected at build
time, with each Containerfile remaining a single `FROM` line:

- `flakes` (current default): `nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`
  — community-published (nix-community/docker-nixpkgs), tagged per NixOS
  release, arch-specific tags.
- `nix`: `nixos/nix:2.31.5` — official upstream image, tagged per Nix
  version, multi-arch (arm64 manifest confirmed).

Motivation: the 26.05 upgrade in `plan.md` is gated on docker-nixpkgs
publishing `nixos-26.05-aarch64-linux`, which has not happened. The official
`nixos/nix` image removes that third-party dependency; the NixOS release pin
then lives entirely in `flake.nix`.

Decided 2026-07-02: once validated, `nix` becomes the **default** flavor via
a staged flip (see the single-source section and Decisions); `flakes`
remains supported as the non-default flavor.

## Review history

Detail lives in git history; one line per pass:

- **2026-06-11** — first review folded in (dead `dx-mount` default, cheaper
  switch, `DX_CONTAINERFILE` ordering, destroy-guard, test touch points).
- **2026-07-02, pass 2 (self)** — change on bootstrap pin rewritten after
  commit 884ab51 (essentials now merge onto the persistent volume); per-flavor
  mkfs label dropped; `-official` naming and side-container identity decided.
- **2026-07-02, pass 3 (third-party, doc since removed)** — side-container
  isolation made structural (per-flavor volume names, not markers); `.env`
  precedence flagged; build-argument stub test; digest-pin and
  `--no-update-lock-file` hardening.
- **2026-07-02, pass 4 (third-party)** — new existing-container flavor
  guard (change 4); precedence contract corrected to env-wins, implemented
  in `dx-lib.sh` (change 7); cross-flavor reserved-name guard and
  `DX_CONTAINERFILE` semantics (change 2); accepted `FROM` reference format
  fixed (change 1); two-volume destroy algorithm specified (change 6); Nix
  pin bump procedure added; flavor-transition acceptance test added;
  over-claims corrected; history condensed.
- **2026-07-02, pass 5 (third-party)** — cross-flavor guard
  extended to `DX_CONTAINERFILE` (change 2); bootstrap-pin fallback made an
  immutable revision and `--inputs-from` promoted to a required pre-flight
  gate; provenance artifact contract rewritten as implementable
  (change 10); digest provenance moved out of the Containerfile (change 1);
  old→new→old store-transition test and image-removal preconditions added
  to the bump procedure; `DX_ENV_FILE` test seam and scoped precedence
  claim (change 7); `container inspect` version/fixture contract
  (change 4); the two transition-failure tests split. Review passes are
  identified by date, not filename — the review file is mutable and is
  removed after incorporation. A full restructure to a lean implementation
  spec is deferred to implementation start.
- **2026-07-02, pass 6 (third-party)** — this revision. Essentials skip
  gate rebuilt around provenance evidence with in-place repin — the
  `useradd` gate could never repin an existing container (change 10);
  image-Nix alignment assertion replaced — the post-activation in-guest
  check was tautological because `dxPackages` ships `nix` (pre-flight
  check plus `meta.env` capture); transition test respecified as two
  flavor-specific env sets — one `dx-test.env`-style profile cannot drive
  it; default flip gated on shipped custom-name profiles declaring
  `DX_BASE` (they otherwise dodge every guard) and the fail-closed
  migration claim narrowed to reserved-default deployments;
  `DX_CONTAINERFILE` guard compares normalized paths/file identity, not
  strings (change 2); digest test assertion made slice-exact, never
  optional (change 8); cannot-verify split from verified-mismatch in
  change 4 with a live inspect smoke test; `--print-env` gains `DX_BASE`
  and `DX_CONTAINERFILE` (change 6); volume backing-file backups
  rejected; README maintenance section synced.
- **2026-07-02, pass 7 (third-party, doc since removed)** — full
  fact/line-reference re-verification against the tree (all held).
  Change 10 made flavor-switch-aware: shared-`/persist` evidence means a
  switch presents old evidence to a fresh container — repin tolerates an
  empty root profile, the install-vs-repin discriminator is stated, and
  the transition test asserts the switch-repin. Change 6's step-4 guard
  skips with a warning instead of aborting mid-destroy; the
  reserved-Containerfile guard scoped to the resolved `DX_CONTEXT_DIR`
  (names are the contract) with rejection on the opposite flavor only;
  guest context noted for the alignment rule's `nix eval`; README
  snippet and stale line refs corrected.

## Change classification

Sequencing and rollback guide; each change below is tagged accordingly.

- **Dual-base core** — required for the selector to work at all:
  changes 1, 2 (selector part), 3, 5.
- **Safety invariants** — required so flavors cannot silently mix and
  validation is actually isolated: change 2 (cross-flavor guard), 4, 6, 7,
  the switch procedure, and the transition acceptance test.
- **Independent hardening** — reviewable/landable separately if it
  complicates delivery: the digest pin (change 1), change 10 (bootstrap
  nixpkgs pin + provenance), and the Nix pin bump procedure. Change 10 fixes
  a registry-drift issue that exists on both bases today; it is not selector
  mechanics.

Delivery (decided 2026-07-02): two slices. Slice 1 lands dual-base core plus
safety invariants, with `flakes` still the default so the
observable-compatibility guarantee holds; slice 2 lands the independent
hardening — change 10 changes both flavors' boot path, so isolating it keeps
a bad bootstrap bisectable. A third, final step flips the default to `nix`
after both-flavor validation, the transition test, and the flip
preconditions (shipped-profile flavor pinning — see the single-source
section) pass.

## Confirmed facts this plan is built on

Verified against the running `dx-host` container and `NixOS/nix` `docker.nix`
(2026-06-10); file/line references re-verified 2026-07-02 (pass 4):

- Current base provides `/bin/bash`, `/bin/sh`, `/bin/env`. The official
  `nixos/nix` image provides only `/bin/sh` (→ bash) and `/usr/bin/env` —
  **no `/bin/bash`**.
- `dx-create-container` passes `--entrypoint sh` unconditionally
  (`bin/dx-create-container:37`; asserted by
  `tests/test_section9_host_scripts.sh:209`), so the launch never depends on
  either image's default entrypoint: the bare `-c "$BOOTSTRAP_LAUNCH_CMD"`
  after the image name is interpreted by that explicit `sh`. The official
  image's `docker.nix` (checked at the `2.31.5` tag) defines `Cmd` but no
  `Entrypoint` — irrelevant to this launch path; recorded here so nobody
  re-derives an entrypoint change from it.
- `dx-create-container` **skips creation whenever the name already exists**
  (`bin/dx-create-container:7-10`) with no check that the existing
  container's image or volumes match the currently resolved values — and
  `bin/dx` calls it on every bring-up (`bin/dx:19`). This is the reuse hole
  change 4 closes.
- Neither image pins the flake registry: `nixpkgs#…` in `install_essentials`
  resolves to `nixpkgs-unstable` via the global registry **today**. Switching
  bases changes nothing here; change 10 turns this from an accident into an
  explicit decision.
- The guest flake's input is literally named `nixpkgs`
  (`container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix:5`),
  which the `--inputs-from` option in change 10 requires.
- `setup_nix_volume` merges **only `/nix/store`** onto a previously seeded
  volume (`cp -a -n /nix/store/. …`, merge branch of `setup_nix_volume`,
  `bootstrap.sh:121`); `/nix/var` — where root's profile generation pointer
  and metadata live — is shadowed by the remount. Root's essentials survive
  only as concrete store paths pinned onto `PATH` by `install_essentials`.
  Any post-boot provenance check therefore cannot rely on `nix profile`
  metadata (see change 10's evidence spec).
- The official image does not enable flakes in its `nix.conf`. The nix
  invocations that run **before** our config exists (`install_essentials`,
  the home-manager `nix run`) pass
  `--extra-experimental-features 'nix-command flakes'` explicitly; the rest
  (e.g. `nix profile list` in `configure_guest`) rely on the
  `/etc/nix/nix.conf` that `configure_nix_daemon` writes earlier in the same
  boot, on both bases. Validation must exercise both classes.
- Both images set `SSL_CERT_FILE`/`NIX_SSL_CERT_FILE` in the image env
  (different store paths); `bootstrap.sh:5-6` only provides fallbacks.
- The official image ships bash, coreutils-full, tar, gzip, grep, which,
  curl, findutils, git, openssh, but **not** `shadow`, so the
  `install_essentials` gate (`command -v useradd`) still triggers.
- Running guest Nix was 2.31.4 when checked (2026-06-10); pinning
  `nixos/nix:2.31.5` minimizes Nix version drift at switch time. Re-verify
  both at implementation time under the pin policy in change 1.
- `container build` supports `-f <path>` to select a Containerfile.
- `.env` is sourced by `dx-lib.sh` in **every** script run
  (`bin/dx-lib.sh:11-16`) with `set -a`, so it currently overrides even the
  process environment. Consequences (all fixed by change 7): profile runs
  under `dx-profile` (`bin/dx-profile:48-51`) lose to `.env`; one-shot
  invocations like `DX_BASE=nix ./bin/dx` lose to `.env`; manually sourced
  profiles (a README-documented usage) lose to `.env`; and the derived
  side-container names `dx-mount` exports before exec'ing `bin/dx`
  (`bin/dx-mount:156-186`, `:249`) are clobbered in the child scripts if
  `.env` sets the same variables — a live isolation bug today, independent
  of this plan.
- `dx-mount --destroy` delegates volume removal to
  `dx-destroy-volumes --force` (`bin/dx-mount:224`), which removes exactly
  the **single** resolved `DX_NIX_VOLUME` plus the persist and bootstrap
  volumes (`bin/dx-destroy-volumes:18`). Removing a second flavor-variant
  volume needs a new step — specified in change 6.
- The side-container identity validation runs only on the
  `--container`-override path (`bin/dx-mount:132`); the derived-name path
  reuses an existing container without any check. Covered by change 4's
  general guard.
- `dx-sync-bootstrap` wipes the payload destination **including dotfiles**
  before every sync (`rm -rf "$dest"/* "$dest"/.[!.]* "$dest"/..?*`,
  `bin/dx-sync-bootstrap:71`), and the guest never receives
  `DX_BOOTSTRAP_PATH` — `dx-create-container` forwards only `HOST_TZ`, the
  activation knobs, and `DX_PUB_KEY`, and `bootstrap.sh` runs under
  `set -u`. So nothing under `/guest-bootstrap` survives a restart, and
  `bootstrap.sh` cannot reference `$DX_BOOTSTRAP_PATH`. Change 10's
  artifact contract is built around both constraints.
- There is no `dx-exec` helper in `bin/`; host-side guest access is
  `container exec` (as `dx-sync-bootstrap` itself uses).
- `install_essentials` installs only when `useradd` is absent
  (`bootstrap.sh:14`). On warm restarts the container's writable layer
  still holds the previous boot's root profile, so the **skip branch is
  the common case** — any evidence scheme must handle it explicitly.
- The section-2 test requires each Containerfile to contain exactly one
  **non-blank line** (`grep -cve '^[[:space:]]*$'`,
  `tests/test_section2_containerfile.sh:47`) — comments are structurally
  excluded from Containerfiles, so pin provenance must live elsewhere.
- The guest flake's `dxPackages` includes `nix` (`flake.nix:46`) and guest
  sessions put `/home/dx/.nix-profile/bin` first on `PATH`
  (`bootstrap.sh:304,311`), so any post-activation `nix --version` reports
  the *locked nixpkgs'* Nix, not the base image's. Root's essentials
  profile, by contrast, never contains `nix` (see the `install_essentials`
  package list at `bootstrap.sh:21`), so during bootstrap — pre-remount,
  pre-activation — `nix` always resolves to the image's own binary, on
  both gate branches, warm or fresh. Change 10's `meta.env` capture and
  the alignment rule's evidence are built on this split.
- The shipped profiles `tests/profiles/dx-test.env` and
  `tests/profiles/dx-tinty.env` set custom `DX_IMAGE` and `DX_NIX_VOLUME`
  values and do **not** set `DX_BASE` — the default-flip hazard and the
  transition-fixture constraint both follow from this shape (see the
  single-source section and the validation checklist).
- `dx-start-container` runs `dx-sync-bootstrap` on **every** bring-up
  (`bin/dx-start-container:19`), so `/guest-bootstrap` — including
  `flake.lock` — is freshly synced whenever `bootstrap.sh` runs. A
  re-lock reaches the guest on the very next restart, and change 10's
  evidence-vs-lock comparison always sees the current lock.
- `dx-mount --print-env` prints thirteen `DX_*` variables
  (`bin/dx-mount:188-203`); none identify the flavor — fixed in change 6.
- **Unverified, gated on pre-flight**: that `container inspect` exposes an
  existing container's image reference and volume mounts in parseable form
  (needed by change 4 — Apple's command reference guarantees JSON output
  but documents no stable field schema, so pre-flight must record the
  `container` version and capture a real fixture); that `container build`
  accepts digest references in `FROM` (change 1 digest pin); that
  `container create` supports labels and `container inspect` surfaces them
  (change 4's optional flavor label); and that
  `nix profile install --inputs-from` works with root's pre-volume nix on
  both bases (change 10 — a required gate).

## Changes

### 1. Containerfile variants (one `FROM` line each) — dual-base core; digest pin: hardening

In `container/aarch64-darwin-apple-container-dx-nixos-25.11/`:

- `Containerfile` — unchanged: `FROM nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`
- `Containerfile.nix` — new: `FROM nixos/nix:2.31.5`

Pin an explicit Nix version tag, never `latest` (a newer Nix can one-way
migrate the store SQLite schema and profile manifest format on the persisted
dx-nix volume, breaking rollback). Bumping the pin is its own deliberate
maintenance task with its own procedure — see
[Bumping the Nix pin](#bumping-the-nix-pin-nix-flavor-maintenance).

**Version policy** (not "latest 2.31.x"): the chosen tag must be
schema-compatible with the currently persisted store — in practice, the same
minor version the guest already runs, or a bump validated through the bump
procedure. The tag additionally follows the **release alignment rule**
(decided 2026-07-02): match the major.minor of the pinned release's default
Nix — `nixpkgs#nix.version` at the locked revision — taking the newest patch
tag within that minor, so the image pin derives mechanically from the
release pin (see the single-source section). `2.31.5` satisfies the rule
today: the 25.11 flakes guest runs the release's default Nix 2.31.4.
Substitute the tag chosen under this policy at implementation time.

**Accepted `FROM` reference format (resolved)** — exactly one of:

```text
FROM nixos/nix:<version>
FROM nixos/nix:<version>@sha256:<digest>
```

The tag-plus-digest form is **adopted** (decided 2026-07-02) — the
pre-flight gates feasibility only, and a failure there drops to tag-only
with the residual risk recorded under Risks; the digest-only form
(`nixos/nix@sha256:…`) is **rejected** even though it is technically valid —
the human-readable version must always be present, and the section-2 test
(change 8) enforces this shape. The pinned digest is the **multi-platform
manifest-list digest** (what `container image pull nixos/nix:<tag>` resolves
and Docker Hub lists for the tag), not a platform-specific image digest.
Record that choice in the bump procedure below — **not** as a Containerfile
comment: the section-2 test requires exactly one non-blank line per
Containerfile (see confirmed facts), and that invariant stays. If the
pre-flight fails, ship tag-only and record the tag-mutability residual risk
under Risks.

### 2. Flavor selector in `bin/dx-lib.sh` — core, plus cross-flavor guard (safety)

- `DX_BASE="${DX_BASE:-flakes}"` — allowed values `flakes` | `nix`; reject
  anything else with a clear error.
- `DX_CONTAINERFILE` — `$DX_CONTEXT_DIR/Containerfile` for `flakes`,
  `$DX_CONTEXT_DIR/Containerfile.nix` for `nix`.
- Flavor-specific `DX_IMAGE` default: keep `dx-nixos-25.11` for `flakes`
  (no behavior change), use `dx-nixos-25.11-official` for `nix` (the
  `-official` token is the resolved naming decision — see
  [Decisions](#decisions)). Distinct names are required because
  `dx-create-image` skips the build when the image already exists — a shared
  name would silently reuse the other flavor's image.
- Flavor-specific `DX_NIX_VOLUME` default: keep `dx-nix` for `flakes`, use
  `dx-nix-official` for `nix`. Each flavor then seeds and owns its own store
  volume: no hybrid store, and switching flavors never requires deleting a
  volume. `/persist` (and the bootstrap volume) stay shared. The new default
  must also be added to `dx-mount`'s `refuse_default_destroy` guard list
  (`bin/dx-mount:217`) — and the guard must refuse **both** `dx-nix` and
  `dx-nix-official` unconditionally, regardless of the active `DX_BASE`,
  because the guard exists precisely for leaked-env cases where `DX_BASE`
  itself may be leaked. Extend the guard test at
  `tests/test_section18_mount_git.sh:204` (currently exercising
  `DX_NIX_VOLUME=dx-nix`) with a `dx-nix-official` case.
- **Cross-flavor reserved-name guard (new)**: explicit `DX_IMAGE` /
  `DX_NIX_VOLUME` / `DX_CONTAINERFILE` overrides are intentionally
  preserved, but that means `DX_BASE=nix` combined with any of
  `DX_IMAGE=dx-nixos-25.11`, `DX_NIX_VOLUME=dx-nix`, or
  `DX_CONTAINERFILE=$DX_CONTEXT_DIR/Containerfile` (e.g. stale `.env`
  entries) would defeat the isolation mechanisms. The Containerfile case
  is the most insidious: with only `DX_CONTAINERFILE` stale, the **wrong
  flavor's base gets built under the right flavor's image name**, and
  change 4's inspect guard then passes because every name matches — it is
  the one override where the name lies about the content. After each value
  resolves, fail fast if it equals the **opposite** flavor's reserved
  default (both directions, all three variables), with an error telling
  the user to remove the stale override. For `DX_CONTAINERFILE` the
  comparison is **not** lexical string equality (pass 6):
  `$DX_CONTEXT_DIR/./Containerfile`, a relative path, and a symlink to the
  reserved file all alias it and would build the wrong base under the
  right image name — the exact failure this guard exists to prevent.
  Normalize the resolved path and, when the file exists, compare by file
  identity (Bash `-ef`);
  when it does not exist, compare the lexically normalized strings — the
  regular-file check in `dx-create-image` (change 3) still catches the
  bogus path at build time, and destroy paths never evaluate it, so a
  stale nonexistent override cannot block recovery. Rejection fires only
  when the value aliases the **opposite** flavor's reserved Containerfile
  (pass 7) — a value aliasing the own flavor's merely restates the
  default and passes. The reserved paths are evaluated against the
  **resolved** `DX_CONTEXT_DIR`, overridden or not (decided, pass 7): in
  every context directory the names are the contract — `Containerfile`
  is the flakes flavor, `Containerfile.nix` the `nix` flavor — so a
  custom context directory must name its `nix` variant
  `Containerfile.nix`, documented with the responsibility note below.
  (Scoping the guard to the default context dir instead would let a
  stale override escape exactly when `DX_CONTEXT_DIR` is also
  overridden.) The image/volume checks run after
  the defaults block; the Containerfile check runs after the
  `DX_CONTAINERFILE` assignment (which follows the `DX_CONTEXT_DIR`
  default — see the split-block note below). Custom, non-reserved values
  remain allowed and are documented as an advanced responsibility: whoever
  overrides them must keep them flavor-consistent themselves (including
  the context-directory naming contract above).
- **`DX_CONTAINERFILE` is public, same contract as every other `DX_*`
  variable (resolved)**: preserved when preset
  (`"${DX_CONTAINERFILE:-$flavor_default}"`), exported, documented in the
  README and as a comment in `tests/profiles/default.env`. An explicit value
  wins over the flavor default; `dx-create-image` verifies it names a
  regular file (change 3).
- **Ordering matters**: the `DX_BASE` validation and flavor-default
  computation must run *before* the existing eager defaults at
  `bin/dx-lib.sh:27` (`DX_IMAGE`) and `:40` (`DX_NIX_VOLUME`), with those
  lines becoming `"${DX_IMAGE:-$flavor_default}"`. The `:-` expansion
  already preserves user overrides — no extra was-it-user-set bookkeeping is
  needed, but a flavor default assigned *after* the eager defaults would
  silently never take effect. The cross-flavor guard runs *after* the
  defaults block (a resolved value equal to the other flavor's reserved
  default can only be an explicit override at that point).
- **Split the flavor block in two**: `DX_CONTAINERFILE` is derived from
  `DX_CONTEXT_DIR`, which is only defaulted at `dx-lib.sh:32`. So the
  `DX_BASE` validation plus image/volume flavor defaults go before the
  eager defaults, and the `DX_CONTAINERFILE` assignment goes after the
  `DX_CONTEXT_DIR` default — otherwise it references an unset variable
  under `set -u`.
- `bin/dx-mount` needs no `DX_IMAGE` mirroring: it sources `dx-lib.sh`
  (line 13), which unconditionally exports `DX_IMAGE`, so the duplicate
  default at `dx-mount:158` is dead code that can never fall back to its
  literal. Delete that line as part of this change. (Its Nix-volume
  derivation *does* change — see change 6.)

### 3. `bin/dx-create-image` — dual-base core

Pass the selected file:
`container build -t "$DX_IMAGE" -f "$DX_CONTAINERFILE" "$DX_CONTEXT_DIR"`.

Before invoking `container build`, fail fast unless `$DX_CONTAINERFILE` is a
regular file — an overridden `DX_CONTEXT_DIR` (likely during the 26.05
context rename) or a typo'd override should die with a clear message, not a
runtime build error.

A correct `DX_CONTAINERFILE` value is not enough — change 8 adds a stubbed
test asserting the exact arguments this command receives, per flavor.

### 4. Refuse to reuse an existing container from the other flavor — safety invariant (new)

The per-flavor image and volume names protect creation, but not **reuse**:
`dx-create-container` skips creation whenever `$DX_CONTAINER_NAME` exists
(`bin/dx-create-container:7-10`), so after a `DX_BASE` change without the
destroy step, `./bin/dx` would ensure the new flavor's image and volume
exist, then silently start the **old** container still attached to the old
image and volumes. The documented switch procedure avoids this only when
followed exactly; a missed step must fail closed, not run the wrong flavor.

Add an invariant to `dx-create-container`, before the exists-skip: when the
container already exists, inspect its configured image and Nix-volume mount
(runtime inspection via `container inspect`, not a cache marker — the
container's own configuration is the authoritative state, and host cache
directories can be deleted while the container survives). If they do not
match the resolved `DX_IMAGE` / `DX_NIX_VOLUME`, fail with the exact switch
command (`./bin/dx-destroy-container`, then re-run). Pre-flight must confirm
`container inspect` exposes these fields (see checklist); if it turns out
not to, fall back to a recorded marker and flag the weaker guarantee here.

**Inspection contract (fixed at pre-flight, before writing the parser)**:
Apple's command reference guarantees JSON from `container inspect` but
documents no stable field schema, so the pre-flight records the supported
`container` version and captures a sanitized **real** inspect response as a
test fixture — stub tests run against that fixture, never a fabricated
response the production parser might not actually match. Nail down: the
exact image and mount fields; whether image comparison uses the tag, a
normalized reference, or an image ID; how named-volume mounts are
distinguished from bind mounts; and that the guard **fails closed**
(refuses with a "cannot verify" error, never skips and continues) on
malformed, incomplete, or unparseable output.

**Two distinct failure modes (pass 6)** — a verified mismatch and an
unverifiable container have different recoveries, so they get different
errors:

- *Verified mismatch* — print the exact switch command
  (`./bin/dx-destroy-container`, then re-run), as above.
- *Cannot verify* (malformed/incomplete/unparseable inspect output) —
  still fail closed, but **never** recommend destroying the container:
  destruction does not repair a parser broken by a new Apple `container`
  schema — it buys exactly one create-and-start run before the next
  bring-up fails verification again. Print the detected and supported
  `container` versions, state that the container itself is untouched, and
  point at updating dxe / reporting the incompatibility. No bypass knob
  (decided, pass 6): an env- or `.env`-settable escape hatch would let one
  stale line permanently defeat the guard; manual destroy-and-recreate
  remains the workaround of last resort, accepted as lossy for the
  writable layer only.

**Scope, stated narrowly (pass 6)**: the guard verifies the image and the
Nix volume — the two flavor-defining resources — and closes cross-flavor
reuse. It does **not** validate the other immutable create-time settings
(persist/bootstrap mounts, port mappings, memory, CPUs), which can still
drift between `.env` and an existing container; that is out of scope
here.

**Optional flavor label (diagnostics)**: if the pre-flight confirms
`container create` supports labels and `container inspect` surfaces them,
label each created container with its `DX_BASE` and expected Nix volume at
creation; the guard then verifies the *declared* flavor alongside the
actual image/mount config instead of inferring flavor solely from mutable
local image names. (The primary defense against name-lies-about-content is
change 2's Containerfile guard; if labels are unsupported, that guard plus
image/volume inspection stand alone.)

Because `bin/dx` runs `dx-create-container` on every bring-up (`bin/dx:19`)
and `dx-mount` execs `bin/dx`, this one guard covers dx-host **and** side
containers, on both the derived-name and `--container` paths — closing the
derived-path reuse hole that the marker check at `bin/dx-mount:132` never
covered. The destroy paths (`dx-destroy-container`, `dx-mount --destroy`,
`dx-destroy`) do not go through this check and must keep working under a
mismatch — that is the recovery route the error message recommends.

### 5. Make `bootstrap.sh` base-agnostic — dual-base core

Both changes work on both images:

- Line 1: `#!/bin/bash` → `#!/usr/bin/env bash`. On `nixos/nix` the current
  shebang fails with ENOENT when the entrypoint loop `exec`s the script —
  this is the single hard breakage of the switch. `/usr/bin/env` presence on
  the **pristine** flakes base is *expected but unproven*: the seven guest
  scripts in `container/.../scripts/` that already use this shebang run in
  an installed guest, which proves nothing about the pre-bootstrap image.
  The pre-flight checklist's pristine-image checks are the actual proof
  gate; treat this claim as pending until they pass. If that gate *fails*
  on either base, do **not** drop to `#!/bin/sh` (pass 6): `bootstrap.sh`
  relies on Bash semantics (`pipefail`, `local`, Bash-style tests). The
  real fallbacks are a proven absolute Bash path per base, or a full
  POSIX rewrite of the bootstrap — each its own deliberate, tested
  change, never a casual substitution.
- In `create_user` (`bootstrap.sh:214`):
  `useradd -m -g dx -s /bin/bash dx` → `-s /bin/sh`. `/bin/sh` exists in
  both images; the shell is switched to nushell at the end of
  `configure_guest` anyway, so `/bin/sh` is only the fallback when nu is
  missing.
- A per-flavor filesystem label for `setup_nix_volume` was considered and
  **dropped** (pass 2): the `dx-nix` label appears at seven sites — four
  `mkfs` calls (`bootstrap.sh:82,84,94,96`), two `blkid -L dx-nix`
  format-idempotence checks (`:75`, `:131`), and the fstab `LABEL=dx-nix`
  entry (`:132`) — and `bootstrap.sh` has no way to learn the flavor, since
  `dx-create-container` forwards no env beyond `DX_PUB_KEY` and the
  activation knobs. Only one volume is ever attached per guest, so the
  shared label stays harmless; not worth the plumbing.

No other `/bin/bash` references exist in the guest payload (verified by
grep, re-verified 2026-07-02).

### 6. Side-container flavor isolation in `bin/dx-mount` — safety invariant

Side-container Nix volumes (`$DX_CONTAINER_NAME-nix`, `bin/dx-mount:163`) do
not encode the flavor, so a side container destroyed with
`dx-destroy-container` (which removes only the container — volumes and the
identity marker survive) and recreated under the other `DX_BASE` would merge
the new image's store into the old flavor's seeded store.

Make the isolation **structural**, mirroring the per-flavor dx-host volumes
in change 2 — derive flavor-specific side-volume names:

- `flakes`: `$DX_CONTAINER_NAME-nix` — unchanged, preserving every existing
  side volume;
- `nix`: `$DX_CONTAINER_NAME-nix-official`.

Recreating a side container under the other flavor then simply seeds and
uses its own volume. (A marker-only mechanism was rejected in pass 3:
`~/.dx-cache/mount-identities` is a deletable host cache directory, not an
isolation boundary.) Wrong-flavor **reuse** of an existing side container is
handled by change 4's general guard, which runs on both the derived-name and
`--container` paths.

Keep the identity marker for diagnostics and `--container`-override
validation:

- Record `DX_RECORDED_BASE=$DX_BASE` alongside
  `DX_RECORDED_GIT_MOUNT_SOURCE` (written at `bin/dx-mount:240-244`); let
  the existing override validation (`bin/dx-mount:132`) report flavor
  mismatches too, as a friendlier early error than change 4's guard. Treat
  a marker without `DX_RECORDED_BASE` as `flakes` (every pre-change side
  container predates the `nix` flavor).
- **Any mismatch check must never block `--destroy`.** The destroy branch
  (`bin/dx-mount:205`) runs after the identity validation; a refusal placed
  ahead of it would reject the very recovery command its own error message
  recommends.

**`--print-env` prints the flavor (pass 6)**: the printed profile is
documented as a self-contained derived profile, but today it omits any
flavor information (see confirmed facts) — sourced under a different
`.env`, or after the default flip, it can resolve a different flavor than
the one it was derived from. Add `DX_BASE` and the resolved
`DX_CONTAINERFILE` to the output; test (change 8) that sourcing the
printed profile in a clean process reproduces the selected image,
Containerfile, and flavor-specific Nix volume.

**`--destroy` algorithm (resolved)** — must remove both flavor variants of
the private Nix volume, otherwise a flavor switch strands a volume no
command cleans up. Exact sequence, keeping `dx-destroy-volumes` narrow
rather than widening the generic command:

1. Run the `refuse_default_destroy` guards as today, with `DX_NIX_VOLUME`
   checked unconditionally against **both** `dx-nix` and `dx-nix-official`
   (change 2).
2. `dx-destroy-container`.
3. `dx-destroy-volumes --force` — unchanged scope: removes the single
   resolved `DX_NIX_VOLUME` plus the persist and bootstrap volumes.
4. New step, in `dx-mount` itself: for each of the two **derived** names
   `$DX_CONTAINER_NAME-nix` and `$DX_CONTAINER_NAME-nix-official` that still
   exists, check it against the reserved defaults, then
   `container volume rm` it. That check **skips the volume with a warning,
   never aborts** (pass 7): `refuse_default_destroy` as implemented exits,
   and an exit here would strand step 5's key and marker cleanup after the
   container and resolved volumes are already gone. The guarded case is
   reachable only on a `--container dx` side container run with an
   explicit non-reserved `DX_NIX_VOLUME` override — its derived names are
   literally `dx-nix`/`dx-nix-official` while step 1 sees only the
   override. (Without the override, the derived `dx-nix` *is* the
   resolved volume and step 1 aborts the whole destroy — today's behavior
   too.) With an explicit user-supplied `DX_NIX_VOLUME`
   override, step 3 removes the named volume and step 4 still cleans only
   the two derived-name variants — `--destroy` never removes any other
   user-named volume.
5. `dx-destroy-keys`; remove the identity marker.

Tests assert the exact `container volume rm` invocations via a stubbed
`container` (change 8), not just grep for cleanup commands.

(Also update the interaction note in `mount-git.md` — see change 9.)

### 7. `.env` precedence: process environment wins — safety invariant (pre-existing bug)

Today `dx-lib.sh` sources `.env` with `set -a` on every script run
(`bin/dx-lib.sh:11-16`), giving the effective order
`.env > profile/process env > defaults`. That breaks four things (see
confirmed facts): `dx-profile` runs, one-shot `DX_BASE=nix ./bin/dx`,
manually sourced profiles (README-documented), and `dx-mount`'s derived
exports in the child scripts it execs. Once the switch procedure puts
`DX_BASE=nix` in `.env`, an isolated `dx-official.env` run would silently
flip flavor — the per-flavor validation below is not isolated without this
fix.

**Contract (resolved, scoped)**: exported `DX_*` configuration variables
in the process environment win over `.env`, and `.env` wins over defaults —

```text
profile/process environment (DX_*) > .env > defaults
```

The scope is deliberate: the snapshot mechanism below restores only `DX_*`
variables, so a non-`DX_` assignment in `.env` keeps today's behavior — do
not document this as "the environment always wins".

Implement it generally in `dx-lib.sh`, not via a `dx-profile` flag: an
earlier `DX_SKIP_ENV_FILE` proposal is **dropped** — it produced
`profile > defaults`, silently discarding every non-conflicting `.env`
value, and fixed neither one-shots nor manual sourcing. Mechanism sketch
(implementation may vary): snapshot the already-exported `DX_*` variables
before sourcing `.env` (e.g. via `export -p`), source `.env` as today so its
shell semantics are preserved, then re-apply the snapshot. `dx-profile`
itself needs no change.

Consequences to document: variables exported from the user's shell rc now
beat `.env` (standard dotenv convention); `.env` remains authoritative for
anything not explicitly in the environment. This is a behavior change for
anyone relying on `.env` overriding profile runs — judged unlikely to be
depended on (profiles exist precisely to escape the defaults), and the old
behavior defeats profile isolation outright.

**Test seam (`DX_ENV_FILE`, resolved)**: `dx-lib.sh` hardcodes
`$DX_PROJECT_ROOT/.env` and recomputes the project root from its own
location, so tests running the real scripts cannot escape the developer's
actual `.env` — and under the env-wins contract, merely unsetting a process
variable lets the repo `.env` restore it. Add `DX_ENV_FILE` (default
`$DX_PROJECT_ROOT/.env`) so tests can point at an empty or temporary file.
`DX_ENV_FILE` is necessarily a process-environment-only knob — it selects
the file, so it cannot itself be set in `.env`. Clean-environment test
helpers (e.g. `dx_mount_clean` in `tests/test_section18_mount_git.sh:19`)
must control `DX_BASE`, `DX_CONTAINERFILE`, and `DX_ENV_FILE` alongside the
variables they already manage.

Tests (change 8) must cover **both** a conflicting variable (process/profile
value wins) and a non-conflicting one (`.env` value still applies during a
profile run), pointing `DX_ENV_FILE` at a temporary env file — never the
user's real `.env`.

### 8. Tests

- `tests/test_section2_containerfile.sh` / `tests/test_helpers.sh`: run the
  existing assertions over **both** Containerfile variants (loop over
  `Containerfile` and `Containerfile.nix`); each must be exactly one
  non-blank `FROM` line. `tests/test_helpers.sh:26` defines a single
  `CONTAINERFILE` variable, so the loop needs a helper change (e.g. a
  `CONTAINERFILE_NIX` sibling or a list).
- Add assertions matching change 1's resolved format exactly:
  `Containerfile` is FROM `nixpkgs/nix-flakes:`; `Containerfile.nix` must
  match the **active digest policy exactly — the digest is never optional
  in the regex** (pass 6: an optional `(@sha256:…)?` group would let an
  adopted digest be removed accidentally without failing CI). While the
  digest pin has not landed (slice 1), require
  `^FROM nixos/nix:<version>$`; when it lands (slice 2), tighten the
  assertion in the same commit to require `@sha256:<64 hex>`; if the
  pre-flight rejects digest references, keep tag-only permanently and
  record the waiver under Risks and in the README maintenance section.
  An explicit version tag is required and `:latest` and the digest-only
  form are rejected in every variant. The one-non-blank-line invariant
  stays as-is: no comments in either Containerfile (digest provenance
  lives in the bump procedure).
- `tests/test_section13_final_review.sh:49` also asserts on `$CONTAINERFILE`;
  cover **both** variants there (decided 2026-07-02).
- `tests/test_section9_host_scripts.sh`: cover `DX_BASE` validation
  (bad value → error; `nix` → `Containerfile.nix` + `dx-nixos-25.11-official`
  + `dx-nix-official`; explicit `DX_IMAGE`/`DX_NIX_VOLUME` still win under
  `DX_BASE=nix` when non-reserved), the cross-flavor reserved-name guard
  (both directions → error, for **all three** variables including
  `DX_CONTAINERFILE` — behavioral, not grep; for `DX_CONTAINERFILE`
  also cover the normalization from change 2: a `./`-alias, a relative
  path, and a symlink to the opposite flavor's reserved Containerfile
  must each be rejected), `DX_CONTAINERFILE` semantics
  (explicit value wins; both flavors resolve correctly under an overridden
  `DX_CONTEXT_DIR`), and the change-7 precedence contract (conflicting and
  non-conflicting `.env` values via `DX_ENV_FILE`, per change 7).
- **Build-command coverage**: the section-9 checks above are static greps;
  none prove `dx-create-image` actually passes `-f` correctly. Add a test
  that puts a stub `container` executable on `PATH` and asserts the exact
  `container build -t <image> -f <containerfile> <context>` arguments for
  both flavors, including with an explicit `DX_IMAGE` override; plus the
  regular-file pre-check failure for a bogus `DX_CONTAINERFILE`.
- **Existing-container guard (change 4)**: with a stubbed `container`
  whose `inspect` output is the sanitized **real fixture** captured at
  pre-flight (never a fabricated response) — a flavor mismatch fails and
  names the switch command; same for an existing derived side container;
  malformed/truncated fixture variants fail closed with the
  **cannot-verify** error (container preserved, detected/supported
  versions printed — distinct from the mismatch error, which is the only
  one that recommends destroy); `dx-destroy-container` and
  `dx-mount --destroy` succeed despite the mismatch. Plus one **live**
  integration smoke test that parses the current runtime's real
  `container inspect` output (pass 6): fixtures prove the parser against
  a recorded schema; the smoke test catches the schema moving.
- **Provenance artifact (change 10)**: every gate outcome — a fresh
  boot (install) produces evidence recording the locked revision; a warm
  restart with valid matching evidence (skip) records the skip and leaves
  the prior install's `profile.json` readable; a warm container with
  `useradd` but **no artifact** (the pre-change-10 shape) and one whose
  recorded revision **differs** from the current `flake.lock` both take
  the repin path and end with fresh matching evidence; evidence whose
  recorded store paths are absent alongside **no prior install** (the
  flavor-switch shape) repins with a no-op remove over the empty root
  profile (pass 7); and the skip decision no longer keys on `useradd`,
  so a base image that shipped it would
  still install-and-record. Assert `flake.lock`'s checksum is unchanged
  across bootstrap (`--no-update-lock-file` actually held). Read via
  `container exec`, per the artifact contract.
- **Shipped-profile flavor declaration (flip precondition)**: every
  profile under `tests/profiles/` that sets a custom `DX_IMAGE` or
  `DX_NIX_VOLUME` must also set `DX_BASE` explicitly (see the flip
  preconditions in the single-source section).
- `tests/test_section18_mount_git.sh`: besides the guard extension in
  change 2, cover change 6 — `DX_BASE=nix` derives
  `<name>-nix-official` in `--print-env`; recreation under the other flavor
  uses its own volume (no hybrid store); `--destroy` under a mismatched
  flavor **succeeds**, issues the exact `container volume rm` calls for both
  flavor-variant volumes (stub-asserted), still refuses all default
  resources, and never removes a non-derived user-named volume beyond the
  resolved one; a derived name colliding with a reserved default (a
  `--container dx` run with an explicit `DX_NIX_VOLUME` override) is
  skipped with a warning while key and marker cleanup still complete
  (pass 7); the marker records `DX_RECORDED_BASE` and a marker missing
  the field is treated as `flakes`; and `--print-env` emits `DX_BASE` and
  `DX_CONTAINERFILE` such that sourcing the printed profile in a clean
  process reproduces the image, Containerfile, and flavor-specific volume
  (pass 6).
- `tests/test_section10_docs.sh`: assert the README documents `DX_BASE`,
  matching the established pattern of doc requirements having test coverage.
- Runtime suites (sections 11/12, tools, etc.) are flavor-relative already;
  a full `run_all_tests.sh` pass is required once per flavor before
  declaring the feature done (see the validation checklist for how the
  `nix`-flavor run is isolated), plus the transition sequence in the
  checklist.

### 9. Docs

- `README.md`: document `DX_BASE` (values, defaults, image-name
  implications) and `DX_CONTAINERFILE` next to the existing "Lightweight
  Host" note; state the switch procedure (below); document the change-7
  precedence contract (exported `DX_*` env > `.env` > defaults — scoped to
  `DX_*`, per change 7) and the `DX_ENV_FILE` seam next to the `.env`
  documentation, including the override-responsibility note from change 2.
  Ahead of the default flip, document that user-maintained profiles with
  custom `DX_IMAGE`/`DX_NIX_VOLUME` names must pin `DX_BASE` explicitly or
  be deliberately migrated — custom image rebuilt, container recreated —
  before relying on post-flip behavior (pass 6; see the flip
  preconditions). Update the roadmap entry (`README.md:648`, "Dual
  base-image support") as slices land — its pass count and status line
  are refreshed with each review pass.
- `tests/profiles/default.env` documents every default as a comment; add
  `# export DX_BASE=flakes` (and a `DX_CONTAINERFILE` comment) there.
- The README's "Release and Pin Maintenance" section (added 2026-07-02,
  ahead of implementation) documents the single-source release pin, the
  alignment rule, and the image-pin bump procedure — keep it in sync as
  changes land, and extend `tests/test_section10_docs.sh` to assert its
  presence alongside `DX_BASE`. Its runtime-validation snippet was
  corrected in pass 6 together with this plan: the old in-guest
  `nix --version` comparison was tautological (see the single-source
  section).
- `mount-git.md:56-59`: the interaction note still cites "that plan's open
  decision on side-container flavor identity" and states side-container
  volume names do not encode the flavor. Update it: the decision is
  resolved, side-container Nix volumes are per-flavor under change 6, and
  any future seeding mechanism must seed from the matching flavor's store.
- `plan.md`: note that the 26.05 base-image gate
  (`nixpkgs/nix-flakes:nixos-26.05-aarch64-linux` must exist) applies only to
  the `flakes` flavor; under `nix` the release bump is purely `flake.nix`
  (`nixos-26.05` inputs) plus revalidation. Also update the release-bump
  playbook's `OLD_IMAGE`/`NEW_IMAGE` definitions, which are keyed by release
  name only and need flavor variants once two flavors exist. (A forward
  pointer to this plan was added to `plan.md` on 2026-06-12.)

### 10. Bootstrap nixpkgs pin — independent hardening (both flavors)

`install_essentials` installs root bootstrap tools from `nixpkgs#…`, which
resolves through the global flake registry to nixpkgs-unstable — on both
flavors, today included. That conflicts with the stated goal of the release
pin living in `flake.nix`.

Since commit 884ab51 the stakes are real: `install_essentials` keeps those
tools valid across the `/nix` remount by pinning `PATH` to their concrete
store paths, and `setup_nix_volume` merges the image store — including the
unstable-resolved essentials — onto the persistent per-flavor volume on
every boot from a freshly built image. Registry drift accretes in the
volume; the old "accept drift, the pre-mount layer is throwaway" option is
dead. Pick one:

- **Pin via the locked flake (recommended)**: use
  `nix profile install --inputs-from /guest-bootstrap --no-update-lock-file
  nixpkgs#shadow …`. `bootstrap.sh` executes from `/guest-bootstrap`, next
  to `flake.nix` and `flake.lock`, and the payload is fully synced before
  bootstrap runs (the launch loop waits for `.dx-bootstrap-ready`). The
  guest flake's input is literally named `nixpkgs` (verified — see
  confirmed facts), so this resolves `nixpkgs` to the locked revision: the
  pin then genuinely lives only in `flake.nix`/`flake.lock`, with no new
  release-bump checklist item. `--no-update-lock-file` ensures the
  bootstrap can never mutate the payload's lock as a side effect. Whether
  `--inputs-from` works with root's pre-volume nix on both bases is a
  **required pre-flight gate** (see checklist) — resolved before any repo
  change, so the fallback below is chosen deliberately, never discovered
  mid-implementation.
- **Pin via an immutable revision (fallback)**, only if that pre-flight
  gate fails. A branch reference like `github:nixos/nixpkgs/nixos-25.11`
  is **not** a pin — it moves, provides no reproducibility, and will not
  generally resolve to the revision the provenance gate checks against.
  The fallback is the exact locked revision:
  `DX_BOOTSTRAP_NIXPKGS="github:nixos/nixpkgs/<40-char rev>"` at the top
  of `bootstrap.sh`, used as `$DX_BOOTSTRAP_NIXPKGS#shadow` etc., where
  the rev **must equal** `nodes.nixpkgs.locked.rev` in the payload's
  `flake.lock` — `flake.lock` stays the single source of truth, and a
  section-3 test asserts the two are in sync. The rev still needs manual
  updating on a release bump, but drift is then caught by test, not
  trusted to a checklist.

**Evidence-gated skip with in-place repin (pass 6; replaces the `useradd`
gate)**. The pin above fixes only *fresh* installs — `install_essentials`
skips whenever `useradd` exists (`bootstrap.sh:14`), and on the first boot
after this change every existing container still has `useradd` from the
old registry-resolved install: the skip branch would have no prior
`profile.json` to retain and would record `state=skipped` over an
unverified install. The same hole reopens whenever `flake.lock` changes
without a container recreate — and `dx-sync-bootstrap` runs on every
bring-up (see confirmed facts), so a re-lock reaches the guest on the very
next restart. The gate therefore changes from "`useradd` exists" to
"**a complete essentials installation provably matches the current locked
revision**", with four outcomes:

- *Valid evidence* — `meta.env` and `profile.json` parse, the recorded
  locked revision equals `nodes.nixpkgs.locked.rev` in
  `/guest-bootstrap/flake.lock`, and the recorded store paths exist (the
  warm writable layer holds them pre-remount) → **skip**; rewrite
  `meta.env` with `state=skipped`.
- *Evidence missing, malformed, or stale* — a pre-change-10 container, a
  lock bumped since install, a flavor switch (below), or a damaged
  artifact → **repin in place**
  (decided 2026-07-02): remove the previous essentials entries from
  root's profile — the root profile contains only them — then reinstall
  from the locked input and write both files fresh. The remove step
  **must tolerate an absent or empty root profile** (pass 7): that state
  is reachable by design, not defensively — see the flavor-switch
  paragraph below. A repin that fails mid-way self-heals: the next boot
  finds no prior install and reinstalls.
- *Fresh container* → **install** as today, plus evidence.
- A base image that itself shipped `useradd` needs no special case — the
  **skip** decision no longer keys on `useradd` at all.

**Install-vs-repin discriminator (pass 7)** — the two branches differ
only in the remove step and the recorded `state`, but the fork must be
defined: a fresh container also has no evidence. It keys on whether a
prior install is present (`useradd` resolves — root's profile is
non-empty). Present → repin; absent → plain install. That covers all
four combinations of {evidence present/absent} × {prior install
present/absent}: valid evidence + install is the skip; stale-or-missing
evidence + install is the repin (the pre-change-10 warm container);
nothing + nothing is the fresh install; and evidence *without* an
install — the flavor-switch shape — repins with a no-op remove.

**Flavor switches make stale evidence a designed state (pass 7)**:
dx-host's two flavors share `dx-persist` (change 2), and the evidence is
deliberately **not** flavor-keyed — `bootstrap.sh` has no way to learn
the flavor (the same constraint that dropped the per-flavor mkfs label
in change 5). After a switch, the fresh container of the new flavor
reads the old flavor's evidence: the recorded revision matches the
shared lock, but the recorded store paths do not exist in the new
image's pre-remount layer, so the gate routes to repin — over an empty
root profile, hence the tolerance requirement above. Every switch
therefore repins on the target flavor's first boot and overwrites the
shared evidence; switching back repins again. That is correct and
asserted by the transition acceptance test (validation checklist). Side
containers are unaffected — their persist volumes are per-container.

The fail-closed-and-recreate alternative was rejected: it would refuse
boot on every existing container and side container at rollout, and turn
every out-of-band `nix flake update` into a forced container recreation.
The `PATH` pinning across the remount stays unconditional exactly as
today — it already runs outside the gate, on every boot
(`bootstrap.sh:23-33`).

Whichever pin option lands, verify it at two levels:

- **Source test (section 3), scoped to `install_essentials`** — not to
  every `nix profile install` line in the file, which would wrongly
  constrain unrelated future installs. Under the variable fallback, assert
  the `install_essentials` body contains no bare `nixpkgs#` reference.
  Under `--inputs-from`, that assertion would fail — the install line still
  legitimately reads `nixpkgs#shadow` (what changes is resolution, not the
  reference) — so assert instead that the `install_essentials` install line
  carries `--inputs-from` and `--no-update-lock-file`.
- **Runtime provenance evidence — artifact contract (rewritten in pass 5;
  the earlier spec was unimplementable)** — a post-boot `nix profile list`
  cannot work: the remount shadows `/nix/var`, so root's profile metadata
  is absent or stale afterwards (see confirmed facts). The evidence is
  captured **before the remount** by `install_essentials`, under this
  contract:
  - **Location and lifetime**: `/persist/.dx/essentials-provenance/`.
    `/persist` is mounted before bootstrap runs (the launch command
    creates it) and is the only guest-writable location that survives
    both container restarts and `dx-sync-bootstrap`'s wipe of
    `/guest-bootstrap`, which deletes dotfiles too (see confirmed facts).
    Nothing under `/guest-bootstrap` may be treated as persistent, and
    `bootstrap.sh` must not reference `$DX_BOOTSTRAP_PATH` (never
    forwarded to the guest; `set -u` would abort) — it uses the literal
    `/persist` path and its own script directory.
  - **Shape**: two files, sidestepping the earlier spec's invalid-JSON
    concatenation — `profile.json` (raw `nix profile list --json` output)
    and `meta.env` (shell-parseable `key=value`:
    `state=installed|repinned|skipped`, a timestamp, the locked nixpkgs
    revision the state was established against, the resolved
    `readlink -f /root/.nix-profile/bin` path, and the image's
    `nix --version` output — captured here, pre-remount, `nix` always
    resolves to the image binary because root's profile never contains
    `nix` (see confirmed facts); this is the alignment rule's runtime
    evidence). Both files are written atomically (temp file + `mv`
    within `/persist`).
  - **Every gate outcome writes**: install and repin overwrite both
    files; the skip branch (the common case — every warm restart)
    rewrites only `meta.env` with `state=skipped`, **after** validating
    the retained `profile.json` against the current lock — a skip is only
    ever declared over verified evidence. That retained evidence is what
    proves the skip branch safe: the skipped tools *are* the previous
    install's store paths, whose provenance was recorded when they were
    installed (or repinned).
  - **Access**: read with `container exec "$DX_CONTAINER_NAME" cat …` —
    there is no `dx-exec` helper (see confirmed facts).
  - **Validation**: compare the locked nixpkgs revision recorded in
    `profile.json` against `nodes.nixpkgs.locked.rev` in
    `/guest-bootstrap/flake.lock`; cross-check that the recorded store
    paths match `nix eval` of the same attributes with
    `--inputs-from /guest-bootstrap` run post-boot, making the evidence
    self-validating rather than trusted. Additionally checksum
    `flake.lock` before and after bootstrap — equality proves
    `--no-update-lock-file` actually held (pass 6). Tests cover all four
    gate outcomes (change 8).

What's not acceptable is the current silent dependence on unstable while
the docs claim the pin lives in `flake.nix`.

## Bumping the Nix pin (`nix` flavor maintenance)

Pinning motivates itself with one-way store-schema migrations — but every
future `nixos/nix` pin still reuses `dx-nix-official`, so a careless bump
recreates the exact hazard the pin exists to prevent. There is also a build
cache trap: `dx-create-image` skips the build while the local image name
exists, so editing `Containerfile.nix` alone changes **nothing** until the
old local image is removed. This procedure is an acceptance criterion for
every future pin bump, not just a risk-list entry:

1. Update the pin in `Containerfile.nix` (tag and, if adopted, the
   manifest-list digest — change 1).
2. Stop or destroy **every** container referencing the official image —
   dx-host and any side containers — then remove the stale local image
   (`container image rm dx-nixos-25.11-official`) so the next
   `dx-create-image` actually rebuilds. Apple `container` refuses to
   delete an image referenced by a running container, so the step must
   fail clearly if a reference remains — never assume the `rm` succeeded.
   (Versioning the image name instead was considered and rejected: it
   multiplies names across guard lists and tests for a rare maintenance
   event.)
3. Validate the new image against a **fresh** volume: run the full
   per-flavor checklist in an isolated profile whose `DX_NIX_VOLUME` is a
   throwaway, never the real `dx-nix-official`. This includes the
   pristine `nix --version` pre-flight against the new exact reference
   (the alignment rule's authoritative image check).
4. **Store-transition gate** — fresh-volume validation proves clean
   installation, not compatibility with a store the old Nix created. Test
   the hazardous transition directly, on a disposable volume:

   ```text
   old image seeds/populates throwaway volume
       → new image boots against that volume and mutates it
         (profile install/remove, GC, a workload)
       → old image boots the same volume again (the rollback path)
   ```

   Run profile and store operations at every stage. Release notes between
   the two versions (store SQLite schema, profile-manifest format) are
   advisory input, not the gate — the transition test is. If the rollback
   stage fails, the bump is one-way: proceed only deliberately, accepting
   that rollback to the older Nix against the real volume becomes
   unsupported (Apple `container` offers no volume snapshot; the
   alternative is recreating the volume and re-downloading).
5. Rollback statement: reverting the pin plus repeating step 2 restores the
   old image; the persisted volume remains rollback-safe only if step 4's
   rollback stage passed.

Backups: do **not** add a host-side `tar`/`cp -a` of the volume's backing
file as a pre-bump safety step (rejected, pass 6) — Apple `container`
documents no cold-copy contract, and copying a mounted filesystem image
can yield an unusable archive. The store-transition gate above *is* the
rollback proof; revisit backups only after an export-and-restore drill
proves one works.

## Single-source release pin and the default flip

Decided 2026-07-02 (this section is mirrored by the README's "Release and
Pin Maintenance" section, written ahead of implementation — keep the two in
sync as changes land).

**The release pin lives in one file.** The guest flake's inputs
(`flake.nix`: `nixpkgs` → `nixos-25.11`, `nixvim` → `nixos-25.11`,
`home-manager` → `release-25.11`, the latter two following this flake's
`nixpkgs`) are the only place a NixOS release is *pinned*; `flake.lock`
records the concrete revisions. Everything downstream resolves from the
lock: the guest toolset (Home Manager activation) and, once change 10
lands, the root bootstrap essentials (`--inputs-from`). Release strings
appearing anywhere else — the context directory name, the
`dx-nixos-25.11*` image names — are identity labels refreshed during a
release bump, not pins. A release bump under the `nix` flavor is: edit the
branch refs in `flake.nix` (one file, one commit), `nix flake update` (in
the guest or anywhere with Nix — the macOS host deliberately has none),
check the alignment rule, revalidate.

**Image-tag alignment rule.** `Containerfile.nix`'s tag is derived, not
chosen: match the major.minor of the pinned release's default Nix
(`nixpkgs#nix.version` at the locked revision, i.e. `nixVersions.stable`),
newest patch tag within that minor, digest per change 1. This folds the
Nix-version bump into the release bump as one deliberate, procedure-gated
event (the bump procedure above), while still allowing an out-of-band
same-minor bump for security fixes.

**How the rule is asserted (corrected in pass 6 — the original in-guest
check was tautological)**: `dxPackages` ships `nix` and guest sessions put
`/home/dx/.nix-profile/bin` first on `PATH` (see confirmed facts), so a
post-activation `nix --version` reports the *locked* Nix — both sides of
the old comparison resolved from the same lock and would agree even under
a wrong image tag. The assertion instead uses two image-faithful
measurements:

- **Pre-flight (authoritative)**: `nix --version` in the pristine image,
  run against the exact reference that will land — the tag-plus-digest
  form, not the mutable tag alone (checklist item).
- **Bootstrap evidence**: the `nix --version` recorded in change 10's
  `meta.env`, captured pre-remount where `nix` always resolves to the
  image binary. Its major.minor must match the tag in `Containerfile.nix`
  and `nix eval --raw --inputs-from /guest-bootstrap nixpkgs#nix.version`
  — run in the guest via `container exec` (the macOS host deliberately
  has no Nix; pass 7).

The post-activation in-guest `nix --version` may still be checked — but
only as a guest-package check (the locked toolset installed correctly),
never described as an image-version check.

Rejected mechanisms for full automation: templating the `FROM` line via
`ARG` (breaks the one-non-blank-line invariant, needs Nix on the macOS
host to evaluate the version at build time, and Apple `container` `ARG`
support is unverified); building the base image ourselves from the flake
(requires external build infrastructure — a different project). The
alignment is enforced by the two image-faithful checks above and the bump
procedure, not by templating. Honest caveat: the image's seed store (built by upstream
against whatever nixpkgs they used) is merged onto the volume and remains
present as inert paths; every tool referenced after bootstrap resolves
through the lock.

**Default flip (final step).** After both flavors pass the full checklist
and the transition test, flip the `DX_BASE` default from `flakes` to `nix`
in `dx-lib.sh`, updating README, `plan.md`, and the `default.env` comment
in the same change. Deployments on the **reserved defaults** then hit
change 4's guard on their next `./bin/dx` (resolved names no longer match
the running container) and are walked through the standard switch
procedure — a fail-closed migration, never a silent flavor change.

That fail-closed claim holds **only** for reserved-default deployments
(narrowed in pass 6). A profile with custom `DX_IMAGE`/`DX_NIX_VOLUME`
names and no explicit `DX_BASE` — the shipped `dx-test.env` and
`dx-tinty.env` are exactly this shape (see confirmed facts) — dodges every
guard after the flip: `dx-create-image` skips because the custom image
already exists (built from the `flakes` base), and change 4 compares the
same custom names on both sides and passes. The result is `flakes`-based
resources silently running under what the operator believes is the `nix`
default. The optional change-4 label helps only containers created after
the feature lands; it cannot identify pre-feature images or containers.

**Flip preconditions** (all land before the default changes):

- every shipped profile that sets a custom `DX_IMAGE` or `DX_NIX_VOLUME`
  declares `DX_BASE` explicitly — pin `dx-test.env` and `dx-tinty.env` to
  `DX_BASE=flakes` to freeze their current behavior; moving any of them
  to `nix` is a separate, deliberate change that rebuilds the custom
  image and recreates the container;
- a test enforces that declaration for every profile under
  `tests/profiles/` (change 8);
- the README documents the same pin-or-migrate requirement for
  user-maintained custom-name profiles (change 9).

The slice-1 no-regression guarantee (unset `DX_BASE` → flakes names)
deliberately inverts at this point; the flip's own validation is the
transition test plus a fresh-deployment run with `DX_BASE` unset resolving
`nix` defaults.

## Switching flavors on an existing deployment

Switching is not hot (the container references the old image), but with
per-flavor Nix volumes it is **non-destructive** — there is deliberately no
step that deletes a volume, because the only existing volume-cleanup path
(`dx-destroy-volumes`) removes `/persist` along with the store and no
precise nix-only reset exists:

1. `./bin/dx-destroy-container` (container only). The image names are
   per-flavor, so the flavors' images never collide and both can coexist;
   destroying the image too (`./bin/dx-destroy`) works but forces a needless
   rebuild/re-pull when switching back.
2. In `.env`: set `DX_BASE=nix`, and **remove or update any explicit
   `DX_IMAGE`, `DX_NIX_VOLUME`, or `DX_CONTAINERFILE` entries** — the
   change-2 guard rejects the opposite flavor's reserved defaults for all
   three outright, but custom values are the owner's responsibility to
   keep flavor-consistent.
   Then `./bin/dx`. Prefer `.env` over a one-shot `DX_BASE=nix ./bin/dx`
   (which works once change 7 lands, but doesn't persist): the flavor must
   stay in force for *every* later `dx-*` invocation — after a one-shot
   switch, a bare `./bin/dx-gc`, `dx-reclaim`, `dx-status`, or
   `dx-destroy-volumes` resolves default-flavor names against a nix-flavor
   deployment, which is the destroy-guard's leaked-env hazard in reverse.
   (Profile runs override `.env` once change 7 lands — that is what keeps
   isolated validation possible alongside a switched `.env`.) Bootstrap
   seeds the flavor's own store volume (`dx-nix-official`) from the new
   base on first boot; the old flavor's `dx-nix` volume is untouched, and
   switching back is the same two steps with the `.env` line set to
   `flakes` (or removed).

A missed step 1 no longer runs the wrong flavor silently: change 4 makes
`./bin/dx` fail closed on the image/volume mismatch and print step 1.

Notes:

- Both flavors share `DX_CONTAINER_NAME=dx-host` and the SSH port: images
  and volumes coexist, but only one flavor's container can exist or run at
  a time. Step 1 is what frees the name.
- `/persist` is shared across flavors: gh/AI credentials and `/persist`
  data carry over. Profiles live in the per-flavor store, so the AI-tools
  opt-in (`dx-ai`) must be re-run once per flavor.
- The first boot after a switch also repins the root bootstrap
  essentials: change 10's evidence on the shared `/persist` records the
  other flavor's store paths, so the gate reinstalls and rewrites it.
  Expected, and cheap next to the store seed itself.
- Reclaiming the unused flavor's store space is a separate, manual,
  destructive act (`container volume rm <volume>` while no container
  references it) — never part of the switch procedure. If a nix-only reset
  becomes a recurring need, add a dedicated guarded script rather than
  widening `dx-destroy-volumes`.

## Validation checklist

Pre-flight, before any repo changes — prove the official image can run the
bootstrap entry path (`--entrypoint sh` → kernel shebang → `env` → `bash` on
the image's default `PATH`, all before `install_essentials` runs;
`dx-create-container` always passes `--entrypoint sh`, so the images'
default entrypoints are irrelevant):

- [ ] `container run --rm nixos/nix:2.31.5 /usr/bin/env bash -c 'echo ok'`
- [ ] `container run --rm --entrypoint sh nixos/nix:2.31.5 -c 'printf "#!/usr/bin/env bash\necho shebang-ok\n" > /tmp/t && chmod +x /tmp/t && exec /tmp/t'`
- [ ] The same two checks against the **pristine** flakes base
      (`nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`) — this is the proof
      the `#!/usr/bin/env bash` shebang works there pre-bootstrap; guest
      scripts running in an installed guest do not establish it (change 5).
- [ ] `container run --rm <exact pinned reference> nix --version` reports
      the tag's version — run against the tag-plus-digest form that will
      land, not the mutable tag alone (the alignment rule's authoritative
      image check; pass 6 — a post-activation in-guest check cannot
      verify this, see the single-source section).
- [ ] `container inspect` on an existing container exposes its image
      reference and volume mounts in a form change 4 can parse. Record the
      supported `container` version, capture a sanitized real response as
      the test fixture, and note the exact fields plus the comparison and
      named-volume-vs-bind semantics here (change 4's inspection
      contract). If it cannot, change 4 falls back to a marker.
- [ ] `container create` accepts labels and `container inspect` surfaces
      them (change 4's optional flavor label; drop the label feature if
      unsupported).
- [ ] `nix profile install --inputs-from <payload dir>
      --no-update-lock-file` resolves through the payload's lock with
      root's pre-volume nix on **both** bases (change 10's required gate;
      only its failure activates the immutable-rev fallback).
- [ ] If the digest pin (change 1) is to be adopted: `container build`
      accepts a `FROM nixos/nix:<tag>@sha256:…` reference, and the recorded
      digest is the manifest-list digest for the tag.

For **each** flavor, from a fresh per-flavor Nix volume. Run the `nix`
flavor in an isolated profile rather than against the primary `dx-host`,
which the two flavors would otherwise have to share (see the
switch-procedure note): add `tests/profiles/dx-official.env` on the
`dx-test.env` pattern — namespaced container name, SSH port, volumes, and
keys, plus `DX_BASE=nix`. This isolation depends on change 7; without it, a
`DX_BASE` (or any `DX_*`) line in `.env` silently overrides the profile.

- [ ] `./bin/dx` completes bootstrap; sshd reachable; `dx-enter` works.
- [ ] `tests/run_all_tests.sh` passes.
- [ ] The provenance artifact under `/persist/.dx/essentials-provenance/`
      records the `nixpkgs` revision from `/guest-bootstrap/flake.lock`,
      its recorded store paths match a post-boot
      `nix eval --inputs-from /guest-bootstrap` cross-check, a warm
      restart flips `meta.env` to `skipped` while preserving
      `profile.json`, a lock bump followed by a restart repins and
      refreshes both files, and `flake.lock`'s checksum is unchanged
      across bootstrap (change 10's runtime assertions; read via
      `container exec`).
- [ ] `nix profile list` output still matches the
      `Flake attribute:\s+packages\.<sys>\.ai-tools` grep in
      `configure_guest` (`bootstrap.sh:539`; version-sensitive scrape;
      Nix 2.31 confirmed OK, re-verify on any future Nix tag bump).
- [ ] (`nix` flavor) The alignment rule holds: the image Nix version
      recorded in `meta.env` (change 10) matches `Containerfile.nix`'s
      tag, and its major.minor equals
      `nix eval --raw --inputs-from /guest-bootstrap nixpkgs#nix.version`
      major.minor (run in the guest via `container exec`; the host has
      no Nix). The post-activation in-guest `nix --version` is
      checked only as a guest-package check — it reports the locked Nix,
      never the image's (see the single-source section).
- [ ] AI-tools opt-in path (`dx-ai`, keyring, persistence links) works.
- [ ] Timezone, persist links, gh persistence intact after
      `dx-destroy && dx` (volume reuse within the same flavor).

Flavor-transition acceptance test (the feature's central state transition —
the per-flavor runs above never exercise it). A single `dx-test.env`-style
profile **cannot** drive it (pass 6): such a profile fixes one custom
`DX_IMAGE`/`DX_NIX_VOLUME` pair, so changing `DX_BASE` alone selects no
different names — the same custom image and store would be reused across
both stages, exactly the hybrid the test exists to rule out. The fixture
is **two environment sets** sharing the namespaced container name, persist
volume, bootstrap volume, SSH port, and key paths, but with distinct
flavor-specific `DX_IMAGE` and `DX_NIX_VOLUME` values and
`DX_BASE=flakes` vs `DX_BASE=nix`; `DX_CONTAINERFILE` stays unset in both
so the selector itself is exercised. Before stage 1, assert the two sets'
image and volume values actually differ. (Default-name derivation is
deliberately not covered here — the flip validation's fresh-deployment
run covers it.) Run:

```text
flakes → destroy container only → nix → destroy container only → flakes
```

- [ ] At each stage: the container's configured image and Nix volume (via
      `container inspect`) match the active flavor; the **other** flavor's
      volume still exists and its sentinel file (written on first boot of
      that flavor) is unchanged; a sentinel in `/persist` survives every
      stage.
- [ ] At each flavor switch: the target flavor's first boot rewrites the
      shared provenance evidence (`state=installed` or `repinned`, never
      `skipped` over the other flavor's store paths), and a subsequent
      warm restart of the same flavor records `state=skipped` (change
      10's flavor-switch behavior).
- [ ] Attempting stage 2 or 4 *without* the destroy step — running under
      the other stage's environment set — fails closed at change 4's
      inspect-based reuse check, naming the switch command.
- [ ] Separately: a stale opposite-flavor reserved override (`DX_IMAGE`,
      `DX_NIX_VOLUME`, or `DX_CONTAINERFILE`) fails earlier, at change 2's
      `dx-lib.sh` guard. Two assertions at two layers — one early failure
      must not mask missing coverage of the other.

And once, with `DX_BASE` entirely unset — the no-regression guarantee for
existing deployments, stated as observable compatibility (a rebuilt image
from a remote base is never literally byte-identical). This guarantee
belongs to slice 1, while `flakes` is still the default; the later default
flip deliberately inverts it (see the single-source section):

- [ ] A full run confirming: resolved defaults unchanged (`dx-nixos-25.11`,
      `dx-nix`, `Containerfile` selected), and runtime behavior matching the
      per-flavor checklist. Live coverage, not just the static section-9
      checks.

## Decisions

All previously open items are resolved; rationale in one line each (full
chronology in git history):

- **Side-container flavor identity** — structural per-flavor volume names
  (change 6); markers are diagnostics only, never the isolation boundary
  (deletable host cache) and never a `--destroy` blocker. Folding the
  flavor into the derived *container* name was rejected: it would orphan
  every existing side container's volumes and keys.
- **Flavor naming token** — `-official` (`dx-nix-official`,
  `dx-nixos-25.11-official`, `$DX_CONTAINER_NAME-nix-official`): in
  `dx-nix`, "nix" already means "the Nix store volume", so a `-nix` suffix
  would read `dx-nix-nix`. `DX_BASE=nix` and `Containerfile.nix` keep their
  names — the flavor *value* names the base-image family, and neither
  appears where the ambiguity bites.
- **`.env` precedence contract** — process environment always wins,
  implemented generally in `dx-lib.sh` (change 7); the `DX_SKIP_ENV_FILE`
  flag approach is dropped as not implementing the stated order.
- **Containerfile reference format** — `nixos/nix:<version>` or
  `nixos/nix:<version>@sha256:<manifest-list digest>`; digest-only rejected
  (change 1).
- **`DX_CONTAINERFILE`** — public override with the standard `DX_*`
  contract; `dx-create-image` requires it to be a regular file (change 2).
- **Cross-flavor guard scope** — all three reserved defaults (`DX_IMAGE`,
  `DX_NIX_VOLUME`, `DX_CONTAINERFILE`) rejected in both directions; the
  Containerfile is included because it is the one override where the name
  can lie about the content (pass 5).
- **Bootstrap-pin fallback** — an immutable 40-char revision that must
  equal `nodes.nixpkgs.locked.rev`, sync-asserted by test; a release
  branch is not a pin. `--inputs-from` viability is a required pre-flight
  gate, so the fallback is only ever chosen deliberately.
- **Provenance artifact** — `/persist/.dx/essentials-provenance/`
  (`profile.json` + `meta.env`), written by every gate outcome
  (install/repin/skip, per pass 6); `/guest-bootstrap` is wiped on every
  sync and is never a persistence location.
- **Precedence claim scope** — env-wins applies to exported `DX_*`
  variables only; `DX_ENV_FILE` (a process-environment-only knob) is the
  test seam.
- **Digest pin** — adopted (2026-07-02); the pre-flight gates feasibility
  only, with tag-only plus recorded residual risk as the failure path.
- **`test_section13_final_review.sh`** — covers both Containerfile
  variants (2026-07-02).
- **Default flavor** — `nix` becomes the default after both-flavor
  validation and the transition test, via the staged flip in the
  single-source section; `flakes` remains supported (2026-07-02).
- **Image-tag alignment rule** — the `nixos/nix` tag follows the pinned
  release's default Nix major.minor, asserted at runtime; enforced by
  procedure and test, not Containerfile templating (2026-07-02).
- **Delivery** — two slices (core + safety invariants, then independent
  hardening), with the default flip as a third, final step (2026-07-02).
- **Essentials gate (change 10)** — evidence-based, not `useradd`: skip
  only over validated evidence matching the current lock; missing/stale
  evidence repins in place. Fail-and-recreate rejected — it refuses boot
  on every existing container at rollout and on every out-of-band
  re-lock (2026-07-02, pass 6).
- **Alignment-rule evidence** — pristine pre-flight against the exact
  pinned reference plus the pre-remount `nix --version` in `meta.env`;
  the post-activation check is a guest-package check only, since the
  guest profile ships the locked `nix` (pass 6).
- **Transition fixture** — two flavor-specific env sets sharing
  container/persist/bootstrap/port/keys, distinct image and volume
  values (asserted distinct up front), `DX_CONTAINERFILE` unset
  (pass 6).
- **Flip preconditions** — shipped custom-name profiles pin `DX_BASE`,
  test-enforced; the fail-closed-migration claim is scoped to
  reserved-default deployments (pass 6).
- **`DX_CONTAINERFILE` guard comparison** — normalized path plus file
  identity (`-ef`), never bare string equality (pass 6).
- **Digest test assertion** — slice-exact, never optional in the regex
  (pass 6).
- **Guard failure modes (change 4)** — verified mismatch and
  cannot-verify get distinct errors; only the mismatch error recommends
  destroy; no bypass knob; fixture tests plus one live inspect smoke
  test (pass 6).
- **`--print-env`** — includes `DX_BASE` and `DX_CONTAINERFILE`; printed
  profiles are flavor-self-contained (pass 6).
- **Volume backing-file backups** — rejected until an export/restore
  drill proves one; the store-transition gate is the rollback proof
  (pass 6).
- **Change-6 step-4 guard semantics** — reserved derived names are
  skipped with a warning during `--destroy`, never an abort that strands
  key/marker cleanup (pass 7).
- **Reserved-Containerfile scope** — evaluated against the resolved
  `DX_CONTEXT_DIR`; the file names are the contract in every context
  directory, and rejection fires only on the opposite flavor's file
  (pass 7).
- **Evidence across flavor switches** — not flavor-keyed (bootstrap
  cannot learn the flavor); a switch repins on the target flavor's first
  boot; repin tolerates an empty root profile; the install-vs-repin fork
  keys on prior-install presence (pass 7).

## Risks / trade-offs accepted

- Two Containerfiles can drift apart conceptually; mitigated by section-2
  tests pinning their exact shape (one FROM line each).
- Under `nix`, the Nix tool version is decoupled from the NixOS release:
  bumping it is a manual chore governed by the
  [bump procedure](#bumping-the-nix-pin-nix-flavor-maintenance); tracking
  it too eagerly risks one-way store-schema migrations on the persisted
  volume. If the digest pin (change 1) is not adopted, the version tag
  remains mutable upstream — accepted only with that recorded here.
- Under `flakes`, the existing third-party tag-availability gate remains;
  this plan does not remove the flavor, only the dependence on it.
- Per-flavor Nix volumes double store disk usage while both flavors exist on
  one host (for dx-host and for any side container used under both flavors).
  Accepted: it buys non-destructive switching and rollback; the unused
  volume can be removed manually — or via `dx-mount --destroy`, which
  cleans both side-container variants — once a flavor decision sticks.
  A useful follow-up before any new destructive cleanup command: report
  both flavor volumes and their sizes in status/maintenance output
  (pass 6; not a prerequisite).
- The change-7 precedence fix alters behavior for anyone relying on `.env`
  overriding an exported shell variable or a profile run; judged unlikely
  to be depended on, matches dotenv convention, and the old behavior
  defeats profile isolation outright (and corrupts `dx-mount`'s derived
  names today).
- Explicit non-reserved `DX_IMAGE`/`DX_NIX_VOLUME`/`DX_CONTAINERFILE`
  overrides can still mix flavors; the change-2 guard blocks only the
  reserved defaults. Accepted and documented as an advanced responsibility.
- Change 4 depends on `container inspect` exposing image and mounts, whose
  field schema is undocumented upstream: the guard is built against a
  recorded `container` version and a real captured fixture, and fails
  closed on unparseable output. The marker fallback is weaker (deletable
  cache) and is taken only if inspection proves impossible. The guard's
  scope is deliberately narrow — image and Nix volume only; other
  create-time settings (persist/bootstrap mounts, ports, memory, CPUs)
  can still drift and are accepted as out of scope.
- Pre-feature images and containers carry no flavor label; after the
  default flip, identifying what a custom-name resource was built from
  relies on the `DX_BASE` pinned in its profile and on operator
  knowledge. Mitigated by the flip preconditions for shipped profiles;
  accepted for user-maintained profiles that ignore the documented
  pin-or-migrate requirement.
- Line-number references in this plan go stale (seven passes running);
  where practical they are anchored to function names
  (`install_essentials`, `setup_nix_volume`, `create_user`,
  `configure_guest`, `refuse_default_destroy`) with line numbers only as a
  convenience, and any remaining numbers must be re-verified at
  implementation time.
