# Plan: dispose of the validated lock refresh, then close the last gap

## Status

Open. Written 2026-08-30, after a session that fixed the guest SSH host
identity, the image-store import, and the bootstrap launcher, and corrected two
stale documents. This plan covers what is left, and deliberately scopes out the
one thing that looks most interesting.

The immediate problem is not a defect. It is that a **validated but uncommitted**
lock refresh is sitting in a worktree while the canary runs it and the primary
does not. That state decays: in two weeks nobody can tell whether the branch was
validated or abandoned, and the validation cost real machine time.

## Step 1 — Land the lock refresh (recommended)

`bump/lock-refresh` in the `dxe-bump` worktree holds a `flake.lock`-only change
that moves the stable inputs on their existing 26.05 branches:

| input | from | to |
| --- | --- | --- |
| `nixpkgs` | `95ca1e20` (2026-06-30) | `d57af924` (2026-08-27) |
| `home-manager` | `868d0a69` | `65258d5c` |
| `nixvim` | `667c8471` | `e2c3f9f3` |

`nixpkgs-unstable` is deliberately untouched, per the documented recipe, so the
optional AI set does not move during a stable refresh.

Evidence it is safe:

- full canary suite on `dx-test`: **1018 passed**, 1 failure since diagnosed as
  a test depending on the developer's gitignored `dx_key` and fixed in `c985d0c`
  — not a bump breakage;
- the volume-reusing recreate imported **881 paths in 8s** and booted first
  time, exercising the corrected importer at realistic scale;
- `dx-test` has since run this lock continuously and healthily.

It is a lock-only change, so it adopts through `dx-recreate`; no salvage is
required.

**State the deviation explicitly in the commit.** The alignment rule
(`docs/release-maintenance.md`) says the image tag should follow the locked
release's default Nix, which is now 2.34.8 against a pinned 2.34.7. It cannot
follow: moving the pin requires the destroy-and-rebuild-with-salvage procedure,
because of the store-path collision recorded in that same document. The
combination is empirically fine — the canary runs the bumped lock on the 2.34.7
image — but it is a knowing deviation, and an unexplained mismatch is
indistinguishable from an oversight to the next reader.

Steps:

1. Rebase `bump/lock-refresh` onto `main` (it predates `c985d0c` and `21e48ca`).
2. Commit the lock with the deviation stated.
3. Adopt on the primary with `dx-recreate` when convenient, and confirm the
   import reports `copying N paths` with N > 0 and no
   `did not materialise required bootstrap paths`.

Alternative, if the deviation is unwelcome: park the branch and revisit when the
pin bump is scheduled, since that event resolves both together. Do not leave it
undecided.

## Step 2 — Clean up

- Remove the `dxe-bump` worktree once the branch is landed or parked.
- Let `dx-test` follow whatever `main` says, rather than sitting on a lock the
  primary does not have.

## Step 3 — `ensure_essentials_valid` ordering

The last real correctness gap. `bootstrap_main` calls it *after*
`nix_restore_image_default_profile`, which is the first consumer of the
post-remount `PATH`, so the repair can never run — it is dead code in practice.
`a428c55` originally placed it immediately after the remount.

Reordering alone does not fix it: the function needs a working `nix`, which is
exactly what is missing when it would be needed. This is a design question about
what the guest can rely on between the remount and the first successful command,
not a line move.

Priority is genuinely third. The enumeration fix and the pre-remount check now
stand in front of it, so it is a fallback that has never been reached rather
than an exposure.

## Explicitly deferred — collision quarantine

Making a volume-reusing pin bump possible means teaching the importer to
quarantine or skip image store paths that collide by name and differ by content
(`docs/release-maintenance.md`, "Bumping the Nix image pin"). That would make
every future pin bump dramatically cheaper than the salvage procedure.

It is deliberately **not** next. It is a design change with consequences for
what the booted guest can trust, and it deserves to be a deliberate decision
rather than the thread that gets pulled because it is the most interesting one.

## Verification

Each step above is complete when `tests/run-tier.sh unit/static` is green and,
where guest behaviour changed, the live tier is green on `dx-test` before the
primary is touched. The coverage gate (`tests/run-coverage-linux.sh`) must stay
at 100% over the declared scope.
