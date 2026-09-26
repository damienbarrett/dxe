# QNAP-hosted DXE implementation plan

Plan created: 2026-09-21.

## Status

Open. Implementation has not started.

Revisit trigger: when the target QNAP can be reached over Tailscale for the
Phase 0 preflight, or when work on the runtime abstraction is scheduled.

## Outcome

Add a supported remote-Docker runtime so the existing DX Experience can be
created, configured, used, upgraded, diagnosed, and removed on a QNAP NAS from
the macOS controller. The intended normal workflow remains recognizably the
same:

```sh
./bin/dx-profile qnap ./bin/dx
./bin/dx-profile qnap ./bin/dx-status
./bin/dx-profile qnap ./bin/dx-recreate
```

The controller reaches the QNAP by its Tailscale MagicDNS name. Container
lifecycle operations use the standard Docker Engine interface over SSH. The
interactive DX session uses the QNAP as an SSH jump host to a guest SSH port
bound only to QNAP loopback.

```text
macOS controller
  |
  | Tailscale + management SSH / Docker Engine over SSH
  v
QNAP host (QTS or QuTS hero + Container Station)
  |
  | Docker image, container, exec, logs, and named volumes
  v
dx-host container
  |
  +-- /nix             persistent Docker volume
  +-- /persist         persistent Docker volume
  +-- /guest-bootstrap persistent Docker volume
  +-- sshd :2222       published on QNAP 127.0.0.1 only
```

The Apple Container implementation remains the default and must not regress.

## Non-goals

- Do not expose the Docker daemon on TCP 2375 or publish it to the LAN or
  internet.
- Do not depend on an undocumented Container Station REST API. Container
  Station remains the QNAP UI, while automation uses Docker's supported CLI/API
  boundary.
- Do not install Tailscale inside the DX guest. Only the QNAP host needs to be
  a tailnet node.
- Do not run the QNAP container in privileged mode.
- Do not emulate an unsupported CPU architecture for the production guest.
- Do not make a QNAP implementation commit refresh `flake.lock`, upgrade the
  Nix channels, or change the Apple Container version unless a separately
  reviewed change requires it.
- Do not claim that a macOS checkout is bind-mounted into a remote Docker
  daemon. The current `dx-mount DIR` behavior is explicitly out of scope for
  the first usable QNAP release.
- Do not automatically destroy or migrate the existing Apple DXE, its keys, or
  its volumes.

## Decisions

### DQ1 — Use Docker Engine over SSH as the control plane

The controller invokes Docker with an SSH endpoint derived from a validated
OpenSSH host alias, for example `ssh://qnap-dxe`. This allows `docker build`,
`docker exec`, streaming stdin, logs, volume operations, and container lifecycle
commands without copying the repository to QTS.

Prefer a command-scoped endpoint over changing the user's global Docker
context. The adapter may use either of these equivalent forms internally:

```sh
docker --host ssh://qnap-dxe container ls
DOCKER_HOST=ssh://qnap-dxe docker container ls
```

The OpenSSH alias owns the username, management identity file, MagicDNS name,
host-key policy, and any connection multiplexing. DXE configuration stores the
alias, not arbitrary SSH option text.

If QNAP's non-interactive `PATH` does not expose the Container Station Docker
CLI, Phase 0 must identify its stable absolute path. The adapter may invoke a
small fixed remote command over SSH in that case; user-controlled values still
cross as validated positional data, never interpolated executable text.

### DQ2 — Keep one lifecycle model and add runtime adapters

Do not fork the lifecycle scripts into `dx-qnap-*` copies. Extract a narrow
runtime contract and provide two implementations:

```text
bin/lib/dx-runtime.sh          selection and runtime-neutral contract
bin/lib/dx-runtime-apple.sh    existing Apple Container behavior
bin/lib/dx-runtime-docker.sh   remote Docker behavior
```

The existing `dx-create-X`/`dx-destroy-X` entrypoints continue to orchestrate
the layers. Runtime-specific CLI syntax, queries, force-stop behavior, and host
process handling live only in their adapter.

The minimum adapter contract covers:

