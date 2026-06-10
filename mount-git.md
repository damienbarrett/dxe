# Plan: Git Repository Access For `dx`

Goal: choose how git repositories should be made available to a `dx` guest, with
the normal path optimized for guest-native development and host bind mounts kept
as an explicit, rare side-container workflow.

The primary workflow needs no host mount at all. Mounting remains useful, but
only as a deliberate side-container feature that must never disturb the main
`dx-host` environment.

## Use Cases Drive The Design

| Use case | Frequency | Source of truth | Container shape | Host mount? |
| --- | --- | --- | --- | --- |
| **UC-1. Guest-native development** | Constant, primary | Guest checkout under `/persist` | Durable `dx-host` | No |
| **UC-2. Occasional host-directory mount** | Rare, explicit | Host checkout | Derived side container | Yes |
| **UC-3. Isolated `dxe` self-development** | Occasional branch work | Guest clone in an isolated env | Derived branch container | No |

### UC-1 - Guest-Native Development

This is the default `dx` session. Repositories are cloned and developed inside
the durable guest, usually under `/persist/git/...`. The host is just a terminal
into that environment. Code moves in and out through normal git remotes, for
example `git push` and `git pull`.

This maps to **F2-durable**: guest-native clone with persistent guest storage.
It avoids Apple Container mount constraints, avoids cross-OS git index churn,
keeps the host filesystem isolated from guest tools, and matches how this repo is
already being developed.

### UC-2 - Explicit Host Mount In A Side Container

Sometimes a host directory should be visible inside a guest at launch, for
example to run guest tooling against a host-side checkout. This is explicitly not
the normal workflow.

Hard rule: **never stop, destroy, recreate, or rebind `dx-host` to satisfy a
mount**. Apple Container fixes mounts at create time, so the answer is not to
make rebind cheaper. The answer is to put host mounts only in a purpose-created
side container with a derived name.

This maps to **F1 side-container mount**, with **F4 sync** as the fallback if the
mount spikes fail.

Do not default UC-2 to sharing the main `/nix` or `/persist` volumes:

- The README documents the writable Nix volume as single-writer. A concurrent
  side container must not mount the default `dx-nix`.
- Sharing all of `/persist` just to get credentials gives a one-off side
  container broad access to durable state and secrets.
- The default side-container shape should use private, namespaced volumes. If it
  needs credentials, solve that separately with launch-time injection or a
  credentials-only volume.

### UC-3 - Isolated `dxe` Self-Development

When testing changes to the `dx` lifecycle scripts themselves, use a disposable
environment derived from the feature branch name, for example:

- branch `feat/mount-git`
- container `dx-branch-feat-mount-git-<hash>`
- private `DX_NIX_VOLUME`
- private persist volume, or no persistent project data beyond private throwaway
  volumes required by bootstrap
- private bootstrap volume, SSH port, and key

The invariant is **no shared durable state with `dx-host`**, not literally "no
volume object exists." Current bootstrap mechanics expect named volumes, so the
practical implementation is private throwaway volumes that can be deleted with
the branch container.

This maps to **F2-ephemeral/private**: clone and checkout the branch inside the
isolated guest. Do not mount the host checkout for this use case, because the
code under test is the lifecycle tooling that creates, destroys, and preserves
containers and volumes. Sharing real `/persist` or `/nix` would put durable user
state inside the blast radius of in-development lifecycle scripts.

## Hard Constraint For Mount-Based Designs

Apple Container fixes a container's mount set at create time:

- Bind mounts are passed to `container create` or `container run`.
- There is no supported `container mount`, and `container start` / `container
  exec` cannot add or change mounts.
- The current `bin/dx-create-container` shape reflects this: all mounts are
  baked into `CREATE_FLAGS`, and the script exits early if the container already
  exists.

Consequence: changing the host path mounted into an existing container requires
destroying and recreating that container. That discards the root filesystem and
any running tmux session. Named volumes may survive, but that does not make the
operation acceptable for `dx-host`.

Therefore:

- Plain `dx` must remain mount-free.
- `dx-host` is reserved for UC-1 and must never be rebound by git-mount logic.
- A host mount must be created only through an explicit side-container workflow.
- Sticky/rebind `dx-host` behavior is rejected for the default design.

## Key Design Decisions

- **Explicit trigger:** UC-2 uses an explicit `bin/dx-mount` flow. Plain `dx`
  must not infer host cwd and must not implicitly mount or rebind anything.
- **No default durable sharing for side containers:** UC-2 side containers use
  private/namespaced Nix, persist, bootstrap, SSH key, and port resources by
  default. Sharing the default `dx-nix` is rejected because the Nix volume is
  writable and single-writer. Sharing all of `/persist` is rejected because it
  exposes broad durable state and credentials.
- **Private throwaway volumes are acceptable isolation:** UC-3 does not literally
  require zero volume objects. It requires no shared durable state with
  `dx-host`; private throwaway volumes are the practical bootstrap-compatible
  shape.
- **Guest clone for branch self-dev:** UC-3 should clone and checkout the branch
  inside the isolated guest. Mounting the host checkout would reintroduce the F1
  constraint and host filesystem blast radius.
- **Derived names must be typed by workflow:** UC-2 uses
  `dx-mount-<slug>-<hash>` and UC-3 uses `dx-branch-<slug>-<hash>`. Avoid a
  generic `dx-<slug>` scheme because it is harder to audit and easier to collide
  with existing profile/container names.
- **Mount identity is the mount source:** the UC-2 slug/hash is derived from the
  mounted source path (the repo top-level when `DIR` is inside a repo), not from
  the literal `DIR` argument. Running `dx-mount` from different subdirectories of
  one repo therefore reuses the same side container; the subdirectory only sets
  the initial guest workdir. Because the name encodes the mount identity, no
  separate identity marker is needed on the default path — only an explicit
  `--container NAME` override requires one.
- **Reuse the profile/env substrate:** the repo already isolates full
  environments through env overrides (`bin/dx-profile`,
  `tests/profiles/dx-test.env` namespaces container, image, volumes, port, and
  key). Both `dx-mount` and `dx-branch` should be thin wrappers that derive a
  profile-shaped set of `DX_*` values and drive the existing `dx` pipeline, not
  parallel create logic.
- **Image sharing differs by use case:** UC-2 side containers may share the
  default `dx-nixos-25.11` image — images are immutable, so sharing is safe and
  avoids a rebuild. UC-3 must namespace `DX_IMAGE` (as `dx-test.env` does)
  because the image-creation scripts are themselves under test.
- **Nix cold-start is a prerequisite for `dx-mount`:** each side container's
  private Nix volume pays a full store rebuild on first boot, which would make
  `dx-mount` unacceptably slow. A seeded or shared read-only Nix base must be
  designed and spiked before `dx-mount` ships; see the Recommendation spikes.

## Option Families

### F1. Host Bind Mount

Declare a host repo path as a bind mount at side-container create time. The guest
sees the real host files live, and guest writes go back to the host tree.

Recommended shape for this repo: **explicit `bin/dx-mount` + derived side
containers**.

- `dx-mount [DIR]`
  - resolves `DIR`, defaulting to the current directory
  - if inside a git repo, resolves to the repo top-level by default
  - derives a side-container name from a slug plus hash of the mounted source
    (the top-level, not the literal `DIR`)
  - mounts the host path at `DX_GIT_MOUNT_TARGET`, default `/workspace`
  - uses private/namespaced volumes by default
  - refuses `DX_CONTAINER_NAME=dx-host` and refuses any derived name that equals
    `dx-host`
- `dx-mount [DIR] --container NAME`
  - allowed only if `NAME` is not `dx-host`
  - should still require explicit user intent before deleting/recreating an
    existing stopped side container

Pros:

- Live, zero-copy host/guest file visibility.
- Supports uncommitted and untracked host work.
- No sync daemon.

Cons:

