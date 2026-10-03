# QNAP promotion and maintenance proof (Branch 11 / Phase 7, `feat/qnap-promotion`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 7 and
`checkout-consolidation-plan.md`'s Branch 11. No home-directory paths, keys,
fingerprints, daemon IDs, NAS hostnames or addresses appear below; the NAS's
addresses are written as `<tailnet address>` and `<LAN address>`.

Branch `feat/qnap-promotion`, from `main` `3606cd9` (Phase 6 landed),
rebased onto `4517c58` before landing (no conflicts). Implemented by a
Sonnet subagent against fake `ssh`/`docker` boundaries only, in short
increments with a hand-back after each; designed, reviewed, gated and
landed by the coordinating session. Design: `docs/refactor/qnap-promotion.md`.
This record is appended to as the live steps run during the canary week.

## User decisions (2026-09-28)

1. Phase 7 proceeds now. 2. Canary `dx-qnap-canary`: SSH on the NAS's
Tailscale address at port 2222, `unless-stopped` from day one, 8 GB / 2 CPU
(a per-profile choice; the checked-in example keeps 4 CPU), one-week
acceptance starting the day it is created; created as soon as this code
lands on `main`. 3. Production port 2223 for the cutover, explicitly
temporary. 4. Pre-approved for the week: the disposable restore-drill
profile `dx-qnap-drill` (port 2224), created and destroyed with a warning
before each; a disposable `dx-qnap-spike2` for the destructive-lifecycle
check; one rebuild-and-recreate of the canary at an idle moment; `dx-host`
promotion #8 after landing, guest idle first. 5. The relay-fallback check
uses a genuinely restrictive network first, a controller-side UDP block
only as a fallback. 6. No history rewrite for the two home-directory paths
that had reached the public repo with Phase 6 (removed the same evening).

## What changed

- **Restore isolation (item 3):** `dx-restore --source-container=NAME`
  reads another profile's mirror while always writing into the current
  profile's own guest; validated with the existing container-name rule,
  announced with an explicit banner, fail-closed on a missing mirror; the
  default path is byte-identical to before, so a plain `dx-restore` never
  crosses profiles. `dx_backup_resolve_dir` gained an optional override
  argument; docker-ssh's host-identity segment still comes from the current
  profile (no cross-host restore). Eight fake-based cases, red before green.
- **Canary procedure (items 1, 2, 4, 5):** `docs/qnap-runbook.md` section 9:
  the daily-use exercise list, the relay-fallback observation (before/after
  `tailscale status` and `tailscale ping`, `dx-status`/`dx-ssh` unchanged
  while relayed), the rebuild-and-recreate step through `dx-recreate` with
  its before/after evidence, the destructive-lifecycle reaffirmation on
  disposables only, the restore drill with its ownership and mode spot
  checks, and the evidence shape (this file).
- **Canary example profile:** `tests/profiles/qnap-canary-example.env`
  (placeholders only). The production example now documents port 2223.