- preflight and stable remote-host identity;
- image exists, build, list, and delete;
- volume exists, create, inspect, usage query, and delete;
- container exists, running query, create, start, stop, kill, and delete;
- container exec with optional stdin, user, TTY, and captured output;
- logs and export streaming;
- runtime capabilities such as direct named-volume mounts, bind mounts,
  restart policy, and host filesystem reclamation.

No production entrypoint may call raw `container` or `docker` lifecycle verbs
outside a runtime adapter after this extraction is complete.

### DQ3 — Preserve local defaults; require an explicit QNAP profile

`DX_RUNTIME=apple` remains the default. A checked-in example profile documents
the QNAP shape but must not contain a real hostname, username, private key, or
secret. A local ignored profile selects the actual NAS.

New configuration fields:

| Field | Apple default | QNAP meaning |
| --- | --- | --- |
| `DX_RUNTIME` | `apple` | Set to `docker-ssh`. |
| `DX_REMOTE_HOST` | empty | Validated OpenSSH alias for the QNAP. Required for `docker-ssh`. |
| `DX_GUEST_SYSTEM` | `aarch64-linux` | `aarch64-linux` or `x86_64-linux`, matching `uname -m`. |
| `DX_NIX_STORAGE_MODE` | `apple-image` | Set to `direct-volume`. |
| `DX_CONTAINER_RESTART_POLICY` | `no` | Initially `unless-stopped` after reboot behavior passes the live gate. |

The configuration snapshot remains complete, versioned, and resolved once.
Runtime-derived defaults must be resolved during initialization rather than
silently re-read by child scripts. Invalid cross-field combinations fail before
contacting either runtime.

### DQ4 — Mount the Docker Nix volume directly at `/nix`

Apple Container currently exposes a small runtime-managed volume and the guest
creates a btrfs/ext4 filesystem inside it. Remote Docker does not need that
indirection. Under `DX_NIX_STORAGE_MODE=direct-volume`:

- mount `DX_NIX_VOLUME` directly at `/nix`;
- mount `DX_PERSIST_VOLUME` at `/persist`;
- mount `DX_BOOTSTRAP_VOLUME` at `DX_BOOTSTRAP_PATH`;
- do not grant `CAP_SYS_ADMIN`;
- do not create a sparse image, loop mount, format a device, edit `/etc/fstab`,
  or run guest `fstrim` against the Docker volume;
- still establish and validate the durable Nix-store identity before importing
  or executing persistent store content.

The direct-volume branch must be explicit. It must not rely on the current
"raw path missing, therefore skip setup" fallback, because that would bypass
part of the store-identity protocol. The unresolved trust cases documented in
`store-trust-plan.md` are not waived for QNAP.

Use Docker named volumes for the first release. A later, separately reviewed
change may add a QNAP shared-folder bind for `/persist` after path validation,
ownership, snapshot, backup, and restore behavior are proven on the actual NAS.

### DQ5 — Keep guest SSH private to the QNAP host

Publish guest SSH as:

```text
127.0.0.1:<DX_SSH_PORT>:2222
```

Connect through the management host:

```sh
ssh -J qnap-dxe -p 2222 dx@127.0.0.1
```

The same jump-aware option builder is used by interactive SSH, command SSH,
`dx-put`, `dx-get`, `dx-forward`, `dx-reverse`, `dx-wait-ssh`, and Herdr. No
helper gets a one-off transport implementation.

The QNAP management host key must use normal OpenSSH verification. Before
production cutover, persist the guest's SSH host identity and stop using
`StrictHostKeyChecking=no` for the QNAP profile. Key rotation needs an explicit
operator-visible procedure.

### DQ6 — Make resource ownership visible in Docker

Every QNAP-created image, volume, container, and coordination object carries
labels sufficient to prove ownership before mutation. At minimum:

```text
io.dxe.managed=true
io.dxe.schema=<version>
io.dxe.profile=<stable-profile-id>
io.dxe.role=image|container|nix|persist|bootstrap|lock
```

Destructive commands verify both the exact configured name and matching labels.
An existing same-named unlabelled or differently labelled object is a collision,
not an adoption candidate.

