# Documentation map

Where to look, in the order a newcomer usually needs them: an
[entry point](#entry-points) names a command or a starting file; an
[operating doc](#operating-docs) is a manual for running and maintaining the
DXE day to day; a [decision](#decisions) records why the current design is
what it is; [dated evidence](#dated-evidence) is the dated record of what was
actually run and observed; a [review](#reviews) is a point-in-time audit of
the whole repository. `tests/test_section10_docs.sh` keeps this map from
drifting: every operating doc listed below must be linked from here, and
every root plan document must be indexed in [`../plans.md`](../plans.md).

## Entry points

- [`README.md`](../README.md) — quick start, principles, normal workflow, and hotkeys.
- `bin/dx*` — every host command. `tests/test_section10_docs.sh` asserts each
  one is discoverable from the operating docs below; most also answer `--help`.

## Operating docs

- [`lifecycle.md`](lifecycle.md) — lifecycle, helpers, migration, and recovery.
- [`configuration.md`](configuration.md) — configuration, profiles, and `dx-mount`.
- [`guest.md`](guest.md) — guest bootstrap, persistence, optional AI tools, NixVim, and theming.
- [`troubleshooting.md`](troubleshooting.md) — troubleshooting.
- [`release-maintenance.md`](release-maintenance.md) — release, pin, upgrade, and base-image changeover procedures.
- [`qnap-runbook.md`](qnap-runbook.md) — QNAP operator runbook.

## Decisions

- [`refactor/decisions/`](refactor/decisions/) — the numbered decision records
  (D1 coverage, D2 config, D3 CI, D4 mount manifest, D5 bootstrap state, D6
  command boundaries, D7 start-generation).
- [`refactor/migration-gates.md`](refactor/migration-gates.md) — current
  refactor decisions and the operational migration gates the completed
  refactor retained.
- [`refactor/validation-matrix.md`](refactor/validation-matrix.md) — test and
  validation tiers: what CI runs, what is manual and mac-only, and what needs
  a live guest, stated once. [`tests/run.sh`](../tests/run.sh) is the single
  runner every tier wrapper now delegates to, selecting suites by their own
  `# tier:`/`# bash32:` header.
- [`refactor/baselines.md`](refactor/baselines.md) — the refactor's
  measurable-targets baseline.
- The rest of `refactor/*.md` records individual design decisions
  (`arch-neutral-guest.md`, `assessment.md`, `constraints.md`,
  `direct-volume-storage.md`, `docker-adapter-mapping.md`,
  `opencode-validation.md`, `qnap-lifecycle.md`, `qnap-promotion.md`,
  `remote-aware-ssh.md`, `risk-controls.md`, `runtime-boundary.md`,
  `runtime-boundary-inventory.md`, `store-trust-design.md`), and
  `refactor/checklists/` holds the phase-by-phase execution checklists.

## Dated evidence

- [`evidence/`](evidence/) — dated records of what was actually run and
  observed (test transcripts, live-guest verification, coverage-ratchet
  history), one dated subdirectory per work session, e.g. `evidence/20260930/`.

## Reviews

- [`reviews/`](reviews/) — point-in-time repository reviews, indexed at
  [`reviews/README.md`](reviews/README.md).

## Root plans

Active and historical plan documents (`plans.md`, `findings.md`,
`checkout-consolidation-plan.md`, and the rest) live at the repository root,
not under `docs/`, and are indexed in [`../plans.md`](../plans.md).
