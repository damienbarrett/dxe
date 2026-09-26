# Active plans

Status checked against the repository on 2026-09-26. Completed plan documents
for the lock refresh, Herdr integration, Herdr theming, and bootstrap
performance have been removed, along with the completed Herdr implementation
review and the lock-refresh disposition tracking log; their implementation
and history remain in Git. `consolidation-plan.md`, the plan that drove this
documentation consolidation (R1 through R8), has also been removed now that
all eight refactors are executed; its implementation and history remain in
Git.

## Status vocabulary

- **Partially complete** — landed work plus named open items.
- **Open** — a problem statement or an unadopted audit; requires a
  `Revisit trigger:`.
- **Historical** — a record only, kept for its evidence rather than as
  live work.

Every plan document below is listed under exactly one of these.

## Partially complete

- [`refactor-plan.md`](refactor-plan.md) — Phases 0 through 5 are checked off
  in `docs/refactor/checklists/`. Phase 6 is nearly complete: README
  reduction, environment-variable inventory, documentation-test decoupling,
  theme writer work, and archiving completed upgrade material are done;
  removing old-base guards remains unchecked.
- [`checkout-consolidation-plan.md`](checkout-consolidation-plan.md) —
  Sequencing plan for landing the remaining consolidation work as small,
  independently validated branches. Priority 1 (Branches 1-3: CI baseline,
  the OpenCode revert, the test-image fixture removal) is done, and Step 4's
  baseline check of `main` passed. Branches 4a (the `container_is_running`/
  `container_exists` SIGPIPE fix) and 4b (live-tier hygiene, seven commits,
  live tier 1105/0/8) have landed; Branch 4c (the same SIGPIPE shape in guest
  bootstrap and theme scripts) is in progress. Branch 5 (this document's own
  move into the repository, plus the rest of `docs/plan-cleanup`) has landed.
  The duplicate clone (`dxe-agent/`) and the August evidence clone
  (`dxe-evidence-20260831/`) were retired on 2026-09-26, ahead of Branch 6:
  the preserved OpenCode work now lives in this repository as local branch
  `preserve/dxe-agent-opencode`. Of the seven decisions (Q1, Q3-Q7; Q2 was
  already resolved), Q1, Q3, Q4, Q5 and Q6 are now resolved, and the QNAP part
  of Q7 was already accepted; only the rest of Q7 (the two large refactor
  proposals) remains open and is not urgent. Because Q1 resolved to "fix the
  bug first," Branch 9 (`fix/bootstrap-start-generation`) ran before Branch 6
  (`feat/opencode`) and is now done: Step 1 characterised the defect live and
  found its core symptom already fixed on `main` by two pre-existing commits,
  landing only an observability increment and the D7 design proposal; Step 2
  implemented D7's accepted option 3 (a bounded host-side confirmation that
  closes Q4's "fail the start" gap) and closed `dx-start-plan.md` into
  [D7](docs/refactor/decisions/D7-start-generation.md) and `docs/lifecycle.md`/
  `docs/troubleshooting.md`. QNAP's Phase 0 (inventory and disposable spike,
  `feat/qnap-phase0-scripts`) has also landed, ahead of its Phases 1-7. Branch
  6 (`feat/opencode`) landed on `main` on 2026-09-26: all increments, gates
  (G1-G3, then CI on the rebased branch), and live `dx-test` validation
  (fresh opt-in, full live tier, retained-state migration) passed; see
  `docs/evidence/20260926/opencode-relanding.md`. `dx-host` does not have
  OpenCode yet (a separate promotion decision). Branches 7, 8, and 10
  through 13 are otherwise not started.

## Open plans

- [`qnap-dxe-plan.md`](qnap-dxe-plan.md) — Implementation plan for a
  Tailscale-reached, QNAP-hosted DXE controlled through Docker Engine over SSH.
  It preserves the Apple runtime as the default, adds an explicit remote-Docker
  adapter and direct `/nix` volume mode, handles native ARM64/x86_64 selection,
  and defines isolated live, reboot, backup/restore, and destructive gates. No
  implementation has landed. Accepted for implementation on 2026-09-26 (see
  `checkout-consolidation-plan.md`, Branch 11), and sequenced after the
  start-generation fix and the `/persist` backup land. Revisit trigger: when
  the target QNAP is available for the Phase 0 preflight, or when the
  runtime abstraction is scheduled.
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
- [`plan.md`](plan.md) — Backlog only: the NixOS 26.05 upgrade record and all
  eight code-review fixes (P3–P10) have landed and been removed from the
  document (see Git history; the upgrade procedure now lives in
  `docs/release-maintenance.md`). B1, an incremental host backup for at-risk
  `/persist` content, is specified but not implemented. Revisit trigger: when
  an incremental `/persist` host backup is next scheduled, or the next time a
  `/persist` loss scare occurs.
- [`refactor-v2-final.md`](refactor-v2-final.md) — Follow-on bootstrap
  refactor plan. Its identity/publication threading, explicit Nix-volume state,
  and claim-cleanup phases remain open; the proposed sourceable-test split and
  possible production-module split are also not complete. The current source
  still uses the environment variables this plan proposes to remove.

  **Recorded conflict.** Phase 4's coverage-ratchet gate vs.
  `declarative-nix-plan-a.md` #12 remains live — see that entry above.
- [`store-trust-plan.md`](store-trust-plan.md) — Folds the two former
  store-trust stubs (`image-pin-collision-plan.md` and
  `post-remount-trust-root-plan.md`) into one document: no design yet for
  safely changing the Nix base-image pin while reusing `/nix` after a
  same-store-path/different-content collision (requires pre-remount failure,
  no mismatched execution, and a valid fresh-volume path), and no design yet
  for recovery when post-remount verification tools themselves depend on the
  persistent store being verified (defines failure outcomes, testing, and
  recovery constraints).
