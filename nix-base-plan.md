# Plan: Move the Base Image to `nixos/nix` (Single Base, Fresh Rebuild)

## Goal

Replace the container base image `nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`
(community-published, per-release tags, third-party) with the official
`nixos/nix:2.31.5` image, as a plain one-way changeover:

- **One base.** No `DX_BASE` selector, no `Containerfile.nix`, no flavor
  names, no coexistence.
- **No in-place migration.** Existing machines are destroyed and rebuilt
  from scratch (decided 2026-07-03; `/persist` contents are an accepted
  one-time loss, with an auditable salvage step). There is no persisted
  cross-base state transition; the new pristine image, filesystem, and
  bootstrap path still require full validation, gated on the canary run
  below.

Motivation unchanged from [`flakes-to-nix.md`](flakes-to-nix.md): the 26.05
upgrade in `plan.md` is gated on docker-nixpkgs publishing
`nixos-26.05-aarch64-linux`, which has not happened. After this change the
docker-nixpkgs release-tag availability gate is gone. Release maintenance
is **not** thereby reduced to two flake edits: it still includes lock
regeneration, `home.stateVersion` review, the aligned Nix image-pin review,
identity-name updates (context dir, local image name), release-string test
updates, and revalidation — see `plan.md`'s playbook. And until the
bootstrap lock pin lands (follow-ups), root bootstrap essentials still
resolve through the global flake registry, not the guest lock — this plan
must not claim otherwise.

## Review history

- **2026-07-03 — initial draft**, derived from `flakes-to-nix.md` after
  its dual-base and in-place-migration requirements were dropped.
- **2026-07-03 — pass 1 (independent review, doc since removed)**
  incorporated: changeover reordered to inventory-and-referrers-first
  (F-01); section-5 `/etc/os-release` dependency replaced — verified a
  **pre-existing** live failure, the file is absent on the current guest
  too (F-02, severity reframed); Containerfile assertion switched from an
  ERE that basic-grep `assert_file_contains` cannot match to an exact
  fixed-string full-line check (F-03); direct regression assertions for
  both bootstrap edits (F-04); fresh validation redefined —
  `test_section11_validate_fresh.sh` verified to accept pre-existing
  resources (F-05); old-base detection upgraded from an ambiguous
  heuristic to an explicit-output runbook gate plus a temporary in-guest
  guard, while the review's inspect/OCI-label alternative is declined
  (F-06, see Decisions); a canary bootstrap gate added before the
  destructive primary reset (F-07); `/persist` salvage made auditable
  (F-08); the future pin-bump procedure downgraded to explicitly
  unresolved on two store-reuse defects (F-09, F-10); the release-bump
  claim narrowed (F-11); `plan.md` doc sweep widened (F-12); image-name
  versioning considered and rejected with a documentation mitigation
  (F-13); rollback's mutable-tag limitation recorded (F-14); confirmed
  facts corrected — SSL env claim verified wrong in `flakes-to-nix.md`,
  epistemic downgrades applied (F-15); `.env` isolation made a canary
  precondition (F-16); procedure steps rewritten as guarded runbook
  steps (F-17).
- **2026-07-03 — pass 2 (independent review, doc since removed)**
  incorporated, all eight findings accepted: `.env` safety widened from
  the canary to **every destructive step** — profile and `dx-mount`
  derived exports are re-clobbered when child scripts re-source `.env`,
  so cleanup itself can be misdirected; inventory upgraded to
  per-container `container inspect` (verified: `container list -a`
  shows images but not volume mounts) with deferral narrowed to
  containers referencing no affected resource; the provenance gate
  rewritten token-positive — the pass-1 snippet read *any*
  `container exec` failure as success — and extended to dangling
  symlinks; the guard gap on running containers closed with a host-side
  twin in `dx-start-container` (verified: it syncs but does not
  re-execute bootstrap when the container is already running); the
  guard and `FROM` flip made an atomic commit (the guard intentionally
  fails the flakes base); an orphaned side-container `--destroy`
  fallback added (verified: `dx-mount` requires the source directory
  and its `--container` path validates the recorded source); canary
  teardown commands corrected to executable form; the weak lock
  substring grep superseded by a mandatory in-guest `nix eval` release
  check.
