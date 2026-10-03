# DXE unified plan — 2 October 2026

**Status: partially complete; all eight user policies recorded, ready for handoff.**
This is the single forward plan consolidating `1-oct-plan-a.md`,
`1-oct-plan-b.md`, and `1-oct-plan-c.md`. Original plans and handoffs are
preserved. It supersedes their pending landing steps with the recorded landing
and records the agreed policies below. All planning choices are resolved;
execution is pending. This consolidation completes documentation/indexing and
the selected private archival only (six originals verified and preserved below).
No guest, profile/PATH or network changes have been performed; no commit/push
or session termination is claimed.

**Continuing owner: Agent A (Phase 7 coordinator).** A receives B/C's work and
finishes repository integration, gates, guest maintenance and Phase 7. B/C
transfer their artifacts and then close; they are not assumed already stopped.
Future coding uses appropriate lower-power subagents in isolated worktrees;
A reviews, gates and coordinates. Unrelated processes remain untouched.

**Agent A start checklist:** first read `2-oct-plan.md`; inspect current clean main and
the shared WIP; confirm B/C's exact transfer before closure; prioritize the
currently available work-Wi-Fi Tailscale baseline, **read-only and no lifecycle**;
then finish every listed fix and final gate before real-guest publication.
When checks pass, prepare backups, current generations, disruption and backout,
then ask the user to select named Mac/QNAP windows. This is ready to hand off;
it does not attest that A has already read/accepted it or that B/C have closed.

## 1. Current reconciled state

Initial local Git inspection on 2 October, before archival: `main` and recorded `origin/main` are `1f287f8`
(landing record). The findings series landed by rebase/fast-forward as
`7194e17`; `main:findings.md` records CI **36907387073, both jobs green**.
The old `landing-prep` ref is gone. **Do not reland the findings branch.**
This is local evidence, not a fresh remote query or live guest inspection.

| Subject | Current evidence and remaining obligation |
| --- | --- |
| Shared checkout | At initial inspection: `refactor/findings-2026-09-29` at `bd25515`, 16 modified tracked files, untracked `bin/qx`, `tests/test_qx.sh`, notes/plans and session launcher. Six source notes/plans have since been archived externally; new plan/index documentation now exists. Preserve implementation WIP; use a clean branch from current main for transfer. |
| `dx-host` | B's 1 October 21:45 read-only check recorded running = published `20261001T052021Z-37948`, shared branch content from about `8c7c910`, before the selector fix. This supersedes A's untouched-`8fba879` claim. Formal promotion #9, verified real-mirror migration and recreate remain open. Recheck before maintenance. |
| `dx-test` | Last left stopped; cold start, one authorised recreate, full lease/marker/health proof, 2,527 + 25 passing checks and scratch backup migration/restore checks recorded. Previous recreate permission is spent. |
| Canary | Last corrected to older main content, generation `20261001T045637Z-17556`, Docker healthy, keyring live. A branch publication was corrected by approved republish and stop/start. No evidence that it yet soaks the newly landed findings release. |
| QNAP acceptance | Creation, canary image rebuild/recreate, disposable spike isolation and isolated restore drill/teardown are done. Restore drill: 1,450 targets identical, backup verified, mode defect recorded. Real-use/relay evidence and production decision remain. |
| Open defects | Directory-mode loss across backup generations/restore; Docker stale PID-1 leases across container restart. Existing findings code already has restored-file `chown -h` and `COPYFILE_DISABLE=1`; verify those remedies instead of implementing duplicates. |
| WIP validation | A reports unrestricted host 170/170, Docker health 50/50, state 166/166, Bash 3.2 and pinned ShellCheck clean. C's earlier sandbox failures are not final unrestricted failures. Neither set certifies the forthcoming safeguards or complete final follow-up. |

Canary created **Tuesday 29 September**. Monday **5 October** is inclusive day 7;
Tuesday **6 October** completes seven elapsed days. “Monday 6 October” in A/B
is wrong. A calendar date alone does not satisfy release-soak/acceptance gates.

