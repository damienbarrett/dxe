# Review of the DXE refactor v2 plan

## Assessment

The plan has a strong direction and sensible priorities, but it should not be
executed unchanged. Four contracts are incomplete enough to risk boot
regressions.

## Blocking findings

### 1. Image identity and "publication pending" are different state

The plan treats `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` as merely a hidden
identity value ([plan](refactor-v2-plan.md#L40)). Its presence also records
whether the marker must be published. On a verified clean skip, it remains
unset and publication is a no-op
([current code](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh#L479)).

Passing the identity unconditionally could rewrite the marker on every boot or
lose the distinction between:

- a verified skip;
- an import being required; and
- an invalid or missing marker requiring later publication.

Phase 1 should explicitly thread both `image_identity` and a decision such as
`publish_identity_marker=true|false`, with tests proving that a clean skip
performs no marker write.

### 2. The default-profile target is not fully threaded

The plan only names root publication as its consumer
([plan](refactor-v2-plan.md#L49)), but the same global is also required by
`nix_restore_image_default_profile`
([code](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh#L400)).
Bootstrap restores it immediately after population
([bootstrap](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L14)).

The target contract should explicitly include:

- resolution as a returned value, replacing
  `capture_nix_image_default_profile`;
- `nix_image_bootstrap_store_paths`;
- GC-root publication; and
- `nix_restore_image_default_profile`.

"Deliberately absent" is not currently a valid production state because
restoration requires the target.

### 3. The preparation-record contract remains undecided and contradicts current branch shapes

The plan postpones choosing between a state file and a pipe-delimited value
([plan](refactor-v2-plan.md#L55)), yet Phase 0 is supposed to test the contract
before implementation. It also requires all five fields, while both
already-mounted branches currently produce only `already-mounted` and `root`
([code](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh#L586)).

The representation should be chosen before Phase 0. A versioned,
non-sourceable tagged record is the clearest option:

- `mode=already-mounted`: require `root`; reject device and filesystem options.
- `mode=prepared`: require all five preparation values.

The promise that the record is deleted after an interrupted process should
also be replaced with a guarantee that stale records are never reused after an
interruption. Cleanup after `SIGKILL` cannot be guaranteed.

### 4. The claim identity contract does not align with the lock API

The plan says claim code obtains identity explicitly and no longer depends on
the lock side effect ([plan](refactor-v2-plan.md#L72)). However,
`dx_lock_acquire` creates `DXE_SELF_PROCESS_IDENTITY`, while `dx_lock_release`
reads it later
([lock implementation](bin/lib/dx-host-util.sh#L101)). Claims currently write
that same global ([claim implementation](bin/lib/dx-container.sh#L177)).

The plan must choose one of two contracts:

- Thread one identity or ownership token through `dx_lock_acquire` and
  `dx_lock_release`, expanding Phase 3 to the tunnel callers of that API; or
- Limit the goal to explicit claim-record identity and acknowledge that the
  generic lock remains stateful.

Whichever contract is selected, the process identity should be computed once.
A structured epilogue is preferable to a trap in these sourceable functions so
caller traps cannot be overwritten. The plan should also define whether an
operation failure or a cleanup failure takes precedence in the returned status.

## Important revisions

### Make live validation prove which generation ran

The known previous-generation boot defect in
[dx-start-plan.md](dx-start-plan.md#L1) has already affected this workspace.
Before any "full bootstrap" gate, assert that the PID 1 lease generation equals
`current`, or make fixing that launcher issue a prerequisite. "One restart"
alone is not strong evidence that the code under review ran.

### Correct Phase 0's red-green-refactor sequence

Phase 0 calls unchanged, still-failing target tests "Green"
([plan](refactor-v2-plan.md#L86)). Phase 0 should add only green
characterization tests. Each later phase should introduce its target test red
and make it green in that phase.

### Add an explicit definition-move matrix to Phase 4

Specify every function's destination and module dependencies before moving
code. The proposed categories currently leave durable identity, essentials
installation, default-profile restoration, and marker ownership ambiguous.
The matrix should also state which file remains responsible for any definitions
left in `base-and-storage.sh`.

### Make marker typing enforceable

Passing both a marker type and an independent validator
([plan](refactor-v2-plan.md#L184)) still permits mismatched combinations. The
helper should accept the marker type and dispatch to its validator internally,
or expose separate per-marker wrappers.

### Decide whether timing output may change

Logging a new phase-start line changes observable bootstrap output despite the
no-behavior-change goal. Phase 5 should either preserve the exact existing
messages and ordering or record the new output as an intentional behavior
change with tests.

### Make verification commands concrete and complete

The focused list should add sections 21 and 22 for lock state machines and
transactional marker publication. It should also name the exact syntax,
ShellCheck, complete container-free, coverage, Nix evaluation, and Bash 3.2
commands used by [CI](.github/workflows/ci.yml#L15). Calls to
`tests/run-tier.sh` need explicit `unit/static` and `host-contract` arguments.
After Phase 4, syntax checks must cover every new module rather than only the
old `base-and-storage.sh` path.

## Verdict

The priority order, failure-injection emphasis, Bash constraints, and commit
isolation are good. After resolving the four blocking contracts above, the
plan should be safe to implement.
