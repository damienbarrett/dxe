# DX Bootstrap Performance Plan

Drafted 2026-08-19.

## Status

Proposed. The ownership performance defect has been reproduced, but no
implementation has been selected or applied yet.

## Summary

DX intentionally operates Nix in single-user mode as the `dx` guest user.
That requires `dx` to own the Nix store and database before Home Manager runs.
The ownership handoff is therefore necessary under the current architecture,
but the current implementation performs an expensive recursive ownership
repair more often than intended.

The immediate cause is the image-store merge in `setup_nix_volume`:

```bash
cp -a -n /nix/store/. /mnt/tmp-nix/store/
```

`cp -a` preserves the root-owned source directory metadata and reapplies it to
the existing destination directory. After the merge, `/nix/store` is once
again owned by `root`. `ensure_nix_ownership` sees that the store is not
writable by `dx` and runs:

```bash
chown -R dx:dx /nix
```

That walks every inode in the persistent Nix filesystem. As the store grows,
ordinary bootstrap time grows with it.

The recommended direction is to establish the correct owner while seeding or
merging content into the persistent filesystem. Recursive ownership repair
should remain only as a one-time legacy-volume migration, not as a normal boot
operation.

## Observed Symptom

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

The live guest log on 2026-08-19 showed the sequence:

```text
Merging freshly built image store into Nix volume...
Configuring Nix daemon...
Configuring guest environment with Home Manager...
Nix store is not writable by dx.
Granting Nix ownership to dx...
```

The persisted ownership marker already existed and had the expected `dx`
owner. The fallback ran because the preceding merge had made `/nix/store`
root-owned again.

A minimal reproduction inside the guest confirmed that:

1. an existing destination directory starts owned by `dx`;
2. the source directory is owned by `root`;
3. `cp -a -n source/. destination/` changes the destination directory owner to
   `root`.

The comment that this merge "never clobbers existing ones" is true for regular
file contents, but not for existing directory metadata.

## Why `dx` Ownership Is Necessary Today

The guest currently uses direct single-user Nix rather than a Nix daemon:

- bootstrap initially runs as `root` so it can format and mount the persistent
  Nix filesystem;
- `/etc/nix/nix.conf` explicitly clears `build-users-group`;
- Home Manager and subsequent Nix commands run as `dx`;
- `NIX_REMOTE` is not configured to use a daemon.

In single-user mode, operations that update the store or its database must run
as the user that owns those locations. If the store remains root-owned, the
Home Manager activation run as `dx` cannot reliably add, optimise, or garbage
collect store paths.

The current function name `configure_nix_daemon` is therefore misleading: it
does not start a daemon and its configuration supports the direct single-user
model.

## Why the Wait Limit Is 5465 Seconds

The displayed value is a maximum failure budget, not an expected duration. It
is derived as:

```text
2 * (1800s Home Manager timeout + 30s forced-kill allowance)
+ 5s retry delay
+ 1800s general clean-bootstrap grace
= 5465s
```

`dx-wait-ssh` polls SSH while bootstrap is running. SSHD is deliberately the
final bootstrap process, so this one wait covers storage initialization,
ownership, Home Manager activation, verification, and SSH startup.

## Goals

1. An ordinary start must not recursively traverse the persistent Nix store to
   repair ownership.
2. A factory-reset bootstrap must create the persistent store with the correct
   owner, without copying everything as root and then walking everything a
   second time.
3. Image paths merged into an existing store must be usable and removable by
   single-user Nix running as `dx`.
4. Existing volumes must migrate safely and at most once.
5. Bootstrap logs must identify and time slow phases clearly.
6. Existing persistence, store-path availability, Home Manager activation,
   GC, and reclaim behavior must remain correct.

## Non-goals

- Making a factory-reset bootstrap instant. It must still format storage,
  populate the initial store, and activate Home Manager.
- Changing the bootstrap publication mechanism.
- Starting SSH before the guest environment is ready.
- Moving to daemon-backed Nix as part of the immediate fix.

