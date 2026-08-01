# Phase 6 — Remove temporary code and reduce documentation coupling

**Goal:** finish the simplification after operational compatibility is proven.
**Owns:** seam 5.
**Optional.** Nothing depends on it.

## Items

- [ ] **1. Remove the old-base guards** once the default guest, side containers, and
  named profiles have all moved off the old base:
  - [`bootstrap.sh`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L11-L29);
  - [`bin/dx-start-container`](../../../bin/dx-start-container#L21-L44).

  Remove their dedicated tests and changeover documentation in the same commit.
  Do not remove them based only on repository age — see the
  [old-base guard gate](../migration-gates.md#old-base-guards).

  **Scope note:** the primary guest is already done. [`plan.md`](../../../plan.md#L64-L73)
  records that the destructive salvage-and-rebuild changeover of the primary
  completed on 2026-07-05 behind an `OLD_BASE_ABSENT` gate with the full suite
  green. The remaining inventory is side containers and named profiles only.

- [ ] **2. Reduce the 1,243-line README** to quick start, common workflows, safety,
  and a documentation index. Move detailed lifecycle, forwarding, configuration,
  recovery, and release procedures into focused `docs/` pages.

- [ ] **3. Generate or validate the documented environment-variable inventory** from
  the canonical config registry. Stop maintaining dozens of independent "README
  contains this variable" assertions — there are currently 69 doc assertions in
  [`test_section10_docs.sh`](../../../tests/test_section10_docs.sh) alone.

- [ ] **4. Replace implementation-string documentation tests with:**
  - command inventory coverage;
  - help/README link validation;
  - default-value consistency;
  - required safety statements.

- [ ] **5. Archive completed upgrade material from [`plan.md`](../../../plan.md)** only
  after its remaining status items are confirmed complete.

- [ ] **6. Keep the theme writer structurally as-is** unless it is being changed for
  a feature. It already has renderer functions and extensive behavior tests. If
  touched, prioritize atomic multi-file publication and golden renderer fixtures
  over further abstraction.

## Exit gate

- The temporary guards have an explicit operational sign-off recorded in the
  [migration gates](../migration-gates.md#old-base-guards).
- Every public command and config variable remains discoverable.
- Documentation tests validate contracts, not paragraph placement.
