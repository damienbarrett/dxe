# Execution-lease identity and directory modes (`fix/docker-ssh-lease-and-restore-modes`) — evidence

Sanitised record for `2-oct-plan.md` step 3: the two runtime defects found
during the canary week (`docs/evidence/20260928/qnap-promotion.md`,
findings 2 and 6) plus the restore follow-through (findings 1, 3, 4).
Implemented by a Sonnet subagent against fakes only, one increment per
commit, red before green; reviewed, live-gated and landed by the
coordinating session.

## What changed

| Increment | Behaviour | Red → green |
| --- | --- | --- |
| execution-lease identity | a lease is live only when its generation, boot id, PID **and** process start time all still hold; the shared guest protocol gained `execution_lease_live` / `execution_leases_prune` / `execution_leases_live` (shipped copy identical); the sync's unchanged-content prune and its publish-time loop use the same parser; the host reads live leases only (`dx_bootstrap_lease_listing`) for `dx-status`, `dx-start-container` and the publication confirmation, so a Docker container restart — same host boot id — no longer reports a false drift | fake `/proc`: Docker restart, reused PID, Apple boot-id change, dead PID, malformed records, reader preference, idempotent prune; bite check by dropping the start-time comparison (7 cases fail) |
| directory modes end to end | the selector reports directory modes without following symlinks; every generation carries `dirs.tsv` (path, octal mode) for the directories holding selected files, fail-closed on an unreadable mode; restore recreates missing directories with the captured mode, treats an existing directory with a different mode as a conflict (refused without `--force`, shown by `--dry-run`), never changes a symlinked or unreadable directory, and applies modes after extraction in one root exec; a mirror without `dirs.tsv` restores as before with one notice; `dirs.tsv` is bookkeeping like `manifest.tsv` | 9 restore cases + the selector case red → green; bite by disabling the apply step (3 fail) |
| one-time mirror upgrade | a `dx-backup` run whose current generation lacks `dirs.tsv` commits one generation that records them, with a notice (also under `--dry-run`); the next run is a no-op | 2 red → green |
| restore follow-through | tests pin the batched `chown -h` and the host tar's `COPYFILE_DISABLE=1`, both already present; runbook 9.4 explains the bootstrap-seeded herdr conflict and the disposable-target `--force` | bite by removing `COPYFILE_DISABLE=1` |
| coverage and lint closers | shipped-list (>1000 paths) variants and failure paths covered; SC2120/SC2034 in new helpers fixed | — |

## Gates (container-free, subagent; logs re-read by the coordinator)

| Gate | Result |
| --- | --- |
| fresh clone in a throwaway Ubuntu 24.04 container (apt ShellCheck 0.9.0, jq, no state directory) | `run_all_tests.sh --skip-integration` passed, on the penultimate and the final commit |
| pinned ShellCheck 0.10.0, CI file set | clean |
| kcov coverage (isolated) | covered 100%; scope 4,190 ≥ floor 3,935; unscoped 2,629 ≤ ceiling 2,635 (ratchet untouched; the branch adds 26 exempt entry-point lines in `dx-backup`/`dx-restore`, within the existing slack) |
| `nix flake check` on `container/dx-nixos-26.05` | passed; `flake.lock` unchanged |
| bash 3.2 | all passed |

## Live gate — Apple (`dx-test`), coordinating session, clean clone of the rebased tip

| Step | Result |
| --- | --- |
| start + `dx-wait-ssh` | ready after 19 s |
| `dx-backup` into a scratch mirror | dirs.tsv recorded: 39 directories; dry-run: identical=204 would-create=0 dir-conflicts=0 notices=0 |
| second `dx-backup` run | "0 files, 0 bytes transferred" — no second upgrade commit |
| stop/start, then `dx-status` | running = published, no drift warning |
| full live tier | live tier: 45 suites, 2566 passed, 0 failed, 94 skipped |
| cold stop | clean |

The Docker side of the lease fix (same host boot id across a container
restart) can only be proven on the NAS; that proof is scheduled as a
disposable `dx-qnap-spike3` restart inside the user's QNAP maintenance
window (2-oct-plan.md D5), never on the canary first.