- **Exit-gate inventory (item 6/7 and the gate's wording):** three genuine
  temporary compatibility exceptions given an owner and a removal condition
  (the runtime-boundary audit exception, the deferred Tailscale-in-guest
  spike, the pending context-tree rename); three candidates recorded as not
  exceptions. Item 7 (`dx-host` stays intact) restated as an unconditional
  constraint.

## Gates (container-free, coordinating session, rebased tip)

| Gate | Result |
| --- | --- |
| ShellCheck (pinned 0.10.0; apt 0.9.0 in throwaway `ubuntu:24.04`) | clean (0.9.0 on the whole CI file set of the rebased tip) |
| Container-free suite on Linux from a fresh git clone, no state directory | 32 sections, 1918 passed, 0 failed, "All tests PASSED!" (state directory absent, as on CI) |
| bash-3.2 | 8 files, 734 passed, 0 failed (clean export of the rebased tip) |
| Coverage (`tests/run-coverage-linux.sh`, isolated kcov runner) | `covered=100% scope_share=20.97%` on the rebased tip; ratchet lowered 2105 → 2097 by the subagent for Increment 1's test dilution (scope 7,544 / total 35,967), confirmed by re-measurement on a clean export |
| Sections 1, 9, 10, 27, 31, 32, 33 | green bare and under the profile (subagent), Sections 1 and 10 again at landing |
| Private identifier scan | clean at the landing tip, run inside the branch worktree (the scanner now names the tip it scanned) |

## Live gate — Apple (`dx-test`)

Run by the coordinating session from a clean clone of the branch tip, stdin
from `/dev/null` throughout. The first pass covered 31 sections (1590 tests,
0 failures) before the restore file's 60,000-entry performance section
crawled under a controller load average near 300 from an unrelated batch;
the gate's time limit cut that pass with no test failed. With the batch
paused, the remaining four files ran under the profile to completion.

| Step | Result |
| --- | --- |
| cold start + `dx-wait-ssh` | ready in 19 s |
| `dx-status` on a healthy guest | the health lines stayed silent; `SSH Port … is OPEN on 127.0.0.1` |
| `dx-restore --dry-run` (no flag) | unchanged behaviour |
| `dx-restore --source-container=<nonexistent> --dry-run` | banner printed, then refused with the no-mirror error; guest untouched |
| live tier, first pass | 31 sections, 1590 passed, 0 failed |
| live tier, remaining files under the profile | 4 files (the restore file, characterisation, boundary audit, Docker adapter), 267 passed, 0 failed |
| cold stop | clean |

Lesson: a live tier shares the controller with whatever else runs there;
the gate now records the load and is re-run rather than judged when an
unrelated batch starves it.

## Landing (2026-09-28)

Rebased once onto `main` `4517c58` after the subagent's hand-back, with no
conflicts; every commit's delta identical before and after (only `main`'s
own promotion-record and home-path-fix lines differ). Ratchet 7,544 /
35,967 → 2097 bp, re-measured on a clean export of the rebased tip;
`covered=100%` confirmed in the isolated runner. Pre-push scan run inside
the branch worktree against its own tip (the scanner now scans the
repository it runs in, after the Phase 6 miss), clean. Landed by
fast-forward after CI. The code is on `main` before any live step: the
canary is created from it, so every command it runs is the landed code.

## Live steps (appended during the canary week)

Order, per the plan's Phase 7 status: 1 create the canary; 2 the week of
real use with the runbook's checklist, including the relay-fallback
observation; 3 image rebuild + `dx-recreate` at an idle moment; 4 the
restore drill into `dx-qnap-drill`; 5 the destructive lifecycle on
`dx-qnap-spike2`; 6 the production profile once the week passes; 7
`dx-host` intact throughout.

### Step 1 — canary created (2026-09-29, day 1 of the acceptance week)

Created from the landed code (`main` `8fba879`) with the local profile
copied from `tests/profiles/qnap-canary-example.env` and a key pair
generated for it; nothing of ours existed on the NAS beforehand (the
managed-label filters were empty).

| Check | Result |
| --- | --- |
| first boot to SSH | 160 s (native x86_64 bootstrap) |
| container | running, restart count 0, policy `unless-stopped`, 2 CPU / 8 GB, health check configured |
| binding | `2222/tcp` on `<tailnet address>` only; NAS listener on that address only; a LAN-side connect from the NAS to `<LAN address>:2222` refused |
| `dx-ssh` | `SSH_OK`, `x86_64`, user `dx`; running generation equals published |
| `dx-status` | SSH section on the tailnet address; `keyring: not running` (fresh guest, expected) |
| Docker health after one minute | `healthy` (Phase 6's health check, live for the first time on a real guest) |

The week's exercise list is `docs/qnap-runbook.md` section 9; entries for
the exercised items, the relay-fallback observation, the rebuild and
recreate, the restore drill and the spike lifecycle follow below as they
happen.

### Step 3 — image rebuild + `dx-recreate` (2026-10-01, day 3)

Run by the coordinating session from a clean clone of `main` `4e8c5cc`
(the canary profile and key pair copied in), stdin from `/dev/null`
throughout, at a moment the canary was idle: no established connection to
its port on the NAS, no logged-in user, guest load average below 1. Runbook
section 9.2, no pin change (same `main` the canary was built from, so
`dx-recreate` rather than the "MIND THE PIN" branch). Immediately before
the recreate a fresh `dx-backup` of the canary was taken (1,450 files,
104 MiB; the following dry-run reported 0 files to transfer), which is
also the restore drill's step 1.

| Check | Before | After |
| --- | --- | --- |
| container | running, restart count 0, `unless-stopped`, 2 CPU / 8 GB, `healthy` | same; `healthy` again 60 s after start |
| binding and labels | `2222/tcp` on `<tailnet address>` only; managed/profile/role/schema/system labels | unchanged |
| `DX_IMAGE_IDENTITY` | `sha256:ca0b6c21…` | `sha256:ca0b6c21…` (see note) |
| bootstrap generation | running = published `20260928T181516Z-37816` | same; the host-side sync reported "Bootstrap content is unchanged; generation … stays current" |
| `dx-backup --dry-run` | 0 files after the fresh backup | 1 file, 0 bytes (`.config/herdr/.dxe-persistence-ready`, a boot marker) — `/persist` content unchanged |
| `dx-ssh` right after the recreate | — | `SSH_OK`, `x86_64`, `dx`; **no host-key mismatch warning**, no `ssh-keygen -R` needed (the expectation in 9.2, now verified) |
| `dx-status` keyring line | `live` | `stale` until `dx-keyring start` (idempotent), then `live` |
| `dx-recreate` wall clock | — | 34 s from `dx-destroy` to "Guest is ready" (image layers cached on the NAS; base image "up to date") |

Notes. (1) The image identity did not change: with the pin and the
context tree unchanged, the NAS's build cache reproduced the identical
image, so "identity changed" in 9.2 is only observable when the build
inputs change — the check that matters held (the sync compared the
identity and the bootstrap content and correctly left the generation
alone). (2) The `keyring: stale` after a recreate is the same behaviour
`dx-host` promotion #8 recorded on Apple ("before dx-ai: stale", live
after `dx-ai`); the guest keyring is started by `dx-ai`/`dx-keyring
start`, not by boot, so a recreate always shows it stale until first use.
(3) `dx` ends by attaching the guest tmux session; under stdin from
`/dev/null` that prints "open terminal failed: not a terminal" and
"duplicate session: dx", cosmetic only.

