# DX Bootstrap Performance Plan

Drafted 2026-08-19. Revised 2026-08-20 after implementation and validation,
following the review then held in `performance-refactor.md` against branch
`herdr-guest-integration` at `375f113`. That file has since been removed, both
reviews having been closed out; the pre-execution text remains in git at
`5e10d4b` and the implementation review's dispositions are tabled below.

## Status

Implemented and validated on the isolated `dx-test` profile on 2026-08-20.
The guest remains direct single-user Nix, with the daemon alternative deferred
as a separate architectural decision. The implementation and validation below
complete the delivery sequence; lifecycle permutations that were not run live
are covered by behavioral interruption and image-bump tests rather than claimed
as live-tested.

Do not begin with the earlier plan's implementation sequence. Instrument the
complete boot path and establish a behavior-tested import boundary first. A
change that only removes `chown -R dx:dx /nix` can leave the observed wall time
unchanged, and a naive replacement for `cp -a -n` can create a guest that boots
once but fails after GC, interruption, or a later restart.

## Implementation and Validation Results

The original ownership handoff was necessary because DX uses a direct,
single-user Nix store and database that must be writable by `dx`. The observed
slow path was more specific: the old `cp -a -n /nix/store/. ...` reset the
existing destination directory metadata to `root`, after which the persisted
sentinel still existed but the writability check failed and an unbounded
`chown -R dx:dx /nix` ran. Normal boot now has no unbounded recursive ownership
repair.

The selected implementation is:

- On a fresh volume, seed through a same-filesystem GNU-tar staging directory
  with numeric owner mapping. The transfer preserves hard links, symlinks,
  modes, timestamps, and dotfiles, and has recognizable ready-stage recovery.
- On an existing volume, use Nix-native `nix copy` from the image's read-only
  local store into an explicit target local store and state database. The
  source is the complete registered image path set, whose sorted paths are
  recorded as a SHA-256 identity.
- Gate on both registered closure and content. Content checks use
  `nix store verify --no-trust` without `--no-contents`: locally built image
  paths are unsigned and otherwise return status 2 even when their content is
  correct. That trust result is not corruption.
- Publish the identity marker and versioned GC roots atomically. Image roots
  use the `v2` layout, are established before pruning, and include the captured
  default profile. The default profile is captured before remount and restored
  after remount; essentials content is repaired when needed, including bounded
  host-key recovery.
- Probe durable Nix and persist UID/GID ownership before creating `dx`. Safe
  identities are reused; unsafe or conflicting identities take an explicit
  migration path. Ownership markers are transactional, versioned, and retain
  the compatibility sentinel. Recurring recursive chowns were removed or
  reduced to bounded XDG-parent repair and one-time migrations.
- Validate every marker as absent or a regular file before publication. Use
  GNU/Linux `mv -Tf` for atomic replacement and a validated Darwin fallback.
  This applies to tree-ownership, durable-Nix-identity, image-identity, Nix
  ownership, and Herdr-readiness markers. Tests cover safe failure, retained
  retry state, and refusal to nest a temporary marker under a directory-valued
  marker path.
- Timings now identify storage/import, ownership, persistence, Home Manager,
  and verification phases; wait output includes elapsed progress and recent
  guest log lines. `configure_nix_daemon` was renamed to
  `configure_single_user_nix`. `dx-reclaim` was made portable without guest
  `sed` and uses absolute guest `bash` and a rooted Nix profile path.

The work followed red-green-refactor behavior testing. The final checks were:

- importer: 49/49 GNU/Linux tests using real numeric UIDs/GIDs;
- Section 3: 102/102; focused live `dx-ai`: 43/43; Section 23: 36 pass/1
  skip; final `run_all_tests.sh --skip-integration` and the full non-integration
  suite pass. The full live suite passed earlier; the exact final tree received
  the normal-boot live smoke below.
- isolated `dx-test` factory-reset standalone test: pass, including the
  persistent write probe;
- coverage: 100% (1936/1936 executable lines), scope share 22.58%, with no
  ratchet rebaseline.

Red failures directly drove the `--no-trust` content gate, `mv -Tf` for the
live default-profile link, version-2 image roots, reclaim's no-`sed`/absolute-
`bash` portability, and ownership repair for a fresh `.local/state` tree.
The full live run initially exposed that fresh persist `.local`/state roots
were not owned correctly; the red-green fix was rerun successfully.

The exact final tree then received a normal-boot smoke on `dx-test`: 14.53s,
unchanged-image import skipped, Nix and ownership phases at 0–1s, Home Manager
at 6s, and healthy SSH. The final Linux behavior suite and coverage run were
also green on this tree.

The first exact-tree non-integration rerun caught a macOS-only Herdr fixture
ordering issue: the persistence standalone fallback sourced `common` after
the fixture's stubs and overwrote fake `run_as_dx` with `setpriv`. TDD made the
fixture load `common` before stubbing; Section 23 then passed 36 tests with one
skip, and the final `run_all_tests.sh --skip-integration` passed.

Mature same-volume boots measured 24.50s and 24.41s before the change, with
10,018 store paths and 477,999 used inodes. Final steady-state measurements
were 13.58s, 14.69s, and 13.38s with AI enabled; the clean immediate second
boot after factory reset was 7.69s. The final mature improvement is about 45%.
Two samples reporting 918s and 281s were rejected: the guest clock jumped
while host wall time was approximately 21s and 31s.

