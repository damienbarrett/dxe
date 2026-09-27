## Lifecycle Layers

The DX environment is built from independent **layers** of state, ordered from
most persistent (slowest to rebuild) to most ephemeral. Each layer has a
dedicated `dx-create-X` and `dx-destroy-X` script. Every create script skips
its work if the layer is already present; every destroy script no-ops if the
layer is absent. A small set of wrappers (`dx`, `dx-destroy`, `dx-recreate`,
`dx-factory-reset`) compose these layer scripts in fixed orders for the common
operations.

### Lifecycle Principles

1. **One concern per script.** Each lifecycle script owns exactly one layer
   (keypair, image, container, runtime state, bootstrap payload, etc.).
2. **Idempotence toward end state.** Every create script no-ops if its layer
   exists. Every destroy script no-ops if its layer is absent.
3. **Symmetric pairs.** Each layer has a `create-X` and `destroy-X` script
   that read as antonyms. The script name tells you which layer it operates on.
4. **Wrappers only orchestrate.** `dx`, `dx-destroy`, `dx-recreate`, and
   `dx-factory-reset` are short sequences of lifecycle calls with no unique
   logic. New phases land in one place.
5. **Forcing a rebuild is explicit.** Idempotent build means "skip if present."
   To force a rebuild at any layer, destroy that layer first.
6. **Persistent volumes are protected by construction.** `/nix` and `/persist`
   survive everything except `dx-factory-reset` (or an explicit
   `dx-destroy-volumes`).
7. **The bootstrap payload is part of every start.** `dx-start-container`
   always runs `dx-sync-bootstrap` after ensuring the container is running, so edits to
   `home/*.nix` or `bootstrap.sh` land on the next `dx` without an image
   rebuild. When that sync actually publishes a new generation (not the
   unchanged-content skip), `dx-start-container` also confirms, bounded by
   `DX_BOOTSTRAP_CONFIRM_TIMEOUT` (default 5s), that the guest's execution
   lease already names it before declaring the start a success. If the
   container was already running and never restarted, the guest can't pick
   the new publish up on its own — the start fails loudly, naming both the
   published and running generation, instead of silently leaving the guest on
   stale code. The remedy is always the same: restart it —
   `./bin/dx-stop-container && ./bin/dx-start-container`. The second start's
   sync sees the content unchanged (already published) and takes the skip
   path, so the freshly-started guest picks it up on its own first boot. See
   [D7](refactor/decisions/D7-start-generation.md) for the full mechanism.
8. **Layer cost informs default behaviour.** Volumes (hours to rebuild) are
   never touched implicitly. Image (minutes) is rebuilt only by `dx-recreate`
   or explicit destroy. Container and runtime state (seconds) are freely
   rebuilt.
9. **Runtime-neutral entrypoints.** No lifecycle script calls the `container`
   binary directly; each reaches it through `bin/lib/dx-runtime.sh`'s
   `dx_runtime_<op>` contract, which dispatches on the `DX_RUNTIME`
   configuration field (default, and today the only implemented value,
   `apple`) to an adapter. An automated audit
   (`tests/test_runtime_boundary_audit.sh`) fails the build if a raw
   `container` call reappears outside the adapter. See
   [`docs/refactor/runtime-boundary.md`](refactor/runtime-boundary.md).

### Layered lifecycle scripts

| # | Layer | Create | Destroy |
| --- | --- | --- | --- |
| 1 | Host SSH keypair | [`bin/dx-create-keys`](../bin/dx-create-keys) | [`bin/dx-destroy-keys`](../bin/dx-destroy-keys) |
| 2 | Persistent volumes | [`bin/dx-create-volumes`](../bin/dx-create-volumes) | [`bin/dx-destroy-volumes`](../bin/dx-destroy-volumes) |
| 3 | Image | [`bin/dx-create-image`](../bin/dx-create-image) | [`bin/dx-destroy-image`](../bin/dx-destroy-image) |
| 4 | Container | [`bin/dx-create-container`](../bin/dx-create-container) | [`bin/dx-destroy-container`](../bin/dx-destroy-container) |
| 5 | Runtime state | [`bin/dx-start-container`](../bin/dx-start-container) | [`bin/dx-stop-container`](../bin/dx-stop-container) |
| 6 | Bootstrap payload | [`bin/dx-sync-bootstrap`](../bin/dx-sync-bootstrap) | *(replaced on next sync)* |
| 7 | SSH connection | [`bin/dx-ssh`](../bin/dx-ssh) | *(user exits)* |