- **2026-07-03 — pass 3 (independent review, doc since removed)**: five
  required corrections and three hardening items, all accepted (one via
  the reviewer's offered alternative): the pass-1 Decisions entry still
  calling the lock grep authoritative corrected — it contradicted the
  pass-2 oracle; the clean-configuration precondition widened from
  `.env` to inherited `DX_*` environment (verified: `dx-mount:5-12`
  honors pre-set values as user-supplied before sourcing the library);
  cleanup made **ledger-driven** — the inventory records every deletion
  target (custom-profile and side-container resources, keys, markers
  included) and post-cleanup verification checks the ledger, not a
  hardcoded list; the pass-2 mkdir-recreate fallback **withdrawn** (a
  recreated path can resolve into an enclosing Git root and derive a
  different container identity) in favor of a destroy-only
  `dx-mount --container` path (new change 5); the gate renamed
  **old-base exclusion** — `/bin/bash` absence excludes flakes but does
  not prove the pinned image; `--no-update-lock-file` added to the
  release-oracle eval; behavioral tests required for both guards; the
  silent-continue claim narrowed rather than guarding
  `dx-ssh`/`dx-enter` (taking the reviewer's offered alternative — see
  Decisions); the canary suite pinned to a clean committed tree
  (verified: `tests/test_section13_final_review.sh:13-18` rejects
  tracked modifications).
- **2026-07-03 — pass 4 (independent review, doc since removed)**: four
  gaps and two minor items, all accepted: side-container markers gain a
  **complete resolved resource manifest** — `dx-mount` honors
  image/volume/key overrides (`bin/dx-mount:5-12,163-186`) but records
  only source/target (`:240-244`), so change 5's derive-from-NAME could
  miss or mis-target overridden resources; legacy markers reconcile
  against the ledger, aborting on mismatch; ledger discovery extended
  to **profile files** — container inspection cannot find a profile's
  orphaned image, volumes, or keys — and shipped-profile cleanup gains
  `dx-destroy-keys` (verified: both profiles set namespaced key pairs);
  `--container NAME` gains container-safe syntax validation plus a
  recorded-name match (verified:
  `dx_require_non_reserved_container_name` rejects only the literal
  `dx-host` — `bin/dx-lib.sh:114-120` — so `/` and `..` currently
  traverse the marker pathname); residual provenance wording fixed —
  the gate token renamed `OLD_BASE_ABSENT`, the pass-1 image-name
  decision no longer credits the guard with provenance, and the
  provenance chain stated as conditional under the tag-only waiver;
  the in-guest guard gains a root-prefix test seam so behavioral tests
  need no disposable containers; the `.env` precondition tightened to
  absent-or-fully-reviewed — it is sourced as shell code, so
  non-`DX_*` lines execute too.
- **2026-07-03 — pass 5 (independent review, doc since removed)**: three
  execution gaps and two minor corrections, all accepted: cleanup
  staged **globally referrer-first** — the per-unit tools interleave
  container and resource removal (`dx-destroy` container-then-image,
  `dx-mount --destroy` container-then-volumes), so cross-unit shared
  resources could fail `rm` mid-unit; restructured as a container-only
  sweep, a verify step, then a resource sweep reusing the same tools
  (verified idempotent on missing resources: container, image, volumes,
  keys all no-op cleanly); `--print-destroy-plan` added — printing a
  deletion plan immediately before deleting allows no review, so legacy
  reconciliation becomes plan → ledger check → separate destructive
  invocation, and step 3's stale derive-from-NAME claim corrected;
  marker manifests made **write-once** — `dx-mount` rewrites its marker
  on every invocation (`bin/dx-mount:240-244`), so an attach without
  the original overrides would corrupt the cleanup record; re-entry now
  validates against the manifest and refuses on mismatch, legacy
  markers never auto-upgraded; the in-guest guard gains a guard-only
  test entry point (`DX_BOOTSTRAP_TEST_MODE=guard`, the
  `DX_FORWARD_TEST_MODE=parse` precedent) — `DX_GUARD_ROOT` alone lets
  a passing fixture continue into the real bootstrap; "presence proves
  the flakes-built image" reworded to "matches the known flakes-base
  signature", and the no-other-`/bin/bash`-references assertion
  explicitly excludes the guard's own check.

## Relationship to `flakes-to-nix.md`

`flakes-to-nix.md` (seven review passes) planned dual-base support with a
staged default flip. On 2026-07-03 both of its load-bearing requirements
were dropped: no need to support both bases, and no need to migrate
existing machines. That document is **superseded** by this one and retained
as design history — its confirmed-facts inventory is the factual basis
here (with the corrections below), and its verification work is what makes
this plan small.

Dropped with the requirements (with the machinery each carried):

- **Change 2** — `DX_BASE` selector, flavor-specific defaults,
  cross-flavor reserved-name guard, `DX_CONTAINERFILE`. One base: nothing
  to select, no reserved opposite-flavor names to leak.
- **Change 3** — `-f` plumbing in `dx-create-image`. The default
  Containerfile path is unchanged.
- **Change 4** — the *permanent* `container inspect` reuse guard, its
  fixture/version contract, labels, and both of its unverified pre-flight
  gates. No cross-flavor reuse can exist; the "edited `FROM` but never
  rebuilt" case gets a temporary in-guest guard and a runbook gate
  (Decisions), not a permanent parser on an unstable JSON schema.
- **Change 6** — per-flavor side-container volumes, `DX_RECORDED_BASE`,
  the two-variant `--destroy` algorithm. Side containers do the same
  one-time changeover.
- **Default flip, switch procedure, transition acceptance test, flip
  preconditions.** No recurring switching exists. The flip's
  custom-profile hazard becomes the referrer-cleanup steps in the
  changeover.
- **Migration-specific machinery from the interim analysis** — volume
  reuse across bases and the store-transition gate *for the changeover*
  (fresh volumes mean no cross-base store state ever exists).

Retained:

- **Change 5** — the bootstrap edits (the hard technical content), now
  framed as a hypothesis proven by the canary, not a confirmed fact.
- **Change 1's pin policy** — explicit tag plus manifest-list digest,
  never `latest`; digest-only form rejected; the release alignment rule.
- **The Nix pin bump procedure — as an unresolved skeleton only.** Two
  store-reuse defects found in pass 1 (F-09, F-10) block publishing it
  as valid; see Future maintenance.
- **Changes 7 and 10** — independent of the base; listed under
  follow-ups, with the interactions pass 1 identified.

## Confirmed facts this plan is built on

Inherited from `flakes-to-nix.md` (verified against the running guest and
`NixOS/nix` `docker.nix` 2026-06-10, re-verified 2026-07-02), re-checked
against the tree and live guest 2026-07-03, with pass-1 corrections:

- The official image provides `/bin/sh` (→ bash) and `/usr/bin/env` but
  **no `/bin/bash`** (confirmed against the 2.31.5 `docker.nix` source in
  pass 1). The running flakes guest has `/bin/bash` and `/usr/bin/env`
  (live-checked 2026-07-03); `/usr/bin/env` presence in the **pristine**
  flakes image remains a pre-flight gate — a running guest does not prove
  the pre-bootstrap image.
- "The shebang and `useradd` shell are the only hard breakages" is an
  **implementation hypothesis** derived from source inspection; the
  canary's full pristine bootstrap is its proof gate (corrected in
  pass 1 from a confirmed-fact claim).
- `dx-create-container` passes `--entrypoint sh` unconditionally
  (`bin/dx-create-container:37`), so neither image's default entrypoint is
  ever exercised. The official image defines `Cmd` but no `Entrypoint`
  (irrelevant to this launch path).
- The official image ships bash, coreutils-full, tar, gzip, grep, which,
  curl, findutils, git, openssh — but **not** `shadow`, so
  `install_essentials` (`bootstrap.sh:14`) still triggers on first boot.
- The official image does not enable flakes in `nix.conf`; every nix
  invocation that runs before `configure_nix_daemon` writes
  `/etc/nix/nix.conf` already passes
  `--extra-experimental-features 'nix-command flakes'` explicitly.
