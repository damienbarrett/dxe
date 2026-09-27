# The Docker-over-SSH adapter: contract → command mapping

Branch 11 / Phase 2 (`qnap-dxe-plan.md` "Phase 2 — Add the remote Docker
adapter safely"), Increment 0. This is a design document only — no adapter
code exists yet. It maps every `dx_runtime_<op>` of the Phase 1 contract
(`bin/lib/dx-runtime.sh`, `docs/refactor/runtime-boundary.md`) to the exact
remote command `bin/lib/dx-runtime-docker.sh` will issue for
`DX_RUNTIME=docker-ssh`, the structured-output query it uses, its failure
classes, and which Phase 2 item (1-8, `qnap-dxe-plan.md` "## Phase 2") it
satisfies. Increments 1-9 implement this red→green→refactor, one item group
at a time; nothing here is final adapter code and every command shape is
still subject to the fake-`ssh`/fake-`docker` characterisation tests those
increments write.

Three points below are flagged rather than silently decided (see
"Flagged for review" at the end); everything else follows directly from
`qnap-dxe-plan.md`'s decisions (DQ1-DQ8) and Phase 0's proven findings
(`tests/qnap/lib/phase0-common.sh`, `tests/qnap/phase0-spike.sh`,
`tests/qnap/phase0-inventory.sh`).

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
| `dx_runtime_image_list` | `<docker> image ls --filter label=io.dxe.managed=true --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'` | raw text for human display only (matches the inventory's existing "raw text for human display" scoping of this op; nothing in `bin/` parses its output except `dx-status`'s pre-existing name-anchored `grep`, which this column order preserves) | connection-loss | 3 (display, not a query the adapter itself parses) |
| `dx_runtime_image_build` | **flagged — see "Flagged for review"** | n/a | n/a | 4 |
| `dx_runtime_image_delete` | label check (`image inspect --format '{{json .Config.Labels}}'`) then `<docker> image rm <ref>` | `{{json .Config.Labels}}` | connection-loss, label-mismatch | 4, 5 |

### Volume

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_volume_exists` | `<docker> volume inspect <name>` | exit status; `--format '{{json .}}'` when labels are needed | connection-loss | 3 |
| `dx_runtime_volume_create` | `<docker> volume create --label io.dxe.managed=true --label io.dxe.schema=<v> --label io.dxe.profile=<profile-id> --label io.dxe.role=<nix\|persist\|bootstrap> <name>` | n/a (create) | connection-loss, name-collision (pre-check via inspect first: an existing same-named, differently-labelled volume refuses instead of `volume create`'s own silent idempotent success) | 4, 5 |
| `dx_runtime_volume_delete` | label check then `<docker> volume rm <name>` | `{{json .Labels}}` from `volume inspect` | connection-loss, label-mismatch | 4, 5 |

### Container

| Contract op | cmd | query | fails | item |
| --- | --- | --- | --- | --- |
| `dx_runtime_container_exists` | `<docker> container inspect <name>` | exit status; `--format '{{json .}}'` | connection-loss | 3 |
| `dx_runtime_container_running` | same inspect JSON, `.State.Running` | `.State.Running` from `container inspect --format '{{json .}}'` | connection-loss | 3 |
| `dx_runtime_container_list` | `<docker> ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'` | raw text for human display only (same scoping as `image_list`) | connection-loss | 3 |
| `dx_runtime_container_create` | `<docker> create --name <name> --label io.dxe.managed=true --label io.dxe.schema=<v> --label io.dxe.profile=<profile-id> --label io.dxe.role=container -v <nix-vol>:/nix -v <persist-vol>:/persist -v <bootstrap-vol>:<bootstrap-path> --restart <DX_CONTAINER_RESTART_POLICY> -e DX_PUB_KEY=<key> <image> -c <bootstrap-launch-cmd> -- <bootstrap-path>` (DQ4 direct-volume mode: no `--privileged`, no `--cap-add SYS_ADMIN`) | n/a (create) | connection-loss, name-collision | 4, 5 |
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

Per the task's "decisions are not yours" list, these are recorded rather
than silently resolved:

1. **`dx_runtime_image_build`.** Phase 0's spike found the real NAS refuses
   `docker build` outright for its test account ("QNAP's Docker wrapper
   creates a per-user build directory under Container Station's own data
   area and refuses it there for a non-default administrator" —
   `qnap-dxe-plan.md`'s Phase 0 outcome and `phase0-spike.sh`'s step-3
   comment). Whether that is specific to the spike's disposable account or a
   general Container Station restriction is unknown (the NAS is off-limits
   to me; nothing here can be tested live). Proposed resolution: the
   docker-ssh adapter never attempts a remote build at all — it cross-builds
   the image locally (the existing Apple `container build` path, or a
   future architecture-neutral equivalent once Phase 4 lands) and imports it
   with `<docker-local-save> | ssh ... <docker> load`, a purely
   stdin-streamed operation (same shape as any other bulk-stdin transfer in
   this document, section 6's unidirectional-write case) that never touches
   a remote build-context directory. This still satisfies DQ1's "without
   copying the repository to QTS" (only the built image crosses, not the
   source tree) but is a real design fork the task text does not spell out
   explicitly, so it is flagged rather than assumed. **Needs confirmation
   before Increment 4 implements it.**
2. **`dx_runtime_system_start`'s refusal.** Recorded as settled, not
   flagged: the standing brief's "any reboot or service restart... needs the
   user's explicit approval each time" already decides this — the adapter
   must not restart Container Station itself. Included here only so the
   reviewer can confirm the reasoning, not because it is genuinely open.
3. **Where stale-lock audit/unlock (item 6) is exposed to an operator.**
   `bin/dx-status` is the one `bin/` entrypoint this task may touch, and it
   is read-only display; audit fits there (a display-only addition), but
   explicit unlock is a mutation and DQ6 requires it to print owner metadata
   and ask for confirmation before removing anything — that shape does not
   obviously fit a read-only status command, and no other new `bin/`
   entrypoint is in the task's allowed-file list. **Needs a decision before
   Increment 6**: extend `dx-status` for audit-only and expose unlock as a
   library function callable only from tests/a future entrypoint (deferring
   the operator-facing unlock command itself to a later, explicitly
   reviewed change), or something else the coordinating session prefers.