## 2. User decision ledger

All eight choices have been answered and drive the execution text below.
Previously selected `dx`/`qx` parity and external private storage are retained;
actual proof and named maintenance windows remain future gates.

| Decision | Agreed policy | Status |
| --- | --- | --- |
| D1 — Source protection and daily PATH | Unconditional source pin and daily PATH on a clean main-only checkout, **provided no sensitive data enters the repository**. Actual profiles/keys, NAS addresses/storage paths/management credentials and machine-specific absolute pin values remain external/private; public code/docs use generic fields/placeholders only. | **Resolved.** |
| D2 — Release sequence | Implement, gate and land all connection/profile safeguards, end-to-end directory modes and Docker leases before real `dx-host`/canary publication or activation. Repository commits may land separately; select one coherent validated final main SHA. | **Resolved.** |
| D3 — Acceptance period | Retain the 29 September → Tuesday 6 October elapsed week; decide readiness from exact final-release evidence. No automatic reset or added seven-day soak after updates; postpone if evidence is incomplete. | **Resolved.** |
| D4 — Network validation | Use the user's **current restrictive work Wi-Fi**, proving access through Tailscale away from the home/private network. A captures read-only path/status/SSH evidence while it is available. Work Wi-Fi or a tailnet address does not itself prove DERP relay; record the observed path honestly. | **Resolved policy; evidence pending.** No waiting or artificial UDP block selected. |
| D5 — Maintenance windows | Ask the user to choose named Mac/QNAP windows once final checks pass and exact release, backup plan, generation baseline, disruption and backout are prepared. Do not proceed merely because a guest is idle. | **Resolved policy; concrete windows pending.** |
| D6 — Mac recreate scope | Include one `dx-host` recreate in the selected maintenance window after verified backup, retaining volumes/keys and verifying the new launcher/healthcheck. | **Resolved scope; execution/window pending.** Do not reask the selected scope. |
| D7 — Production/default access | `dx-qnap`, 8 GB/4 CPU, `unless-stopped`, tailnet-only temporary port 2223; daily `qx` switches to production after validated cutover. | **Resolved configuration; production acceptance/cutover pending.** |
| D8 — Artifacts | Track/index the sanitized authoritative new plan; archive the six original handoffs/plans privately, preserving contents. Sensitive values never enter tracked material. | **Resolved and documented.** Plan indexed; all six original files privately archived and exact bytes verified before original-copy removal. |

Update affected acceptance criteria only if the user later changes a policy.
Do not reask settled designs/scope, findings landing, the continuing owner,
shared `dx`/`qx` behavior, port 2223, or the completed key migration. D5's concrete
windows and the prepared production acceptance go remain future requests.

## 3. Settled behavior and private setup

- Preserve `qx → dx-profile → dx → dx-ssh`: running/owned reconnect performs no
  bootstrap publication; stopped/missing guest uses the full bring-up path.
  Both commands forward arguments to existing SSH command handling; no arguments
  attach/create tmux `dx`. Do not revive every-invocation lifecycle publication.
- `dx` preflights runtime/service before guest state, locks Apple service startup,
  polls readiness with positive `DX_SYSTEM_WAIT_TIMEOUT` (current default 30 s),
  fails before guest operations on start/timeout error, and releases locks before
  SSH exec. QNAP Container Station startup stays manual.
- Bootstrap changes need deliberate publication and restart to activate. Printed
  remedies retain the profile on both stop/start commands. Restart ends guest
  processes/tmux sessions; laptop sleep is not proof of restart persistence.
- Real canary profile: `~/.config/dxe/profiles/qnap-canary.env` (600); directory
  700. Keys `~/.ssh/dxe/qnap-canary` (600) and `.pub` (644); directory 700.
  SSH identity was preserved. Sibling `dxe-main` profile symlink points there;
  remaining private ops-clone/spike copies must be inventoried during transfer.