The end-to-end factory reset took 224.78s, including image/key rebuild and
cold network/build work. Its phases were approximately 45s essentials, 7s
fresh seed, 0s ownership migrations, and 158s Home Manager. It passed the
persistent write probe. After factory reset and AI activation, the store had
10,010 paths, 458,133 used inodes, and 8,127,928 KiB used.

GC initially deleted 2,750 paths (3.8 GiB) and optimized 86.8 MiB. The later
full reclaim deleted 10 paths (144.1 MiB), reduced the sparse image from 11 GiB
to 5.0 GiB, and reduced the store from 4.2 GiB to 3.8 GiB; both volumes were
trimmed. The post-reclaim restart skipped import, verified the rooted closure
with result 0, and preserved the default profile, `sh`, and the CA bundle.
That boot took 19.68s because Home Manager refetched for 14s.

Final root validation found three v2 image roots and a successful full content
verification. The temporary recovery directories used during live
default-profile recovery were removed after validation. All destructive
GC/reclaim/factory-reset operations were scoped to `dx-test`; unrelated
primary-host operational state is not part of this record.

One follow-up remains outside this performance change: the pre-existing
`dx-ai` publication path leaves Nix's automatic GC roots pointing at renamed
`.staging-*` paths. Those roots are dangling while the current AI profile is
valid, so GC preservation for the AI profile should not be relied on until
`dx-ai` root publication is fixed separately.

## Progress and Final-Review Chronology

- 2026-08-19: reproduced the ownership regression, reviewed the pre-execution
  findings then held in `performance-refactor.md` (removed once closed; text in
  git at `5e10d4b`), and expanded the scope from `/nix` ownership to all
  recurring recursive ownership work and import correctness.
- 2026-08-20: implemented the instrumented import, identity, ownership,
  essentials, GC-root, default-profile, reclaim, and documentation changes;
  completed the original red-green-refactor validation on isolated `dx-test`.
  The full live suite and 100% coverage were green before the final adversarial
  review fixes.
- Final adversarial review found that an existing `dx` group at the durable GID
  with no corresponding user made a redundant `groupadd` abort. TDD fixed this
  in `system.sh`; the final importer result is 49/49 and the conflicting-
  identity fallback remains green.
- Final adversarial review also found that directory-valued marker paths could
  make `mv` nest a temporary marker and falsely report success, causing a
  repeated migration. TDD hardening now validates absent-or-regular-file
  markers, uses atomic `mv -Tf` on GNU/Linux with a validated Darwin fallback,
  and preserves retry state on safe failure. The tree-ownership,
  durable-identity, image-identity, Nix-ownership, and Herdr-readiness marker
  cases include no-nested-temp regression tests.
- Final coverage is 1936/1936 executable lines (100%), with 22.58% scope share
  and no ratchet rebaseline. Diff and shell-syntax checks are green.

Validation safety context: destructive GC, reclaim, and factory-reset actions
were strictly scoped to `dx-test`. During validation an unprofiled
`dx-reclaim --help` was mistakenly invoked; the script has no help mode and it
was terminated during read-only “Before” usage reporting, before GC or trim,
so it made no changes. A read-only check also observed that `dx-host` SSH was
already broken/missing `sshd-session`; `dx-host` was not repaired, restarted,
or modified and remains out of scope. The two temporary live recovery
directories were removed after validation.

## Executive Summary

DX intentionally operates Nix in single-user mode as the `dx` guest user.
That requires `dx` to own the Nix store and database before Home Manager runs.
The ownership handoff is therefore necessary under the current architecture,
but the current implementation performs an expensive recursive ownership
repair more often than intended.

The immediate trigger is the image-store merge in `setup_nix_volume`:

```bash
cp -a -n /nix/store/. /mnt/tmp-nix/store/
```

`cp -a` reapplies the root-owned source directory metadata to the existing
destination directory. `/nix/store` becomes root-owned, the persisted ownership
sentinel remains present, the cheap writability check fails, and bootstrap runs:

```bash
chown -R dx:dx /nix
```

That walks every inode in the persistent Nix filesystem. The cost grows with
the complete history of the store.

The review found four correctness problems that must be solved with the
performance fix:

1. Paths copied from the image into an existing volume are not registered in
   that volume's Nix database, so GC can treat them as invalid garbage.
2. `cp -n` cannot repair a path that exists but is incomplete or truncated. A
   previous SIGBUS mitigation for this exact failure is stranded on unmerged
   commit `a428c55`.
3. A killed copy can expose a partially populated store path because the merge
   has no staging/publication boundary.
4. A replacement importer must account for hard links, not only modes,
   timestamps, symlinks, and hidden entries.

The broader performance issue is also larger than `/nix`: normal bootstrap
contains several recursive ownership operations over `/home/dx`, `/nix/cache`,
and `/persist/home/dx`, sometimes traversing the same persisted trees multiple
times. These must be timed and brought into the primary scope.

The recommended direction is:

- measure every unbounded recursive operation first;
- split volume mount/probe from store import;
- preserve the durable volume's UID/GID when creating `dx` where safe;
- import store paths through an atomic, registered, ownership-correct boundary;
- verify the bootstrap essentials closure after remount and repair it when
  necessary;
- retain recursive repair only as an explicit, one-time legacy migration;
- eliminate normal-boot recursive ownership walks whose cost grows with user
  data.

