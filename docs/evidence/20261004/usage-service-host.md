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

## Production enablement incident and the upgrade-path fix (2026-10-04)

The first enablement of the service on production `dx-qnap` (profile on, `dx-recreate`) failed
closed: the existing guest's essentials profile had never received `s6`, because the bootstrap
installed that profile only on a fresh guest. The guest crash-looped under `unless-stopped` and
was unreachable for about two hours (03:59 to 06:01 NZDT) until it was recreated with the
service off; data intact, release link kept. The disposable spike had passed because it was
fresh.

Fix (`fix/essentials-upgrade-on-boot`): the bootstrap gates the essentials install on the
tools the configured boot needs (the shadow tools, plus `s6-svscan` and `s6-log` when the
service is on) and upgrades the profile from the current bootstrap flake when one is missing,
re-registering the closure; the start-and-wait path fails fast when the container stops
running or its restart count climbs, printing the container's last log lines; the runbook
documents the git-bundle copy over `scp` and the slower first boot.

Upgrade-path proof on a disposable `dx-qnap-spike8`: created from `main` `a71fb8d` with the
service off, then synced and recreated from the fix branch with the service on. The boot
upgraded the essentials profile, PID 1 became `s6-svscan`, the health check went green, the
restart count stayed at or below one; live tier live tier: 48 suites, 2886 passed, 1 failed, 89 skipped (recorded on the first spike8 run against the same tree d033f60; the failure is the class D dx-ai case) (the one failure is Section 17's dx-ai live case: the source-build guard refused on binary-cache lag for one package, the documented remedy is to wait; unrelated to the service); the release built to the same
store path and answered over the tailnet. Apple regression tier: live tier: 48 suites, 2917 passed, 0 failed, 84 skipped.

## Follow-up: launcher PATH order (2026-10-04, after enablement)

Production's first service-on boot logged "dbus-daemon is unavailable; the keyring service
cannot start": the launcher started the keyring before putting the active dx-ai generation's
`profile/bin` on PATH, and dbus and the keyring tools live in that generation. The order is
reversed (`fix/usage-launcher-path-before-keyring`), covered by a fake generation that holds
the only dbus-daemon. Applied to production by `dx-sync-bootstrap` and
`dx-usage-service restart` (the service only; the guest was not recreated).

## Follow-up: service logs owned by dx (2026-10-04)

After enablement `dx-backup` failed on production: each service's `s6-log` ran as root and created
root-only directories under `/persist/services/agent-stats/logs`, and the backup (running as dx)
refuses an unreadable directory during repository discovery. No backup was taken from 10:41 to
12:23 NZDT; backups were restored at 12:23 by handing the directories to dx, and the last good
backup before that was from 10:40. Fix (`fix/usage-logs-owned-by-dx`): every `s6-log` runs as dx,
and the boot hands the logs subtree back to dx before starting the tree. Proven on a disposable
spike that took production's path: created on the previous `main` with the service on (root-owned
log directories, backup failing), then synced and restarted from the fix tree (directories and
`s6-log` processes owned by dx, backup succeeding with a new mirror generation).
