# DXE refactor v2 plan

This plan turns the reviewed opportunities in the guest bootstrap and host Nix
volume lifecycle into an implementation sequence. It is deliberately a plan,
not a claim that the current behavior is defective. The first three seams are
the priority because they make state flow and lock ownership explicit before
the larger file/test moves begin.

## Goals

- Make the image-store identity a value computed once by `bootstrap_main` and
  passed through validation, import, GC-root creation, and marker publication.
- Give Nix-volume preparation and population an explicit, documented contract;
  keep process-local state local and make the saved image default-profile
  target an explicit input to root publication.
- Make Nix-volume claim locking and cleanup linear and auditable, with process
  identity obtained by the claim code itself.
- Reduce responsibility and test-file size without changing the bootstrap
  ordering, persistence formats, retry behavior, or public CLI behavior.
- Preserve Bash 3.2 compatibility and declarative/idiomatic Nix conventions.

## Non-goals and invariants

- No change to image identity semantics, import verification, GC-root
  retention, marker formats, volume names, lock-file formats, or ownership
  rules unless a test first records an intentional migration.
- No replacement of Bash with another shell, no broad bootstrap rewrite, and no
  change to the Nix module's declarative interface as part of this work.
- Home Manager's custom retry-heavy diagnostics remain intact; the timing
  helper may wrap them but must not flatten, delay, or replace their failure
  output.
- Atomic marker publication remains temp-file plus validated rename. Any helper
  consolidation must be typed by marker kind and must not permit a caller to
  accidentally publish one marker as another.

## Target contracts

### Image identity (priority 1)

`bootstrap_main` computes `image_identity` once, after the source image and
configuration inputs are known. The value is passed as a positional argument
to `nix_image_store_import_required`, `nix_store_import_registered`,
`nix_install_image_essentials_root`, and `publish_nix_image_store_identity`.
Those functions validate the same 64-hex format at their boundary; none reads
or writes `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` and the variable is removed
from production code and tests. A skipped import still receives the identity
so root publication and marker publication describe the same decision.

The default-profile target is likewise resolved once (or deliberately absent)
and passed to `nix_image_bootstrap_store_paths` / root publication. It must not
be silently re-derived from a mutable global during a later phase.

### Volume preparation (priority 2)

The five preparation outputs (`DX_NIX_VOLUME_ALREADY_MOUNTED`,
`DX_NIX_VOLUME_ROOT`, `DX_NIX_VOLUME_DEVICE`, `DX_NIX_VOLUME_FS_TYPE`, and
`DX_NIX_VOLUME_MOUNT_OPTS`) become a private preparation record or explicit
positional values. The preferred contract is a caller-owned temporary state
file with a fixed, validated field order, passed to `populate_prepared_nix_volume
<state-file> <image-identity> <default-profile-target>`; no output field is
exported. A compatibility wrapper may create/read that record for direct
sourceable callers during migration, but it must be removed at the phase gate.
The record is deleted on both success and failure and is never sourced as
shell.

If implementation experience shows a record is unnecessary, the acceptable
alternative is for `prepare_nix_volume_impl` to return a single explicit
`root|device|fstype|mount-options|already-mounted` value consumed immediately
by its caller. Whichever representation is selected, the contract and invalid
field handling must be tested before the writer changes.

### Claims (priority 3)

`dx_nix_volume_claim_acquire` and `dx_nix_volume_claim_release` each establish
one cleanup path immediately after lock acquisition (`locked=1`, then one
`cleanup` block/trap or equivalent structured epilogue). Every return after
acquisition releases the same lock, including malformed records, unsafe paths,
duplicate ownership, and temporary-file failures. The claim code obtains the
current process identity explicitly (using the existing process-identity
helper) and writes that value; it does not depend on `dx_lock_acquire` to set
`DXE_SELF_PROCESS_IDENTITY` as a side effect. Release continues to remove only
the named owner's claim.

## Phased red-green-refactor sequence

