# DX bootstrap performance plan review

Reviewed 2026-08-19 against `performance-plan.md` (Proposed) on branch
`herdr-guest-integration` at `375f113`.

**Verdict: the diagnosis is correct and the recommended direction is sound. Do
not start at step 1 of the delivery sequence.** Five findings (P1–P5) should
change the plan before any code is written: one of them (P1) means the plan as
written will most likely not remove the observed pause, and two (P2, P3) mean
the new merge can produce a guest that boots today and fails to boot later.
P6–P10 are execution-shaping; P11–P13 are hygiene.

| # | Severity | Finding | Recommended change |
| --- | --- | --- | --- |
| P1 | High | `/nix` is one of **seven** recursive chowns on the same boot path; the other six are unconditional and run every boot over `/home/dx`, `/nix/cache` and `/persist/home/dx` (which holds `~/.claude`) | Bring them into scope, or at minimum instrument all of them before choosing an implementation |
| P2 | High | Store paths merged into an existing volume are never registered in that volume's Nix database; `dx-gc` can delete the bootstrap toolchain | Register imported paths (`nix-store --dump-db`/`--load-db`) as part of the import |
| P3 | High | `cp -n` cannot repair a present-but-truncated path. The mitigation for the resulting SIGBUS boot failure exists only on an **unmerged branch** | Publish each imported path atomically via staging + `mv`, and re-land a validity check |
| P4 | High | Hard links are missing from the plan's preservation requirements, though `auto-optimise-store = true` and `dx-gc` make the store a hardlink farm | Add hard-link preservation to the requirement list and to the fixtures |
| P5 | High | The proposed ownership fixtures cannot fail: `cp`, `chown` and `run_as_dx` are stubbed to no-ops in the existing probes | Extract a parameterised import function; use the recording-boundary harness and real uids in the Linux runner |
| P6 | Medium | The reorder migrates the volume to whatever uid `useradd` picks, when it could take the uid from the volume | Probe the mounted volume *before* `create_user`; create `dx` with the volume's uid/gid |
| P7 | Medium | `dx-recreate` boots the *previous* generation, which will meet the new-format volume first | Keep `/nix/.dx-owner-set` in place beside the new marker |
| P8 | Medium | The merge itself is an unconditional full traversal of the image store on every boot, independent of ownership | Gate the whole merge on an image-identity marker |
| P9 | Medium | No before/after measurement protocol, and both obvious ways to measure are known-unreliable here | Specify the protocol, including the two-start rule and the `dx-wait-ssh` false stop |
| P10 | Medium | The coverage scope-share ratchet will fail when the new tests land | Re-measure `ratchet.env` against the finished tree and record why |
| P11 | Low | Rename blast radius, plus a nix.conf ordering smell the rename exposes | Update the three call sites; consider writing nix.conf before `install_essentials` |
| P12 | Low | The `dx-wait-ssh` changes are cheaper than the plan implies, but one has a documented contract cost | Reuse `print_container_logs`; a new env knob must go through the config registry |
| P13 | Low | No document in `docs/` mentions Nix ownership, and users will see a one-time migration | Add it to `docs/troubleshooting.md` and `docs/guest.md` |

## What the plan gets right (verified)

These claims were checked and hold; they do not need re-litigating during
execution.

- **The `cp -a` diagnosis.** `base-and-storage.sh:143` runs
  `cp -a -n /nix/store/. /mnt/tmp-nix/store/`. With a source operand ending in
  `/.`, GNU `cp` treats the destination as the directory being copied and, under
  `--preserve=all`, reapplies the root-owned source directory's metadata to it.
  `-n` protects existing *files*, not existing *directory metadata*. The
  in-guest reproduction in the plan matches GNU semantics.
- **`dx` ownership is genuinely required today.** `configure_nix_daemon`
  (`base-and-storage.sh:162`) clears `build-users-group`, no daemon is started,
  `NIX_REMOTE` is unset, and both `dx-gc` and `dx-reclaim` carry the comment
  "Nix must run as dx". The handoff is architectural, not incidental.
