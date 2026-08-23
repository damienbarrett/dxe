# DXE refactor v2 — final plan

## Status

Merged 2026-08-21 from three documents, all committed at `cd20f62` and removed
here: the original `refactor-v2-plan.md`, and two independent reviews of it,
`refactor-v2-review-a.md` (6 findings) and `refactor-v2-review-o.md` (4 blocking
findings, 6 revisions). Every finding's disposition is tabled at the end.

The two reviews were complementary rather than redundant. They overlapped on one
finding — the claim/lock identity contract — and each caught defects the other
missed. The original plan cannot be executed as written: three of its four target
contracts were incomplete in ways that risk boot regressions, and one phase plus
one invariant rested on premises that are no longer true.

Prerequisite A1 is **already closed**: the coverage ratchet was re-measured to
2267 bp at `7ffa66b`. Phase 4 depended on it. That figure is the measurement
taken at that commit, not the live baseline: `tests/coverage/ratchet.env` has
since moved to 2256 bp, lowered deliberately because the digest work added more
lines to `tests/` than to the covered scope. Read the ratchet file, not this
number, before touching the gate.

This plan changes no production behavior. It makes state flow explicit, and it
must not alter bootstrap ordering, persistence formats, marker formats, retry
behavior, or public CLI behavior.

## Goals

- Make the image-store identity **and the decision to publish its marker** values
  computed once by `bootstrap_main` and passed explicitly through validation,
  import, GC-root creation, and publication.
- Resolve the image default-profile target once and thread it to all three of its
  consumers, preserving its capture-before-remount ordering.
- Give Nix-volume preparation an explicit, versioned, mode-tagged contract that
  matches the shapes the code actually produces.
- Make Nix-volume claim locking and cleanup linear and auditable, with process
  identity obtained explicitly by the claim code.
- Reduce responsibility and test-file size without changing behavior.

## Non-goals and invariants

- No change to image identity semantics, import verification, GC-root retention,
  marker formats, volume names, lock-file formats, or ownership rules unless a
  test first records an intentional migration.
- No broad bootstrap rewrite; no shell replacement; no change to the Nix module's
  declarative interface.
- Home Manager's retry-heavy diagnostics remain intact. A timing helper may wrap
  the outer phase but must not flatten, delay, or replace its failure output.
- Atomic marker publication remains temp-file plus validated rename.
- **Bash 3.2 compatibility is a host-only constraint.**
  `tests/run-bash32-tests.sh` enforces it over `bin/dx*` and `bin/lib/*.sh` only;
  guest bootstrap modules run under the guest's Bash 5 and are exempt. This binds
  Phase 3 and nothing else. The prohibition is on **associative arrays**
  (`declare -A`), namerefs, `mapfile`, and `local var=$(...)` status traps —
  Bash 3.2 has indexed arrays, and forbidding those would be wrong.

## Target contracts

### 1. Image identity and publication decision (priority 1)

`DX_NIX_PENDING_IMAGE_STORE_IDENTITY` is not merely a hidden identity value. It
encodes **three** facts:

| Role | Mechanism |
| --- | --- |
| The identity value | assigned at `base-and-storage.sh:489`, `:499`, `:538` |
| "A marker publication is pending" | left **unset** on the verified-clean skip (`:496` returns 1 without assigning) |
| "Publication is complete" | the trailing `unset` at `:520` |

`publish_nix_image_store_identity` returns early when it is unset (`:512`), so on
a verified clean boot the marker is deliberately not rewritten.

**Threading the identity alone would rewrite the marker on every clean boot** —
an extra atomic write plus `chown` on precisely the path this work exists to keep
cheap, and the loss of the distinction between a verified skip, a required
import, and a missing/invalid marker.

Contract: `bootstrap_main` computes `image_identity` once and passes it, together
with an explicit `publish_identity_marker` decision, to
`nix_image_store_import_required`, `nix_store_import_registered`,
`nix_install_image_essentials_root`, and `publish_nix_image_store_identity`. Each
validates the 64-hex format at its boundary. No function reads or writes the
environment variable, and it is removed from production code and tests.

Phase gate: a test proving a verified clean skip performs **no marker write**.

### 2. Image default-profile target (priority 1)

Three consumers, not one:

- `nix_image_bootstrap_store_paths` (`base-and-storage.sh:463`),
- GC-root publication, and
- `nix_restore_image_default_profile` (`:403`), which **hard-fails** with
  `Error: no retained image default profile target is available after the /nix
  remount` when the value is empty.

"Deliberately absent" is therefore **not** a valid production state, and the
original plan's allowance for it is struck.

The reason this is a global is an ordering constraint, not convenience: it is
captured at `bootstrap.sh:14` (`capture_nix_image_default_profile`) *before*
`prepare_nix_volume`, and consumed at `bootstrap.sh:19`
(`nix_restore_image_default_profile`) *after* `populate_prepared_nix_volume` has
replaced /nix. The value must survive the remount that destroys the image's /nix
tree. That makes `bootstrap_main` the natural owner of the threaded value, and
any refactor must preserve capture-before-remount.

Contract: resolution returns a value (replacing `capture_nix_image_default_profile`
as a global-setter) which `bootstrap_main` holds and passes to all three
consumers. It is never silently re-derived from a mutable global.

### 3. Nix-volume preparation record (priority 2)

The original plan required a record carrying all five preparation outputs in a
fixed field order. The code does not produce that shape: both already-mounted
branches set only `DX_NIX_VOLUME_ALREADY_MOUNTED` and `DX_NIX_VOLUME_ROOT`, while
the prepared branch sets all five. A five-field contract would reject the
already-mounted case.

Contract — a versioned, **mode-tagged**, non-sourceable record, chosen now rather
than deferred past Phase 0:

- `mode=already-mounted` — requires `root`; **rejects** device, filesystem type,
  and mount options.
- `mode=prepared` — requires all five values.

Passed as `populate_prepared_nix_volume <state-file> <image-identity> <publish-decision> <default-profile-target>`.
No output field is exported. The record is never sourced as shell.

The guarantee is that **a stale record is never reused after an interruption** —
not that it is always deleted. Cleanup after `SIGKILL` cannot be promised, so the
reader must validate mode, version, and field completeness and reject anything
else, rather than relying on the writer's cleanup.

Invalid-field handling is tested before the writer changes.

### 4. Claims and lock identity (priority 3)

Two facts about the current code:

- `dx_lock_acquire` lazily assigns `DXE_SELF_PROCESS_IDENTITY`
  (`bin/lib/dx-host-util.sh:104-106`), and `dx_lock_release` reads it back
  (`:142`). It is the **only** assignment anywhere.
- `dx_nix_volume_claim_acquire` *reads* that global at
  `bin/lib/dx-container.sh:215` to write its value into the claim record. It does
  not assign it.

The read is **undefaulted** — `"$DXE_SELF_PROCESS_IDENTITY"`, not
`"${DXE_SELF_PROCESS_IDENTITY:-}"` — inside scripts running `set -euo pipefail`,
on the host's main entry point. It is safe today only because
`dx_lock_acquire … || return 1` at `:188` forces an early return whenever the
lock is not held. The correctness of a boot-critical write rests on the ordering
of two statements 27 lines apart, with nothing declaring the dependency. Any
reordering makes it a hard unbound-variable abort.

Contract, choosing the **narrower** of the two options the review posed:

- Scope is the claim record's identity. The claim code computes process identity
  once, explicitly, via the existing `dx_process_start_identity` helper, and
  writes that value. It does not depend on the lock's side effect.
- The generic lock **remains stateful**, and that is acknowledged rather than
  silently accepted. Threading an ownership token through `dx_lock_acquire` /
  `dx_lock_release` is recorded as a follow-up: it would pull in the tunnel
  callers of that API and is a materially larger blast radius than this phase.
- Acquire and release each establish **one** cleanup path immediately after lock
  acquisition. Every return after acquisition releases the same lock — malformed
  records, unsafe paths, duplicate ownership, `mktemp` failure, publication
  failure. Today `dx_lock_release` appears at 8 call sites in acquire and 3 in
  release.
- Use a **structured epilogue, not a trap**: these are sourceable functions, and
  a trap would overwrite the caller's.
- Define explicitly whether an operation failure or a cleanup failure wins the
  returned status.
- Release continues to remove only the named owner's claim.

## Phased sequence

### Phase 0 — Freeze behavior

