# Active plans

Status checked against the repository on 2026-09-19. Completed plan documents
for the lock refresh, Herdr integration, Herdr theming, and bootstrap
performance have been removed, along with the completed Herdr implementation
review and the lock-refresh disposition tracking log; their implementation
and history remain in Git.

## Status vocabulary

- **Partially complete** — landed work plus named open items.
- **Open** — a problem statement or an unadopted audit; requires a
  `Revisit trigger:`.
- **Historical** — a record only, kept for its evidence rather than as
  live work.

Every plan document below is listed under exactly one of these.

## Partially complete

- [`plan.md`](plan.md) — The NixOS 26.05 upgrade and live validation are
  complete. In the separate code-review workstream, the timezone fallback and
  ordering fixes, dead `start_ssh` removal, D-Bus environment handling, the
  exact filesystem-type check (P7), and wiring the documented
  `DX_NIX_DISK_SIZE` setting through container creation (P10) are all now
  present. Backlog B1, an incremental host backup for at-risk `/persist`
  content, is specified but not implemented.

  **Recorded conflict — P7 vs. `refactor-v2-final.md` Phase 2.** P7 fixes an
  unanchored FSTYPE match in `prepare_nix_volume_impl`
  (`base-and-storage.sh:629`); Phase 2 separately deletes the *wrapper*
  functions `setup_nix_volume`/`setup_nix_volume_impl` as dead code
  (disposition A2). Neither touches the other's target, but landing Phase 2
  first could read as "the FSTYPE item's area is gone" when the live defect
  survives untouched. Resolution: P7's fix belongs in the preparation record
  Phase 2 builds, not in a standalone patch to the current function.

  **Recorded conflict — P10 vs. the config registry (resolved).** `plan.md`
  decided "canonical default `64G`" in 2026-06; `bin/lib/dx-config.sh:41` and
  `docs/configuration.md:27` registered/documented `20G`; the code hardcoded
  `truncate -s 64G` (`base-and-storage.sh:669`). Resolved to `64G`, not `20G`:
  `64G` is the value that has actually shipped, and reconciling down to `20G`
  would silently lower a real, already-in-use disk cap. The registry and the
  docs now both read `64G`, and `dx-create-container` forwards
  `DX_NIX_DISK_SIZE` into the guest so a configured value actually reaches
  `truncate`.
- [`refactor-plan.md`](refactor-plan.md) — Phases 0 through 5 are checked off
  in `docs/refactor/checklists/`. Phase 6 is partly complete: README reduction,
  environment-variable inventory, documentation-test decoupling, and theme
  writer work are done; removing old-base guards and archiving completed
  upgrade material remain unchecked.

## Open plans

- [`consolidation-plan.md`](consolidation-plan.md) — The plan that drove this
  documentation consolidation. R1, R2, R4, R5, R6, and R7 are executed —
  R6's remaining piece was resolved by dropping the `Owner:` requirement from
  the status vocabulary above rather than by naming owners. Two refactors
  remain, each blocked on a precondition this plan cannot itself satisfy:
  - **R3** — delete `plan.md` Part A. Blocked on
    `docs/refactor/checklists/phase-6.md` item 5, which is itself blocked on
    P7, P10, and B1 closing. Revisit trigger: when P7, P10, and B1 all close.
  - **R8** — fold the two store-trust stubs into one document. Revisit
    trigger: when R3 and R8 land, this plan is retired (see below).
- [`declarative-nix-plan-a.md`](declarative-nix-plan-a.md) — Audit proposing
  incremental Bash-to-Nix/Home Manager conversions. It puts Nix evaluation and
  coverage gates first, followed by smaller configuration conversions and the
  larger Herdr TOML merger. It is tracked in Git; its recommendations have not
  been adopted as an implementation plan.

  **Recorded conflict — #12 vs. `refactor-v2-final.md` A1/Phase 4.** #12
  proposes replacing the coverage-ratchet ratio with a ceiling on uncovered
  production shell. `refactor-v2-final.md`'s A1 review finding was closed
  against that ratio's measurement at `7ffa66b`, and its Phase 4 gate
  re-measures the same ratio. If #12 lands first, both are against a metric
  shape that no longer exists. Undecided which lands first; no owner named
  for either document.
- [`dx-start-plan.md`](dx-start-plan.md) — Documents the stale-bootstrap
  generation defect: a recreated guest can start the previous payload because
  the host publishes the new one only after starting the container. It records
  constraints and desired behavior; no solution is selected.
- [`image-pin-collision-plan.md`](image-pin-collision-plan.md) — No design yet
  for safely changing the Nix base-image pin while reusing `/nix`, after a
  same-store-path/different-content collision. Requires pre-remount failure,
  no mismatched execution, and a valid fresh-volume path.
- [`post-remount-trust-root-plan.md`](post-remount-trust-root-plan.md) — No
  design yet for recovery when post-remount verification tools themselves
  depend on the persistent store being verified. Defines failure outcomes,
  testing, and recovery constraints.
- [`refactor-v2-final.md`](refactor-v2-final.md) — Follow-on bootstrap
  refactor plan. Its identity/publication threading, explicit Nix-volume state,
  and claim-cleanup phases remain open; the proposed sourceable-test split and
  possible production-module split are also not complete. The current source
  still uses the environment variables this plan proposes to remove.

  **Recorded conflicts.** Phase 2 vs. `plan.md` P7, and Phase 4's coverage-
  ratchet gate vs. `declarative-nix-plan-a.md` #12 — see those entries above.

## Optional follow-up

- **Herdr tool-inventory consolidation and two snapshot/pane-history
  acceptance cases.** Low-priority items noted in the completed Herdr
  implementation review (removed; see Git history): the AI-tools inventory is
  still repeated across the Nix package list, the host install message, and
  prose, rather than unified into one source; and the corrupt/too-new
  snapshot recovery path and the deletion half of pane-history cleanup remain
  unautomated acceptance cases. Neither reopens the review's verdict that
  remediation and the isolated live gate passed. No owner; pick up
  opportunistically.