- Mounts are create-time only.
- Cross-OS git metadata churn is possible between macOS and Linux.
- Guest tools can delete or corrupt host source.
- Large bind-mounted trees may be slower than native guest storage.
- Worktrees and submodules whose `.git` metadata points outside the mounted tree
  need an explicit support policy.
- Each side container needs a private `dx-nix` volume, so first boot pays a full
  Nix-store rebuild (the bootstrap `mkfs`-es and repopulates the volume). This
  makes "spin up a mount side container" much heavier than the matrix
  implementation-cost rating alone suggests. A seeded or shared read-only Nix
  base is therefore a prerequisite spike for `dx-mount`, not a deferred
  optimization.

F1 is only for UC-2. It is not the primary workflow.

### F2. Guest-Native Clone

The guest owns its own checkout. The host may have a separate checkout or none.
Code crosses environments through git remotes.

Two shapes matter:

- **F2-durable:** clone into `/persist` in `dx-host` for normal development.
- **F2-ephemeral/private:** clone into an isolated branch-specific environment
  with no shared durable state from `dx-host`.

Pros:

- No Apple Container mount constraint.
- Native Linux git; no macOS/Linux index churn.
- Strong host-filesystem isolation.
- Simple parallel repo support.
- Best match for the existing durable guest model.

Cons:

- Host and guest checkouts diverge until pushed/pulled.
- Uncommitted/untracked work does not cross automatically.
- Needs a reachable remote, unless paired with F5.
- Host editors need a remote-edit path if they must edit guest files directly.

F2-durable is the primary recommendation for UC-1.

### F3. One-Shot Copy

Use the existing `dx-put` and `dx-get` scripts to copy a tree into or out of the
guest.

This remains useful for occasional file transfer or non-git directories, but it
is a point-in-time copy, not a live development workflow.

### F4. Continuous File Sync

Use a sync tool such as Mutagen, Unison, or an rsync watcher to mirror a host
directory to a guest directory over SSH.

Pros:

- Avoids create-time mount constraints.
- Can be bidirectional or near-live.
- Can ignore `.git`, build outputs, and cache directories.

Cons:

- Adds a daemon and conflict model.
- Eventual consistency rather than true live sharing.
- Syncing `.git` itself is risky; syncing only the worktree complicates git
  state.

F4 is the fallback for UC-2 if F1's mount support, write-through behavior, or
cross-OS git behavior is unacceptable.

### F5. Git Remote Bridge

Keep separate host and guest checkouts, and add one side as an SSH-accessible git
remote for the other. This moves committed state without requiring GitHub or a
shared upstream.

F5 is a local-only supplement to F2. It does not solve uncommitted/untracked
state by itself.

## Comparison Matrix

Ratings are relative for the intended development loop.

| Criterion | F1 Side Mount | F2 Durable Clone | F2 Private Clone | F3 Copy | F4 Sync | F5 Remote |
| --- | --- | --- | --- | --- | --- | --- |
| Primary UC | UC-2 | UC-1 | UC-3 | Stopgap | UC-2 fallback | F2 supplement |
| Live host edits visible in guest | Yes | No | No | No | Near-live | No |
| Uncommitted work crosses | Yes | No | No | On copy | Yes | No |
| Apple mount constraint | Create-time only | None | None | None | None | None |
| Cross-OS git churn risk | High | None | None | Low | Medium | None |
| Host filesystem blast radius | High | None | None | Low | Medium | None |
| Uses `dx-host` | Never | Yes | Never | Optional | Optional | Optional |
| Shares default `/nix` | No | Yes | No | N/A | N/A | N/A |
| Shares default `/persist` | No by default | Yes | No | N/A | N/A | N/A |
| Implementation cost | Medium-high | Low | Medium | Existing | Medium | Low-medium |

## Recommendation

1. Keep **plain `dx` mount-free**. It should continue to bring up the durable
   `dx-host` guest and attach to it. There should be no implicit current-working
   directory detection in `dx`.
2. Treat **F2-durable** as the primary workflow. Normal repos live under
   `/persist` in `dx-host` and synchronize through git remotes.
