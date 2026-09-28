# The Docker-over-SSH adapter: contract → command mapping

Branch 11 / Phase 2 (`qnap-dxe-plan.md` "Phase 2 — Add the remote Docker
adapter safely"). Written as a design document in Increment 0, before any
adapter code existed; now (Increments 1-9 complete) it also serves as the
as-built reference for `bin/lib/dx-runtime-docker.sh`'s command-by-command
shape, kept current rather than superseded because the vast majority of
what it originally proposed is exactly what was built. Maps every
`dx_runtime_<op>` of the Phase 1 contract (`bin/lib/dx-runtime.sh`,
`docs/refactor/runtime-boundary.md`) to the exact remote command
`bin/lib/dx-runtime-docker.sh` issues for `DX_RUNTIME=docker-ssh`, the
structured-output query it uses, its failure classes, and which Phase 2
item (1-8, `qnap-dxe-plan.md` "## Phase 2") it satisfies.

Everything here follows directly from `qnap-dxe-plan.md`'s decisions
(DQ1-DQ8) and Phase 0's proven findings (`tests/qnap/lib/phase0-common.sh`,
`tests/qnap/phase0-spike.sh`, `tests/qnap/phase0-inventory.sh`), except
`dx_runtime_container_create`'s parameter shape, which changed during
Increment 4 for a reason this document did not originally anticipate: see
`dx_runtime_container_create`'s row in section 4 and
`docs/refactor/runtime-boundary.md`'s "Phase 2" section for what changed
and why. The three points originally flagged for review, and a fourth
flagged during Phase 2's own implementation, are all resolved (see
"Flagged for review" at the end, now a decision log, not an open list) --
the fourth (`bin/dx-mount`'s missing `bind_mounts` guard) by Branch 11 /
Phase 5 item 7.

## 1. How every remote command is built (DQ1, Phase 2 item 1)

Every `dx_runtime_docker_<op>` issues zero or one SSH round trip of this
exact shape (Phase 0's `dxe_qnap_ssh_exec`/`dxe_qnap_docker_run`, adapted from
the hard-coded `DXE_QNAP_HOST`/env-var world to the resolved `DX_REMOTE_HOST`
config field):

```sh
ssh -o BatchMode=yes -o ConnectTimeout=<DX_REMOTE_HOST_CONNECT_TIMEOUT> \
    -o LogLevel=ERROR \
    <DX_REMOTE_HOST> <docker-abs-path> <verb> <arg>...
```

No `ssh://` Docker transport (confirmed broken on the real NAS's
non-interactive `PATH`, per `qnap-dxe-plan.md`'s Phase 0 outcome and
`phase0-common.sh`'s `dxe_qnap_docker_run` comment) and no persistent
`docker context`; the endpoint is command-scoped every time. `<docker-abs-path>`
is discovered once per run (section 3 below) and cached; it is never
re-derived by a child process.

**The quoting rule (why it exists).** SSH's exec channel has no real remote
argv: the client concatenates every trailing argument after the destination
with a single space and hands the joined string to the remote login shell to
parse as one command line. `phase0-spike.sh` hit this directly (steps 5 and
6: a multi-word `sh -c` script, passed as one of several trailing ssh
arguments, had its quoting destroyed by ssh's own rejoin, producing a remote
syntax error / a silently corrupted `sha256sum` invocation) and fixed it by
building the *entire* remote command as one already-quoted string with a
`printf %q`-based helper (`dxe_argv_desc`) before handing ssh that single
string as its only trailing argument. The docker-ssh adapter reuses this
shape for every call that carries more than a bare docker verb + plain
tokens: each individual value (image ref, volume name, container name, label
value, shell snippet) is independently `%q`-escaped, then the tokens are
joined with single spaces into one remote command string. This is how DQ1's
"user-controlled values still cross as validated positional data, never
interpolated executable text" and `docs/refactor/constraints.md`'s "Values
cross shell-command boundaries as positional arguments or validated
environment data, not by interpolation into generated executable text" are
satisfied over a transport that only ever accepts one string: quoting
discipline stands in for argv separation, and it is applied uniformly, not
ad hoc per call site. A plain-token call (e.g. `docker version`, `docker ps
-a`) does not need the helper; anything carrying a name, label value, or
shell snippet does.

Values are also validated *before* they ever reach this helper (existing
`dx_config_validate_value` shape for the new fields in section "Increment 1"
of the task) — quoting prevents a validated value from being misparsed by
the remote shell, it is not the only defence against an invalid one.

## 2. Label schema (DQ6, item 5)

Every image, volume, container, and lock resource this adapter creates
carries:

```text
io.dxe.managed=true
io.dxe.schema=<DXE_CONFIG_SNAPSHOT_VERSION_CURRENT, or a docker-adapter-specific schema constant>
io.dxe.profile=<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>
io.dxe.role=image|container|nix|persist|bootstrap|lock
```

`io.dxe.profile` identifies "this DXE profile" (an alias + container-name
pair), distinct from `io.dxe.owner` (section 6) which identifies "this
particular lock acquisition." Every destructive command (`image_delete`,
`volume_delete`, `container_delete`, lock release) first runs a structured
label query against the exact configured name and refuses — before issuing
any mutating command — if the resource is absent, or present but missing any
of these labels, or present with a label value that does not match this
profile. An existing same-named object that is unlabelled or differently
labelled is a collision, never an adoption candidate (DQ6, verbatim).

## 3. Preflight and stable remote identity (item 2)

Run once per process, cached (mirrors `dx_init_config`'s own
`DXE_CONFIG_RESOLVED` idempotency guard — a second call in the same process
reuses the cached facts rather than re-issuing SSH):

1. **Host verification** — `dxe_qnap_require_reachable`'s shape: a real (not
   dry-run) `ssh -o BatchMode=yes -o ConnectTimeout=... <DX_REMOTE_HOST>
   true`. Failure here is the "connection loss"/"authentication failure"
   diagnostic branch point (section 7).
