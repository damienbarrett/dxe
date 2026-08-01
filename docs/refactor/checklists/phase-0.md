# Phase 0 — Freeze behavior at the risky boundaries

**Goal:** make current public behavior reviewable before moving code.
**Owns:** seam 1 (preparation for all five seams).
**Decisions:** [D3](../decisions/D3-ci.md) (minimal job only).

Phase 0 starts with the test harness, not with tests. Every characterization
case below has to be written against *some* harness, and
[`tests/test_helpers.sh`](../../../tests/test_helpers.sh#L17-L29) currently sources
[`dx-lib.sh`](../../../bin/dx-lib.sh#L56-L69), which hard-exits when `container` is
absent. Writing the new cases first and splitting the harness afterwards means
writing them twice. The split is test-only and moves no production file, so it
belongs here rather than in Phase 1b.

## Items

- [x] **1. Rework the test bootstrap before adding cases.**
  - stop sourcing the container adapter from `tests/test_helpers.sh`;
  - put reusable fakes under `tests/lib/` instead of embedding separate copies
    in large section files;
  - remove or correct the dead helpers `assert_true` and `assert_false`
    ([`tests/test_helpers.sh`](../../../tests/test_helpers.sh#L31-L50)), which have no
    callers and would execute their message argument as part of the command;
  - normalize strict-mode declarations, including the `set -uo` in
    [`test_section8_nixvim_config.sh`](../../../tests/test_section8_nixvim_config.sh#L5)
    that prints the shell option table because `-o` has no option name.

- [x] **2. Add the minimal CI job.** `bash -n` over every shell file plus
  ShellCheck, on hosted Linux. This depends on nothing else in the plan and there
  is no `.github/` today, so it gives the cases below somewhere to run as they are
  written. The full matrix is [Phase 1a](phase-1a.md); see [D3](../decisions/D3-ci.md).

- [x] **3. Inventory the 14 current skips.** Classify each as **CI-required** (must
  become a hard failure in Phase 1a), **mac-only** (legitimately unavailable on
  a Linux runner), or **delete**. Record the table in the repository; Phase 1a's
  "no silent skips" gate is checked against it.

- [x] **4. Inventory production-only test seams and command-code boundaries.** The
  baseline is four test-mode branches (`dx-forward`, `dx-reverse`, `dx-mount`,
  and `bootstrap.sh`), not three. Classify every production `sh -c`/`bash -lc`
  use as a fixed program with positional data, an intentional public
  user-command contract, or a Phase 1b/4 replacement under
  [D6](../decisions/D6-command-boundaries.md).

- [x] **5. Record the test-coupling baseline per file.** Count
  `assert_file_contains`/`assert_file_not_contains` calls and `sed`/`awk`
  extractions of production files. Current totals are 492 and 5; the per-file
  breakdown is what later phases are measured against. See
  [measurable targets](../../../refactor-plan.md#measurable-targets).

- [x] **6. Add table-driven contract cases for:**
  - the **current** config precedence and repeated-load behavior across caller
    environment, named profile, root `.env`, and defaults, captured in an
    isolated fixture without endorsing that behavior as the target contract;
  - repeated-load behavior through `dx`, `dx-destroy`, `dx-recreate`,
    `dx-factory-reset`, and `dx-mount`, including the values observed by every
    child in each chain;
  - the current shell-sourceable profile syntax that Phase 1b must diagnose or
    migrate rather than silently reinterpret;
  - container/image/running-state queries against recorded CLI output;
  - exact runtime-process discovery against exact, prefix-colliding, missing,
    and malformed `ps` fixtures;
  - all `dx-forward` and `dx-reverse` parse/start/list/stop/stop-all outcomes;
  - `dx-mount --print-env`, attach, destroy-plan, and refusal exit statuses;
  - versionless legacy and version-1 mount manifests with spaces and shell
    metacharacters in paths.

- [x] **7. Specify the missing failure-injection cases** and assign each to the phase
  that will make it green:
  - exact process selection, PID-reuse refusal, and secure timeout cleanup
    (Phase 0.5);
  - non-evaluating read of a hostile mount identity file (Phase 0.5);
  - [D2](../decisions/D2-config.md) precedence/origin tracking, complete snapshot
    validation, and one-time resolution across every orchestration chain named
    above (Phase 1b);
  - accepted/rejected data grammar for root `.env` and profiles, including
    `${DX_PROJECT_ROOT}` and fail-closed legacy shell syntax (Phase 1b);
  - configuration values that contain shell metacharacters at
    [D6](../decisions/D6-command-boundaries.md) command boundaries (Phase 1b);
  - container list output is empty, malformed, or from a supported older CLI
    (Phase 1b);
  - SSH master starts but metadata publication fails (Phase 2);
  - tunnel stop fails while the master remains alive (Phase 2);
  - concurrent tunnel start/start, start/stop, and stop-all transitions target
    the same state key (Phase 2);
  - manifest write is interrupted (Phase 3, core);
  - every Bash 3.2 `%q` fixture specified by [D4](../decisions/D4-mount-manifest.md)
    (Phase 3, core);
  - two concurrent first attaches target the same mount identity (Phase 3, hardening);
  - complete legacy-manifest conversion succeeds while incomplete legacy state
    refuses migration without changing the authoritative file (Phase 3, hardening);
  - bootstrap archive transfer or extraction fails halfway (Phase 4, core);
  - malicious legacy keyring content, and a failed AI generation/symlink
    publication retains the prior `current` (Phase 4, core);
  - bootstrap sync races another sync or generation collection (Phase 4, hardening);
  - a stale lease reuses foreground PID 1 after a guest restart (Phase 4, hardening).

  Add any case that already describes supported behavior now. Add a currently
  red safety case as the first commit of its owning phase, immediately before
  the fix, rather than carrying a known failure through unrelated phases.

- [x] **8. Capture public stdout/stderr separately.** Assert exact text only for stable
  user contracts and safety diagnostics; otherwise assert behavior and state.

- [ ] **9. Record the existing live `dx-test` profile result** before structural changes.

  **Open, and no longer satisfiable as written (2026-08-01).** The production
  files have already moved, so a "before" baseline cannot be captured
  retroactively. This does not block the other phases, but it does mean there is
  no pre-refactor live comparison point. Discharge it instead as a
  pre-promotion run of `./bin/dx-profile dx-test tests/run_all_tests.sh` and
  record that result here.

## Red-test timing

The current runner observes one exit status per section file while each section
aggregates many named assertions. It therefore cannot safely classify one
assertion as expected-red without risking suppression of unrelated failures in
the same section. Do not add an expected-failure registry and do not register a
whole section as known-red. Keep the executable suite green between phases;
the failure specifications in item 7 are the queue, and each becomes a real red
test only when its owning implementation work begins. If future work needs
long-lived expected failures for another reason, case-level IDs and a structured
result protocol must land first as an independently reviewed harness feature.

## Exit gate

- Every executable characterization test passes against the current
  implementation; no known-red section or assertion is hidden by the runner.
- Every deferred safety-gap specification names its owning phase and expected
  behavior, ready to become that phase's first red test.
- The non-live suite runs to completion on a machine with no `container`
  binary. (The full portability gate is Phase 1a's; this is the harness-level
  precondition for writing the rest of the plan's tests.)
- The 14-skip inventory exists and every entry is classified.
- The four production test-mode branches and every production shell-command
  boundary are inventoried and assigned to a phase or intentional contract.
- The test-coupling baseline is recorded per file.
- `bash -n` and ShellCheck run in CI on every push.
- No production file has moved yet.