3. Add host mounts only as a future **explicit `dx-mount` side-container**
   command. It should derive a non-`dx-host` container name from the mounted path
   and use private/namespaced volumes by default.
4. Use **F2-ephemeral/private** for branch-based `dxe` self-development. The
   branch environment must never share the default `/nix`, persist, or bootstrap
   volumes with `dx-host`.
5. Run F1 go/no-go spikes before implementing `dx-mount`: absolute host-path bind
   support, bidirectional write-through as the `dx` user, usable ownership, and
   clean `git status` from both host and guest after guest access. In the same
   gate, spike a seeded or shared read-only Nix base so side containers do not
   pay a full Nix-store rebuild on first boot; `dx-mount` does not ship until
   cold-start is acceptable.
6. Keep F4 available as the UC-2 fallback if bind mounts fail or prove too sharp.

## Public Interface Plan

### Plain `dx`

No git-mount behavior:

- no host cwd detection
- no source mount
- no `DX_GUEST_WORKDIR` translation from host cwd
- no marker files for mounted repo state
- no stopped-container rebind

### `bin/dx-mount`

Future command for UC-2:

```bash
bin/dx-mount [DIR] [--container NAME]
```

Behavior:

- Resolve `DIR`, defaulting to `$PWD`.
- If `DIR` is inside a git repo, use the git top-level as the mounted source and
  compute the initial guest workdir from the original subdirectory.
- If `DIR` is not inside a git repo, mount `DIR` itself.
- Derive the default container name as `dx-mount-<slug>-<hash>`, slugging and
  hashing the mounted source. Different subdirectories of one repo reuse the
  same side container.
- Reject `dx-host` as an explicit or derived name.
- Mount the host source at `DX_GIT_MOUNT_TARGET=/workspace`.
- Share the default image; use private default names for the side container's
  Nix, persist, and bootstrap volumes and SSH key.
- Use a non-default SSH port, derived or explicitly supplied, so the side
  container can run alongside `dx-host`.
- Implement by deriving a profile-shaped `DX_*` environment and driving the
  existing `dx` pipeline (`dx-create-keys` through `dx-ssh`), not by duplicating
  create logic.
- If the derived side container already exists, start and attach to it — the
  name encodes the mount identity, so no further check is needed.
- With `--container NAME`, verify the existing container's recorded mount
  identity. On mismatch, refuse by default and tell the user the exact
  destroy/recreate command. Do not silently delete even stopped containers.
- Teardown reuses `bin/dx-destroy` under the same derived environment. Derived
  name prefixes (`dx-mount-`, `dx-branch-`) keep side containers discoverable in
  `container list` for cleanup.

### Branch Self-Dev Profile

Future helper/profile for UC-3:

```bash
bin/dx-branch [BRANCH]
```

Behavior:

- A thin profile generator: derive a `dx-test.env`-shaped set of `DX_*` values
  from the branch (container `dx-branch-<slug>-<hash>`, private image, Nix,
  persist, and bootstrap names, private key, derived port) and drive the
  existing `dx` pipeline with them.
- After bring-up, clone the repo inside the guest and checkout `BRANCH`.
- Never mount the host checkout.
- Never use default `dx-host`, `dx-nixos-25.11`, `dx-nix`, `dx-persist`, or
  `dx-bootstrap` resources. Unlike UC-2, the image is private too, because the
  image-creation scripts are part of what is under test.

`dx-branch` is a convenience shape, not a prerequisite for `dx-mount`. Until it
exists, UC-3 is already achievable by hand: copy `tests/profiles/dx-test.env`,
rename every resource, and run the pipeline through `bin/dx-profile`.

## Implementation Notes For Future Code

- Add a shared slug/hash helper for derived names. Normalize path/branch names to
  lowercase alphanumerics plus `-`, trim repeated separators, cap the slug length,
  and append a short stable hash to avoid collisions.
- Reserve `dx-host` centrally so no derived-name helper can return it.
- Add `DX_GIT_MOUNT_TARGET`, default `/workspace`.
- Plumb the mount through `dx-create-container` as an optional
  `DX_GIT_MOUNT_SOURCE` (empty by default; when set, append one `--volume
  "$DX_GIT_MOUNT_SOURCE:$DX_GIT_MOUNT_TARGET"` to `CREATE_FLAGS`). Plain `dx`
  never sets it, so the default pipeline stays mount-free.
