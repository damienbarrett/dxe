# Live tails never reach a guest on their own, and never the default guest (`fix/live-tail-guards`) — evidence

Background: eleven unit-tier suites end with a live tail (`requires_container`,
`wait_for_ssh`, then real `dx-ssh` work). `tests/run.sh` already forces
`SKIP_INTEGRATION=true` unless `--live` is given, but a file invoked directly
inherited the variable unset, treated that as "live allowed", and with no
profile selected targeted the registry defaults — the operator's primary
guest on `localhost:2222`. On 2026-10-02 a subagent invoking section 17
directly reached that guest's sshd (closed at pre-auth only because its
worktree had no key).

## What changed (one increment per commit, red before green)

| Increment | Behaviour | Red → green |
| --- | --- | --- |
| unset means skip | `live_tail_enabled` (`tests/test_helpers.sh`) succeeds only when `SKIP_INTEGRATION` is exactly `false`; `requires_container` and `wait_for_ssh` consult it first; the 13 top-level checks in 11 suites use it; the skip names the sanctioned invocation | Section 20: 10 red → green; direct runs of sections 17, 7 and 4 with the variable unset call no container, ssh, scp or dx-ai stub |
| never the default guest | when enabled, a tail whose `DX_CONTAINER_NAME` or `DX_SSH_PORT` equals the registry default (read from the registry via `tests/lib/registry-defaults.sh`) fails with a clear message and calls nothing; the `dx-test` fixture passes | Section 20: 3 red → 38 green; `tests/run.sh --live` with no profile refused |
| runbook notes | post-backup dry-run transients (SQLite `-wal`/`-shm`) and the selector's "`.git` is a file" warning explained | docs only |

## Gates

| Gate | Result |
| --- | --- |
| Section 20 and every changed suite (`SKIP_INTEGRATION=true`), Sections 9 and 10, refactor contracts | green |
| bash 3.2 | all passed |
| fresh clone in Ubuntu 24.04, no state directory | all passed (the lint section self-skips on a non-pinned ShellCheck, by design) |
| pinned ShellCheck 0.10.0, CI file set | clean |
| kcov coverage | 100%; scope 4,194 ≥ 3,935; unscoped 2,629 ≤ 2,635 (ratchet untouched) |
| `nix flake check` | passed; `flake.lock` unchanged |

## Live gate — Apple, coordinating session, clean clone of the rebased tip

| Step | Result |
| --- | --- |
| guard proof on the real controller: section 17 run directly, no profile, `SKIP_INTEGRATION` unset | section 17 direct: skipped its tail (rc=0), no 'Waiting for guest bootstrap' line -> dx-host never contacted |
| sanctioned path: `./bin/dx-profile dx-test tests/run_all_tests.sh --live` | live tier: 45 suites, 2595 passed, 0 failed, 94 skipped; see log |
| cold stop | clean |
