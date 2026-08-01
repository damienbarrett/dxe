# Refactor assessment

Assessment snapshot: 2026-07-31. Verified against the repository 2026-08-01.

Part of the [refactor plan](../../refactor-plan.md).

## What is already working well

- The public lifecycle is composed from small, idempotent scripts. For example,
  [`bin/dx`](../../bin/dx#L12-L23) is an orchestrator rather than a second
  implementation of lifecycle state.
- Destructive operations contain explicit safeguards, especially the
  default-resource refusals in
  [`bin/dx-mount`](../../bin/dx-mount#L274-L379).
- The forwarding helpers have meaningful behavioral coverage for active,
  stale, orphaned, partially failed, and prefix-colliding state.
- NixVim is already split into focused modules under
  [`container/aarch64-darwin-apple-container-dx-nixos-26.05/nvim`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/nvim).
- The guest bootstrap records the rationale for subtle image, filesystem,
  authentication, and persistence behavior. Those comments should move with
  the relevant code, not be discarded during extraction.
- The repository explicitly requires Red-Green-Refactor and behavior-oriented
  testing in [`constitution.md`](../../constitution.md).
- Some target patterns already exist and only need to be generalized rather than
  invented — see [Existing patterns to reuse](#existing-patterns-to-reuse).

## Baseline and size

The assessment ran:

```sh
tests/run_all_tests.sh --skip-integration
```

Result: **804 passed, 0 failed, 14 skipped**. The skipped set included
ShellCheck, Nix-dependent checks, and live guest checks.

Those 14 skips are not yet individually accounted for, and the plan cannot
demand "no silent skips" without knowing what they are. Phase 0 produces the
inventory.

There is currently no CI configuration and no generated coverage report.
Consequently, the constitution's 100% coverage requirement is not presently
measurable or enforced.

The host-side developer toolchain is also missing. Neither `shellcheck`, `nix`,
nor `kcov` is installed on the assessment host, so no mandatory gate can be run
locally today. Making ShellCheck mandatory in CI without also providing a local
install path would turn the fast lint tier into slow remote feedback; Phase 1a
therefore treats the host toolchain as a deliverable, not an assumption.

Approximate line counts, excluding `flake.lock`:

| Area | Lines | Concentration |
| --- | ---: | --- |
| Host scripts (`bin/`) | 2,796 | `dx-mount` 487, `dx-forward` 450, `dx-reverse` 435, `dx-lib.sh` 392 |
| Guest shell scripts | 1,723 | `bootstrap.sh` 724, tool-theme writer 419 |
| Nix files | 1,083 | Already reasonably modular |
| Tests | 6,983 | Section 9 is 1,719 lines; sections 18, 3, and 14 are 818, 785, and 761 lines |

The large test-to-production ratio is not itself a problem. The issue is that
many checks assert source strings or extract functions by file layout, so a
behavior-preserving move creates widespread test churn. That cost is measured:
**492** `assert_file_contains`/`assert_file_not_contains` calls and **5**
`sed`-extractions of production files. See the metrics table in the
[plan](../../refactor-plan.md#measurable-targets).

## Highest-value findings

| Priority | Fixed in | Finding | Evidence | Consequence |
| --- | --- | --- | --- | --- |
| P0 | Phase 1b | `dx-lib.sh` mixes configuration, platform preflight, pure derivation, Apple Container adaptation, timeout/process control, and host discovery. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L6-L392) | Every source operation has side effects and unrelated commands cannot be tested in isolation. |
| P0 | Phase 0 | Static tests require the Apple `container` binary before their own skip logic runs. | [`tests/test_helpers.sh`](../../tests/test_helpers.sh#L17-L29) sources [`dx-lib.sh`](../../bin/dx-lib.sh#L56-L69). | The nominal non-integration suite is not portable to a normal Linux CI runner. |
| P0 | Phases 0 and 1a | Lint and coverage policy are not enforced. | [`tests/test_section0_lint.sh`](../../tests/test_section0_lint.sh#L9-L13) treats missing ShellCheck as a skip; no CI or coverage configuration exists. | A green local result can omit a required quality gate. |
| P0 | Phase 1b | Sourcing the shared library imposes `set -euo pipefail` on every caller. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L2); [`tests/test_helpers.sh`](../../tests/test_helpers.sh#L4) has to re-declare its own options after sourcing. | A library silently changes its caller's error semantics, and the test harness cannot trust its own strict-mode declaration. |
| P1 | Phase 0.5 | The emergency runtime-process selector uses a prefix substring, and its test asserts that implementation string. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L272-L293), [`tests/test_section9_host_scripts.sh`](../../tests/test_section9_host_scripts.sh#L1526-L1541) | A fallback stop for `dx-host` can select a process whose UUID is `dx-host-other`; `dx_require_non_reserved_container_name` rejects only the exact name, so `--container dx-host-other` is accepted. Process-control code must prove exact identity before signalling. |
| P1 | Phase 0.5 | Timeout bookkeeping uses a predictable path in shared temporary storage. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L218-L255) | Another process can create or delete `$TMPDIR/dx-timeout.$$.<pid>` to force or mask exit 124. |
| P1 | Phase 0.5, completed in Phase 3 | `dx-mount` executes its identity file as shell code. | [`bin/dx-mount`](../../bin/dx-mount#L217-L228) | A user-writable state file used to authorize deletion is also a code-execution surface. |
| P1 | Phase 2 | Forward and reverse tunneling carry parallel copies of the same control-socket state machine. | [`bin/dx-forward`](../../bin/dx-forward#L83-L394) and [`bin/dx-reverse`](../../bin/dx-reverse#L83-L379) | Fixes to discovery, metadata, stale-state cleanup, or stop semantics must be made and tested twice. |
| P1 | Phase 3 | `dx-mount` combines option parsing, path resolution, profile derivation, manifest encoding, compatibility, authorization, destruction, and launch. | [`bin/dx-mount`](../../bin/dx-mount#L51-L487) | Safety-sensitive branches are hard to review and fixture setup dominates its 818-line test file. |
| P1 | Phase 1b | Config precedence is re-applied at every process boundary. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L10-L16), [`bin/dx-mount`](../../bin/dx-mount#L169-L197), and [`bin/dx`](../../bin/dx#L9-L20) | A root `.env` can replace values in a side-container plan after preview, defeating resolve-once behavior and potentially profile isolation. |
| P1 | Phases 1b and 4 | The data/code inventory is incomplete: named profiles and keyring address state are also sourced as shell. | [`bin/dx-profile`](../../bin/dx-profile#L45-L49), [`dx-ai.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/dx-ai.sh#L84-L89), and [`home/shell.nix`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/home/shell.nix#L6-L11) | Changing only root `.env` and mount manifests would leave inconsistent trust rules and an inaccurate completion metric. |
| P1 | Phase 1b | Configuration is interpolated into generated `sh -c`/`bash -lc` programs at several host/guest boundaries. | [`bin/dx-lib.sh`](../../bin/dx-lib.sh#L363-L365), [`bin/dx-migrate-persist`](../../bin/dx-migrate-persist#L33-L57) | Moving file parsers to data formats would still leave values crossing into executable text; inherited values can bypass the data-file grammar. |
| P1 | Phase 2 | Tunnel metadata publication is not protected by a state-transition lock. | [`bin/dx-forward`](../../bin/dx-forward#L197-L229), [`bin/dx-reverse`](../../bin/dx-reverse#L183-L215) | A concurrent stop can terminate a just-started master before metadata publication, after which the starter can publish orphan metadata and report success. |
| P1 | Phases 3 and 4 (hardening) | Durable migration/liveness protocols are not actionable with format reporting or PID-only reasoning alone. | [`bin/dx-mount`](../../bin/dx-mount#L464-L477), [`bootstrap.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L722-L724) | Legacy manifests cannot reach a zero-old-format gate without a safe conversion path, while a stale lease for foreground PID 1 can look live after a restart. |
| P1 | Phase 4 | Bootstrap sync removes the current payload before the replacement stream has succeeded. | [`bin/dx-sync-bootstrap`](../../bin/dx-sync-bootstrap#L65-L85) | An interrupted tar/copy can leave no usable payload and no last-known-good generation. |
| P1 | Phase 4 | The 724-line guest bootstrap has an unguarded top-level main sequence. Tests copy everything above a `# Main` comment in order to call functions. | [`bootstrap.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L706-L724), [`test_section3_bootstrap.sh`](../../tests/test_section3_bootstrap.sh#L58-L64) | Tests depend on file layout, and unrelated bootstrap functions share one global shell namespace. |
| P2 | Phase 4 | D-Bus/keyring discovery is duplicated between bootstrap and `dx-ai`. | [`bootstrap.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L482-L518), [`dx-ai.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/dx-ai.sh#L45-L81) | Credential fixes can drift between initial bootstrap and later AI-tool updates. |
| P2 | Phase 4 | `dx-ai` rewrites an embedded Nix derivation with range-sensitive `sed`. | [`dx-ai.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/dx-ai.sh#L111-L142) | Reformatting or extracting the derivation can silently break the updater contract, and in-place writes conflict with immutable bootstrap generations. |
| P2 | Phase 1a | Tests and release checks are mixed together. | [`tests/run_all_tests.sh`](../../tests/run_all_tests.sh#L68-L95), [`test_section13_final_review.sh`](../../tests/test_section13_final_review.sh#L12-L18) | An intentionally dirty development tree can fail a behavior suite, while capability-based skips are spread across individual files. |

## Low-cost cleanup candidates

Each carries the phase that absorbs it so none is left orphaned:

- *(Phase 4)*
  [`bootstrap.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L699-L704)
  defines an unused `start_ssh` function.
- *(Phase 0)* `assert_true` and `assert_false` in
  [`tests/test_helpers.sh`](../../tests/test_helpers.sh#L31-L50) have no callers and
  would execute the message argument as part of the command if used.
- *(Phase 0)*
  [`test_section8_nixvim_config.sh`](../../tests/test_section8_nixvim_config.sh#L5)
  uses `set -uo`, which prints the shell option table because `-o` has no
  option name.
- *(Phase 1b)* Container existence checks parse the first column of
  human-readable tables in [`dx-lib.sh`](../../bin/dx-lib.sh#L85-L103). The locally
  installed Apple Container 1.2 CLI supports quiet and structured list output;
  the adapter should prefer a machine-readable form with a tested compatibility
  fallback.
- *(Phase 1b, decision [D2](decisions/D2-config.md))* The `.env` comment says it is
  loaded "safely," but [`dx-lib.sh`](../../bin/dx-lib.sh#L10-L16) executes it as
  shell code. The intended contract should be made explicit and enforced.
- *(Phase 3)* [`dx-mount`](../../bin/dx-mount#L483-L485) has a fourth production
  test-mode branch, `DX_MOUNT_TEST_MODE=resolve`, used by 14 section-18 call
  sites. It must be removed with the other production test seams once the real
  planner is directly sourceable.
- *(Phase 4, decision [D5](decisions/D5-bootstrap-state.md))* The keyring address
  file is parsed as data by bootstrap but sourced as shell by `dx-ai` and Bash
  startup. Replace it with one raw, validated address file used by Bash, Fish,
  Nushell, and `dx-ai`.

## Existing patterns to reuse

The plan prescribes several patterns the repository already implements. Treat
these as reference implementations and mechanical moves, not as new design work:

- **Fixed program body with positional data** — [`bin/dx-sync-bootstrap`](../../bin/dx-sync-bootstrap#L65-L71)
  already runs `container exec … sh -c '<fixed body>' -- "$path"`. This is exactly
  the shape decision [D6](decisions/D6-command-boundaries.md) requires everywhere.
- **Pure derivation helpers** — `dx_slugify`, `dx_short_hash`, `dx_derived_name`,
  and `dx_derived_port` ([`bin/dx-lib.sh`](../../bin/dx-lib.sh#L134-L179)) are
  already side-effect free. Moving them into `dx-host-util.sh` is a file move, not
  a rewrite.
- **Fixed-length hash suffix** — `dx_derived_name` appends a 10-character hash, so
  *derived* container names cannot prefix-collide with each other. The exact-match
  requirement in Phase 0.5 exists for `--container` overrides, not for derived names.
