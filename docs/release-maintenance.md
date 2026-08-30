## Release and Pin Maintenance

> Status: this section is the maintenance contract for the single official
> `nixos/nix` base image. A dual-base flip was once considered and dropped
> in favor of a one-time, one-way changeover onto the single official base
> — no `DX_BASE` selector, no flavor names, no coexistence. See
> [Base Image Changeover](#base-image-changeover-one-time) below for the
> cutover runbook.

### One release pin

The NixOS release is pinned in exactly one file — the flake inputs in
`container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.nix`:

```nix
nixpkgs.url      = "github:nixos/nixpkgs/nixos-26.05";
nixvim.url       = "github:nix-community/nixvim/nixos-26.05";
home-manager.url = "github:nix-community/home-manager/release-26.05";
```

`flake.lock` records the concrete revisions those branches resolved to
(`nixvim` and `home-manager` follow this flake's `nixpkgs` for their own
package set):

- the full guest toolset follows the lock — Home Manager activation builds
  from this flake;
- the root bootstrap essentials follow this lock through the local
  `bootstrap-essentials` flake output; bootstrap installs it with
  `--no-update-lock-file`, so the global flake registry is not consulted.

The base image is release-agnostic: it contributes the Nix tool itself and
a seed store that is merged once and then inert — after bootstrap, every
tool in use resolves through the lock. The release string also appears in
*names* (the context directory, the `dx-nixos-26.05*` image names); those
are identity labels refreshed during a release bump, not additional pins.
The local image name (`dx-nixos-26.05`) is a **mutable local cache key,
never provenance** — see "Build-cache trap" below; it says nothing about
which `Containerfile` produced the image bits.

After the base changeover (below), the docker-nixpkgs release-tag
availability gate that previously blocked the 26.05 upgrade is **gone**.
Release maintenance is **not** thereby reduced to two flake edits: it still
includes lock regeneration, `home.stateVersion` review, the aligned Nix
image-pin review (below — a release bump can change the correct image
tag), identity-name updates (context directory, local image name),
release-string test updates, and revalidation — see
[plan.md](../plan.md)'s playbook. Root bootstrap essentials follow the checked-in
flake lock through the `bootstrap-essentials` output, so this document does not
rely on the global flake registry for their provenance.

A release bump is therefore:

```bash
# 1. One place: edit the three branch refs in flake.nix (one file, one commit).
# 2. Re-lock the stable inputs only — run in the guest, or anywhere with Nix;
#    the macOS host needs none. --flake targets the context dir (the repo root
#    is not a flake); nixpkgs-unstable is left untouched so the optional AI set
#    does not move during a stable release bump:
nix flake update nixpkgs nixvim home-manager \
    --flake container/aarch64-darwin-apple-container-dx-nixos-26.05
# 3. Check the base-image alignment rule (below), then apply — MIND THE PIN:
#    - if the recheck did NOT change the Nix image pin, dx-recreate (which
#      reuses the /nix volume) is fine;
#    - if it CHANGED the pin, volume reuse is currently INVALID (see "Bumping
#      the Nix image pin" below) — do a full destroy-and-rebuild with salvage
#      (Upgrade / Bump step 7), NOT dx-recreate.
./bin/dx-recreate        # only when the Nix image pin is unchanged
tests/run_all_tests.sh
```

For the complete step-by-step procedure (image pre-flight, canary, and the
destructive apply), follow [Upgrade / Bump](#upgrade--bump-new-nixos-release).

The full release playbook, including the context-directory rename and the
parallel validation instance, is in [plan.md](../plan.md).

### Base-image alignment rule

`Containerfile` pins the official image by Nix version and manifest-list
digest:

```Dockerfile
FROM nixos/nix:2.34.7@sha256:<manifest-list digest>
```

Policy:

- match the major.minor of the pinned release's default Nix
  (`nixpkgs#nix.version` at the locked revision, i.e. `nixVersions.stable`),
  taking the newest patch tag within that minor. Bumping the release
  therefore tells you the correct image tag mechanically, and the
  Nix-version bump folds into the same deliberate event instead of being an
  independent chore;
- explicit tag **plus** the tag's multi-platform manifest-list digest (what
  `container image pull nixos/nix:<tag>` resolves) — never `latest`; a
  digest-only reference (no tag) is rejected;
- **re-query the digest immediately before any change** — never copy a
  previously recorded digest blind. Tags are mutable; a stale digest can
  silently pin different content than the tag currently resolves to.

A post-activation in-guest `nix --version` cannot verify the alignment —
the guest toolset itself ships the locked `nix`, which shadows the image's
on `PATH`. Verify against the pristine image directly instead:

```bash
container run --rm nixos/nix:<tag>@sha256:<digest> nix --version
```

This must match the tag's major.minor, and that in turn must match the
release's default Nix — checked in the guest (the macOS host has no Nix):

```bash
container exec dx-host nix eval --raw --no-update-lock-file --inputs-from /guest-bootstrap nixpkgs#nix.version
```

The alignment is test-enforced rather than templated into the
Containerfile: the Containerfile is deliberately a single `FROM` line (no
`ARG` indirection), and the macOS host has no Nix with which to evaluate
the version at build time.

#### Waiver — newest-patch clause, 2026-08-31

> **Status: in force once the refresh is landed.** All gates are green on the
> validated tip, including both canary paths. This waiver still describes the
> guest only from the point the refresh actually reaches it; it is not a claim
> about any machine that has not adopted it yet.

**Scope.** The stable-lock refresh runs on the image pinned as:

```
nixos/nix:2.34.7@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
```

**What is deviated from.** Only the "newest patch tag within that minor"
clause. The major.minor requirement is *satisfied*: the candidate's locked
`nixpkgs#nix.version` evaluates to 2.34.8, and the pinned image is 2.34.x.

**Re-queried immediately before this waiver was written**, per the rule above:

| Fact | Value |
| --- | --- |
| Locked `nixpkgs#nix.version` (candidate) | `2.34.8` |
| Newest `nixos/nix:2.34.x` tag | `2.34.8`, published 2026-07-06 |
| That tag's manifest-list digest | `sha256:1a711b619c8a713eff32c3f8d8781b3b4d0130cb91c0a57f67e87abfeeb90b01` |
| `linux/arm64` present for it | yes (`2.34.8-arm64`) |
| Actually pinned | `2.34.7@sha256:bf1d938835ab…` |

**Reason it cannot be satisfied.** Moving the pin to 2.34.8 requires the
destroy-and-rebuild-with-salvage procedure, because of the store-path content
collision recorded under "Bumping the Nix image pin" — observed directly on
2026-08-30 bumping the isolated `dx-test` profile from 2.34.7 to 2.34.8 with
its `/nix` volume retained. There is no valid volume-reusing pin bump today,
and a lock refresh does not justify a destructive rebuild of the primary.

**Evidence so far, stated as it stands.** The canary ran the refreshed lock on
the 2.34.7 image, with the running generation proved from the PID-1 lease and
its `flake.lock` hashing to the candidate. `nix flake check` passed and all
four aarch64-linux outputs built against the candidate lock, with the lock
hash unchanged afterwards.

Both canary paths are green on the validated tip, each 1045 passed / 0 failed
/ 9 skipped: reused-volume, and fresh-volume after a full factory reset and
cold rebuild. The running generation was proved from the PID-1 lease on each
boot.

An earlier revision of this waiver recorded the reused-volume canary at 1040
passed / 2 failed. Those two failures were an Apple Container runtime-client
race in `dx-migrate-persist`, unrelated to the refresh; they were fixed with a
bounded retry rather than argued away, and the gate is now genuinely green.

At no point did the alignment deviation itself cause an observed failure.

**Residual risk, and why accepted.** The guest toolset ships the locked Nix
(2.34.8) which shadows the image's 2.34.7 on `PATH`, so the version actually
used at runtime is the locked one; the image's Nix matters only for the
pre-activation window. That window is small, and both versions are the same
minor.

**Decision maker.** Damien Barrett.

**Expiry.** The next image-pin maintenance event, or the next stable-lock
refresh, whichever comes first. Resolution is tracked in
[`image-pin-collision-plan.md`](../image-pin-collision-plan.md); this waiver
must be closed or re-scoped as part of that work.

**Note on test enforcement.** `tests/test_section2_containerfile.sh` asserts
the literal `FROM` line, so it stays green throughout this mismatch. It pins
the expected digest; it does not prove the pin follows the locked
`nix.version`. Do not read its passing as evidence the alignment rule holds.

### Build-cache trap

`dx-create-image` skips the build whenever the local image name
(`dx-nixos-26.05`) already exists — editing the Containerfile changes
nothing until the old image is removed. `./bin/dx-destroy` removes
container **and** image; `./bin/dx-factory-reset` additionally removes all
three volumes and the SSH keypair (confirmation-gated, `--force` to skip).
Both operate only on the resources the active profile resolves.

### Bumping the Nix image pin — blocked by a store-path collision

**There is currently no valid, volume-reusing pin-bump procedure.** The
blocker is a store-path *content* collision between image versions. Observed
directly on 2026-08-30, bumping the isolated `dx-test` profile from
`nixos/nix:2.34.7` to `2.34.8` while retaining its `/nix` volume:

```
copying path '/nix/store/dy9skynmbyj7yc7dnn7qcgrfpwiy2yh6-base-system' to 'local://'...
error: hash mismatch importing path '/nix/store/dy9skynmbyj7yc7dnn7qcgrfpwiy2yh6-base-system';
         specified: sha256:0n8y708xzz6w5wfmjj9lfazp63f5rpkhwaz90hcvcnvlrl8n20v1
         got:       sha256:0nwfi38jwvazkb5mwvkg1i711v5j3g27z0p7p0m079kqhslmw5c1
Error: Nix could not import and register the image store closure.
```

Both images ship a `base-system` path with the same store path name and
different content. The volume holds the old one, registered, so importing
the new one is a collision and Nix refuses it. This is inherent to reusing a
store across images that disagree about a path's content; no amount of
registration hygiene resolves it. Making a volume-reusing bump possible is a
design change — the importer would have to quarantine or skip colliding
image paths, and that has consequences for what the booted guest can then
trust.

The failure is safe, and that is by design: it aborts before the `/nix`
remount, names the offending path, and leaves the volume intact. Revert the
pin, rebuild the image, and the guest comes back — verified on the same
canary.

**The only safe way to bump the Nix image pin is a full destroy-and-rebuild
with salvage** — the same one-time changeover procedure below (quiesce and
salvage `/persist`, referrer-first inventoried cleanup, factory reset,
rebuild, validate), not an in-place volume-reusing bump. What *is* safe to
rely on today: the alignment rule above, this section's build-cache trap
warning, and the digest re-query discipline.

Two earlier diagnoses were recorded here and have not survived testing. They
are kept only so nobody re-derives them:

- *"the store-seeding merge copies paths onto the volume without registering
  them — invisible to `nix path-info` and unprotected from garbage
  collection."* Written against the old `cp -a` merge and **no longer
  reproduces**. The importer uses `nix copy`, which registers; verified on
  the canary that imported paths resolve through `nix path-info` and that
  the in-use toolchain is GC-live rather than dead. Registration is in fact
  what makes the collision above detectable at all.
- *"a reused volume's profile paths can keep resolving `nix` to the old
  image's binary."* **Untested.** The pin-bump boot dies at the import, well
  before this could manifest, so it is neither confirmed nor ruled out.

## Upgrade / Bump (new NixOS release)

The step-by-step runbook for moving the pinned release, e.g. **26.05 →
26.11**. This is the sequence validated on the 25.11 → 26.05 bump
(2026-07-04); the reference policy it leans on lives in
[Release and Pin Maintenance](#release-and-pin-maintenance) above, and the
destructive apply in step 7 is [Base Image Changeover](#base-image-changeover-one-time)
below. Throughout, **OLD** is the current release (e.g. `26.05`) and
**NEW** is the target (e.g. `26.11`).

**Two hard-won rules before you start:**

- **Static checks do not catch the breakages that cost the most time.**
  `nix flake check` catches *eval*-time breaks (a removed package). It does
  **not** catch `home-manager` buildEnv path conflicts or runtime shell/tool
  API changes — those surface only at **live Home Manager activation**, i.e.
  at the canary in step 6. On the 26.05 bump, three separate breaks
  (`neofetch` removed, `ghostty.terminfo` colliding with ncurses, nushell's
  `$nu.home-path` renamed to `$nu.home-dir`) each slipped past the static
  suite and were caught only by rebuilding a real guest.
- **`nix flake check` needs a roomy container** (≥ 8 GB). The default
  container size OOMs mid-evaluation and is `SIGKILL`ed, which can look like
  a pass if you only check the exit path — always give it memory and read
  the final `all checks passed!` line.

### 1. Preconditions

- NEW's flake input branches exist and resolve — check without changing
  anything (throwaway container; the macOS host has no Nix):

  ```bash
  IMG='nixos/nix:2.34.7@sha256:<current pinned digest>'   # current base is fine
  for ref in \
      github:nixos/nixpkgs/nixos-26.11 \
      github:nix-community/home-manager/release-26.11 \
      github:nix-community/nixvim/nixos-26.11; do
    container run --rm "$IMG" nix --extra-experimental-features 'nix-command flakes' \
        flake metadata "$ref" >/dev/null 2>&1 \
        && echo "OK  $ref" || echo "MISSING  $ref"
  done
  ```

  If `home-manager/release-NEW` or `nixvim/nixos-NEW` is not published yet,
  **wait** — do not promote a mixed stable/unstable combination.
- Clean configuration surface (same precondition as the changeover):
  `env | grep '^DX_'` prints nothing, and `.env` is absent or reviewed
  line by line.
- A working tree with no unrelated changes (`tests/release-check.sh` rejects a
  dirty tree, and the canary must validate a committed bump).

### 2. Pick the aligned Nix image pin

The base image is pinned by **Nix version**, not NixOS release, per the
[Base-image alignment rule](#base-image-alignment-rule). A release bump can
therefore change the correct image tag. Determine NEW's default Nix and
choose the newest patch tag of that minor:

```bash
# NEW's default Nix version (throwaway container, locked to NEW's nixpkgs):
container run --rm "$IMG" nix --extra-experimental-features 'nix-command flakes' \
    eval --raw 'github:nixos/nixpkgs/nixos-26.11#nix.version'
# → e.g. 2.36.1  ⇒  pin the newest nixos/nix:2.36.x tag
```

Then **re-query the manifest-list digest from Docker Hub immediately**
(never copy a digest blind — tags are mutable) and confirm the tag has a
`linux/arm64` manifest. This exact `tag@sha256:digest` is what lands in the
`Containerfile`.

### 3. Pre-flight the new image (throwaway containers, no repo change)

Prove the pinned reference before editing anything:

```bash
NEW_IMG='nixos/nix:2.36.1@sha256:<re-queried digest>'
container run --rm "$NEW_IMG" /usr/bin/env bash -c 'echo env-bash-ok'
container run --rm "$NEW_IMG" nix --version                 # matches the tag
container run --rm --entrypoint sh "$NEW_IMG" -c \
    'if [ -e /bin/bash ] || [ -L /bin/bash ]; then echo OLD_BASE; else echo OK-no-bin-bash; fi'
mkdir -p /tmp/pf && printf 'FROM %s\n' "$NEW_IMG" > /tmp/pf/Containerfile \
    && container build -t dx-preflight -f /tmp/pf/Containerfile /tmp/pf \
    && container image rm dx-preflight        # digest-pinned FROM must build
```

`OK-no-bin-bash` is required — the official base ships no `/bin/bash`, which
is what the temporary old-base guards key on.

### 4. Make the bump (one revertible commit)

Do these together so the lock diff has a single cause. TDD where a test
encodes the change: flip the failing test first (`test_helpers.sh`'s
`DX_EXPECTED_NIXOS_RELEASE`, `test_section2_containerfile.sh`'s exact `FROM`
line), watch it fail against OLD, then make it pass.

- `git mv container/aarch64-darwin-apple-container-dx-nixos-OLD container/aarch64-darwin-apple-container-dx-nixos-NEW`
- `flake.nix` inputs → the three NEW branches (`nixpkgs-unstable` stays on
  `master`).
- Regenerate `flake.lock` — targeted, in a throwaway container bind-mounting
  the renamed context dir:

  ```bash
  container run --rm -v "$PWD/container/aarch64-darwin-apple-container-dx-nixos-NEW:/ctx" "$IMG" \
      nix --extra-experimental-features 'nix-command flakes' \
      flake update nixpkgs nixvim home-manager --flake /ctx
  ```
- `home.nix`: `home.stateVersion = "NEW"` (review the Home Manager
  state-version notes first).
- `Containerfile`: the single `FROM` line to the step-2 `tag@sha256:digest`,
  and update the exact-line string in `tests/test_section2_containerfile.sh`.
- `bin/dx-lib.sh` defaults: `DX_IMAGE=dx-nixos-NEW` and `DX_CONTEXT_DIR`.
- `tests/test_helpers.sh`: `DX_EXPECTED_NIXOS_RELEASE=NEW`.
- Release-string sweep — update every **live** reference, leave design
  history alone:

  ```bash
  grep -rn 'OLD' bin tests container README.md   # e.g. grep -rn '26\.05' ...
  ```

  Update `dx-nixos-OLD` image names, the `dx-nixos-OLD` assertions in
  `tests/test_section18_mount_git.sh`, profile `.env` comments, and this
  file's examples. Leave `plan.md`'s OLD/NEW playbook framing as history.
- Static gate — all green, plus a roomy `flake check`:

  ```bash
  # Note the underscore in the glob: test_section${s}_*.sh matches only
  # section s. Bare test_section$s*.sh would let s=1 also match 10-19 and
  # s=2 also match 20.
  for s in 0 1 2 3 5 9 10 18 20; do bash tests/test_section${s}_*.sh || break; done
  container run --rm --memory 8g --cpus 4 \
      -v "$PWD/container/aarch64-darwin-apple-container-dx-nixos-NEW:/ctx" "$NEW_IMG" \
      nix --extra-experimental-features 'nix-command flakes' \
      flake check --no-write-lock-file /ctx        # must end: all checks passed!
  ```

  Commit as one "Bump the pinned release to NixOS NEW" commit.

### 5. Fix compatibility breaks (separate commits, TDD)

`nix flake check` will name any **removed / renamed package** (eval error) —
fix each in `flake.nix` (e.g. `neofetch` → `fastfetch`) as its own commit
with the check as the gate. The **activation-only** breaks (buildEnv path
conflicts, shell/tool API changes) are not visible yet; they surface at the
canary in step 6. Keep every compat fix a separate commit from the raw bump
so a lock diff and a package swap never share a commit.

### 6. Canary — rebuild the isolated `dx-test` profile (non-destructive)

Gate the primary on a full, from-scratch NEW build of the throwaway
profile. This is where activation-only breaks appear; fix each (own commit),
restart, and re-run until green:

```bash
./bin/dx-profile dx-test ./bin/dx-destroy
./bin/dx-profile dx-test ./bin/dx-destroy-volumes --force
./bin/dx-profile dx-test ./bin/dx-destroy-keys
./bin/dx-profile dx-test ./bin/dx                      # fresh NEW bootstrap
./bin/dx-profile dx-test bash tests/run_all_tests.sh   # must be all-green
# Confirm the release oracle actually reports NEW (not a stale default):
./bin/dx-profile dx-test ./bin/dx-ssh \
    "bash -lc 'grep VERSION_ID /etc/os-release; nix --version'"
```

**Do not touch the primary until this is all-green and reports NEW.**

### 7. Apply to the primary

Because there is still **no valid volume-reusing pin-bump procedure** (see
[Bumping the Nix image pin](#bumping-the-nix-image-pin--unresolved-pending-store-reuse-fixes)
— blocked on the `setup_nix_volume` store-reuse defects), a pin-changing
bump reaches the primary the same way the base changeover did: **full
destroy-and-rebuild with salvage.** Follow
[Base Image Changeover](#base-image-changeover-one-time) below verbatim —
salvage `/persist` first (the `dx-get`/`dx-put` round-trip is now reliable),
inventory referrer-first, `dx-factory-reset`, rebuild on the NEW commit,
pass the old-base exclusion gate and the full suite, then re-establish
`gh auth` / `dx-ai` / repos. (Only once the store-reuse fixes land, and only
for a bump that does **not** change the Nix image pin, would an in-place
`./bin/dx-recreate` become a valid volume-reusing alternative.)

### 8. After the bump

- Remove any now-stale OLD image left behind (`container image ls`;
  `container image rm dx-nixos-OLD` once no container references it) — see
  the [Build-cache trap](#build-cache-trap).
- Update the concrete release numbers and the current digest in **this**
  section and in [Release and Pin Maintenance](#release-and-pin-maintenance)
  so the next bump starts from accurate examples.
- Once every machine and profile is on the new base, the temporary old-base
  guards (`guard_old_base` in `bootstrap.sh`, its twin in
  `dx-start-container`, and their tests) can be removed in a cleanup commit.

## Base Image Changeover (one-time)

> This is a **one-time, destructive** cutover — not a recurring maintenance
> task, and not a live flip. It replaces the (now removed) third-party,
> per-release community-published base with the official, digest-pinned
> `nixos/nix` base defined above. There is no in-place migration: existing machines are
> destroyed and rebuilt from scratch, with an auditable one-time `/persist`
> salvage step. This section is the guarded runbook for that changeover —
> each step copyable, with expected output, safe behavior when the resource
> it targets is already absent, an abort condition, and a verification
> before you continue to the next step.

### Clean-configuration precondition — required before every destructive step below

Two configuration surfaces can silently redirect a destructive command at
the wrong (including default) resources. Verify both before step 1 of the
changeover procedure, and re-verify before any later destructive step if
you are not running the whole procedure in one sitting:

- **`.env`** is sourced **as shell code** (`set -a`) by every child script,
  *after* the parent script has already exported its own values — so *any*
  line in it executes, and a `DX_*` line there silently re-overrides the
  profile's or `dx-mount`'s own exports. `.env` must be **absent, or
  reviewed line by line** — not merely free of `DX_*` entries.
- **Inherited `DX_*` environment**: exported variables in your shell
  survive into every resolution — `dx-mount` in particular captures
  pre-set values as user-supplied before it even sources the shared
  library. Confirm:

  ```bash
  env | grep '^DX_'
  ```

  Expected output: **nothing**. If anything prints, unset it, or print and
  review every effective resource name immediately before each destructive
  command below.

Destroying under a clobbered or polluted resolution is strictly worse than
validating under one — do not proceed past this point until both checks
are clean.

### Canary gate — required before the primary is touched

Before anything on the real machine is destroyed, prove a full
official-base bootstrap works, in isolation, on the exact commit that will
land:

1. Create a dedicated cutover profile (the `tests/profiles/dx-test.env`
   pattern): a unique container name, image name, SSH port, all three
   volume names, and its own key pair.
2. Re-check the clean-configuration precondition above — an unisolated
   `.env` or environment defeats canary isolation too.
3. **Assert absence** — confirm the cutover profile's container, image,
   volumes, and keys do not already exist:

   ```bash
   container list -a
   container image ls
   container volume ls
   ```

   Expected: nothing named after the cutover profile. **Abort condition**:
   any of them already exist — pick different names or clean up first.
4. Bring it up on the branch carrying the new `FROM` line:

   ```bash
   ./bin/dx-profile <cutover> ./bin/dx
   ```

   Expected: bootstrap completes and SSH is reachable under the profile.
5. Run the full suite, profile-aware, from a **clean, committed tree** —
   `test_section13_final_review.sh` fails on tracked modifications by
   design, so this validates the changeover **commit**, never a dirty
   working tree. Then run the same-base recreate cycle, to prove volume
   reuse still works on the new base:

   ```bash
   ./bin/dx-profile <cutover> tests/run_all_tests.sh
   ./bin/dx-profile <cutover> ./bin/dx-destroy
   ./bin/dx-profile <cutover> ./bin/dx
   ```
6. Tear the canary down completely, in this order:

   ```bash
   ./bin/dx-profile <cutover> ./bin/dx-destroy
   ./bin/dx-profile <cutover> ./bin/dx-destroy-volumes --force
   ./bin/dx-profile <cutover> ./bin/dx-destroy-keys
   ```

   Verify: `container list -a` / `container image ls` / `container volume
   ls` show nothing named after the cutover profile, and its key files are
   gone.

**Abort condition**: any canary step fails, or teardown leaves a resource
behind. Do not start the changeover procedure until the canary passes
cleanly end to end. The primary factory reset (step 4 below) is gated on
this run passing.

### Changeover procedure (per machine)

**Ordering rule**: destroy referrers before resources. `container image
rm` / `container volume rm` fail while any container still references the
target, and that can strand a half-reset machine mid-procedure. Every step
below is safe to re-run; **step 2 (inventory) is the re-entry point** if
you stop partway, and nothing destroys the primary before step 4.

1. **Quiesce and salvage `/persist`.** Stop active guest workloads; push
   every repository and verify the remotes are up to date. Then:

   ```bash
   ./bin/dx-get /persist ./persist-backup-$(date +%Y%m%d)
   ```

   **Inspect the copied tree by eye before continuing — this is not
   optional.** `dx-export` is **not** a substitute: it wraps `container
   export`, which captures the root filesystem only, not named-volume
   contents. Record what is deliberately not preserved (for example
   gh/AI credentials — these are re-established in step 9, not salvaged).

   **Abort condition**: the backup looks incomplete or wrong — stop and
   investigate before touching anything else.

2. **Inventory and deletion ledger.** Enumerate every resource that will be
   removed, and write it down (a text file, a scratch note — anything you
   check step 5 against):

   ```bash
   container list -a
   ls ~/.dx-cache/mount-identities/ 2>/dev/null   # absent is fine — no side containers
   ```

   For **every** profile file — `tests/profiles/*.env` and any
   user-maintained profiles — read its image, volume, and key values into
   the ledger **even when no container currently exists for it**:
   container inspection alone cannot discover an orphaned profile's image,
   volumes, or keys. Cross-check for unaccounted `dx-*` strays:

   ```bash
   container image ls
   container volume ls
   ```

   Then run `container inspect <name>` on **each** container in the list
   and read the output yourself — `container list -a` shows images but
   **not** volume mounts, so volume referrers are visible only this way.
   While reading, add to the ledger every container, image, and volume
   (persist/bootstrap, custom-profile, and side-container volumes alike),
   key file, and identity marker that is slated for removal.

   Any container referencing a ledgered image or volume **must** be
   destroyed in step 3 — it cannot be deferred, since the resource removal
   later fails while it is still referenced. Leave alone only containers
   referencing nothing ledgered (for example Apple's own `buildkit`
   builder).

   **Abort condition**: you cannot account for a `dx-*` resource — stop
   here, not mid-reset.

3. **Destroy non-default referrers, staged globally referrer-first.** Do
   this in three stages, not per-unit — the per-unit tools interleave
   container and resource removal, so staging avoids a resource shared
   *across* units (the default image every side container references, or
   an override-shared volume) failing mid-unit:

   - **3a — containers only**, every ledgered container:

     ```bash
     ./bin/dx-profile dx-test ./bin/dx-destroy-container
     ./bin/dx-profile dx-tinty ./bin/dx-destroy-container
     # ... and any custom profiles
     DX_CONTAINER_NAME=<name> ./bin/dx-destroy-container   # per side container
     ```

   - **3b — verify**: `container list -a` shows no ledgered container.
     **Abort condition**: any survives — stop and resolve before 3c.

   - **3c — resources**, through the same guarded tools (each is verified
     idempotent on already-missing resources, so re-running any of these is
     always safe):

     - side containers still attached to their checkout:

       ```bash
       ./bin/dx-mount <source-dir> --destroy
       ```

     - an **orphaned** side container (checkout moved or deleted) — do
       **not** try to recreate the directory to make the normal form work;
       `dx-mount` resolves identity via `git rev-parse --show-toplevel`,
       so a recreated empty directory can resolve into an *enclosing* Git
       root and derive the wrong identity. Instead, in two separate
       invocations:

       ```bash
       ./bin/dx-mount --container <name> --print-destroy-plan
       # reconcile the printed plan against your ledger, THEN:
       ./bin/dx-mount --container <name> --destroy
       ```

     - shipped profiles:

       ```bash
       ./bin/dx-profile dx-test ./bin/dx-destroy
       ./bin/dx-profile dx-test ./bin/dx-destroy-volumes --force
       ./bin/dx-profile dx-test ./bin/dx-destroy-keys
       # repeat the same triple for dx-tinty and any custom profiles
       ```

4. **Factory-reset the primary** — gated on the canary gate above having
   passed:

   ```bash
   ./bin/dx-factory-reset
   ```

   Removes the primary container, image, all three volumes, and keys
   (confirmation-gated).

5. **Verify the ledger, not a hardcoded list.** Every entry recorded in
   step 2 must now be absent: containers via `container list -a`, images
   via `container image ls`, **all** volumes via `container volume ls`
   (persist/bootstrap, custom-profile, and side-container volumes alike),
   key files, and identity markers on the host filesystem.

   **Abort condition**: any ledger entry survives — return to step 2.

6. **Rebuild:**

   ```bash
   ./bin/dx
   ```

   Fresh image from the edited Containerfile, fresh volume seed, fresh
   bootstrap.

7. **Old-base exclusion gate.** `/bin/bash` absence **excludes** the known
   flakes base — it does not by itself prove the image is `nixos/nix` at
   the pinned digest. Positive provenance instead comes from the
   digest-pinned `FROM`, the ledger-verified image removal in step 5, and
   the fresh rebuild in step 6 — exact-content provenance only under the
   digest pin; base-family only under a tag-only waiver. Run exactly this
   — it fails closed on any `container exec` error, and treats absence as
   a positive token, never as the fallback branch of a failed probe:

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

   Expected output: `OK: old flakes base excluded (no /bin/bash)`. Any
   other output is a hard stop. The same invariant is also enforced by a
   pair of temporary guards on every container boot and every
   `dx-start-container` bring-up, for as long as they remain in the tree
   (see the temporary old-base guards described above) — this manual gate exists because a
   bring-up against an **already-running** container only re-syncs the
   bootstrap payload; it does not by itself prove which image is running.

   **Accepted residual window**: `dx-ssh` and `dx-enter` bypass
   `dx-start-container`, so a direct session against an
   **already-running old container**, between pulling this change and that
   container's next start or restart, is caught by no guard. The window
   closes at the next lifecycle touch; it does not exempt you from running
   this gate.

8. **Validate:**

   - [ ] `./bin/dx` completed bootstrap; sshd reachable; `dx-enter` works.
   - [ ] Full test suite passes.
   - [ ] Old-base exclusion gate (step 7) passes; neither temporary guard
         fired during the rebuild.
   - [ ] AI-tools opt-in path (`dx-ai`, keyring, persistence links) works.
   - [ ] Timezone, persist links, and `gh` persistence are intact after a
         `dx-destroy && dx` cycle — same-base volume reuse is revalidated,
         not assumed, on the new base.
   - [ ] Both shipped profiles (`dx-test`, `dx-tinty`) rebuild from scratch
         and pass their suites (their old images/volumes were removed in
         step 3).

9. **Re-establish intentional state — last, only after validation
   passes:** `gh auth login`, `dx-ai` opt-in, re-clone into `/persist`.
   Anything deliberately not salvaged in step 1 is re-created here, not
   before.

**Rollback**: `git revert` the changeover commit, then repeat this same
procedure in reverse. Fresh volumes both directions, so no store-schema
compatibility proof is needed — but the flakes tag is **mutable**:
rollback restores the old base family and release label, not necessarily
byte-identical content (mitigate by recording the pulled flakes digest
during pre-flight if that matters), and it presumes the flakes `25.11` tag
is still published.