Add **green** characterization tests only, covering identity consistency, volume
state across mounted/new/import/failure paths, and claim contention. Record the
current call graph and the exact marker, claim, and state-file fixtures.

The original plan labelled still-failing target tests "Green" here. Corrected:
each phase introduces its own target test **red** and makes it green within that
phase. Phase 0 establishes a passing baseline and moves no files.

Gate: baseline reproducible with the Verification commands; new tests describe
the intended contract, not implementation source text.

### Phase 1 — Thread identity and the publication decision

**Red:** call every affected function with an identity, a publication decision,
and a profile target; assert the same identity reaches import, GC roots, and
publication; assert a **verified clean skip writes no marker**; assert the old
variable is unset before and after a complete path and that a retry recovers no
state from the environment.

**Green:** thread positional arguments from `bootstrap_main`; validate at
boundaries; preserve verify/import/skip ordering and publication timing.

**Refactor:** delete stale environment-variable tests; update comments to describe
data flow rather than history. Fix the `local expected="$(id -u dx):$(id -g dx)"`
status trap at `base-and-storage.sh:283` while in this file.

Exit: no production `DX_NIX_PENDING_IMAGE_STORE_IDENTITY`; one identity per
bootstrap; marker and GC-root tests pass for fresh, matching, mismatching,
invalid, and interrupted-import cases.

### Phase 2 — Explicit volume state and profile target

**Red:** preparation emits a valid mode-tagged record for each branch shape,
rejects malformed/incomplete/wrong-mode records, handles already-mounted and
directory/block-device paths, and leaves no reusable stale record after either
outcome. Population receives the profile target explicitly.

**Green:** introduce the record; pass it from `prepare_nix_volume` to
`populate_prepared_nix_volume`; thread identity, publication decision, and profile
target through root publication.

**Refactor:** unexport and remove the five globals.

**No compatibility adapter.** `setup_nix_volume` and `setup_nix_volume_impl` have
no production callers — `bootstrap.sh:15,18` calls `prepare_nix_volume` and
`populate_prepared_nix_volume` directly. The only references are
`tests/test_sourceable_coverage.sh` and the function list at
`tests/test_section3_bootstrap.sh:25`, plus two descriptive comments. Delete both
functions and their tests alongside the globals.

Exit: no `export` of preparation outputs; cleanup covered under success, mount
failure, import failure, and interrupted-process simulation.

### Phase 3 — One claim cleanup path

**Red:** contention, same-owner idempotence, stale takeover, malformed and
multiline claims, unsafe names, lock timeout, `mktemp` failure, publication
failure, release by owner and by non-owner. Stub the process-identity helper and
assert the written identity is exactly its result. **Include the case where
`DXE_SELF_PROCESS_IDENTITY` is unset on entry** — the condition today's code
cannot survive.

**Green:** acquire once, capture identity explicitly, one cleanup epilogue on
every path. Preserve the claim record format and user-facing diagnostics.

**Refactor:** factor only the genuinely shared validation/cleanup primitive. Do
not introduce a generic lock abstraction that hides ownership.

Exit: no successful path bypasses cleanup; the lock is released on every tested
failure; Bash 3.2 and Linux behavior agree.

### Phase 4 — Responsibility and test split (gated)

**Two gates before any code moves:**

1. The coverage ratchet is measured against the current tree — **closed at
   `7ffa66b`** (2267 bp, no slack).
2. A written **definition-move matrix** naming every function's destination
   module and its dependencies, including the cases the original categories left
   ambiguous: durable identity, essentials installation, default-profile
   restoration, and marker ownership. It must also state what remains in
   `base-and-storage.sh`.

**Test split — proceed.** `tests/test_sourceable_coverage.sh` is 1,450 lines, more
than twice the module it covers. Split into module-focused suites (identity,
import/volume, claims, remaining helpers) with shared isolated fixture setup. Add
one aggregate entry point that runs every suite in the pinned environment and
emits one combined result; CI runs the aggregate **once**, never once per module.

**Production split — open question.** `base-and-storage.sh` is 695 lines, which is
not obviously over-large for staging, copy, verification, identity, roots, markers,
and volume lifecycle — responsibilities genuinely coupled through the import
transaction. Decide with evidence after Phases 1–3, when the threading work has
shown where the real seams are. If it proceeds: `nix-import`, `nix-identity`,
`nix-volume`, with explicit source order and no module executing on source.

