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
   `dx-destroy-volumes`). `bin/dx-reset-nix-volume` is the one other
   explicit, narrower exception: it removes only the Nix volume (never
   `/persist` or the bootstrap volume), for the one case `dx-destroy-volumes`
   is too broad for — recovering from a store-trust refusal
   (`store-trust-plan.md`) without also discarding `/persist`.
7. **The bootstrap payload is part of every start.** `dx-start-container`
   always runs `dx-sync-bootstrap` after ensuring the container is running, so edits to
   `home/*.nix` or `bootstrap.sh` land on the next container start without
   an image rebuild. `dx` connects directly when the container is already running;
   applying bootstrap edits then requires an explicit publish and restart.
   When that sync actually publishes a new generation (not the
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
   configuration field (default `apple`; `docker-ssh` is the second
   implemented runtime, for a remote QNAP guest over SSH) to an adapter. An
   automated audit (`tests/test_runtime_boundary_audit.sh`) fails the build
   if a raw `container` call, or a call into either adapter's own
   `dx_runtime_apple_*`/`dx_runtime_docker_*` namespace, reappears outside
   the two adapter files. Two narrowly-scoped exceptions are documented in
   the audit itself: `bin/dx-lock` and `bin/dx-status`'s read-only lock
   helpers, and `bin/lib/dx-container.sh`'s whole-operation destructive
   ownership proof (Branch 11 / Phase 6, `dx_destructive_plan_and_verify`)
   — both call into the Docker adapter directly because neither locking
   nor a multi-resource ownership plan is a `dx_runtime_<op>` the Apple
   side has an equivalent for. See
   [`docs/refactor/runtime-boundary.md`](refactor/runtime-boundary.md).
10. **Storage mode is explicit, not inferred.** `DX_NIX_STORAGE_MODE`
    (`apple-image` default | `direct-volume`) tells the guest bootstrap
    which of the two `/nix` protocols to run, forwarded by
    `dx-create-container` as a plain env token so an absent value (every
    container created before this setting existed) behaves exactly like
    `apple-image`. `apple-image` formats and mounts Apple's own
    runtime-managed raw volume; `direct-volume` (`docker-ssh` only) mounts
    a Docker named volume directly at `/nix` with no formatting, staging,
    or `/etc/fstab` edit at all, relying on Docker's own documented
    behaviour of populating a fresh, empty named volume from the image's
    content at its mount point the first time it is used. This is also
    what "a QNAP guest starts from scratch" means in practice: there is no
    existing `/nix`/`/persist` data to migrate onto a QNAP, so
    `direct-volume` mode is only ever exercised against freshly created
    volumes, and a second `--env DX_IMAGE_IDENTITY=...` token (the
    runtime's own stable identity for the image that created the
    container) lets the guest detect and refuse a later image change on a
    *reused* volume rather than silently trusting mismatched content. See
    "Reclaiming host disk space" below for what else differs by storage
    mode, and
    [`docs/refactor/direct-volume-storage.md`](refactor/direct-volume-storage.md)
    for the full in-guest protocol.
11. **The guest is architecture-neutral; the guest itself selects its own
    system.** One flake tree, evaluated per system
    (`aarch64-linux`/`x86_64-linux`) via a small local `forEachSystem`
    helper, not a duplicated Home Manager/NixVim/bootstrap/scripts tree per
    architecture (qnap-dxe-plan.md DQ7). `packages.<system>.*` and
    `devShells.<system>` exist for both; `homeConfigurations` gains flat
    `"dx-<system>"` attributes, and `homeConfigurations.dx` stays a real
    alias -- the same derivation, not a second definition -- of
    `dx-aarch64-linux`, so nothing that still names the bare attribute
    breaks. The guest never trusts a host-supplied system name blindly: a
    shared sourceable helper
    (`scripts/lib/dx-guest-system.sh`, used by both `bootstrap.sh` and
    `scripts/dx-ai.sh`) maps its own `uname -m` to a Nix system and
    cross-checks it against `DX_GUEST_SYSTEM` -- a third
    `dx-create-container` env token, alongside `DX_NIX_STORAGE_MODE` and
    `DX_IMAGE_IDENTITY` -- refusing before touching Nix if the two
    disagree. `pins/agy.json` (the Antigravity CLI's download pin) is
    keyed per system the same way; an architecture with no native artifact
    gets a JSON `null` entry, `flake.nix` omits that architecture's `agy`
    from `aiPackages` entirely (never substituting a foreign binary), and
    `dx-ai` prints an explicit "agy: no native artifact for `<system>`;
    skipping (DQ7)" and installs everything else. Docker-ssh's resource
    labels (item below) include `io.dxe.system`, and `bin/dx-create-container`
    forwards `DX_GUEST_SYSTEM` unconditionally, so Apple's guest (always
    `aarch64-linux`) sees it too, as a no-op confirmation. See
    [`docs/refactor/arch-neutral-guest.md`](refactor/arch-neutral-guest.md)
    for the full design.
12. **The guest's own SSH address is remote-aware, not assumed loopback.**
    A new contract operation, `dx_runtime_guest_ssh_address`, is what every
    guest-SSH entry point (`dx-ssh`, `dx-herdr`, `dx-wait-ssh`,
    `dx-tunnel.sh`, `dx-status`) actually dials, through the single shared
    option/endpoint builder in `bin/lib/dx-ssh-common.sh`
    (`dx_ssh_endpoint`/`dx_ssh_common_options`) rather than a
    per-caller-hardcoded `dx@127.0.0.1`. Apple's answer is that same fixed
    loopback constant, unchanged; `docker-ssh`'s answer is the NAS's own
    Tailscale address, discovered over the management connection and
    validated, never the LAN or `0.0.0.0` (`qnap-dxe-plan.md` DQ5). See
    "Reaching a QNAP guest over SSH" below for the address, the guest's
    pinned host identity, and what refuses.

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
| [`bin/dx`](../bin/dx) | Checks the container service first, starts Apple Container if needed, and waits up to `DX_SYSTEM_WAIT_TIMEOUT` (default 30s) for readiness; connects directly when running; otherwise `create-keys → create-image → create-volumes → create-container → start-container → wait-ssh → ssh`. |
| [`bin/dx-destroy`](../bin/dx-destroy) | `destroy-container → destroy-image` (preserves volumes and keys) |
| [`bin/dx-recreate`](../bin/dx-recreate) | `dx-destroy → exec dx` (preserves volumes and keys) |
| [`bin/dx-factory-reset`](../bin/dx-factory-reset) | prompts once, then `destroy-container → destroy-image → destroy-volumes --force → destroy-keys` |

### The lifecycle lock (Astra F4)

`bin/lib/dx-runtime-docker-lock.sh`'s remote per-profile lock container
existed with no production caller before WP6.5: two controllers could run
overlapping `create`/`recreate`/`destroy` sequences against the same
profile. `bin/lib/dx-container.sh`'s `dx_lifecycle_lock_acquire`/
`dx_lifecycle_lock_release` are the operation-level boundary every mutating
entrypoint (`dx-create-container`, `dx-start-container`, `dx-stop-container`,
`dx-destroy-container`, `dx-destroy`, `dx-recreate`, `dx`) now calls before
its first mutating runtime call, refusing (or, on Apple, waiting briefly)
rather than issuing any mutation when the lock cannot be claimed.

**Nested ownership.** An orchestrator that runs a mutating entrypoint as a
child process — `dx` running `dx-create-container`/`dx-start-container`,
`dx-destroy` running `dx-destroy-container`/`dx-destroy-image` — acquires
once and exports `DXE_LIFECYCLE_LOCK_OWNER`; a nested `dx_lifecycle_lock_acquire`
call that finds it already set returns immediately, issuing no runtime call
and taking no release responsibility. This works across a plain fork+wait
child (the owner token is exported, so the child inherits it) and across
`exec` (`dx-recreate` execing into `dx`) the same way, but an `exec`'d
program's own local release-responsibility flag does not survive the image
change — so `dx-recreate` and `dx` each release explicitly immediately
before their own final `exec`, rather than relying on an `EXIT` trap that
would never fire across it. `dx-recreate` and `dx` therefore run as two
short, sequential lock holds (one for `dx-destroy`, one for `dx`'s own
create+start), not one continuous hold across the whole recreate.

**Per runtime.** Docker (`DX_RUNTIME=docker-ssh`) dispatches to the existing
remote lock-container protocol: one real controller-exclusion primitive
shared by every profile on the same `DX_REMOTE_HOST`, using Docker's own
atomic `create --name` name-conflict as the exclusion mechanism (never a
raw label check anyone could race). Its failure can never distinguish a
live owner from an interrupted one, so a refusal always prints the current
owner (`dx-lock status`'s own audit) and the remedy — confirm staleness by
other means, then `dx-lock unlock --force` — rather than guessing or
silently stealing it. Apple (`DX_RUNTIME=apple`, the default) has no remote
daemon to exclude at all — Apple Container is always local, one controller,
one daemon, and `bin/dx-lock` itself already refuses outright for this
runtime — so its own `dx_runtime_apple_lock_acquire`/`_release`
(`bin/lib/dx-runtime-apple.sh`) is a narrower local safety net: a plain
`mkdir`+owner-file lock (`bin/lib/dx-host-util.sh`'s `dx_lock_acquire`, the
same primitive `bin/lib/dx-tunnel.sh` uses for its own per-key lock) under
this profile's own state directory, guarding only against two invocations
from the same machine against the same `DX_CONTAINER_NAME` running at once.

**First-run image guard.** The lock container's own base image is
`$DX_IMAGE` (never started, but `docker create` still requires it to
exist), so `dx-create-container` confirms the image exists before ever
attempting the lock — a plain first run with no image yet gets today's
"run `dx-create-image` first" message, never a confusing lock-acquisition
failure.

**Scope per daemon.** The local Nix-volume creation claim
(`dx_nix_volume_claim_dir`) is folded into `dx_profile_state_segment`
(WP3.4), the same per-profile identity segment `dx-tunnel`/`dx-backup`/
`dx-ssh-common` already use, so two `docker-ssh` profiles pointed at
different NASs never collide on the same local claim file merely because
they share `$HOME` and a `DX_NIX_VOLUME` name. Apple's own claim path is
unaffected (a single local daemon has nothing to disambiguate).

### Helpers and runtime utilities

These do not belong to the layer model — they observe state, transfer files,
or perform maintenance operations.

| Script | Role |
| --- | --- |
| [`bin/dx-lib.sh`](../bin/dx-lib.sh) | Short compatibility facade that loads the source-only host libraries and resolves one complete configuration snapshot. |
| [`bin/dx-profile`](../bin/dx-profile) | Parses a named data profile from `${XDG_CONFIG_HOME:-$HOME/.config}/dxe/profiles/<name>.env`, falling back to bundled `tests/profiles/<name>.env`, resolves the complete snapshot, then execs the command. `DX_PROFILES_DIR` selects one explicit directory. A remote Docker-over-SSH profile (`DX_RUNTIME=docker-ssh`, `DX_REMOTE_HOST`, `DX_GUEST_SYSTEM`, `DX_NIX_STORAGE_MODE`, `DX_CONTAINER_RESTART_POLICY`) follows the placeholder-only shape in [`tests/profiles/qnap-example.env`](../tests/profiles/qnap-example.env); keep the real profile in user config and its keys under `~/.ssh/dxe/` (see [`docs/configuration.md`](configuration.md)). |
| [`bin/dx-mount`](../bin/dx-mount) | Launches an isolated side container, records a bounded v2 identity manifest, and exposes audit/migration/destroy-plan modes. Refuses before any mutation under a runtime without the `bind_mounts` capability (`DX_RUNTIME=docker-ssh` today): a controller-local directory is never a valid remote bind source over SSH. |
| [`bin/dx-wait-ssh`](../bin/dx-wait-ssh) | Blocks until guest SSH responds, dialling the guest's own remote-aware address (`dx_ssh_endpoint`). Gates the SSH connection layer. |
| [`bin/dx-status`](../bin/dx-status) | Reports image, container, SSH (the address actually probed, on either runtime), tool, persist, tmux, and profile-aware tunnel migration state; for `DX_RUNTIME=docker-ssh`, also the remote per-profile lock's read-only state. |
| [`bin/dx-lock`](../bin/dx-lock) | `DX_RUNTIME=docker-ssh` only: reports who holds the remote per-profile lock (`status`), or removes it after printing that same owner metadata (`unlock --force`) -- never on elapsed time alone (`qnap-dxe-plan.md` DQ6). |
| [`bin/dx-put`](../bin/dx-put) | Copies host files into the guest. |
| [`bin/dx-forward`](../bin/dx-forward) | Exposes guest web ports on macOS loopback addresses with SSH local forwarding. |
| [`bin/dx-reverse`](../bin/dx-reverse) | Exposes macOS loopback services inside the guest with SSH reverse forwarding. |
| [`bin/dx-enter`](../bin/dx-enter) | Direct `container exec` shell, bypassing SSH. Over `docker-ssh`, the management SSH transport forces its own pty (`-tt`) whenever a TTY was requested, so it works both interactively and driven non-interactively (e.g. `dx-enter <cmd>`). |
| [`bin/dx-gc`](../bin/dx-gc) | Runs Nix garbage collection and store optimization inside the guest. |
| [`bin/dx-reclaim`](../bin/dx-reclaim) | Reclaims host disk space by deleting old Nix generations in the guest and trimming persistent filesystems. |
| [`bin/dx-export`](../bin/dx-export) | Archives the container to a tar file. Atomic: streams to a `.partial` sibling first, verified non-empty, then renamed into place; a mid-stream failure or an interruption removes the partial rather than leaving a truncated file at the final path. |
| [`bin/dx-nix-disk`](../bin/dx-nix-disk) | Prepares a sparse Nix disk image; lifecycle-adjacent storage prep. Apple-only (`raw_nix_disk` capability); refuses immediately under `DX_RUNTIME=docker-ssh`, before any mutation. |
| [`bin/dx-reset-nix-volume`](../bin/dx-reset-nix-volume) | Removes ONLY the Nix volume (`/persist` and the bootstrap volume are untouched); refuses while the container still exists or the runtime reports the volume in use. The volume-scoped recovery path both `store-trust-plan.md` refusals (a collision at a pin bump, or a broken prerequisite right after the volume reaches its final place) name by command: run this, then `./bin/dx` to rebuild `/nix` from the image and re-seed it. Replaces the earlier "no valid procedure, full destroy-and-rebuild with salvage" pin-bump text in `docs/release-maintenance.md`. |
| [`bin/dx-backup`](../bin/dx-backup) | Captures the at-risk contents of `/persist` into a Mac folder, incrementally. |
| [`bin/dx-restore`](../bin/dx-restore) | Pushes a captured mirror (or a named subpath of it) back into a running guest's `/persist`. |
| [`container/.../bootstrap.sh`](../container/dx-nixos-26.05/bootstrap.sh) | Runs the ordered sourceable phases from the atomically published, leased bootstrap generation. |

### Reclaiming host disk space

Apple Container stores named volumes as sparse host images. The apparent size
of those images can stay high after the guest deletes data until the guest
filesystem reports its free blocks back to the host. `dx-reclaim` handles that
maintenance path for the DX volumes, for either storage mode:

```bash
./bin/dx-reclaim
```

Run it when the `dx-nix` or `dx-persist` volume has grown noticeably and you
want to return unused space. The container must already be running.

`dx-reclaim` prints volume usage (via `dx_runtime_volume_usage`: Apple's own
host sparse-image size; a `docker-ssh` guest's Docker-visible volume size, or
`unknown` when Docker cannot say) and guest filesystem usage before and after
the operation. It then:

1. Deletes old Nix generations inside the guest with `nix-collect-garbage -d`
   (identical for both runtimes).
2. **`apple-image` only:** runs `fstrim -v` on `/nix` and `/persist` so
   already-free blocks can be discarded from the sparse host images.
   **`direct-volume` (`docker-ssh`) skips this step entirely** and prints one
   line saying so (`dx_runtime_capability host_filesystem_reclamation`
   answers no for `docker-ssh` — there is no host-side sparse image to trim
   against a Docker named volume).

This does not delete persisted files. It removes only unreferenced Nix store
paths and, under `apple-image`, discards blocks the guest filesystem has
already marked free. It is reasonable to run occasionally after large
rebuilds or dependency churn, but it does not need to run constantly or on a
tight schedule.

### Reaching a QNAP guest over SSH

Branch 11 / Phase 5 (`qnap-dxe-plan.md` DQ5) made every guest-SSH entry
point reach a `docker-ssh` guest directly on the NAS's own Tailscale
address, instead of the controller's loopback Apple always used. Nothing
here changes Apple's own behaviour: `dx@127.0.0.1`, today's exact SSH
options, unchanged.

**The address.** `dx_runtime_guest_ssh_address` (a `dx_runtime_<op>`
contract operation, like every other runtime-neutral call) is Apple's
fixed loopback constant, or `docker-ssh`'s NAS Tailscale IPv4 address,
discovered over the existing management SSH connection (the same
qpkg-CLI-then-interface-fallback shape Phase 0's spike proved), validated
as a dotted quad in Tailscale's own CGNAT range, and cached for the rest
of the process. Never the LAN, never `0.0.0.0`, never written to any
tracked file — an address that cannot be discovered or does not validate
refuses outright ("the NAS has no Tailscale address; DQ5 forbids
publishing on the LAN or 0.0.0.0"). The guest's own SSH port is published
there directly (`bin/dx-create-container`'s neutral `--publish
PORT:2222`, prefixed by each adapter with its own address) — no jump
host, exposure governed entirely by Tailscale ACLs.

**The pin.** `docker-ssh` connections use a real, persistent, per-profile
known-hosts file (`${XDG_STATE_HOME:-$HOME/.local/state}/dxe/<profile-id>/known_hosts`,
`<profile-id>` the same `<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>` identity
tunnel/mount/backup state already uses) with `StrictHostKeyChecking=
accept-new`, prepared 0700 by the SSH option builder itself before ever
dialling out. First contact records the guest's host key normally; a
later mismatch is OpenSSH's own refusal, which already names the
known-hosts file, the offending line, and the exact remedy
(`ssh-keygen -R '[<address>]:<port>' -f <file>`). Apple's disposable,
constantly-recreated local guest is never pinned — there is nothing
stable there worth pinning.

**What refuses, and when.** Fail-closed, before any remote mutation:

| Command | Under `docker-ssh` |
| --- | --- |
| `dx-mount DIR` | Refuses (`bind_mounts` capability absent): a controller-local directory is never a valid remote bind source. |
| `dx-nix-disk` | Refuses (`raw_nix_disk` capability absent): Apple-only sparse-image mechanism. |
| A `--volume git:...` (bind-mount) spec reaching `dx_runtime_container_create` by any path, not only through `dx-mount` | Refuses at the adapter itself, for the same reason, before any `docker create` call. |

**`dx-enter`.** `docker exec -it` requests a pty from the remote Docker
daemon; the outer management SSH transport now forces its own pty
(`-tt`, not a single `-t` — a single `-t` depends on the ssh client's own
local stdin being a real terminal, which `-tt` does not) exactly when a
TTY was requested, so `dx-enter` works both attached to a real terminal
and driven non-interactively. Every other exec caller is unaffected: none
of them request a TTY.

**`dx-export`.** Streams to a `.partial` sibling of the target file,
verified non-empty, renamed into place only on success; a trap removes
the partial on any other exit path (failure or interruption), on both
runtimes.

### Operating a QNAP guest

Install, preflight, day-to-day operation, update, backup, restore, and
removal for a `docker-ssh` guest are covered end to end in
[`docs/qnap-runbook.md`](qnap-runbook.md); this section only records what
Branch 11 / Phase 6 (`qnap-dxe-plan.md`) added to the shared lifecycle
model rather than repeating the runbook's own walkthrough:

- **Health reporting.** `dx-status`'s SSH section now distinguishes two
  states a bare "port open"/"port closed" line could not: the port not
  open yet while the container is running (shows the guest's most recent
  bootstrap-progress marker instead of nothing) and the port open but the
  guest not actually answering a login shell (shows the probe's own
  error). `dx-wait-ssh`'s progress tick prints the same two pieces of
  information on every 30-second tick, not only at final timeout. Both
  reuse existing sources (the guest's own log, the shared SSH option
  builder) — no new `dx_runtime_<op>` contract operation.
- **Container Station display.** A container created under `DX_RUNTIME=
  docker-ssh` optionally carries a Docker `HEALTHCHECK`
  (`dx_runtime_capability container_healthcheck`: no for Apple, yes for
  docker-ssh) whose probe command is SSH-independent — it checks the
  guest's own execution-lease/`current`-symlink state through the same
  `docker exec` plane Container Station's own UI already reads from,
  never the guest's network path.
- **Destructive operations.** `dx-factory-reset` and `dx-destroy-volumes`
  now print an immutable ownership plan and refuse the *whole* operation
  — zero delete calls issued — if any targeted resource under
  `DX_RUNTIME=docker-ssh` fails its DQ6 label check, rather than a
  resource-by-resource partial destroy. See principle 9 above for where
  this lives in the runtime-boundary audit's exception list. Apple's
  behaviour is unaffected: it has no DQ6 labels to check at all.
- **Restart policy and restart ordering** — settled 2026-09-28. A
  maintenance window against a disposable guest proved
  `DX_CONTAINER_RESTART_POLICY=unless-stopped` across a container restart,
  a Container Station restart, and a full NAS reboot on the production
  NAS: state, generation, and the Tailscale-only bind all survived every
  restart kind, with no controller present. Item 9's restart ordering is
  decided as relying on Docker's own restart policy (no NAS-side hook):
  on this NAS `tailscale0` is addressed before Container Station starts
  any container, so the race item 9 exists to handle never occurred; a
  NAS-side autorun hook remains a documented fallback design, never
  implemented without the user's explicit word. The default stays `no` —
  see [the runbook](qnap-runbook.md) for the guardrail on when to opt in,
  and `qnap-dxe-plan.md`'s Phase 6 status and
  `docs/refactor/qnap-lifecycle.md` section B for the full evidence and
  reasoning.

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
| `current` | A symlink to the published `generations/<id>/` (never a plain directory once a run has published through it). Reads (`dx-restore`, `--dry-run`) go through this path exactly as before; only `dx-backup`'s publish step ever repoints it. |
| `generations/<id>/` | One full mirror of the at-risk set as of that run, plus that run's own `manifest.tsv` (`path<TAB>size<TAB>mtime<TAB>sha256` for every mirrored file). Unchanged files are hard-linked forward from the previous generation, never copied or edited in place; only a changed file's fresh bytes land as new files. |
| `.lock/` | A per-mirror lock directory (`bin/lib/dx-host-util.sh`'s `dx_lock_acquire`), shared by `dx-backup` and `dx-restore`. |
| `last-run.log` | One line per completed run: timestamp and the transfer summary. |

**Generations and locking (Astra F5).** A run that changes anything stages
its transfer into a brand-new `generations/<id>/` — carrying every unchanged
entry forward from the previous generation as a hard link, landing only the
fetched files there, and verifying each fetched file's hash against the
selection's own listing — and publishes it by repointing the `current`
symlink only once every one of those steps has fully succeeded. A truncated
transfer, a hash mismatch between listing and transfer, or a failed publish
all leave the previously published generation untouched; only the current
generation plus the one it replaced are ever retained, older ones are
pruned. `dx-backup` and `dx-restore` take the same per-mirror lock before
touching `current` or a generation, so two overlapping backups, or a backup
and a restore, can never interleave their own reads or writes of the
mirror — the second one refuses (or waits, up to a bounded timeout) rather
than reading or writing a partly-published state. `--dry-run`/`--summary`
never take this lock and never create the mirror directory: they only read
the guest listing and the previously published generation's manifest. A
mirror created before this generation model existed (`current/` a real
directory, `manifest.tsv` sitting directly beside it) is migrated
automatically, in place, the first time a real `dx-backup` run takes the
lock — its existing content is renamed (never copied or re-transferred)
into `generations/legacy-<id>/`, retained as the previous generation
exactly like any other; `dx-restore` never migrates anything, so an
unmigrated mirror still restores correctly, read-only.

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