### Phase 0 — Freeze behavior and define seams

1. **Red:** Add sourceable probes for identity consistency across validation,
   import, roots, and publication; prove an invalid identity is rejected and
   no pending environment variable is consulted. Add volume-state contract
   probes for mounted, new-volume, import, and failure paths. Add claim probes
   that stub process-identity acquisition, force each post-lock failure, and
   assert the lock is gone afterward.
2. **Green:** Keep the implementation unchanged except for test seams/stubs;
   run the existing isolated coverage suite and confirm the new tests fail for
   the not-yet-explicit contract where expected.
3. **Refactor preparation:** Record the current call graph and exact marker,
   claim, and state-file fixtures. Do not move files yet.

Gate: baseline behavior is reproducible with the commands in Verification,
and the new tests identify the intended contract rather than implementation
source text.

### Phase 1 — Remove hidden image-import state

1. **Red:** Change tests to call every affected function with an identity and
   profile target, asserting the same identity reaches import, GC roots, and
   publication. Assert the old variable is unset before and after a complete
   path and that a retry does not recover state from the environment.
2. **Green:** Thread positional arguments from `bootstrap_main`; validate at
   boundaries; preserve the existing verify/import/skip ordering and marker
   publication timing. Keep compatibility only in a clearly named adapter if
   external maintenance callers require it.
3. **Refactor:** Delete the adapter and stale environment-variable tests once
   all in-repository callers use the explicit API. Update comments to describe
   data flow, not historical state.

Exit criteria: no production `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` reference;
one identity per bootstrap invocation; marker and GC-root tests pass for fresh,
matching, mismatching, invalid, and interrupted-import cases.

### Phase 2 — Make volume state and profile target explicit

1. **Red:** Test that preparation emits all five fields, rejects malformed or
   incomplete state, handles already-mounted and directory/block-device paths,
   and leaves no temporary state after either outcome. Test that population
   receives the saved default-profile target explicitly and does not consult a
   mutable global.
2. **Green:** Introduce the state-record (preferred) or single-value contract;
   pass it from `prepare_nix_volume` to `populate_prepared_nix_volume`, then
   thread identity/profile arguments through root publication. Keep
   `setup_nix_volume_impl` as a compatibility adapter until callers migrate.
3. **Refactor:** Unexport and remove the five globals, then remove the adapter
   when `rg` shows no direct callers. Keep `local` declarations separate from
   command substitutions where Bash 3.2 status propagation matters.

Exit criteria: direct sourceable callers use the documented contract; no
`export` of preparation outputs; state cleanup is covered under success,
mount failure, import failure, and interrupted-process simulation.

### Phase 3 — One claim cleanup path

1. **Red:** Add tests for contention, same-owner idempotence, stale takeover,
   malformed/multiline claims, unsafe names, lock timeout, `mktemp` failure,
   publication failure, and release by owner/non-owner. Stub the process
   identity helper and assert the written identity is exactly its result.
2. **Green:** Acquire once, capture identity explicitly, perform checks, and
   run one cleanup epilogue on every path. Preserve claim record format and
   user-facing diagnostics.
3. **Refactor:** Factor only the genuinely shared validation/cleanup primitive;
   keep acquire/release policy visible and avoid a generic lock abstraction
   that hides ownership.

Exit criteria: shell tracing shows no successful path that bypasses cleanup;
the lock is released on every tested failure; Bash 3.2 and Linux behavior agree.

### Phase 4 — Responsibility and test-suite split

Split `base-and-storage.sh` into sourceable modules with narrow interfaces:
`nix-import` (staging/copy/verification), `nix-identity` (identity, roots,
markers), and `nix-volume` (prepare/mount/populate). Move shared validators to
the smallest existing common module. Source order is explicit in bootstrap and
tests; no module executes a main sequence on source.