### Review finding disposition

| Review finding | Incorporated disposition |
| --- | --- |
| P1: other recursive chowns | Expanded from adjacent work into the primary performance goal, inventory, instrumentation, tests, and acceptance criteria |
| P2: missing database registration | Made filesystem publication plus target-database registration one import transaction |
| P3: partial/truncated paths | Added atomic staging, interruption recovery, essentials validation/repair, and the unmerged SIGBUS regression |
| P4: hard links | Added explicit transfer, fixture, and physical-growth requirements, refined so legitimate imports may still consume space |
| P5: vacuous ownership tests | Required a parameterized importer and real-UID Linux behavior tests rather than no-op stubs |
| P6: durable UID/GID | Reordered the target design to probe Nix and persist ownership before creating `dx`, with conflict validation |
| P7: stale bootstrap generation | Preserved `/nix/.dx-owner-set` beside the new marker and added generation-aware migration/testing |
| P8: unconditional merge | Added an image/closure identity gate coupled to essentials verification |
| P9: unreliable measurements | Added guest phase timing, same-volume comparison, generation confirmation, and false-stop handling |
| P10: coverage ratchet | Added finished-tree-only remeasurement and rationale requirements |
| P11: rename/order blast radius | Listed call/test sites and added the early `nix.conf` ordering decision |
| P12: wait output | Reused the existing log helper and recorded the configuration-registry contract |
| P13: missing user documentation | Added guest ownership and one-time migration documentation deliverables |

### Implementation review disposition

The post-implementation review of 2026-08-20 (recorded in `performance-refactor.md`,
removed once closed) raised I1–I10 against the finished tree. All are resolved;
the two criticals were fixed before commit and the remainder followed rather
than being deferred.

| Review finding | Resolution |
| --- | --- |
| I1: `getent` absent in the guest, conflict guard unreachable | `auth_entries_with_numeric_id` reads the materialized `/etc/passwd`/`/etc/group`; fixtures dropped their `getent` stub for a `getent`-free PATH plus occupied-UID and occupied-GID cases |
| I2: boot-blocking essentials gate omitted `--no-trust` | Added to `essentials_store_valid` and `repair_store_closure`, `--no-contents` still deliberately absent; tested by modelling the Nix trust boundary rather than string-matching the flag |
| I3: `DX_NIX_VOLUME_PHASE` global steering one function | Global removed; `bootstrap_main` calls `prepare_nix_volume` and `populate_prepared_nix_volume` directly |
| I4: `DX_NIX_OWNERSHIP_CONTENT_VALIDATED` exported into every child | Replaced by a parameter; the `run_as_dx "test -w …"` safety condition is retained in both branches |
| I5: duplicated PIPESTATUS, move-if-absent, and `shopt` idioms | `dx_pipeline_succeeded`, `dx_seed_staged_entries`/`dx_move_missing_entries`; the `shopt` save/restore is gone entirely, the helpers being subshell functions |
| I6: Section 25 always skips on macOS inside `unit/static` | The tier prints a note directing the reader to `tests/run-coverage-linux.sh`; no macOS fallback was added |
| I7: unrelated `bin/dx-reclaim` portability work | Kept, being required by the validated reclaim path; named separately in the commit message |
| I8: single-writer rule documented but unenforced | Host-side volume claim under `~/.dx-cache/nix-volume-claims` — outside the contended Nix filesystem — acquired by create/start and released by destroy, with stale-claim recovery |
| I9: no non-destructive recovery for an inconsistent volume | Runbook added to `docs/troubleshooting.md`, explicitly warning against deleting identity markers or GC roots |
| I10: essentials resolved through the mutable flake registry | `bootstrap-essentials` flake output installed with `--no-update-lock-file`; `docs/release-maintenance.md` corrected and the pin asserted in tests |

Two follow-ups landed after that review. The durable-identity marker was renamed
from `.dx-owner-layout-v2` to `.dx-durable-identity-v1`: it records a different
one-time migration than activation.sh's `.dx-owner-layout-v1` rather than a later
version of it, and the shared `v*` naming invited a future reader to treat one as
superseding the other. Neither marker had been committed, so no deployed volume
carries the old name. `tests/test_refactor_contracts.sh` also gained a contract
over `bootstrapEssentials`: I10 made that list the only declaration of the
pre-sshd closure, so the test asserts both that each providing package is still
declared and that each mapped binary is still genuinely invoked by bootstrap.

## Confirmed Evidence

### Reported symptom

`dx-wait-ssh` reported:

```text
Bootstrap wait limit: 5465s. A fresh factory-reset bootstrap can take several minutes.
.....
Bootstrap still running (32s elapsed). Latest guest log:
  Granting Nix ownership to dx...
```

The ownership message is printed before `chown -R` starts. Until that command
finishes there is no newer guest log line, so it remains the reported active
phase.

### Live guest sequence

The live guest log on 2026-08-19 showed:

```text
Merging freshly built image store into Nix volume...
Configuring Nix daemon...
Configuring guest environment with Home Manager...
Nix store is not writable by dx.
Granting Nix ownership to dx...
```

The existing `/nix/.dx-owner-set` marker had the expected `dx` owner. The
fallback ran because the preceding merge had changed `/nix/store` back to root.

A minimal in-guest reproduction confirmed that:

1. an existing destination directory starts owned by `dx`;
2. the source directory is owned by `root`;
3. `cp -a -n source/. destination/` changes the destination directory owner to
   `root`.

The current comment that this merge "never clobbers existing ones" is true for
regular file contents, but not for existing directory metadata.

### Current Nix model

The guest uses direct single-user Nix rather than a daemon:

- bootstrap initially runs as `root` so it can format and mount the persistent
  Nix filesystem;
- `/etc/nix/nix.conf` clears `build-users-group`;
- Home Manager, `dx-gc`, and `dx-reclaim` run Nix as `dx`;
- `NIX_REMOTE` is unset;
- no Nix daemon is started.

In single-user mode, the process modifying the store and database must own the
relevant locations. Leaving imported paths recursively root-owned is not a
sound solution: read-only execution may work while later optimization, repair,
or GC fails within those trees.

The function name `configure_nix_daemon` is therefore misleading. It writes
configuration for direct single-user operation and starts no daemon.

### Wait-limit calculation

The displayed `5465s` value is a maximum failure budget, not an expected
duration:

```text
2 * (1800s Home Manager timeout + 30s forced-kill allowance)
+ 5s retry delay
+ 1800s general clean-bootstrap grace
= 5465s
```

SSHD is the final bootstrap process, so `dx-wait-ssh` covers storage setup,
imports, ownership, Home Manager activation, verification, and SSH startup.

## Full Recursive-Ownership Inventory

The `/nix` handoff is not the only unbounded ownership traversal. The current
boot path contains these recursive call sites or targets:

| Location | Target | Frequency |
| --- | --- | --- |
| `activation.sh:63` | `/nix` | when the ownership sentinel check fails |
| `activation.sh:77` | `/home/dx` | every boot |
| `activation.sh:81` | `/nix/cache` | every boot |
| `persistence.sh:47` | `/persist/home/dx` | every boot |
| `persistence.sh:47` | `/home/dx/.config` | every boot |
| `persistence.sh:244` | persisted Herdr config | every boot |
| `persistence.sh:291` | persisted Herdr state | every boot |
| `activation.sh:200` | both Herdr directories again | every boot |
| `activation.sh:101` | `/persist/home/dx` again | when AI tools are enabled |
| `persistence.sh:74` | `/persist/home/dx/.local` | when AI tools are enabled |
| `system.sh:187` | `/home/dx/.ssh` | when authorized keys exist |

Several targets grow with user activity:

- `/nix/cache` contains Nix evaluation, binary-cache, tarball, and fetched-input
  state;
- `/persist/home/dx` contains AI tool configuration and session history;
- persisted Herdr state grows with sessions and history;
- `/home/dx` persists across stop/start of the same container rootfs.

Removing the `/nix` traversal can therefore move the silent pause to the next
recursive call. The user may then see only `Configuring guest environment with
Home Manager...`, even though Home Manager has not started.

The governing performance invariant is broader than the original plan:

> An ordinary start performs no recursive ownership operation whose cost grows
> with user or historical data.

Use the established `install -d -o dx -g dx` pattern from `persistence.sh` for
new directories. Existing populated trees should use explicit, marker-guarded
one-time migrations rather than unconditional repair.

## Store-Import Correctness Findings

### Imported paths are not registered

The fresh-volume path copies all of `/nix`, including
`/nix/var/nix/db/db.sqlite`, so the image's store registrations arrive with the
files. The existing-volume path copies only `/nix/store`; it does not update
the volume's existing database.

An unregistered store path is not a valid imported path merely because its
files exist. `dx-gc` and `dx-reclaim` can treat it as garbage, including paths
needed by the root bootstrap profile and `/usr/bin` symlinks.

The import transaction must publish both:

1. the complete filesystem object for each imported store path; and
2. its validity, references, deriver, and other required metadata in the target
   store database.

If a custom transfer is used, capture the image database before `/nix` is
hidden and merge the required registrations only after filesystem publication
succeeds. `nix-store --dump-db`/`--load-db` is one candidate that must be tested
for safe merging into a populated database. A Nix-native store copy is another
candidate and may avoid maintaining this protocol ourselves.

### Present-but-incomplete paths are not repaired

`cp -n` skips an existing file even if it is truncated. A prior branch recorded
a deterministic failure where an incomplete OpenSSH closure caused
`ssh-keygen -A` to SIGBUS before SSHD started. Commit `a428c55`, on the unmerged
`fix/dx-bootstrap-sigbus-volume-store` history, added:

- a bounded essentials-closure validity check after the volume remount;
- repair from substituters, with reinstall fallback;
- self-healing host-key generation rather than a fatal bare `ssh-keygen -A`.

That commit targeted the older `25.11` monolithic bootstrap and is not an
ancestor of the current branch. The relevant protection must be re-landed and
adapted to the modular `26.05` bootstrap rather than copied mechanically.

At minimum, the current work must add:

- a cheap registration/presence check of the root essentials closure on every
  boot;
- a tested policy for detecting registered-but-truncated critical content: a
  bounded full-content check of the essentials closure, targeted checks of the
  executables used before SSHD, or equivalent guarantees from the selected
  importer;
- a bounded content-verifying repair path when either the cheap check or the
  critical-content policy reports a problem;