## Recommended Design

### 1. Create `dx` before importing the Nix filesystem

Move the authentication-file materialization and `create_user` steps before
`setup_nix_volume`. `install_essentials` must remain first because user and
group management depend on those tools.

This makes the dynamically allocated `dx` UID and GID available when the
persistent filesystem is first populated. Do not hard-code the IDs: the
current base image already reserves IDs for its Nix build users, and a future
base may allocate them differently.

The intended high-level order is:

```text
install bootstrap essentials
materialize writable passwd/group files
create dx
mount the persistent Nix filesystem at the temporary mount point
seed or merge content with dx ownership
mount the populated filesystem at /nix
run Home Manager as dx
```

The exact order of release identity, system Bash linking, SSH configuration,
and timezone setup should remain unchanged unless their dependencies require a
small adjustment.

### 2. Assign ownership at copy time

For a new volume, make the destination root writable by `dx`, then copy the
image Nix tree so newly created entries are owned by `dx`. For an existing
volume, add only missing image-store content under the same ownership rule.

Candidate implementations include:

- execute the copy as `dx` with ownership preservation disabled while still
  preserving modes, timestamps, and symlinks;
- create and extract a tar stream whose archive owner and group are explicitly
  mapped to the discovered `dx` UID and GID;
- explicitly identify newly imported store paths and normalize only those
  paths, never the complete persistent store.

The chosen implementation must be tested against the actual GNU tools in the
guest. In particular, it must:

- preserve symlinks and executable/read-only modes;
- avoid changing metadata on an existing `/nix/store` directory back to root;
- handle hidden entries intentionally, including any Nix bookkeeping paths;
- surface partial-copy failures rather than silently publishing an incomplete
  import;
- avoid a second traversal of the entire destination tree.

Simply restoring ownership of `/nix/store` after the current `cp` would stop
the immediate writable-directory failure, but it would leave newly copied
descendants root-owned. That is not a complete fix: read-only use may work,
while later GC or deletion can fail inside root-owned store directories.

### 3. Convert the sentinel into a legacy migration marker

The current `/nix/.dx-owner-set` marker is not proof of the current invariant:
root can import more content after it is created. Replace it with a versioned
marker that records at least:

- the ownership-layout version;
- the expected `dx` UID and GID;
- successful completion of any legacy recursive migration.

For a pre-change volume, perform one final full ownership normalization and
publish the new marker only after it succeeds. For a newly initialized or
already migrated volume, ownership must be correct by construction and no
recursive repair should occur.

If any future bootstrap operation must write store content as root, it must
either invalidate this marker before writing or explicitly transfer ownership
of only the paths it introduced.

### 4. Keep cheap invariant checks

Normal bootstrap should retain inexpensive checks for the mutable roots used by
single-user Nix, including `/nix/store` and `/nix/var/nix`. A failed check must
produce a precise diagnostic.

Do not recursively scan the store to prove that every descendant has the right
owner on every boot; that has the same scaling problem as the repair. The
invariant should instead follow from controlling every writer.

### 5. Clarify naming and logs

- Rename `configure_nix_daemon` to a name such as
  `configure_single_user_nix` or `configure_nix`.
- Change `Granting Nix ownership to dx...` to describe whether this is a
  one-time legacy migration or a targeted import.
- Time storage initialization, image-store merge, legacy ownership migration,
  and Home Manager activation separately.
- Print a completion line with elapsed time for each potentially long phase.
- Consider showing the last several guest log lines in `dx-wait-ssh`, rather
  than only the most recent line.
- Render the wait budget in minutes as well as seconds, and explain that it is
  a failure ceiling derived from retry budgets.

## Adjacent Ownership Work

After fixing `/nix`, audit the other recursive operations in bootstrap:

```text
chown -R dx:dx /home/dx
chown -R dx:dx /nix/cache
chown -R dx:dx /persist/home/dx
```

