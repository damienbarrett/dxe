# Plan: consolidate the root plan documents

## Status

Open. R1, R2, R4, R5, R6 (structural half only), and R7 have been executed —
see Git history and `plans.md`. R3, R6's owner/revisit-trigger assertion, and
R8 remain open, each blocked on a precondition this plan cannot itself
satisfy; see their sections below, and `plans.md`, where each is folded in as
an entry with its own revisit trigger.

Written 2026-09-19 against the tree on `fix/dx-wait-ssh-probe-budget`;
executed the same day. Owner: _unfilled_. Revisit trigger: when the
precondition on R3, R6, or R8 (below) is met.

Scope: the nine plan-shaped Markdown files at the repository root, the index
`plans.md`, and the `docs/refactor/` material that already governs part of this
work. Out of scope and excluded from every inventory and gate below: the
`consolidate-plans-*.md` selection documents, including this one. Those
selection documents have since been resolved: the two unselected drafts were
deleted, and this document — the selected one — was renamed from
`consolidate-plans-anthropic-opus-5.0.md` to `consolidation-plan.md` and
folded into the standard `plans.md` index as an Open plan once its refactors
were executed or deferred.

## Shape of the work

Eight independent refactors. Each is **one commit** — R6 is two, for the reason
given there — revertible with a single `git revert`, and **depends on no other refactor** — any subset, in any order,
leaves the tree consistent and the suite green. Two carry a precondition (a
repository gate or an ownership decision), which is a reason to wait, not a
dependency on another refactor here.

None of this is gated behind the open engineering work. The alternative — hold
every document until P7, P10, B1, the refactor phases, and the declarative-Nix
tiers land, then archive in one pass — defers a true index behind months of
unrelated work and lets the drift compound. The single exception is R3, where
the repository itself sets a gate.

| # | Refactor | Touches | Precondition |
| --- | --- | --- | --- |
| R1 | Commit the in-flight removal of four completed plans | the files already in that change set, plus seven comments | none |
| R2 | Delete the six landed code-review items from `plan.md` | `plan.md` | none |
| R3 | Delete `plan.md` Part A, the completed upgrade record | `plan.md`, `docs/refactor/checklists/phase-6.md` | phase‑6 item 5 |
| R4 | Delete the two completed historical records | `herdr-refactor.md`, `bump-disposition-track.md`, 3 referrers | none |
| R5 | Strip landed phases from the two refactor plans | `refactor-plan.md`, `refactor-v2-final.md` | none |
| R6 | Enforce the index with behavior assertions | `plans.md`, `tests/test_section10_docs.sh` | none |
| R7 | Record the conflicts between live plans | `plans.md`, `plan.md` | none |
| R8 | Fold the three no-design stubs | 3 stubs, `plans.md` | an owner each |

Removal is the established pattern, not an invention: `plans.md` already
records that the four completed plans "have been removed; their implementation
and history remain in Git." Nothing here is archived into a new directory —
completed material is deleted, and Git holds it.

## Guarantees every refactor keeps

- **No silent loss.** A document or section leaves the tree only when it is
  landed, duplicated in a permanent home, or reachable in Git history with the
  index saying so in the same commit.
- **Open items survive verbatim.** P7, P10, B1, `refactor-v2-final.md`'s open
  phases, and the three stubs' safety properties are no harder to find after
  than before.
- **Link integrity.** `tests/test_section10_docs.sh` walks every `*.md` to depth
  4 and fails on any unresolved relative link. It is green today (verified). It
  is the load-bearing gate for R1, R3, R4, and R5.
- **Gates outrank tidiness.** Nothing is removed past an unmet precondition in
  `docs/refactor/`.
- **Established patterns only** (`constitution.md`): the `## Status` + `Owner:`
  + `Revisit trigger:` header the three stubs already use, the `plans.md` index,
  and the `docs/refactor/checklists/` phase files. No new document format, no
  new test runner.

## R1 — Commit the in-flight removal of four completed plans

The deletions of `bump-disposition-plan.md` (635 lines), `herdr-plan.md` (357),
`herdr-theme-plan.md` (261), and `performance-plan.md` (969) are unstaged; the
pointer repairs that keep them from breaking links are unstaged; the index that
announces them is staged. Commit the whole set as one change.

