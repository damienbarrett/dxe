# Plan: Support Both Base Images (`nixpkgs/nix-flakes` and `nixos/nix`)

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

> Reviewed 2026-06-11 against the working tree; the review's corrections
> (dead `dx-mount:158` default, cheaper switch procedure, `DX_CONTAINERFILE`
> ordering, unconditional destroy guard, test touch points, line-number
> refresh) are folded in below. Two items remain explicitly open decisions —
> see [Open decisions](#open-decisions).

## Confirmed facts this plan is built on

Verified against the running `dx-host` container and `NixOS/nix` `docker.nix`
(2026-06-10):

- Current base provides `/bin/bash`, `/bin/sh`, `/bin/env`. The official
  `nixos/nix` image provides only `/bin/sh` (→ bash) and `/usr/bin/env` —
  **no `/bin/bash`**.
- Neither image pins the flake registry: `nixpkgs#…` in `install_essentials`
  resolves to `nixpkgs-unstable` via the global registry **today**. Switching
  bases changes nothing here; change 7 below turns this from an accident into
  an explicit decision.
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
- Running guest Nix is 2.31.4; pinning `nixos/nix:2.31.5` minimizes Nix
  version drift at switch time.
- `container build` supports `-f <path>` to select a Containerfile.

## Changes

### 1. Containerfile variants (one `FROM` line each)

In `container/aarch64-darwin-apple-container-dx-nixos-25.11/`:

- `Containerfile` — unchanged: `FROM nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`
- `Containerfile.nix` — new: `FROM nixos/nix:2.31.5`

Pin an explicit Nix version tag, never `latest` (a newer Nix can one-way
migrate the store SQLite schema and profile manifest format on the persisted
dx-nix volume, breaking rollback). Bumping the Nix pin becomes its own,
deliberate maintenance task.

### 2. Flavor selector in `bin/dx-lib.sh`

- `DX_BASE="${DX_BASE:-flakes}"` — allowed values `flakes` | `nix`; reject
  anything else with a clear error.
- `DX_CONTAINERFILE` — `$DX_CONTEXT_DIR/Containerfile` for `flakes`,
  `$DX_CONTEXT_DIR/Containerfile.nix` for `nix`.
- Flavor-specific `DX_IMAGE` default: keep `dx-nixos-25.11` for `flakes`
  (no behavior change), use `dx-nixos-25.11-nix` for `nix`. Distinct names
  are required because `dx-create-image` skips the build when the image
  already exists — a shared name would silently reuse the other flavor's
  image.
- Flavor-specific `DX_NIX_VOLUME` default: keep `dx-nix` for `flakes`, use
  `dx-nix-nix` for `nix`. Each flavor then seeds and owns its own store
  volume: no hybrid store, and switching flavors never requires deleting a
  volume. `/persist` (and the bootstrap volume) stay shared. The new default
  must also be added to `dx-mount`'s `refuse_default_destroy` guard list
  (`bin/dx-mount:217`) — and the guard must refuse **both** `dx-nix` and
  `dx-nix-nix` unconditionally, regardless of the active `DX_BASE`, because
  the guard exists precisely for leaked-env cases where `DX_BASE` itself may
  be leaked. Extend the guard test at `tests/test_section18_mount_git.sh:204`
  (currently exercising `DX_NIX_VOLUME=dx-nix`) with a `dx-nix-nix` case.
- **Ordering matters**: the `DX_BASE` validation and flavor-default
  computation must run *before* the existing eager defaults at
  `bin/dx-lib.sh:27` (`DX_IMAGE`) and `:37` (`DX_NIX_VOLUME`), with those
  lines becoming `"${DX_IMAGE:-$flavor_default}"`. The `:-` expansion
  already preserves user overrides (including `.env`, which is sourced
  before the defaults block) — no extra was-it-user-set bookkeeping is
  needed, but a flavor default assigned *after* line 27 would silently never
  take effect.
- **Split the flavor block in two**: `DX_CONTAINERFILE` is derived from
  `DX_CONTEXT_DIR`, which is only defaulted at `dx-lib.sh:32`. So the
  `DX_BASE` validation plus image/volume flavor defaults go before line 27,
  and the `DX_CONTAINERFILE` assignment goes after line 32 — otherwise it
  references an unset variable under `set -u`.
- `bin/dx-mount` needs no mirroring: it sources `dx-lib.sh` (line 13), which
  unconditionally exports `DX_IMAGE`, so the duplicate default at
  `dx-mount:158` is dead code that can never fall back to its literal.
  Delete that line as part of this change; the flavor logic in `dx-lib.sh`
  alone covers `dx-mount`.

### 3. `bin/dx-create-image`

Pass the selected file: `container build -t "$DX_IMAGE" -f "$DX_CONTAINERFILE" "$DX_CONTEXT_DIR"`.

### 4. Make `bootstrap.sh` base-agnostic

Both changes work on both images:

- Line 1: `#!/bin/bash` → `#!/usr/bin/env bash`. On `nixos/nix` the current
  shebang fails with ENOENT when the entrypoint loop `exec`s the script —
  this is the single hard breakage of the switch. (`/usr/bin/env` is proven
  present on the flakes base too: all seven guest scripts in
  `container/.../scripts/` already use `#!/usr/bin/env bash` and run in
  today's guest; the pre-flight checklist still exercises it explicitly.)
- Line 151: `useradd -m -g dx -s /bin/bash dx` → `-s /bin/sh`. `/bin/sh`
  exists in both images; the shell is switched to nushell at the end of
  `configure_guest` anyway, so `/bin/sh` is only the fallback when nu is
  missing.
- While touching `setup_nix_volume`, optionally make the mkfs filesystem
  label per-flavor (it hardcodes `-L dx-nix` at `bootstrap.sh:60,67`).
  Harmless today since only one volume is attached per guest, but free to
  disambiguate while in there.

No other `/bin/bash` references exist in the guest payload (verified by
grep).

### 5. Tests

- `tests/test_section2_containerfile.sh` / `tests/test_helpers.sh`: run the
  existing assertions over **both** Containerfile variants (loop over
  `Containerfile` and `Containerfile.nix`); each must be exactly one
  non-blank `FROM` line. `tests/test_helpers.sh:26` defines a single
  `CONTAINERFILE` variable, so the loop needs a helper change (e.g. a
  `CONTAINERFILE_NIX` sibling or a list).
- Add assertions: `Containerfile` is FROM `nixpkgs/nix-flakes:`,
  `Containerfile.nix` is FROM `nixos/nix:` with an explicit version tag
  (reject `:latest`).
- `tests/test_section13_final_review.sh:49` also asserts on `$CONTAINERFILE`;
  either cover both variants there or keep it deliberately default-only —
  decide explicitly, don't leave it implicit.
- `tests/test_section9_host_scripts.sh`: cover `DX_BASE` validation
  (bad value → error; `nix` → `Containerfile.nix` + `dx-nixos-25.11-nix` +
  `dx-nix-nix`; explicit `DX_IMAGE`/`DX_NIX_VOLUME` still win under
  `DX_BASE=nix`).
- `tests/test_section10_docs.sh`: assert the README documents `DX_BASE`,
  matching the established pattern of doc requirements having test coverage.
- Runtime suites (sections 11/12, tools, etc.) are flavor-relative already;
  document that a full `run_all_tests.sh` pass is required once per flavor
  before declaring the feature done.

### 6. Docs

- `README.md`: document `DX_BASE` (values, defaults, image-name implications)
  next to the existing "Lightweight Host" note; state the switch procedure
  (below).
- `plan.md`: note that the 26.05 base-image gate
  (`nixpkgs/nix-flakes:nixos-26.05-aarch64-linux` must exist) applies only to
  the `flakes` flavor; under `nix` the release bump is purely `flake.nix`
  (`nixos-26.05` inputs) plus revalidation. Also update the release-bump
  playbook's `OLD_IMAGE`/`NEW_IMAGE` definitions, which are keyed by release
  name only and need flavor variants once two flavors exist. (A forward
  pointer to this plan was added to `plan.md` on 2026-06-12.)

### 7. Bootstrap nixpkgs pin (decision)

`install_essentials` installs root bootstrap tools from `nixpkgs#…`, which
resolves through the global flake registry to nixpkgs-unstable — on both
flavors, today included. That conflicts with the stated goal of the release
pin living in `flake.nix`. Pick one:

- **Pin via the locked flake (recommended)**: use
  `nix profile install --inputs-from /guest-bootstrap nixpkgs#shadow …`.
  `bootstrap.sh` executes from `/guest-bootstrap`, next to `flake.nix` and
  `flake.lock`, and the payload is fully synced before bootstrap runs (the
  launch loop waits for `.dx-bootstrap-ready`). This resolves `nixpkgs` to
  the locked revision — the pin then genuinely lives only in
  `flake.nix`/`flake.lock`, with no new release-bump checklist item and
  better reproducibility than a branch name. Validate once that
  `--inputs-from` works with root's pre-volume nix on both bases.
- **Pin via a variable (fallback)** if `--inputs-from` doesn't work
  pre-volume: replace the bare `nixpkgs#` references with a single variable
  at the top of `bootstrap.sh`, e.g.
  `DX_BOOTSTRAP_NIXPKGS="github:nixos/nixpkgs/nixos-25.11"`, used as
  `$DX_BOOTSTRAP_NIXPKGS#shadow` etc. Add it to the release-bump checklist
  alongside the `flake.nix` inputs.
- **Accept drift**: these are throwaway pre-mount root tools (shadow, sudo,
  tar, …) that are hidden once the volume mounts; record that in
  `bootstrap.sh` as a comment and in `plan.md`.

Whichever pin option lands, add a section-3 test asserting `bootstrap.sh`
contains no bare `nixpkgs#` reference. What's not acceptable is the current
silent dependence on unstable while the docs claim the pin lives in
`flake.nix`.

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
2. `DX_BASE=nix ./bin/dx` (or set `DX_BASE=nix` in `.env`). Bootstrap seeds
   the flavor's own store volume (`dx-nix-nix`) from the new base on first
   boot; the old flavor's `dx-nix` volume is untouched and switching back is
   the same two steps with `DX_BASE=flakes`.

Notes:

- `/persist` is shared across flavors: gh/AI credentials and `/persist`
  data carry over. Profiles live in the per-flavor store, so the AI-tools
  opt-in (`dx-ai`) must be re-run once per flavor.
- Reclaiming the unused flavor's store space is a separate, manual,
  destructive act (`container volume rm <volume>` while no container
  references it) — never part of the switch procedure. If a nix-only reset
  becomes a recurring need, add a dedicated guarded script rather than
  widening `dx-destroy-volumes`.

## Validation checklist

Pre-flight, before any repo changes — prove the official image can launch
the bootstrap entry path (entrypoint `sh` → kernel shebang → `env` → `bash`
on the image's default `PATH`, all before `install_essentials` runs):

- [ ] `container run --rm nixos/nix:2.31.5 /usr/bin/env bash -c 'echo ok'`
- [ ] `container run --rm --entrypoint sh nixos/nix:2.31.5 -c 'printf "#!/usr/bin/env bash\necho shebang-ok\n" > /tmp/t && chmod +x /tmp/t && exec /tmp/t'`
- [ ] The same two checks against the flakes base
      (`nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`), so the
      `#!/usr/bin/env bash` claim is proven on both images, not inferred.

For **each** flavor, from a fresh per-flavor Nix volume:

- [ ] `./bin/dx` completes bootstrap; sshd reachable; `dx-enter` works.
- [ ] `tests/run_all_tests.sh` passes.
- [ ] `nix profile list` output still matches the
      `Flake attribute:\s+packages\.<sys>\.ai-tools` grep in
      `bootstrap.sh:410` (version-sensitive scrape; Nix 2.31 confirmed OK,
      re-verify on any future Nix tag bump).
- [ ] AI-tools opt-in path (`dx-ai`, keyring, persistence links) works.
- [ ] Timezone, persist links, gh persistence intact after
      `dx-destroy && dx` (volume reuse within the same flavor).

And once, with `DX_BASE` entirely unset:

- [ ] A full run confirming default behavior is byte-for-byte unchanged
      (default image name, volume name, Containerfile selection). The
      no-regression guarantee for existing deployments is this plan's most
      important property; give it live coverage, not just the static
      section-9 checks.

## Open decisions

- **Side-container flavor identity (must decide before implementation).**
  The "each flavor seeds and owns its own store volume: no hybrid store"
  guarantee only holds for `dx-host`. `dx-mount` side-container identities
  (`dx-mount-<slug>-<hash>`, `bin/dx-mount:124`) and their volumes
  (`$DX_CONTAINER_NAME-nix`, `bin/dx-mount:163`) do not encode the flavor.
  If a side container's container is destroyed but its volumes kept (e.g.
  via `dx-destroy-container` rather than `dx-mount --destroy`), recreating
  it under the other `DX_BASE` reuses the old flavor's seeded store — a
  mixed store. Either fold the flavor into the derived identity/name, or
  explicitly document this as an accepted limitation of the side-container
  path. (Also relevant to the seeded-Nix-base follow-up in
  [`mount-git.md`](mount-git.md).)
- **Flavor naming token (cosmetic, author's call).** `dx-nix-nix` and
  `dx-nixos-25.11-nix` overload "nix": in `dx-nix` it means "the Nix store
  volume", while the `-nix` suffix means "official nixos/nix base". A
  distinct token (e.g. `-official`: `dx-nix-official`,
  `dx-nixos-25.11-official`) reads better in `container volume list` output
  and in destroy-guard error messages.

## Risks / trade-offs accepted

- Two Containerfiles can drift apart conceptually; mitigated by section-2
  tests pinning their exact shape (one FROM line each).
- Under `nix`, the Nix tool version is decoupled from the NixOS release:
  bumping it is a new manual chore, and tracking it too eagerly risks
  one-way store-schema migrations on the persisted volume. Always pin, bump
  deliberately, validate against the checklist.
- Under `flakes`, the existing third-party tag-availability gate remains;
  this plan does not remove the flavor, only the dependence on it.
- Per-flavor Nix volumes double store disk usage while both flavors exist on
  one host. Accepted: it buys non-destructive switching and rollback; the
  unused volume can be removed manually once a flavor decision sticks.
