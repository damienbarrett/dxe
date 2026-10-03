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

## Correction (same day)

The guard scanned the working tree, so an operator's private, git-excluded profile in
`tests/profiles/` (the documented place for one) failed Section 1 in every checkout that
held one, and a disposable live-tier profile failed the docker-ssh live tier's Sections 1
and 20. Commit `d776c79` scans tracked files only (`git ls-files`; a clean export without a
repository scans the tree, which then contains only tracked files). Red: an untracked
decoy profile with the real alias failed the old guard and passes the new one; tracked
literals still fail. Landed on unit-tier gates (unit tier, bash 3.2, ShellCheck 0.10.0,
pre-push scan); the usage-service branch's live tiers on both runtimes re-exercise Section 1
on top of it.

## Second correction and the permanent test (same day)

While making the untracked-file behaviour a permanent harness case, the case found that the
tracked-only guard compared git's physical repository root with the logical checkout path, so
under a symlinked path (macOS temporary directories) it fell back to scanning the whole tree
and untracked private profiles failed Section 1 again. The comparison is now physical on both
sides. The harness case runs Section 1 in a throwaway local clone: an untracked private
profile with the real alias must leave both guard cases passing, and the same file once
tracked must fail them; it fails against both earlier guard versions and passes now.