Remote state transitions use a Docker-visible per-profile lock with atomic
name creation. A crash may leave a stale lock, but elapsed time alone never
authorizes removal. Provide an audit command and a separate explicit unlock
operation that prints the immutable target and owner metadata before asking for
confirmation. The normal lifecycle fails closed on a lock it cannot prove it
owns.

### DQ7 — Support the NAS's native architecture

Phase 0 records the target result of `uname -m`:

| QNAP result | DX guest system | Disposition |
| --- | --- | --- |
| `aarch64` | `aarch64-linux` | Reuse the existing system output after runtime portability work. |
| `x86_64` | `x86_64-linux` | Add and build a native x86_64 output and architecture-specific binary pins. |
| 32-bit ARM | none | Unsupported for DXE. Stop the plan. |

Make the guest source tree architecture-neutral rather than duplicating the
Home Manager, NixVim, bootstrap, and scripts trees. Architecture-specific
download pins, including Antigravity, become a keyed data map. A missing native
artifact disables that optional tool with an explicit diagnostic; it never
causes a foreign binary to be installed silently.

The existing architecture/runtime-encoded context directory can be renamed only
in a standalone mechanical commit. Update every path consumer and test in that
commit, retain a bounded compatibility reader if profiles persist the old path,
and do not mix the move with runtime behavior changes.

### DQ8 — Do not pretend every Apple-host helper has remote parity

Classify each command before the first release:

| Command or capability | QNAP release disposition |
| --- | --- |
| `dx`, image/volume/container lifecycle, start/stop, status, SSH, wait, put/get, GC | Required. |
| `dx-forward` and `dx-reverse` | Required through the jump-aware guest SSH transport. |
| `dx-enter` | Required through remote `docker exec`. |
| `dx-export` | Required; stream the archive to the controller and test interruption cleanup. |
| `dx-ai`, Herdr, themes, tmux, NixVim | Required guest-level parity, subject to native package availability. |
| `dx-reclaim` | Guest Nix GC only. Apple sparse-image and `fstrim` reporting is unsupported on Docker. |
| `dx-nix-disk` | Apple-only; fail immediately with a clear capability message. |
| `dx-mount DIR` | Unsupported in the first QNAP release; fail before runtime mutation because a controller path is not a remote bind source. |
| factory reset and volume destruction | Implemented only after isolated destructive tests and ownership labels pass. |

A later plan may add an explicit remote-worktree sync command. It must define
direction, deletion, conflict handling, ignored files, symlinks, permissions,
and interruption recovery; it must not overload `dx-mount` with snapshot-copy
semantics.

## Invariants

All existing invariants in `docs/refactor/constraints.md` continue to apply. In
addition:

- Apple Container remains the zero-configuration default.
- QNAP management occurs only over the named SSH/Tailscale route.
- QNAP host identity is verified before any Docker mutation.
- No QNAP port is published beyond loopback unless a separate, explicit feature
  defines the exposure and its access control.
- A runtime mismatch never makes an Apple command act on QNAP or a QNAP command
  act locally.
- Remote destructive actions require exact runtime, host, profile, name, and
  ownership-label agreement.
- `/nix`, `/persist`, and bootstrap state survive image and container
  replacement. Only the explicit volume-destruction/factory-reset path removes
  them.
- A failed build, sync, bootstrap, SSH connection, or controller disconnect
  leaves the previous persistent state recoverable.
- A QNAP or Container Station reboot does not require an interactive controller
  session to preserve state.
- Sourceable libraries remain side-effect free and compatible with macOS Bash
  3.2. Guest modules may continue to target their pinned Linux Bash.
- Tests use non-default names, ports, labels, and volumes. Destructive live
  tests refuse default resources.

## Phase 0 — Target discovery and disposable proof

Do not modify production resources during this phase.

### Inventory

Run through the QNAP's Tailscale name and record sanitized results in a short
target note linked from this plan:

```sh
ssh qnap-dxe '
  uname -m
  uname -r
  command -v docker
  docker version
  docker info
  docker compose version
  getconf _NPROCESSORS_ONLN
  awk "/MemTotal/ { print }" /proc/meminfo
'
```