2. **Native architecture vs `DX_GUEST_SYSTEM`** — `ssh ... <alias> uname -m`;
   map `x86_64`→`x86_64-linux`, `aarch64`→`aarch64-linux`; anything else, or a
   mismatch against the configured `DX_GUEST_SYSTEM`, refuses before any
   Docker call (DQ7's 32-bit-ARM "stop the plan" case included).
3. **Docker path discovery** — Phase 0's exact snippet, reused not
   duplicated: `dxe_qpkg_binary_discovery_snippet`/
   `dxe_qnap_docker_discovery_remote_script`'s shape (`command -v docker`,
   falling back to the qpkg glob
   `/share/*/.qpkg/container-station/bin/docker`), one SSH round trip,
   result cached as the adapter's resolved docker-binary path for the rest
   of the process. `NOTFOUND` is the "missing Docker access" diagnostic.
4. **Engine/CLI compatibility** — `<docker> version --format '{{json .}}'`.
   Structured query (never `docker version`'s free-text table). Compatible
   means: the command exits 0 **and** the parsed JSON's `.Server.Version`
   (equivalently `.Server.Platform.Name`) is non-empty. An empty/absent
   `.Server` block with a 0 exit status (CLI present, daemon unreachable or
   API-incompatible) is the "missing Docker access" / "daemon restart"
   diagnostic branch, not a hard crash.
5. **Stable Docker daemon ID** — same preflight family, one more field from
   a single `<docker> info --format '{{json .}}'` call: `.ID` when present
   and non-empty; if Docker ever omits or empties `.ID`, fall back to a
   short hash of `.ID` (may be empty) + `.Name` + `.Architecture` +
   `.OperatingSystem` from that same JSON blob — still one query, still
   structured, never a second round trip just to get a fallback.

`dx_runtime_docker_host_identity` returns
`docker-ssh:<DX_REMOTE_HOST>:<daemon-id-from-step-5>` — the alias makes two
different profiles pointing at genuinely different NASs distinguishable even
before any daemon call succeeds; the daemon ID additionally catches the case
where an alias silently starts resolving to a *different* daemon underneath
an unchanged name (DNS/Tailscale IP reassignment, a swapped NAS) — the two
together are item 7's "runtime plus stable remote daemon identity."

`dx_runtime_docker_available` is preflight steps 1-4 (identity's daemon-ID
step is folded into the same `docker info` call `available` already needs
for other fields, so `host_identity` costs no extra round trip beyond
`available`'s own).

## 4. Per-operation mapping

Legend: **cmd** = remote command line (via section 1's ssh shape; docker
verbs only, `<docker>` stands for the discovered absolute path); **query** =
structured-output form used, if any; **fails** = failure classes from
section 7's taxonomy that this op must distinguish; **item** = Phase 2 item
number(s) satisfied.

### Preflight / identity

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_available` | section 3, steps 1-4 | `<docker> version --format '{{json .}}'`, `<docker> info --format '{{json .}}'` | connection-loss, auth-failure, missing-docker-access, daemon-restart | 1, 2 |
| `dx_runtime_system_running` | `<docker> info` (exit status only; no output needed) | none (exit code) | connection-loss, missing-docker-access | 2 |
| `dx_runtime_system_start` | **refused, no remote command issued** — see "Flagged for review" below: this is a settled refusal, not an open question | n/a | n/a (always the same operator-facing refusal message) | 2, 8 |
| `dx_runtime_host_identity` | reuses `available`'s `docker info` JSON, no extra call | `.ID` (+ fallback hash) from `docker info --format '{{json .}}'` | connection-loss (identity unknown until reachable) | 2, 7 |

### Image

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_image_exists` | `<docker> image inspect <ref>` | exit status; `--format '{{json .}}'` if labels are also needed by the caller | connection-loss | 3 |
| `dx_runtime_image_list` | `<docker> image ls --filter label=io.dxe.managed=true --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'` (corrected 2026-09-28 at a Phase 4 exit-gate: the as-built format string had joined Repository and Tag into one `{{.Repository}}:{{.Tag}}` column — a colon, no whitespace — instead of this row's own separate, tab-delimited columns; `bin/dx-status`'s pre-existing `grep "^${DX_IMAGE}[[:space:]]"` then matched nothing against `dx-qnap-spike-nixos:latest ...`, exited 1, and `set -e` killed dx-status right after its own header lines. Apple's `container image list` already prints NAME and TAG as separate columns, which is why the identical grep worked there and this never surfaced until a real image existed on the docker-ssh side. `tests/test_docker_runtime_adapter.sh`'s fake now refuses the joined shape and `tests/test_section9_host_scripts.sh` gained a docker-ssh dx-status characterisation case reproducing the NAS failure) | raw text for human display only (matches the inventory's existing "raw text for human display" scoping of this op; nothing in `bin/` parses its output except `dx-status`'s pre-existing name-anchored `grep`, which this column order preserves) | connection-loss | 3 (display, not a query the adapter itself parses) |
| `dx_runtime_image_build` | never a remote `docker build`: parses the Containerfile's single `FROM <ref>` line (fail-closed on anything beyond exactly one such line) then `<docker> pull <ref>` + `<docker> tag <ref> <image>` — see "Flagged for review" item 1 for why this differs from the load/save design first proposed here | n/a | connection-loss, malformed-containerfile | 4 |
| `dx_runtime_image_delete` | `<docker> image rm <ref>` -- no label check: the image is the pulled, digest-pinned upstream base re-tagged with `DX_IMAGE` (see `image_build`), and `docker tag` cannot attach labels, so there is nothing DQ6-shaped to verify on it; ownership is carried by the tag NAME, which only ever comes from the resolved profile (corrected 2026-09-27 at Phase 3's landing: this row had described a label check the as-built code never had) | n/a | connection-loss | 4 |
| `dx_runtime_image_identity` (Branch 11 / Phase 3, added after this document's original Phase 2 scope; see `docs/refactor/direct-volume-storage.md` section 5) | `<docker> image inspect --format '{{.Id}}' <ref>` | `{{.Id}}` (`sha256:<hex>`, rendered by Docker's own template, no controller-side parsing) | connection-loss | n/a (Phase 3) |

### Volume

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_volume_exists` | `<docker> volume inspect <name>` | exit status; `--format '{{json .}}'` when labels are needed | connection-loss | 3 |
| `dx_runtime_volume_create` | `<docker> volume create --label io.dxe.managed=true --label io.dxe.schema=<v> --label io.dxe.profile=<profile-id> --label io.dxe.role=<nix\|persist\|bootstrap> <name>` (role resolved from which of `DX_NIX_VOLUME`/`DX_PERSIST_VOLUME`/`DX_BOOTSTRAP_VOLUME` the given name matches; refuses to create an unrecognised name unlabelled) | n/a (create) | connection-loss, name-collision (pre-check via inspect first: an existing same-named, differently-labelled volume refuses instead of `volume create`'s own silent idempotent success) | 4, 5 |
| `dx_runtime_volume_delete` | label check then `<docker> volume rm <name>` | `{{json .Labels}}` from `volume inspect` | connection-loss, label-mismatch | 4, 5 |
| `dx_runtime_volume_usage` (Branch 11 / Phase 3, added after this document's original Phase 2 scope; `qnap-dxe-plan.md` Phase 3 item 5) | `<docker> system df -v --format "{{range .Volumes}}{{if eq .Name \"<name>\"}}{{.Size}}{{end}}{{end}}"` -- Docker's own template filters by name and returns just the matching volume's size, never a `{{json .}}` blob needing a parser on the controller. Corrected 2026-09-27: the byte-count field is `.UsageData.Size` on the API, but the CLI's `system df -v` formatter only exposes `.Size` -- Docker's own human-readable string (`"4.835MB"`, `"0B"`, or `"N/A"`), not a byte count; `{{.UsageData.Size}}` fails outright ("can't evaluate field UsageData in type *formatter.volumeContext"). Re-verified live against a real Docker CLI (29.4.0) 2026-09-28 (Finding 5's audit): `{{.Size}}` still correct. | Docker's own human-readable size string, printed verbatim (also what the Apple side's `du -sh` prints); "unknown" when empty/unparseable or the query fails | connection-loss | n/a (Phase 3) |

### Container

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_container_exists` | `<docker> container inspect <name>` | exit status; `--format '{{json .}}'` | connection-loss | 3 |
| `dx_runtime_container_running` | `<docker> container inspect --format '{{.State.Running}}' <name>` (a direct scalar template, not a `{{json .}}` blob parsed on the controller) | `true`/`false` string compare | connection-loss | 3 |
| `dx_runtime_container_list` (Branch 11 / Phase 4 gained the fourth column, design point E) | `<docker> ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "io.dxe.system"}}'` (corrected 2026-09-28, Finding 5, NAS re-gate: the as-built format string had used `{{index .Labels "io.dxe.system"}}` -- inspect's map-style label access -- but `docker ps`/`ls` render `.Labels` as a comma-separated STRING, not a map; only `docker inspect` exposes it as a map. A real Docker CLI (29.4.0, verified live 2026-09-28) rejected the old string outright: "failed to execute template: ... error calling index: cannot index slice/array with type string". This broke dx-status's Container section under docker-ssh (dies right after the section header) and would have broken `dx_container_list_names` the same way had it ever run against real Docker (unaffected only because its own `awk` never looks past the first column). The correct field for `ps`/`ls` is `.Label "io.dxe.system"` -- a method, singular, not `index .Labels`. `tests/test_docker_runtime_adapter.sh`'s fake now refuses the old map-style shape inside a `ps` format, and `tests/test_section9_host_scripts.sh`'s docker-ssh dx-status characterisation case was extended to cover the Container section too, alongside the existing Image section one. Every other `--format` string in this file was re-audited for the same mistake and re-verified live against the same real Docker CLI: every `inspect` call (`image_identity`, `container_running`, `container_delete`, the docker-ssh preflight's `discover_daemon_id`, the remote-lock audit/release, `volume_delete`) correctly uses map-style `index .Labels`/`index .Config.Labels`, since `inspect --format` genuinely exposes Labels as a map -- only this one `ps` row had the mismatch) | raw text for human display only (same scoping as `image_list`) | connection-loss | 3 |
| `dx_runtime_container_create` | rendered from the runtime-neutral vocabulary (see the note at the top of this document and `runtime-boundary.md`'s Phase 2 section), not hand-mapped per flag: `<docker> create --name <name> --entrypoint sh --volume <nix-vol>:/nix:<mode> --volume <persist-vol>:<target>:<mode> --volume <bootstrap-vol>:<target>:<mode> -e <K=V>... -m <memory> --cpus <cpus> -p <publish> --restart <policy> --label io.dxe.managed=true --label io.dxe.schema=<v> --label io.dxe.profile=<profile-id> --label io.dxe.role=container <image> -c <entrypoint-cmd> -- <entrypoint-args...>` (DQ4 direct-volume mode: no `--privileged`, no `--cap-add SYS_ADMIN`; `--cpus` is Docker's real fractional-CPU flag, never Apple's `-c`/CPU-count meaning) | n/a (create) | connection-loss, name-collision | 4, 5 |
| `dx_runtime_container_start` | `<docker> start <name>` | n/a | connection-loss, daemon-restart | 4 |
| `dx_runtime_container_stop` | `<docker> stop -t <DX_STOP_GRACE_SECONDS> <name>` (bounded the same way `container_stop_bounded` already bounds the Apple call) | n/a | connection-loss, daemon-restart | 4 |
| `dx_runtime_container_kill` | `<docker> kill <name>` | n/a | connection-loss | 4 |
| `dx_runtime_container_delete` | label check then `<docker> rm [-f] <name>` | `{{json .Config.Labels}}` from `container inspect` | connection-loss, label-mismatch | 4, 5 |

### Exec / logs / export

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_exec` | `<docker> exec [-i] [-t] [-u <user>] <name> <cmd>...` — **but see section 6**: any caller needing both stdin *and* bulk stdout is split into two unidirectional calls, never one bidirectional `-i` exec | n/a (pass-through) | connection-loss, daemon-restart, partial-stdin-transfer | 4, 8 |
| `dx_runtime_logs` | `<docker> logs [-n <N>] <name>` | n/a (raw stream) | connection-loss | 4 |
| `dx_runtime_export` | `<docker> export <name>` (stdout stream over the same ssh channel back to the local redirect target — unidirectional, no stdin, so none of section 6's split applies) | n/a (raw stream) | connection-loss, partial-stdin-transfer (mid-stream truncation, detected the same way as any interrupted stream: short byte count / non-zero exit) | 4 |

### Ephemeral run / capability

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_run_ephemeral` | `<docker> run --rm -v <vol>:<mount> --entrypoint sh <image> -lc '<script>' -- <args>` | n/a | connection-loss, daemon-restart, partial-stdin-transfer (if the caller feeds stdin — same section-6 split applies) | 4 |
| `dx_runtime_capability` | no remote command — a fixed table, like Apple's | n/a | n/a | 8 (feeds DQ8's per-command disposition table) |

`dx_runtime_docker_capability`'s fixed answers, matching DQ3/DQ4/DQ8:

| capability | docker-ssh answer | why |
| --- | --- | --- |
| `direct_named_volume_mounts` | yes | DQ4: `/nix`, `/persist`, bootstrap all mount via named volumes directly |
| `bind_mounts` | no | DQ8: `dx-mount DIR` is unsupported in the first QNAP release — a controller-local directory is never a valid remote bind source |
| `restart_policy` | yes | DQ3: `DX_CONTAINER_RESTART_POLICY` is a real docker-ssh field (`no`\|`unless-stopped`), unlike Apple's fixed "no" |
| `host_filesystem_reclamation` | no | DQ8: Apple's sparse-image/`fstrim` host-side reclamation has no Docker equivalent; guest-side `nix-collect-garbage` still works via `dx_runtime_exec`, unaffected |
| `raw_nix_disk` (Branch 11 / Phase 5) | no | DQ8: `bin/dx-nix-disk`'s sparse Apple raw-disk-image mechanism has no Docker equivalent at all; `bin/dx-nix-disk` refuses immediately, before any mutation |
| `container_healthcheck` (Branch 11 / Phase 6) | yes | `qnap-dxe-plan.md` Phase 6 item 4, the one neutral create-time health flag pre-authorised for the phase: `bin/dx-create-container` always passes `--health-cmd`/`--health-interval`/`--health-retries`; Apple discards them exactly like `--restart-policy` (no HEALTHCHECK concept in `container create`), docker-ssh renders `docker create --health-cmd ... --health-interval ... --health-retries ...` verbatim (Docker's own flag names, no translation). The probe command is SSH-independent — reachable through the same `docker exec` plane Container Station's own health display already uses, never the guest's tailnet path — and reuses the existing execution-lease/`current`-symlink state `dx-status`'s Bootstrap Generation section already reads, rather than a new guest-side marker |

## 5. Ephemeral-run retry (Apple's race vs. Docker)

`dx_runtime_apple_run_ephemeral`'s bounded retry exists solely for Apple
Container's own `no runtime client exists: container is stopped` race
(`docs/refactor/runtime-boundary.md`). Docker over SSH has no documented
equivalent race for `docker run --rm`. The docker-ssh implementation of
`run_ephemeral` therefore does **not** carry that retry loop; if Increment 4's
characterisation work (fake `docker`/`ssh`) or the eventual live gate
surfaces a distinct Docker-side race, that is new evidence for a
scoped retry to be added then, not something to guess at now.

## 6. Splitting bidirectional exec (Branch 17 finding)

Branch 17 found that an exec which both feeds stdin and reads bulk stdout
over the same multiplexed channel can stall a transfer. The same shape
exists here: `docker exec -i` over an SSH-tunnelled connection multiplexes
stdin-in and stdout-out over one channel exactly like the Apple case did.
Concretely, this affects any call site (backup/restore streaming through
`bin/lib/dx-backup.sh`'s two tar directions, `dx-put`'s host→guest tar
piping) once Increment 4 ports them: instead of one
`... | ssh ... <docker> exec -i <name> tar ...` doing both directions at
once, the docker-ssh adapter issues two separate, unidirectional remote
invocations for any operation that needs both:

- host→guest: one `docker exec -i` carrying only stdin (guest write, no bulk
  stdout expected back beyond a short status/hash line read separately if
  needed);
- guest→host: one `docker exec` (no `-i`) carrying only stdout (guest read,
  no stdin).

This matches Phase 0's own step 6 (`tar -cf - | ssh ... exec -i ... tar -xf -
-C /tmp` for the host→guest half, then a *separate* `ssh ... exec ... sh -c
'sha256sum ...'` call for reading the verification hash back) — Phase 0
never combined a bulk write and a bulk read in one exec, and this adapter
formalises that as the design rule, not merely an accident of that script's
structure.

## 7. Diagnostics taxonomy (item 8)

Every remote call classifies its failure into one of these, each with its
own operator-facing message (never a bare "command failed"):

| Class | Detected by |
| --- | --- |
| Connection loss | `ssh` exits 255 with stderr matching `Connection (refused\|closed\|timed out)`, `ssh: connect to host .* port .*: .*`, or an empty capture combined with a non-zero ssh exit before any remote output appeared |
| Authentication failure | `ssh` exits 255 with stderr matching `Permission denied`, `Host key verification failed`, or `Too many authentication failures` |
| Missing Docker access | ssh itself succeeds (reaches the remote shell) but the docker invocation fails with `command not found` (stale cached path — triggers one re-discovery, section 3 step 3) or `permission denied` (remote user lacks Docker Engine access) |
| Daemon restart | a previously-succeeding call now fails with `Cannot connect to the Docker daemon`, `Is the docker daemon running?`, or an inspect/exec against a previously-confirmed-running container now reports it stopped/gone with no lifecycle command of ours having stopped it |
| Partial stdin transfer | the write-half of a section-6 split exits non-zero, or the expected byte count/hash (same sha256-verification shape as `phase0-spike.sh` step 6) does not match after a transfer that itself reported success |

Each class maps to a distinct, specific error message (host alias, which
step, what to check) — never a single generic "remote command failed";
Increment 8 is where these get characterisation tests against a fake `ssh`
that scripts each of these exact failure shapes.

## 8. Remote per-profile lock (item 6)

Constrained (per the task's "decisions are not yours" list) to labelled
volumes/containers only — no other remote resource. Docker's atomic
primitive for "create, fail if already present" is container-name
uniqueness (`docker volume create` is idempotent and does *not* fail if the
volume already exists, so it cannot serve as the exclusion primitive;
`docker create --name X` does fail atomically with "Conflict... name ... is
already in use" if `X` exists) — the lock is therefore a **non-running,
labelled container** named `dxe-lock-<profile-id>`:

- **Acquire**: `<docker> create --name dxe-lock-<profile-id> --label
  io.dxe.managed=true --label io.dxe.role=lock --label
  io.dxe.profile=<profile-id> --label io.dxe.owner=<owner-token> <minimal
  image>` — succeeds (lock held) or fails with the name-conflict message
  (lock already held by someone). `<owner-token>` is more than a PID alone
  (`docs/refactor/constraints.md`: "Locks and execution leases identify an
  owner by more than PID alone...") — a `<controller-hostname>:<random
  session id>:<UTC timestamp>` string, generated fresh per acquisition
  attempt and also kept locally so a crashed controller's own stale lock is
  distinguishable from a foreign one on the next audit.
- **Release**: label check (profile *and* owner-token match) then `<docker>
  rm dxe-lock-<profile-id>` — covers the complete state transition (create
  through eventual delete), not just a final file write, per the same
  constraint.
- **Stale-lock audit**: `<docker> container inspect dxe-lock-<profile-id>
  --format '{{json .Config.Labels}}{{.Created}}'` — prints the immutable
  owner metadata and creation time for the operator. Elapsed time alone
  never authorises removal (DQ6, verbatim); an explicit unlock step must
  print that same metadata and require confirmation before it removes the
  lock container.
- **Normal lifecycle**: any state-transition path that cannot prove it holds
  the lock it needs fails closed rather than proceeding.

Where audit/unlock are exposed to an operator is an open question (see
"Flagged for review"); the lock's on-the-wire shape above does not depend on
that answer.

## 9. Identity-scoped local state (item 7)

`dx_runtime_docker_host_identity`'s value (section 3) becomes an extra
segment in the existing local-state key shapes, so two QNAPs (or a QNAP and
the Apple runtime) never collide over the same cache slot:

- `bin/lib/dx-tunnel.sh`'s `dx_tunnel_key` (today `"$1:$DX_CONTAINER_NAME:$2"`,
  i.e. direction:container:port) gains the runtime identity as a fourth
  segment for any tunnel opened against a `docker-ssh` profile — the
  existing Apple-only key shape is unchanged when `DX_RUNTIME=apple` (no
  identity segment needed there; Apple's `host_identity` is the fixed string
  `local`, which would otherwise be indistinguishable across every Apple
  profile — appending it changes nothing observable for Apple since it was
  already implicitly "the one local runtime").
- `bin/lib/dx-mount-plan.sh`'s manifest/identity-directory paths under
  `DX_MOUNT_IDENTITY_DIR` gain the same extra segment.
- `DX_BACKUP_DIR`'s per-profile subdirectory (used by `bin/lib/dx-backup.sh`)
  likewise.

No new resource type is introduced; this is purely a naming/keying change to
existing cache-path builders, all of which already live in `bin/lib/` (in
scope).

## 10. Configuration surface referenced here (Increment 1's job, not this one)

Per DQ3 (recorded here only for cross-reference; Increment 1 implements the
registry entries): `DX_RUNTIME` (`apple` default | `docker-ssh`),
`DX_REMOTE_HOST` (validated OpenSSH alias; required for `docker-ssh`, refused
for `apple`), `DX_GUEST_SYSTEM` (`aarch64-linux` | `x86_64-linux`),
`DX_NIX_STORAGE_MODE` (`apple-image` | `direct-volume`),
`DX_CONTAINER_RESTART_POLICY` (`no` | `unless-stopped`). The example profile
`tests/profiles/qnap-example.env` documents this shape with placeholder
values only.

## Flagged for review

Per the task's "decisions are not yours" list. The three items raised during
design (Increment 0) are resolved below with the coordinating session's
actual decisions; a fourth item was discovered during implementation
(Increment 7) and remains open — it is outside this task's allowed-file
list to fix.

1. **`dx_runtime_image_build` — RESOLVED (decision received before
   Increment 4).** Phase 0's spike found the real NAS refuses `docker build`
   outright for its test account. This document originally proposed a
   local-build-then-`docker load` design as the resolution. The coordinating
   session decided differently: the docker-ssh adapter never builds an image
   at all, remote or local. "Build" is `<docker> pull <ref>` + `<docker> tag
   <ref> <DX_IMAGE>`, where `<ref>` is parsed from the Containerfile's own
   single `FROM <ref>@sha256:...` line (Phase 0 spike's proven steps 2+3).
   The adapter fails closed if the Containerfile contains anything beyond
   exactly one such line. This is simpler than the load/save design (no local
   build step, no stdin-streamed image transfer) and matches how the
   Containerfile is actually used today: a pinned upstream reference, not a
   Dockerfile with local build instructions. Implemented in
   `dx_runtime_docker_image_build`/`dx_runtime_docker_base_image_ref`
   (`bin/lib/dx-runtime-docker.sh`); characterised in
   `tests/test_docker_runtime_adapter.sh` including the empty-FROM-reference
   and multi-token-FROM rejection cases.
2. **`dx_runtime_system_start`'s refusal — RESOLVED, as originally
   recorded.** The coordinating session confirmed this reasoning explicitly:
   restarting Container Station remotely is a service-restart-class action
   that stays out of an unattended adapter's hands; the operator uses the
   NAS's own App Center UI. Implemented as an unconditional refusal in
   `dx_runtime_docker_system_start` with an operator-facing message naming
   that UI.
3. **Where stale-lock audit/unlock (item 6) is exposed to an operator —
   RESOLVED (decision received before Increment 6).** The coordinating
   session authorised a new `bin/dx-lock` entrypoint (added to the task's
   allowed-file list for this reason), with `status` (read-only audit,
   prints the lock's owner/profile/creation-time labels) and `unlock
   [--force]` (prints that same owner metadata, then removes the lock
   container) subcommands. `bin/dx-lock` refuses outright under
   `DX_RUNTIME=apple` (the lock concept has no Apple equivalent). `bin/dx-status`
   separately shows the same audit view read-only, for operators who do not
   otherwise need `dx-lock`. Both go through
   `dx_runtime_docker_lock_audit`/`dx_runtime_docker_lock_release` directly,
   not through the `dx_runtime_<op>` dispatch contract, since locking is not
   one of the Phase 1 contract's operations.
4. **`bin/dx-mount` does not refuse under `DX_RUNTIME=docker-ssh` —
   RESOLVED, Branch 11 / Phase 5 item 7.** DQ8's capability table records
   `bind_mounts: no` for docker-ssh and `dx_runtime_docker_capability` in
   `bin/lib/dx-runtime-docker.sh` already answered this correctly, but
   nothing in `bin/dx-mount` itself queried that capability before this
   phase. `bin/dx-mount` is now (Phase 5's authorised file list includes
   it) guarded with an early `dx_runtime_capability bind_mounts || fail
   ...` before `dx_require_container_cli`, in its create/attach path (the
   destroy/print-plan/audit/migrate branches never create a bind mount).
   Widened further per the coordinating session's decision: `DX_GIT_MOUNT_SOURCE`
   is a plain config field settable directly, independent of `bin/dx-mount`,
   so `dx_runtime_docker_container_create`'s own `--volume` case now
   refuses a `git:` (bind-mount) spec at the adapter level too, closing the
   gap for any caller that reaches the runtime-neutral vocabulary without
   going through `bin/dx-mount` at all. See
   `docs/refactor/remote-aware-ssh.md` section 7.
