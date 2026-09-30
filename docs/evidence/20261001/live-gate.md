# dx-test live gate — 2026-10-01 (findings branch)

First live run of `refactor/findings-2026-09-29` against the disposable
Apple-runtime guest `dx-test` (profile `tests/profiles/dx-test.env`, port
2299, every resource named `dx-test-*`). Sanitised: no addresses, keys or
fingerprints. Run logs are retained privately.

## Subject

- Branch tip at the start: `29e3bad` (gate run 18 and CI green). Fixes made
  during the gate landed as `dd11ce5`.
- Host: macOS 27.0, Apple `container` runtime; `dx-host` was running
  throughout and was never named by any command.
- `dx-test` existed stopped from 2026-09-28 with its three volumes; it was
  cold-started, not recreated (see "Not done" below).

## Steps and results

| Step | Result |
| --- | --- |
| `dx-profile dx-test env` | every resource resolved to a `dx-test-*` name; `DX_BACKUP_DIR` is the shared real mirror, so the backup step below used a scratch `DX_BACKUP_DIR` |
| cold start (`dx-start-container` then `dx-wait-ssh`) | ready in 40 s; bootstrap generation synced and published through the WP5.1 result file; Home Manager activation 23 s |
| `dx-status` | image, container, generation running = published, SSH port open |
| WP8.1 scratch records | `/run/dx-bootstrap/{durable-identity-record,image-default-profile-target,nix-volume-record}` present, root-owned, identity 30033:30001 |
| WP6.7 readiness marker | absent by design: the container's launcher command was baked at creation (2026-09-28, before WP6.7) and never passes the lease triple, so the marker is the documented no-op; a lease exists. Only a recreate exercises the new launcher and healthcheck |
| full sweep, first pass (`tests/run.sh --live --tier unit` then `--tier live`) | 42 suites, 2,462 passed, 14 failed, 78 skipped |
| after fixes, re-run of sections 15, 16, 6, 11 | 13/0/1, 39/0/1, 166/0/19, 8/0/0 |
| section 12 (in-guest run of the committed tree) | 1 passed after the harness fix |
| section 21 under the profile | 166 passed after the probe fix |
| `dx-backup --dry-run --summary` (scratch mirror) | **fails**: `repository discovery failed: find: '/persist/lost+found': Permission denied` (open, below) |
| cold stop | clean; `dx-test` left stopped as found |

## Findings

1. **Guest PATH regression (fixed, `dd11ce5`).** WP7.4 replaced the three
   per-shell PATH prepends with `home.sessionPath` and dropped
   `~/.nix-profile/bin`. A bare login shell over raw ssh (`ssh dx@guest
   "bash -lc …"`, the form sections 6, 15 and 16 use) starts from sshd's
   default PATH with no Nix directory, so `nu`, `tmux`, `id` and `rm` were
   all "command not found". `dx-ssh` masked it by exporting PATH itself.
   Ten of the fourteen failures. Verified live after re-activation: raw ssh
   resolves all three from `~/.nix-profile/bin`.
2. **Harness awk dependency (fixed, `dd11ce5`).** Section 12 runs the new
   `tests/lib/harness.sh` inside the guest under the bootstrap essentials,
   which have no awk. Two functions rewritten in bash.
3. **Section 21 probe under a profile (fixed, `dd11ce5`).** `bin/dx-profile`
   exports the resolved DX_/DXE_ snapshot; the BASH_SOURCE root-derivation
   probe inherited it. The probe now clears those variables only.
4. **`dx-backup` fails on a real guest (open).** WP6.1 (Astra F1) makes any
   nonzero `find` fatal in `dx_pbs_find_repos`; a real `/persist` has
   root-owned `lost+found` and `etc` the dx user cannot read. Fixtures never
   had an unreadable entry. Needs a decision against the WP6.1 case
   (prune unreadable directories with an explicit warning, or scope
   discovery to `/persist/home`), then TDD. Until then no backup works on
   any guest from this branch, so this blocks promotion.
5. **hm-session-vars ordering wart (pre-existing).** The generated file
   evaluates `$(id -u)` for `TMUX_TMPDIR` before its own PATH line, so a
   bare login shell prints "id: command not found" once and gets
   `/run/user/`. Same before the branch (the old prepends also ran after
   it). Not fixed.
6. **Recreate not run.** `dx-profile dx-test dx-recreate` was refused by the
   session's permission classifier (it contains the destroy step); it was
   not retried. The launcher/healthcheck (WP6.7), the ownership checks
   (WP6.4) and the lock-once orchestration (WP6.5) therefore remain
   unexercised live. Command for the user, from the branch tip:
   `./bin/dx-profile dx-test ./bin/dx-recreate hostname </dev/null`, then
   `./bin/dx-profile dx-test bash tests/run.sh --live --tier unit` and
   `--tier live`.

## Not done

- QNAP canary: not started, per the standing decision that it follows a
  green `dx-test`; finding 4 keeps `dx-test` short of green.
- Full sweep not repeated end to end after the fixes (time-boxed session);
  the five affected suites were re-run individually.