The Markdown repairs are already written — do not redo them. What is missing is
**seven** dangling pointers the repairs did not reach, five in test comments and
two in production bootstrap comments:

```
tests/test_section16_persist_storage.sh:194        bump-disposition-plan.md
tests/test_section14_tinty_theming.sh:761,763     herdr-theme-plan.md
tests/test_section23_herdr.sh:328                 herdr-theme-plan.md
tests/test_section23_herdr.sh:685                 herdr-plan.md
container/…/bootstrap/activation.sh:244           herdr-plan.md (H4/H9)
container/…/bootstrap/persistence.sh:312          herdr-plan.md
```

Repoint each at Git history in the same idiom the Markdown repairs use, keeping
the surrounding assertion and intent untouched — the two bootstrap comments cite
a deleted plan for *why* a guest-invariant layout exists, so restate the reason
rather than dropping the sentence. Add `bump-disposition-track.md` to
`plans.md` — it is the one document the index omits entirely.

**Stage explicitly, never `git add -A`.** Three untracked `consolidate-*.md`
selection documents sit in the root, and `dx_key`, `dx-test_key*`,
`dx-mount-*_key*` and `tests/coverage/out/` are ignored there. A blanket add
sweeps the selection documents into the commit.

Re-measure before executing: every line count in this plan was taken on
2026-09-19 and the branch has moved since.

**Gate:** link walk green; `git diff --check` clean; the sweep below returns only
`see Git history`-qualified lines and the selection documents' own tables:

```bash
grep -rn -E 'bump-disposition-plan|herdr-plan\.md|herdr-theme-plan|performance-plan\.md' \
  --include='*.md' --include='*.sh' . | grep -v consolidate-plan
```
**Rollback:** one revert restores four files and their pointers together.

## R2 — Delete the six landed code-review items from `plan.md`

`plan.md`'s Part B table claims eight items, of which six are closed. Verified
in the tree today:

| Item | Verified state |
| --- | --- |
| P3 | landed — `bin/dx-sync-bootstrap`; the document already says "no action" |
| P4 | dropped after review; no code to carry |
| P5 | landed — `bin/lib/dx-host-util.sh:210` warns and defaults to `UTC` |
| P6 | landed — `configure_timezone` resolves via `resolve_timezone_file` (`container/…/bootstrap/system.sh:98`) |
| P8 | landed — no `start_ssh` remains anywhere |
| P9 | landed — `persistence.sh:219` passes `DBUS_SESSION_BUS_ADDRESS` through `env` |
| P7 | **open** — unanchored `findmnt -n -o TARGET,FSTYPE /nix \| grep -q "$fs_type"` at `container/…/bootstrap/base-and-storage.sh:629` |
| P10 | **open** — `truncate -s 64G` hardcoded at `base-and-storage.sh:669`, registered default `20G` (`bin/lib/dx-config.sh:41`), documented `20G` (`docs/configuration.md:27`), and `bin/dx-create-container` still forwards no size (volumes from line 45) |

Delete the six closed rows and their entries. Delete the stale decision block
that still says "Delivery — deferred … No implementation yet", which six
landings contradict. Delete the two dated review-reconciliation sections, which
record a completed review.

Keep P7, P10, and B1, and refresh their citations: every path in the table
points into the retired `dx-nixos-25.11` context dir, and P10 cites
`bin/dx-lib.sh:40`, now a 23-line shim.

**P7 also names the wrong function.** `setup_nix_volume` is now a timing wrapper
around `setup_nix_volume_impl` (`base-and-storage.sh:707-721`) with no production
callers; the live unanchored check is in `prepare_nix_volume_impl` at `:629`.
Fixing P7 as written edits dead code and leaves the defect in place. Repoint the
subject, and see R7 — `refactor-v2-final.md` Phase 2 deletes that wrapper.

**Gate:** no surviving claim cites a path that does not resolve; P7, P10, and B1
read the same as before apart from corrected paths.
**Rollback:** one revert; no other file is touched.

## R3 — Delete `plan.md` Part A, the completed upgrade record

Part A records a finished 26.05 upgrade, and its reusable content already has a
permanent home: `docs/release-maintenance.md` carries the release-pin
procedure, the base-image alignment rule, `Upgrade / Bump` steps 1–8, and the
one-time changeover with its canary gate. Removing Part A is therefore deleting
a duplicate, not discarding a procedure — but confirm that section by section
before deleting, and migrate anything with no equivalent.