- **The 5465s derivation.** `dx_default_ssh_wait_timeout`
  (`bin/lib/dx-host-util.sh:72`) computes
  `attempts * (timeout + 30) + (attempts - 1) * retry_delay + 1800`, i.e.
  `2 * 1830 + 5 + 1800 = 5465`. It is a failure ceiling, exactly as the plan
  says.
- **`configure_nix_daemon` is misnamed.** It writes `/etc/nix/nix.conf` and
  starts nothing.
- **Deferring the Nix-daemon migration is the right call** for a
  one-interactive-user guest. The plan's list of what a daemon would change is
  accurate and each item is real work.
- **"Create directories with the intended owner" is already the house pattern.**
  `install -d -o dx -g dx -m 0755` appears at `persistence.sh:8` and
  `persistence.sh:58`, with a comment explaining exactly why. The adjacent-work
  section should name it rather than describe it.

## Findings

### P1 — High: `/nix` is one of seven recursive chowns on the same boot, and the other six are unconditional

The plan treats `chown -R dx:dx /home/dx`, `chown -R dx:dx /nix/cache` and
`chown -R dx:dx /persist/home/dx` as "adjacent work" that is "not the confirmed
cause of the reported pause". The full inventory on a single boot is larger than
the three lines quoted, and the ones outside `/nix` have no sentinel at all:

| Line | Target | Runs |
| --- | --- | --- |
| `activation.sh:63` | `/nix` | only when the sentinel check fails |
| `activation.sh:77` | `/home/dx` | every boot |
| `activation.sh:81` | `/nix/cache` | every boot |
| `persistence.sh:47` | `/persist/home/dx` + `/home/dx/.config` | every boot |
| `persistence.sh:244` | `/persist/home/dx/.config/herdr` | every boot |
| `persistence.sh:291` | `/persist/home/dx/.local/state/herdr` | every boot |
| `activation.sh:200` | both Herdr dirs again | every boot |
| `activation.sh:101` | `/persist/home/dx` again | when AI tools are enabled |
| `persistence.sh:74` | `/persist/home/dx/.local` | when AI tools are enabled |

Three of these targets grow without bound:

- `/nix/cache` is the persisted Nix user cache (`~/.cache/nix` is symlinked to
  it at `activation.sh:82`). It holds `eval-cache-*`, the binary-cache sqlite,
  and `tarball-cache` — a git object store that accumulates one object per
  fetched flake input.
- `/persist/home/dx` holds `.claude`, `.claude.json`, `.codex` and `.gemini`.
  A Claude Code state directory is tens of thousands of small files once it has
  session history. It is chowned recursively at least once and up to three times
  per boot, and `/persist` survives factory resets of everything else.
- `/home/dx` persists across stop/start (Apple `container` preserves the rootfs
  and resets it only on delete/create).

Two consequences for the plan:

1. **The observed symptom may move rather than disappear.** "Granting Nix
   ownership to dx..." was the last log line because nothing logs between it and
   the next phase. Remove that chown and the next silent stretch is
   `activation.sh:77` and `:81`, whose last printed line is "Configuring guest
   environment with Home Manager..." — a *more* misleading message, since Home
   Manager has not started. Acceptance criterion 1 ("no full recursive `/nix`
   ownership operation") can be met while the boot stays exactly as slow.
2. **Goal 1 is under-specified.** It says an ordinary start must not recursively
   traverse *the persistent Nix store*. The real invariant the plan is reaching
   for is: *an ordinary start performs no recursive ownership operation whose
   cost grows with user data.* Restate it that way and the adjacent work stops
   being adjacent.

Recommendation: keep the `/nix` fix as the first change, but land the timing
instrumentation (delivery step 1) over **all** of these before choosing an
implementation, and let the measurements decide the order. The `/persist` ones
are the cheapest to fix — `install -d -o dx -g dx` at creation plus a
first-boot-only migration guarded by a marker under `/persist`, which is the
same shape as the `/nix` marker the plan already designs.

### P2 — High: merged store paths are never registered in the volume's Nix database

The fresh-volume path copies all of `/nix` (`base-and-storage.sh:132`), so the
image's `/nix/var/nix/db/db.sqlite` comes with it and every seeded path is
valid. The merge path copies **only** `/nix/store`
(`base-and-storage.sh:143`). Nothing registers the newly arrived paths in the
volume's existing database.

Unregistered paths in the store directory are garbage from Nix's point of view.
`bin/dx-gc` runs `nix-collect-garbage --delete-older-than 14d` and
`bin/dx-reclaim` runs `nix-collect-garbage -d`, both as `dx`. After an image
rebuild introduces new paths — the exact case the plan wants to support
(lifecycle case 4) — a `dx-gc` can delete the freshly merged bootstrap toolchain
that `/usr/bin` symlinks and root's profile point at.

This is a pre-existing defect, not one the plan introduces, but the plan makes
it load-bearing in two ways: acceptance criterion 5 requires GC and
`nix store verify` to pass *after an image-store merge*, and the recommended
design explicitly wants to "identify newly imported store paths". Whatever
mechanism identifies them for chown purposes is the same mechanism that should
register them.

Recommendation: in the image (pre-remount) capture `nix-store --dump-db`, and
after the import run `nix-store --load-db` as `dx` against the volume. Add a
fixture asserting that a path present in the store but absent from the database
is registered by the import, and a lifecycle assertion that
`nix-store --gc --print-dead` does not list the bootstrap essentials after a
simulated image bump.

### P3 — High: the new merge must not re-entrench the partial-path boot failure, whose fix is not on this branch

`git log -S ensure_essentials_valid --all` finds exactly one commit, `a428c55`
("Repair the bootstrap toolchain and persist host keys to fix ssh-keygen
SIGBUS"), and `git merge-base --is-ancestor a428c55 HEAD` is false — it lives
only on `fix/dx-bootstrap-sigbus-volume-store`. No `ensure_essentials_valid`,
`generate_host_keys`, or `nix store verify` call exists anywhere in the current
tree. `configure_ssh` still calls a bare `ssh-keygen -A` (`system.sh:194`).

That commit's message documents the failure mode this plan is about to rewrite:
the volume's store held a stale root profile whose closure was only partially
materialised; `cp -a -n` could not repair it (`-n` skips existing files, so a
truncated file stays truncated, and a wholly missing path can only be supplied
if the *current* image happens to contain it); cold `mmap`-exec of the
incomplete binary SIGBUSes; under `set -euo pipefail` that kills the boot before
sshd, and because host keys are on the ephemeral rootfs it never self-heals.

Any "copy only what the destination is missing" implementation inherits this
exactly. Two design requirements follow, neither of which is in the plan's
must-satisfy list:

- **Publish atomically.** Extract each imported store path into a staging
  directory on the destination filesystem and `mv` it into place — a rename
  within one filesystem, which is how Nix itself publishes. A killed bootstrap
  then leaves a staging directory to clean up rather than a visible half-written
  store path. This also gives the plan its "surface partial-copy failures rather
  than silently publishing an incomplete import" property for free, and it is
  strictly stronger than checking an exit status.
- **Keep a validity check on the essentials closure.** The plan's
  cheap-invariant section (§4) checks *writability* of `/nix/store` and
  `/nix/var/nix`. Add a bounded validity check of root's essentials closure
  after the remount — `nix store verify --recursive --no-contents` over one
  profile path, not the store — and repair from substituters on failure. This is
  the one place where a second pass is worth its cost, because the alternative
  is a guest that cannot boot at all.

Recommendation: fold the `a428c55` mitigation into this work rather than leaving
it stranded on an unmerged branch. It touches the same function, in the same
place, for a failure with the same signature ("Container stopped before SSH
became responsive").

### P4 — High: hard links are missing from the preservation requirements

`configure_nix_daemon` writes `auto-optimise-store = true`
(`base-and-storage.sh:169`) and `bin/dx-gc:19` runs `nix-store --optimise`. Both
replace duplicate store files with hard links into `/nix/store/.links`. A mature
volume store is therefore a hardlink farm, and `.links` is typically the single
largest entry by inode count in the whole filesystem.

The plan's must-satisfy list names symlinks, modes, timestamps, hidden entries
and partial-copy failures — but not hard links. That matters because the
requirement is invisible in the current code: `cp -a` implies `--preserve=all`,
which includes `links`, so today's implementation preserves them by accident.
Two of the plan's three candidate implementations can silently drop them:

- `cp -R --preserve=mode,timestamps` (the natural spelling of "preserve
  everything except ownership") omits `links` and multiplies the store's disk
  usage.
- A tar stream preserves hard links, but only if the archive is created over the
  whole set of linked paths in one pass — a per-path tar of only the missing
  entries will break links that cross the selection boundary.

There is also a scaling note: `--preserve=links` makes `cp` hold an in-memory
table of every multiply-linked source inode. On the fresh-seed path over the
whole image store that is bounded and fine; it is another argument against
reaching for it on the destination side.

Recommendation: add "preserves hard links, and does not increase the store's
inode or block count" to the requirement list; add a fixture that hardlinks two
files in the source, imports, and asserts the destination pair still shares an
inode; and add "blocks used by `/nix` before and after" to the performance
measurements, where a broken-hardlink regression shows up immediately.

### P5 — High: the proposed ownership fixtures cannot fail as the suite is currently built

The plan's unit list ("a fresh destination receives the expected `dx`
ownership", "merging into an existing `dx`-owned store does not change the store
root to `root`") cannot be expressed against the existing probes:

- `tests/test_sourceable_coverage.sh` stubs `cp() { :; }` in every
  `setup_nix_volume` fixture (lines 407, 425, 444, 455). No copy semantics are
  exercised at all — these are line-coverage probes, not behaviour tests.
- The `ensure_nix_ownership` probes (lines 962–965) stub `stat`, `run_as_dx` and
  `chown`. The chown is a no-op.
- This is a known, twice-recurring failure mode in this repo: a no-op `chown`
  stub makes every ownership assertion vacuous, and so does asserting ownership
  in a test that does not run as root, since everything it creates is already
  owned by the caller and passes either way.

The suite already contains the right pattern.
`tests/test_section23_herdr.sh:665` defines `herdr_boundary_chown`, which
*records* the paths it was asked to chown (expanding `-R` through `find`), and
`herdr_boundary_run_as_dx`, which refuses to write into a directory absent from
that manifest — exactly as an unprivileged `ln` would. Reverting the fix it
guards makes it fail with the chowned paths listed.

Two structural prerequisites, both cheap, both matching established patterns:

1. **Extract the import as a parameterised function.** `setup_nix_volume`
   hard-codes `/nix` and `/mnt/tmp-nix`, so it can only be tested by stubbing
   the tools. `guard_old_base`, `link_system_bash`, `materialize_auth_files` and
   `essentials_profile_path` all already take a root prefix (`DX_GUARD_ROOT`,
   `DX_LINK_ROOT`, `DX_AUTH_ROOT`, `DX_ESSENTIALS_ROOT`) for precisely this
   reason. Give the import the same treatment — a function taking source,
   destination, uid and gid — and `setup_nix_volume` becomes a thin caller.
2. **Assert real uids in the Linux runner.** `tests/run-coverage-linux.sh` runs
   as root inside the pinned Ubuntu image, so a behaviour test can `useradd` a
   real unprivileged user, build a real fixture store (with a hardlink, a
   symlink, a `0555` directory, a dotfile and a pre-existing destination), run
   the real import, and assert `stat -c %u`. That is the only form of this test
   that can distinguish the fix from the bug.

Recommendation: the behaviour tests belong in a dedicated file run by
`run_all_tests.sh` (the `test_herdr_config_persistence.sh` precedent), with
`test_sourceable_coverage.sh` topping up only genuinely unreachable branches.
Retaining the `cp -a` regression reproduction, as the plan asks, is right — make
it assert the *destination directory's owner*, so it fails if someone
reintroduces `--preserve=all` on the destination side.

### P6 — Medium: take the uid from the volume, not from `useradd`

The plan correctly refuses to hard-code the uid, and correctly records expected
uid/gid in the marker so a mismatch triggers migration. But it then resolves a
mismatch by migrating the *volume* — a full recursive chown over a mature store,
i.e. the exact operation the whole plan exists to remove — whenever the base
image's reserved-user allocation shifts `dx`'s dynamically assigned id.

The volume is the durable artefact; the uid is not. Inverting the dependency
removes the migration case entirely: mount the volume at `/mnt/tmp-nix`, `stat`
the existing `store` directory, and create `dx` with that uid/gid (`groupadd -g`,
`useradd -u`). A new volume keeps today's dynamic allocation.

That requires probing the volume **before** `create_user`, which the plan's
stated order forecloses:

```text
create dx
mount the persistent Nix filesystem at the temporary mount point
```

The order that supports it is: mount at the temporary mount point → read the
existing owner (if any) → create `dx` with that identity → seed or merge →
remount at `/nix`. `setup_nix_volume` would need splitting into a
mount-and-probe half and an import half, which the P5 extraction wants anyway.

Two caveats to record if this is adopted: `useradd -u` fails if the id is
already taken (fall back to migration, and log which branch was taken), and the
uid must come from the store directory rather than the mount point, since the
mount root's ownership is set by `mkfs`.

### P7 — Medium: keep `/nix/.dx-owner-set` when the versioned marker lands

`bin/dx-start-container` starts the container before `dx-sync-bootstrap`
publishes, and the guest entrypoint proceeds as soon as `$root/current` exists —
so the first boot after publishing a bootstrap change runs the **previous**
generation. This is a recorded property of the repo, not a hypothetical; it has
already cost one live debugging session.

Applied here: the first container start after this change lands boots the *old*
`ensure_nix_ownership` against a volume that the *new* code will later manage.
If the versioned marker replaces `/nix/.dx-owner-set` — deleted, renamed, or
turned into a directory — the old code sees no sentinel, takes `needs_chown=1`,
and runs `chown -R dx:dx /nix` over the mature store. The change's first
observable effect would be the slowest boot yet.

Recommendation: publish the new marker at a new path and leave
`/nix/.dx-owner-set` present and `dx`-owned. It costs one `touch`. Add an
explicit note to the delivery sequence that step 6's measurements must be taken
on the *second* start, and that the generation should be confirmed
(`container logs <name> | grep -oE 'generations/[0-9TZ-]+'`) before any timing
is recorded or any regression is re-diagnosed.

### P8 — Medium: gate the merge itself, not only its ownership

`setup_nix_volume` runs on every boot, and on every boot where the volume
already has a store it reaches the `cp -a -n` merge. That is a full traversal of
the image store plus a `stat` of every corresponding destination entry —
unconditionally, whether or not the image has changed. It is bounded by image
size rather than by history, so it is not the reported pause, but it is pure
waste on the overwhelmingly common case where the image is byte-identical to
last boot.

The plan optimises how this copy assigns ownership without asking whether the
copy needs to happen. A marker on the volume recording the identity of the image
whose store was last merged (the release identity already derived in
`configure_release_identity`, or a hash of the image's store listing) turns the
steady-state case into one file read. That is a larger saving than any
improvement to the copy itself, and it composes with the ownership fix rather
than competing with it.

Caveat: the marker must be invalidated by anything that removes paths from the
volume — `dx-gc` and `dx-reclaim` both run `nix-collect-garbage` — otherwise a
GC that deletes a merged path leaves the guest with no way to get it back. The
safe form is "skip the merge if the image identity matches **and** the essentials
closure verifies", which is the P3 check reused.

### P9 — Medium: specify the measurement protocol, including the two known unreliable paths

The plan lists what to record but not how, and both obvious methods are
compromised on this project:

- `dx-wait-ssh` aborts on a *single* negative reading from
  `container_is_running` (`bin/dx-wait-ssh:45`) and can report "Container
  stopped before SSH became responsive" on a perfectly healthy boot under load.
  A timing run that builds a mature store in parallel is exactly the load that
  triggers it. Any measurement harness must treat that error as "retry and check
  `container logs`", not as a data point.
- A single `dx-recreate` measures the previous generation (P7).

Concrete protocol worth writing into the plan:

- Time phases inside the guest with bash's `SECONDS`, not `date` — it needs no
  binary on `PATH`, which matters in `install_essentials` and around the
  remount, and `dx-wait-ssh` already uses it for exactly that reason.
- Print one completion line per phase with its elapsed seconds, so
  `container logs` is the measurement artefact and no host-side instrumentation
  is needed.
- Record store scale as `find /nix/store -maxdepth 1 | wc -l` (paths) and `df` /
  `du -s` blocks (the P4 hardlink regression signal), on the same volume, before
  and after.
- Report each phase before and after against **the same volume**, and state the
  store size next to every number. A mature-store measurement without its path
  count is not comparable to anything.

Add an acceptance criterion the plan currently lacks: *the factory-reset path
must not get slower*. Every acceptance criterion is about the mature-store case,
so a candidate implementation that halves restart time and doubles first-boot
time passes as written.

### P10 — Medium: the coverage scope-share ratchet will fail when the tests land

`tests/run-coverage-linux.sh:61-65` computes covered-scope lines as a share of
all shell lines in `bin`, `tests` and `container`, and fails if it drops below
`scope_share_basis_points=1937`. Because `total_lines` counts `tests/`, adding
behaviour tests *lowers* the share — the file's own header calls this "a known
sharp edge in this metric: it makes writing tests look like a regression", and
it has been rebaselined for this reason five times.

The test surface P3–P5 imply (real-uid import fixtures, hardlink and atomicity
assertions, lifecycle and measurement additions) is large enough to move it.
Plan for it: re-measure against the **finished** tree, never mid-change — a
baseline taken mid-change has already shipped once carrying 15 bp of unearned
slack — and record the reason in `ratchet.env` alongside the existing entries.

Also note that the extraction recommended in P5 moves logic *into* the covered
scope, which pushes the share up and partially offsets this. Both effects should
be measured once, at the end.

### P11 — Low: rename blast radius, and the ordering smell it exposes

`configure_nix_daemon` has three call sites to update: `bootstrap.sh:14`,
`tests/test_section3_bootstrap.sh:25` (a sourceable-function inventory), and
`tests/test_sourceable_coverage.sh:471`. No document in `docs/` mentions it, so
`test_section10_docs.sh` is unaffected. `ensure_nix_ownership` additionally
appears at `test_section23_herdr.sh:749` and
`test_sourceable_coverage.sh:1030` as a stub; if it is split or renamed those
stubs must move with it or the Herdr ordering tests will call the real function.

Worth deciding while renaming: `install_essentials` runs a root
`nix profile install` *before* `configure_nix_daemon` writes the nix.conf that
clears `build-users-group`. Those essentials paths are therefore created under
the base image's own Nix settings. It is harmless today (they land in the image
store, and the merge is what carries them to the volume) and it becomes harmless
by construction once ownership is assigned at import time — but if the intent of
the rename is to make the single-user model explicit, writing nix.conf before
the first root `nix` invocation is the change that actually states it.

### P12 — Low: the `dx-wait-ssh` changes are cheaper than the plan implies, with one exception

`print_container_logs` already takes a line count (`bin/dx-wait-ssh:30`); the
progress path just passes `1` (line 62) while the failure paths pass `80`.
Showing more lines during progress is a one-token change.

The exception is making it configurable. `DX_SSH_POLL_INTERVAL` and
`DX_SSH_PROGRESS_INTERVAL` are read directly from the environment with a literal
default, but `DX_SSH_WAIT_TIMEOUT` comes from the registry — and every name in
`DXE_CONFIG_FIELDS` must appear in `docs/configuration.md` or
`test_section10_docs.sh` fails. Either follow the local convention (plain env
var with a literal default, like its two neighbours) or accept the documentation
contract.

Rendering the budget in minutes is worth doing, but the more useful phrasing is
*why* it is large: it is `attempts × (activation timeout + kill grace)` plus a
clean-boot grace, so it scales with `DX_GUEST_ACTIVATION_*` and is not an
estimate of anything.

### P13 — Low: the ownership model is undocumented, and users will see the migration

Nothing in `docs/` mentions Nix ownership, the `dx` single-user store, or
`/nix/.dx-owner-set`. This change adds a one-time migration whose whole point is
that it is slow and happens once — precisely the thing a user hits, does not
recognise, and interrupts. `docs/troubleshooting.md` should say what "migrating
Nix ownership" means, that it happens once per volume, and that interrupting it
is safe because the marker is published only on success (which the plan already
specifies). `docs/guest.md` should state the invariant that the store is owned
by `dx` and that root must not write to it after the remount.

## Recommended implementation

The plan asks for one of three candidates to be selected against the real GNU
tools. Based on what is already installed and what the constraints above imply:

**Prefer the tar stream with create-side owner mapping, run as root.**

```sh
tar -C "$src" --owner="$uid" --group="$gid" --numeric-owner -cf - . \
  | tar -C "$stage" -xf -
```

- It assigns ownership at write time with no second traversal, satisfying goals
  2 and 3 directly.
- `gnutar` is already installed by `install_essentials`
  (`base-and-storage.sh:25`), so it costs no new dependency.
- It preserves hard links, symlinks and modes (P4).
- It runs entirely as root, which avoids the failure mode hiding in the "execute
  the copy as `dx`" candidate: parts of `/nix/var` in a base image can be
  root-readable only, and a `dx`-run copy would fail on them — while GNU `cp`
  *silently tolerates* ownership-preservation failures for non-root callers, so
  the same candidate can also succeed while quietly doing nothing.

Combine it with staging + `mv` per imported path (P3) and database registration
(P2). Verify in the guest, as the plan instructs: that `--owner` on the create
side is honoured on extraction as root, that hard links survive the pipe, that
`0555` directories are populated before their mode is applied, that dotfiles at
the store root are included by `.`, and that a failure in either half is
detected — `tar | tar` under `set -euo pipefail` needs `PIPESTATUS` or
`set -o pipefail` to be checked explicitly, since the plan requires partial
imports to be loud.

## Recommended delivery sequence

The plan's sequence is reasonable; this reorders it so each step has a failing
test to earn it, and so the P1 measurement lands before the design is fixed.

1. **Instrument first, all of it.** Phase timing (`SECONDS`) around storage
   init, image merge, ownership, `/home/dx`, `/nix/cache`, `/persist/home/dx`,
   and Home Manager. Record a mature-store baseline on the *second* start. This
   is the red test for P1: it either confirms `/nix` dominates or redirects the
   work.
2. **Extract the import into a parameterised function** with no behaviour change
   (P5), and add the `cp -a` directory-metadata regression reproduction against
   it — asserting the destination directory's owner, with a real unprivileged
   uid, in the Linux runner.
3. **Implement ownership-correct seed and merge** (tar + staging + `mv`), with
   the hardlink, dotfile, symlink, mode, atomicity and loud-failure fixtures.
4. **Register imported paths in the volume database** (P2), with the GC
   assertion.
5. **Probe the volume for its uid/gid before `create_user`** and reorder
   accordingly (P6), then add the versioned marker beside — not instead of —
   `/nix/.dx-owner-set` (P7).
6. **Remove the recurring whole-store fallback**, leaving the cheap writability
   checks and the essentials-closure validity check (P3).
7. **Gate the merge on image identity** (P8).
8. **Fix the `/persist` and `/home/dx` chowns** using `install -d -o dx -g dx`
   plus a marker-guarded one-time migration (P1).
9. **Lifecycle and performance runs**, then re-measure `ratchet.env` against the
   finished tree (P10).
10. **Rename, logs, docs** (P11–P13).
11. Daemon-backed Nix stays a separate design document, as the plan says.

## Additions to the acceptance criteria

- No recursive ownership operation whose cost grows with user data runs on an
  ordinary start — including `/home/dx`, `/nix/cache` and `/persist/home/dx`.
- Factory-reset wall time does not regress.
- `/nix` block and inode counts do not increase across an import (hard links
  intact).
- Every path present in the store after an import is registered in the volume's
  Nix database, and `nix-store --gc --print-dead` does not list the bootstrap
  essentials.
- An interrupted import leaves no visible partial store path.
- A guest whose essentials closure is incomplete on the volume repairs itself
  and boots.