Recorded once for the week's final validation: NixOS release pin
`nixos-26.05` (`nixpkgs`), `nixpkgs-unstable`, Home Manager
`release-26.05`; base image `nixos/nix:2.34.7` at digest
`sha256:bf1d9388…`; `DX_IMAGE_IDENTITY` before and after the rebuild as
above.

### Step 5 — destructive lifecycle on a disposable, canary live (2026-10-01, day 3)

Runbook section 9.3, run by the coordinating session from a clean clone
of `main` `4a1e3ce`, stdin from `/dev/null`, with `dx-qnap-canary`
running (healthy, restart count 0) throughout. A disposable
`dx-qnap-spike2` profile (own names, own key pair, port 2225, policy
`no`, 8 GB / 2 CPU) was created, destroyed through the immutable
ownership plan, and its resources confirmed gone; the canary's container
and three volumes were the only managed resources on the NAS before,
during (alongside the spike's) and after.

| Step | Result |
| --- | --- |
| `dx-create-keys`, `dx` (image from the cached layers, volumes, container, start, `dx-wait-ssh`) | ready in 195 s; `SSH_OK`, `x86_64`, user `dx` |
| inventory with the spike live | containers: spike2 and canary; volumes: three per profile; canary `running/healthy/restarts=0` |
| `dx-stop-container`, then `dx-factory-reset --force` under the spike profile | the immutable plan printed first (container and three volumes, each `labels=true|1|<host>__dx-qnap-spike2|<role>`), then the container, image, the three volumes and the key pair removed; "Factory reset complete." |
| inventory after the reset | only the canary's container and volumes; canary `running/healthy/restarts=0` |
| negative case: an **unlabelled** volume created under the spike's nix-volume name, then `dx-destroy-volumes --force` | refused: "it exists but is unlabelled or labelled for a different profile/role … this is a collision, not an adoption candidate", then "refusing to destroy any volume"; the unlabelled volume still existed afterwards (zero deletes); removed by hand |
| leftovers | no spike2 image tag, no spike2 local state, profile and keys removed from the clone; final inventory identical to the initial one |

No command in this step named the canary; the misnamed-target case used
the spike's own name deliberately, since a profile that reused the
canary's container name would resolve to the canary's own labels and is
exactly what "never run any destructive command against the canary"
forbids.

### Step 4 — restore drill into `dx-qnap-drill` (2026-10-01, day 3)

Runbook section 9.4, run by the coordinating session from a clean clone of
`main` `74f6427`, stdin from `/dev/null`; the user gave an explicit go
before the drill's creation and another before its destruction. The drill
profile was disposable (own names, own key pair, port 2224, policy `no`,
8 GB / 2 CPU) and ran alongside the live canary.

| Step | Result |
| --- | --- |
| fresh `dx-backup` of the canary | 2 changed files since the morning's backup, 69 bytes |
| `dx-create-keys`, `dx` for the drill | ready in 144 s; `SSH_OK`, user `dx` |
| plain `dx-restore --dry-run` under the drill (no flag) | refused: no backup mirror for a fresh profile, as designed |
| `dx-restore --source-container=dx-qnap-canary --dry-run` | banner printed ("Restoring dx-qnap-canary's backup into dx-qnap-drill (cross-profile restore).") |
| `dx-restore --source-container=dx-qnap-canary` (no `--force`) | **refused**: one target already existed and differed, `home/dx/.config/herdr/config.toml`, seeded by the fresh guest's own bootstrap |
| the same with `--force` (disposable target only) | 93 s; the restore's `chown` warned once about a dangling symlink (`…/dx-ai/generations/<id>/profile-1-link`) |
| dry-run after the restore | banner; 1,450 targets "already identical"; 0 would create or update |
| ownership | no entry under `/persist` (outside the root-owned `/persist/etc`) that is not `dx:dx` |
| mode spot checks against the canary | `/persist/home/dx`, `/persist/git`, `.config` 755; `keyring-address` and `herdr/config.toml` 600 — all equal; **`.local/state/dx` 755 on the drill, 700 on the canary** |
| content | 1,205 of the drill's 1,441 regular files under `/persist/home` byte-identical with the live canary; the rest are tool state the canary changed after the backup (gh, codex and herdr configuration), and the canary's own cache trees the selector never backs up |
| teardown (second go) | `dx-factory-reset --force` under the drill profile: immutable plan, container, image, three volumes and key pair removed; final inventory = the canary and its three volumes, canary `running/healthy/restarts=0` |

Findings, none blocking, carried as follow-ups: (1) a restore into a
fresh guest needs `--force` for the bootstrap-seeded herdr configuration,
which section 9.4 should say; (2) `dx-restore` recreates a missing
directory with the default mode (755) rather than the mirror's (700 for
`.local/state/dx`) — file modes are preserved, directory modes are not;
(3) the restore's ownership pass should use `chown -h` so a dangling
symlink does not warn; (4) macOS `tar` adds `LIBARCHIVE.xattr` extended
headers the guest's tar ignores noisily (cosmetic). With this drill the
canary's `/persist` backup counts as **verified** (section 9.5's
qualifying event).

