# The runtime boundary

Branch 11 / Phase 1 (`qnap-dxe-plan.md` DQ2, "Keep one lifecycle model and
add runtime adapters"): a mechanical extraction of every raw Apple
`container` lifecycle invocation in the host scripts behind a narrow,
runtime-neutral contract, with an Apple adapter that preserves commands,
output, defaults, state, stdin passthrough, and exit status exactly. See
`runtime-boundary-inventory.md` in this directory for the full call-by-call
mapping this extraction implements. Phase 2 (below) adds the second,
remote Docker-over-SSH adapter this contract exists for.

## Why

Before this branch, every lifecycle script called the `container` binary
directly. Adding a second runtime (Phase 2's remote Docker adapter for the
QNAP target) would otherwise mean either forking every entrypoint into
`dx-qnap-*` copies, or scattering `if [ "$DX_RUNTIME" = ... ]` branches
through each one. Neither shares the lifecycle model between targets. This
branch inserts one seam instead: entrypoints call `dx_runtime_<op>`, and
exactly one dispatch function per operation decides which adapter runs.

## Shape

```text
bin/lib/dx-runtime.sh          selection + the runtime-neutral contract
bin/lib/dx-runtime-apple.sh    the Apple implementation of every operation
```

`bin/lib/dx-runtime.sh` defines one `dx_runtime_<op>` function per
operation. Each is a one-line dispatch:

```sh
dx_runtime_exec() { dx_runtime_dispatch_ok && dx_runtime_apple_exec "$@"; }
```

`dx_runtime_dispatch_ok` checks `DX_RUNTIME` (resolved by
`bin/lib/dx-config.sh`'s registry, default `apple`) and rejects anything
else with a clear message — defence in depth on top of the registry's own
rejection during configuration resolution. Because a dispatch function is
a plain function call with no subshell or pipe of its own, stdin and exit
status pass through unchanged from caller to adapter to the real
`container` invocation; this is proven directly (piped, file-redirected,
and argv-verbatim) in `tests/test_sourceable_coverage.sh`.

`bin/lib/dx-runtime-apple.sh` defines one `dx_runtime_apple_<op>` function
per operation. Most are a direct, argument-for-argument passthrough:

```sh
dx_runtime_apple_container_delete() { container delete "$@"; }
```

Two operations keep the primary/fallback structure they already had before
this extraction (an older Apple Container CLI without `--quiet` falls back
to the tabular listing form): `dx_runtime_apple_container_list_names` and
`dx_runtime_apple_image_exists`. Nothing about that logic changed; it moved
here verbatim.

## Contract operations

Preflight / host identity, image (exists/build/list/delete), volume
(exists/create/delete), container (exists/running/list/create/start/stop/
kill/delete), exec (with stdin/user/TTY/captured-output), logs, export, an
ephemeral no-persistent-container run, and capability queries — the
complete list and their exact Apple implementations are in
`bin/lib/dx-runtime.sh`/`dx-runtime-apple.sh` themselves; the historical
call-by-call source mapping is in `runtime-boundary-inventory.md`.

Two additions beyond `qnap-dxe-plan.md` DQ2's literal enumeration:

- **`dx_runtime_run_ephemeral`** — `container run --rm` with no persistent
  container, used by `bin/dx-migrate-persist` to read and copy volume
  contents in isolation. Holds the bounded retry loop for Apple Container's
  own runtime-client-attach race (`no runtime client exists: container is
  stopped`) — that retry is specifically about the Apple CLI's own timing,
  so it lives in the adapter rather than the caller, and any future caller
  of "run" inherits it for free.
- **`dx_runtime_host_identity` / `dx_runtime_capability`** — defined per
  `qnap-dxe-plan.md` DQ2/DQ8. No Apple entrypoint calls either (Apple is
  always local, so identity is a fixed `local` string and nothing branches
  on a capability while Apple is the only runtime; its answers reflect
  what the existing entrypoints already do -- direct named-volume mounts
  and bind mounts: yes; a restart policy flag: no, nothing sets one today;
  host filesystem reclamation: yes, `dx-reclaim`'s sparse-image trimming).
  Phase 2's docker-ssh adapter DOES use both: `host_identity` feeds item
  7's local-state scoping (`docker-ssh:<alias>:<daemon-id>`) and DQ6's
  per-profile lock naming, and `capability` answers differently for three
  of the four questions (see Phase 2's own section below).

## What stayed outside the contract

`bin/dx-reclaim`'s host-side sparse-image size measurement (a direct host
filesystem read, never a `container` call) and all of `bin/dx-nix-disk`
(no `container` reference at all) are Apple-only host mechanics per
`qnap-dxe-plan.md` DQ8 ("Apple sparse-image and fstrim reporting is
unsupported on Docker"); they were never raw `container` calls and needed
no migration.

## Wrapper names preserved

`bin/lib/dx-container.sh`'s existing helper names
(`dx_require_container_cli`, `container_system_is_running`/
`ensure_started`, `dx_container_list_names`, `container_exists`,
`container_is_running`, `container_image_exists`, `container_ensure_volume`,
`container_stop_bounded`) are unchanged for every existing caller and test;
only their bodies now call the contract. `dx_container_list_names` calls
the Apple adapter directly rather than through `dx_runtime.sh`'s dispatch:
it is Apple-CLI-version fallback logic with no Docker equivalent to
dispatch to, not a contract-level operation.

## The audit

`tests/test_runtime_boundary_audit.sh` (Section 32) fails if any file under
`bin/` other than `bin/lib/dx-runtime-apple.sh` invokes a raw Apple
`container` lifecycle verb. `tests/` may still call `container` directly
(a fake `container` on `PATH`, or a live guest in the full tier) — the
audit only scans `bin/`. Its detector requires "container" to be
immediately followed by whitespace and a lifecycle verb, with a documented,
dated exception list for the handful of comments and operator-facing
messages that still match that shape; every exception names why it is
prose, not a call.

## Phase 2: the docker-ssh adapter (landed)

Phase 2 (`feat/qnap-docker-adapter`) adds `bin/lib/dx-runtime-docker.sh`,
implementing every `dx_runtime_<op>` for `DX_RUNTIME=docker-ssh` (the
Phase 1 placeholder name `docker` was retired in favour of this real
value; see `bin/lib/dx-config.sh`'s registry). `dx_runtime_dispatch_ok`
now accepts `apple` and `docker-ssh`; every dispatch function's own body
became one shared `dx_runtime_dispatch` helper (`bin/lib/dx-runtime.sh`)
that computes `dx_runtime_apple_$op` / `dx_runtime_docker_$op` dynamically
rather than a one-liner per adapter per operation — a plain function call
with no subshell or pipe of its own either way, so the stdin/exit-status
passthrough proof from Phase 1 still holds unchanged (proven again, for
both adapters, in `tests/test_docker_runtime_adapter.sh`).

Full design: `docs/refactor/docker-adapter-mapping.md` (the command-by-
command mapping to Docker-over-SSH, DQ1-DQ8). Summary:

- Every remote call is `ssh -o BatchMode=yes ... <alias> <docker-abs-path>
  <verb> ...`, never Docker's own `-H ssh://` transport (confirmed broken
  against the real NAS in Phase 0). Values cross as individually
  `printf %q`-quoted tokens joined into ONE remote command string — ssh's
  exec channel has no real remote argv, so this quoting discipline is what
  stands in for "positional data, never interpolated executable text"
  (DQ1).
- `dx_runtime_container_create` is the one operation with a genuinely
  runtime-neutral PARAMETER vocabulary (not just a runtime-neutral NAME):
  `bin/dx-create-container` speaks only `--name`, `--image`, `--volume
  {nix,persist,bootstrap,git}:...`, `--env`, `--memory`, `--cpus`,
  `--publish`, `--restart-policy`, `--entrypoint-cmd`/`--entrypoint-arg` —
  never a single Apple or Docker flag name — and each adapter renders its
  own real create argv from it (DQ2: "runtime-specific CLI syntax ... lives
  only in the adapter"). This mattered here and nowhere else in the
  contract because two of Apple's real flags are wrong, not merely
  differently named, for docker-ssh's direct-volume mode (DQ4): Apple's
  `--cap-add CAP_SYS_ADMIN` must never reach Docker, and Apple's `-c`
  (CPU count) is Docker's `--cpu-shares`, a different unit entirely. An
  earlier draft translated Apple's own flags inside the Docker adapter
  instead; the coordinating session rejected that design as making
  Apple's CLI syntax the de facto contract, which is exactly what DQ2
  forbids. `dx_runtime_apple_container_create` reproduces today's exact
  `container create` argv byte-for-byte from the same neutral vocabulary
  (proven in `tests/test_runtime_boundary_characterisation.sh`).
  `dx_runtime_run_ephemeral` was NOT made neutral this way -- it stays the
  Apple pass-through it already was; giving it its own neutral vocabulary
  is deferred to whichever of Phase 3/6 first needs it for docker-ssh.
- DQ6 labels (`io.dxe.managed`, `io.dxe.schema`, `io.dxe.profile`,
  `io.dxe.role`) are attached at create time for volumes and containers
  (their role/profile computed from resolved config, never passed by the
  runtime-neutral caller, since only the Docker adapter needs
  `DX_REMOTE_HOST`) and verified before every delete: an existing
  same-named resource with missing or mismatched labels refuses ("a
  collision, not an adoption candidate"). Images are the one exception --
  never labelled, since `image_build` never builds (see below), and
  `docker tag` cannot attach a label.
- `image_build` never issues a remote `docker build`: Phase 0 found the
  real NAS refuses one for its account. The Containerfile is (and must
  stay) a single `FROM <pinned-ref>@sha256:...` line; "build" is
  `docker pull <ref>` + `docker tag <ref> <DX_IMAGE>` (Phase 0 spike's
  proven steps 2+3), with the adapter itself parsing and fail-closing on
  anything beyond that one line.
- `system_start` always refuses for docker-ssh: restarting Container
  Station remotely is a service-restart-class action the standing rules
  keep out of an unattended adapter's hands; the operator uses the NAS's
  own App Center UI.
- A remote per-profile lock (a labelled, never-started container named
  `dxe-lock-<profile-id>` -- Docker's one atomic "create, fail if already
  present" primitive is container-NAME uniqueness, since `docker volume
  create` is idempotent and cannot serve as an exclusion primitive) backs
  a new `bin/dx-lock` entrypoint (`status`, `unlock [--force]`); `bin/dx-status`
  shows the same lock state read-only. Never removed on elapsed time
  alone.
- Local cache keys (`bin/lib/dx-tunnel.sh`'s tunnel state,
  `bin/lib/dx-backup.sh`'s per-container backup directory) gain an extra
  identity segment -- `dx_runtime_host_identity`'s
  `docker-ssh:<alias>:<daemon-id>` -- for docker-ssh only, so two
  profiles that share a container name (two different NASs, or the same
  alias resolving to a different daemon) can never collide. Apple's own
  key/path shapes are byte-for-byte unchanged.
- Distinct diagnostics (`dx_runtime_docker_classify_failure`): a failed
  ssh or docker call is classified into "authentication failure",
  "connection loss", "daemon restart or unreachable", "missing Docker
  access", or a generic-but-never-silent fallback, and the classification
  is quoted alongside the raw remote text rather than a single generic
  message.

No entrypoint, and no name in `bin/lib/dx-container.sh`'s wrapper layer,
needed to change to add the second adapter -- that was the point of the
seam Phase 1 inserted -- except `container_system_ensure_started`'s own
echo, which hardcoded "Apple container system is not running" and needed
a runtime-conditional message once a second runtime existed (Apple's own
wording is kept byte-for-byte identical).

Developed and characterised entirely against fake `ssh`/`docker`
boundaries (`tests/test_docker_runtime_adapter.sh`, Section 33); the real
NAS is production and was never touched by this branch. The only live
step -- a read-only `dx-status` against a disposable QNAP profile -- is
the coordinating session's own, separate step after this branch lands.
