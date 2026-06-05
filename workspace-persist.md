# Workspace Persist Closeout

Historical plan: rename guest persistence from `/workspace` to `/persist`.

The original implementation landed in commit `797f09f` and deleted the old
planning file. This file now tracks final closeout verification and cleanup.

## Current State

- Guest persistence surface is `/persist`.
- Default persistent volume is `dx-persist`.
- Host configuration variable is `DX_PERSIST_VOLUME`.
- Guest shell env var is `PERSIST`.
- Legacy `DX_WORKSPACE_VOLUME` and `DX_WORKSPACE_PATH` fail early.
- `bin/dx-migrate-persist` exists for one-time migration from `dx-workspace`.
- User has started the guest, inspected `/persist`, and approved proceeding with
  final verification and cleanup.

## Closeout Checklist

- [x] Run focused verification: section 3 with `--skip-integration`.
  - Passed: 24 passed, 0 failed, 0 skipped.
- [x] Run focused verification: section 9 with `--skip-integration`.
  - Passed: 142 passed, 0 failed, 0 skipped.
- [x] Run full test suite.
  - Ran once in sandbox: failed because Apple Container lifecycle commands were
    not permitted.
  - Ran again with container permissions: lifecycle/workspace-persist checks ran,
    including section 11 and section 16 integration checks.
  - Remaining non-workspace-persist failures:
    - Section 5: live guest lacks `/etc/os-release`, so the release-identity
      assertion cannot pass.
    - Section 13: tracked working tree is dirty while current edits are
      uncommitted.
- [x] Run destructive section 16 persistence E2E with `DX_TEST_DESTRUCTIVE=1`.
  - Passed: 36 passed, 0 failed, 0 skipped.
  - Verified `/persist` contents survive
    `dx-destroy-container + dx-create-container + dx-start-container`.
  - Verified GitHub CLI config under persisted storage survives the same
    lifecycle.
- [x] Remove legacy `dx-workspace` volume if it still exists.
  - `container volume inspect dx-workspace` now reports `volume 'dx-workspace'
    not found`.
  - `container volume inspect dx-persist` still succeeds.
- [x] Record final status and any residual risks.

## Final Status

Workspace-persist closeout is complete.

Verified:

- Focused section 3 static gate passed.
- Focused section 9 static gate passed.
- Full suite was run with container permissions; workspace-persist lifecycle
  checks passed, including section 11 fresh-container lifecycle and section 16
  migration integration.
- Destructive section 16 E2E passed with `DX_TEST_DESTRUCTIVE=1`.
- Legacy `dx-workspace` volume was removed.
- Current `dx-host` is running and reports `/persist` mounted from `dx-persist`.

Residual non-workspace-persist issues observed during full-suite verification:

- Section 5 live release-identity check fails because the guest has no
  `/etc/os-release`.
- Section 13 final-review clean-tree check fails until the current tracked edits
  are committed or otherwise cleared.

## Notes

- The destructive section 16 check recreates the guest container while preserving
  `/nix` and `/persist`.
- Removing `dx-workspace` is irreversible for the old volume, but `/persist` has
  already been inspected and accepted as the source of truth.
