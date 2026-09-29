# D8 — Docker-over-SSH adapter: development history and rejected alternatives

**Recorded 2026-09-30 (WP8.3 step 6).** Astra R3 found the adapter's
comments narrating individual branches, increments, coordinating sessions,
and historical alternatives already recorded elsewhere, making the current
contract harder to locate beside the code. This document is where that
narrative now lives; `bin/lib/dx-runtime-docker.sh` and the four files it
sources (`dx-runtime-docker-transport.sh`, `-identity.sh`, `-lifecycle.sh`,
`-lock.sh`) keep only concise invariants, failure behaviour, and platform
constraints, with a pointer back here where the "why now" matters.

## Origin: Branch 11, qnap-dxe-plan.md DQ1–DQ8

The docker-ssh runtime adapter was built on git branch `Branch 11` against
`qnap-dxe-plan.md`'s eight design questions (DQ1–DQ8), in phases (Phase 0
through Phase 6). The phase numbers below are the historical record of
*when* each piece landed; the adapter files themselves only cite the DQ/item
numbers that still identify a live requirement.

### Phase 0 — the spike that ruled out the obvious designs

Phase 0 was a spike against the real QNAP NAS (production infrastructure,
off-limits to any later test) that eliminated three designs before any
adapter code was written:

- **Docker's own `-H ssh://` transport was tried first and rejected.** It
  fails silently: the NAS's non-interactive SSH PATH lacks `docker`, and
  Docker's ssh transport just runs `docker ...` on whatever that shell
  resolves — it does not fail loudly, it fails to find the binary and
  reports a confusing error. `tests/qnap/phase0-spike.sh` reproduces the
  finding directly. The adapter instead issues plain, non-interactive SSH
  commands (`ssh -o BatchMode=yes ... <host> <docker-abs-path> <verb> ...`)
  and discovers the Docker CLI's absolute path itself, once per process.
- **A remote `docker build` is refused outright.** "QNAP's Docker wrapper
  creates a per-user build directory ... and refuses it there for a
  non-default administrator." `dx_runtime_docker_image_build` therefore
  never builds — it pulls a pinned reference and tags it, exactly Phase
  0's spike's proven steps 2+3 (pull, then tag).
- **The Containerfile constraint this forces.** Because there is no remote
  build, the Containerfile in this repository is, and must stay, a single
  `FROM <pinned-ref>@sha256:...` line — confirmed by the coordinating
  session on 2026-09-27, which also confirmed the guest's actual content
  comes from the bootstrap volume, never image layers.  `dx_runtime_docker_base_image_ref`
  fails closed if the Containerfile ever grows a second stage or a
  RUN/COPY instruction, rather than silently building only part of it.

### Phase 2 — quoting discipline and structured output

The two design choices that shaped every later function: `%q`-quote every
token before joining them into ssh's single remote command string (DQ1:
"positional data, never interpolated executable text"), and never parse
`docker ... | awk` table output — always request a `--format` Go template
that returns exactly the field(s) needed.

### Phase 3 — image identity and capability-aware sizing

`dx_runtime_docker_image_identity` (direct-volume image-bump detection) and
`dx_runtime_docker_volume_usage` (the `docker system df -v` sizing query
for `bin/dx-reclaim`) both date from Phase 3. The volume-usage query's
`.Size` vs `.UsageData.Size` choice was verified live against a real
Container Station Docker (27.1.2) on 2026-09-27: the byte-count template
(`.UsageData.Size`) failed outright with `can't evaluate field UsageData in
type *formatter.volumeContext`, so the adapter uses the human-readable
`.Size` string Docker's own CLI formatter already produces, matching what
the Apple side's `du -sh` prints.

### Phase 4 — DQ6 labels and `io.dxe.system`

The five `--label k=v` pairs every docker-ssh-created resource carries
(`io.dxe.managed`, `io.dxe.schema`, `io.dxe.profile`, `io.dxe.role`, and
`io.dxe.system`, design point E of this phase) so an image, container,
volume, or lock can never be mistaken for a different profile or a
different guest architecture.