- **Corrected (pass 1)**: the current flakes image sets `SSL_CERT_FILE`
  only — **not** `NIX_SSL_CERT_FILE` (image env inspected 2026-07-03;
  `flakes-to-nix.md`'s "both images set both" was wrong). `bootstrap.sh:5-6`
  provides the fallbacks either way, so this is immaterial functionally.
- **Neither image provides `/etc/os-release`** — verified absent on the
  live flakes guest 2026-07-03, and the official image's `docker.nix`
  does not create it. `tests/test_section5_nix.sh`'s live
  `VERSION_ID="25.11"` assertion therefore fails **today**; the
  changeover inherits, not introduces, that defect (pass 1 / F-02).
- Guest Nix under 25.11 is 2.31.4; `nixos/nix:2.31.5` satisfies the
  alignment rule (same minor as the release's default Nix) and pass 1
  confirmed it is the newest published 2.31 patch tag with a
  `linux/arm64` manifest. Its manifest-list digest as of 2026-07-03:
  `sha256:4ae3542b89e38bf739a98d9e1ffd082c3c7b8a6455ec0c2331560b9440aec442`
  — **re-query immediately before implementation**; never copy it blind.
- With fresh volumes the changeover has no store-schema compatibility
  constraint — the alignment rule is kept as a coherence rule, not a
  safety one. It becomes a safety rule again for future pin bumps.
- The section-2 test requires exactly one non-blank line in the
  Containerfile (`tests/test_section2_containerfile.sh:47`); its `FROM`
  assertion is currently just `^FROM ` (`:38`).
- `assert_file_contains` runs plain `grep -q` — **basic** regular
  expressions (`tests/test_helpers.sh:74-82`). ERE operators like `+` and
  `{64}` do not work through it (pass 1 / F-03).
- `tests/test_section11_validate_fresh.sh` does **not** prove freshness:
  `dx-create-image` succeeds by skipping an existing image, and an
  existing container is accepted without checking its image (verified,
  pass 1 / F-05). It is an idempotent lifecycle smoke test.
- `dx-create-image` skips the build whenever the local image name exists
  (`bin/dx-create-image:7-10`) — editing the Containerfile changes nothing
  until the old image is removed. `./bin/dx-destroy` removes container
  **and** image; `./bin/dx-factory-reset` additionally removes all three
  volumes and the SSH keypair (confirmation-gated, `--force` to skip).
  Both operate **only** on the resources the active profile resolves —
  they never touch `dx-test`, `dx-tinty`, side containers, or custom
  profiles (pass 1 / F-01).
- Profile tooling: `./bin/dx-profile <profile> <command…>` sources
  `tests/profiles/<profile>.env` and execs the command; its own header
  documents `./bin/dx-profile dx-test ./bin/dx-destroy` as the cleanup
  idiom. Shipped profiles: `dx-test` (container `dx-test`, image
  `dx-test-nixos`, volume `dx-test-nix`, port 2299) and `dx-tinty`
  (container `dx-tinty`, image `dx-tinty-nixos`, volume `dx-tinty-nix`,
  port 2298); both also set namespaced persist/bootstrap volumes and
  key pairs (`dx-test_key`, `dx-tinty_key` under the project root —
  pass 4).
- `container image rm` / `container volume rm` fail while a container
  references the resource; under `set -e` that aborts a procedure
  mid-way. Referrers must be destroyed first (pass 1 / F-01).
- **`.env` overrides every profile and derived export in child
  scripts**: `dx-lib.sh:11-16` sources `.env` with `set -a` in every
  script run, *after* the parent (`dx-profile`, `dx-mount`) has
  exported its values. A `DX_*` line in `.env` therefore redirects
  `./bin/dx-profile dx-test ./bin/dx-destroy` and the child scripts of
  `dx-mount --destroy` to whatever `.env` names — including default
  resources (pass 2; the same pre-existing bug `flakes-to-nix.md`
  change 7 fixes).
- `dx-start-container` skips `container start` when the container is
  already running and then only runs `dx-sync-bootstrap`
  (`bin/dx-start-container:13-19`): the payload is refreshed but
  `bootstrap.sh` is **not** re-executed until the next container
  restart (pass 2).
- `dx-mount` requires its source directory to exist and derives the
  container name from the resolved path (`bin/dx-mount:99-107`), so a
  moved or deleted checkout blocks the normal `--destroy` form; the
  `--container NAME` path validates the marker's recorded mount source
  against the current directory (`bin/dx-mount:144-154`) and is
  therefore not a fallback **today** — change 5 adds the destroy-only
  path that makes it one. The identity markers under
  `~/.dx-cache/mount-identities/` record **only**
  `DX_RECORDED_GIT_MOUNT_SOURCE`/`TARGET` (`bin/dx-mount:240-244`); the
  container name appears only in the marker filename, and none of the
  image/volume/key overrides `dx-mount` honors (`:5-12`, `:163-186`)
  are recorded (pass 4). Directory absent when no side containers
  exist.
- `dx_require_non_reserved_container_name` rejects only the literal
  `dx-host` (`bin/dx-lib.sh:114-120`) — `--container` names containing
  `/` or `..` currently pass validation and traverse the marker
  pathname (pass 4).
- `container list -a` shows each container's **image** but not its
  volume mounts (verified 2026-07-03) — volume referrers are only
  visible via per-container `container inspect`.
- `dx-get <guest_path> [host_path]` copies out of the guest and is the
  supported `/persist` salvage path. `dx-export` wraps
  `container export` (root filesystem) and must **not** be assumed to
  include named-volume contents (pass 1 / F-08).
- The string `nix-flakes` appears in exactly three non-plan locations:
  `container/aarch64-darwin-apple-container-dx-nixos-25.11/Containerfile:1`,
  `README.md:635`, and the roadmap entry at `README.md:704`. No test
  asserts the base-image string or `bootstrap.sh`'s shebang. `plan.md`
  additionally carries flakes-image assumptions beyond its gate section
  (pass 1 / F-12) — the doc change sweeps the whole file.
- `nix profile list` output matches the
  `Flake attribute:\s+packages\.<sys>\.ai-tools` scrape in
  `configure_guest` (`bootstrap.sh:539`) on Nix 2.31. This proves the
  scrape works on the new base's Nix; it says nothing about base
  provenance (post-activation `nix` is the locked guest Nix).
- **Unverified, gated on pre-flight**: `/usr/bin/env` in the pristine
  images; that `container build` accepts a `FROM <tag>@sha256:…`
  reference. (Pass 1 confirmed the image/tag/digest facts from primary
  sources but did not execute the image or build — those remain live
  gates.)

## Changes

### 1. Containerfile (one line)

`container/aarch64-darwin-apple-container-dx-nixos-25.11/Containerfile`:

```text
FROM nixos/nix:2.31.5@sha256:<manifest-list digest, re-queried at implementation>
```

- Explicit version tag, never `latest`. The digest is the
  **multi-platform manifest-list digest** for the tag (what
  `container image pull nixos/nix:<tag>` resolves). If the pre-flight
  shows `container build` rejects digest references, ship tag-only and
  record the tag-mutability residual risk under Risks.
- The tag follows the **release alignment rule**: major.minor of the
  pinned release's default Nix (`nixpkgs#nix.version` at the locked
  revision), newest patch tag within that minor. `2.31.5` satisfies it
  today; substitute the tag chosen under this rule at implementation
  time.
- The one-non-blank-line invariant stays: no comments; digest provenance
  lives in the README maintenance section.
- **Every other name is unchanged**: `dx-nixos-25.11`, `dx-nix`,
  `dx-host`, the context directory, side-container derivations. They are
  release/identity labels, not base labels. The local image name is
  thereby a **mutable cache key, not provenance** — document exactly
  that (Decisions; pass 1 / F-13).

### 2. `bootstrap.sh` (two edits plus one temporary guard)

- Line 1: `#!/bin/bash` → `#!/usr/bin/env bash`. On the official image
  the current shebang fails with ENOENT when the entrypoint loop `exec`s
  the script. If the pre-flight shows `/usr/bin/env` missing from either
  pristine image, do **not** drop to `#!/bin/sh` (`bootstrap.sh` relies
  on Bash semantics: `pipefail`, `local`, Bash tests); the fallback is a
  proven absolute Bash path, as its own deliberate change.
- `create_user` (`bootstrap.sh:214`): `useradd -m -g dx -s /bin/bash dx`
  → `-s /bin/sh`. `/bin/sh` exists in both images, and the shell is
  switched to nushell at the end of `configure_guest` anyway.
- **Canary finding (2026-07-04)**: the first canary bootstrap failed in
  `setup_nix_volume` — on the official image a plain root `nix profile install`
  targets `/nix/var/nix/profiles/per-user/root/profile` (not on PATH, not what
  `install_essentials`' `/root/.nix-profile` resolution sees), so the installed
  essentials were unreachable. This falsifies the "shebang and useradd are the
  only hard breakages" hypothesis exactly the way the canary gate was designed
  to catch. The interim fix — pinning the install with an explicit
  `--profile /nix/var/nix/profiles/default` — failed a second canary: that
  profile already holds the image's own package environment at priority 5, so
  the essentials collide with it at an equal-priority tie, and the blanket
  `--priority` override tried to break that tie instead broke nixpkgs' own
  meta-priority de-confliction *between* essentials-list packages (a
  `shadow`/`util-linux` man-page tie on `chfn.1.gz`). The resolution that
  passed both canaries keeps the stock, conflict-free `nix profile install`
  (no `--profile`, no `--priority`) and instead generalizes PATH derivation:
  `essentials_profile_path` iterates every profile-bin candidate that Nix
  might have used (per-user root profile, XDG state profile, legacy
  `~/.nix-profile`), resolving each existing one with `readlink -f` so the
  concrete `/nix/store` paths survive the `/nix` remount in `setup_nix_volume`.
- **Canary finding #3 (2026-07-04)**: a third canary bootstrap, past the
  first two `setup_nix_volume` fixes above, failed in `create_user`:
  `groupadd: cannot open /etc/group: Too many levels of symbolic links`. On
  the official image `/etc/passwd`, `/etc/group`, and `/etc/shadow` are
  symlinks into the read-only base-system store path (`/etc/gshadow` does
  not exist), and shadow-utils open these files with O_NOFOLLOW, so any
  symlink there is ELOOP. Fixed by materializing each symlinked auth file as
  a regular, writable copy of its content (`materialize_auth_files`, seamed
  through `DX_AUTH_ROOT` for tests; a dangling symlink becomes an empty
  regular file rather than aborting bootstrap) immediately before
  `create_user` runs.
- **Canary finding #4 (2026-07-04)**: a fourth canary bootstrap, past the
  three fixes above, completed guest bootstrap, but every SSH command
  against the guest then failed for the whole wait budget. `dx`'s login
  shell is nushell, and a non-interactive sshd session hands it only the
  bare default PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). Both `dx-wait-ssh`'s
  readiness probe and `dx-ssh`'s command wrapper (`base64 -d | bash -l`)
  bootstrap the guest environment via `bash -l`, and on the old base that
  worked only because the image shipped a global `/bin/bash`. The official
  base ships none. Fixed by linking the essentials bash at `/usr/bin/bash`
  (already on sshd's default PATH) — `link_system_bash`, seamed through
  `DX_LINK_ROOT` for tests — called immediately after `install_essentials`
  once bash is on `PATH`, and resolved via `command -v bash` so the linked
  target is a concrete `/nix/store` path that survives the `/nix` remount
  in `setup_nix_volume`. Deliberately linked at `/usr/bin/bash`, not
  `/bin/bash`: the latter remains `guard_old_base`'s signature and must
  never be created by this payload.
- **Canary finding #5 (2026-07-04, reboot path)**: `install_essentials`
  re-runs on every container boot by design (its steps are idempotent), but
  its skip-gate (`command -v useradd`) used to run *before*
  `essentials_profile_path`'s output was put on `PATH`. On the official base
  the per-user profile is never on the image's default PATH, so every
  reboot missed the previous boot's already-installed essentials, fell into
  the install branch again, and its `nix profile install` collided with
  that same profile's own earlier contents once the registry-resolved
  package revision had moved on — crashing a warm boot that a fresh boot
  had passed. Fixed by resolving and exporting the essentials PATH before
  the skip-gate, and re-resolving it once more after a fresh install so the
  newly installed tools are usable for the rest of bootstrap without
  requiring another restart.
- **Temporary old-base guard (pass 1 / F-06, revised in pass 2) — two
  sites, one invariant**: fail fast with an explicit message when
  `/bin/bash` exists (`-e` or `-L`, catching a dangling symlink) — the
  official image never provides it and nothing in the guest payload
  creates it (grep-verified), so its presence **matches the known
  flakes-base signature** (pass 5 wording: a signature match, not proof
  of any particular image).
  - *In-guest site*: near the top of `bootstrap.sh` — fires on every
    container **boot**.
  - *Host site (added in pass 2)*: at the end of `dx-start-container`,
    after `dx-sync-bootstrap` (by which point `container exec` is
    proven working) — because a bring-up against an **already-running**
    container syncs the payload but never re-executes `bootstrap.sh`
    (`bin/dx-start-container:13-19`), the in-guest guard alone leaves a
    skipped changeover silent until the next restart. The host check is
    a plain `container exec … sh -c` filesystem test — not inspect
    parsing.
  Both sites: the error names this plan's changeover procedure; both
  carry the same removal note — delete after every machine (primary,
  side containers, profiles) has changed over. **Sequencing (pass 2)**:
  the guard intentionally fails the flakes base, so both guard sites
  and their test assertions land **in the same commit as the `FROM`
  flip** — never earlier. Only the shebang and `useradd` edits are
  base-compatible and may land ahead of the flip. The guard tests the
  actual root filesystem — stronger evidence than parsing
  `container inspect` output, with no schema dependency (see
  Decisions).

No other `/bin/bash` references exist in the guest payload (verified by
grep, re-verified 2026-07-02). Once the guard lands, its own check is
the single permitted reference — the section-3 assertion excludes it
explicitly (pass 5).

### 3. Tests

- **Containerfile identity (pass 1 / F-03)**: assert the file's single
  non-blank line **exactly equals** the adopted reference — a
  fixed-string, full-line match (e.g. `grep -qxF` or direct string
  comparison against `$(grep -ve '^[[:space:]]*$' "$CONTAINERFILE")`),
  not a pattern through `assert_file_contains` (BRE — the previously
  proposed ERE could never match). Wrong tag, changed digest,
  digest-only, `latest`, an extra instruction, and an extra non-blank
  line must each fail. If tag-only fallback is adopted, change the exact
  expected line in the same commit and record the waiver. The
  one-non-blank-line check (`:47`) stays.
- **Bootstrap regression assertions (new, pass 1 / F-04)**, in
  `tests/test_section3_bootstrap.sh`: exact first line
  `#!/usr/bin/env bash`; `useradd` line carries `-s /bin/sh`; no
  `useradd … -s /bin/bash`; no other `/bin/bash` reference in the guest
  payload **excluding the guard's own check** (pass 5 — the guard
  necessarily contains the string); both temporary guard sites are
  present (assertions land in the flip commit with the guards and are
  removed together with them — see the sequencing note in change 2).
- **Guard behavioral tests (pass 3; harness specified in pass 4)**:
  exercise both guard sites, not just grep for them — the official-base
  shape passes; `/bin/bash` present, a dangling `/bin/bash` symlink,
  and a failing `container exec` (host site) each fail with the
  changeover message. Harness: the in-guest check tests an absolute
  path, so it reads `${DX_GUARD_ROOT:-}/bin/bash` (default empty →
  `/bin/bash` in production) and the section-3 test points
  `DX_GUARD_ROOT` at a fixture directory containing a regular file, a
  dangling symlink, or nothing — the established env-seam pattern
  (`DX_FORWARD_WAIT_SSH` and friends), no disposable containers
  needed. **`DX_GUARD_ROOT` alone is not enough (pass 5)**: it makes
  the predicate injectable but a *passing* fixture would continue into
  the real bootstrap. Factor the check into a named function and add a
  guard-only entry point — `DX_BOOTSTRAP_TEST_MODE=guard` runs the
  guard and exits (the `DX_FORWARD_TEST_MODE=parse` precedent) — so
  both pass and fail shapes run without executing any bootstrap step.
  The host-site check is exercised with a stubbed `container` on
  `PATH` (the section-9 pattern) covering pass, `OLD_BASE`, and
  exec-failure exits. Removed together with the guards.
- **Section 5 release identity (pass 1 / F-02, strengthened in
  pass 2)**: remove the `/etc/os-release` live assertion — it fails on
  the current guest already and neither image provides the file. The
  release oracle is a **mandatory** in-guest
  `nix eval --raw --no-update-lock-file --inputs-from /guest-bootstrap
  nixpkgs#lib.version` (`--no-update-lock-file` so validation can never
  mutate the lock — pass 3, same discipline as change 10's installs)
  whose output must start with the expected release — the existing
  `flake.lock` grep (`tests/test_section5_nix.sh:64-68`) only proves the
  branch string appears *somewhere* in the lock (any transitive input
  could satisfy it), so it stays as a cheap static check but is not the
  oracle. Reword test messages so they do not claim the container is a
  full NixOS system.
- **Fresh-base integration (pass 1 / F-05)**: section 11 stays as the
  idempotent lifecycle smoke test but is no longer cited as freshness
  proof. Real freshness proof is the canary (below): an isolated profile
  whose container, image, volumes, and keys are **asserted absent**
  before the run.
- No other existing test changes are required for the switch itself
  (verified: no test asserts the base string or the bootstrap shebang;
  `test_helpers.sh:26` keeps its single `CONTAINERFILE`).

### 4. Docs

- `README.md:635` (base-image description) and `:704` (roadmap entry):
  rewrite for the single official base; point the roadmap entry here and
  mark the third-party dependency removed.
- README "Release and Pin Maintenance" (`README.md:587`): remove the
  `DX_BASE`/flavor framing and the flip note; keep the single-source
  release pin and the alignment rule; mark the pin-bump procedure
  **unresolved pending F-09/F-10** (Future maintenance) rather than
  publishing it as valid. Use the narrowed release-bump claim from the
  Goal section verbatim (pass 1 / F-11).
- The README changeover section is written as **guarded runbook steps**
  (pass 1 / F-17): each step copyable, with expected output, safe
  absent-resource behavior, an abort condition, and verification before
  continuing.
- `plan.md`: **sweep the whole file** (pass 1 / F-12) — the gate at
  `:76-80` plus every other flakes-image assumption (principles,
  pre-flight, implementation changes, acceptance criteria; occurrences
  near lines 27, 78, 91, 101, 328, 439). The `OLD_IMAGE`/`NEW_IMAGE`
  playbook definitions (`plan.md:22`) stay keyed by release name only;
  the per-flavor caveat at `:80` is obsolete. Add a stale-reference
  grep (`nix-flakes`, the old gate wording) to the acceptance criteria.
- `mount-git.md` (seeding note, item 2): drop the flavor-identity
  interaction — with one base, side-container volumes have exactly one
  possible seed source.
- `flakes-to-nix.md`: add a superseded-by header pointing here; retain
  as design history. (The pass-1 review file was removed after
  incorporation, per the convention established in `flakes-to-nix.md`;
  its findings are dispositioned in the Review history and Decisions
  sections.)

### 5. `dx-mount`: destroy-only `--container` path (new in pass 3, hardened in pass 4)

The only host-script change beyond change 2's guard. `dx-mount
--destroy` requires the mount source directory: the container name is
derived from the resolved path (`bin/dx-mount:99-107`), and the
`--container NAME` override validates the marker's recorded source
against the current directory (`bin/dx-mount:144-154`). An orphaned side
container — checkout moved or deleted — is therefore un-destroyable
through guarded tooling, and the obvious workaround (recreate the
recorded path) is unsafe: the resolution runs
`git rev-parse --show-toplevel`, so a recreated empty directory can
resolve into an enclosing Git root and derive a different identity.

Make `--container NAME --destroy` a supported **destroy-only** path:

- the identity marker under `~/.dx-cache/mount-identities/<name>.env`
  must exist — it is the authorization; without it, today's error (with
  its manual-recovery hint) stands;
- the mount-source comparison is skipped **for destroys only** —
  attach/create paths keep full validation. This is the principle
  already settled in `flakes-to-nix.md` change 6: a mismatch check must
  never block the recovery command its own error message recommends;
- **`NAME` is validated before it touches the marker pathname
  (pass 4)**: `dx_require_non_reserved_container_name` rejects only
  `dx-host`, so `/` and `..` currently traverse
  `$identity_dir/$NAME.env`. Require container-safe syntax
  (`^[A-Za-z0-9][A-Za-z0-9_.-]*$` — no slashes, no leading `-` or `.`),
  record the container name **inside** the marker as well, and verify
  the recorded name matches before any destructive use — a renamed or
  copied marker file must not authorize a different container's
  destruction;
- **new markers persist the complete resolved resource manifest
  (pass 4)**: container name, image, nix/persist/bootstrap volumes, and
  key paths, written at creation alongside source/target. `dx-mount`
  honors image/volume/key overrides, but the marker records none of
  them — derive-from-NAME would miss or mis-target overridden
  resources. (Today's *normal* destroy shares this hole when re-run
  without the original overrides; the manifest fixes both paths.)
  Destroy-only resolves every resource from the manifest, still passing
  the `refuse_default_destroy` guards;
- **legacy markers** (source/target only) fall back to derived-from-NAME
  (`<name>-nix`, `<name>-persist`, `<name>-bootstrap`, slugged key
  pair). (Reconciliation lives in the runbook, not in `dx-mount` —
  code-side reconciliation would require parsing `container inspect`,
  which stays declined);
- **`--print-destroy-plan` — a non-destructive review mode (pass 5)**:
  prints the fully resolved deletion plan (manifest-resolved or
  name-derived) and exits without deleting anything. Printing a plan
  immediately before deleting allows no review and abort, so the
  required sequence for legacy markers is: plan → reconcile against the
  inventory ledger → separate destructive invocation (a mismatch means
  the container was created with overrides; destroy it with explicit
  env values instead). Mutually exclusive with `--destroy`, like
  `--print-env`;
- **the manifest is write-once (pass 5)**: today `dx-mount` rewrites
  its marker on **every** invocation (`bin/dx-mount:240-244`), so an
  ordinary attach *without* the original overrides would silently
  replace the recorded manifest with derived values — corrupting the
  cleanup record the manifest exists to be. New behavior: the manifest
  is written at creation only; every later invocation validates its
  resolved resources against the recorded manifest and **refuses on
  mismatch** (re-run with the original overrides, or destroy and
  recreate — deliberate recreation is the only way to change it).
  Legacy markers are never auto-upgraded: an upgrade written by an
  attach without the original overrides would record the same wrong
  values; they stay legacy until destroy-and-recreate;
- behavioral coverage in `tests/test_section18_mount_git.sh`: the
  destroy-only override succeeds without the source directory present,
  resolves overridden resources from a manifest marker,
  `--print-destroy-plan` prints the plan (manifest and legacy shapes)
  and deletes nothing, an attach without the original overrides is
  refused and leaves the manifest byte-identical, a plain re-attach
  does not rewrite the marker, refuses without a marker, rejects unsafe
  names (`../x`, `a/b`), refuses a marker whose recorded name
  mismatches, and never removes default resources.

Lands with (or before) the flip commit — orphaned side containers may
already exist at changeover time.

## Pre-flight (before any repo change)

- [ ] Re-query the tag and manifest-list digest from Docker Hub; confirm
      `2.31.5` (or the then-current aligned tag) still has a
      `linux/arm64` manifest.
- [ ] `container run --rm nixos/nix:<tag>@sha256:<digest> /usr/bin/env bash -c 'echo ok'`
- [ ] `container run --rm --entrypoint sh nixos/nix:<tag>@sha256:<digest> -c 'printf "#!/usr/bin/env bash\necho shebang-ok\n" > /tmp/t && chmod +x /tmp/t && exec /tmp/t'`
- [ ] The same two checks against the pristine current base
      (`nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`) — keeps the
      **base-compatible** bootstrap edits (shebang, `useradd`) landable
      ahead of the flip. The temporary guard is deliberately *not*
      base-compatible and lands atomically with the `FROM` change
      (pass 2; see change 2).
- [ ] `container run --rm nixos/nix:<tag>@sha256:<digest> nix --version`
      reports the tag's version — the exact reference that will land,
      not the mutable tag.
- [ ] `container build` accepts the `FROM <tag>@sha256:…` form (digest
      feasibility; on failure, tag-only plus recorded risk).
- [ ] Record the currently pulled flakes image's digest if exact
      rollback content matters (pass 1 / F-14) — tag-only rollback
      restores the base *family*, not necessarily byte-identical
      content.

## Canary gate (before any destructive step; pass 1 / F-05, F-07)

The pristine-image pre-flight proves Bash entry only. Before the primary
is destroyed, a full official-base bootstrap must succeed from
asserted-absent resources:

1. Create a dedicated cutover profile (`dx-test.env` pattern): unique
   container name, image name, SSH port, all three volumes, and keys.
2. **`.env` precondition**: the changeover-wide precondition below
   applies here too — without it the canary is not isolated.
3. Assert the profile's container, image, volumes, and keys do **not**
   exist, then `./bin/dx-profile <cutover> ./bin/dx` on the branch with
   the new `FROM` line.
4. Run the corrected full suite profile-aware, plus the same-base
   recreate cycle (`dx-destroy && dx` under the profile, volumes
   preserved). Run from a **clean, committed tree**: section 13 fails
   on tracked modifications (`tests/test_section13_final_review.sh:13-18`,
   verified), so the canary validates the flip *commit*, never a dirty
   working tree (pass 3).
5. Tear the canary down completely (executable form; pass 2):
   `./bin/dx-profile <cutover> ./bin/dx-destroy`, then
   `./bin/dx-profile <cutover> ./bin/dx-destroy-volumes --force`, then
   `./bin/dx-profile <cutover> ./bin/dx-destroy-keys`.

The primary factory reset is **gated** on this run passing.

## Changeover procedure (per machine, one-time, destructive by design)

Ordering rule learned in pass 1 (F-01): destroy **referrers before
resources**, and destroy nothing on the primary until every other
referrer is accounted for — `container image rm`/`volume rm` fail while
referenced, and under `set -e` that strands a half-reset machine.

**Precondition for every destructive step (pass 2, widened in pass 3):
the configuration surface must be clean.** Two sources can redirect
destructive commands at the wrong (including default) resources:

- **`.env`**: either the precedence fix (follow-ups) has landed, or the
  file must be **absent or fully reviewed line by line** — not merely
  free of `DX_*` entries (tightened in pass 4): `dx-lib.sh:11-16`
  sources it **as shell code** with `set -a` in every child script, so
  *any* line executes, and `DX_*` lines additionally clobber the
  exports of `dx-profile` and `dx-mount`.
- **Inherited `DX_*` environment (pass 3)**: exported variables in the
  operator's shell survive into every resolution — `dx-lib.sh` defaults
  are `:-` fallbacks, and `dx-mount` explicitly honors pre-set values
  as user-supplied, captured before it even sources the library
  (`bin/dx-mount:5-12`). Verify `env | grep '^DX_'` prints nothing in
  the shell running the runbook; failing that, print and review every
  effective resource name immediately before each destructive command.

Destroying under a clobbered or polluted resolution is strictly worse
than validating under one. (Verified 2026-07-03: this machine has no
`.env`.)

1. **Quiesce and salvage `/persist`** (pass 1 / F-08): stop active guest
   workloads; push every repository and verify remotes; then
   `./bin/dx-get /persist ./persist-backup-$(date +%Y%m%d)` and
   **inspect the copied tree** before proceeding. Record what is
   deliberately not preserved (gh/AI credentials — re-established
   later). `dx-export` is not a substitute (root fs only). Do not
   continue until the backup has been verified by eye.
2. **Inventory (rewritten in pass 2)**: enumerate with
   `container list -a` (shows names and images), plus
   `~/.dx-cache/mount-identities/` for side-container names (directory
   may be absent), plus **every profile file** — `tests/profiles/*.env`
   and any user-maintained profiles — reading their image, volume, and
   key values into the ledger **regardless of whether a container
   currently exists** (pass 4: container inspection cannot discover a
   profile's orphaned image, volumes, or keys), cross-checked against
   `container image ls` / `container volume ls` for unaccounted `dx-*`
   strays. Then run `container inspect` on **each** container —
   list output does not show volume mounts, so volume referrers are
   invisible without it. The operator reads the inspect output during
   the runbook; no code parses it (see Decisions). While classifying,
   **record a deletion ledger (pass 3)**: every container, image,
   volume — including persist/bootstrap volumes, custom-profile volumes,
   and side-container derivations — key file, and identity marker
   slated for removal. The ledger, not a hardcoded name list, is what
   step 5 verifies, so arbitrary custom-profile resources are covered
   automatically. Any container referencing a ledgered image or volume
   **must be destroyed in step 3 — an affected referrer cannot be
   deferred**, since the later `rm` commands fail while it exists. Only
   containers referencing no ledgered resource (e.g. Apple's `buildkit`
   builder) are left alone. Abort here, not mid-reset.
3. **Destroy non-default referrers, staged globally referrer-first
   (restructured in pass 5)**. The per-unit tools interleave container
   and resource removal (`dx-destroy` is container-then-image,
   `dx-mount --destroy` container-then-volumes), so a resource shared
   *across* units — the default image every side container references,
   or an override-shared volume — could fail its `rm` mid-unit under
   `set -e` after that unit's container is already gone. Every destroy
   tool is idempotent on missing resources (verified: container, image,
   volumes, and keys all no-op cleanly), so stage the sweeps:

   - **3a — containers only**, every ledgered container:
     `./bin/dx-profile dx-test ./bin/dx-destroy-container`, the same
     for `dx-tinty` and any custom profiles;
     `DX_CONTAINER_NAME=<name> ./bin/dx-destroy-container` for each
     side container.
   - **3b — verify**: `container list -a` shows no ledgered container.
     Abort here if any survives.
   - **3c — resources**, per unit through the same guarded tooling —
     each now no-ops on the already-destroyed containers, cannot hit a
     live referrer, and tolerates a shared resource another unit's
     sweep already removed:
     - side containers: `./bin/dx-mount <source-dir> --destroy`; for an
       **orphaned** one (checkout moved or deleted), the change-5
       destroy-only path in two invocations — first
       `./bin/dx-mount --container <name> --print-destroy-plan`,
       reconcile the printed plan against the ledger (mandatory for
       legacy markers, whose resources are name-derived; manifest
       markers resolve from the recorded manifest), then
       `./bin/dx-mount --container <name> --destroy`. (The pass-2
       mkdir-recreate workaround stays withdrawn:
       `git rev-parse --show-toplevel` can resolve a recreated empty
       path into an *enclosing* Git root and derive a different
       identity.);
     - shipped profiles: `./bin/dx-profile dx-test ./bin/dx-destroy`,
       `./bin/dx-profile dx-test ./bin/dx-destroy-volumes --force`,
       `./bin/dx-profile dx-test ./bin/dx-destroy-keys`, the same
       triple for `dx-tinty` and any custom profiles (custom images,
       volumes, and namespaced key pairs — `dx-test_key`,
       `dx-tinty_key` — all ledgered; the keys step was missing before
       pass 4).
4. **Factory-reset the primary**: `./bin/dx-factory-reset` (container,
   image, all three volumes, keys; confirmation-gated).
5. **Verify the deletion ledger (pass 3)**: every ledger entry from
   step 2 is absent — containers via `container list -a`, images via
   `container image ls`, **all** volumes (persist/bootstrap,
   custom-profile, and side-container ones included) via
   `container volume ls`, key files, and identity markers on the host
   filesystem. Any survivor → return to step 2. (The pass-2 form
   checked a hardcoded image/volume list, which missed custom-profile
   resources, keys, and markers.)
6. **Rebuild**: `./bin/dx` on the changeover commit — fresh image from
   the edited Containerfile, fresh volume seed, fresh bootstrap.
7. **Old-base exclusion gate** (pass 1 / F-06, corrected in pass 2,
   renamed in pass 3): `/bin/bash` absence **excludes** the known
   flakes base — it does not prove the image is `nixos/nix` at the
   pinned digest. Positive provenance comes from the digest-pinned
   `FROM`, the ledger-verified image removal (step 5), and the fresh
   rebuild (step 6): the built image can only have come from the edited
   Containerfile. **That chain fixes exact content only under the
   digest pin; under the tag-only waiver it fixes the base family and
   tag, no more — the provenance claim is conditional (pass 4)**.
   Absence is asserted as a **positive token**, never as
   the failure branch of the probe: the pass-1 `if/else` form read
   *any* `container exec` failure (stopped container, name typo,
   runtime error) as "official base". Errors fail closed, and `-L`
   catches a dangling `/bin/bash` symlink:

   ```bash
   state="$(container exec dx-host sh -c \
       'if [ -e /bin/bash ] || [ -L /bin/bash ]; then echo OLD_BASE; else echo OLD_BASE_ABSENT; fi')" \
       || { echo "FAIL: could not verify (container exec error)"; exit 1; }
   case "$state" in
       OLD_BASE_ABSENT) echo "OK: old flakes base excluded (no /bin/bash)" ;;
       OLD_BASE)        echo "FAIL: /bin/bash present — still the old flakes base"; exit 1 ;;
       *)               echo "FAIL: unexpected verification output: $state"; exit 1 ;;
   esac
   ```

   The temporary guards (change 2) enforce the same invariant on every
   container boot and on every `dx-start-container` bring-up.
   **Residual window (claim narrowed in pass 3)**: `dx-ssh` and
   `dx-enter` bypass `dx-start-container`, so direct sessions against
   an already-running old container between a source pull and the next
   bring-up or restart are caught by no guard. Accepted — the window
   closes at the next lifecycle touch, this runbook gate is mandatory,
   and extending guards to hot interactive paths was declined (see
   Decisions).
8. **Validate** (next section).
9. **Re-establish intentional state**: `gh auth login`, `dx-ai` opt-in,
   re-clone into `/persist` — only after validation passes.

Recovery from partial completion: every step is re-runnable; the
inventory (step 2) is the re-entry point, and nothing destroys the
primary before step 4.

## Validation

- [ ] Canary gate passed (before this machine was touched).
- [ ] `./bin/dx` completes bootstrap; sshd reachable; `dx-enter` works.
- [ ] Corrected full suite passes (`/etc/os-release` assertion replaced;
      Containerfile exact-line and bootstrap assertions in place).
- [ ] Old-base exclusion gate passes (token-positive); neither
      temporary guard fired.
- [ ] `nix profile list` scrape in `configure_guest` still matches on
      the new base's Nix (works-on-base proof, not provenance).
- [ ] AI-tools opt-in path (`dx-ai`, keyring, persistence links) works.
- [ ] Timezone, persist links, gh persistence intact after
      `dx-destroy && dx` — same-base volume reuse remains a core
      supported operation and must be revalidated on the new base.
- [ ] Both shipped profiles rebuild from scratch under the new base and
      pass their suites (their old images/volumes were removed in
      step 3).

## Rollback

`git revert` the changeover commit, then repeat the changeover procedure
in the reverse direction. Fresh volumes both ways — no
store-compatibility proof needed. Two recorded limitations (pass 1 /
F-14): the flakes tag is **mutable** — rollback restores the old base
family and release label, not provably byte-identical content (mitigate
by recording the pulled flakes digest during pre-flight if that
matters); and rollback presumes the flakes 25.11 tag remains published
(it is today's dependency; the distrust that motivated this plan
concerns its *future* tags).

## Future maintenance — explicitly unresolved (pass 1 / F-09, F-10)

Destroy-and-rebuild was a one-time dispensation; after the changeover the
persisted volume and `/persist` again hold real state, so future Nix pin
bumps need a volume-reusing procedure. The skeleton inherited from
`flakes-to-nix.md` (update pin → destroy referrers → remove stale image →
fresh-volume validation → old→new→old transition gate on a throwaway
volume) is retained **but must not be published as valid**: pass 1 found
two defects in its foundations, both rooted in `setup_nix_volume`'s
store handling:

- **F-09 — the new image's Nix may never actually run.** On a reused
  volume, `/nix/var` comes from the volume; post-remount, profile paths
  (`/nix/var/nix/profiles/default/bin`) can keep resolving `nix` to the
  **old** image's binary even after a new image is built. A nominal
  "new image mutates the store" transition stage can therefore run the
  old Nix and produce a false rollback-safety result. Any valid
  procedure must capture the new image's exact Nix store path/version
  pre-remount, ensure that closure is validly present on the volume,
  invoke that exact binary in the "new" stage, and assert binary path
  and version at old, new, and rollback stages.
- **F-10 — merged store paths are not registered.** The merge branch
  copies `/nix/store` directories (`cp -a -n`) without updating the
  volume's store database under `/nix/var/nix/db`. Copied paths exist on
  disk unregistered — invisible to `nix path-info`, unprotected from
  GC. A valid procedure needs a Nix-supported closure
  transfer/registration for the paths it depends on, post-remount
  verification, and GC-survival proof; the current non-fatal copy
  warning must become fatal for required paths.

Until both are resolved (their own design change, out of scope here),
the only safe pin bump is the one this plan itself performs: full
destroy-and-rebuild with salvage. The README maintenance section states
exactly that. What *is* retained as valid now: the alignment rule, the
build-cache trap warning (nothing rebuilds while the local image name
exists), and the digest re-query discipline.

No host-side backing-file backups (rejected in `flakes-to-nix.md` pass 6):
no cold-copy contract exists; a proven transition gate — once F-09/F-10
are fixed — is the rollback proof.

## Decisions

- **Old-base detection: filesystem guards, not inspect parsing**
  (2026-07-03, pass 1; revised pass 2). The pass-1 review proposed
  verifying provenance via `container image inspect` OCI labels and
  image descriptors. That reintroduces the undocumented-schema
  dependency this plan deliberately dropped with change 4. Adopted
  instead: temporary `/bin/bash` guards at two sites — inside
  `bootstrap.sh` (every boot) and at the end of `dx-start-container`
  (every bring-up, closing the running-container window pass 2 found) —
  plus the token-positive runbook gate. All three test the actual root
  filesystem via plain `container exec`; none parse output. Declined:
  any permanent lifecycle parser. Removal criterion: all machines
  changed over. Sequencing: guards land atomically with the `FROM`
  flip.
- **Operator-read `container inspect` in the inventory does not
  contradict the no-parser decision** (2026-07-03, pass 2). What was
  rejected is *permanent lifecycle code* parsing an undocumented JSON
  schema and failing closed on drift. A human reading inspect output
  once, during a one-time runbook, has no schema dependency — whatever
  shape the JSON takes, the operator can find the image and mounts in
  it. Volume referrers are invisible any other way (`container list -a`
  shows images only — verified).
- **Local image name stays `dx-nixos-25.11`** (2026-07-03, pass 1 /
  F-13). Versioning the name by base/pin was considered (it would make
  rebuilds automatic) and rejected — it churns guard lists, tests, and
  docs for a rare event, and `flakes-to-nix.md` rejected it for the
  same reason. Mitigation adopted: the README documents the image name
  as a mutable local cache key, never provenance; the cache trap is
  named in the maintenance section. Old-base **exclusion** comes from
  the guards and the runbook gate; provenance comes from the
  digest-pinned `FROM`, the ledger-verified removal, and the fresh
  rebuild — conditional under the tag-only waiver. (Pass 4 corrected
  this entry, which still credited the guard with provenance.)
- **Section-5 release oracle: the mandatory in-guest `nix eval`, not
  `/etc/os-release` and not the lock substring grep** (2026-07-03;
  pass 1 dropped `/etc/os-release`, pass 2 made the eval the oracle,
  pass 3 fixed this entry, which still called the lock grep
  authoritative). The file is absent on both bases; the branch grep
  proves only substring presence and stays as a secondary static
  check.
- **Salvage contract** (2026-07-03, pass 1 / F-08): push-plus-`dx-get`
  with mandatory inspection; `dx-export` documented as not covering
  volumes; accepted loss must be deliberate and enumerated, never
  accidental.
- **Guard scope: `dx-ssh`/`dx-enter` deliberately unguarded**
  (2026-07-03, pass 3; the reviewer's either/or, narrow arm taken).
  Extending the temporary guards to every guest entry point would put a
  `container exec` round trip on hot interactive paths for a one-time
  event. Declined; instead the silent-continue claim is narrowed — the
  residual window (direct sessions on an already-running old container)
  closes at the next bring-up or restart, and the runbook gate is
  mandatory.
- **Deletion ledger over hardcoded name lists** (2026-07-03, pass 3):
  the inventory records every resource slated for removal and
  post-cleanup verification checks the ledger — hardcoded lists cannot
  cover arbitrary custom-profile images/volumes, keys, or markers.
- **Destroy-only `--container` path in `dx-mount`** (2026-07-03,
  pass 3): replaces the pass-2 mkdir-recreate fallback, which could
  resolve into an enclosing Git root and derive a different identity.
  The marker is the authorization; destroys skip source validation
  (mismatch checks must never block recovery — the principle settled in
  `flakes-to-nix.md` change 6); `refuse_default_destroy` unchanged.
- **Referrer-first is a global staging invariant, not a per-unit
  property** (2026-07-03, pass 5): all ledgered containers are
  destroyed and verified gone before any image, volume, key, or marker
  is removed. The resource sweep reuses the per-unit guarded tools,
  relying on their verified idempotence on missing resources — no new
  cleanup machinery.
- **Marker manifests are write-once** (2026-07-03, pass 5): recorded at
  creation, validated on every re-entry, changed only by
  destroy-and-recreate; legacy markers never auto-upgraded. A cleanup
  record that ordinary use can rewrite is not a record. Review of a
  deletion plan happens in a separate non-destructive invocation
  (`--print-destroy-plan`), never as output printed on the way to
  deleting.
- **Gate renamed to old-base exclusion** (2026-07-03, pass 3; token and
  conditionality in pass 4): `/bin/bash` absence excludes the flakes
  base but proves nothing about the pinned digest; the gate's token is
  `OLD_BASE_ABSENT`, never "official base". Provenance is established
  by the digest-pinned `FROM`, the ledger-verified image removal, and
  the fresh rebuild — exact-content provenance only under the digest
  pin; base-family only under the tag-only waiver.
- **Future pin procedure withheld** (2026-07-03, pass 1 / F-09, F-10):
  published as unresolved with named defects rather than inherited as
  ready.

## Out of scope / follow-ups (independent, with known interactions)

- **`.env` precedence fix + `DX_ENV_FILE`** (`flakes-to-nix.md`
  change 7) — a pre-existing bug unrelated to the base. Interaction
  (pass 1 / F-16, widened in pass 2): it is the clean precondition for
  the **entire changeover** — not only canary isolation but the
  destructive cleanup itself, whose profile/derived exports are
  re-clobbered by `.env` in child scripts; until it lands, the
  changeover requires a verified-absent or verified-clean `.env`. Also
  wanted by `port-plan.md`'s test isolation.
- **Bootstrap nixpkgs pin + provenance** (`flakes-to-nix.md` change 10)
  — the registry-drift bug is identical on the new base; its
  `--inputs-from` pre-flight gate moves with it. Until it lands, this
  plan and the README must not claim the guest lock governs bootstrap
  essentials (pass 1 / F-11, F-16). Its provenance-artifact design must
  also not be inherited blind — it predates the F-10 registration
  finding.
- **`setup_nix_volume` store-reuse fixes** (new, from pass 1 / F-09,
  F-10) — required before any volume-reusing pin bump; its own design
  change.
- **Port forwarding hardening** (`port-plan.md`) — unrelated; proceeds
  independently.
- **The 26.05 release bump** (`plan.md`) — unblocked from the image-tag
  gate by this change; scope per the narrowed claim in the Goal section.

## Risks / trade-offs accepted

- **One-time `/persist` loss** at changeover — accepted by decision
  (2026-07-03); mitigated by the auditable salvage step, with accepted
  exclusions enumerated.
- **No side-by-side comparison** after changeover day; recoverable any
  time via an isolated profile on a branch.
- **Tag mutability** if the digest pre-flight fails — tag-only pin,
  recorded here and in the README maintenance section; the changeover's
  provenance chain then fixes only the base family and tag, not exact
  content (pass 4).
- **Rollback is family-level, not byte-identical** (F-14) — the flakes
  tag is mutable; digest recording at pre-flight is the optional
  mitigation.
- **Nix version decoupled from the release** — governed by the alignment
  rule; future bumps are blocked on the F-09/F-10 fixes and until then
  are full rebuilds.
- **The temporary guards add two code branches** (`bootstrap.sh` boot
  path, `dx-start-container` bring-up path) for one release — accepted
  as strictly cheaper than the silent-stale-base hazard they close;
  removal criterion recorded, landing atomic with the flip.
- A machine that skips the changeover is caught on its next bring-up
  (host-side guard) or boot (in-guest guard). Direct
  `dx-ssh`/`dx-enter` sessions against an already-running old container
  remain uncaught until then — an accepted residual window (pass 3;
  see Decisions), bounded by the next lifecycle touch.

## Acceptance criteria

- Single Containerfile, exactly one non-blank line, official base pinned
  as tag-plus-manifest-list-digest (or tag-only with recorded waiver);
  the test asserts the exact line as a fixed string and each corruption
  mode fails (wrong tag, changed digest, digest-only, `latest`, extra
  instruction, extra line).
- Both bootstrap edits carry direct source assertions; no `/bin/bash`
  dependency remains in the guest payload; both temporary guard sites
  are present with their removal notes, landed atomically with the
  `FROM` flip.
- Section 5 passes on an official-base guest without `/etc/os-release`
  and still fails if the flake inputs point at the wrong release —
  proven by the mandatory in-guest `nix eval`, not only the lock
  substring grep.
- Canary: a full official-base bootstrap and corrected suite pass from
  asserted-absent isolated resources, including the same-base recreate
  cycle, before the primary is touched.
- The changeover runbook enforces the clean-configuration precondition
  (`.env` absent-or-fully-reviewed **and** inherited `DX_*`) before any
  destructive step, inventories per-container inspection **and profile
  files** into a deletion ledger (volume referrers identified, orphaned
  profile resources and key pairs ledgered without a container,
  affected referrers never deferred), stages cleanup globally
  referrer-first (all ledgered containers destroyed and verified gone
  before any resource removal — pass 5), verifies salvage before
  destruction, verifies **every ledger entry** absent after cleanup,
  and cannot mistake a skipped reset — or a failed verification probe —
  for success (two behaviorally-tested guards + a token-positive
  old-base exclusion gate that fails closed on exec errors and never
  claims more than exclusion).
- `dx-mount --container <name> --destroy` (change 5) destroys an
  orphaned side container marker-authorized without its source
  directory, resolves overridden resources from the write-once marker
  manifest (legacy markers reviewed via `--print-destroy-plan` and
  reconciled against the ledger before the destructive invocation),
  rejects unsafe names and mismatched recorded names, refuses without a
  marker, refuses an attach whose resolution mismatches the manifest,
  and never removes default resources — behaviorally tested, including
  that plan mode deletes nothing and ordinary re-entry never rewrites
  the marker.
- Shipped profiles rebuild from scratch on the new base and pass.
- No permanent dual-base machinery introduced: no `DX_BASE`, no
  `Containerfile.nix`, no inspect parsing; the only guard is temporary
  with a recorded removal criterion.
- `README.md`, `plan.md` (full sweep, stale-reference grep), and
  `mount-git.md` updated; `flakes-to-nix.md` marked superseded; the
  future pin-bump procedure published as unresolved, not as valid.
