# Keyring owned by dx-ai (Branch 16, `refactor/keyring-owned-by-dx-ai`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 16.
No home directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `refactor/keyring-owned-by-dx-ai`, from `main` `6d9a4ca`, rebased onto
`main` `2acffa9` before landing (commit ids below are the rebased ones).
Commits, in order: `46d8698` (the move: `scripts/lib/dx-keyring.sh` gains the
real probe, stale cleanup, idempotent start and status; new `dx-keyring`
command; `dx-ai` delegates; Home Manager wiring; bootstrap loses every
keyring function and call; tests retargeted — one commit because the
coverage gate couples the removal and the retargeting), `128312d` (ratchet),
`77075d8` (docs and plan), `af4eb21` (ratchet re-measure after the rebase).

## Why and what (user decision 2026-09-27: option 4, explicit start, no wrapper)

The keyring (a per-user D-Bus session bus plus `gnome-keyring-daemon`'s
Secret Service) exists in the guest for one consumer, `agy`, which `dx-ai`
installs. Bootstrap used to start it and had to resolve binaries only the AI
generation provides (Branch 15); it also had a latent defect: after a
container restart the previous boot's `/tmp/dbus-*` socket file survives in
the writable layer, the old liveness check (`[ -S socket ]`) accepted it as a
live bus, `dbus-daemon` was never started, and `gnome-keyring-daemon` was
started against a dead address; `dx-ai` repeated the mistake and started a
second keyring daemon. Now:

- Bootstrap keeps no keyring knowledge (124 lines removed; a Section 3
  assertion fails if any returns).
- `scripts/lib/dx-keyring.sh` is the single implementation: `dx_keyring_probe`
  makes a real client call (`dbus-send … org.freedesktop.DBus.ListNames`
  under a timeout — chosen after showing live that a killed daemon's socket
  file still satisfies `[ -S ]` and that `kill -0` still succeeds on the
  unreaped zombie), `dx_keyring_clear_stale` removes the address file and
  socket only after a failed probe, `dx_keyring_start` is idempotent (a live
  bus with `org.freedesktop.secrets` registered starts nothing), and
  `dx_keyring_status` reports live/stale/absent with pids.
- `dx-ai`'s `dx_ai_ensure_keyring` delegates to the library (loaded through
  the same three candidates as the OpenCode helper); a new `dx-keyring
  start|status` command, installed by Home Manager like `dx-ai`, is the
  explicit way to bring the keyring up after a restart. No automatic
  start-on-`agy` wrapper; the `dbus-run-session`-per-invocation alternative
  is recorded in `docs/guest.md` as deferred (a fresh bus per run means a
  locked keyring per run).
- Found in passing and fixed: the previous `dx_ai_ensure_keyring` loaded the
  library from a Home Manager path that Home Manager never actually
  installed, so on a real guest `dx-ai`'s last step always failed; every
  test had stubbed that function.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | 99/0/0 aggregate; Section 3 133/0/0 |
| G1 container-free contracts (runner-matched) | "All tests PASSED!" (run against a disposable clone of the worktree) |
| G1 pinned ShellCheck 0.10.0 | clean |
| G2 coverage | `covered=100%`; ratchet 1789 → 1791 on the branch's own base, 1949 after the rebase onto a `main` that had gained Branch 10 |
| G3 Nix | `nix flake check --no-build --no-write-lock-file`: "all checks passed!"; `flake.lock` unchanged (two `home.file` additions only) |
| G4 live | `dx-test`, below |
| G5 CI | GitHub Actions on the pushed rebased branch, green before `main` was fast-forwarded |

Red/green: the "bootstrap contains no keyring code" assertion failed against
the pre-removal tree; two coverage-fixture regressions surfaced through the
coverage gate's own trap and were fixed with explicit fixtures.

## Live validation on `dx-test` (default 12 GB)

- (a) `dx-start-container` + `dx-wait-ssh` on the new bootstrap: no
  keyring/dbus lines in the bootstrap log, no dbus/keyring processes — as
  designed.
- (b) `dx-keyring status` → `stale` (leftover record); `dx-keyring start` →
  live with real pids; `dbus-send ListNames` shows `org.freedesktop.secrets`.
- (c) `dx-ai` (from cache), twice → "already running"; pids identical before
  and after — no second daemon.
- (d) `dx-stop-container` / `dx-start-container` / `dx-wait-ssh` →
  `dx-keyring status` reports `stale` (the historical defect reproduced
  live); `dx-keyring start` recovers with exactly one new pid of each.
- (e) `dx-recreate` + `dx-wait-ssh`: clean; `status` correctly reports
  `stale` for the surviving `/persist` record.
- (f) `DX_TEST_DESTRUCTIVE=1 … --section=17`: 104/0/0 including the new
  live `dx-keyring` assertions.
- (g) Full live tier (28 files): one failure, `test_section6_tools.sh`'s
  tmux-resurrect restore probe — a file this branch does not touch;
  reproduced three times in isolation with three different outcomes (one
  pass, two different failing sub-checks), i.e. pre-existing timing
  flakiness in a live tmux-server-startup probe. Recorded as a backlog item
  in the plan's Observations; accepted for landing on that basis.
- `dx-test` cold-stopped; volumes and AI generation intact; `dx-host` and
  the NAS untouched.

Dual-target stand-in: Section 27 green; both Phase 0 dry-runs exit 0.

## Landing (2026-09-27)

Rebased onto `main` `2acffa9` (Branch 10 had landed meanwhile); only
`tests/coverage/ratchet.env` overlapped. This branch's own delta is
identical before and after the rebase (verified by diffing the diffs), so
the results above stand for the rebased commits. Re-checked by the
coordinating session on the rebased tip: bash-3.2 suite, Sections 1, 10 and
27, the Phase 0 dry-runs, the private identifier scan. `dx-host` will pick
this up at its next promotion (Appendix D); until then its bootstrap still
starts the keyring the old way, and `dx-keyring` is not yet installed there.
