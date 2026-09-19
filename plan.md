# Backlog — unscheduled

The NixOS 26.05 upgrade record (Part A) and the eight code-review fixes
(P3–P10, originally `plan-3.md`…`plan-10.md`) that used to fill this
document have all landed or been dropped after review; their implementation
and history remain in Git. The reusable upgrade procedure, the base-image
alignment rule, the `Upgrade / Bump` runbook, and the one-time changeover
with its canary gate now live in
[`docs/release-maintenance.md`](docs/release-maintenance.md).

## Status

Open. One unscheduled backlog item remains, with no owner or phase yet. It
states the problem and the acceptance criteria; no design is selected.

Revisit trigger: when an incremental `/persist` host backup is next
scheduled, or the next time a `/persist` loss scare occurs.

## B1 — Back up the at-risk contents of `/persist` to the host

**Why now.** As of 2026-09-07 every Apple container volume is excluded from Time
Machine, including `dx-persist`. That was the right call for the host — a single
16 GB `volume.img` whose mtime moves whenever the guest runs was re-copied whole
on every hourly pass, and a file-level copy of a mounted ext4 image is not a
dependable restore source anyway (see `docs/troubleshooting.md`, "`dx` hangs at
Waiting for guest SSH on a loaded host"). But it leaves `/persist` with **no
host-side backup at all**, and `dx-factory-reset` destroys it.

**What to build.** A host-invoked, rsync-style incremental pull from `/persist`
into a directory on the host, transferring only what changed since the last run.

**The selection rule is the interesting part.** Do not copy everything. Copy only
what could not be reconstructed from somewhere else:

- Skip any file that is committed and unmodified in a git repository under
  `/persist` *and* whose repository has that commit on a reachable remote — that
  content is already safe, and it is the bulk of the bytes.
- Keep uncommitted work: modified tracked files, staged changes, and untracked
  files that are not ignored.
- Keep files that live outside any git repository entirely (shell history,
  credentials, caches worth keeping, scratch state).
- Decide explicitly, and document, what happens to `.gitignore`d files — some are
  pure build output, some are the only copy of a secret. Defaulting to "skip
  ignored" is the safe-looking choice that silently drops the second category.
- A repo with commits **not** pushed to any remote is not safe. Treat unpushed
  commits as at-risk content, not as backed up.

**Open questions.**

- Transport. `rsync` is not currently in the guest toolchain, and adding it means
  a `flake.nix` change plus a Nix rebuild; `tar` over `container exec` (the
  `dx-get`/`dx-put` idiom) needs no new dependency but has no incremental mode.
- Where the change detection lives. Asking git per repo is accurate but costs a
  process per repo; a single `find -newer` pass against a timestamp is cheap and
  wrong at the edges.
- Whether this runs on demand, on `dx-stop-container`, or on a schedule.
- Whether the destination should be excluded from Time Machine too. It should
  not be — this backup exists precisely so that ordinary host backups can protect
  guest state as normal files.

**Acceptance criteria.**

- A committed, pushed, unmodified file under `/persist/git/<repo>` is not
  transferred; the same file with a local edit is.
- A commit that exists only locally is treated as at-risk and its content is
  captured.
- A file outside any repository is always transferred.
- A second consecutive run with no guest-side change transfers nothing.
- Behaviour tests, per `constitution.md`: fake the guest boundary the way
  `tests/lib/fake-tools.sh` does, and cover the ignored-file policy explicitly
  rather than asserting on the command string.
