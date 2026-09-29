# D1 — What does "100% code coverage" measure?

Implemented by [Phase 1a](../checklists/phase-1a.md).

[`constitution.md`](../../../constitution.md) requires 100% coverage. That target
is not reachable as stated by the mechanism the plan proposes to measure it:
`kcov` is Linux-only, and the tier it would instrument is precisely the one that
runs with no Apple `container` binary on `PATH`. The macOS- and
Apple-Container-specific branches therefore cannot be covered by the instrument
that reports coverage. Leaving this unresolved makes the definition of done
unverifiable.

## Resolution

Keep the 100% figure and define the scope it applies to rather than weakening the
constitution. Coverage is measured over `bin/lib/*.sh`, the guest
`bootstrap/*.sh` modules, and `container/.../scripts/lib/*.sh` — the pure,
sourceable code the refactor exists to create — executed on Linux under the
stubbed contract suite. Everything else is covered by behavior tests instead,
listed in a short, reviewed exclusion file with a one-line justification per
entry, and that file is itself asserted by a test so exclusions cannot grow
silently.

The same pinned Linux coverage environment used by CI is exposed through a local
wrapper so a macOS contributor can reproduce the report without a native `kcov`
package. Declarative Nix and live Apple Container paths remain outside line
coverage and inside their explicit evaluation/build/behavior tiers.

## More than one number

A single "100%" over a declared scope is a vanity metric on its own. After Phase
1b the ~20 executables in `bin/` — where the user-facing behavior lives — are
outside the measured scope. The exclusion-file test catches new *entries*; it does
not catch logic being left in, or pushed back into, entrypoints to stay under the
bar. The excluded share can grow while the headline number stays at 100%.

The coverage job therefore reports more than the headline percentage:

1. **Gated** — 100% line coverage over the declared sourceable scope. A regression
   fails CI.
2. **Ratcheted** — two further numbers, both against their own previous value
   rather than a fixed target. Until 2026-09-30 this was a single share ratio
   (scope text lines over all shell text lines, including tests), which fell
   when tests were added and rose when comments were added inside a covered
   library — the metric rewarded and punished changes that never touched
   executable behavior. `tests/lib/coverage-metric.sh` (WP1.5 / decision D-1;
   old ratio history at
   [../../evidence/20260930/coverage-ratchet-history.md](../../evidence/20260930/coverage-ratchet-history.md))
   replaced it with `scope_exec_lines` (a **floor**: kcov's own executable
   line count summed over the scope, immune to comments and to tests, which
   are outside the scope) and `unscoped_prod_exec_lines` (a **ceiling**:
   non-comment source lines over the exempt production set in
   `tests/coverage/exclusions.txt`, so logic pushed out of the covered scope
   into an exempt entrypoint to dodge the 100% gate shows up as a
   regression).

These further numbers are what make the headline percentage meaningful. They
are tracked in [baselines.md's measurable targets](../baselines.md#measurable-targets).