### Incident and correction — a non-`main` bootstrap published into the canary (2026-10-01)

At 13:55:58 NZDT, while the drill was being created, a bring-up under
the canary profile ran from the shared development checkout, which was on
a work-in-progress branch, not `main`. It wrote the branch's own
volume-claim cache entry for the canary's nix volume and published the
branch's bootstrap tree into the canary as generation
`20261001T005602Z-31314` (70 files, byte-identical to that branch's
guest tree; `main`'s is 60 files). The canary kept running its original
generation, SSH and the keyring were unaffected, but Docker reported it
`unhealthy` (the health check requires an execution lease for the
*published* generation) and its next restart would have booted unvetted
content. The coordinating session's own drill ran from a clean clone of
`main`; the drill guest's generation carries the canary's original
digest. The other Claude session working in that checkout confirmed it
ran nothing against the NAS; the remaining candidate is an agent session
the user had started in that checkout two minutes earlier.

Correction, each step after the user's go: `dx-sync-bootstrap` from the
clean clone re-published `main`'s content (generation
`20261001T045637Z-17556`, the original digest); `dx-start-container`
**skipped** the running container ("already running; skipping start"),
so `dx-stop-container` then `dx-start-container` were run: 37 s to
"Guest is ready", Docker health `healthy` again within 60 s, restart
count still 0, keyring started and live. The branch generation remains
on the volume, unreferenced.

Findings: (5) `dx-status`'s drift advice ("Run dx-start-container again
to pick it up") is wrong for a running container, which that command
deliberately skips — it should say stop then start, or the command
should restart; (6) **docker-ssh lease pruning**: after the restart
`dx-status` still reports the old running generation because the
previous incarnation's PID-1 lease survives — the unchanged-content
prune keys on `/proc/sys/kernel/random/boot_id`, which inside a Docker
container is the NAS kernel's boot id and does not change across a
container restart (it does on an Apple VM), and
`dx_bootstrap_lease_generation` returns the first `.1` lease it sees;
the Docker health check, which looks for the *current* generation's
lease, is right and the drift warning is false; (7) operationally, the
real profile and key pair of a production guest must not live in a
checkout that moves between branches — a `main`-only checkout for live
QNAP work is now the rule for the coordinating session, and the same is
recommended for the operator's own daily use.

