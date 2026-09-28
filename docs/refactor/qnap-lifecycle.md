# QNAP lifecycle, reboot, and operational hardening (Branch 11 / Phase 6, `feat/qnap-lifecycle`) — design

Increment 0 design note, written before any code changes exist (the same
discipline `docker-adapter-mapping.md`, `direct-volume-storage.md`, and
`store-trust-design.md` used for their own Increment 0 notes). Implements
`qnap-dxe-plan.md`'s `## Phase 6` items 1-9 and its exit gate. Nothing here
proposes a change outside `bin/`, `bin/lib/`, `tests/`, `docs/`, the example
profile, and the two plan files (`qnap-dxe-plan.md`,
`checkout-consolidation-plan.md`) — no `.nix` change, no change to Apple's
own behaviour beyond the shared health layers in `dx-status` (section C).

This document does not repeat what is already recorded elsewhere; it cites
`docs/lifecycle.md`, `docs/refactor/docker-adapter-mapping.md`,
`docs/refactor/direct-volume-storage.md`, `docs/refactor/store-trust-design.md`,
`docs/refactor/remote-aware-ssh.md`, `docs/refactor/decisions/D7-start-generation.md`,
and the evidence records under `docs/evidence/20260927/` and
`docs/evidence/20260928/` by name rather than re-deriving their content.

## 0. Settled inputs (not decided here)

- **DQ3** (`qnap-dxe-plan.md`): `DX_CONTAINER_RESTART_POLICY` default `no`
  everywhere; `unless-stopped` only after the reboot behaviour passes the
  live gate. Already a validated config field
  (`bin/lib/dx-config.sh:28,114`), passed by `bin/dx-create-container:91`
  as `--restart-policy`, rendered by the Docker adapter as `--restart
  <value>` (`bin/lib/dx-runtime-docker.sh:490`); Apple ignores it
  (`dx_runtime_capability restart_policy` is `no` for Apple, `yes` for
  docker-ssh — `docs/refactor/docker-adapter-mapping.md` section 4). Item 3
  is the decision and proof, not new plumbing.
- **DQ5**: guest SSH publishes on the NAS's Tailscale address only, never
  loopback, LAN, or `0.0.0.0`; discovered at run time, never persisted to a
  tracked file. Governs every alternative in section B.
- **DQ6**: `io.dxe.managed=true`, `io.dxe.schema`, `io.dxe.profile`,
  `io.dxe.role` on every Docker image/volume/container/lock object;
  `io.dxe.system` (Phase 4) on containers, volumes, and the per-profile lock
  container. An unlabelled or differently-labelled same-named object is a
  collision, never an adoption candidate. Already enforced per-resource at
  the adapter level for containers and volumes
  (`bin/lib/dx-runtime-docker.sh`'s `dx_runtime_docker_verify_labels`,
  `dx_runtime_docker_container_delete`, `dx_runtime_docker_volume_delete`);
  section E extends this to a whole-operation plan.
- **DQ8**: factory reset and volume destruction are "implemented only after
  isolated destructive tests and ownership labels pass" — this phase's
  section E and Increment 3.
- **Invariants** (`qnap-dxe-plan.md` "## Invariants"): the only published
  QNAP port is guest SSH on the Tailscale address; remote destructive
  actions require exact runtime/host/profile/name/label agreement; `/nix`,
  `/persist`, and bootstrap state survive image/container replacement; a
  QNAP or Container Station reboot does not require an interactive
  controller session to preserve state.
- **Phase 0 item 8 / 8b/8c**: container restart, Container Station restart,
  and (in an agreed maintenance window) a NAS reboot, verifying volumes and
  tailnet-only publication persist. 8b (Container Station restart) and 8c
  (NAS reboot) are still open; today's maintenance window (below) closes
  them. Recording their outcome in the plan is the coordinating session's
  step, not designed here (user decision 5).
