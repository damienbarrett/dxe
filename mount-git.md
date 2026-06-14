# Plan: Git Repository Access For `dx` — Remaining Work

The original plan chose how git repositories are made available to a `dx`
guest. The chosen design is implemented: guest-native clones under `/persist`
are the primary workflow (UC-1), and host bind mounts exist only behind the
explicit `bin/dx-mount` side-container command (UC-2), shipped in commit
`d0a82a4`, validated interactively, covered by
`tests/test_section18_mount_git.sh`, and documented in the README
("Mounting a Host Checkout"). This file now tracks only the decisions that
remain binding and the follow-up work that is still open.

## Decisions That Remain Binding

These constrain all follow-up work; they are recorded here because they are
design rationale, not derivable from the code:

- **Apple Container fixes a container's mount set at create time.** There is
  no `container mount`; changing a mount means destroy + recreate. Therefore
  plain `dx` stays mount-free, `dx-host` is never rebound by mount logic, and
  host mounts live only in derived side containers.
- **No default durable sharing for side containers.** The default `dx-nix`
  volume is writable and single-writer; `/persist` holds credentials and
  durable state. Side containers use private/namespaced volumes, keys, and
  ports by default. They may share the immutable default image.
- **UC-3 (isolated `dxe` self-development) requires no shared durable state
  with `dx-host`**, including the image, because the lifecycle/image scripts
  are what is under test. Private throwaway volumes are acceptable isolation.
- **Derived names are typed by workflow:** `dx-mount-<slug>-<hash>` for
  mounts, `dx-branch-<slug>-<hash>` for branch self-dev. The slug/hash derives
  from the mounted source (repo top-level), so subdirectories of one repo
  reuse one side container.
- **Continuous file sync (Mutagen/Unison-style) remains the fallback** if
  bind mounts prove unsuitable for a specific repo or workflow; it is not
  implemented.
- **Never `chown -R` the bind mount from inside the guest.** Policy
  constraint; the current implementation honours it.

## Open Work

1. **`dx-branch` helper for UC-3.** A thin profile generator: derive a
   `dx-test.env`-shaped set of `DX_*` values from the branch name (container
   `dx-branch-<slug>-<hash>`, private image, Nix, persist, and bootstrap
   names, private key, derived port), drive the existing `dx` pipeline, then
   clone the repo and check out the branch inside the guest. Never mount the
   host checkout. Until it exists, UC-3 is achievable by hand: copy
   `tests/profiles/dx-test.env`, rename every resource, and run through
   `bin/dx-profile`. The helper name `dx-branch` is a placeholder.

2. **Seeded/read-only Nix base for side-container cold starts.** Each side
   container's private Nix volume pays a full store bootstrap on first boot.
   `dx-mount` shipped with this cost documented; a seeded or shared read-only
   base remains a desirable optimization. The mechanism is undecided
   (host-side volume clone, export/import of a populated store, or a
   read-only shared mount) and must not violate the single-writer constraint
   on the default `dx-nix` volume.
   *Interaction with [`flakes-to-nix.md`](flakes-to-nix.md):* side-container
   volume names (`<container>-nix`) do not encode the base-image flavor, so
   any seeding mechanism must seed from the matching flavor's store (see that
   plan's open decision on side-container flavor identity).

3. **Credential propagation for side containers.** Intentionally out of
   scope so far; side containers currently require explicit re-auth. If
   needed, choose one of: launch-time secret injection, a credentials-only
   named volume, or keeping explicit re-auth as the documented answer. Do not
   share all of `/persist` just to get credentials.

4. **Automatic port retry.** When the derived SSH port is busy, `dx-mount`
   refuses with `DX_SSH_PORT` guidance. Whether to retry to an alternate
   derived port automatically is still open; refusal is the shipped behavior.

5. **Worktree and submodule support.** Repos whose `.git` metadata points
   outside the mounted tree are unvalidated. Start with ordinary repos;
   validate the edge cases before claiming support.

6. **Destroy-path live validation.** `dx-mount --destroy` (private volumes,
   key pair, marker removal; refusal of default dx-host resources) is wired
   and statically tested against a stubbed container CLI, but has not been
   exercised end-to-end against real Apple Container state — interactive
   validation deliberately avoided destroying containers. Run it once for
   real and confirm no orphaned resources remain.
