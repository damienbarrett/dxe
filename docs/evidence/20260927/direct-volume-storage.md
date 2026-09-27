# Direct Docker volume storage (Branch 11 / Phase 3, `feat/qnap-direct-storage`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 3 and
`checkout-consolidation-plan.md`'s Branch 11. No home-directory paths, keys,
fingerprints, daemon IDs, or NAS identifiers appear below; the pre-approved
placeholder alias `qnap-dxe` and the disposable resource names `dx-qnap-spike*`
stand in for the real host throughout.

Branch `feat/qnap-direct-storage`, from `main` `062d727`. Implemented by a
Sonnet subagent against fake `ssh`/`docker` boundaries and guest-bootstrap
fixtures only (12 commits: a design note `f06404c`, its amendment `bc70453`,
Increments 1-7, three follow-ups); reviewed, live-gated, and landed by the
coordinating session (this record's "Landing" section). Design:
`docs/refactor/direct-volume-storage.md`.

## User decisions (2026-09-27)

1. Phase 3 proceeds as a subagent task.
2. Storage is Docker **named volumes in Container Station's default volume
   location**; no bind mounts, no share/pool paths in any tracked file.
3. QNAP guests **start from scratch**: no restore onto the NAS is required,
   so item 7 (the restore drill) is dropped and item 6 is met by the existing
   `dx-backup`/`dx-restore`, proven to render valid Docker argv through the
   runtime exec boundary.
4. The two disposable live checks on the NAS (below) were approved in
   advance ("Approved in advance.").

## What changed

- **The mode reaches the guest explicitly.** `bin/dx-create-container` passes
  two env tokens for both runtimes: `DX_NIX_STORAGE_MODE` and
  `DX_IMAGE_IDENTITY` (the runtime's stable identity for the image, via the
  new contract operation `dx_runtime_image_identity`: Docker `image inspect
  --format '{{.Id}}'`, Apple the `id` from `container image inspect`). This
  is the one deliberate change to Apple's create argv; the characterisation
  expectation was updated on purpose.
- **Explicit bootstrap dispatch** in `base-and-storage.sh`: an absent
  `DX_NIX_STORAGE_MODE` (every container created before this phase, including
  the primary guest) falls through to the apple-image body unchanged;
  `direct-volume` takes a separate function that requires `/nix` to be a
  mountpoint and never calls `mkfs*`, `mount`, `umount`, `truncate`, `blkid`,
  or touches `/etc/fstab` (recording stubs assert none is called); any other
  value refuses.
- **In-place populate** for direct-volume mode, in this order: `/nix/store`
  must already exist (Docker populates an empty named volume from the
  image's content on first mount; a missing store refuses and names that
  dependency); `DX_IMAGE_IDENTITY` must be present; a per-volume marker
  `.dx-image-identity-v1` is written atomically on first boot and compared on
  every later boot — a mismatch refuses before any phase-controlled store
  execution ("recreate the Nix volume, or wait for `store-trust-plan.md`
  Problem 1's verified import"); the original store-identity check stays as a
  corruption-only signal. No remount, no fstab.
- **Design review finding (coordinating session).** The subagent's design
  note correctly showed that the originally specified refusal could not
  detect a plain image bump on a reused volume (Docker's copy never touches a
  non-empty volume, and the image's own store is hidden under the mount).
  The host-provided image identity above is the amendment. Direct-volume
  mode has **no pre-remount window at all**: the entrypoint and every
  bootstrap binary come from the volume's store from the first instruction.
  That is `store-trust-plan.md` Problem 2 in sharper form; stated, not
  waived, not solved here (Branch 12).
- **Helpers through the adapter (item 4):** `dx-create-volumes`,
  `dx-destroy-container`, `dx-destroy-image`, `dx-migrate-persist` proven
  under `docker-ssh` with fakes (DQ6 labels on create, label check before
  volume delete, `run_ephemeral` argv valid Docker syntax). One boundary leak
  fixed: `dx_container_list_names` called the Apple adapter directly; the
  Section 32 audit now also forbids `dx_runtime_apple_*`/`dx_runtime_docker_*`
  calls outside the adapters, with the two authorised exceptions
  (`bin/dx-lock`, `bin/dx-status`'s lock audit) allow-listed.
- **Capability-aware `dx-reclaim` (item 5):** new contract operation
  `dx_runtime_volume_usage` (Apple: the host sparse-image `du -sh`; Docker:
  `docker system df -v` filtered server-side by a Go template); `fstrim` is
  skipped, with one line saying so, when `host_filesystem_reclamation` is
  not supported (DQ4).
- **Backup (item 6):** fake-boundary characterisation that
  `bin/lib/dx-backup.sh` renders `docker exec -i -u dx …` for the stdin phase
  and `docker exec -u dx … tar … -T <file>` (no `-i`) for the stream phase —
  Branch 17's unidirectional discipline survives the adapter.
- Docs: `docs/refactor/direct-volume-storage.md` (design), `docs/lifecycle.md`
  (storage modes, reclaim under docker-ssh, what "start from scratch" means
  for a QNAP volume), `runtime-boundary.md` + inventory (two new operations),
  both plans. The exit gate's "recreate preserves /nix, /persist, …" check
  for direct-volume needs the x86_64 guest and moves to Phase 4's gate.

## Gates (subagent, on `908bb48`; re-checked by the coordinating session)

| Gate | Result |
| --- | --- |
| Fast tier (`tests/run-tier.sh unit/static`) | coordinating session: 22 sections, 1,176 passed, 0 failed, 14 usual local skips |
| bash-3.2 (`/bin/bash tests/run-bash32-tests.sh`) | 24/0, 123/0, 99/0 |
| Pinned ShellCheck 0.10.0 (CI file set) | clean |
| apt ShellCheck 0.9.0 (throwaway `ubuntu:24.04`) + full fast suite inside it | clean / "All tests PASSED!" (caught three SC2034 subshell assignments; fixed by `export`) |
| Coverage (`tests/run-coverage-linux.sh`) | `covered=100%`, `scope_share=21.64%`; ratchet unchanged at 2164 (re-measured on a clean export at landing: 6,755 / 31,209 = 2164) |
| Nix (`nix flake check` on a clean export) | all checks passed, `flake.lock` unchanged |
| Phase 0 dry-runs | exit 0 |
| Private identifier scan | clean |

Red/green: every increment failed first for the intended reason (progress
record, section 3). Two real bugs were caught by tests during the work: an
over-anchored `sed` in the Apple image-identity extractor, and the
container-list boundary leak the audit should have caught and now does.

## Live check 1 — the NAS, disposable resources only (approved in advance)

Run by the coordinating session from the branch worktree with the disposable
local profile (`dx-qnap-spike*` names; git-ignored). Every step bounded by an
alarm, stdin from `/dev/null`, output in the private recovery log.

- `dx-create-volumes` created the three named volumes, each carrying the DQ6
  labels (`io.dxe.managed=true`, `io.dxe.profile`, `io.dxe.role`,
  `io.dxe.schema=1`); `dx_runtime_volume_exists` saw all three.
- `dx-create-image` resolved the Containerfile's digest-pinned base
  reference: the NAS already had that digest (Docker reported "Image is up
  to date", nothing was downloaded), and the disposable tag was created.
  `dx_runtime_image_identity` returned a `sha256:` identity for it.
- **Copy-on-first-mount confirmed:** a throwaway `--rm` run of the tagged
  image with the empty Nix volume at `/nix` saw 124 store entries and
  `/nix/var/nix` present; a probe file written in that run was read back by
  a second run with the same store count, so the volume retains what Docker
  copied. This is the dependency the direct-volume populate relies on.
- **One real defect found and fixed before landing:** `dx_runtime_volume_usage`
  printed `unknown` for every volume. Its template asked `docker system df -v
  --format` for `.UsageData.Size` (the API's byte field); the CLI's volume
  formatter has no such field (Docker 27.1.2 said so verbatim) and exposes
  `.Size` as a human-readable string instead. Fixed in `e2ddf59`, the fake
  updated to answer as the real CLI does (the new test fails against the old
  adapter: 123 passed, 1 failed; 124/0 with the fix), re-run live: the
  populated Nix volume reported 471.4MB, the two empty ones 0B, a missing
  volume `unknown`.
- Cleanup: the three volumes deleted through the label-checked
  `dx_runtime_volume_delete`, the disposable tag removed with
  `dx_runtime_image_delete`; the pre-existing base image was left exactly as
  found. Afterwards no volume carrying `io.dxe.managed=true` remained on the
  NAS, and `dx_runtime_volume_exists`/`dx_runtime_image_exists` were false
  for every disposable name. Nothing production-named was touched; no
  restart or reboot.

## Live check 2 — Apple regression on `dx-test` (disposable)

Run by the coordinating session from the branch worktree (standing rule:
the coordinating session runs live gates; keys copied from the main
checkout, never generated in the worktree). The image is unchanged by this
branch, so only the CONTAINER was recreated, onto the existing `/nix` and
`/persist` volumes — the shape a real `dx-recreate` takes.

- `dx-destroy-container`, `dx-create-image` ("already exists; skipping"),
  `dx-create-volumes` (all three ensured), `dx-create-container`,
  `dx-start-container` (new bootstrap generation synced), `dx-wait-ssh`:
  guest ready in about 75 seconds.
- The container's configuration carries both new tokens,
  `DX_NIX_STORAGE_MODE=apple-image` and `DX_IMAGE_IDENTITY=sha256:…`, and
  the identity equals the host's own `container image inspect` id for the
  image.
- Bootstrap log: "Setting up dedicated Nix volume… Detected block device
  backing /var/lib/dx-nix-raw… Mounting… Reusing durable identity… Nix volume
  image import completed in 0s… Restoring the persisted SSH host identity" —
  the apple-image path, no re-seed, no direct-volume message.
- Preservation: `/persist/home/dx` still held files dated before the
  recreate; `/nix` still showed its 11 GB of store; the bootstrap generation
  running equalled the published one in `dx-status`.
- Full Apple live tier: **35 sections, 1,687 passed, 0 failed, 8 skipped**
  ("All tests PASSED!"), then a cold stop; `dx-test` left stopped.

One process lesson, not a product defect: the first attempt at the tier
stalled for 22 minutes inside Section 27 because the gate script had not
redirected the tier's stdin from `/dev/null` (that section's fake `ssh`
blocks on an open stdin; two stale copies from an earlier run were found
hung the same way and were cleaned up). Re-run correctly, Section 27 passed
in seconds. Recorded as an open follow-up in the consolidation plan (make
the fake robust) and in the live-gate rule.

## Landing (2026-09-27)

`main` had not moved since the branch was cut (`062d727`), so no rebase was
needed. The ratchet measured 6,755 / 31,209 = 2164 bp on a clean export,
equal to the committed baseline. The private identifier scan of
`main..feat/qnap-direct-storage` was clean. Landing also corrected the
Phase 2 mapping doc's `dx_runtime_image_delete` row, which described a label
check the as-built code never had (a pulled, re-tagged image cannot carry
DQ6 labels; ownership is the tag name from the resolved profile).