- an explicit failure if repair cannot make the essentials closure valid;
- guarded recovery for `ssh-keygen -A`, or persistence/restoration of already
  valid SSH host keys, so a single bad executable does not produce an opaque
  pre-SSHD death.

### Import publication must be atomic and recoverable

A transfer must never make a half-written store path look complete. Each new or
replacement path must be fully materialized on the destination filesystem
before it becomes visible at its final `/nix/store/<hash>-<name>` location.

The design must define interruption recovery:

- staging entries are recognizable and safe to clean or resume;
- an existing valid path is never overwritten;
- an existing invalid path is quarantined or replaced through a defined rename
  sequence;
- the database is updated only after filesystem publication;
- the image/import marker is written only after files, registration, ownership,
  and closure verification succeed.

A same-filesystem staging directory plus rename is the minimum custom-import
boundary. If Nix's store-copy machinery already provides stronger atomicity and
registration, prefer it after validating ownership and performance.

### Hard links are an explicit requirement

`auto-optimise-store = true` and `nix-store --optimise` turn duplicate store
files into hard links, including links associated with `/nix/store/.links`.
The current `cp -a` preserves links implicitly. A replacement can silently
inflate disk and inode use if it preserves modes and symlinks but not hard
links.

Requirements differ by path:

- a fresh seed should preserve hard-link relationships in the imported image
  tree without a second destination-wide traversal;
- an incremental importer must preserve links within its transfer set where
  possible and must not corrupt existing optimized paths;
- if atomic per-path publication prevents preserving links across path
  boundaries, run or schedule a bounded/explicit optimization step and measure
  the resulting storage overhead.

Do not use the absolute assertion that block or inode counts can never increase:
adding legitimate paths necessarily consumes space. Instead compare physical
growth with the expected imported payload and include a fixture whose linked
source files remain linked, or are demonstrably re-optimized, at the target.

## Goals

1. An ordinary start performs no recursive ownership operation whose cost grows
   with user or historical data.
2. A factory-reset bootstrap creates the persistent store with the correct
   owner without copying everything and then walking it all again solely to
   repair ownership.
3. Every newly imported store path is complete, atomically published, and
   registered in the target Nix database.
4. A killed import leaves no visible partial store path and is recoverable on
   the next boot.
5. The bootstrap essentials closure is verified after remount and repaired
   before tools from it are executed, including a defined way to detect
   registered-but-truncated critical content.
6. Hard links, symlinks, modes, timestamps, and hidden entries are preserved or
   restored according to an explicitly tested policy.
7. Existing volumes migrate safely and at most once per ownership-layout
   version.
8. A base-image UID allocation change does not automatically force a recursive
   migration of every durable file when the existing durable identity can be
   reused safely.
9. An unchanged image does not trigger an unconditional full image-store merge
   on every boot.
10. Logs identify and time every potentially slow phase.
11. Home Manager, verification, GC, reclaim, and rollback compatibility remain
    correct.

## Non-goals

- Making factory-reset bootstrap instant. It must still format storage,
  populate the initial store, and activate Home Manager.
- Changing bootstrap publication as part of this work, although its stale-
  generation behavior must be accounted for in migration and measurement.
- Starting SSH before the guest environment is ready.
- Moving to daemon-backed Nix as part of the immediate fix.
- Optimizing every bootstrap command before phase timings identify its cost.

## Recommended Design

### 1. Instrument before selecting the implementation

Use Bash's `SECONDS` counter so timing does not depend on binaries that may be
unavailable before or during the `/nix` remount. Print a completion line for:

- essentials installation;
- filesystem detection, formatting, and mounting;
- fresh seed or image-store import;
- `/nix` ownership migration;
- `/home/dx` ownership work;
- `/nix/cache` ownership work;
- GitHub, AI, keyring, and Herdr persistence ownership work;
- Home Manager evaluation/activation;
- final tool verification.

Instrumentation must cover all recursive ownership sites listed above before
the implementation order is finalized. This establishes whether `/nix`
dominates and prevents the pause from merely moving to an unlabeled phase.

### 2. Split mount/probe from import

`setup_nix_volume` currently combines device discovery, filesystem creation,
mounting, initial copy, incremental merge, final mount, and fstab mutation.
Split it into explicit seams:

1. discover/format and mount the durable filesystem at a temporary location;
2. probe existing layout, identity, and import markers;
3. create `dx` with the selected identity;
4. seed or import through a parameterized transfer function;
5. verify and publish markers;
6. remount at `/nix` and validate the essentials closure.

The import function must accept source root, destination root/store, UID, and
GID as parameters. Production can pass the real paths; behavior tests can use
disposable fixtures without stubbing `cp`, `chown`, `stat`, or `run_as_dx` into
no-ops.

### 3. Preserve durable identity where safe

Do not always create `dx` first and migrate the volume to whatever UID/GID
`useradd` chooses. On an existing volume, the durable data should normally be
the identity source.

Before `create_user`:

1. inspect the owner of the existing persistent `/nix/store` directory;
2. inspect the owner of `/persist/home/dx` when it exists;
3. require the durable stores to agree, or choose and log an explicit migration
   policy;
4. reject UID/GID 0, reserved/invalid values, and identities already assigned
   incompatibly in the base image;
5. create the `dx` group/user with the durable GID/UID when safe;
6. for a new volume, allocate normally and record the resulting identity.

