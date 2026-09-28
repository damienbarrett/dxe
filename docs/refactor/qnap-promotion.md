# QNAP promotion and maintenance proof (Branch 11 / Phase 7, `feat/qnap-promotion`) — design

Increment 0 design note, written before any code changes exist (the same
discipline `docker-adapter-mapping.md`, `direct-volume-storage.md`,
`store-trust-design.md`, and `qnap-lifecycle.md` used for their own
Increment 0 notes). Implements `qnap-dxe-plan.md`'s `## Phase 7` items 1-7
and its exit gate. Nothing here proposes a change outside `bin/`,
`bin/lib/`, `tests/`, `docs/`, the example profiles, `README.md`/`plans.md`
(index/link lines only), and the two plan files — no `.nix` change, no
change to Apple's own behaviour.

This document does not repeat what is already recorded elsewhere; it cites
`docs/lifecycle.md`, `docs/qnap-runbook.md`, `docs/release-maintenance.md`,
`docs/refactor/qnap-lifecycle.md`, and `tests/profiles/qnap-example.env` by
name rather than re-deriving their content. Every live step below (create
the canary, run it for a week, rebuild/recreate it, restore into a second
profile, destructive lifecycle on disposables, create the production
profile) is the coordinating session's own action, each after the user's
explicit go; this design and the fakes that prove the one code change
(section B) are the whole of this subagent's work.

## 0. Settled inputs (not decided here)

