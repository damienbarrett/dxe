# The live tier on both runtimes, and the remaining backlog (`fix/harness-live-tails-and-cosmetics`) — evidence

Eight increments, one commit each, red before green, by a Sonnet subagent
against fakes; reviewed, live-gated on both runtimes and landed by the
coordinating session. This is the first time the harness itself has driven
a full live tier against a docker-ssh guest.

## What changed

| Increment | Behaviour |
| --- | --- |
| the "everything" run really runs everything | `tests/run_all_tests.sh --live` now runs the unit tier with `--live` too, so the eleven unit files' live tails (sections 4, 5, 6, 7, 8, 14, 15, 16, 17, 19, 23) execute against the selected guest; they had been skipped under the live tier (94 skips every run) |
| `dx`/`dx-ssh` with no terminal | one non-interactive `true` over SSH and a one-line note instead of the failing tmux attach |
| quiet raw SSH logins | `TMUX_TMPDIR` uses an absolute `id` (Home Manager's own default used a bare `$(id -u)` before PATH was set); evaluated by Section 15 |
| behavioural hostname check | section 4's live tail asserts `/etc/hostname` and `uname -n` equal the container name on whichever guest the tier targets |
| runtime-neutral live helpers | `requires_container`, `container_exec_dx` and the SSH endpoint go through the runtime adapter (`dxe_runtime_call`); Apple-only cases skip with a message under docker-ssh |
| inner-runner isolation | inner `tests/run.sh` / `run_all_tests.sh` calls start from a clean `SKIP_INTEGRATION` |
| hermetic cases never inherit a profile | `tests/lib/inherited-config.sh`: the shared helpers save and unset any inherited configuration snapshot at source time (scrub list derived from the registry); `live_tail_enabled` restores it only for the live tails; `dxe_enter_hermetic` drops it again — default-deny, so a future suite cannot leak |
| no failure can hide | `print_summary` names every failure recorded in the results file, so a `test_fail` inside a discarded capture still prints |

## Container-free gates (subagent; coordinator re-read the logs)

fresh clone in Ubuntu 24.04 with no state directory: all passed (lint section
self-skips on the non-pinned ShellCheck, by design); pinned ShellCheck 0.10.0:
clean; kcov: 100%, scope 4,195 ≥ 3,935, unscoped 2,635 ≤ 2,635 (at the
ceiling, not over; ratchet untouched); `nix flake check --all-systems`:
passed, `flake.lock` unchanged; bash 3.2: passed.

## Live tier — Apple (`dx-test`), final tip, clean clone

| Step | Result |
| --- | --- |
| guard proof: section 17 run directly, no profile, variable unset | section 17 direct: skipped its tail (rc=0), no 'Waiting for guest bootstrap' line -> dx-host never contacted |
| `./bin/dx-profile dx-test tests/run_all_tests.sh --live` with the unit tails enabled | live tier: 45 suites, 2737 passed, 0 failed, 84 skipped — section 17's in-guest `dx-ai` ran and passed |

## Live tier — docker-ssh, disposable `dx-qnap-spike6`, canary live and untouched

| Step | Result |
| --- | --- |
| first `dx` of the never-created profile | spike6 up in 147 s; `/etc/hostname` = the container name |
| `./bin/dx-profile qnap-spike6 tests/run_all_tests.sh --live` | live tier: 45 suites, 2705 passed, 2 failed, 89 skipped |
| the two failures | section 17's in-guest `dx-ai` refused to build `herdr` from source — the x86_64 `nixpkgs-unstable` binary cache lagging the lock refresh (environmental; remedy: wait, or `DX_AI_ALLOW_SOURCE_BUILDS=1`); and the Section 20 hidden refusal fixed by the last increment (test-only, so the run was not repeated) |
| factory-reset | clean; final inventory the canary and its three volumes; no lock containers |

The first docker-ssh run, before the isolation increments, had 64 failures;
every one was a hermetic unit suite inheriting the exported docker-ssh
profile and bypassing its fakes (some reaching the real adapter over
management SSH; the characterisation suite's create/destroy pairs were
self-contained, and the NAS audit afterwards found no leftovers). None was a
docker-ssh behavioural difference. Live tails that passed on docker-ssh:
sections 4 (including the hostname assertion), 5, 6, 7, 8, 11, 12, 14, 15,
16's live part and 19's reverse-tunnel round trip.

Still skipped by design on the Mac controller (~85): cases needing `nix`
locally (covered by the Nix and container gates), root plus `setpriv`
(covered by the kcov runner), the pinned ShellCheck (its own gate), the
opt-in tmux-resurrect round trip, and Herdr when it is not installed in
the guest.
