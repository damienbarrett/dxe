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

- [`2-oct-plan.md`](2-oct-plan.md) — Unified execution plan consolidating the
  October session plans and the user's eight agreed policies. Findings landed;
  remaining work is the transferred connection/profile safeguards, directory-mode
  and Docker-lease fixes, final gates, named guest-maintenance windows, and QNAP
  acceptance/production cutover. Agent A coordinates; original notes are
  privately archived. Revisit trigger: a candidate/gate changes or an execution
  milestone completes.
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

- [`findings.md`](findings.md) — Consolidated findings plan, combining three
  independent reviews of the repository at `4e8c5cc` dated 2026-09-29
  (`docs/reviews/2026-09-29-astra.md`, `docs/reviews/2026-09-29-muse.md`,
  `docs/reviews/2026-09-29-fable.md`; index at `docs/reviews/README.md`).
  Records decision D-1, which resolves the recorded conflict below between
  `declarative-nix-plan-a.md` #12 and `refactor-v2-final.md` Phase 4: the
  coverage metric (WP1.5) lands first. Revisit trigger: stated inside the
  document, under "Revisit trigger:" at the top.
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
  for either document. The ordering is decided in `findings.md` D-1: the
  metric lands first.
- [`refactor-v2-final.md`](refactor-v2-final.md) — Follow-on bootstrap
  refactor plan. Its identity/publication threading, explicit Nix-volume state,
  and claim-cleanup phases remain open; the proposed sourceable-test split and
  possible production-module split are also not complete. The current source
  still uses the environment variables this plan proposes to remove.

  **Recorded conflict.** Phase 4's coverage-ratchet gate vs.
  `declarative-nix-plan-a.md` #12 remains live — see that entry above. The
  ordering is decided in `findings.md` D-1: the metric lands first.
- **Backlog probes from the consolidation plan** — Four small, specified
  probes `checkout-consolidation-plan.md`'s own "Open follow-ups" section
  tracked without a branch (Muse D5): a live tmux-resurrect restore probe
  in Section 6 is timing-flaky (make it poll for the observable condition
  instead of a fixed delay, the way the Herdr acceptance tests do, and
  prove it stable across three consecutive live runs); `dx-status` has no
  "keyring: not running" line for the failure-policy B warning path (its
  host-script test fixture answers every exec identically regardless of
  command, so extend that fixture first); `dx-restore --dry-run` over a
  very large target set is O(n^2) and had not finished after 13 minutes
  over 60,000 targets — **addressed by `findings.md` WP6.9** (one-pass
  parent-dir dedupe, bounded transport; design landed 2026-09-30,
  implementation in progress); and Section 27's fake `ssh` blocks forever
  when its stdin is an open pipe or socket (make its fake redirect its own
  stdin from `/dev/null`, and add a bounded-time test that runs Section 27
  with stdin held open). owner: the user. Revisit trigger: when each of
  the three remaining probes (tmux-resurrect, `dx-status` keyring,
  Section 27 stdin) is fixed and proven stable across three consecutive
  live runs, and when `findings.md` WP6.9 lands, closing the restore item
  here too.

## Historical

- [`checkout-consolidation-plan.md`](checkout-consolidation-plan.md) —
  **Complete 2026-10-03.** The sequencing plan that took the repository from
  several divergent checkouts to one green, buildable `main` (Branches 1-17,
  trimmed to remaining work on 2026-09-27). Kept for its decision history
  (Q1-Q7). Surviving obligations moved: open items to
  `findings.md`, the QNAP promotion to
  `qnap-dxe-plan.md` Phase 7, forward work to
  `2-oct-plan.md`.
- [`qnap-dxe-plan.md`](qnap-dxe-plan.md) — **Complete 2026-10-03.** The
  Tailscale-reached, QNAP-hosted DXE plan: phases 0-7 are done and the
  production guest is live (evidence:
  `docs/evidence/20260928/qnap-promotion.md`). Kept as the design record;
  its remaining operator steps are recorded in
  `2-oct-plan.md`.