- Do not add `DX_GIT_MOUNT_ENABLED` to plain `dx`; mounts are triggered only by
  `dx-mount`.
- Make container memory and CPU configurable (the current `-m 12G -c 4` is
  hardcoded in `CREATE_FLAGS`). A side container running alongside `dx-host`
  doubles host VM memory pressure, so side containers likely want smaller
  defaults.
- Follow the `dx-test.env` precedent for derived key paths
  (`$DX_PROJECT_ROOT/<name>_key`), and make teardown remove the derived key
  pair along with the container and volumes.
- Do not introduce host-side marker state for `dx-host`. Side containers may keep
  a marker keyed by their derived name only to verify their own mount identity.
- Do not `chown -R` the bind mount from inside the guest.
- Quote every path. Host paths can contain spaces.
- Derive the side-container SSH port deterministically from the slug/hash into a
  reserved range, and retry/refuse on collision so concurrent side containers do
  not contend for the same `127.0.0.1` port as `dx-host` (default `2222`).
- Keep credential propagation out of the initial `dx-mount` implementation unless
  a separate auth plan chooses one of:
  - launch-time secret injection
  - credentials-only named volume
  - explicit re-auth in the side container

## Validation Plan

Future implementation tests:

- Plain `dx` from inside a host git repo does not attempt any host mount and does
  not alter `DX_CONTAINER_NAME`.
- `dx-mount` rejects `dx-host`.
- `dx-mount` derives stable names and avoids collisions for paths with the same
  basename.
- `dx-mount` handles repo root, repo subdirectory, non-git directory, and paths
  containing spaces.
- `dx-mount` from two different subdirectories of the same repo derives the same
  container name and reuses the existing side container.
- Destroying a side container removes its derived volumes and key pair and
  leaves no orphaned resources.
- `dx-mount` creates exactly one host source mount at `DX_GIT_MOUNT_TARGET`.
- `dx-mount` uses private/namespaced Nix, persist, bootstrap, key, and port
  defaults.
- A running `dx-host` continues unaffected while a mount side container is
  created, started, stopped, and destroyed.
- Guest-created files appear on the host, host-created files appear in the guest,
  and ownership remains usable on both sides.
- `git status --short` stays clean on both host and guest after guest access, or
  the known cross-OS churn is documented as a blocker.
- Branch self-dev profiles never use default durable resources and can be
  destroyed without affecting `dx-host`.

Suggested test section when implementation starts:

```bash
tests/test_section18_mount_git.sh
```

Promotion gate for future implementation:

```bash
tests/run_all_tests.sh --skip-integration
tests/run_all_tests.sh --section=9 --skip-integration
DX_TEST_MOUNT_GIT=1 tests/run_all_tests.sh --section=18
```

Then run the full Apple Container suite against an isolated profile before
documenting the feature as available.

## Deferred Decisions

- Credential delivery for UC-2 side containers. Default to no broad `/persist`
  sharing until a least-privilege auth design exists.
- The mechanism for the seeded/read-only Nix base (host-side volume clone,
  export/import of a populated store, or a read-only shared mount). The decision
  that some such mechanism must exist before `dx-mount` ships is made; only the
  mechanism is open. It must not violate the single-writer constraint on the
  default `dx-nix` volume.
- SSH-port allocation scheme for concurrent side containers (deterministic range
  plus collision handling). The range must avoid `dx-host`'s default `2222` and
  the `dx-test` profile's `2299`.
- Default memory/CPU sizing for side containers once the `-m`/`-c` flags become
  configurable.
- Whether F4 sync is worth implementing after the F1 spikes.
- Exact branch-helper name and UX. The plan uses `dx-branch` as a concrete
  placeholder.
- Worktree/submodule support for F1. Start with ordinary repos unless validation
  proves the edge cases are safe.
