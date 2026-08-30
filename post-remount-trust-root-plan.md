# Plan: recovery blind spot for the post-remount trust root

## Status

Open, **no design selected**. Created 2026-08-30 as the durable tracking
artifact split out of `bump-disposition-plan.md` (Step 3). Third priority: two
newer defences sit in front of this path and it has never been reached.

Owner: _unfilled_. Revisit trigger: any change to the post-remount bootstrap
path, or the next boot failure that reaches `ensure_essentials_valid`.

This file records scope and acceptance criteria only. It is not implemented on
the lock-refresh commit stack, and no mechanism has been chosen.

## The defect, stated accurately

`ensure_essentials_valid` is **not** dead code — an earlier framing said so and
was wrong. It executes on every boot and can detect or repair damage in closure
members consumed later, while its own prerequisites remain usable.

The real defect is narrower: `nix_restore_image_default_profile` runs after the
remount and invokes `readlink`, `mkdir`, `mktemp`, `rm`, `ln`, `chown`, and `mv`
before `ensure_essentials_valid` is reached. The verifier itself needs working
shell utilities, `run_as_dx`, and `nix`. So it cannot recover when the corrupted
path **is** one of its own prerequisites, or one of the earlier restore's.

## The invariant to state and defend

After the remount, no binary from the persistent store may be trusted to prove
that same trust root sound.

## Required observable outcomes — decide before selecting a mechanism

| Failure state | Required observable decision |
| --- | --- |
| Healthy reused volume | Boot succeeds without repair/import churn or marker rewrite |
| Missing/corrupt pre-verifier core utility | Independently repair and continue, or fail before trusting it, with an actionable recovery path |
| Missing/corrupt Nix | Independently repair and continue, or fail deterministically before marker publication |
| Corrupt later closure member | Existing bounded content verification/repair behavior remains effective |
| Offline repair | Bounded success from retained image material, or bounded fail-fast — never an unbounded network wait |
| Failed/interrupted recovery | No success marker; persistent state stays unambiguous; the documented retry/reset path works |

## Designs to compare — do not select one by moving a call

1. Pre-remount verification of the target store using image-resident tooling.
2. An absolute captured image toolchain used as the verifier.
3. Deliberate fail-fast when independent repair is impossible.

A separately declared Nix output is declarative, but it is **not** automatically
an independent trust root if its interpreter or libraries still resolve through
the remounted `/nix/store`. Prove independence behaviorally.

## Test contract

Red first: the regression must fail on then-current `main` **for the intended
reason**, and that failure must be recorded before any production change.
Source-shape assertions are not enough — the reproducer removes a prerequisite
between remount and verification.

Use the existing layers deliberately:

- Sourceable orchestration and failure-injection behavior goes in Section 3 or a
  new focused suite dispatched by `run_all_tests.sh`. A new suite must satisfy
  the dispatch-completeness contract in `tests/test_refactor_contracts.sh`.
- Real Nix content/registration/repair behavior goes in Section 25's isolated
  Linux/root runner (`tests/test_nix_store_import.sh`). Coverage probes in
  `tests/test_sourceable_coverage.sh` may reach otherwise unreachable branches,
  but they are not behavioral evidence.
- Per `constitution.md`, any fake `nix`, `mount`, or trust-root command boundary
  is validated against the real boundary at least once.
- Finish with an isolated live and destructive recovery exercise using only
  non-default resources.

Preserve the existing invariant that the image-store identity marker is
published only after successful post-remount validation.

## Implementation constraints

- Preserve the visible `bootstrap_main` ordering and source-only module purity.
- Prefer explicit arguments and results over new exported `DX_NIX_*` steering
  state. Do not hide trust state in a mutable global to make a test injectable.
- Do not add a production test-mode environment branch. Existing patterns favor
  sourceable functions, disposable filesystem fixtures, shell-function command
  fakes, and explicit parameters.
- A new pre-SSHD binary must declare its provider in the locked, separate
  `bootstrapEssentials` output and extend the binary-to-package contract in
  `tests/test_refactor_contracts.sh`. Membership in `dxPackages` does **not**
  make a tool available before SSH.
- Resolve through the checked-in flake with `--no-update-lock-file`. Never use
  the mutable global registry, and never mutate the lock during boot.
- Prefer Nix-native `nix copy` and full-content `nix store verify --no-trust`
  over ad hoc filesystem hashes. Do not add `--no-contents`, and do not treat
  unsigned image-store paths as corrupt merely because signature trust is absent.
- Keep fixed command bodies separate from positional data at every `sh -c` /
  `bash -c` boundary.
- If the chosen design changes persisted marker/state format, land a compatible
  reader before the writer and document the backout, per
  `docs/refactor/risk-controls.md`.
- Preserve 100% coverage over the sourceable scope. Recalculate the ratchet only
  on the finished tree, document any test-driven denominator change, and never
  lower it preemptively.

## Definition of done

- one design selected, with the rejected alternatives and the reason recorded;
- every row of the outcome table has a passing behavioral test at the right
  layer;
- the red reproducer and its recorded failure are in the history;
- unit, coverage, and isolated live/destructive recovery gates green;
- no new exported steering state and no production test-mode branch.
