# Active plans

Status checked against the repository on 2026-09-19. Completed plan documents
for the lock refresh, Herdr integration, Herdr theming, and bootstrap
performance have been removed, along with the completed Herdr implementation
review and the lock-refresh disposition tracking log; their implementation
and history remain in Git.

## Status vocabulary

- **Partially complete** — landed work plus named open items.
- **Open** — a problem statement or an unadopted audit; requires an
  `Owner:` and a `Revisit trigger:`.
- **Historical** — a record only, kept for its evidence rather than as
  live work.

Every plan document below is listed under exactly one of these.

## Partially complete

- [`plan.md`](plan.md) — The NixOS 26.05 upgrade and live validation are
  complete. In the separate code-review workstream, the timezone fallback and
  ordering fixes, dead `start_ssh` removal, and D-Bus environment handling are
  already present. The exact filesystem-type check (P7) and wiring the
  documented `DX_NIX_DISK_SIZE` setting through container creation (P10) remain
  open. Backlog B1, an incremental host backup for at-risk `/persist` content,
  is specified but not implemented. The plan's older status table still lists
  some now-landed fixes as open.
- [`refactor-plan.md`](refactor-plan.md) — Phases 0 through 5 are checked off
  in `docs/refactor/checklists/`. Phase 6 is partly complete: README reduction,
  environment-variable inventory, documentation-test decoupling, and theme
  writer work are done; removing old-base guards and archiving completed
  upgrade material remain unchecked.

## Open plans

- [`declarative-nix-plan-a.md`](declarative-nix-plan-a.md) — Audit proposing
  incremental Bash-to-Nix/Home Manager conversions. It puts Nix evaluation and
  coverage gates first, followed by smaller configuration conversions and the
  larger Herdr TOML merger. This file is currently untracked in Git; its
  recommendations have not been adopted as a committed implementation plan.
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