Also record:

- QNAP model, QTS or QuTS hero version, and Container Station version;
- Tailscale package/version and whether its host interface survives reboot;
- filesystem/storage-pool type and free space available to Container Station;
- whether a non-default administrative account can run Docker non-interactively;
- the Docker CLI path in an SSH non-interactive shell;
- whether the Docker SSH transport supports `docker system dial-stdio`;
- current QNAP backup and snapshot coverage;
- CPU and memory headroom while normal NAS workloads are active.

Never record credentials, auth keys, tailnet secrets, full Docker environment,
or private registry tokens in the repository.

### Disposable spike

Using names prefixed `dxe-spike-`:

1. Connect with a command-scoped Docker SSH endpoint.
2. Pull the pinned base image for the native architecture.
3. Build the current minimal `Containerfile` remotely.
4. Create three disposable named volumes with DXE labels.
5. Run a disposable container with the Nix volume mounted directly at `/nix`
   and without privileged mode or `CAP_SYS_ADMIN`.
6. Stream a small tar payload through `docker exec -i` and verify its digest.
7. Bind guest port 2222 to QNAP loopback and reach it through `ProxyJump`.
8. Restart the container, Container Station, and—during an agreed maintenance
   window—the NAS; verify volumes and loopback-only publication persist.
9. Delete only the labelled spike resources and prove unrelated resources were
   untouched.

### Exit gate

- Native architecture is supported or the plan stops with a recorded reason.
- Docker over SSH, stdin streaming, loopback publishing, named volumes, and
  reboot persistence work on the actual QNAP.
- Resource limits are chosen from observed hardware rather than inheriting the
  current 12 GB/four-CPU defaults blindly.
- No spike resource or port remains.

### Phase 0 scripts

Versioned, non-interactive, idempotent replacements for running the
Inventory and Disposable spike sections above by hand:

- `tests/qnap/phase0-inventory.sh` — runs the Inventory list's commands
  over one SSH session (discovering the Docker CLI and Tailscale by glob
  rather than assuming either is on the non-interactive PATH — confirmed on
  the real NAS that neither is) plus the Mac-side `docker -H ssh://<alias>
  version` control-plane finding, and writes a full report and a small
  whitelisted-fields-only summary.
- `tests/qnap/phase0-spike.sh` — runs the Disposable spike's nine steps as
  individually reported steps, scoped throughout to `dxe-spike-*`-named,
  `dxe.role=spike`-labelled resources; every Docker command runs as a plain
  SSH remote command against the discovered absolute path (DQ1's fallback,
  not the local Docker CLI's own ssh transport); `--cleanup` alone removes
  only those.
- `tests/qnap/README.md` — access setup (the `ssh_config` alias and
  authorized-keys step), how to run both scripts, how to read their
  output, and this section's exit gate restated for operators.
- `tests/test_section27_qnap_scripts.sh` — container-free contracts against
  a stub `ssh`/`docker`, run in CI and via `tests/run-tier.sh unit/static`.
- `tests/test_section1_secrets.sh` — extended with generic leak-shape
  detectors (tailnet IPs, Tailscale MagicDNS suffixes, QNAP storage-pool
  paths, SSH public-key blobs/fingerprints, PEM private-key headers) so a
  future accidental paste of NAS-identifying detail into a tracked file
  fails this gate.

The NAS is a production system and this repository is public: both
scripts' full report and summary default OUTSIDE the repository (under
`$HOME/dxe-recovery/qnap/`), never inside it. The only thing this plan
document should ever record from a real run is a one-line outcome —
native architecture supported (yes/no) and Docker-over-SSH viability —
added by hand; never the full or summary report content.

Status unchanged: this is tooling for Phase 0, not a run of it. Nothing
above has been executed against a real QNAP; see `tests/qnap/README.md`
for the two spots (the spike's in-container listener choice and its
Container Station restart command) that are necessarily best-effort until
a real NAS is reachable.

## Phase 1 — Characterize and extract the runtime boundary