- **User decisions (2026-09-28):** Phase 7 proceeds now. Canary: name
  `dx-qnap-canary`, guest SSH on the NAS's Tailscale address at port
  **2222**, `DX_CONTAINER_RESTART_POLICY=unless-stopped` from day one
  (proven on this NAS in Phase 6's maintenance window), **8 GB / 2 CPU**
  (the user's own choice for the canary only — the checked-in example
  keeps its documented 8G/4CPU default and rationale; the canary's 2 CPU
  is recorded below as a per-profile choice, never a new default),
  acceptance period **one week** of real daily use. The two checks Phase
  6's exit gate carried over are Phase 7's: the relay fallback (item 1's
  network-change exercise) and a full backup + restore demonstrated on a
  QNAP guest (item 3). Item 7 stands: `dx-host` stays intact until the
  QNAP instance has passed the acceptance period and irreplaceable data
  has a verified backup. Production identifiers (item 6) are the user's
  to choose later; this note proposes defaults only (section C).
- **DQ3:** `DX_RUNTIME=apple` remains default; a QNAP profile is always
  explicit and local/git-ignored. **DQ5:** guest SSH publishes on the
  NAS's Tailscale address only, discovered at run time, never persisted to
  a tracked file. **DQ6:** every Docker object carries `io.dxe.*` labels;
  destructive commands verify exact name + label agreement, whole-operation
  refusal on any mismatch (already implemented and live-proven, Phase 6
  item 7). **DQ8:** `dx-backup`/`dx-restore` are both "Required" with no
  remote-parity caveat.
- **Invariants** continuing to govern this phase: `/nix`, `/persist`, and
  bootstrap state survive image/container replacement; remote destructive
  actions require exact runtime/host/profile/name/label agreement; tests
  use non-default names, ports, labels, and volumes.
- **Facts already built:** `dx_backup_resolve_dir()`
  (`bin/lib/dx-backup.sh:50-58`) already isolates the `/persist` mirror by
  `DX_CONTAINER_NAME` (Apple) or `DX_CONTAINER_NAME` plus
  `dx_runtime_host_identity()` (docker-ssh, so two profiles on different
  NASs sharing a container name still cannot mix). `dx-restore --dry-run`
  classifies `create` / `identical` / `conflict` (there is no separate
  `missing` state in the code — a target absent from the guest classifies
  `create`) via `dx_backup_restore_status`, made O(n) in the hardening
  branch. `docs/release-maintenance.md` holds the image-pin bump procedure;
  `dx-recreate` (`dx-destroy -> exec dx`, preserving volumes and keys) is
  the volume-preserving rebuild+recreate primitive item 2 needs verbatim.
  `DX_IMAGE_IDENTITY` (Phase 3) is the guest-side token that lets a
  `direct-volume` guest notice a rebuilt image on a reused volume.
- **What Phase 6 already proved** and Phase 7 does not need to re-derive:
  container restart / Container Station restart / NAS reboot all survive
  with `unless-stopped`, on this NAS, against a disposable
  `dx-qnap-spike` guest; the controller changing networks mid-phase had no
  effect on the guest (this is distinct from the relay-fallback check,
  which is still open — see section A1); the destructive ownership plan
  refuses the whole operation, zero deletes, on one mislabelled resource,
  proven live against the real NAS.

## A. Canary procedure (items 1, 2, 4, 5)

### A1. Checklist shape

The checklist is a new section in `docs/qnap-runbook.md` (Increment 2),
not a separate file — the runbook already owns "install / preflight /
operate / update / backup / restore / removal"; promotion is the next
operational phase in the same document's shape. Proposed section, "9.
Promotion (canary acceptance)":

- **Identity block** (restated, not re-decided): `dx-qnap-canary`, port
  2222, 8G/2CPU (per-profile, not a new default — cite
  `tests/profiles/qnap-example.env`'s own 8G/4CPU comment for contrast),
  `unless-stopped` from creation, one-week acceptance period, start date
  recorded by the coordinating session.
- **Daily-use exercise list** (what to touch at least once during the
  week, not a fixed daily order): `git` (clone/commit/push/pull inside the
  guest); Nix (a rebuild that changes a generation, `dx-status` showing the
  new generation active); `tmux` (a session that survives a `dx-ssh`
  disconnect/reconnect); at least one editor; `dx-ai`/Herdr or another AI
  tool; `dx-forward`/`dx-reverse` (one tunnel each way); controller
  suspend/reconnect (close the laptop lid mid-session, reopen, confirm
  `dx-status`/`dx-ssh` recover without guest-side action); a controller
  network change (Wi-Fi to a different network, or Wi-Fi to a hotspot) —
  ordinary case, already the kind Phase 6 exercised; **and the
  relay-fallback observation** (below), which is the one carried-over item
  that still needs its own explicit pass.
- **Relay-fallback observation** (the exact carried-over check, item 1):
  force the controller's *direct* Tailscale path to the NAS to fail —
  reaching a network known to block UDP hole-punching (a restrictive
  Wi-Fi/hotspot, or a controller-side firewall rule blocking outbound UDP
  is an equivalent, controller-only substitute if no such network is
  available) — never anything on the NAS side. Before: `tailscale status`
  (the NAS's peer line) and `tailscale ping <NAS's tailscale address>`,
  both showing a direct endpoint. Force the change; after: the same two
  commands now showing the peer routed `via` a DERP relay. While relayed:
  `dx-status`/`dx-ssh` against `dx-qnap-canary` still succeed, unchanged —
  this is the actual DXE-level proof (plain SSH over whatever Tailscale
  routes underneath, nothing about the published `<tailscale
  address>:2222` bind ever changes). Record all four outputs (sanitized —
  no real address in the evidence file, see below).
- **Image rebuild + recreate** (item 2) and **destructive lifecycle on
  disposables** (item 4): their own procedures, sections A2/A3 below;
  listed here only as checklist line items with a pointer.
- **Evidence to record, and where:** a sanitized, dated record under
  `docs/evidence/<date>/qnap-promotion.md` (the shape every other Phase 6
  evidence record already uses — Increment 3 records this location in
  `qnap-dxe-plan.md`'s Phase 7 status paragraph, not the record itself,
  which is the coordinating session's own artifact per the brief's public-
  repo rule). One entry per exercised item: date, what was run (the exact
  `dx-*` command, generic host alias `qnap-dxe` only, never a real
  address), and the observed result. The relay-fallback entry additionally
  carries the four `tailscale status`/`ping` before/after lines,
  sanitized to `<tailnet address>` the same way `qnap-lifecycle.md`'s
  evidence record already does.
- **Target versions and final validation evidence** (item 5): the NixOS
  release pin (`flake.nix`'s three branch refs), the base image tag +
  digest (`docs/release-maintenance.md`'s alignment rule), `DX_IMAGE_IDENTITY`
  before/after the rebuild (A2), and a closing line tying the week's log,
  the rebuild/recreate proof, and the restore-drill proof (section B)
  together as the one "promotion evidence" record referenced by Phase 7's
  status paragraph before the production profile is created.

### A2. Image rebuild + recreate preserving volumes (item 2)

Follow `docs/release-maintenance.md`'s existing procedure exactly — no new
procedure invented for QNAP. The minimum item 2 asks for (rebuild +
recreate, volumes preserved) is exactly what `dx-recreate` already is
(`docs/lifecycle.md` Wrappers table): `dx-destroy` (destroys container +
image, keeps volumes/keys) then `exec dx` (rebuilds the image, brings the
container back up against the same volumes). Concretely, against the live
canary:

```sh
./bin/dx-profile dx-qnap-canary ./bin/dx-recreate
```

If the coordinating session wants this to coincide with an actual release
bump, follow `docs/release-maintenance.md`'s "MIND THE PIN" branch instead
(pin unchanged → `dx-recreate`; pin changed → `dx-destroy -> dx-reset-nix-volume
-> dx`, because a changed Nix image pin is a store-trust event, not a
plain recreate) — item 2's own bar is met by either branch, since both
preserve `/persist` and the SSH identity; only `/nix`'s handling differs,
and that difference is already fully designed in `store-trust-plan.md`.
Evidence to record before/after, all via `dx-status`/`dx-backup
--dry-run`, no new tooling:

- `DX_IMAGE_IDENTITY` changed (new build) and the guest's own bootstrap
  log shows it noticed the change (`direct-volume-storage.md`'s protocol).
- `/persist` content unchanged: `dx-backup --dry-run` against the canary
  immediately before and immediately after the recreate reports the same
  at-risk selection (ideally "0 files ... transferred" on the after-run
  if a backup was taken just before recreating).
- SSH host identity unchanged: the per-profile known-hosts pin
  (`docs/lifecycle.md` "Reaching a QNAP guest over SSH") still validates
  without a mismatch warning — a QNAP guest's host key lives on the
  `/persist`-adjacent state that `direct-volume` mode preserves across a
  container recreate, so this is expected to need no `ssh-keygen -R`.
- Labels, port, and restart policy unchanged (`docker inspect` /
  `dx-status`): the recreate must not silently drop `unless-stopped` or
  move the published port.

### A3. Destructive lifecycle on disposables only (item 4)

Reaffirms, does not redesign, Phase 6's already-proven procedure
(`dx-destroy-volumes`/`dx-factory-reset`'s immutable ownership plan,
whole-operation refusal on any label mismatch). The Phase 7-specific value
of re-running it now: Phase 6 proved it in isolation (only
`dx-qnap-spike` existed); Phase 7 proves it **with the canary concurrently
live and in daily use** — a stronger, more realistic proof that exact-name
+ label matching still isolates a disposable spike resource from a real
neighbor. Procedure: create a fresh `dx-qnap-spike2`-labelled disposable
guest (or reuse the existing spike-naming convention with a new suffix),
run `dx-destroy-volumes --force`/`dx-factory-reset --force` against it,
and separately attempt (and expect refusal of) a deliberately mislabelled
or misnamed target resembling the canary, confirming zero delete calls.
**Never** run any destructive command against `dx-qnap-canary` itself, its
volumes, or its keys, at any point in this phase — the checklist item
explicitly excludes it by name, not merely by convention.

## B. Restore into a second isolated profile (item 3)

### B1. What already holds, unchanged

`dx_backup_resolve_dir()` keys the mirror by `DX_CONTAINER_NAME` (+
`dx_runtime_host_identity()` for `docker-ssh`). A second profile's own
`DX_CONTAINER_NAME` differs from the canary's by construction (every QNAP
profile's identifiers are distinct per DQ3's own example header). So
today, running plain `dx-restore` under a **fresh** second profile already
fails closed — `Error: no backup mirror at .../current. Run dx-backup
first.` — even with the canary's own mirror sitting right next to it under
the same `DX_BACKUP_DIR`. Half of item 3's isolation requirement ("never
defaulting to another profile's mirror") is already true; nothing to fix
there. What is missing is a supported, explicit way to restore the
canary's own already-taken backup into that second profile's guest on
purpose — which the task pre-authorises exactly one new flag for.

### B2. The flag: `dx-restore --source-container=NAME`

**Form.** `--source-container=NAME` (a single `=`-joined token), not
`--source-container NAME` (two tokens). Reason: `dx-restore`'s (and
`dx-backup`'s) argument loop is `for arg in "$@"; do case "$arg" in
--dry-run) ...; --force) ...; esac; done` — a single-token scan with no
existing value-taking flag. A `--flag=value` form slots into that same
`case` with one more arm and a `${arg#--source-container=}` expansion; a
two-token form would need restructuring the whole loop into an
index/`shift`-based parser for the sake of one flag. Smallest change,
reuses the existing idiom (brief's design rule).

**Semantics.**

- **Omitted (default):** byte-identical to today. Source directory =
  `dx_backup_resolve_dir()` using the *current* profile's own
  `DX_CONTAINER_NAME` (+ identity). No behaviour change for any existing
  caller or test.
- **`--source-container=NAME`:** overrides *only* the container-name path
  segment used to find the mirror to read **from**. The identity segment
  (docker-ssh only) still comes from the *current* profile's own resolved
  `DX_REMOTE_HOST`/host identity — this proves the actual Phase 7
  scenario (both profiles on the same NAS); it is not a cross-host
  restore mechanism (see "Known limitation" below). The push
  **destination** — the running guest actually written to — is
  unconditionally the current profile's own `$DX_CONTAINER_NAME`, exactly
  as today; the flag can only ever change where bytes are read from,
  never where they are written to. `dx-restore` prints one explicit line
  whenever the flag is given, before anything else, including under
  `--dry-run`: `Restoring <NAME>'s backup into <DX_CONTAINER_NAME>
  (cross-profile restore).` — never silent.
- **Validation, fail-closed.** `NAME` is checked with the exact character
  class `bin/lib/dx-config.sh` already applies to `DX_CONTAINER_NAME`
  (`''|[.-]*|*[!A-Za-z0-9_.-]*` → reject) — reused directly via
  `dx_config_validate_value DX_CONTAINER_NAME "$NAME"` (already sourced
  through `dx-lib.sh`), not a new pattern. A `NAME` that does not resolve
  to an existing `.../current` mirror fails with the exact same "no
  backup mirror" error text as the no-flag case, just naming `NAME`'s
  directory — no partial state, no fallback search, no "closest match."
- **Known limitation, stated not solved:** because the identity segment
  always comes from the current profile, pointing `--source-container` at
  a name that only exists under a *different* NAS's identity segment
  simply resolves to "no backup mirror" — it fails safe, it does not read
  the wrong host's data. A genuine cross-host restore would need a
  separate `--source-identity`/full-path override; Phase 7 does not need
  it (both the canary and the second profile live on the same NAS), so it
  is explicitly out of scope here, not designed.
- **No new contract operation.** This stays entirely inside `dx-restore`
  and `bin/lib/dx-backup.sh`; no new `dx_runtime_<op>`. Matches "the
  restore source-profile flag is the one pre-authorised addition."

### B3. Verifying content and permissions after a real restore

**Content:** re-run `dx-restore --source-container=NAME --dry-run` after
the real push completes. Every target should now classify `identical`
(the same sha256-based comparison `dx_backup_restore_status` already
does) — this is the content proof, no new mechanism.

**Permissions:** neither the manifest (`path size mtime sha256`) nor the
guest listing carries mode/owner bits, so this needs one explicit,
documented spot check (runbook, Increment 2), not a new contract
operation — `dx_backup_restore_push` already documents that it always
restores `dx:dx` ownership and preserves the file's mode from the tar
stream:

```sh
./bin/dx-profile <second-profile> ./bin/dx-enter -- \
    find /persist -not \( -user dx -a -group dx \) -print   # expect empty
```

plus a `stat -c '%a'` comparison against one or two known paths in the
exercised backup that carry non-default mode bits (an executable script,
if the selection includes one), against the same paths' mode as captured
on the canary before the backup was taken.

### B4. Tests (fakes must prove the isolation both ways)

1. **Negative/regression, no flag:** under profile B (fresh
   `DX_CONTAINER_NAME`, no flag), `dx-restore` refuses with today's exact
   "no backup mirror" error even though profile A's (the canary's) fixture
   mirror exists on disk right next to it under the same `DX_BACKUP_DIR`
   — proves the default never crosses profiles. (This case already passes
   against the unmodified code; it becomes a permanent regression guard.)
2. **Positive, with the flag:** under profile B, `--source-container=A`
   reads profile A's fixture mirror and pushes into profile B's fake
   guest — assert the `exec`/`put` calls target `DX_CONTAINER_NAME=B`,
   the read path is A's directory, `--dry-run` classification is correct
   (`create`/`identical`/`conflict`), a real push transfers the expected
   files, and profile A's own mirror/manifest is byte-unchanged afterward
   (read-only source).
3. **Fail-closed, nonexistent source:** `--source-container=doesnotexist`
   errors exactly like the missing-default-mirror case; zero guest
   mutation.
4. **Validation:** `--source-container=` with a leading dot/dash or a
   shell metacharacter is rejected by the reused validator before
   touching the filesystem or the guest — same fixture style
   `test_section*` already uses for other identifier fields.
5. **Interaction:** `--source-container` combined with `--force`,
   `--dry-run`, and explicit `PATH` arguments all behave exactly as today,
   just against the overridden source directory.
6. **Apple no-op regression:** `DX_RUNTIME=apple` with `--source-container`
   set behaves the same as `docker-ssh` for the flag itself (the flag only
   changes the container-name segment, which `dx_backup_resolve_dir`
   already branches on) — one characterisation case, not new behaviour.

## C. Production profile (item 6) and the Apple guest (item 7)

### C1. A second checked-in example profile

`tests/profiles/qnap-example.env` already documents a production-shaped
example (`DX_CONTAINER_NAME=dx-qnap`, port 2222, 8G/4CPU, key pair
`dx-qnap_key`) — written before the canary existed. The canary needs its
own distinct, checked-in placeholder shape too, so an operator (or a
future subagent) does not have to hand-derive the delta from prose.
**Decision:** add a second checked-in example,
`tests/profiles/qnap-canary-example.env`, mirroring
`qnap-example.env`'s header conventions and placeholder-only rule (no real
hostname/username/key material), with the settled canary fields:
`DX_CONTAINER_NAME=dx-qnap-canary`, `DX_CONTAINER_MEMORY=8G`,
`DX_CONTAINER_CPUS=2` (comment: per-profile canary choice, not a new
default — cross-reference `qnap-example.env`'s own 4-CPU rationale),
`DX_CONTAINER_RESTART_POLICY=unless-stopped` (comment: proven on this NAS
in Phase 6's maintenance window, "from day one" per the user's own
decision — contrast with `qnap-example.env`'s cautious `no` default,
which stays unchanged since that file documents the general, not-yet-
NAS-tested shape), `DX_SSH_PORT=2222`, distinct volumes
(`dx-qnap-canary-nix`/`-persist`/`-bootstrap`), distinct image
(`dx-qnap-canary-nixos`), distinct key pair (`dx-qnap-canary_key`). This
is Increment 2 work (docs only); Increment 0 only decides that it exists
and its shape.

### C2. Production profile proposal (the user decides)

Propose, do not decide:

| Field | Proposed value | Reasoning |
| --- | --- | --- |
| `DX_CONTAINER_NAME` | `dx-qnap` | Already the checked-in `qnap-example.env`'s own value — no change needed there. |
| `DX_SSH_PORT` | **2223** (open question — see below) | Distinct from the canary's 2222 so both *could* run concurrently during the cutover window, rather than requiring the canary torn down first purely to free the port. |
| `DX_CONTAINER_MEMORY`/`DX_CONTAINER_CPUS` | `8G`/`4` | The existing checked-in example's own documented default — unchanged; the canary's 2-CPU choice was explicitly recorded as a per-profile, canary-only choice (user decision 2), not a new default. |
| `DX_CONTAINER_RESTART_POLICY` | `unless-stopped`, from creation | Carries over the now-doubly-proven (Phase 6 + the canary's own week) evidence for this specific NAS. |
| Key pair, volumes | `dx-qnap_key`, `dx-qnap-nix`/`-persist`/`-bootstrap` | Already the checked-in example's own values — no change needed. |

**Open question left to the user, named explicitly (not decided here):**
the port. 2223 lets the canary and production coexist during promotion;
reusing 2222 is equally valid if the canary is retired first — either
way, `DX_SSH_PORT` in a real local profile is git-ignored and costs
nothing to change later, so this is a low-stakes but still user-owned
choice per the brief's "which port to use" rule. No code or example
change is needed either way: `tests/profiles/qnap-example.env` already
documents `DX_CONTAINER_NAME=dx-qnap`/port 2222 and needs no edit unless
the user picks a different port for production, in which case Increment 2
or a later change updates that one line and its header comment.

### C3. Item 7 — `dx-host` stays intact

Documentation-only rule, restated (not re-decided) in the runbook's
promotion section and in the live-steps list (section E): `dx-host`
receives no destroy, no factory-reset, no volume change, until **both**
(a) the canary has completed its full one-week acceptance period with no
unresolved checklist failure, and (b) `/persist`'s irreplaceable content
has a **verified** backup — meaning restored-and-checked, not merely
captured. Section B's restore-into-a-second-profile drill is the
qualifying verification event for (b) unless the coordinating session
prefers to run an equivalent backup+restore cycle against the production
profile itself once it exists. Destroying or retiring `dx-host` is never
scheduled by this design, this phase, or any subagent — it stays the
user's own separate, later, explicit call, per the brief's rule that
"Never start, stop, create, recreate, or destroy `dx-host` ... its
volumes" applies unconditionally to every subagent, always.

## D. Exit gate — compatibility exception inventory

"No temporary compatibility exception lacks an owner and removal
condition." Inventory of every exception found across `qnap-dxe-plan.md`
and the design notes, with disposition:

| # | Exception | Owner | Removal condition | Blocks Phase 7? |
| --- | --- | --- | --- | --- |
| 1 | Runtime-boundary audit exception: `bin/dx-lock`, `bin/dx-status`'s read-only lock helpers, and `bin/lib/dx-container.sh`'s `dx_destructive_plan_and_verify` call into `dx_runtime_docker_*` directly (`docs/lifecycle.md` principle 9, `tests/test_runtime_boundary_audit.sh`). | Whichever future branch next extends DQ2's adapter contract — none scheduled today. | Locking and the multi-resource ownership plan become real `dx_runtime_<op>` operations with an Apple-side equivalent defined (Apple has neither a lock concept nor an ownership plan today, so there is nothing to make symmetric yet). | No. |
| 2 | Tailscale-in-guest spike deferred (`## Non-goals`: "Under review: Phase 5 item 9 ... evaluates the opposite as a design spike; this non-goal stands until that spike's go/no-go"). | None assigned; a future spike branch if ever prioritised. | The spike runs and reaches an explicit go/no-go. | No — explicitly restated in "E. Not in this phase" below. |
| 3 | Context-tree rename pending (DQ7: "can be renamed only in a standalone mechanical commit ... retain a bounded compatibility reader if profiles persist the old path"; `qnap-dxe-plan.md:767` "remains pending, deliberately untouched"). | None assigned; a future standalone mechanical-rename commit. | That commit lands, updates every path consumer and test, and (if needed) the bounded compatibility reader's own removal condition is decided at that time. | No. |
| 4 | Restart-ordering item 9 fallback design (a NAS-side autorun hook, "alternative (b)") — documented, never implemented. | N/A — not a live exception. | N/A. | **Not an exception:** item 9 is *decided* (alternative (a), Docker's own restart policy, no NAS-side hook); alternative (b) is a documented fallback kept on record only in case a future NAS or QTS/QuTS release changes `tailscale0`'s boot-time ordering (which would fail loud per `qnap-lifecycle.md` section B), not an open gap. |
| 5 | `DX_CONTAINER_RESTART_POLICY` default stays `no` despite `unless-stopped` being proven on this NAS (DQ3's default table; `qnap-example.env`'s own comment). | N/A — permanent, not temporary. | N/A. | **Not an exception:** per-NAS calibrated guidance by design — every operator must run their own reboot check before opting in; the checked-in example cannot inherit one NAS's proof. |
| 6 | `dx-mount DIR` / `dx-nix-disk` unsupported under `docker-ssh` (DQ8's disposition table). | N/A — permanent capability gap. | N/A (a later plan may add an explicit remote-worktree sync command per DQ8's own closing paragraph — new work, not a fix to this one). | **Not an exception:** DQ8 records this as a permanent, documented capability boundary, not debt. |

Three genuinely temporary exceptions exist (#1-3), each now has an owner
and a removal condition per the table above; none blocks Phase 7's own
definition-of-done. Three more (#4-6) were considered and are recorded as
explicitly *not* exceptions, with reasoning, so the inventory is seen to
be complete rather than silently skipping them. Increment 3 records this
table (or a condensed form of it) directly in `qnap-dxe-plan.md`, most
naturally as a subsection under Phase 7's own exit-gate text, since that
is the text the exit gate's wording refers to.

## E. Ordered list of live steps for the coordinating session

All of the following are the coordinating session's own actions, each
after the user's explicit go; no subagent runs any of them.

1. Create the canary profile (`tests/profiles/` local, git-ignored,
   copied from `qnap-canary-example.env` once it exists —
   `dx-create-keys`, then `./bin/dx`) with the settled fields: name
   `dx-qnap-canary`, port 2222, 8G/2CPU, `unless-stopped` from creation.
2. One week of real daily use against the runbook's promotion checklist
   (section A1); log evidence as it goes, sanitized, under
   `docs/evidence/<date>/qnap-promotion.md`, including the relay-fallback
   observation at least once during the week.
3. Image rebuild + `dx-recreate` against the canary, preserving volumes
   (section A2); record before/after evidence.
4. Restore drill (section B): `dx-backup` on the canary (fresh if
   needed), create the second isolated profile (disposable, its own
   name/keys/volumes), bring its guest up, run
   `dx-restore --source-container=dx-qnap-canary` against it, `--dry-run`
   both before and after the real push, verify content (post-restore
   dry-run reports all `identical`) and permissions (`dx:dx` ownership +
   mode spot check).
5. Destructive lifecycle on disposables only (`dx-qnap-spike*`),
   reaffirming Phase 6's proof now with the canary concurrently live
   (section A3) — never touching the canary or the second profile.
6. Once the week passes with no unresolved checklist failure and step 4
   counts as the verified backup, the user decides the production
   identifiers (section C2, in particular the port) and creates the
   production profile.
7. `dx-host` stays intact throughout every step above; its own retirement
   (if ever) is a separate, later, explicit decision, not part of Phase
   7's exit gate (section C3).

## Not in this phase

Per the task's own "E. Not in this phase," restated: creating anything on
the NAS (all of section E above is the coordinating session's, with the
user's go); any `.nix` change (none expected or proposed); Branch 13; the
Tailscale-in-guest spike (still deferred, item 2 of the exception
inventory).

## Test list by increment

- **Increment 1** (restore isolation, section B): the six fake-based cases
  in B4, against `docker-ssh` fixtures with two distinct profile
  fixtures' mirror directories present side by side under one
  `DX_BACKUP_DIR` — the exact "both ways" shape the task asks for
  (default never crosses; explicit flag does, and only in the read
  direction). No new `dx_runtime_<op>`; existing Section 9/host-scripts
  and backup/restore test files gain the new cases rather than a new
  section.
- **Increment 2** (docs, sections A/C): `docs/qnap-runbook.md` gains "9.
  Promotion (canary acceptance)"; `tests/profiles/qnap-canary-example.env`
  added (Section 1 secrets scan covers it automatically, same
  placeholder-only rule as `qnap-example.env`); Section 10
  (`tests/test_section10_docs.sh`) extended to include the runbook's
  existing entry already covers this (no new tracked doc file needs a new
  Section 10 entry beyond the new example profile itself, which Section 1
  already covers structurally) — confirm during Increment 2 whether
  Section 10 checks example profiles at all before assuming no change
  is needed there.
- **Increment 3** (section D, plan updates): the exception-inventory table
  recorded in `qnap-dxe-plan.md`'s Phase 7 exit-gate subsection; Phase 7's
  own status paragraph added (designed/proven vs. awaiting live steps);
  `checkout-consolidation-plan.md`'s Branch 11 row/section updated to
  record Phase 7 designed-and-code-proven, live steps pending. No test
  changes; prose only.

Sections 1, 9, 10, 27, 32, 33, characterisation, and bash-3.2 all continue
to run per the brief's validation list; nothing above proposes skipping or
weakening any of them.
