# Remote-aware SSH and user workflows (Branch 11 / Phase 5, `feat/qnap-remote-ssh`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 5 and
`checkout-consolidation-plan.md`'s Branch 11. No home-directory paths, keys,
fingerprints, daemon IDs, or NAS identifiers appear below; the NAS's
Tailscale address is discovered at run time and is never written to a
tracked file.

Branch `feat/qnap-remote-ssh`, from `main` `6bfe9f0`, rebased onto `d0c28d1`
before landing (no conflicts). Implemented by a Sonnet subagent against fake
`ssh`/`docker`/`nc` boundaries only (nine commits: the design note, the
seven increments' worth of code and docs with one deferred-validation fix,
and two test-only follow-ups found at landing) plus the coordinating
session's ratchet rebaseline and this record; designed, reviewed,
live-gated and landed by the coordinating session.
Design: `docs/refactor/remote-aware-ssh.md`.

## User decisions (2026-09-28)

1. Phase 5 proceeds now. 2. The Tailscale-in-guest spike (item 9) is
**deferred** until items 1-8 land; the NAS-address binding is the access
model. 3. Guest SSH port **2222** on the NAS's Tailscale address. 4.
(`dx-host` promotion #5 ran in parallel; recorded in Appendix D.)

## What changed

- **One new contract operation, `dx_runtime_guest_ssh_address`:** Apple
  `127.0.0.1`; docker-ssh the NAS's Tailscale IPv4 address, discovered over
  the management connection with Phase 0's proven shape (a production copy
  kept in step with `tests/qnap/lib/phase0-common.sh` by a drift contract
  test), validated as a dotted quad in the Tailscale range, cached per run,
  never persisted; no address → refuse ("DQ5 forbids publishing on the LAN or
  0.0.0.0").
- **Publish through the adapter:** `dx-create-container` passes the neutral
  `PORT:2222`; Apple prepends `127.0.0.1:` (its rendered argv is byte-identical
  to before), Docker prepends the discovered address.
- **One SSH builder for every entry point:** `dx_ssh_endpoint` dials
  `dx@<guest address>`; `dx-wait-ssh` lost its private option array;
  `dx-status` probes and prints the real address and port; the tunnel helper
  dials the endpoint while its local forward/reverse binds stay on
  `127.0.0.1`; `dx-ssh`, `dx-herdr` inherit; `dx-put`/`dx-get` stay on the
  exec plane (asserted).
- **Host-key pinning for docker-ssh profiles:** a per-profile known-hosts
  file under the controller's state directory (0700), `accept-new` on first
  contact, refusal with the `ssh-keygen -R` remedy on a later mismatch; Apple's
  options unchanged.
- **`dx-enter` over remote exec** forces a TTY on the management ssh (`-tt`)
  exactly when `-t`/`-it` is requested and never otherwise (Branch 17's
  stdin discipline preserved); **`dx-export`** streams to `<file>.partial`,
  renames on success, removes the partial on failure or interrupt.
- **Fail-closed capability checks:** `dx-mount` requires `bind_mounts`,
  `dx-nix-disk` a new `raw_nix_disk` capability (Apple yes, Docker no), and
  the Docker adapter refuses a git-role bind-mount volume at create time —
  closing the `dx-mount` gap Phase 2 recorded.
- **Real defects found by the deferred validation checkpoint and fixed
  before hand-back:** a boundary-audit violation (a shared helper called the
  Docker adapter directly), bash 3.2 `set -u` empty-array expansions (one new,
  two pre-existing in both adapters' create rendering), two SC2034 warnings
  only apt ShellCheck 0.9.0 reports, an uncovered docker-ssh branch, a stale
  Section 4 assertion on the old loopback publish literal, assertions
  swallowed by a subshell in a characterisation block, and placeholder
  Tailscale-range literals in tracked text (Section 1's leak pattern).

## Gates

| Gate | Result |
| --- | --- |
| Container-free contracts (`run_all_tests.sh --skip-integration`, throwaway `ubuntu:24.04`) | "All tests PASSED!" on the hand-back tip; on the final tip, from a fresh git clone on Linux with no state directory present (as on CI): 32 sections, 1883 passed, 0 failed, "All tests PASSED!" |
| bash-3.2 | subagent's own file 100 passed; the whole bash-3.2 suite on a clean export of the final tip: 8 files, 701 passed, 0 failed |
| Pinned ShellCheck 0.10.0 and apt 0.9.0 | clean, including 0.9.0 on the final tip |
| Coverage (`tests/run-coverage-linux.sh`) | `covered=100%`; ratchet RAISED 2088 → 2111 at the rebase (more in-scope production lines than tests), then LOWERED to 2104 on the final tip for the two test-only follow-ups (105 test lines, scope unchanged at 7,366); the isolated Linux runner confirmed `covered=100% scope_share=21.04%` |
| Sections 1, 4, 9, 19, 23, 27, 32, 33, characterisation, refactor state machines | green bare and under `./bin/dx-profile dx-test … --skip-integration`; Section 9 also green with `XDG_STATE_HOME` pointing at an absent directory (133 passed) |
| Nix | not applicable (no `.nix` change) |
| Private identifier scan | clean, whole branch and per commit |

## Live gate — QNAP (2026-09-28, disposable `dx-qnap-spike`, x86_64, 8 GB / 4 CPU)

Run by the coordinating session from the controller (which was itself on a
network other than the NAS's LAN at the time), with a disposable key pair
and profile, every invocation with stdin from `/dev/null`, and the NAS
otherwise untouched. Steps and results, in order:

| Step | Result |
| --- | --- |
| Guest SSH address op | returned the NAS's Tailscale IPv4 address (private log only); the known-hosts pin did not exist beforehand |
| create-volumes / image / container | Docker's port binding inspected: `2222/tcp` bound to **the Tailscale address only** (no `0.0.0.0`, no LAN address) |
| start + `dx-wait-ssh` | ready in ~2 min through the shared builder; first contact recorded the pin (one line, directory mode 0700) at `<state>/dxe/<container>/<host-identity>/known_hosts` |
| `dx-ssh` (second contact) | `SSH_OK`, `x86_64`, user `dx`; pin unchanged (still one line) |
| `dx-put` / `dx-get` | round trip byte-identical |
| `dx-forward 8080:18080` | listener `ssh 127.0.0.1:18080` in the controller's socket table (controller loopback, never the tailnet address); gone after `--stop` |
| `dx-reverse 18081` / `--stop` | reverse established `dx-qnap-spike 127.0.0.1:18081 -> host 127.0.0.1:18081`, then stopped |
| `dx-enter uname -m` | `x86_64` over remote exec, non-interactive (no TTY forced) |
| `dx-export` | 512M tarball, no `.partial` left beside it |
| `dx-mount` / `dx-nix-disk` | both refused with exit 1, naming the runtime (`not supported under DX_RUNTIME=docker-ssh … DQ8`) and the `raw_nix_disk` capability; remote container/volume/image counts identical before and after |
| `dx-status` | SSH section probes `<tailnet address>:2222` and reports it OPEN; shows `x86_64-linux`, `keyring: not running`, remote lock not held |
| LAN unreachability | `nc -z -w 3 <NAS LAN address> 2222` failed. Weak on its own (the controller was off-LAN, so the probe timed out at the kernel's connect limit rather than at 3 s); the binding inspection above is the strong evidence. The user's own on-LAN and external-network checks remain |
| Cleanup | container stopped and removed, three volumes and the image tag deleted; `io.dxe.managed` filters returned no containers and no volumes, image tag count 0; controller state directory and worktree key copies removed |

Three harness defects in the gate scripts, none in the branch: (1) the first
pin check assumed a `<profile-id>` layout — the library's own
`dx_ssh_known_hosts_path` is `<container>/<host-identity>` and the pin was
there; (2) the redaction pass turned `127.0.0.1` into `<ip>` before the
loopback grep, so a correct bind read as a failure (re-verified from the
socket table, and loopback is now exempt from redaction); (3) an
exit-status capture read `PIPESTATUS` after an `if` body had reset it, so a
correct refusal read as "did not refuse" (re-run with the status taken
directly). Each was re-run from the failed step; no step was skipped.

## Live gate — Apple (`dx-test`, 2026-09-28)

Run twice by the coordinating session from the branch worktree, stdin from
`/dev/null` throughout. The first run's live tier reported one failure in
the Docker adapter test file while the subagent was still red-proofing an
edit to that very file in the same worktree; the same test passed 165/0
from a clean export of the committed tip, bare and under the profile, and
the whole gate was re-run on the final tip after hand-back. Second run:

| Step | Result |
| --- | --- |
| cold start + `dx-wait-ssh` | ready in ~20 s through the shared builder, Apple endpoint `127.0.0.1` |
| `dx-status` | SSH section now reads `SSH (127.0.0.1:2299)` / `SSH Port 2299 is OPEN on 127.0.0.1` where it used to say `localhost` — the one visible Apple text change, from the shared address op; `keyring: stale`, the documented state after any container restart until the keyring service is started again |
| `dx-enter uname -m` | with stdin from `/dev/null` Apple's `container exec -it` refuses (`NSPOSIXErrorDomain Code=19`); `bin/dx-enter` and the Apple exec are byte-identical to `main` and the same invocation fails the same way there, so this is pre-existing, not Phase 5. Under a real pseudo-terminal (`expect`) it returns `aarch64`, exit 0 — a terminal is how `dx-enter` is used |
| `dx-export` | 1.1G tarball, no `.partial` beside it |
| full live tier under the profile | 35 sections, 1821 passed, 0 failed |
| cold stop | clean |

The live tier ran on the tip that carried the test-isolation commit; the
one commit after it (the snapshot-helper guard below) changes test helpers
only and was covered by the container-free suites instead of another live
run.

Lesson recorded: a live tier is run from a tree nobody else is editing (a
`git archive HEAD` export, or after hand-back), never from a subagent's
working tree.

## Landing checks on the final tip: one more test-only defect

The final-tip verification found that the test-isolation commit's new
snapshot helper ran `find <state dir> | sort` unconditionally; on a fresh
Linux runner, in the coverage container and on CI the directory does not
exist, `find` exits 1, and under the callers' `set -e` the assignment
aborted the whole file: the Ubuntu run of the container-free suite lost
Section 9 without a Results line, and the Linux coverage gate stopped in
the sourceable-coverage probe. It passed on the controller only because
that directory happened to exist there; reproduced with `XDG_STATE_HOME`
pointing at an absent path. Fixed by the subagent (an absent directory is
an empty snapshot; a regression test in Section 9), then every container-
free gate was re-run on the final tip — see the Gates table.

## Landing (2026-09-28)

Rebased once onto `main` `d0c28d1` before the live gates, with no conflicts;
every commit's delta identical before and after. Final ratchet 7,366 /
34,995 → 2104 bp, re-measured on a clean export of the finished tip after
the two test-only follow-ups (it had been raised to 2111 at the rebase for
the phase's production code); `covered=100%` confirmed in the isolated
Linux runner. Private identifier scan clean, whole branch and per commit.
Landed by fast-forward after CI. Lessons recorded in the plan: run a live
tier only from a tree nobody else is editing, and run every Linux-facing
test gate on a fresh clone without the controller's own state, which is
where the snapshot-helper defect hid.
