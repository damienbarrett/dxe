# Read-only reconnect, profile pin and fixture isolation (`feat/dx-reconnect-readonly`) — evidence

Sanitised record for `2-oct-plan.md` step 2 (and its D1 policy). No
home-directory paths, real profile values, hostnames or addresses appear
below.

## Origin

The branch starts from a byte-for-byte transfer (`c1343fe`-era commit) of
work another session had left uncommitted in the shared checkout after the
1 October canary incident: `dx` connects without publishing when the guest
is already running, a bounded service-readiness wait
(`DX_SYSTEM_WAIT_TIMEOUT`), profile-preserving restart guidance, XDG profile
lookup in `dx-profile`, `bin/qx` and its contract test. Reviewing it found
two regressions its own validation had not run into: `dx` under docker-ssh
no longer refused while the lifecycle lock was held, and the unmeasured
entry-point line count had grown past the coverage ceiling. Both are fixed
on this branch rather than waived.

## What landed (one increment per commit, red before green)

| Increment | Behaviour | Red → green |
| --- | --- | --- |
| `DX_PROFILE_ROOT` pin | optional registry field (kind `optpath`); a profile that sets it refuses, before any side effect, unless the canonical checkout equals the pin (exit 2, holder of the pin printed); the value is validated data and travels in the snapshot | Section 9: 6 failing cases ("unknown configuration field") → 180 green |
| lifecycle lock on reconnect | the lock brackets only the ownership decision (acquire → owned check → release → `exec dx-ssh`); a held lock refuses with the holder printed; nothing is created or synced | `test_docker_adapter_lock` / `test_docker_runtime_adapter` red under bash 3.2 → green; `test_qx` 21 incl. a held-lock case |
| fixture isolation | `tests/run.sh` exports `DX_PROFILES_DIR=tests/profiles` (overriding a caller) and fails closed when it is missing, so a personal `dx-test` profile can never shadow the fixture | Section 9: 3 red → 183 green |
| `QX_PROFILE` | `bin/qx` selects its profile through the shared name validator, default `qnap-canary` | contract cases red → green |
| `qx` in the inventories | Section 9, Section 10 and the coverage metric's production set include `bin/qx` | inventory cases red → green |
| moved into covered libraries | the connect-or-bring-up decision (`dx_connect_or_bring_up`), the profile lookup/pin/apply helpers and `dx_qx_profile` live in `bin/lib` with direct unit tests (`tests/test_entrypoint_decisions.sh`); the entry points are a call each | unscoped production lines 2,685 → 2,603 (ceiling 2,635), scope 4,059 (floor 3,935), 100% covered |
| docs and examples | QNAP example profiles show absolute key-path placeholders and the pin; runbook, configuration, lifecycle, troubleshooting and README describe the final behaviour; a comment in the library notes the three remote round trips a docker-ssh reconnect costs and why the ownership check stays | Section 10 green |

## Gates (container-free, subagent; coordinator re-checked the logs)

| Gate | Result |
| --- | --- |
| affected suites after every increment | green (Section 9 183, state machines 166 with the 40-field registry, Docker health 50, qx 21, entrypoint decisions) |
| bash 3.2 (`tests/run-bash32-tests.sh`) | all passed |
| fresh clone in a throwaway Ubuntu 24.04 container, no state directory | suite exit 0 (lint sections ran) |
| pinned ShellCheck (0.10.0) on the CI file set | clean |
| kcov coverage | covered 100%; scope 4,059 ≥ floor 3,935; unscoped 2,603 ≤ ceiling 2,635 (ratchet file untouched) |
| `nix flake check` on `container/dx-nixos-26.05` | exit 0; `flake.lock` unchanged |

## Live gate — Apple (`dx-test`), coordinating session, clean clone of the rebased tip

| Step | Result |
| --- | --- |
| start + `dx-wait-ssh` | ready after 13 s |
| `dx` on the running guest | reached the guest (`DX_RECONNECT_OK`), no "Syncing bootstrap"/"Bringing up" output; generations unchanged across dx reconnect |
| full live tier (`tests/run_all_tests.sh --live`) | 45 suites, 2520 passed, 0 failed, 94 skipped; live tier rc=0 after 890 s |
| cold stop | clean |

The QNAP side was not exercised by this branch (no lifecycle command runs
against the NAS outside a user-named window, 2-oct-plan.md D5); the
docker-ssh behaviour is covered by the fake-boundary suites, and the real
canary's own profile now carries the pin privately.
