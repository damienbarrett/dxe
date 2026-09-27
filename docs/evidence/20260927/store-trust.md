# Store trust (Branch 12, `fix/store-trust`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 12 and
`store-trust-plan.md`'s Problems 1 and 2. No home-directory paths, keys,
fingerprints, or NAS identifiers appear below.

Branch `fix/store-trust`, from `main` `6688a7c`, rebased onto `e9076fc` before
landing (7 commits; every file's delta identical before and after the rebase,
verified by diffing the diffs). Implemented by a Sonnet subagent against
fixtures and Section 25's real-Nix runner only; designs selected, live-gated,
and landed by the coordinating session. Design comparison:
`docs/refactor/store-trust-design.md`.

## Decisions (coordinating session, 2026-09-27, after the design comparison)

- **Problem 1 (volume-reusing image-pin bump):** Reading 1 and Design P1-A —
  make the refusal deliberate over the bounded bootstrap-root set, covering
  both collision shapes the characterisation found, pre-remount and
  recoverable. No quarantine, no import of mismatched content (P1-B/P1-C
  rejected, per the plan's own "not collision quarantine").
- **Problem 2 (post-remount trust root):** Design 2-3 — a minimal
  presence-and-execution fail-fast over the named early tools immediately
  after the volume reaches its final place, identical in apple-image and
  direct-volume mode (Q6's accepted posture). Design 2-1 recorded as a
  possible apple-only complement later; 2-2 rejected.
- **The recovery path is a real command:** `bin/dx-reset-nix-volume`
  (authorised scope addition; the user was told and did not object). It
  refuses while the container exists, deletes only `DX_NIX_VOLUME` through
  the runtime contract, leaves `/persist` and the bootstrap volume alone, and
  both refusals name it. The pin-bump procedure becomes `dx-destroy` →
  `dx-reset-nix-volume` → `dx`, with `/persist` kept — the same "start from
  scratch for `/nix`" remedy the QNAP direct-volume mode already uses.
- No shared verifier; one branch.

## What the characterisation found (design note, sections 1.1 and 2.1)

- The known collision has **two shapes**. Shape A (the incident on record): the
  image's own database disagrees with its own on-disk bytes, producing the
  observed "hash mismatch importing path" error. Shape B, previously
  undocumented: the reused volume already validly holds *different*
  self-consistent content under the same path name, and `nix copy` **silently
  skips it with exit 0**. Both reproduced with real Nix in a throwaway
  `nixos/nix:2.34.8` container (`nix-store --dump-db`/`--load-db`), removed
  after use.
- For Problem 2, breaking one of `nix_restore_image_default_profile`'s own
  tools (`readlink`, `chown`) after a valid remount either misdiagnosed the
  failure or failed with no output, and `ensure_essentials_valid` was never
  reached; recorded red on `main` before any production change.

## What changed

- `bootstrap/common.sh`: `verify_remount_prerequisites`, called from
  `bootstrap_main` between `populate_prepared_nix_volume` and
  `nix_restore_image_default_profile`. For `readlink mkdir mktemp rm ln chown
  mv setpriv bash nix` it resolves each name and executes `--version` (a bare
  lookup would pass a truncated binary), then checks `run_as_dx true`; any
  failure names the tool and the recovery command.
- `bootstrap/base-and-storage.sh`: `nix_verify_no_bootstrap_path_collision`,
  called on the reuse branch of `populate_prepared_nix_volume` before
  `nix_store_import_registered` — only when an import is actually required,
  so a healthy reused volume sees no extra work. Per root: `nix store verify
  --no-trust` against the image's own store (Shape A), then a direct hash
  comparison between image and volume for a path present in both (Shape B).
- `bin/dx-reset-nix-volume` (new), with Section 9 and Section 33 tests.
- Docs: `docs/release-maintenance.md` ("Bumping the Nix image pin" now
  documents the refusal and the tested recovery; the August alignment waiver
  is re-scoped — the mechanism exists, only its live application to the
  primary remains — and the conflicting rollback wording is fixed),
  `docs/lifecycle.md`, `docs/troubleshooting.md`, `store-trust-plan.md`
  status, the consolidation plan's Branch 12 row/section, `plans.md`.

## Gates

| Gate | Result |
| --- | --- |
| Fast tier (`tests/run-tier.sh unit/static`, coordinating session, rebased tip) | 22 sections, 1,206 passed, 0 failed, 14 usual local skips |
| bash-3.2 | 99 passed, 0 failed |
| Pinned ShellCheck 0.10.0 and apt 0.9.0 | clean |
| Section 25 real-Nix runner (throwaway `nixos/nix:2.34.8`) | 6/6, both collision shapes red then green |
| Coverage (`tests/run-coverage-linux.sh`) | `covered=100%`, ratchet 2164 → 2153 (test dilution; re-measured on a clean export at landing: 6,876 / 31,930 = 2153) |
| Nix (`nix flake check --no-build`) | all checks passed; `flake.nix`/`flake.lock` untouched |
| Private identifier scan | clean |

Red/green: Section 3 P10 (Problem 2) and P11 (Problem 1) fail with the fix
stashed; `dx-reset-nix-volume`'s Section 9 tests fail with the script moved
aside. Two infrastructure findings fixed along the way: the new real-Nix
block skips gracefully in the sanctioned no-Nix coverage container, and a
kcov line-attribution gap in the collision loop (matched the file's existing
single-line-loop convention rather than adding an exclusion).

## Live exercise on `dx-test` (coordinating session, 2026-09-28)

The plan's "isolated live and destructive recovery exercise using only
non-default resources", run from the branch worktree with stdin from
`/dev/null` throughout (keys copied from the main checkout):

- **Healthy reused volume:** `dx-test` started on the new bootstrap generation
  with both checks present; SSH ready in 22 s; no refusal message in the
  bootstrap log.
- **Refusal:** `dx-reset-nix-volume` exited 1 while the container existed,
  naming `dx-destroy-container`.
- **Reset:** after stop and destroy-container, the reset removed
  `dx-test-nix` only; `dx-test-persist` and `dx-test-bootstrap` were still
  present.
- **Fresh `/nix`, old `/persist`, no manual step:** `dx-create-volumes`
  (new Nix volume), create, start, `dx-wait-ssh` — the bootstrap formatted
  the fresh device, seeded it from the image in 14 s, restored the persisted
  SSH host identity, and Home Manager activation completed; SSH was ready
  under 5 minutes after the reset. `/persist` held the same 166 files before
  and after; the home directory's files kept their pre-reset dates.
- **Tools return:** keyring `stale` before `dx-ai`, `live` after; all of
  `codex gemini claude agy herdr opencode nvim tmux` present; `/nix` at
  4.9 GB after the rebuild (the old volume had grown to 11 GB).
- **One dangling symlink in the home directory, benign and pre-existing:**
  `~/.nix-defexpr/channels` → the (never created) channels profile under
  `~/.local/state/nix/profiles`. It is Nix's single-user default with no
  channels configured (flakes only) and is dangling on the primary guest too,
  so it is unrelated to the reset.
- **Full Apple live tier on the rebuilt guest:** 35 sections, 1,724 passed,
  0 failed, 8 skipped ("All tests PASSED!"), then a cold stop; `dx-test` left
  stopped.
- **Not done live, deliberately:** fabricating a store collision on the live
  guest. The real-boundary validation the plan requires was done with real
  Nix in Section 25's isolated container (both shapes); the live exercise
  proves the healthy path and the recovery procedure end to end.

## Landing (2026-09-28)

Rebased onto `main` `e9076fc` (only the promotion record had landed
meanwhile); every file's delta identical before and after (diff of diffs);
ratchet re-measured on a clean export equal to the committed 2153 bp; private
identifier scan clean; fast tier re-run on the rebased tip (above). The
alignment waiver in `docs/release-maintenance.md` stays open, re-scoped: the
procedure exists and is proven on `dx-test`; applying it to the primary is a
separate, explicitly approved, `/nix`-destructive step for the next real
pin change.
