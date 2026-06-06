# Plan: Git Repository Access For `dx`

Goal: choose how git repositories should be made available to a `dx` guest, with
the normal path optimized for guest-native development and host bind mounts kept
as an explicit, rare side-container workflow.

This document used to center on "mount the current host checkout at
`/workspace`." The review in `mount-git-review.md` changes the framing: the
primary workflow needs no host mount at all. Mounting remains useful, but only as
a deliberate side-container feature that must never disturb the main `dx-host`
environment.

This is separate from guest persistence. The `/workspace` -> `/persist` rename in
`workspace-persist.md` must land first so `/workspace` is free for a future host
source mount. Do not reuse `DX_WORKSPACE_PATH`; that variable is reserved for the
old persistence surface and should be rejected by the persistence rename guard.

## Use Cases Drive The Design

| Use case | Frequency | Source of truth | Container shape | Host mount? |
| --- | --- | --- | --- | --- |
| **UC-3. Guest-native development** | Constant, primary | Guest checkout under `/persist` | Durable `dx-host` | No |
| **UC-2. Occasional host-directory mount** | Rare, explicit | Host checkout | Derived side container | Yes |
| **UC-1. Isolated `dxe` self-development** | Occasional branch work | Guest clone in an isolated env | Derived branch container | No |

### UC-3 - Guest-Native Development

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

### UC-1 - Isolated `dxe` Self-Development

When testing changes to the `dx` lifecycle scripts themselves, use a disposable
environment derived from the feature branch name, for example:

- branch `feat/mount-git`
- container `dx-branch-feat-mount-git-<hash>`
- private `DX_NIX_VOLUME`
- private persist/workspace volume, or no persistent project data beyond
  private throwaway volumes required by bootstrap
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
- `dx-host` is reserved for UC-3 and must never be rebound by git-mount logic.
- A host mount must be created only through an explicit side-container workflow.
- A4/A4b style "sticky/rebind `dx-host`" behavior is rejected for the default
  design.

## Option Families

### F1. Host Bind Mount

Declare a host repo path as a bind mount at side-container create time. The guest
sees the real host files live, and guest writes go back to the host tree.

Recommended shape for this repo: **explicit `bin/dx-mount` + derived side
containers**.

- `dx-mount [DIR]`
  - resolves `DIR`, defaulting to the current directory
  - if inside a git repo, resolves to the repo top-level by default
  - derives a side-container name from a slug plus hash of the resolved path
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

F2-durable is the primary recommendation for UC-3.

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
| Primary UC | UC-2 | UC-3 | UC-1 | Stopgap | UC-2 fallback | F2 supplement |
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
   branch environment must never share the default `/nix`, persist/workspace, or
   bootstrap volumes with `dx-host`.
5. Run F1 go/no-go spikes before implementing `dx-mount`: absolute host-path bind
   support, bidirectional write-through as the `dx` user, usable ownership, and
   clean `git status` from both host and guest after guest access.
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
- Derive the default container name as `dx-mount-<slug>-<hash>`.
- Reject `dx-host` as an explicit or derived name.
- Mount the host source at `DX_GIT_MOUNT_TARGET=/workspace`.
- Use private default names for the side container's Nix, persist/workspace, and
  bootstrap volumes.
- Use a non-default SSH port, derived or explicitly supplied, so the side
  container can run alongside `dx-host`.
- If the side container already exists with the same mount identity, start and
  attach to it.
- If the side container exists with a different mount identity, refuse by default
  and tell the user the exact destroy/recreate command. Do not silently delete
  even stopped containers.

### Branch Self-Dev Profile

Future helper/profile for UC-1:

```bash
bin/dx-branch [BRANCH]
```

Behavior:

- Derive a container name as `dx-branch-<slug>-<hash>`.
- Derive private volume, key, and port names from the same slug/hash.
- Clone the repo inside the guest and checkout `BRANCH`.
- Never mount the host checkout.
- Never use default `dx-host`, `dx-nix`, `dx-workspace`/`dx-persist`, or
  `dx-bootstrap` resources.

`dx-branch` is a convenience shape, not a prerequisite for `dx-mount`.

## Implementation Notes For Future Code

- Add a shared slug/hash helper for derived names. Normalize path/branch names to
  lowercase alphanumerics plus `-`, trim repeated separators, cap the slug length,
  and append a short stable hash to avoid collisions.
- Reserve `dx-host` centrally so no derived-name helper can return it.
- Add `DX_GIT_MOUNT_TARGET`, default `/workspace`.
- Do not add `DX_GIT_MOUNT_ENABLED` to plain `dx`; mounts are triggered only by
  `dx-mount`.
- Do not introduce host-side marker state for `dx-host`. Side containers may keep
  a marker keyed by their derived name only to verify their own mount identity.
- Do not `chown -R` the bind mount from inside the guest.
- Quote every path. Host paths can contain spaces.
- Keep credential propagation out of the initial `dx-mount` implementation unless
  a separate auth plan chooses one of:
  - launch-time secret injection
  - credentials-only named volume
  - explicit re-auth in the side container

## Validation Plan

Documentation/static validation for this plan update:

```bash
rg -n 'A4b is the best default|Choosing A4b as the default|defaulting to `dx-host`|DX_GIT_MOUNT_ENABLED, defaulting|share full `/persist`|share the main `/nix` by default' mount-git.md | rg -v '^.*rg -n '
```

The command should return no old recommendation language.

Future implementation tests:

- Plain `dx` from inside a host git repo does not attempt any host mount and does
  not alter `DX_CONTAINER_NAME`.
- `dx-mount` rejects `dx-host`.
- `dx-mount` derives stable names and avoids collisions for paths with the same
  basename.
- `dx-mount` handles repo root, repo subdirectory, non-git directory, and paths
  containing spaces.
- `dx-mount` creates exactly one host source mount at `DX_GIT_MOUNT_TARGET`.
- `dx-mount` uses private/namespaced Nix, persist/workspace, bootstrap, key, and
  port defaults.
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
- Whether F4 sync is worth implementing after the F1 spikes.
- Exact branch-helper name and UX. The plan uses `dx-branch` as a concrete
  placeholder.
- Worktree/submodule support for F1. Start with ordinary repos unless validation
  proves the edge cases are safe.