Prefer creating directories with the intended owner, changing ownership only
on paths bootstrap creates, and repairing declared roots rather than repeatedly
walking user-controlled trees. These calls are not the confirmed cause of the
reported pause, but they have the same unbounded-growth characteristic.

## Test Plan

### Unit and sourceable-function coverage

Add fixtures covering:

1. a fresh destination receives the expected `dx` ownership;
2. merging into an existing `dx`-owned store does not change the store root to
   `root`;
3. a newly imported store path and its descendants are owned appropriately;
4. existing store-path contents are not overwritten;
5. hidden entries and symlinks are handled as intended;
6. a partial copy fails loudly;
7. a matching versioned marker skips legacy migration;
8. a marker with an old layout version or different UID/GID triggers exactly
   one migration;
9. the marker is not published when migration fails.

Retain a regression test that demonstrates the current `cp -a source/.`
directory-metadata behavior so a later simplification cannot reintroduce it.

### Lifecycle coverage

Exercise these cases with isolated container and volume names:

1. factory reset followed by first `dx`;
2. stop and start of the same container;
3. container recreation with `/nix` preserved;
4. image rebuild that introduces previously absent store paths;
5. Home Manager activation after each case;
6. `nix store verify`, garbage collection, and reclaim behavior;
7. a simulated ownership-layout version or UID/GID change.

The destructive factory-reset test must retain its existing isolated-profile
guard and must never target the default `dx-host` resources.

### Performance measurements

Record at least:

- number of entries in the persistent store;
- time spent initializing or mounting storage;
- time spent merging image paths;
- time spent migrating ownership;
- time to Home Manager start;
- time to SSH readiness.

Measure a clean volume and a mature, large persistent store. The mature-store
case is the important regression target because the current cost grows with
all historical store contents.

## Acceptance Criteria

1. A normal restart logs no full recursive `/nix` ownership operation.
2. Recreating a container with a mature preserved store does not make bootstrap
   time proportional to the total number of existing store entries merely to
   repair ownership.
3. A factory-reset bootstrap does not perform a full copy followed by a second
   full recursive ownership pass.
4. `/nix/store`, `/nix/var/nix`, and all newly imported paths satisfy the
   ownership requirements of Nix running as `dx`.
5. Home Manager activation, store verification, GC, and reclaim pass after a
   fresh bootstrap and after an image-store merge.
6. An existing pre-change volume performs no more than one explicit legacy
   migration.
7. Progress logs show which phase is active and how long completed slow phases
   took.

## Larger Alternative: Nix Daemon

The official base already supplies a `nix-daemon` binary, a `nixbld` group, and
32 build users. DX could instead keep the persistent store root-owned and have
unprivileged `dx` commands forward store operations to a root-owned daemon.
That would eliminate the ownership handoff and align with Nix's stronger
multi-user security model.

This should be treated as a separate architectural decision because it changes:

- daemon and socket lifecycle without systemd as the guest supervisor;
- `NIX_REMOTE`, trusted-user, and substituter configuration;
- process supervision alongside foreground SSHD;
- bootstrap failure and shutdown behavior;
- `dx-gc`, `dx-reclaim`, and any scripts that currently rely on Nix running as
  `dx` against a directly writable store;
- security and integration tests.

For the current one-interactive-user guest, correcting ownership during import
is the smaller and lower-risk performance fix. A daemon migration remains
worth evaluating if DX is moving toward stronger isolation or multiple
untrusted guest users.

## Proposed Delivery Sequence

1. Add timing and the regression reproduction around the current merge.
2. Reorder user creation ahead of Nix-volume population.
3. Implement ownership-correct fresh seeding and incremental merge.
4. Add the versioned one-time legacy migration.
5. Remove the recurring whole-store ownership fallback from normal bootstrap.
6. Run isolated lifecycle and performance tests.
7. Audit adjacent recursive ownership operations.
8. Consider daemon-backed Nix in a separate design document.