This phase changes structure without adding QNAP behavior.

1. Add behavior tests around every Apple runtime operation currently used by an
   entrypoint, including error and timeout paths.
2. Define the runtime capability and operation contract from DQ2.
3. Move Apple-specific implementation into `dx-runtime-apple.sh` without
   changing commands, output, defaults, or state.
4. Make `DX_RUNTIME=apple` explicit in the configuration registry and resolved
   snapshots.
5. Replace raw runtime calls in entrypoints with adapter functions.
6. Add an automated source audit that rejects new raw lifecycle calls outside
   runtime adapters and approved tests.
7. Run all current non-live and isolated Apple live gates before proceeding.

### Exit gate

- Existing Apple behavior is unchanged and the full existing suite is green.
- Runtime selection is explicit, validated, and side-effect free while sourced.
- Adapter behavior, including stdin and exit-status preservation, has 100%
  sourceable-shell coverage.
- The repository is green between the mechanical extraction and any Docker
  implementation commit.

## Phase 2 — Add the remote Docker adapter safely

Develop with fake `docker` and `ssh` boundaries first.

1. Add and validate `DX_REMOTE_HOST` and the Docker SSH endpoint derivation.
2. Implement read-only preflight: SSH host verification, native architecture,
   Docker availability, Engine/CLI compatibility, and stable Docker daemon ID.
3. Implement image, volume, and container queries with structured Docker output
   (`--format`/inspect JSON), never human table parsing.
4. Implement create/start/stop/kill/delete, exec, logs, build, and export while
   preserving meaningful remote exit statuses.
5. Add DQ6 labels and collision refusal before enabling deletion.
6. Add remote per-profile locking and explicit stale-lock audit/unlock.
7. Scope local caches, tunnel state, and manifests by runtime plus stable remote
   daemon identity so two QNAPs cannot collide.
8. Make connection loss, authentication failure, missing Docker access, daemon
   restart, and partial stdin transfer distinct diagnostics.

### Exit gate

- Host-contract tests cover success, refusal, timeout, broken SSH transport,
  remote command failure, name collision, label mismatch, concurrent create,
  stale lock, and interrupted streaming.
- No destructive operation can target an unlabelled or mismatched resource.
- Read-only `dx-status` against the disposable QNAP profile works before any
  production-named resource is allowed.

## Phase 3 — Add direct Docker storage mode

1. Add the explicit `direct-volume` bootstrap branch from DQ4.
2. Mount `/nix` directly and remove Apple-only mount/format/fstab steps from
   that branch.
3. Preserve Nix store identity, base-image provenance, ownership, and bootstrap
   rollback checks.
4. Make create/delete/migrate helpers operate on remote Docker volumes through
   the adapter.
5. Give QNAP `dx-reclaim` capability-aware output: run Nix garbage collection,
   report Docker-visible volume usage where reliable, and skip Apple sparse
   image/fstrim operations.
6. Define a controller-side, streamed backup and restore procedure for all
   irreplaceable `/persist` data. Do not treat container export as a volume
   backup.
7. Perform a restore drill into a new non-default volume and container before
   production cutover.

### Exit gate

- Recreate preserves `/nix`, `/persist`, SSH authorization, tool state, and the
  current bootstrap generation.
- Factory reset is still disabled for QNAP at this point.
- Store identity mismatch fails before untrusted persistent store content is
  executed.
- A documented backup can restore `/persist` into an isolated container.

## Phase 4 — Make the guest architecture-neutral

1. Parameterize flake outputs for the Phase 0 target and retain
   `aarch64-linux` Apple outputs.
2. Move architecture-specific external download pins into keyed data with hash
   validation.
3. Add the native Antigravity artifact if one exists; otherwise mark only that
   optional tool unsupported on the affected architecture.
4. Verify every required package is available for the target system.
5. Ensure image tags and labels include the guest system so an image cannot be
   mistaken for a different architecture.
6. If renaming the context tree, do it in the separate mechanical commit
   described by DQ7.

### Exit gate