**Precondition — `docs/refactor/checklists/phase-6.md` item 5** archives this
material "only after its remaining status items are confirmed complete." P7,
P10, and B1 are open, so the precondition is unmet. Two honest routes:

1. close P7 and P10 first — both are Low severity and small — then do R3 and
   check item 5 off; or
2. do R3 with R2 already landed, and amend item 5 in the same commit to state
   that the open items now stand alone, which is what the precondition exists
   to protect.

Route 1 is preferred. Do not check item 5 off under route 2 unless the amendment
is in the same commit.

**Gate:** `docs/refactor/checklists/phase-6.md`'s `../../../plan.md` links still
resolve or are updated in the same commit; every deleted Part A section is
named with the `docs/release-maintenance.md` section that carries it.
**Rollback:** one revert restores Part A; nothing depends on its absence.

## R4 — Delete the two completed historical records

`herdr-refactor.md` (1249 lines) records a review whose verdict passed;
`bump-disposition-track.md` (762) is an hourly observer log for a lock refresh
that completed. Both are finished records sitting in the root beside live plans,
named like plans. Delete both.

Two things must move before they go. `herdr-refactor.md`'s one remaining
optional follow-up (the R6 inventory and snapshot cleanup) becomes an
explicitly-optional entry in `plans.md`, or is dropped with a reason recorded —
removing a record must not quietly retire live work. And `dx-start-plan.md`
depends on this record substantively, not decoratively: lines 9, 94, 125, and
180 cite it for the L6 misclassification and the two corrected claims. Restate
what `dx-start-plan.md` needs inside `dx-start-plan.md`, then repoint the
citations at Git history. Also repair `README.md`'s Project records links (lines
136–138) and the comment at `tests/test_herdr_config_persistence.sh:368`.

**Gate:** link walk green; `README.md` stays under 250 lines (currently 138) and
keeps its `docs/<doc>.md` links; `dx-start-plan.md` still stands on its own,
read cold.
**Rollback:** one revert restores both records and the citations together.

## R5 — Strip landed phases from the two refactor plans

`refactor-plan.md` narrates Phases 0–5 as decisions; all six are checked off in
`docs/refactor/checklists/`, and of Phase 6's items, 2, 3, 4, and 6 are checked
while 1 and 5 are open with reasons recorded. Delete the landed narrative and
leave the two open items, pointing at the checklists as the record.
`refactor-v2-final.md` opens by declaring prerequisite A1 already closed;
delete that and any other closed material, leaving the open phases.

**Do not edit checklist semantics** under `docs/refactor/checklists/` — the
checklists are the record these documents defer to, and R5 only stops the root
documents from paraphrasing them.

Commit the two files separately so either can be reverted alone.

`declarative-nix-plan-a.md` is deliberately untouched here: it is a two-week-old
audit of 17 findings, some of which may already be fixed. Re-verify its findings
against the tree before deleting any of them; that verification is its own
refactor, not part of this one.

**Gate:** `./tests/run-tier.sh unit/static` green; `README.md`'s
`refactor-plan.md` links still resolve; no open item loses its gate reference.
**Rollback:** one revert per file.

## R6 — Enforce the index with one behavior assertion

`plans.md` is prose today: a plan can be added, removed, or falsified without a
test noticing. Append the status vocabulary to it — *Partially complete*
(landed work plus named open items), *Open* (problem statement or unadopted
audit; requires `Owner:` and `Revisit trigger:`), *Historical* (record only) —
and add one assertion to Section 10, which already owns documentation contracts
and already walks every Markdown file:

- every plan document at the root is listed in `plans.md` under exactly one
  status;
- every `plans.md` entry resolves to a file that exists;
- every entry listed Open names an owner and a revisit trigger.

Enumerate by an explicit list or a glob that excludes `consolidate-plans-*.md`,
so the selection documents cannot trip it. Per `constitution.md`, demonstrate
the assertion red before green — add a throwaway plan file, watch it fail —
rather than asserting the property in prose.

