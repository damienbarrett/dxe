# Phase 4 — Make bootstrap phases sourceable and payload publication safe

**Goal:** isolate boot-critical responsibilities without changing their order.
**Owns:** seam 4.
**Decisions:** [D5](../decisions/D5-bootstrap-state.md) (tiered),
[D6](../decisions/D6-command-boundaries.md).

The target guest layout and the published/mutable state split are in
[constraints](../constraints.md#guest-side-target-shape).

**This phase has an internal stopping point.** Items 1–11 are D5-core. Items 12–13
are D5-hardening — see
[D5's stopping point](../decisions/D5-bootstrap-state.md#stopping-point).

## D5-core

- [x] **1. Start with red tests** for partial transfer/extraction/permission
  failure, malicious legacy keyring content, and failed AI generation/pointer
  publication.

- [x] **2. Add `bootstrap_main`** and call it only when the file is executed, not
  sourced. Keep strict mode in the executable orchestrator; guest library modules
  do not set shell options, run commands, emit output, or mutate state when
  sourced.

- [x] **3. Move functions by responsibility while preserving the current explicit
  call order.** Do not opportunistically reorder storage, ownership, Home Manager,
  timezone, or SSH startup. The rationale comments in `bootstrap.sh` move with the
  code they explain — they are not discarded during extraction.

- [x] **4. Replace the `# Main` extraction in tests** with direct library sourcing
  and per-phase fakes. The `sed '/^# Main$/,$d'` pattern at
  [`test_section3_bootstrap.sh`](../../../tests/test_section3_bootstrap.sh#L62) is to
  be eliminated, not relocated.

- [x] **5. Remove the `DX_BOOTSTRAP_TEST_MODE=guard` branch** at
  [`bootstrap.sh`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L707).
  It is the same production test-mode anti-pattern Phase 2 removes from the
  tunnel commands, and once `guard_old_base` is a function in a sourceable
  module it can be called directly.

  *Sequencing note:* the guard it exercises is itself scheduled for deletion in
  [Phase 6](phase-6.md) item 1, so if Phase 6's operational sign-off lands first,
  this step collapses into that removal — do not do the work twice.

- [x] **6. Implement the [D5](../decisions/D5-bootstrap-state.md#keyring-state-is-data)
  keyring data contract.** Share D-Bus address parsing, session-config discovery,
  liveness checks, exact legacy conversion, and raw address read/write in
  `scripts/lib/dx-keyring.sh`; keep root-vs-user startup policy in the callers.
  Install that same checked-in library with Home Manager at
  `~/.local/lib/dx/dx-keyring.sh`, update `dx-ai` to source the installed library,
  and update Bash/Fish/Nushell startup to parse the raw address as data. No
  consumer sources `.dx-keyring-env`.

- [x] **7. Split `configure_guest`** into persistence preparation, optional AI
  persistence, Home Manager activation, and shell selection. Remove the broad
  `chown -R dx:dx /guest-bootstrap`; published generations remain root-owned and
  readable/executable, while only the explicit `/persist` state is writable by `dx`.

- [x] **8. Remove the unused `start_ssh` function**
  ([`bootstrap.sh`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L699-L704),
  no callers anywhere in the repository) after the main-path test proves the
  `exec sshd -D -e -p 2222` tail is the canonical SSH startup path.

- [x] **9. Move the Antigravity pin out of the derivation.** Put version, URL, and
  hash into `pins/agy.json`, make the Nix derivation read that file, and remove the
  range-sensitive source editing at
  [`dx-ai.sh`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/dx-ai.sh#L111-L142).
  Do this **before** making generations immutable.

- [x] **10. Implement mutable AI working generations under `/persist`.** Stage a new
  generation from the current published bootstrap, refresh the pin and
  `flake.lock`, validate and install from staging, then atomically switch
  `current`. Never rename a staged directory over a non-empty live directory, and
  never let a failed switch change `current`. `dx-ai` must never write the
  published bootstrap generation.

- [x] **11. Change bootstrap sync to stage, validate, and publish:**
  - transfer into a fresh same-filesystem generation/staging directory;
  - validate required files and archive extraction;
  - normalize root ownership and read-only/executable modes in staging;
  - atomically switch `current` only after validation;
  - retain the previous ready generation on any failure.

  Keep a compatibility path for `/guest-bootstrap` consumers while the generation
  layout changes. `bootstrap.sh`, flake evaluation, `dx-ai`, and tests must all
  resolve the same `current` generation, while writes go only to the explicit
  `/persist` state paths. Test compatibility shims against an old container launch
  command before changing the launcher. Apply
  [D6](../decisions/D6-command-boundaries.md) to the replacement launcher: its
  program text is fixed and paths cross as positional or validated environment
  data. Register the
  [bootstrap-layout removal gate](../migration-gates.md#flat-bootstrap-layout) with
  the reader, per [reader-before-writer](../risk-controls.md#reader-before-writer).

### D5-core exit gate

- Bootstrap functions are tested by sourcing their real modules, with no
  `sed`-generated test copies and no production test-mode branch remaining in
  `bootstrap.sh`.
- An injected transfer/extract/permission failure leaves the prior payload
  runnable and not falsely marked as the new ready version.
- Published generations are read-only and root-owned.
- `dx-ai` and every shell treat keyring state as data, use the packaged shared
  library where applicable, and execute no content from the legacy env file.
- A failed AI pin/lock update or pointer switch leaves the published bootstrap and
  `dx-ai/current` unchanged and usable; successful publication is one atomic
  symlink switch.
- Fresh boot, warm restart, failed activation/retry, and persistent-volume
  repair all pass against the isolated profile.

---

## Stopping point

Stopping after D5-core is safe **provided automatic generation collection stays
off** — without leases, collection cannot prove a generation is unused. Record
that in the migration checklist.

---

## D5-hardening

- [x] **12. Red tests first:** concurrent sync, collection while a generation is in
  use, and a stale lease whose foreground PID 1 is reused after restart.

- [x] **13. Add the publication lock, leases, predecessor metadata, and collection.**
  - a bounded publication lock serializes sync and garbage collection;
  - the staged generation records the old current as immutable predecessor
    metadata before publication;
  - while still holding the publication lock, resolve `current` and create an
    execution lease containing generation, guest boot ID, PID, and process start
    time before bootstrap can execute it;
  - garbage-collect only after a successful switch, never collecting current,
    current's recorded predecessor, or generations with a fully validated live
    lease; a matching PID alone is not a live lease;
  - each `dx-ai` generation records its predecessor ID so the prior generation is
    retained and recoverable.

### D5-hardening exit gate

- Concurrent sync and garbage-collection tests prove current, its recorded
  predecessor, and leased generations remain complete.
- Restart/PID-reuse tests reject stale leases.
- A failed AI publication leaves the retained predecessor generation usable.