### Phase 5 — guest address, publish flag, pty forcing, and the bind-mount refusal

- The shared `--publish "PORT:2222"` spec (no bind address) is rendered
  with `dx_runtime_docker_guest_ssh_address`'s own discovered Tailscale
  address (DQ5: never loopback, never the LAN, never `0.0.0.0`).
- `docker exec -it`'s outer ssh transport needs its own pty allocation
  (`-tt`, not a single `-t` — OpenSSH's manual is explicit that a single
  `-t` does not force allocation when the client's own stdin is not a real
  terminal) for the remote pty request to actually reach the daemon.
- **Coordinating session's decision 4:** a `git:` (bind mount) volume's
  NAME field is a controller-local directory path, never a valid remote
  bind source over SSH. The session decided this refuses at the adapter
  level (`dx_runtime_docker_container_create`'s own backstop) as well as
  at `bin/dx-mount`'s fail-fast guard, so a caller that sets
  `DX_GIT_MOUNT_SOURCE` directly and runs `bin/dx-create-container`
  without going through `bin/dx-mount` still gets refused before any
  remote mutation.

### Phase 6 — the whole-operation destructive plan and container healthcheck

qnap-dxe-plan.md Phase 6 item 7 asked for more than a per-resource DQ6
check at delete time: an IMMUTABLE PLAN printed before ANY deletion, with
the WHOLE operation refused (zero delete calls reached) if any one target
fails its label check. `dx_runtime_docker_destructive_plan_and_verify`
implements this; `bin/dx-factory-reset`/`bin/dx-destroy-volumes` reach it
through `bin/lib/dx-container.sh`'s runtime-neutral
`dx_destructive_plan_and_verify` rather than duplicating the label-query
internals outside the adapter boundary. Phase 6 item 4 also authorised the
one neutral create-time health flag (`--health-cmd`/`--health-interval`/
`--health-retries`), which render as Docker's own real create flags with no
translation needed.

## WP3.4 / Fable A1 — the daemon-identity cache bug and its fix

Before WP3.4, `dx_runtime_docker_host_identity` (and everything that keys
off it — `dx_tunnel_key`, `dx_backup_resolve_dir`, `dx_ssh_known_hosts_dir`)
always cost a fresh ssh round trip unless the identity happened to already
be cached in the *same process*. A later process on an unreachable host —
exactly the moment an operator wants `dx-forward --list`/`--stop` to work —
had to dial out just to recompute a path for state that already existed
locally. Worse, docs/reviews/2026-09-29-fable.md #A1 found that a failing
`$(...)` used only as a `printf` argument does not abort under `errexit`,
so the identity segment silently became empty instead of refusing. The fix
(`dx_runtime_docker_daemon_id_cache_write`/`_read`, WP3.4) persists the
resolved daemon id once known — 0600, atomic tmp+mv, directory 0700 — so a
later call in a *different* process resolves the same identity, and
therefore the same local paths, without touching the network again.

## Branch 17 — unidirectional-exec discipline

`dx_runtime_docker_exec`'s non-tty path must remain byte-for-byte what it
was before pty forcing was added: `bin/dx-enter` is the only caller that
ever passes `-it`; every other caller (`dx-gc`, `dx-reclaim`, `dx-status`,
`bin/lib/dx-backup.sh`'s `-i` phase, `dx-sync-bootstrap`) passes `-i`
alone, `-u` alone, both, or neither, and this discipline (established on
git branch `Branch 17`) requires all of those to keep working unmodified.

## `bin/dx-lock` — a new entrypoint, and why the lock is a never-started container

The remote per-profile lock (`dx_runtime_docker_lock_*`) is not part of the
`dx_runtime_<op>` contract at all — Apple's runtime is always local, one
controller, one daemon, with no concurrent-invocation problem to solve, so
it has no lock concept to dispatch to. `bin/dx-lock` is a new entrypoint
the coordinating session authorised specifically for this. Docker's only
atomic "create, fail if already present" primitive is container-NAME
uniqueness (`docker volume create` is idempotent and does *not* fail if the
volume already exists, so it cannot serve as an exclusion primitive;
`docker create --name X` fails atomically with a "Conflict... name is
already in use" error if X exists) — so the lock itself is a labelled,
never-started container named `dxe-lock-<profile-id>`, using the
already-pulled/tagged `$DX_IMAGE` as its base image, purely as a naming
slot it never runs.

## Increment 8 — the ephemeral-run retry that was not added

Apple's own retry loop (`dx_runtime_apple_run_ephemeral`) exists solely for
Apple Container's own "no runtime client exists: container is stopped"
race. Docker over SSH has no documented equivalent, so
`dx_runtime_docker_run_ephemeral` carries no retry. This was a deliberate
non-decision at Increment 8's live gate: if later characterisation work
surfaces a distinct Docker-side race, that is new evidence for a scoped
retry then, not something to guess at in advance.

## WP8.3 — splitting the adapter (2026-09-30)

Muse A2, Fable A7, and Astra R3 (docs/reviews/2026-09-29-*.md) all
independently flagged the same god-file: 1,109 lines, 55 functions, 482
comment lines, 27 near-identical `require_bin`/`ssh_exec` preambles. WP8.3
addressed this in steps:

1. **Steps 1–2:** a byte-equality transcript fixture
   (`tests/fixtures/docker-adapter-transcript.txt`) captured every adapter
   operation's rendered ssh argv before any change, then
   `dx_runtime_docker_cli` collapsed the 27 repeated
   `require_bin`-then-`ssh_exec` preambles to one call each.
2. **Step 3:** the file split along its natural seams into
   `dx-runtime-docker-transport.sh` (quoting, ssh option/raw/exec,
   `require_bin`, `cli`), `-identity.sh` (discovery, the daemon-identity
   cache, host identity, label verification, ownership checks),
   `-lifecycle.sh` (create/start/stop/kill/delete/exec/volumes/logs/export/
   run_ephemeral/destructive plan), and `-lock.sh` (acquire/audit/release),
   with `dx-runtime-docker.sh` itself becoming the facade that sources all
   four in the order their cross-file calls require. Every function name
   is unchanged; a code-multiset diff against the pre-split file (comments
   and blank lines excluded) confirmed no line of code was altered, only
   regrouped. `tests/test_runtime_boundary_audit.sh`'s adapter allow-list
   was extended from the two named files (`dx-runtime-apple.sh`,
   `dx-runtime-docker.sh`) to `*/lib/dx-runtime-docker-*.sh`, since each
   split file carries the same genuine `docker container <verb>` CLI
   syntax the monolithic file did.
3. **Step 5:** `bin/dx-forward` and `bin/dx-reverse` — 44-line mirror
   images differing only in which side of a port mapping is the
   deduplicated, non-privileged "key" (forward keys on the host port,
   reverse keys on the guest port) — were merged into one
   `dx_tunnel_cli <direction> "$@"` in `bin/lib/dx-tunnel.sh`, leaving each
   entrypoint its shared preamble plus two direction-specific lines
   (`forward_main`/`reverse_main` and the `BASH_SOURCE` guard, preserving
   the WP4.1 contract).
4. **Step 6 (this document):** the branch/phase/increment/coordinating-
   session narrative above was moved out of the five adapter files, in
   favour of the concise invariant/failure-behaviour/platform-constraint
   text that remains beside the code, plus a pointer here.

Step 4 of the original plan — moving `dx_nix_volume_claim_*`
(`bin/lib/dx-container.sh:301–378`, 78 lines of runtime-neutral local
claim state that live in the file whose header says "Apple Container
adapter") to a new `bin/lib/dx-claims.sh` — was skipped by design for this
pass: it requires editing `bin/lib/dx-container.sh`, which is out of scope
here and left for the agent that owns that file.