**The owner check is red on today's tree**: all three stubs read
`Owner: _unfilled_`. It cannot land until someone is named. Split R6 into two
commits — the structural assertions (indexed, resolves) first, which are green
after R1, and the owner assertion once owners exist — rather than weakening the
check to make it pass, or blocking the other two behind a naming decision.

**Gate:** `./tests/run_all_tests.sh --skip-integration --section=10` green, and
the new assertion demonstrably fails on an unindexed plan.
**Rollback:** one revert removes the assertion and the vocabulary together.

## R7 — Record the conflicts between live plans

A true index is not enough: two live plans can prescribe contradictory work on
the same code, and no amount of accurate status surfaces that. Three exist
today. Record each in `plans.md` beside the entries it spans, and correct the
affected document:

- **P7 versus `refactor-v2-final.md` Phase 2.** P7 says to fix the FSTYPE match
  in `setup_nix_volume`; Phase 2 deletes `setup_nix_volume`/`_impl` outright as
  dead code (disposition A2). Whichever lands first makes the other read as done
  while the live defect at `prepare_nix_volume_impl` (`base-and-storage.sh:629`)
  survives. Resolution: P7's fix belongs in the preparation record Phase 2
  builds, not in the wrapper.
- **P10 versus the config registry.** Three values disagree: `plan.md` decided
  "canonical default `64G`" in 2026-06, the registry and docs say `20G`
  (`bin/lib/dx-config.sh:41`, `docs/configuration.md:27`), and the code
  hardcodes `truncate -s 64G` (`base-and-storage.sh:669`). P10 cannot be
  implemented without picking one; the registry is the newer decision.
- **`declarative-nix-plan-a.md` #12 versus `refactor-v2-final.md` A1.** #12
  argues the coverage ratchet punishes exactly the refactors below it; A1 is
  closed on a ratchet figure measured at `7ffa66b`. If #12's reform lands, A1's
  measurement is against a scope that no longer exists.

This is recording, not resolving: each conflict gets a named resolution or an
explicit "undecided, owner X". It is what the index cannot express on its own,
and it is cheap — a paragraph each.

**Gate:** no live plan prescribes work on code another live plan deletes without
the conflict being named where a reader of either document will see it.
**Rollback:** one revert.

## R8 — Fold the three no-design stubs (optional)

`image-pin-collision-plan.md` (52 lines) and
`post-remount-trust-root-plan.md` (111) state safety properties with no design;
`dx-start-plan.md` (185) diagnoses a defect with no selected fix. Folding them
into one open-items document shrinks the root by three files; keeping them
standalone keeps each revisit trigger visible in its own file.

**Precondition:** each has a named owner — all three read `Owner: _unfilled_`
today. The owner field is the only thing keeping these documents reachable;
folding them while unowned buries three live safety constraints.

`image-pin-collision-plan.md` and `post-remount-trust-root-plan.md` are the
stronger pair to fold: both turn on verifying the persistent store before
trusting it, one on a pin change and one after remount, so a single document
would state the shared invariant once. That is a design argument, not tidying.

Recommendation: defer until owned. If R4 lands first, fold `dx-start-plan.md`
only after it has absorbed what it needs from `herdr-refactor.md`.

**Gate:** every safety property and revisit trigger survives the fold verbatim;
`tests/test_section9_host_scripts.sh:469` and
`tests/test_bootstrap_publication.sh:169`, which cite `dx-start-plan.md`, are
repointed.
**Rollback:** one revert.

## What remains when all eight land

Measured today, the root carries **10 documents, 4,026 lines**. The end state,
with R7 deferred, is **8 documents, ~1,510 lines**:

| Document | Now | After | What is left in it |
| --- | ---: | ---: | --- |
| `plans.md` | 53 | ~90 | the index, the three-status vocabulary, and the three recorded conflicts |
| `plan.md` | 512 | ~95 | P7, P10, B1 — nothing else |
| `refactor-plan.md` | 172 | ~80 | the two open Phase 6 items, the unmet definition-of-done bullets, and the measurable-targets table |
| `refactor-v2-final.md` | 427 | ~400 | open phases 1–5, the four target contracts, the review rationale minus closed A1 |
| `declarative-nix-plan-a.md` | 503 | 503 | untouched, pending its own findings re-verification |
| `dx-start-plan.md` | 185 | ~200 | *grows* — absorbs the L6 substance from the deleted record |
| `image-pin-collision-plan.md` | 52 | 52 | unchanged |
| `post-remount-trust-root-plan.md` | 111 | 111 | unchanged |
| `herdr-refactor.md` | 1249 | — | deleted (R4) |
| `bump-disposition-track.md` | 762 | — | deleted (R4) |

