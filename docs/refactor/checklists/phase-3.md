# Phase 3 — Separate `dx-mount` planning from execution

**Goal:** make destructive resolution a pure, inspectable decision before any
mutation.
**Owns:** seam 3.
**Decisions:** [D4](../decisions/D4-mount-manifest.md) (tiered).
**Independent of** [Phase 2](phase-2.md) — either order, or one without the other.

The code-execution surface itself is already closed by
[Phase 0.5](phase-0.5.md) item 3, which swapped `source "$identity_file"` for a
non-evaluating legacy reader in place. This phase does the structural work.

**This phase has an internal stopping point.** Items 1–7 are D4-core. Items 8–10
are D4-hardening and can be deferred indefinitely without leaving a half-finished
migration — see [D4's stopping point](../decisions/D4-mount-manifest.md#stopping-point).

## D4-core

- [ ] **1. Start with red failure tests** for interrupted manifest publication,
  malicious legacy tokens, and every Bash 3.2 `%q` fixture specified by
  [D4](../decisions/D4-mount-manifest.md#legacy-decoders).

- [ ] **2. Extract pure functions** into `bin/lib/dx-mount-plan.sh` for:
  - option conflict validation;
  - canonical repository/mount identity resolution;
  - side-container resource derivation;
  - manifest decoding and schema validation;
  - attach compatibility comparison;
  - destroy-plan resolution;
  - default-resource refusal checks.

- [ ] **3. Have the planner produce one complete resolved plan.** Both
  `--print-destroy-plan` and `--destroy` must consume the same plan; the latter
  must not re-resolve resources after confirmation. When normal attach hands off
  to `dx`, export the plan as [D2](../decisions/D2-config.md)'s complete resolved
  snapshot so no child can reapply root `.env` or accept a partial marker.

- [ ] **4. Implement the [D4-core](../decisions/D4-mount-manifest.md#d4-core-mandatory)
  codec:** the version-2 header/allowlisted-record/base64 format, plus the exact
  non-evaluating decoders for versionless and version-1 Bash `%q` output already
  introduced in Phase 0.5. Reject every token outside the specified grammar; never
  evaluate manifest contents.

- [ ] **5. Validate every decoded field by type:**
  - safe container and volume/image identifiers;
  - absolute paths where required;
  - positive, in-range port;
  - exact known field names with duplicate/unknown-field rejection.

- [ ] **6. Create the identity directory at mode 0700**, stage a mode-0600 manifest
  in the same directory, and publish with an atomic `rename`. Refuse symlinked or
  unexpectedly owned state paths. Inject failures at every boundary and prove no
  partial manifest becomes authoritative.

- [ ] **7. Keep orchestration in `dx-mount` small:**

  ```text
  parse -> resolve plan -> validate/print or execute -> exec dx
  ```

- [ ] **8. Remove `DX_MOUNT_TEST_MODE=resolve`**
  ([`bin/dx-mount`](../../../bin/dx-mount#L483-L485)). Convert its 14 section-18
  call sites to source and invoke the real planner with fake mutation
  dependencies, so no production-only test branch remains in `dx-mount`.

- [ ] **9. Convert the 17 near-repeated manifest scenarios in section 18** into a
  fixture table that varies marker version, overrides, container existence,
  expected status, and expected plan.

### D4-core exit gate

- No persisted mount state is sourced or evaluated as code.
- Versionless legacy and version-1 manifests still attach/destroy according to
  the current contract, using only the bounded D4 grammar.
- `--print-destroy-plan` is a byte-for-byte preview of the resources the
  executor will use, and child lifecycle commands cannot replace it from `.env`.
- Safety tests prove that default resources are refused before any container,
  volume, or key command is invoked.
- An interrupted publication leaves either the old manifest or the complete new
  one, never a partial file.
- `DX_MOUNT_TEST_MODE` is gone and planner tests call the real sourceable code.

---

## Stopping point

Stopping after D4-core is safe. Record in the migration checklist that the v0/v1
decoders are retained deliberately, because without `--audit-manifests` the
[legacy-manifest removal gate](../migration-gates.md#legacy-mount-manifests) cannot
be satisfied.

---

## D4-hardening

- [ ] **10. Red tests first:** concurrent first attach, concurrent attach/destroy,
  and complete vs. incomplete legacy migration.

- [ ] **11. Add the per-container lock** for attach, first-create, migration, and
  destroy. Record PID plus process start identity in lock metadata. Recheck
  absence while locked, and publish first-create with the atomic
  hard-link/no-replace operation rather than an overwriting `mv`. Test PID reuse,
  stale-lock reclamation, and bounded lock-wait failure.

- [ ] **12. Implement the migration path.** `--migrate-manifests` previews every
  legacy record and its eligibility; `--apply` converts only complete records that
  match the resolved plan, under lock and with an atomic format-only replacement.
  Refuse incomplete records with destroy/recreate remediation. Test interruption
  before and after staging and prove the old file remains authoritative until the
  v2 replacement is complete.

- [ ] **13. Add `--audit-manifests`**, which walks every mount identity file
  reachable from every profile parsed through [D2](../decisions/D2-config.md) and
  reports each one's format version, completeness, and migration eligibility. This
  is what makes deleting the decoders an evidence-backed step.

### D4-hardening exit gate

- Concurrent first-attach/attach/destroy tests prove the manifest remains
  semantically write-once, complete, and authoritative, with bounded lock
  failure behavior; the only permitted replacement is a verified format-only
  legacy conversion.
- `--audit-manifests` reports format and migration eligibility across all local
  profiles, complete legacy records have an atomic conversion path, and
  incomplete records receive safe destroy/recreate remediation.
- The [legacy-manifest removal gate](../migration-gates.md#legacy-mount-manifests)
  is now satisfiable.