### Week step 2 — off-home network observation (2026-10-02, day 4)

Read-only, no lifecycle command, from the coordinating session's clean
clone of `main` `1f287f8` on the user's work Wi-Fi (a network outside the
home LAN; the user had reported it as restrictive). Runbook section 9.1's
relay-fallback observation requires the before/after pair; the "before"
is the home-LAN direct path recorded the previous evening.

| Check | Result |
| --- | --- |
| `tailscale status` (NAS peer line) | peer listed, no active direct-connection annotation before traffic |
| `tailscale ping` (4 requested) | one pong, **direct**, via a public endpoint (not a LAN address), 12 ms; the ping stops at the first direct response |
| `tailscale netcheck` | UDP reachable, IPv4 yes, IPv6 no, port mapping varies by destination, nearest DERP Sydney |
| `dx-status` under the canary profile over that path | container `healthy`, up 19 h, SSH port open on the tailnet address, `keyring: live`, remote lock not held; 9.9 s wall clock |
| `dx-ssh 'uname -m; uptime'` | `SSH_OK`, `x86_64`, guest up 3 days 19 h, 0 users, load 0.08; 2.2 s wall clock |

Conclusion, recorded as observed: **off-home reachability through
Tailscale is proven** (the canary is reached from a foreign network with
the profile's unchanged tailnet-address bind, nothing published or
changed); the **DERP-relay fallback is not yet exercised** — this network
allowed UDP hole-punching, so the path stayed direct. Per the user's
decision D4 (2026-10-02) no artificial UDP block is used; the relay proof
stays open until a network that forces the relay turns up, and is flagged
for owner review at the production decision.

### Day 4 maintenance — the canary moves to the final release (2026-10-02, evening)

Inside the user's named QNAP window (2-oct-plan.md D5), from the
coordinating session's clean clone of `main` `00b67d0`, canary idle (no
established connection, no user).

| Step | Result |
| --- | --- |
| `dx-sync-bootstrap` first (non-activating) | published generation `20261002T093725Z`; running unchanged — ordered this way because `dx-backup` runs the guest's *published* selector and the old one lacked directory-mode support |
| `dx-backup` | legacy mirror migrated in place (`current -> generations/…`, manifest and `dirs.tsv`), 468 files / 44 MiB; the selector skipped the root-owned top-level `/persist/etc` with a named warning |
| `dx-restore --dry-run` | 1,705 identical, 0 would create, 0 directory-mode conflicts |
| stop/start | ready in 30 s; running = published; **no drift warning** — the stale previous-incarnation lease is pruned on docker-ssh now, which is the lease fix observed live; the two unreferenced older generations were retired from the volume |
| health, keyring | `healthy` at +60 s, restart count still 0; keyring started, `live` |

From this point the week soaks `main` `00b67d0`, the release the day-7
decision will consider. Two things did not go to plan the same evening and
are recorded honestly: (1) the disposable `dx-qnap-spike3` meant to prove
the lease fix across a Docker restart could not be created — the lifecycle
lock container is built from the profile's own image, which does not exist
for a never-created profile, so the first `dx` of any new docker-ssh profile
refuses ("may already be held"); a fix branch is in progress and must land
before the production profile is created, and the spike proof follows it;
(2) the first attempt ran the backup before the sync and failed closed on
the old selector ("refusing to publish an incomplete record"), leaving the
mirror untouched — the order above is the correct one and is now the rule
for every guest update.

### Day 4, late — disposable spike proofs of the two docker-ssh fixes (2026-10-02, 23:51–23:55)

Inside the same user-named QNAP window, from the coordinating session's
clean clone of `main` `b4c4b0d` (which carries the lock-image fix landed
minutes earlier), with the canary live throughout and the only managed
resources before and after being the canary and its three volumes.