With R8 folded in as well, the three stubs and `plan.md`'s residue become one
owned open-items document: **5 documents, ~1,540 lines**. Note the line count
barely moves — R8 buys fewer documents, not less text. The 2,500-line drop comes
from R2, R3, and R4 deleting material that is already complete.

`refactor-plan.md` is the one that resists reduction: its measurable-targets
table is a live baseline (largest test file still 1,719 lines, 492 source-text
assertions, 14 unclassified skips), so it cannot be deleted as finished work
even though most of its narrative is.

Unchanged and outside the root, holding the record: `docs/refactor/`
(checklists, D1–D6 decisions, migration gates, validation matrix),
`docs/release-maintenance.md`, and Git history for all six deleted documents.

## Decisions required

1. **R3 route.** Close P7 and P10 first (preferred), or amend phase‑6 item 5 in
   the same commit. Both are small; the first is honest without wording changes.
2. **`declarative-nix-plan-a.md`.** Keep Open with an owner, or archive
   unadopted. Recommendation: keep it Open through R6 and decide adoption on its
   merits — consolidation should not be the event that silently adopts or
   discards a 503-line audit.
3. **R8 now or when owned.** Recommendation: when owned — but fold the two
   store-trust stubs as a pair when it happens.
4. **`plan.md`'s name, once it is three open items.** A file called `plan.md`
   re-attracts content by its name alone. Recommendation: rename it for what it
   holds, or fold it into R7's open-items document.
5. **Where `refactor-plan.md`'s definition of done and targets live.** They are
   refactor record material, and the record is `docs/refactor/`, beside D1–D6
   and the gates. Moving those two sections there deletes one more root
   document; keeping them at root keeps the acceptance contract in one hop from
   `README.md`. Recommendation: move them, and repoint `README.md`.
6. **These selection documents.** Delete the unselected `consolidate-plans-*.md`
   files, and this one, once its refactors are executed or folded into
   `plans.md`. They must not survive as a fourth category of root document.

## Non-goals

- Closing P7, P10, or B1, or selecting a design for any of the three stubs.
- Changing checklist semantics under `docs/refactor/checklists/`.
- Editing the content of the two historical records; they are deleted as a
  whole, not rewritten.
- Any behavior change in `bin/`, `container/`, or bootstrap. R1 edits two
  comment lines under `container/…/bootstrap/`; no executable line moves. This
  plan touches documentation, seven comments, and one assertion.

## Verification

```bash
# Documentation contracts, including the Markdown link walk. R1, R3, R4, R5, R6.
./tests/run_all_tests.sh --skip-integration --section=10

# Full static tier, for any refactor that touches a test file.
./tests/run-tier.sh unit/static

# Dangling pointers to deleted plans, in prose as well as links. R1, R4.
grep -rn -E 'bump-disposition-plan|herdr-plan\.md|herdr-theme-plan|performance-plan\.md' \
  --include='*.md' --include='*.sh' . | grep -v consolidate-plan

# Nothing unintended staged, no whitespace damage. Every refactor.
git status --porcelain && git diff --check
```

Every failure mode of a refactor that deletes or moves documents surfaces in the
link walk first.

## Definition of done

Per refactor, its own gate. Across all eight:

- The root holds live plans only; every completed plan and every completed
  section is gone, with Git history and `plans.md` accounting for it.
- `plans.md` lists every live plan under one of three stated statuses, and no
  entry contradicts its document or the code.
- A test fails if a plan is added without an index entry, if an entry dangles,
  or if an Open entry has no owner and no revisit trigger.
- P7, P10, B1, and the three stubs' safety properties are findable from
  `plans.md` in one hop.
- `docs/refactor/checklists/phase-6.md` item 5 is checked off only if it landed.
- No live plan prescribes work on code another live plan deletes, unnamed.
- No pointer to a deleted plan survives unqualified, in links or in prose.
- Each commit reverts cleanly on its own.