Split `tests/test_sourceable_coverage.sh` into module-focused suites (identity,
import/volume, claims, and remaining sourceable helpers). Each suite uses the
same isolated fixture setup and exits nonzero on failure. Add one aggregate
coverage entry point that runs all suites in the pinned environment and emits
one combined result; do not run the aggregate once per module in CI.

Use red-green-refactor for each move: copy behavior behind the new module,
make focused tests green, switch the production source list, then remove the
old definition and duplicate test block. Preserve line/branch coverage scope.

### Phase 5 — Timing/status helper and cautious marker consolidation

Add a small `run_bootstrap_phase <name> <command...>` helper that logs start,
success/failure, elapsed seconds, and exit status. It must work when sourced,
avoid `eval`, and preserve the wrapped command's arguments and return status.
Use it for ordinary phases first. Leave Home Manager's custom retry loop and
diagnostic capture as its own implementation, optionally calling the helper
around the outer phase only.

After phase 1 tests are stable, inventory typed marker kinds (identity,
ownership, compatibility). Consolidate only repeated temp-file/chown/validated-
rename mechanics behind a helper taking an explicit marker type, validator, and
destination. Keep marker-specific validation and messages at call sites. Red:
failure-injection tests for `mktemp`, `chown`, validation, rename, and cleanup;
green: helper preserves all existing outcomes; refactor: remove duplication.

## Migration order, risks, and rollback

Land phases 0–3 in separate commits, in priority order. Keep readers compatible
with old in-memory callers while introducing new writers; do not change a
persistent marker or claim format. Land module/test moves only after explicit
contracts pass. The main risks are argument-order mistakes in boot-critical
code, accidentally losing state on a failed mount/import, and lock leaks on
early returns. Mitigate with positional-argument comments, state-file cleanup
traps/epilogues, failure injection, and isolated Linux coverage.

If a phase fails its gate, revert that phase's commit (or restore the adapter)
without reverting unrelated user changes. Never delete an old reader until a
full bootstrap and one restart have passed with the new path. A compatibility
adapter is a temporary migration aid, not a second long-term state mechanism.

## Acceptance criteria

- Existing bootstrap, Nix-store import, host-container, and sourceable behavior
  suites remain green.
- New tests cover the red cases listed in phases 0–3 and pass in the pinned
  isolated Linux environment.
- `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` and the five preparation output globals
  are absent from production code after their respective migration gates.
- Identity, default-profile target, preparation state, and process identity are
  explicit inputs/results, with no hidden environment or lock side effects.
- Bash 3.2 syntax and runtime compatibility are demonstrated; no arrays,
  `mapfile`, namerefs, `local var=$(...)` status traps, or Bash-4-only syntax
  are introduced.
- Nix remains declarative: module options and generated configuration are data,
  not evaluated shell fragments; formatting/evaluation checks remain green.
- Timing output is useful but does not replace custom Home Manager retry
  diagnostics; typed marker publication retains atomicity and validation.

## Verification commands and gates

Run from the repository root (environment-specific commands may be skipped only
with an explicit reason):

```sh
git diff --check
rg -n 'DX_NIX_PENDING_IMAGE_STORE_IDENTITY|DX_NIX_VOLUME_(ALREADY_MOUNTED|ROOT|DEVICE|FS_TYPE|MOUNT_OPTS)' \
  container bin tests
bash -n container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh
bash -n bin/lib/dx-container.sh
./tests/run_all_tests.sh --skip-integration --section=3
./tests/run_all_tests.sh --skip-integration --section=5
./tests/run_all_tests.sh --skip-integration --section=9
./tests/run_all_tests.sh --skip-integration --section=25
./tests/run-coverage-linux.sh
./tests/run-bash32-tests.sh
```

The `rg` gate is expected to find only migration documentation/tests until
each phase's exit gate, and no production reference after completion. Before
module splitting, run the monolithic sourceable suite as the behavioral
baseline; after splitting, run the aggregate once and each focused suite once
when diagnosing failures. Finish with the full applicable `tests/run-tier.sh`
and Nix evaluation/lint gates used by CI.