- `nix flake check --no-build` evaluates every supported system.
- The target closure builds natively on the actual QNAP or another matching
  native Linux builder; emulation is not the release proof.
- Apple aarch64 build and live gates remain green.
- The QNAP guest verifies the required CLI inventory after bootstrap.

## Phase 5 — Make SSH and user workflows remote-aware

1. Extend the shared SSH option builder with an optional validated jump host;
   do not duplicate it in individual commands.
2. Adapt wait/status probes to test the guest through the jump host rather than
   controller loopback.
3. Route interactive SSH, command SSH, put/get, Herdr, and guest probes through
   the shared transport.
4. Verify `dx-forward` and `dx-reverse` semantics through `ProxyJump`, including
   their existing lock/socket cleanup behavior.
5. Route `dx-enter` through remote runtime exec.
6. Stream `dx-export` to an atomic controller-side temporary path, rename only
   after success, and clean partial output after interruption.
7. Add capability checks and fail-closed messages for `dx-mount`, `dx-nix-disk`,
   and unsupported reclaim operations.
8. Persist and pin the guest SSH host identity for the QNAP profile.

### Exit gate

- Every command in the DQ8 required set works from an external network over
  Tailscale.
- Guest port 2222 is unreachable through the QNAP's LAN and public addresses
  but reachable through the verified management jump.
- Forward and reverse tunnels still bind controller loopback by default.
- An unsupported command fails before creating, modifying, or deleting remote
  state.

## Phase 6 — QNAP lifecycle, reboot, and operational hardening

1. Add the QNAP profile example and an operator runbook covering install,
   preflight, normal operation, update, backup, restore, and removal.
2. Choose CPU and memory defaults from Phase 0 observations and document how
   they interact with NAS workloads.
3. Enable `unless-stopped` only after the existing-current-generation bootstrap
   path succeeds without a controller following container and NAS reboots.
4. Ensure Container Station displays useful names, labels, health, ports, and
   logs for DXE resources created through the Docker API.
5. Add health reporting that distinguishes Docker health, bootstrap progress,
   SSH readiness, Nix/Home Manager activation, and optional-tool state.
6. Test QTS/QuTS and Container Station update survival using the documented
   backup first; never perform an update solely for this test.
7. Implement QNAP volume destruction and factory reset only now, with immutable
   plans, exact ownership proof, non-default destructive tests, and the existing
   typed confirmation behavior.
8. Document emergency access when Tailscale is down without opening permanent
   public ingress.

### Exit gate

- A NAS reboot, Container Station restart, laptop network change, and failed
  direct Tailscale path with relay fallback do not lose state.
- Normal start after reboot uses the last complete bootstrap generation.
- Backup and restore are demonstrated, not merely documented.
- Factory reset cannot remove Apple resources, another QNAP profile, or
  unrelated Container Station resources.

## Phase 7 — Promotion and maintenance proof

Promote a non-default canary profile before creating the production QNAP DXE.

1. Run the canary for normal development work long enough to exercise Git,
   Nix, tmux, editors, AI tools, tunnels, suspend/reconnect, and controller
   network changes.
2. Rebuild the image and recreate the canary while preserving volumes.
3. Restore its `/persist` backup into a second isolated profile and verify
   content and permissions.
4. Run an explicit destructive lifecycle only against disposable labelled
   resources.
5. Record target versions and final validation evidence.
6. Create the production profile with distinct keys, names, ports, volumes, and
   local state.
7. Keep the Apple DXE intact until the QNAP instance has passed the acceptance
   period and irreplaceable data has a verified backup.

### Exit gate

All definition-of-done items below are satisfied and no temporary compatibility
exception lacks an owner and removal condition.

## Test strategy

Use Red -> Green -> Refactor in every phase, per `constitution.md`. Tests should
assert behavior at the adapter and trust boundaries rather than matching shell
source text.

### Non-live tests required in CI

- configuration grammar, precedence, snapshot versioning, and invalid runtime
  combinations;
- Apple and Docker adapter contract suites against recorded/fake CLI output;
- safe positional transport of spaces, quotes, leading dashes, newlines where
  permitted, and rejected metacharacters in identifiers;