- User/XDG profile lookup precedes bundled profiles; explicit `DX_PROFILES_DIR`
  is authoritative and a missing/invalid selected profile fails closed. Profiles
  are validated data. They support `${DX_PROJECT_ROOT}` path substitution,
  but not `~`, `$HOME` or `$XDG_CONFIG_HOME`; private external paths are absolute.
- External storage is not source isolation: another checkout can resolve it.
  Until D1 is implemented, real QNAP lifecycle work stays on approved clean main.
  Use profile-selected `dx-ssh` there for interim connection access.
- Mac's default key still lives at `$DX_PROJECT_ROOT/dx_key` and `.pub`.
  Its migration is optional deferred work, not part of completed QNAP setup.

## 4. Ordered repository work — Agent A

### Step 1: transfer and preserve

Coordinate handoff while B/C remain available. Record current HEAD, main, active
edits/tests, tracked patch and untracked implementation contents. Transfer only
owned changes onto a clean follow-up branch from `1f287f8` or its verified
successor; compare the resulting diff. Leave shared WIP/original notes intact.
No blanket stash/reset/clean, indiscriminate staging or branch switch over WIP.
Close B/C only after A confirms the transfer and any necessary private records.

Owned paths: `.github/workflows/ci.yml`, `README.md`, `bin/{dx,dx-profile}`,
`bin/lib/{dx-config,dx-container}.sh`, `docs/{configuration,lifecycle,qnap-runbook,
troubleshooting}.md`, registry fixture, both QNAP example profiles, Docker-health,
state-machine and Section 9 tests; new `bin/qx` and `tests/test_qx.sh`.
Preserve unrelated launchers and all three source plans.

### Step 2: connection/profile safeguards

**Done (2026-10-02, `feat/dx-reconnect-readonly`, evidence
`docs/evidence/20261002/dx-reconnect.md`):** pin (`DX_PROFILE_ROOT`),
fixture isolation in the runner, `QX_PROFILE`, `qx` in every inventory,
the lifecycle-lock contract restored on reconnect, logic moved into covered
libraries (unscoped 2,603 ≤ 2,635), all gates and the Apple live tier
green. Remaining for D1: set the private pin value in the real profile and
repoint the daily PATH `dx`/`qx` to the designated main-only checkout
(operator setup, not repository work).


Implement D1's selected **unconditional main-only source pin** as a small
reviewed follow-up. Optional `DX_PROFILE_ROOT` is a registered absolute-path
constraint with an empty fixture/default value, parsed as data, enforced before
the wrapped command or side effects, and preserved/validated in child snapshots.
Canonicalize root/symlink identity. Cover `DX_CONTEXT_DIR` and
`DX_BOOTSTRAP_SOURCE` overrides; matching root cannot approve arbitrary source.
Root pinning itself does not certify a clean/approved commit. Public registry,
reader/validation code and documentation stay generic, with placeholders only;
canonical-path tests use temporary fixture paths. The actual approved root value,
profiles/keys, NAS addresses/storage paths and management credentials remain
externally managed private configuration and must never be tracked or copied
into public evidence or this plan.

Before enabling it, designate the approved main-only daily checkout, repoint
PATH `dx`/`qx` to its vetted `bin/`, and verify from a new shell. The operations
clone needs its own approved pinned private profile or must use the designated
checkout; never bypass the pin to preserve an old command. Branch-wrapper
invocation must refuse clearly. Lifecycle-only protection is not the selected
design; daily connections resolve through the approved main-only entrypoints.

Complete these requirements:

1. Force test runners/live harnesses to select `$BASE_DIR/tests/profiles` before
   profile resolution; prove personal `dx-test` cannot shadow the fixture and
   missing explicit fixtures fail. Keep lookup-precedence tests self-contained;
   a blanket duplicate-name error is unnecessary if normal precedence is retained.
2. Add validated `QX_PROFILE`, default `qnap-canary`; preserve forwarding/status.
3. Make `tests/test_qx.sh` executable: currently 0644, but coverage discovery
   executes `coverage: yes` suites directly. Include/classify `qx` deliberately
   in entrypoint contracts and the coverage metric, not only CI lint discovery.