- **User decisions (2026-09-28)**: Phase 6 proceeds now; the coordinating
  session runs today's maintenance window (~16:00 NZDT) against disposable
  `dx-qnap-spike` with `DX_CONTAINER_RESTART_POLICY=unless-stopped` in its
  local profile only, observing a container restart, a Container Station
  restart, and a NAS reboot; items 3 and 9 are designed here as alternatives
  and finalised only after those observations arrive; the slow `dx-test`
  restart (cold stop 23s into a boot, ~10 min to become SSH-ready, guest
  healthy afterward) is investigated inside item 5 (section "Interrupted
  boot investigation plan" below); guest size stays 8 GB / 4 CPU.
- **Facts not to rediscover**: Docker injects `HOME` into the management SSH
  session (affects nothing designed here, noted for completeness); fakes
  cannot see Go templates (`docker ... --format '{{...}}'` output must be
  characterised against a real remote or accepted as untested by the fake,
  per existing adapter test comments); `keyring: stale` after any container
  restart is the documented state until `dx-keyring start` runs again
  (`docs/evidence/20260928/remote-aware-ssh.md`, `bin/dx-status:135`) — not
  a defect health reporting needs to "fix," only to report accurately;
  Apple's `container exec -it` needs a real tty and fails under
  `stdin from /dev/null` (`docs/evidence/20260928/remote-aware-ssh.md`) —
  pre-existing, unrelated to this phase.

## A. Restart policy (item 3) — stays opt-in

Default `no` everywhere (unchanged). `tests/profiles/qnap-example.env`
already documents `unless-stopped` as the value to set *after* the operator
has observed reboot behaviour on their own NAS (its existing comment says
exactly this); nothing in the example file needs to change for the default
value, only its surrounding prose gains a pointer to the runbook (section F,
Increment 5).

**What an unattended start (`unless-stopped`, no controller present at
all — no `dx-start-container`, no `dx-sync-bootstrap`) must guarantee:**

1. **The existing-current-generation bootstrap path completes with no
   controller present.** The mechanism already exists
   (`docs/refactor/decisions/D7-start-generation.md`, "Candidate mechanisms"
   §1): the guest's own launcher (`dx_bootstrap_launch_command`,
   `bin/lib/dx-ssh-common.sh`) removes `.dx-bootstrap-ready` on every boot,
   waits up to `DX_BOOTSTRAP_PUBLISH_GRACE` (default 30s) for a host
   publisher that will never arrive, then falls back to booting `current`
   with a stderr warning — this is precisely requirement 2 from
   `dx-start-plan.md`'s six requirements ("a start with no host sync ...
   must not hang waiting for a publisher that will never arrive"). This
   exact no-publisher path is live-verified, but only on Apple and only via
   `container stop`/`container start` (not a Docker restart policy):
   `docs/evidence/20260926/start-generation-red.md`, "Requirement 2
   (no-publisher start must still work, bounded)" — with generation `7438`
   already current, `container stop dx-test` then `container start dx-test`
   directly, the guest logged `Warning: no publication signal after 30s;
   using the generation already current.` and reached SSH normally. That
   record explicitly calls this "the manual-start / reboot / 'runtime
   restarts the container' case," i.e. it stands in for exactly what an
   unattended `unless-stopped` restart does (no `dx-start-container`
   involved), but the trial itself ran under Apple's `container` binary,
   not Docker's restart-policy supervisor. `dx-start-container`'s own
   confirm-timeout check (`DX_BOOTSTRAP_CONFIRM_TIMEOUT`, D7 option 3) never
   runs on this path either way, because nothing calls
   `dx-start-container`. Item 3 therefore needs no new mechanism — the
   guest-side code is identical on both runtimes — but item 3's own live
   gate (the coordinating session's, not this subagent's) still needs to
   confirm this specific evidence, gathered on Apple, reproduces under
   Docker's restart supervision on the actual NAS; this design note does not
   claim that half is already proven.
2. **The port binds the Tailscale address.** Already true structurally
   (`dx_runtime_guest_ssh_address` + the adapter's address-prefixed
   `--publish`, Phase 5). What is *not* yet proven is whether it binds
   correctly on the very first restart attempt when `tailscale0` has no
   address yet — that is item 9, section B.
3. **SSH becomes ready**, observable the same way any boot's readiness is
   observed today (`dx-wait-ssh`, `dx-status`'s SSH section) — no new
   contract needed, only the health-layer work in section C so a long wait
   here reads as expected progress rather than a hang.
4. **Any failure is visible in `dx-status`** without requiring the operator
   to have been watching a controller session at all: `docker ps`/Container
   Station show the container's own state (restarting, exited, healthy —
   section D), and a later `dx-status` invocation (which itself needs no
   prior controller session — it just SSHs to the NAS and queries Docker)
   reports the last known bootstrap generation and SSH reachability exactly
   as it does today for any other guest.

**Guardrail for the runbook (section F):** `unless-stopped` should not be
set before the guest has completed at least one full, successful bootstrap
and `dx-status` shows a healthy generation — an unattended restart's "no
controller, fall back to `current`" path has nothing to fall back to on a
guest that has never finished bootstrapping once. This is a documentation
point, not a code gate: `dx-create-container`/`dx-status` already exist and
nothing prevents setting the field early, but the runbook must say so
explicitly, per DQ3's own "after the reboot behaviour passes the live gate"
wording.

