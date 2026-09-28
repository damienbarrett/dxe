# QNAP lifecycle, reboot and operational hardening (Branch 11 / Phase 6, `feat/qnap-lifecycle`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 6 and
`checkout-consolidation-plan.md`'s Branch 11. No home-directory paths, keys,
fingerprints, daemon IDs, NAS hostnames or addresses appear below; the NAS's
Tailscale and LAN addresses are written as `<tailnet address>` and
`<LAN address>`.

Branch `feat/qnap-lifecycle`, from `main` `1cceb58` (Phase 5 landed).
Implemented by a Sonnet subagent against fake `ssh`/`docker`/`nc` boundaries
only; designed, reviewed, live-gated and landed by the coordinating session.
Design: `docs/refactor/qnap-lifecycle.md`.

## User decisions (2026-09-28)

1. Phase 6 proceeds now. 2. The coordinating session runs a maintenance
window the same day with a disposable guest; the user types the Container
Station restart and the NAS reboot (only they hold `sudo` on the NAS).
3. The slow `dx-test` restart seen earlier that day is investigated inside
item 5 (health reporting). 4. Guest size stays 8 GB / 4 CPU. 5. Phase 0's
items 8b/8c close in the same window.

## What changed

- **Health layers (item 5):** `dx-status` gains a third bootstrap state —
  container running but SSH not yet open shows the last bootstrap-phase
  marker and its age; port open but the login shell not answering prints
  the probe's own error — and `dx-wait-ssh`'s progress tick names the last
  bootstrap phase and the last probe error on every tick, not only at the
  final timeout. One shared login-shell probe helper serves both.
- **Container Station display (item 4):** a neutral create-time health
  check (`--health-cmd/--health-interval/--health-retries`) behind a new
  `container_healthcheck` capability; the Docker adapter renders Docker's
  own flags, Apple discards them. The probe is SSH-independent: it checks
  the guest's own `current` generation link and its lease.
- **QNAP destructive operations (item 7):** `dx-factory-reset` and
  `dx-destroy-volumes` print an immutable plan — every target's kind, exact
  name and label state — and refuse the whole operation with zero delete
  calls if any existing resource lacks this profile's labels; the typed
  confirmation follows the printed plan. Apple output is byte-identical.
- **Restart policy and ordering (items 3 and 9):** the default stays `no`;
  `unless-stopped` is opt-in per profile, now proven for this NAS across a
  container restart, a Container Station restart and a NAS reboot. The
  ordering question (does the guest start before `tailscale0` has its
  address?) was answered by observation: it does not on this NAS; the
  fail-loud path (an exited container with a bind error, visible in
  `dx-status`, remedied by `dx-start-container`) is documented, and no
  NAS-side hook is needed.
- **Documentation (items 1, 2, 6, 8):** `docs/qnap-runbook.md` (install,
  preflight, operation, update with backup first, backup, restore, removal,
  emergency access over LAN SSH to the NAS with `docker exec`, never a public
  or LAN publish of guest SSH), `docs/lifecycle.md`'s QNAP section, the
  example profile's sizing rationale, the README link and the plan index.
- **Interrupted-boot investigation (decision 3):** not reproducible. Two
  clean runs on `dx-test`, one with the original sequence exactly, came
  back ready in about 20 s; the original guest's own log shows every
  bootstrap phase finishing in a second. Host contention from concurrent
  coverage and Ubuntu containers is the likely factor, and the gate script
  had discarded `dx-wait-ssh`'s probe diagnosis. Item 5's new lines exist so
  the next such wait explains itself as it happens.

## Gates (container-free, coordinating session, final tip)

| Gate | Result |
| --- | --- |
| ShellCheck (pinned 0.10.0; apt 0.9.0 in throwaway `ubuntu:24.04`) | clean after one SC2155 fix the 0.9.0 runner demanded |
| Container-free suite on Linux from a fresh git clone, no state directory | 32 sections, 1902 passed, 0 failed, "All tests PASSED!" (state directory absent, as on CI) |
| bash-3.2 | 8 files, 718 passed, 0 failed (clean export of the rebased tip) |
| Coverage (`tests/run-coverage-linux.sh`, isolated kcov runner) | `covered=100%` after seven adapter lines gained probes; ratchet raised 2104 → 2107 for the production code, then lowered to 2105 for the two test-only follow-ups (scope unchanged at 7,530) |
| Sections 1, 9, 10, 32, 33, characterisation | green bare and under the profile |
| Private identifier scan | clean, whole branch and per commit (pre-push scan at the landing tip) |