`dx-destroy-volumes` is the only interactive lifecycle script: it lists the
volumes it is about to remove, requires the user to type `destroy` to confirm,
and refuses to run non-interactively without `--force`. Every other script is
fire-and-forget.

### Wrappers

| Wrapper | Composition |
| --- | --- |
| [`bin/dx`](../bin/dx) | `create-keys → create-image → create-volumes → create-container → start-container → wait-ssh → ssh` |
| [`bin/dx-destroy`](../bin/dx-destroy) | `destroy-container → destroy-image` (preserves volumes and keys) |
| [`bin/dx-recreate`](../bin/dx-recreate) | `dx-destroy → exec dx` (preserves volumes and keys) |
| [`bin/dx-factory-reset`](../bin/dx-factory-reset) | prompts once, then `destroy-container → destroy-image → destroy-volumes --force → destroy-keys` |

### Helpers and runtime utilities

These do not belong to the layer model — they observe state, transfer files,
or perform maintenance operations.

| Script | Role |
| --- | --- |
| [`bin/dx-lib.sh`](../bin/dx-lib.sh) | Short compatibility facade that loads the source-only host libraries and resolves one complete configuration snapshot. |
| [`bin/dx-profile`](../bin/dx-profile) | Parses a named data profile from `tests/profiles/<name>.env`, resolves the complete snapshot, then execs the command. |
| [`bin/dx-mount`](../bin/dx-mount) | Launches an isolated side container, records a bounded v2 identity manifest, and exposes audit/migration/destroy-plan modes. |
| [`bin/dx-wait-ssh`](../bin/dx-wait-ssh) | Blocks until guest SSH responds. Gates the SSH connection layer. |
| [`bin/dx-status`](../bin/dx-status) | Reports image, container, SSH, tool, persist, tmux, and profile-aware tunnel migration state. |
| [`bin/dx-put`](../bin/dx-put) | Copies host files into the guest. |
| [`bin/dx-forward`](../bin/dx-forward) | Exposes guest web ports on macOS loopback addresses with SSH local forwarding. |
| [`bin/dx-reverse`](../bin/dx-reverse) | Exposes macOS loopback services inside the guest with SSH reverse forwarding. |
| [`bin/dx-enter`](../bin/dx-enter) | Direct `container exec` shell, bypassing SSH. |
| [`bin/dx-gc`](../bin/dx-gc) | Runs Nix garbage collection and store optimization inside the guest. |
| [`bin/dx-reclaim`](../bin/dx-reclaim) | Reclaims host disk space by deleting old Nix generations in the guest and trimming persistent filesystems. |
| [`bin/dx-export`](../bin/dx-export) | Archives the container to a tar file. |
| [`bin/dx-nix-disk`](../bin/dx-nix-disk) | Prepares a sparse Nix disk image; lifecycle-adjacent storage prep. |
| [`bin/dx-backup`](../bin/dx-backup) | Captures the at-risk contents of `/persist` into a Mac folder, incrementally. |
| [`bin/dx-restore`](../bin/dx-restore) | Pushes a captured mirror (or a named subpath of it) back into a running guest's `/persist`. |
| [`container/.../bootstrap.sh`](../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh) | Runs the ordered sourceable phases from the atomically published, leased bootstrap generation. |

### Reclaiming host disk space

Apple Container stores named volumes as sparse host images. The apparent size
of those images can stay high after the guest deletes data until the guest
filesystem reports its free blocks back to the host. `dx-reclaim` handles that
maintenance path for the DX volumes:

```bash
./bin/dx-reclaim
```

Run it when the `dx-nix` or `dx-persist` volume has grown noticeably and you
want to return unused space to macOS. The container must already be running.

`dx-reclaim` prints host sparse-image usage and guest filesystem usage before
and after the operation. It then:

1. Deletes old Nix generations inside the guest with `nix-collect-garbage -d`.
2. Runs `fstrim -v` on `/nix` and `/persist` so already-free blocks can be
   discarded from the sparse host images.

This does not delete persisted files. It removes only unreferenced Nix store
paths and discards blocks the guest filesystem has already marked free. It is
reasonable to run occasionally after large rebuilds or dependency churn, but it
does not need to run constantly or on a tight schedule.

### Backing up and restoring /persist

