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

## Two numbers, not one

A single "100%" over a declared scope is a vanity metric on its own. After Phase
1b the ~20 executables in `bin/` — where the user-facing behavior lives — are
outside the measured scope. The exclusion-file test catches new *entries*; it does
not catch logic being left in, or pushed back into, entrypoints to stay under the
bar. The excluded share can grow while the headline number stays at 100%.

The coverage job therefore reports **two** numbers:

1. **Gated** — 100% line coverage over the declared sourceable scope. A regression
   fails CI.
2. **Ratcheted** — the share of total repository shell lines that falls *inside*
   the covered scope. Baselined at the Phase 1b exit gate, published alongside the
   report, and forbidden to regress. This is not gated at a fixed value; it is
   gated against its own previous value.

The second number is what makes the first one meaningful. It is tracked in the
plan's [measurable targets](../../../refactor-plan.md#measurable-targets).
