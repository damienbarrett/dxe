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
   rebuild.
8. **Layer cost informs default behaviour.** Volumes (hours to rebuild) are
   never touched implicitly. Image (minutes) is rebuilt only by `dx-recreate`
   or explicit destroy. Container and runtime state (seconds) are freely
   rebuilt.

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
