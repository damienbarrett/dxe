# Usage service, DXE half: live gates (2026-10-04)

Branch `feat/usage-service-host` (design: `docs/refactor/usage-service-host.md`; decisions
1B/2B/3A/4A). Container-free gates on the branch: unit tier, bash 3.2, kcov 100% of the
declared scope (unscoped ceiling raised 2635 → 2650 for the irreducible entrypoint lines,
see `docs/evidence/20260930/coverage-ratchet-history.md`), pinned ShellCheck 0.10.0,
fresh-clone Ubuntu run, `nix flake check`, pre-push scan clean.

## Apple tier, `dx-test` (service-off regression)

Runner path `./bin/dx-profile dx-test tests/run_all_tests.sh --live` from a clean clone:
live tier: 47 suites, 2889 passed, 0 failed, 84 skipped. `dx-usage-service` refuses under the Apple runtime with the capability
message; the guest's PID 1 stays `sshd`.

## docker-ssh tier and service proof, disposable `dx-qnap-spike7` (service on)

Created from the branch tip with `DX_USAGE_SERVICE=on` (host port 8787). Live tier:
live tier: 47 suites, 2858 passed, 1 failed, 89 skipped (the one failure is Section 17's dx-ai live case: the source-build guard refused on binary-cache lag for one package, the documented remedy is to wait; unrelated to the service). Proof steps, all recorded in the private log:

- PID 1 is `s6-svscan`; the tree holds `sshd`, `agent-stats`, `agent-stats-watchdog`
  and `.s6-bin`; both publications sit on the NAS's Tailscale address (never LAN,
  loopback or 0.0.0.0); the Docker health check is `healthy`.
- Before any release is linked the launcher fails clearly and does not spin:
  launcher log lines: 2 -> 4 over 60 s (expect <= 3 new: one failure message per 30 s delay).
- Package by option E: a `git archive` of the agent-stats release commit copied into the
  guest and built natively (`nix build path:.#agent-stats-release`): `/nix/store/n79wc6…-agent-stats-release-0.1.0`;
  store path MATCHES the recorded x86_64 path.
- Release selection with `nix-store --add-root … --indirect`, then
  `dx-usage-service restart`: `/health/live` 200 inside the guest and from the Mac over
  the tailnet; `restart` changes only agent-stats's PID (sshd's unchanged); `stop`
  leaves no orphan tmux or agent-stats processes.
- Container stop is bounded (stop took 17 s); after a stop/start cycle PID 1 is `s6-svscan`
  again, the service is up and the health check is `healthy`.
- Factory reset afterwards; the NAS inventory shows only production `dx-qnap` before and
  after.

Production enablement (decision 3A) is recorded in `docs/evidence/20260928/qnap-promotion.md`
when done. The dx-ai compatibility check stays a stub until the package's version
command is confirmed; the hook's restart path was exercised by fakes only.