## B. Restart ordering (item 9) — alternatives, decided after observations

`qnap-dxe-plan.md` item 9's requirement: since guest SSH publishes to the
NAS's Tailscale address (DQ5), the container must start only after
`tailscale0` already has an address — on NAS boot, after a Container Station
restart, and after a Tailscale service restart alike — rather than
publishing a port that silently binds nothing reachable.

| # | Alternative | NAS boot | Container Station restart | Tailscale service restart | DQ5 risk |
| --- | --- | --- | --- | --- | --- |
| (a) | Rely on Docker's own restart-policy backoff to retry a failed port bind until `tailscale0` has an address | Depends on whether Docker's restart-policy backoff re-attempts the *port bind*, not just the process, after a bind failure at container start — **unverified, see observations below** | Same mechanism, shorter window (Tailscale is usually already up unless the restart also bounces `tailscaled`) | Same mechanism | None if Docker's own retry never falls back to `0.0.0.0`/all-interfaces on retry (it won't — the bind spec is fixed at container-create time); the risk is purely "never becomes reachable," not "reachable on the wrong interface" |
| (b) | A NAS-side start hook (QTS autorun, or a Container Station "application") that starts the guest only after Tailscale reports an address | Guarantees ordering by construction | Only helps if Container Station restart re-triggers the hook, which a plain container restart-policy does not | Only helps if the hook is wired to the Tailscale service's own restart, not just boot | Lowest technical risk to DQ5, but is NAS-side automation outside Container Station's own restart-policy field — **an autorun hook is a design option to describe here, not to implement without the user's explicit word** (SUBAGENT-BRIEF "Decisions are not yours"; task's own "Decisions are not yours" list names this exact case) |
| (c) | A guest- or adapter-side wait that fails fast with a clear diagnostic and leaves the retry to the operator/`dx-start-container` | Guest already waits (30s grace, section A) but that wait is for a *publisher*, not for the *network*; a bind failure at container-create/start time is a different failure mode this alternative would need to detect and report, not silently retry | Same | Same | Safest for DQ5 (no automatic fallback path that could widen the bind), but does not satisfy item 9's "the container must start only after ... alike" wording on its own unless paired with (a) actually working, since this alternative's whole point is failing loudly rather than recovering unattended |

**Why the port-bind failure mode matters (unresolved without the live
observations):** `docker create ... -p <tailscale-ip>:2222:2222` requires
Docker to resolve `<tailscale-ip>` to a *routable local address* at bind
time. If `tailscale0` has no address yet, the most likely Docker behaviour
is that the initial `docker start` (or the daemon's own restart-policy
retry) fails outright with an address-not-available error, and whether the
restart-policy's own backoff (`no`/`unless-stopped` only takes an interval,
no dedicated "retry until bindable" semantics) re-attempts that specific
failure the same way it retries a crashed process is not established by
anything already read from Phase 0/2/3/5 — hence the observation list.

**Exact observations the maintenance window must produce (for the
coordinating session to collect against `dx-qnap-spike`,
`DX_CONTAINER_RESTART_POLICY=unless-stopped`):**

1. **Container restart** (`docker restart dx-qnap-spike`, or the OS-level
   equivalent of a crash): does the container return to `Running` with
   `2222/tcp` bound to the Tailscale address (unchanged, since Tailscale
   never went down here)? Baseline case — expected to work regardless of
   which alternative wins.
2. **Container Station restart** (`/etc/init.d/container-station.sh
   restart`): (a) does the container come back on its own without a manual
   `docker start`? (b) is the restart-policy flag (`unless-stopped`)
   preserved, or does Container Station recreate the container from its own
   stored definition (which could silently drop or alter it)? (c) is
   `tailscale0`'s address still present throughout (Container Station
   restarting should not touch Tailscale) — if so, this case tells us
   nothing about the race, only about Container Station's own restart
   fidelity; note it separately from case 3.
3. **NAS reboot**: (a) wall-clock time from power-on to: Docker daemon
   accepting connections; `tailscale0` showing a CGNAT address
   (`tailscale status` or `ip -4 addr show tailscale0`, polled/logged
   continuously from a device that is not the NAS itself, since the NAS's
   own logging is unavailable until it finishes booting); container
   `Running`; port `2222` actually bound to the Tailscale address (not
   `0.0.0.0`, not absent); SSH answering. (b) During the window between
   "Docker up" and "`tailscale0` addressed," does the container attempt to
   start at all, and if so does that attempt fail visibly (`docker ps`
   shows `Restarting`/`Exited` with a reason) or silently bind nothing? (c)
   Once `tailscale0` gets its address, does the *same* container instance
   recover on its own (restart-policy backoff succeeding on a later retry),
   or does it stay failed until a manual `docker start`? (d) At any point
   during the retry window, does `docker port dx-qnap-spike` or Container
   Station's UI show the port bound to `0.0.0.0` or absent-with-a-different-
   binding (a transient DQ5 violation would matter even if short-lived)?
