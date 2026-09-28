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