4. Cover service readiness, lock inheritance/release on every error, foreign
   ownership refusal, state changes during bring-up, manual Docker-start refusal,
   profile-preserving restart guidance and no reconnect mutation.
5. Align generic examples/default tables/docs with external keys, chosen source
   constraint and PATH setup. Registry field count is currently 39 in WIP;
   derive the final expectation after any added field. Share validation helpers
   only where useful; do not turn this follow-up into a redesign.

### Step 3: directory-mode and lease fixes

**Done (2026-10-02, `fix/docker-ssh-lease-and-restore-modes`, evidence
`docs/evidence/20261002/step3-leases-and-modes.md`):** lease liveness by
full incarnation identity (shared protocol, one parser), directory modes
captured per generation and restored with a conflict/`--force` policy, the
one-time mirror upgrade, `chown -h`/`COPYFILE_DISABLE` pinned by tests,
runbook 9.4 `--force` note; all gates and the Apple live tier green. The
Docker-restart proof of the lease fix runs on a disposable spike inside the
D5 QNAP window. Repository work for D2 is complete; guest maintenance
(section 5) may now be scheduled.


**Modes end-to-end:** selected-file tar and `mkdir -p` ancestor creation can lose
original modes during capture/carry-forward, before restore. Audit all three
stages; capture validated directory metadata and retain it through generations.
Restore missing directories with original modes, including 700; detect differing
existing permissions and require a documented conflict/explicit-force policy
rather than silently widening them. Report unavailable legacy mode information
instead of inventing it. Prove fail-closed handling, ownership/symlink safety,
both adapter transports, large selections and bounded runtime-call count.
Keep generation `manifest.tsv` excluded/refused as restore content.

**Docker leases:** same NAS kernel boot ID survives container restart. Validate
full incarnation identity (boot/PID/process start or equivalent stronger
validated identity), rather than taking the first `.1` filename. Reuse the
publication protocol; cover same-boot stale/live leases, reused PID, malformed
records, Apple reboot, Docker restart and valid live lease/GC protection. Real
Docker confirmation uses a specifically authorised disposable profile.

Update restore-drill instructions for bootstrap-seeded Herdr conflicts and
disposable-target `--force`. Verify existing `chown -h`/tar guards on the selected
release; only add further fixes if warnings remain. Stage explicit scoped paths.

### Step 4: candidate gates and landing

Run focused behavioral/affected suites, then complete non-live unit tier,
Bash 3.2, pinned ShellCheck 0.10.0, isolated kcov/ratchet, and dual-system Nix
evaluation. Require 100% measured sourceable coverage and justified metric
accounting; do not raise ceilings to hide moved/unmeasured logic. Run required
slow cases for release/CI even if iteration used `DXE_SKIP_SLOW_TESTS=1`.
Then run the applicable authorised clean-snapshot Apple live gate on `dx-test`
and disposable Docker trust-boundary proof. Record exact SHA, failures/skips
and environment limits; require final candidate CI, review and private-identifier
scan before authorised landing. Current source-check evidence is not a substitute.

**Repository acceptance:** D1 implemented with usable PATH/ops configuration;
fixture isolation, selectors and discovery proven; end-to-end directory-mode
and Docker-lease defects fixed; final required gates green; scoped changes landed.
D2 requires all these fixes before any real `dx-host`/canary publication or
activation. Commits may land separately, but the guest update uses one coherent
validated final main SHA. No landing automatically publishes into guests.

## 5. Guest maintenance and acceptance — decisions D2–D7