- Docker inspect/JSON parsing and daemon identity;
- ownership labels, collision refusal, lock behavior, and destructive planning;
- stdin streaming with producer failure, consumer failure, short read, and
  connection loss;
- SSH jump option construction and exit-status preservation;
- runtime capability handling for every public command;
- both supported Nix systems evaluated without building;
- Bash 3.2 compatibility for every host library and entrypoint;
- 100% coverage over newly added sourceable shell modules.

### Live Apple regression tier

Run the existing isolated Apple profile and release checks. The QNAP work does
not lower or replace the Apple live gate.

### Live QNAP tiers

Use a dedicated profile whose image, container, volumes, SSH port, labels,
locks, and local state cannot equal production defaults.

| Tier | Required proof |
| --- | --- |
| Read-only | Preflight, daemon identity, status, collision reporting, no mutation. |
| Disposable lifecycle | Build, volumes, create, start, bootstrap, SSH, stop, restart, recreate, export. |
| Persistence | `/nix`, `/persist`, bootstrap generation, guest host key, and tool state survive recreate and reboot. |
| Transport | Public Wi-Fi/Tailscale, direct and relay paths, jump SSH, put/get, forward/reverse tunnels. |
| Failure injection | SSH drop, Docker restart, bootstrap failure, full/near-full volume, name collision, lock left behind, interrupted export/sync. |
| Restore | Fresh volumes and a new container recover from the documented `/persist` backup. |
| Destructive | Explicit opt-in; non-default resources only; prove unrelated resources remain byte-for-byte/identity unchanged. |

The real QNAP boundary must be tested at least once for every privileged or
trust-sensitive fake: Docker socket access, labelled deletion, loopback-only
port binding, direct `/nix` persistence, restart policy, and backup restore.

## Rollout and backout

- Land each phase as independently revertible commits; keep the suite green
  between them.
- Land readers before writers for any new persisted config, labels, lock
  records, or state layout.
- Keep QNAP resources isolated under non-default names until final promotion.
- Before a container/image change, back up `/persist` and retain the previous
  image tag until the new guest passes health checks.
- Backout normally means select the previous image and recreate the container
  against the same volumes. It must never mean deleting volumes.
- If the remote adapter is unsafe or unavailable, the Apple default remains
  usable by omitting the QNAP profile.
- Reverting a writer is allowed only while the retained reader can still read
  every state format already emitted.

## Definition of done

- The QNAP passes Phase 0 and its native architecture has a supported guest
  output.
- The existing Apple workflow and all current tests remain green.
- The required DQ8 command set works through one explicit QNAP profile.
- No Docker daemon or guest service is exposed publicly; guest SSH is
  loopback-only behind the verified jump host.
- Image/container recreation preserves `/nix`, `/persist`, bootstrap state, and
  SSH identity.
- NAS and Container Station restarts recover without state loss.
- Runtime, host, profile, name, and ownership labels are verified before every
  destructive action.
- Unsupported remote-host semantics fail clearly before mutation.
- Native target Nix outputs build and the required guest tool inventory passes.
- `/persist` backup and isolated restore have both been executed successfully.
- Non-live, Apple live, QNAP live, failure-injection, and isolated destructive
  gates are documented and green.
- Operator documentation covers setup, daily use, upgrades, backup, restore,
  diagnostics, emergency access, and complete removal.

## Open questions resolved by Phase 0

These are evidence requests, not invitations to choose silently during
implementation:

1. What exact QNAP model, CPU architecture, RAM, OS, Container Station version,
   storage pool, and available capacity are present?
2. Does the non-interactive administrative SSH environment expose a Docker CLI
   compatible with Docker's SSH transport?
3. What resource limits leave sufficient headroom for the NAS's primary duties?
4. Does the QNAP Tailscale package provide a stable host-network interface after
   QTS/QuTS and Container Station restarts?
5. Is a native Antigravity CLI artifact available for the target architecture?
6. Which QNAP backup destination and retention policy will protect `/persist`?
7. What maintenance window is available for the one NAS reboot proof and later
   OS/Container Station update validation?