If the durable UID/GID conflicts with a base-image account, fall back to an
explicit one-time migration to a safe identity. Log both the conflict and the
chosen branch. This should be exceptional rather than the default response to
a base-image allocation shift.

This ordering is:

```text
install bootstrap essentials
mount the durable Nix filesystem at the temporary mount point
probe durable Nix and persist identity
materialize writable passwd/group files
create dx using the selected identity
seed or import the Nix store with that identity
mount the populated filesystem at /nix
validate the essentials closure
run Home Manager as dx
```

The Nix configuration ordering should also be reviewed. Writing the explicit
single-user `nix.conf` before the first root `nix profile install` states the
model consistently, provided the required filesystem tools are available.

### 4. Selected import mechanisms and spike outcome

The review recommends a GNU tar stream with create-side owner mapping because
`gnutar` is already installed and can assign UID/GID without a second ownership
walk:

```bash
tar -C "$src" --owner="$uid" --group="$gid" --numeric-owner -cf - . \
  | tar -C "$stage" -xf -
```

The tar stream is selected for the fresh seed. The pinned Nix 2.34.7 CLI was
also tested against the real guest tools for incremental import. The two
boundaries have different jobs: tar supplies ownership-correct full-volume
seeding, while Nix supplies store registration, reference metadata, validity
checks, and repair semantics for an existing volume.

#### Candidate A: Nix-native store copy

Use `nix copy` between the image's read-only local store and the temporary
target store, using an explicit `real`/`state` local-store URI. The spike and
live validation established that it:

- it can open the image source read-only and write the mounted target;
- it copies exactly the required image closure or registered store set;
- it atomically restores paths and registers them in the target database;
- it produces the required `dx` ownership, either by running against a target
  owned by `dx` or through a safe post-publication rule scoped only to imported
  paths;
- signature settings are correct for image paths built or installed locally;
- interruption recovery is deterministic;
- hard-link and physical-space behavior is acceptable;
- it avoids a full destination ownership traversal on unchanged boots.

The content gate deliberately uses `--no-trust`, not `--no-contents`, because
the image's local unsigned paths otherwise return status 2. Content is still
verified.

#### Candidate B: tar plus explicit registration

The tar importer remains the fresh-seed mechanism and has:

- create-side owner/group mapping;
- same-filesystem staging;
- atomic/recoverable publication of store paths;
- explicit registration merge after file publication;
- pipeline failure handling under `set -o pipefail` and checks of both producer
  and consumer status;
- one archive over the relevant set when hard links can cross path boundaries;
- a defined policy for `.links` and post-import optimization.

The implementation does not use a per-path archive blindly: it can lose hard
links that cross the selected path boundary. It also does not use
`cp -R --preserve=mode,timestamps` as a shortcut, since that omits link
preservation and does not solve registration or atomic publication.

For either candidate, importing only missing names is insufficient. An existing
but invalid destination path must be detected and repaired or replaced through
the recovery protocol.

### 5. Make markers transactional and backward-compatible

Replace the zero-information sentinel as the authoritative marker with a new,
versioned marker that records at least:

- ownership-layout version;
- expected `dx` UID/GID;
- image/import identity;
- successful completion of any legacy migration;
- successful filesystem publication, database registration, and essentials
  verification.

Keep `/nix/.dx-owner-set` as a regular, `dx`-owned compatibility marker. Do not
rename it or turn it into a directory. A stale or rollback bootstrap generation
still knows only this path and would otherwise perform the full recursive
handoff again.

The current bootstrap delivery flow can run the previous generation on the
first start after a payload change. Therefore all migrations must tolerate old
code executing, and validation/performance runs must confirm which generation
actually booted.

Publish markers only after success. If root introduces store content through
any future path, it must invalidate the import marker before writing or publish
that content through the same import transaction.

### 6. Gate unchanged-image imports

The current merge traverses the complete image store on every boot, even when
the image is unchanged. Record a deterministic identity of the relevant image
store or essentials closure before remount and skip import only when:

1. the recorded image identity matches; and
2. the essentials closure in the durable store still verifies.

The release number alone is not a sufficient identity because the image's
bootstrap closure can change without a release change.

GC or reclaim can remove imported paths, so an identity match without closure
verification must never suppress repair. Write the new identity marker only
after import, registration, and validation complete.

### 7. Retain cheap normal-boot checks and bounded repair

Normal bootstrap should check writable mutable roots such as `/nix/store` and
`/nix/var/nix`, validate marker structure and identity, and perform the bounded
essentials-closure check.

Do not recursively scan the store to prove ownership on every boot; that has
the same scaling defect as recursive repair. Correctness should follow from
controlling all writers, with an explicit migration or repair path when a cheap
invariant fails.

### 8. Remove the other recurring ownership traversals

After timing establishes the order, convert the `/home/dx`, `/nix/cache`, and
`/persist/home/dx` ownership operations to the same model:

- create bootstrap-owned directories with `install -d -o dx -g dx`;
- chown only files or directories bootstrap itself just created or moved;
- publish separate versioned migration markers for previously populated durable
  trees;
- avoid re-chowning Herdr config/state in both `setup_herdr_persistence` and
  `dx_activate_herdr`;
- never recursively traverse all AI state merely to add or repair one declared
  directory;
- preserve existing symlink-refusal and readiness-marker safety properties.

### 9. Clarify names, progress, and documentation

- Rename `configure_nix_daemon` to `configure_single_user_nix` or
  `configure_nix` and update its bootstrap and test call sites.