**Status (2026-10-02 evening, both D5 windows run on the user's go):**
`dx-host` promotion #9 complete (sync → backup with mirror migration →
stop/start → D6 recreate; Appendix D of `checkout-consolidation-plan.md`).
The canary was synced, backed up (mirror migrated, directory modes
recorded) and restarted; it soaks `main` `00b67d0` from 22:39 NZDT with no
drift warning (`docs/evidence/20260928/qnap-promotion.md`, "Day 4
maintenance"). The docker-ssh lock no longer depends on the profile's own image
(`fix/docker-lock-image`, evidence `docs/evidence/20261002/docker-lock-image.md`),
so a new profile's first `dx` works again — proven live the same night on a
disposable `dx-qnap-spike3`, which also proved the lease fix across a Docker
restart (`docs/evidence/20260928/qnap-promotion.md`, "Day 4, late").
Remaining for Phase 7: the week's real use on `main` `00b67d0`+, the
relay-fallback observation (still unexercised), and the production decision
on Tuesday 6 October.


Prepare exact clean release SHA, profiles/targets, inventory, current image and
published/running generation, idle status, retained predecessor/backout and
expected session disruption before the D5-selected window. All publication itself
is maintenance, even when it does not activate a guest. No automatic restarts.

**Mac promotion #9:** the landed host backup invokes the selector under guest
`/guest-bootstrap/current`; the older guest publication lacks the selector fix.
Therefore the recorded promotion sequence intentionally needs an **authorised
non-activating sync of the selected vetted main first**, then `dx-backup` against
`~/Backups/dxe-persist/dx-host`, including legacy in-place mirror migration and
verification. Do not restart/recreate before the backup is proven. Inspect that
sync changes only the intended published helper/payload and retains the running
lease; record the activation still pending. If this cannot be shown safe, stop
and use an independently verified backup route before activation, rather than
running the old broken selector or proceeding without backup.

After backup verification, approved stop/start activates the chosen generation.
Verify SSH, raw-login PATH/tools, persistence, keyring, lease/marker/health and
backup/restore usability. Under D6, one named `dx-host` recreate follows in the
same selected window, retaining volumes and keys. Check idle state and the exact
window/target; D6 settles its scope, while D5 still requires the user's window
choice before action. Current findings pin is
unchanged; a subsequent pin bump uses the store-trust/base-changeover procedure.

**Canary:** complete D2's full final release before publication/activation; D5 sets
the window policy for backup, vetted republish and stop/start. D3 retains the
original elapsed week and requires evidence for this final release.
Check generation/image/persistence/SSH/keyring/Docker health afterward and record
which SHA the remaining week actually soaks. Account for the lease-status defect
until fixed. If activation is deferred, the old main's soak does not prove the
new release. Do not repeat completed canary recreate, drill or spike merely to
check old boxes; any necessary updated proof uses fresh scoped authority.

**Network evidence now:** under D4, A prioritizes a read-only baseline on the
currently available restrictive work Wi-Fi, from the approved operations setup.
Privately capture Tailscale path plus successful profile-selected SSH/status,
then retain sanitized evidence. Prove off-home reachability through Tailscale;
distinguish a direct Tailscale peer path from DERP relay. If relayed, record the
relay proof; if direct, record VPN reachability and flag relay proof as unmet for
owner review. Neither Wi-Fi location nor a tailnet IP proves relay. No automatic
UDP block or NAS network/service/reboot change is selected, and no network check
runs as part of this drafting task.

Continue the real-use Git/Nix/editors/AI/tmux/tunnels/suspend/reconnect/network
checklist. Once final release checks pass, A presents the prepared named Mac
and QNAP windows under D5 and waits for the user's choice before maintenance.

**Production:** D3 retains the original 29 September → Tuesday 6 October week;
D7 fixes operating configuration and default access. Review readiness on
6 October only if exact final-release evidence is complete: gates, real use,
relay, backups/isolation and health. Record which SHA/generation was exercised
and why it is ready. No minimum additional soak is invented; postpone if evidence
is incomplete, without automatically resetting a seven-day clock. `dx-qnap` gets distinct keys,
names/volumes/state, tailnet-only port 2223, verified backup/restore and selected
resources/policy. Switch daily `qx` to production after validated cutover, keeping
explicit `QX_PROFILE` selection available. Production creation/cutover needs the
prepared final acceptance go;
choosing policy while drafting does not schedule it. Keep `dx-host` intact.
Canary retirement and moving production back to port 2222 are later decisions.

**Production (2026-10-03 evening):** D3 closed early by the user's
sign-off on day 5 (relay waived, recorded as not met); D7 executed —
`dx-qnap` created, populated from the canary by the cross-profile restore
and verified, `dx-ai` live inside it; the canary remains the fallback. The
user's `qx` now lands on production (`QX_PROFILE=qnap`, 2026-10-03 evening);
the canary's retirement and the port-2222 return are the remaining operator
decisions.

## 6. Document disposition, residual work and completion

**Backlog status (2026-10-03):** the cosmetic items, the behavioural
hostname check, the live-tail guards and the hermetic-isolation fixes are
landed (`docs/evidence/20261003/`), and the harness now runs the full live
tier on both runtimes — Apple on `dx-test`, docker-ssh on a disposable
spike — with the unit files' live tails included. Remaining residual work
is the post-Phase-7 plan housekeeping named below and the optional Mac key
relocation.


D8's artifact policy is settled: this sanitized `2-oct-plan.md` is indexed once
under **Partially complete** in `plans.md`. The six originals
(`1-oct-a.md`, `1-oct-b.md`, `1-oct-c.md`, `1-oct-plan-a.md`,
`1-oct-plan-b.md`, `1-oct-plan-c.md`) have been relocated to the private archive
`~/dxe-recovery/20261002/plan-consolidation/`. The consolidating session verified
all six exact file contents before removing the original copies; directory mode
is 700 and file modes are 600. Source references are plain filenames,
not public-clone links to private originals.

The root-document contract explains this disposition: Section 10 scans **untracked
as well as tracked** root Markdown except `README.md`, `constitution.md`,
`plans.md`; simply keeping notes untracked does not avoid failures. Preserve
private originals outside the repository before removing relocated root copies,
as completed above.
Do not copy private values into published provenance; local-only originals/parent
paths must not become public-clone links.
Run developer-tree and clean-candidate doc checks after disposition. Do not
silently exempt all dated files or delete originals to make the suite green.

After Phase 7: close WP9.1, update plan ownership/triggers and retire obsolete
consolidation narrative with history retained. Reconcile stale WP5.2/WP8.1
checkboxes with actual implemented phases; coverage-first D-1 is already executed.
Keep Q7's unadopted large proposals and optional Mac-key migration deferred as in
the previous plans; accepting either would be a separate scope decision.
Retain owned follow-ups for tmux-resurrect polling/stability, Apple keyring-warning
fixture, Section 27 stdin hang, raw-login hm-session-vars ordering, and removal
of the guest-tree compatibility symlink at the next base changeover. WP6.9's
large-restore performance work is landed; update stale progress text.

**Done:** A has the transferred work; B/C closure is confirmed; chosen safeguards
and fixes are reviewed/gated/landed; named guest promotions have verified backups
and recorded results; the actual QNAP release meets D3/D7 and receives its production
decision; and records/artifacts match that outcome without private data or lost
originals. Policies and archival are complete; remaining evidence, implementation,
session handoff and maintenance gates are not claimed complete.

Evidence: inspect current main's `findings.md` landing entry,
`docs/evidence/20261001/live-gate.md`,
`docs/evidence/20260928/qnap-promotion.md`,
`docs/evidence/20260930/coverage-ratchet-history.md`, and
`docs/refactor/validation-matrix.md`. Shared-checkout copies can be stale; use
`git show main:<path>` until working from the clean selected release. Private
ledger/logs remain under `~/dxe-recovery/`. Runtime/network validation and
implementation have not run during consolidation. Only documentation contracts
ran: `bash tests/test_section10_docs.sh` passed **170 checks, 0 failed,
0 skipped (exit 0)** after private archival, in the current developer working
tree. This does not certify a clean merged implementation candidate or full suite;
no guest, network or runtime implementation actions ran.
