# Fixture host alias: fail closed (2026-10-04)

Branch `fix/fixture-host-alias-fail-closed`, tests only. Motivation: on 2026-10-03 an
exploratory script whose fake tools were missing fell through to the operator's real
ssh_config alias (the public example alias name) and ran read-only Docker queries against
the production NAS. Three structural layers now prevent a repeat:

1. Every fake-tool directory starts with fail-closed defaults for `ssh scp sftp docker
   tailscale container nix curl` (message `fake-tools: no fake for <tool>; refusing to
   reach a real host`, exit 99); real fakes overwrite them. Scenarios whose point is a
   tool's absence remove the default explicitly.
2. Test fixtures name `dxe-fixture-nas.invalid` (reserved, never resolves) instead of the
   example alias; `tests/qnap/` operator scripts and the example profiles keep the real
   alias by design.
3. Section 1 guards: no scanned test file names the example alias, every
   `DX_REMOTE_HOST=` assignment under `tests/` ends in `.invalid`, and the fail-closed list
   and message stay in `tests/lib/fake-tools.sh`.

Gates: unit tier and bash 3.2 green on the branch; `tests/test_persist_backup_select.sh`
5/5 after one load-induced failure; pre-push scan clean. Apple live tier on `dx-test`
from a clean clone: live tier: 45 suites, 2739 passed, 0 failed, 84 skipped (log kept privately).