- Describe slow operations as `Importing image Nix closure`, `Migrating legacy
  Nix ownership`, or the actual phase rather than the generic `Granting...`.
- Print elapsed completion lines for every slow phase.
- Reuse `print_container_logs` in `dx-wait-ssh` with several lines instead of
  one. If a new configuration variable is introduced, add it through the
  configuration registry and `docs/configuration.md`; otherwise follow the
  existing literal-default environment-variable convention.
- Render the wait ceiling in minutes as well as seconds and explain the retry
  formula.
- Document the single-user ownership invariant in `docs/guest.md`.
- Document the one-time migration, its success marker, and safe interruption
  behavior in `docs/troubleshooting.md`.

The rename currently has at least three direct call/inventory sites:
`bootstrap.sh`, `tests/test_section3_bootstrap.sh`, and
`tests/test_sourceable_coverage.sh`. Changes to `ensure_nix_ownership` must also
update the Herdr and sourceable-coverage stubs that currently shadow it.

## Test Strategy

### Extract a behavior-testable import boundary

The current `setup_nix_volume` coverage probes stub `cp`, `mount`, and related
commands to no-ops. The ownership probes stub `stat`, `chown`, and `run_as_dx`.
Those tests can cover branches but cannot detect broken ownership or transfer
semantics.

Create a dedicated behavior test for the parameterized importer. Run it as root
inside the pinned Linux coverage runner so it can create a real unprivileged
user and assert distinct numeric owners. Reuse the repository's recording-
boundary pattern where true privilege operations cannot be exercised, but do
not treat a no-op `chown` stub as ownership evidence.

Keep line-coverage probes only for branches the behavior test cannot reach.

### Import behavior fixtures

Cover:

1. fresh destination ownership using a real non-root UID/GID;
2. merge into an existing `dx`-owned store without changing its root to root;
3. complete ownership of newly imported paths;
4. preservation of existing valid paths;
5. detection and repair/replacement of an existing truncated path;
6. same-inode hard-linked files in the source and the documented target result;
7. symlinks, executable and `0555` modes, timestamps, and dotfiles;
8. failure in both halves of any transfer pipeline;
9. interruption before publication, during path publication, and before
   database registration;
10. cleanup or resumption of stale staging/quarantine entries;
11. registration of newly imported paths in the target database;
12. `nix-store --gc --print-dead` not listing the bootstrap essentials solely
    because their registration was omitted;
13. marker publication only after files, registration, ownership, and validity
    all succeed;
14. unchanged-image gate reopening after GC removes a required path.

Retain a small regression fixture for GNU `cp -a source/.` that asserts the
existing destination directory's owner changes. It documents the exact trigger
and prevents a later simplification from restoring it.

### Identity and migration fixtures

Cover:

1. new volume with dynamically allocated identity;
2. existing Nix and persist volumes with matching durable UID/GID;
3. mismatch between Nix and persist identities;
4. durable UID/GID already occupied incompatibly by the base image;
5. root or otherwise unsafe durable identity;
6. old layout marker requiring exactly one migration;
7. matching versioned marker skipping migration;
8. changed UID/GID or layout version taking the explicit fallback path;
9. failed migration publishing no success marker;
10. preservation of `/nix/.dx-owner-set` for an old bootstrap generation.

### Essentials recovery fixtures

Adapt the useful assertions from unmerged commit `a428c55`:

1. registered and complete essentials closure takes the fast path;
2. missing or unregistered closure triggers repair;
3. truncated content triggers a content-verifying repair path;
4. repair failure is explicit and prevents execution of broken tools;
5. host-key generation has a bounded recovery path and no fatal unguarded
   `ssh-keygen -A` remains.

### Lifecycle coverage

Use isolated container, volume, image, port, and key names for:

1. factory reset followed by first `dx`;
2. stop and start of the same container;
3. container recreation with `/nix` and `/persist` preserved;
4. image rebuild introducing previously absent store paths;
5. interrupted image import followed by restart;
6. GC/reclaim followed by restart with the same image identity;
7. Home Manager activation after each applicable case;
8. store verification, optimization, GC, and reclaim;
9. old-generation/new-marker compatibility;
10. a simulated base-image UID allocation change.

The destructive factory-reset test must retain its isolated-profile guard and
must never target default `dx-host` resources.

### Coverage ratchet

The scope-share metric counts test lines in its denominator, so adding behavior
tests can lower the share even when production logic moves into the covered
scope. Re-measure `tests/coverage/ratchet.env` only against the finished tree,
after all production and test changes land. If the baseline changes solely due
to this known dilution effect, record the final numerator/denominator and reason
beside the existing history. Never take or commit a mid-change baseline.

## Measurement Protocol

The two obvious host-side signals are not independently reliable:

- the first start after a bootstrap edit can run the previous published
  generation;
- `dx-wait-ssh` can report a false stop after one negative container-state
  sample under load.

Use this protocol:

1. Add guest-side `SECONDS` timing before taking a baseline.
2. Publish the instrumented generation and start twice when required by the
   current publication behavior.
3. Confirm `Using bootstrap generation ...` in container logs and ensure the
   running generation matches the published generation before accepting data.
4. If `dx-wait-ssh` reports that the container stopped, re-check actual state
   and guest logs. Do not record the run if the guest remained healthy.