Each move is red-green-refactor: copy behavior behind the new module, make focused
tests green, switch the production source list, then remove the old definition and
duplicate test block. Line and branch coverage scope must be preserved — the
ratchet is now a live gate on exactly this.

### Phase 5 — Timing helper and typed marker consolidation

Add `run_bootstrap_phase <name> <command...>` logging start, outcome, elapsed
seconds, and exit status. It must work when sourced, avoid `eval`, and preserve
the wrapped command's arguments and return status. Home Manager's retry loop keeps
its own implementation; the helper may wrap only the outer phase.

**A new phase-start line changes observable bootstrap output.** Either preserve the
exact existing messages and ordering, or record the new output as an intentional
behavior change with tests asserting the new format. Do not let it land as an
unremarked side effect of a no-behavior-change refactor.

After Phase 1's tests are stable, consolidate repeated temp-file/chown/validated-
rename mechanics. The helper takes the **marker type and dispatches to that type's
validator internally** — passing type and validator as independent arguments still
permits mismatched pairs. Per-marker wrappers are an acceptable alternative.
Marker-specific messages stay at call sites.

The volume root carries four marker files across three kinds —
`.dx-owner-layout-v1` (ownership), `.dx-durable-identity-v1` and
`.dx-image-store-identity` (identity), `.dx-owner-set` (legacy compatibility) —
and the first two are independent migrations that deliberately do not supersede
one another. A helper that let one be published as another would be a data-loss
bug, not a style regression.

Red: failure injection for `mktemp`, `chown`, validation, rename, and cleanup.

## Migration order, risks, rollback

Land Phases 0–3 as separate commits in priority order. Introduce new writers while
old readers still work; change no persistent marker or claim format. Land module
and test moves only after the explicit contracts pass.

Principal risks: argument-order mistakes in boot-critical code; losing state on a
failed mount or import; lock leaks on early returns. Mitigations: positional-
argument comments, state cleanup epilogues, failure injection, isolated Linux
coverage.

If a phase fails its gate, revert that phase's commit without reverting unrelated
changes. Never delete an old reader until a full bootstrap and one restart have
passed with the new path — subject to the generation check below.

## Acceptance criteria

- Existing bootstrap, Nix-store import, host-container, and sourceable suites stay
  green.
- New red cases from Phases 0–3 pass in the pinned isolated Linux environment.
- `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` and the five preparation globals are
  absent from production code after their gates.
- Identity, publication decision, profile target, preparation state, and process
  identity are explicit inputs or results, with no hidden environment or lock side
  effects in the claim path.
- A verified clean boot performs no image-identity marker write.
- Host scripts remain Bash 3.2 clean per `run-bash32-tests.sh`; no associative
  arrays, namerefs, `mapfile`, or `local var=$(...)` status traps introduced
  anywhere.
- Nix remains declarative; `nix flake check` stays green.
- Timing output either matches the previous messages exactly or is covered by
  tests recording the intended change.

## Verification

```sh
git diff --check
rg -n 'DX_NIX_PENDING_IMAGE_STORE_IDENTITY|DX_NIX_VOLUME_(ALREADY_MOUNTED|ROOT|DEVICE|FS_TYPE|MOUNT_OPTS)' \
  container bin tests

# Focused suites. 21 and 22 are the lock state machines and transactional
# publication -- the two most exposed by Phases 3 and 5.
./tests/run_all_tests.sh --skip-integration --section=3    # bootstrap
./tests/run_all_tests.sh --skip-integration --section=5    # nix
./tests/run_all_tests.sh --skip-integration --section=9    # host scripts
./tests/run_all_tests.sh --skip-integration --section=21   # test_refactor_state_machines.sh
./tests/run_all_tests.sh --skip-integration --section=22   # test_bootstrap_publication.sh
./tests/run_all_tests.sh --skip-integration --section=25   # test_nix_store_import.sh

./tests/run-tier.sh unit/static
./tests/run-tier.sh host-contract

# The gates CI actually runs (.github/workflows/ci.yml):
find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \) -print0 | xargs -0 -n1 bash -n
shellcheck --severity=warning   # via the pinned nixpkgs shell in CI
./tests/run_all_tests.sh --skip-integration
./tests/run-coverage-linux.sh
nix flake check --no-build --no-write-lock-file ./container/aarch64-darwin-apple-container-dx-nixos-26.05
./tests/run-bash32-tests.sh
```

