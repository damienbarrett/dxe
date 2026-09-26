# Phase 6 — Remove temporary code and reduce documentation coupling

**Goal:** finish the simplification after operational compatibility is proven.
**Owns:** seam 5.
**Optional.** Nothing depends on it.

## Items

- [x] **1. Remove the old-base guards** once the default guest, side containers, and
  named profiles have all moved off the old base:
  - `bootstrap.sh` / `bootstrap/system.sh` (`guard_old_base`);
  - `bin/dx-start-container`.

  Removed their dedicated tests and changeover documentation in the same
  commits, not on repository age — see the
  [old-base guard gate](../migration-gates.md#old-base-guards).

  **Scope note:** the primary guest changed over first. See
  [Base Image Changeover, "History"](../../release-maintenance.md#base-image-changeover-one-time)
  for the destructive salvage-and-rebuild changeover of the primary
  completing on 2026-07-05 behind an `OLD_BASE_ABSENT` gate with the full
  suite green. The remaining inventory — side containers and named
  profiles — was confirmed off the old base by the 2026-09-26 inventory
  below.

  **Done (2026-09-26).** Old-base guard gate signed off with inventory in
  [`docs/evidence/20260926/legacy-guard-removal.md`](../../evidence/20260926/legacy-guard-removal.md);
  both guards removed in Branch 8 (`refactor/legacy-migration-cleanup`),
  commits `8fe2448` (guest-side `guard_old_base`) and `24933e2` (host-side
  `dx-start-container` guard).

- [x] **2. Reduce the 1,243-line README** to quick start, common workflows, safety,
  and a documentation index. Move detailed lifecycle, forwarding, configuration,
  recovery, and release procedures into focused `docs/` pages.

- [x] **3. Generate or validate the documented environment-variable inventory** from
  the canonical config registry. Stop maintaining dozens of independent "README
  contains this variable" assertions — there are currently 69 doc assertions in
  [`test_section10_docs.sh`](../../../tests/test_section10_docs.sh) alone.

- [x] **4. Replace implementation-string documentation tests with:**
  - command inventory coverage;
  - help/README link validation;
  - default-value consistency;
  - required safety statements.

- [x] **5. Archive completed upgrade material from `plan.md`** only
  after its remaining status items are confirmed complete.

  **Done (2026-09-19).** P7 and P10 closed; B1 remains, but as an
  unscheduled backlog item standing on its own in `plans.md`, not an
  in-flight status item this gate was protecting. Part A is archived —
  deleted from `plan.md`, with its content in
  [`docs/release-maintenance.md`](../../release-maintenance.md) and Git
  history.

  **Update (Branch 10, `feat/persist-backup`):** B1 is now implemented —
  see ["Backing up and restoring /persist"](../../lifecycle.md) — and
  `plan.md` itself (now empty of open items) has been deleted; its entry in
  `plans.md` is removed with it.

- [x] **6. Keep the theme writer structurally as-is** unless it is being changed for
  a feature. It already has renderer functions and extensive behavior tests. If
  touched, prioritize atomic multi-file publication and golden renderer fixtures
  over further abstraction.

## Exit gate

- The temporary guards have an explicit operational sign-off recorded in the
  [migration gates](../migration-gates.md#old-base-guards).
- Every public command and config variable remains discoverable.
- Documentation tests validate contracts, not paragraph placement.