## Maintenance window (2026-09-28, disposable `dx-qnap-spike`, `unless-stopped`, 8 GB / 4 CPU)

The controller was off the NAS's LAN throughout. Each restart kind was
observed with Docker's own state, the NAS's socket table, a LAN-side
connect attempt from the NAS itself, and the guest's bootstrap generation.

| Step | Observation |
| --- | --- |
| Create + first boot | 120 s to SSH; policy `unless-stopped`; `2222/tcp` bound to `<tailnet address>` only; NAS listener on that address only; LAN-side connect refused |
| User's external check (Phase 5 exit gate) | `dx-wait-ssh`, `dx-ssh` (`x86_64`, `dx`), `dx-put`/`dx-get` byte-identical, `dx-forward` on controller loopback only, `dx-status` showing the tailnet address OPEN — all from the off-LAN controller |
| Container restart (`docker restart`) | back to running, restart count 0, binding unchanged, SSH ready 36 s later, generation unchanged with no controller publish |
| Container Station restart (user, `sudo`) | daemon unreachable ~40 s; the guest came back **by itself**, policy preserved, binding unchanged, `tailscale0` kept its address throughout; SSH ready 35 s later; generation unchanged |
| NAS reboot (user, `sudo reboot`) | NAS SSH down 404 s; at return `tailscale0` already addressed (+0 s), Docker up +2 s, guest **already running** +3 s (restart count 0, no error), `docker port` on the tailnet address; NAS listener tailnet only; LAN-side connect refused; SSH ready 29 s later; generation unchanged with no controller |
| Cleanup through the branch's `dx-factory-reset --force` | immutable plan printed (container and three volumes with `managed=true`, schema, profile, role), then everything removed; managed filters empty afterwards |
| Negative case | an **unlabelled** volume with the guest's nix-volume name made `dx-destroy-volumes --force` refuse with zero deletes ("exists but is unlabelled … a collision, not an adoption candidate"); the volume was still present and was removed by hand |

Phase 0's items 8b (Container Station restart) and 8c (NAS reboot) close
with this window: volumes and tailnet-only publication persisted through
both.

## Live gate — Apple (`dx-test`)

Run by the coordinating session from a clean clone of the branch tip, stdin
from `/dev/null` throughout, with no other container work on the controller
(the lesson from Phase 5's contaminated run).

| Step | Result |
| --- | --- |
| cold start + `dx-wait-ssh` | ready in 19 s |
| `dx-status` on a healthy guest | the two new health lines stayed silent (no "Login shell is not answering", no "Still bootstrapping"); `SSH Port … is OPEN on 127.0.0.1` |
| `dx-destroy-volumes` with no `--force`, stdin from `/dev/null` | refused before any mutation with Apple's own text (`Refusing to destroy volumes without --force …`), no "Immutable plan" text, container intact |
| full live tier under the profile | 35 sections, 1841 passed, 0 failed |
| cold stop | clean |

## Landing (2026-09-28)

Rebased once onto `main` `1f65b0d` after all gates, with no conflicts;
every commit's delta identical before and after (only `main`'s own
promotion-record lines differ). Final ratchet 7,530 / 35,758 → 2105 bp,
re-measured on a clean export of the finished tip (raised to 2107 for the
phase's production code, then lowered for the two test-only follow-ups);
the isolated Linux runner confirmed `covered=100% scope_share=21.05%` on
the rebased tip. Landed by fast-forward after CI. Lessons recorded: run
the Linux gates from a fresh clone (the SC2155 and coverage findings only
appeared there); a subagent whose context fills up hands back mid-task
with its work staged, so the coordinating session commits what it has
validated rather than resuming a spent agent; and every live observation
that decides a design (here, restart ordering) goes into the design note
verbatim, with what was not observed named as such.
