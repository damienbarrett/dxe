# Active plans

Status checked against the repository on 2026-09-26. Completed plan documents
for the lock refresh, Herdr integration, Herdr theming, and bootstrap
performance have been removed, along with the completed Herdr implementation
review and the lock-refresh disposition tracking log; their implementation
and history remain in Git. `consolidation-plan.md`, the plan that drove this
documentation consolidation (R1 through R8), has also been removed now that
all eight refactors are executed; its implementation and history remain in
Git. `refactor-plan.md` has also been removed: its one remaining item,
Phase 6's old-base guards, closed on 2026-09-26 (Branch 8,
`refactor/legacy-migration-cleanup`); its Measurable targets table moved to
[`docs/refactor/baselines.md`](docs/refactor/baselines.md#measurable-targets)
and its narrative and decision history remain in Git and in
`docs/refactor/`.

## Status vocabulary

- **Partially complete** — landed work plus named open items.
- **Open** — a problem statement or an unadopted audit; requires a
  `Revisit trigger:`.
- **Historical** — a record only, kept for its evidence rather than as
  live work.

Every plan document below is listed under exactly one of these.

## Partially complete

- [`checkout-consolidation-plan.md`](checkout-consolidation-plan.md) —
  Sequencing plan for the remaining consolidation work. Priority 1 (a
  complete, green, buildable `main`, proven on a guest) and almost all of
  Priorities 2-3 are done: Branches 1-10 and 14-17 have landed, CI green,
  live-verified on `dx-test`; QNAP's Phase 0 (inventory/spike) and Phase 1
  (runtime-boundary extraction) have also landed. `dx-host` (the primary
  guest) is promoted through `main` `122258c` (Branches 1-15, including
  OpenCode and persist-backup); Branches 16 and 17 land at its next
  promotion. Of the seven decisions, Q1-Q6 and the QNAP part of Q7 are
  resolved; only the rest of Q7 (the two large refactor proposals) remains
  open and is not urgent. Trimmed to remaining work only on 2026-09-27, per
  the plan's own retirement step (history: `git log` and `docs/evidence/`).
  Remaining: land Branch 11 Phase 7 (promotion to a real QNAP profile --
  designed and code-proven on `feat/qnap-promotion`, live steps ahead
  after landing) and Branch 13 (the two large proposals, Q7). Branch 12
  (`fix/store-trust`) and the four small follow-ups (`fix/test-hardening`)
  landed 2026-09-28.
- [`store-trust-plan.md`](store-trust-plan.md) — **Resolved on
  `fix/store-trust` (Branch 12), landed on `main` 2026-09-28.** Both problems
  it tracked (a same-store-path/different-content collision at an image-pin
  bump; recovery when post-remount verification tools themselves depend on
  the persistent store being verified) have a selected, implemented, tested
  design; see the plan's own Status section and
  `docs/refactor/store-trust-design.md` for the comparison that preceded
  implementation. Remaining before this line moves to "removed, history in
  Git": land the branch (dual-target gate, live verification on `dx-test`)
  and apply the new pin-bump procedure to the primary at least once
  (re-scoped waiver in `docs/release-maintenance.md`).

## Open plans

- [`qnap-dxe-plan.md`](qnap-dxe-plan.md) — Implementation plan for a
  Tailscale-reached, QNAP-hosted DXE controlled through Docker Engine over SSH.
  It preserves the Apple runtime as the default, adds an explicit remote-Docker
  adapter and direct `/nix` volume mode, handles native ARM64/x86_64 selection,
  and defines isolated live, reboot, backup/restore, and destructive gates.
  Phases 0-6 have landed on `main` (Phase 6 on 2026-09-28: its own
  maintenance window proved the reboot/restart behaviour and settled the
  restart-ordering decision against the real NAS); Phase 7 (promotion) is
  designed and code-proven on `feat/qnap-promotion` (not yet landed),
  with every live step against the real NAS still ahead.
  Accepted for implementation on
  2026-09-26 (see `checkout-consolidation-plan.md`, Branch 11), and sequenced
  after the start-generation fix and the `/persist` backup land. Revisit
  trigger: when Phase 7 lands and its live steps (canary creation, the
  restore drill, the disposable-spike destructive-lifecycle
  reaffirmation, the canary's own rebuild + recreate, and the production
  profile) complete.
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
- [`refactor-v2-final.md`](refactor-v2-final.md) — Follow-on bootstrap
  refactor plan. Its identity/publication threading, explicit Nix-volume state,
  and claim-cleanup phases remain open; the proposed sourceable-test split and
  possible production-module split are also not complete. The current source
  still uses the environment variables this plan proposes to remove.

  **Recorded conflict.** Phase 4's coverage-ratchet gate vs.
  `declarative-nix-plan-a.md` #12 remains live — see that entry above.