Every Apple container volume is excluded from Time Machine, including
`dx-persist` — a single sparse `volume.img` whose mtime moves whenever the
guest runs would otherwise be re-copied whole on every hourly pass, and a
file-level copy of a mounted filesystem image is not a dependable restore
source anyway (see `docs/troubleshooting.md`, "`dx` hangs at Waiting for
guest SSH on a loaded host"). That leaves `/persist` with no host-side backup
at all, and `dx-factory-reset` destroys it. `dx-backup` and `dx-restore`
close that gap: an on-demand, incremental, git-aware capture of the contents
of `/persist` that a rebuild could not reconstruct, mirrored into a normal
Mac folder that Time Machine (or any other host backup tool) already
protects. Unlike the excluded container volumes, this destination is
deliberately left **inside** Time Machine's scope — that is the entire point
of moving the at-risk content out of a volume Time Machine skips and into
plain files it doesn't.

```bash
./bin/dx-backup              # capture; prints "N files, N bytes transferred"
./bin/dx-backup --dry-run    # show the at-risk selection and would-be transfer only
./bin/dx-backup --dry-run --summary  # show the selection's size only, by top-level directory and by reason

./bin/dx-restore              # push the whole mirror back into a running guest
./bin/dx-restore PATH...      # push only the named subpath(s) (relative to /persist)
./bin/dx-restore --dry-run    # show what would change, without pushing
./bin/dx-restore --force      # push even where the guest already has different content
```

**Destination:** a registered config field (see
[configuration](configuration.md)), `DX_BACKUP_DIR`, default
`~/Backups/dxe-persist`, names the BASE directory. `dx-backup`/`dx-restore`
always append `/<DX_CONTAINER_NAME>` themselves, even when `DX_BACKUP_DIR`
is overridden, so `dx-host` and `dx-test` can never share a mirror by
accident. Inside `$DX_BACKUP_DIR/$DX_CONTAINER_NAME`:

| Path | Contents |
| --- | --- |
| `current/` | One mirror of the at-risk set. No dated generations — every run updates the same tree in place. |
| `manifest.tsv` | `path<TAB>size<TAB>mtime<TAB>sha256` for every mirrored file, written atomically (via a temp file plus `mv`) only after a run's transfer fully succeeds. |
| `last-run.log` | One line per completed run: timestamp and the transfer summary. |

**What is captured (the at-risk set).** `dx-backup` runs a selector inside the
guest, as `dx`, over `/persist`. For every git work tree it finds there (a
directory containing a `.git` **directory** — a `.git` *file*, as used by a
linked worktree or a submodule, is not treated as a repository boundary; see
the warning it prints if it encounters one):

- A repository with commits on a local branch that are not on any remote, or
  with no remote at all (`git log --branches --not --remotes --oneline`
  non-empty, or `git remote` empty), is **at-risk as a whole**: the entire
  work tree is mirrored, `.git/` included, so the commits themselves survive.
- Otherwise, the repository is treated as safe, and only its modified,
  staged, and untracked-but-not-ignored files are mirrored. A committed file
  that is unmodified and already reachable through the remote is **not**
  copied — that is the bulk of the bytes this backup deliberately skips.

A git work tree nested inside another one (a plain subdirectory containing
its own `.git`, not a submodule) is its own repository, evaluated and
mirrored entirely by its own pass — the outer repository's walk prunes at
every nested repository's boundary, so nothing is ever selected twice.

Files outside any repository are always at-risk. **Ignored files are
included by default** — a `.gitignore`d secret must never be dropped
silently — except for a deny-list of rebuildable caches:

```
node_modules/  target/  .direnv/  result  result-*  __pycache__/
.cache/  dist/  build/  .venv/  .tox/  .pytest_cache/  .mypy_cache/
.pnpm-store/  .Trash-*/  .tmp/
```

plus two anchored, path-shaped entries: the guest's own Nix-profile
generation trees (`home/dx/.local/state/dx-ai/generations/*/profile`) and
the `agy` (Antigravity CLI) binary/state bundle `dx-ai` reinstalls
(`home/dx/.gemini/antigravity-cli`) — its sibling config and credentials
elsewhere under `.gemini` are not rebuildable and stay in. `.pnpm-store` is
pnpm's content-addressable package store; `.Trash-*` is a trash directory;
`.tmp` is transient scratch wherever it turns up (for example under
`~/.codex`) — the rest of a persisted tool directory like `.codex` (its
config, its session history) is unaffected, since the deny only matches
the literal `.tmp` path component, nothing else nearby.

This deny-list applies everywhere (inside an at-risk-whole repository too,
and outside any repository), not only to the "ignored by default" case: it
exists purely to keep rebuildable bulk out of the backup. Extend it with
your own patterns, one glob per line (matched against the full path
relative to `/persist`; blank lines and `#` comments are skipped), from
either source, in priority order:

1. `DX_BACKUP_EXCLUDE_FILE=/path/to/file`, if set.
2. Otherwise, `${XDG_CONFIG_HOME:-$HOME/.config}/dxe/dx-backup-exclude` on
   the host, if that file exists — a default location so an extra pattern
   doesn't need an env var set on every invocation. A missing default file
   is not an error; a `DX_BACKUP_EXCLUDE_FILE` that is set but does not
   exist is.

Symlinks are mirrored as symlinks (a changed target is a detected change).
Sockets, fifos, and device files are skipped and counted, never mirrored.

**Incremental transfer.** The guest selector emits a listing
(`path size mtime sha256`) for the current at-risk set; the host diffs it
against `manifest.tsv` and fetches only new or changed paths over the same
`container exec` transport `dx-get`/`dx-put` use (no new guest dependency,
no `rsync`). A path that is no longer at-risk (for example, a repository
that got pushed) is removed from the mirror. A second run with nothing
changed in the guest transfers "0 files, 0 bytes" — only the listing pass
still runs.

The fetch itself is two separate execs, not one: the name list is shipped
into a guest temp file first (stdin-only, no pipe), then the archive is
read back from that file with the exec's own stdin closed. An earlier
version pushed the name list through one exec's stdin while reading the
archive back from that same exec's stdout, which deadlocked in production
on a large selection (tens of thousands of files) even though it worked
fine on a small one — every exec here is unidirectional by construction
instead, so that size-dependent failure mode cannot recur. The guest-side
archive create also passes `--hard-dereference`, so a repeated path (which
the nested-repository handling above already prevents, but which the
archive step defends against independently) is always shipped as an
independent regular-file copy rather than a hardlink record — the guest's
tar otherwise treats the exact same path added twice as if it were a
second hardlink, which the host's tar refuses to extract.

**Reviewing a large selection.** `dx-backup --dry-run --summary` prints the
at-risk set's total files and bytes, aggregated by `/persist`'s top-level
directory and by why each file is included (`modified-untracked`,
`whole-repo`, `outside-repo`, `ignored-kept`), instead of listing every
file — useful when the selection is too large to review file by file, to
decide whether `DX_BACKUP_EXCLUDE_FILE` needs another pattern.

**Restoring.** `dx-restore` needs a running guest: it pushes `current/` (or
the exact paths you name) back into `/persist`, preserving file modes and
restoring `dx:dx` ownership. It refuses the whole run — without `--force` —
if any target already exists in the guest with different content, so it never
silently overwrites newer guest-side work; `--dry-run` reports, for every
target, whether it would be created, is already identical, or would
overwrite a conflict. To restore into a **freshly created** guest (after
`dx-factory-reset`, or onto a new machine): bring the guest up as usual
(`./bin/dx`) so `/persist` exists and is running, then run `dx-restore` with
the same `DX_BACKUP_DIR` the backup was taken into.

**What this does not do (yet).** Capture is on demand only — there is no
schedule. Run it yourself before anything that could lose `/persist` (a
factory reset, a storage migration, a base-image pin change) and whenever you
want a fresh recovery point.

### Migration from earlier versions

| Old name | New name | Notes |
| --- | --- | --- |
| `dx-init-keys` | `dx-create-keys` | |
| `dx-build` | `dx-create-image` | Now idempotent: skips when the image already exists. |
| `dx-create` | `dx-create-container` | |
| `dx-destroy` | `dx-destroy-container` | The old name now refers to an umbrella that destroys image AND container — see the Wrappers table. |
| `dx-start` | `dx-start-container` | Now also syncs the bootstrap payload, so direct starts bring SSH up without a separate `dx-sync-bootstrap` step. |
| `dx-stop` | `dx-stop-container` | |

If you have data in the old default `dx-workspace` volume, migrate it before
starting the renamed lifecycle:

```bash
./bin/dx-migrate-persist
```

The helper copies `dx-workspace` into `dx-persist`, writes a migration sentinel,
and never deletes the old volume. For a custom old volume, run:

```bash
DX_LEGACY_WORKSPACE_VOLUME=<old-volume> \
DX_PERSIST_VOLUME=<new-volume> \
./bin/dx-migrate-persist
```

After starting the guest, verify the data under `/persist`. Only then remove
the old volume manually, for example:

```bash
container volume rm dx-workspace
```