| Step | Result |
| --- | --- |
| first `dx` of the never-created disposable `dx-qnap-spike3` (port 2225) | the lifecycle lock was acquired from the pinned base image and released; keys, image, volumes, container, start, `dx-wait-ssh`; guest reached (`x86_64`) in 185 s — **lock-image fix proven**; no lock container left behind |
| Docker restart of the spike (`dx-stop-container`, `dx-start-container`) | ready; `dx-status` running = published `20261002T105121Z`, **no drift warning**; exactly one execution lease on the volume (the previous incarnation's PID-1 lease was pruned although the kernel boot id is the NAS's and unchanged) — **execution-lease fix proven on docker-ssh** |
| `dx-factory-reset --force` on the spike | immutable ownership plan, container, image, three volumes and key pair removed; canary `running/healthy/restarts=0`; no lock containers |

With this, every item the plan's D2 required before real-guest
publication has both its gates and its live proof, and the canary's own
restart earlier the same evening showed the same lease behaviour on the
real guest.

### Day 5 — sign-off and the production profile (2026-10-03)

The user signed off the acceptance period on day 5 rather than day 7
(decision D3 was the owner's to revise): the canary had run the final
release for about 42 hours with restart count 0 and no drift, both
runtimes had passed their full live tiers that day
(`docs/evidence/20261003/live-tier-both-runtimes.md`), the backup was
verified by the restore drill, and the relay-fallback check was waived by
the user on 2026-10-03 ("working on the public networks that are most
important to me; revisit later if needed") — recorded here as **waived,
not met**. Soak note: the canary soaked `main` `00b67d0`; production was
created from `main` `5b8d4f3`, whose only guest-affecting additions (the
docker-ssh hostname and lock-image fixes) had been proven live on
disposable spikes the same day.

**Production profile `dx-qnap`** (decision D7): SSH on the NAS's Tailscale
address at port **2223** (temporary, may move back to 2222 once the canary
is retired), `unless-stopped` from creation, 8 GB / 4 CPU, its own key pair
and volumes, hostname `dx-qnap`, the private profile pinned to the user's
main-only checkout.

| Step | Result |
| --- | --- |
| first `dx` of the never-created profile | lock acquired, image from the cached base, up in 147 s; `/etc/hostname` = `dx-qnap`; running, restart count 0, `unless-stopped`, 4 CPU / 8 GB, `healthy`, bound to `<tailnet address>:2223` only |
| first `dx-backup` (fresh guest) | 3 files into a generation-shaped mirror with `dirs.tsv`; dry-run clean |
| cutover: fresh canary backup | 498 files / 39 MiB; the canary's own dry-run 2,039 identical |
| cross-profile restore `dx-restore --source-container=dx-qnap-canary --force` under `qnap` | banner printed; 2,040 files restored in 44 s (`--force` for the bootstrap-seeded herdr configuration, as the drill predicted) |
| verification | dry-run 2,042 identical, 0 would create, 0 directory-mode conflicts; no entry under `/persist` outside root-owned `/persist/etc` that is not `dx:dx`; spot-checked modes equal to the canary's, including `.local/state/dx` at 700 — the directory-mode fix observed in production; both git repositories present |
| `dx-ai` in production | completed in 64 s (the x86_64 binary cache had caught up with `herdr-0.9.1`); D-Bus and the keyring started, `live`; `agy`, `claude`, `codex` resolve |
| final state | `dx-qnap` running = published `20261003T043128Z`, healthy; `dx-qnap-canary` healthy, untouched, kept as the fallback until the user retires it |

The user's daily `qx` was switched to the production profile the same
evening (`QX_PROFILE=qnap` in the shell configuration; a fresh login shell's
`qx` reaches `dx-qnap`, and `QX_PROFILE=qnap-canary qx` still reaches the
fallback). Remaining under D7: the user's later decisions on retiring the
canary and returning production to port 2222.

## 2026-10-04 incident: usage-service enablement crash loop, rolled back

Enabling the usage service on production (`DX_USAGE_SERVICE=on` + `dx-recreate`) crash-looped
the guest for about two hours (03:59 to 06:01 NZDT): the bootstrap never upgraded an existing
guest's essentials profile, so `s6` was missing and the service-on boot failed closed. Rolled
back by recreating with the service off (volumes and keys kept; data verified against the
backup taken minutes earlier). Root cause, fix and upgrade-path proof:
`docs/evidence/20261004/usage-service-host.md`. Lesson recorded: changes to the guest's
essentials closure are proven on an upgrade-path spike, not only a fresh one.