4. **Existing-current-generation bootstrap path**: on the NAS-reboot case,
   does the guest's own launcher (section A) complete its 30s-grace
   fallback and boot `current` correctly with no controller present, the
   same behaviour `docs/evidence/20260926/start-generation-red.md` recorded
   for Apple's `container stop`/`container start`? Confirms section A's
   guarantee 1 under Docker's restart supervision and under a full NAS
   reboot, neither of which that evidence record covers.
5. **Timing budget**: do any of these windows exceed `DX_SSH_WAIT_TIMEOUT`'s
   existing default, and if a real operator's `dx-wait-ssh`/`dx-status`
   would time out or read as "down" during a NAS reboot that is actually
   still in progress — feeds section C's health-layer design directly.

**Decision rule (for the coordinating session once observations arrive):**
if (a) alone reaches a Tailscale-bound, reachable port on every one of the
three restart kinds within a reasonable multiple of `DX_SSH_WAIT_TIMEOUT`,
prefer (a) — zero new moving parts, nothing beyond Container Station. If
Docker's retry never re-attempts a failed bind (observation 3b/3c answers
this), (b) is the next candidate but needs the user's explicit go before any
NAS-side hook is written, per the brief's "Decisions are not yours" and this
task's own list. (c) is the fallback that requires no NAS-side automation at
all but, on its own, does not satisfy item 9's "must start only after ...
alike" wording — it would need to be paired with (a) or (b) rather than
replace them. This document does not pick a winner; Increment 4 documents
whichever the observations settle, or says the observations have not
arrived and does Increment 5 first (per the task's own instruction).

## C. Health reporting (item 5) — layered, runtime-neutral where possible

| Layer | Source | Apple | docker-ssh |
| --- | --- | --- | --- |
| Docker health | `docker inspect --format '{{.State.Health.Status}}'` (if a `HEALTHCHECK` is set — see below) | n/a (no Docker) | yes, once a healthcheck is added |
| Bootstrap progress | Guest's `Bootstrap phase: <name> completed/failed in <N>s` lines, already emitted by every phase (`container/.../bootstrap/{common,base-and-storage,activation,persistence}.sh`) to stdout, which is the container's own PID 1 output (bootstrap.sh execs into `sshd -D -e -p 2222` only at the very end, so everything before that is on the same stream `docker logs`/`container logs` already read) | yes (existing) | yes (existing) |
| SSH readiness | `dx-wait-ssh`'s probe / `dx-status`'s SSH section, via `dx_runtime_guest_ssh_address` | yes (existing) | yes (existing) |
| Nix / Home Manager activation | The same `Bootstrap phase: ...` markers (activation.sh) plus the execution-lease generation `dx-status` already reads | yes (existing) | yes (existing) |
| Optional-tool state | `scripts/dx-verify-inventory` (Phase 4) — present/missing for the CLI inventory, run as `dx` with a login shell | yes (existing, callable) | yes (existing, callable) |

**What's actually new in Increment 1:**

1. **`dx-status`'s "Bootstrap Generation" section currently only
   distinguishes "container running" vs "container not running/not
   found"** (`bin/dx-status`, the `container_is_running` branch). It has no
   third state for "container running, but sshd has not started yet" (the
   entire unattended-restart window, and the ~10-minute `dx-test` case).
   `dx_runtime_exec` works whether or not sshd has started (it goes through
   the container runtime, not through the guest's own network stack), so a
   new check can safely run `dx_runtime_exec` for a lightweight phase-marker
   read even before SSH is reachable. Design: when the container is running
   but `dx_runtime_guest_ssh_address`/the SSH probe is not yet OPEN, read
   the last `Bootstrap phase: ...` line (from `dx_runtime_logs`, matching
   `dx-status`'s existing dead-guest fallback which already does exactly
   this against `container logs`) and print it as `Bootstrap: still running
   phase "<name>" (started <N>s ago)` instead of nothing. This directly
   answers the interrupted-boot investigation's requirement below: "health
   reporting must make that state visible instead of looking like a hang."
2. **`dx-wait-ssh`'s existing 30s progress tick already tails 5 log lines**
   (`print_container_logs 5`, `bin/dx-wait-ssh`). Extend it to grep the tail
   for the latest `Bootstrap phase: ...` line specifically and lead with
   it (e.g. `Bootstrap still running (420s elapsed): last phase "Nix
   ownership check/migration"`), rather than relying on the operator to spot
   it inside five raw lines that might be dominated by other output. No
   change to the timeout/diagnosis logic already there (banner-exchange vs
   refused-connection, `docs/refactor/decisions/` unrelated to this).
3. **A `HEALTHCHECK`-shaped signal** is proposed for D below; if it earns
   its place, `dx-status`'s Docker health line for docker-ssh reads it via a
   plain `docker inspect` query, same shape as every other adapter query
   (`docs/refactor/docker-adapter-mapping.md` section 1).

### Interrupted-boot investigation: appendix (resolved, Increment 1)

Observed fact (user decision 3): on `dx-test`, a cold stop 23s into a boot,
followed by a start, took ~10 minutes to become SSH-ready (vs. ~20s for a
normal cold start — `docs/evidence/20260928/remote-aware-ssh.md`'s Apple
live-gate table); guest healthy afterward. This section originally proposed
an O(store-size) bootstrap-phase hypothesis (an interrupted volume-prepare
or essentials-repair pass walking a real, populated store) and a Section
3-style fixture to characterise it. **That hypothesis is withdrawn** — the
coordinating session is off-limits to subagents for any live run against
`dx-test` (no live-gate access for subagents, without exception; the
original text above wrongly assumed one), so the coordinating session
gathered the evidence directly instead, and it rules the hypothesis out.

**Evidence 1 — the captured log.** The coordinating session captured
`dx-test`'s container log from the actual interrupted-boot trial
(`/Users/damien/dxe-recovery/progress/logs/dx-test-interrupted-boot-2026-09-28.log`,
outside the repository). Every `Bootstrap phase: ... completed in Ns` line
in it reads **0s or 1s** ("essentials installation completed in 0s", "Nix
volume prepare/mount completed in 0s", "Nix ownership check/migration
completed in 0s", "Home Manager activation completed in 1s", ...), and
`sshd` reaches `Server listening on 0.0.0.0 port 2222.` within about two
seconds of the restart. No phase is slow. The remaining ~115 lines are
`Connection closed by authenticating user dx ... [preauth]` entries — sshd
observing the *client* (the readiness probe) disconnect during
authentication, repeated roughly every 5s (`DX_SSH_POLL_INTERVAL`'s
default) for the rest of the window, until whatever finally let one
succeed.

**Evidence 2 — two live reproduction attempts, neither reproduced it.** The
coordinating session ran the trial's exact sequence twice more on
`dx-test` (start; two failing no-tty `dx-enter` attempts; `dx-status`; stop
at 23s; a 45s gap; start again). Both came back fast: `dx-start-container`
in ~2s, `dx-wait-ssh` in 18-20s, the port open at +3s, both a raw `ssh` and
a login-shell `ssh` succeeding at +22s. Together with Evidence 1, this rules
out both the guest's boot sequence and the interruption itself as the
cause — the mechanism is not reproducible from the guest side at all.

**Conclusion — controller-side contention, not a guest-side mechanism.**
What differed on the original occasion: the controller was simultaneously
running the kcov coverage container, a throwaway Ubuntu container executing
the whole test suite, and the native macOS suite. The likeliest cause is
host contention starving either the `dx-test` VM or the readiness probe
itself — exactly the failure mode `dx-wait-ssh`'s own `print_probe_diagnosis`
already names (TCP answered, banner exchange or authentication not
finished within budget) — and the gate script that hit the real trial
discarded `dx-wait-ssh`'s own output, which is why the diagnosis was lost
in the moment rather than shown live. Treat the cause as **"unexplained;
controller-side contention suspected,"** not as a bootstrap phase, and nothing
here proposes changing bootstrap's behaviour (`## G. Not in this phase`
already excludes that; this finding does not reopen it).

**What changed in the design because of this finding (both approved,
implemented in Increment 1, no new `dx_runtime_*` contract op):**

1. `dx-wait-ssh`'s 30s progress tick now also prints the last bootstrap-
   progress marker (the same `Bootstrap phase: ...`/`Using bootstrap
   generation ...`/`Waiting for bootstrap payload ...` grep the dead-guest
   branch already uses) and the **last probe error** — `PROBE_STDERR`'s own
   content, which the script already captures every attempt but previously
   surfaced only at final timeout — so an operator watching a slow wait
   sees "connection refused" vs. "banner exchange timeout" vs. an
   authentication-phase close during the wait itself, not only after the
   full budget elapses.
2. `dx-status`'s third state now distinguishes two cases via the *existing*
   SSH section, both through sources that already exist: **(a)** container
   running, port not open yet — shows the last bootstrap-progress marker
   from `dx_runtime_logs`, exactly as originally designed; **(b)** port
   *open* but the login-shell probe itself fails — a new one-shot probe (the
   same shared `dx_ssh_common_options` builder `dx-wait-ssh` uses, not a
   new contract operation) prints its own stderr. Case (b) is what the real
   incident actually was: `dx-status` would have reported the port OPEN
   throughout, which is exactly the ambiguity the coordinator's trial hit
   (`dx-status` said OPEN "right afterwards" while the wait had already
   failed for ten minutes).
3. The runbook (Increment 5) documents that a slow-but-healthy restart under
   host load is expected and names the diagnosis text above as the first
   thing to read; the remedy is patience or freeing up the controller, never
   a guest rebuild.

No fixture characterises a "mechanism" here because there no longer is a
guest-side mechanism to characterise — the two reproduction attempts and
the phase-by-phase log both point at the controller, not the guest, and
Increment 1's tests instead prove the two new `dx-status`/`dx-wait-ssh`
observability paths directly against fakes (see "Test list" below).

## D. Container Station display (item 4)

Names and labels already exist and are already exercised by fakes (Section
33, `tests/test_docker_runtime_adapter.sh`'s `docker ps --format` label
assertions). What Container Station's UI actually renders from the Docker
API — names, labels, published ports, `docker logs` — is therefore already
correct by construction; item 4's remaining decision is whether a Docker
`HEALTHCHECK` earns its place.

**Proposal:** one new, pre-authorised neutral create-time flag through the
existing contract (the task's own "one neutral create-time health flag is
pre-authorised, nothing else"): `dx_runtime_container_create` gains an
optional health-check parameter set (command, interval, retries — the
smallest shape Docker's `--health-cmd`/`--health-interval`/`--health-retries`
need) that the Docker adapter renders as those three flags and Apple's
adapter ignores entirely (`dx_runtime_capability container_healthcheck`:
`no` for Apple, `yes` for docker-ssh, following the exact pattern
`restart_policy` already uses). The probe command itself must not depend on
SSH being up (defeats the point for the interrupted-boot window) — a
`test`-based check against a marker file bootstrap already writes (the
execution-lease/`current` symlink machinery) is the natural candidate,
reachable via `docker exec` the same way `dx_runtime_exec` always is.
Verified with fakes only (`docker inspect --format '{{json
.Config.Healthcheck}}'` on a fake, asserting the rendered argv); no live
Container Station screenshot is this subagent's to take.

`docker logs` already shows the full bootstrap phase sequence followed by
`sshd`'s own foreground output, confirmed by bootstrap.sh's structure
(`exec sshd -D -e -p 2222` as the last step of `bootstrap_main`, so nothing
after that point is a separate process whose output could go missing) — no
change needed there, only a fake-backed test asserting it (Increment 2).

## E. QNAP destructive operations (item 7)

**What already exists:** `dx_runtime_docker_container_delete` and
`dx_runtime_docker_volume_delete` already verify DQ6 labels per resource
before deleting it (`bin/lib/dx-runtime-docker.sh`'s
`dx_runtime_docker_verify_labels`, tested in
`tests/test_docker_runtime_adapter.sh` around lines 1051-1207: label match
passthrough, refusal on unlabelled, refusal on a different profile, refusal
on an unrecognised volume name). Images have no labels at all (Docker's
`tag` cannot attach one — documented in the adapter's own comment) so image
deletion's only protection is exact-name addressing, unchanged.

**The gap:** `bin/dx-factory-reset` and `bin/dx-destroy-volumes` call the
per-resource-checked delete operations *in sequence*, with no upfront,
whole-operation plan or verification. A factory reset today could delete
the container successfully, then refuse partway through the three volumes —
a partial destroy, and the operator's typed confirmation was for a
description that never named per-resource label state at all. Item 7 asks
for "an immutable plan first" and a refusal "if any listed resource lacks
the labels," which reads as an all-or-nothing property this sequence does
not currently have.

**Design:** a shared helper (`bin/lib/dx-container.sh`, alongside the
existing lifecycle helpers), e.g. `dx_destructive_plan_and_verify`, used by
both `dx-factory-reset` and `dx-destroy-volumes`:

1. Resolve the exact configured name for every resource the caller is about
   to target (container, image, the three volumes for factory-reset; just
   the existing volumes for `dx-destroy-volumes`).
2. **`docker-ssh` only** (Apple has no labels to check, and the invariant
   here is "byte-identical Apple behaviour" — this step is skipped entirely
   under `DX_RUNTIME=apple`, not merely printing the same thing): for each
   resource that exists, read its labels through the adapter's existing
   `dx_runtime_docker_container_labels`/`dx_runtime_docker_volume_labels`
   query functions (already there; no new query shape) and print the
   immutable plan — kind, exact name, and label state (`managed`, `schema`,
   `profile`, `role`) — **before any deletion call is issued**.
3. If any existing resource's labels do not match this profile
   (unlabelled, wrong profile, wrong role — the same three collision cases
   the per-resource check already distinguishes), refuse the **whole**
   operation with a message naming every failing resource, and issue **zero**
   delete calls. This is the "immutable plan first, refuse before mutating"
   property; the per-resource checks inside the adapter remain as
   defence-in-depth, not the only line of defence.
4. Only after every existing resource passes does the existing sequence run
   (unchanged: `dx-destroy-container` → `dx-destroy-image` →
   `dx-destroy-volumes --force` → `dx-destroy-keys` for factory-reset).
5. The existing typed confirmation (`Type "factory-reset"/"destroy" to
   confirm`) is reused exactly as-is and runs *after* the plan is printed,
   so what the operator confirms is the accurate, verified plan — not a
   generic resource-name list as today.

**Apple behaviour:** byte-identical. The plan-and-verify step is a no-op
under `DX_RUNTIME=apple` (nothing to check, nothing new printed), proven by
existing characterisation tests continuing to pass unmodified plus one new
assertion that Apple's `dx-factory-reset --force` output/argv sequence is
unchanged from before this increment.

**Destructive-tier fakes (Increment 3):** `tests/standalone_test_factory_reset.sh`
is Apple/raw-`container`-only today (it literally creates and destroys a
live environment) and cannot exercise `docker-ssh` at all without a real
remote Docker daemon, which is off-limits to this subagent and not what the
disposable-guest live tier is for either. New coverage is fake-only, added
to the ordinary container-free suite (not `tests/run-tier.sh destructive`,
which stays the live-only tier): a new test group (extending
`tests/test_docker_runtime_adapter.sh`'s Section 33, or a new adjacent
Section) proving, against `fake_qnap_ssh_write` + a fake `docker`:

- The plan prints every target's exact name and label state before any
  delete call.
- **Zero delete calls are issued** when any one resource is mislabelled,
  even when every other resource is fine (the all-or-nothing property) —
  asserted by a call-count/log on the fake, not by output text alone.
- Succeeds end-to-end (all delete calls issued, in the existing order) when
  every resource matches.
- A resource that does not exist at all is skipped in the plan (nothing to
  verify or delete), distinct from one that exists but is mislabelled —
  mirrors the existing "nonexistent target is distinct from a mislabelled
  one" case already tested at the adapter level.
- Apple's argv/output sequence is unchanged (a characterisation diff against
  the pre-increment behaviour).

`tests/run-tier.sh`'s destructive tier already refuses default container
resources (`DX_CONTAINER_NAME=dx-host`); it is unaffected by this design
since the new fake tests live in the container-free suite, and the live
destructive tier against a disposable QNAP guest remains the coordinating
session's own step, unchanged.

## F. Documentation (items 1, 2, 6, 8)

**Runbook (`docs/qnap-runbook.md`, item 1)**, referencing
`tests/profiles/qnap-example.env` throughout and never a real hostname/user/
address (Section 1's secrets scan and the pre-push scan enforce this):

- **Install**: copy `qnap-example.env`, rename it, set `DX_REMOTE_HOST` to a
  real `~/.ssh/config` alias, confirm it connects non-interactively (the
  example file's own existing guidance), generate the profile's own SSH
  keypair (`dx-create-keys` under the profile — never reuse `dx_key`/
  `dx-test_key`).
- **Preflight**: `uname -m` matches `DX_GUEST_SYSTEM` (DQ7, already
  adapter-enforced); Docker reachable over the management SSH alias;
  `tailscale0` has an address (item 9's precondition).
- **Normal operation**: `./bin/dx-profile <name> ./bin/dx` /
  `dx-status` / `dx-ssh` / `dx-forward`/`dx-reverse` — pointing at
  `docs/lifecycle.md` rather than re-describing the layer model.
- **Update**: the documented-backup-first procedure (item 6, below).
- **Backup / Restore**: `dx-backup`/`dx-restore` already isolate profiles by
  `DX_CONTAINER_NAME` (`docs/lifecycle.md` "Backing up and restoring
  /persist" — `dx-host`/`dx-test`/a QNAP profile can never share a mirror by
  accident); the runbook states the QNAP-specific case (no restore-from-
  another-guest migration path — a QNAP guest starts from scratch,
  `direct-volume-storage.md`).
- **Removal**: `dx-factory-reset` / `dx-destroy-volumes` with the new
  ownership-proof plan (section E), emphasising by construction it can never
  touch Apple resources, another QNAP profile, or an unrelated Container
  Station resource.

**CPU/memory defaults (item 2):** restate the already-made decision (8 GB /
4 CPU, Phase 4, user decision 4 — unchanged by this phase) and its
interaction with NAS workloads in repo-safe generic terms only ("size to
leave headroom for the NAS's existing services and other Container Station
workloads; see the private target note for this NAS's actual measured
headroom" — per the brief's rule that full inventory/spike reports live
outside the repo, `/Users/damien/dxe-recovery/qnap/`, not inside it).

**Update-survival procedure (item 6):** document backup-first
(`dx-backup`), then the QTS/Container Station update itself is the
coordinating session's own step against the real NAS, never performed
solely for this test (`qnap-dxe-plan.md` Phase 6 item 6's own wording) —
this subagent documents the procedure and its ordering, not a stubbed test
of an update that cannot happen against fakes meaningfully.

**Emergency access when Tailscale is down (item 8):** LAN SSH to the NAS
itself as the human operator (QNAP's own admin SSH access — distinct from,
and never a substitute for, DXE's guest SSH, which stays tailnet-only by
DQ5's invariant: "nothing is published on the LAN or public addresses, and
any further exposure needs a separate, explicit feature with its own access
control"), then `docker exec`/`docker logs` into the guest from the NAS's
own local Docker CLI, entirely bypassing the Tailscale-dependent guest-SSH
transport. Explicitly documents what this is *not*: no permanent public
ingress, no fallback LAN publish of the guest's own SSH port (the exact
escape DQ5 forbids).

`docs/lifecycle.md` gains a short QNAP-specific note under principle 9
("Runtime-neutral entrypoints") pointing at the runbook, plus whatever
restart-policy guardrail text section A settles, rather than duplicating the
runbook's content.

`checkout-consolidation-plan.md`'s Branch 11 row/section is updated to
record Phase 6 landed, in Increment 5, alongside `qnap-dxe-plan.md`'s own
Phase 6 status and Phase 0's 8b/8c outcome (recorded only once the
coordinating session reports it — user decision 5).

## G. Not in this phase

Phase 7 (promotion, real profile); item 9's Tailscale-in-guest spike (Phase
5 item 9, still deferred); any `.nix` change; any change to Apple behaviour
beyond the shared health layers in `dx-status`.

## Test list by increment

- **Increment 1** (health layers): `dx-status`'s two third-state cases
  (container running + port not yet open, shown via the last bootstrap-
  progress marker; port open + login-shell probe failing, shown via the
  probe's own stderr) for both runtimes via fakes (`tests/test_section9_host_scripts.sh`,
  a new fake `nc`/`ssh` on the Apple and docker-ssh fixtures respectively);
  `dx-wait-ssh`'s progress tick naming the last bootstrap-progress marker
  and the last probe error. No interrupted-boot fixture: the appendix above
  found no guest-side mechanism to characterise.
- **Increment 2** (Container Station display): `HEALTHCHECK` flag rendered
  for docker-ssh, absent/no-op for Apple, via fakes; a characterisation test
  that `docker logs`'s fake output contains the full phase sequence plus the
  point where `sshd` output would follow.
- **Increment 3** (destructive operations): the all-or-nothing plan-and-verify
  helper's fake-based cases above (zero-delete-on-any-mismatch, full-success,
  nonexistent-vs-mislabelled, Apple byte-identical); no change to
  `tests/run-tier.sh`'s destructive tier itself.
- **Increment 4** (restart policy / ordering docs): none beyond documentation
  assertions already covered by Section 10 (below) — this increment is
  prose plus whichever alternative the observations settle, not new
  production code.
- **Increment 5** (docs): Section 10 (`tests/test_section10_docs.sh`) extended
  to include `docs/qnap-runbook.md` in its checked document list (it
  currently checks `lifecycle`, `configuration`, `guest`, `troubleshooting`,
  `release-maintenance` only); Section 1's secrets scan already covers any
  new tracked file automatically.

Sections 1, 9, 10, 27, 32, 33, characterisation, refactor state machines,
and bash-3.2 all continue to run per the brief's validation list; nothing
above proposes skipping or weakening any of them.