The `rg` gate should match only migration documentation and tests until each
phase's exit gate, and nothing in production after completion.

Section 25 requires the isolated Linux runner; `run-tier.sh unit/static` prints a
note and skips it on macOS. `run-coverage-linux.sh` is the real gate for it.

ShellCheck is absent on the development machine, where section 0 silently skips
it. **CI is the only lint gate** — do not read a local green as lint-clean.

**Live validation must prove which generation ran.** A known launcher defect in
this workspace means a restart can execute the *previous* bootstrap generation, so
"one restart passed" is not evidence the code under review ran. Before trusting any
full-bootstrap result, assert that the PID 1 lease generation equals `current`, or
fix that launcher issue first as a prerequisite.

Before the Phase 4 split, run the monolithic sourceable suite as the behavioral
baseline. Afterwards, run the aggregate once, and individual suites only when
diagnosing. Syntax checks must cover every new module — CI's glob does this
automatically; a hardcoded `bash -n` list would not.

## Review disposition

Findings from `refactor-v2-review-a.md` (A) and `refactor-v2-review-o.md` (O),
both at `cd20f62`.

| Finding | Disposition |
| --- | --- |
| A1: coverage ratchet stale by ~330 bp | **Closed** at `7ffa66b` — re-measured to 2267 bp (3,695 / 16,298); was Phase 4's blocking gate |
| A2: Phase 2's compatibility adapter is unnecessary | Adapter removed from the plan; Phase 2 now deletes `setup_nix_volume`/`_impl` outright |
| A3: Bash 3.2 is host-only; "no arrays" is wrong | Invariant rescoped to `bin/` per `run-bash32-tests.sh`; prohibition narrowed to associative arrays |
| A4: undefaulted `DXE_SELF_PROCESS_IDENTITY` is a `set -u` hazard | Elevated into contract 4; Phase 3 must test the unset-on-entry case |
| A5: Phase 4 is the weakest item | Kept but double-gated; test split proceeds, production split is an explicit open question |
| A6: `local var="$(...)"` status trap at `:283` | Folded into Phase 1's refactor step |
| O-1: identity also encodes "publication pending" | Accepted and extended — three roles, not two; contract 1 threads an explicit publication decision, gated on a no-write test |
| O-2: default-profile target not fully threaded | Accepted — three consumers named, "deliberately absent" struck, capture-before-remount ordering recorded as the reason it is a global |
| O-3: preparation record contradicts branch shapes | Accepted — mode-tagged record decided before Phase 0; deletion promise replaced with never-reuse-a-stale-record |
| O-4: claim identity misaligns with the lock API | Accepted with the narrower scope; the generic lock stays stateful and token threading is a recorded follow-up |
| O: prove which generation ran | Added to Verification as a precondition on any live gate |
| O: Phase 0 mislabels red-green-refactor | Accepted — Phase 0 is green characterization only |
| O: Phase 4 needs a definition-move matrix | Accepted as the second Phase 4 gate |
| O: marker typing must be enforceable | Accepted — helper dispatches by marker type internally |
| O: decide whether timing output may change | Accepted — preserve exactly, or record as intentional with tests |
| O: verification commands incomplete | Accepted — rewritten against the actual CI workflow, with sections 21/22 and explicit tier arguments |

Three corrections to review O, made while verifying its claims:

- Claims **read** `DXE_SELF_PROCESS_IDENTITY`; they never assign it. The sole
  assignment is `dx_lock_acquire` at `dx-host-util.sh:105`. The finding stands —
  the contract does span the lock API, since `dx_lock_release` reads it too — but
  the mechanism is a shared read, not a shared write.
- `bootstrap.sh:14` is where the profile target is **captured**;
  `nix_restore_image_default_profile` is at `:19`.
- Sections 21 and 22 are real and worth adding, but the files are
  `test_refactor_state_machines.sh` and `test_bootstrap_publication.sh` — there
  are no `test_section21*.sh` / `test_section22*.sh` files.

Review A missed O-1 and O-2 entirely, treating the identity variable as a simple
hidden value. Those are the two findings most likely to have caused a boot
regression, and they are why this plan was not executed from review A alone.