5. Use the same isolated volume for before/after mature-store measurements.
6. Record image identity, store-path count, filesystem block/inode usage, and
   enabled optional features beside every timing.
7. Record phase times from `container logs`, not from the duration of the host
   wrapper.
8. Collect expensive scale measurements outside the timed boot path so the
   measurement itself does not become part of bootstrap.
9. Run the factory-reset case separately and compare first-boot wall time; an
   improvement to mature-store restart must not hide a material cold-start
   regression.

Useful scale measures include immediate store-path count, `df` block/inode
usage, and a carefully timed `du` when physical-content comparison is needed.
Report the scale next to every timing; a mature-store number without its size is
not comparable.

## Acceptance Criteria

1. An ordinary start performs no recursive ownership operation whose cost grows
   with `/nix`, `/nix/cache`, `/home/dx`, `/persist/home/dx`, or persisted Herdr
   and AI state.
2. Recreating a container with a mature preserved store does not make bootstrap
   ownership time proportional to total historical store entries.
3. A factory-reset bootstrap does not copy the complete Nix tree and then walk
   it all again solely to repair ownership.
4. Factory-reset wall time does not materially regress.
5. Every newly imported store path is complete and registered in the target
   database before the import marker is published.
6. An interrupted import leaves no visible partial path treated as valid and
   recovers on the next boot.
7. An incomplete or unregistered essentials closure repairs itself when
   possible and otherwise fails with an explicit diagnostic before executing a
   broken bootstrap tool.
8. GC/reclaim does not delete required bootstrap essentials because their
   registrations were omitted.
9. Hard-link behavior is proven by fixtures, and physical store growth matches
   the expected imported payload without unexplained duplication.
10. Existing pre-change volumes perform no more than one explicit migration per
    layout version.
11. A compatible durable UID/GID is reused; conflicts take a logged, tested
    fallback rather than an accidental migration.
12. `/nix/.dx-owner-set` remains compatible with a stale or rollback bootstrap
    generation.
13. An unchanged image skips the full merge only when its identity matches and
    the essentials closure verifies.
14. Home Manager activation, store verification, optimization, GC, and reclaim
    pass after a fresh seed, image import, interruption recovery, and GC repair.
15. Progress logs identify every potentially slow phase and print its elapsed
    time.
16. Before/after results use the same volume and confirmed bootstrap generation.

## Completed Delivery Sequence

1. **Instrument all slow boundaries — complete.** Added `SECONDS` timing around storage,
   every recursive ownership target, persistence activation, Home Manager, and
   verification. Record same-volume cold and mature baselines using the
   measurement protocol.
2. **Extract the parameterized import seam — complete.** Added a
   real-UID Linux behavior harness and the failing `cp -a` directory-owner
   regression.
3. **Spike and select Nix-native copy versus tar — complete.** Proved
   registration, ownership, hard links, interruption recovery, content
   verification, and the performance boundary with the pinned Nix/GNU tools;
   the decision is recorded in section 4.
4. **Implement ownership-correct fresh seed and incremental import — complete.** Include
   staging/publication, target-database registration, failure cleanup, and the
   full transfer fixtures.
5. **Re-land essentials validation and repair — complete.** Adapted the relevant protection
   from `a428c55` to the modular current bootstrap and cover the SIGBUS/truncated
   path failure.
6. **Split mount/probe from user creation — complete.** Reused a safe durable UID/GID when
   possible and cover conflicts/mismatches.
7. **Add transactional, backward-compatible markers — complete.** Kept
   `/nix/.dx-owner-set`, add the versioned layout/import marker, and remove the
   recurring whole-store fallback from normal bootstrap.
8. **Gate unchanged-image import — complete.** Used a deterministic closure/store identity
   plus essentials verification so GC cannot make the gate lie.
9. **Remove the remaining unbounded ownership traversals — complete.** Used intended-owner
   creation and separate one-time migrations for home, cache, persist, AI, and
   Herdr state.
10. **Run lifecycle and performance validation — complete.** Included two-start generation
    confirmation, interruption, image bump, GC/reclaim, and factory reset.
11. **Finish coverage accounting — complete.** Re-measured the ratchet only on the completed
    tree and explain any test-denominator rebaseline.
12. **Rename and document — complete.** Updated configuration naming, progress output,
    `docs/guest.md`, `docs/troubleshooting.md`, and any configuration registry
    contract affected by new knobs.
13. **Evaluate daemon-backed Nix separately — deferred.** It is not coupled to this delivery.

## Larger Alternative: Nix Daemon

The official base already supplies `nix-daemon`, a `nixbld` group, and 32 build
users. DX could keep the persistent store root-owned and forward unprivileged
`dx` operations to a root-owned daemon. That would eliminate the ownership
handoff and align with Nix's stronger multi-user isolation model.

Treat this as a separate architectural decision because it changes:

- daemon and socket lifecycle without systemd as the guest supervisor;
- `NIX_REMOTE`, trusted-user, and substituter configuration;
- process supervision alongside foreground SSHD;
- bootstrap failure and shutdown behavior;
- `dx-gc`, `dx-reclaim`, and scripts that expect a directly writable store;
- security and integration tests.

For the current one-interactive-user guest, a correct atomic import plus
intended-owner creation is the smaller change. A daemon migration remains worth
evaluating if DX moves toward stronger isolation or multiple untrusted guest
users.
