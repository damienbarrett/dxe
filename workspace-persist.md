# Plan: Rename Guest Persistence From `/workspace` To `/persist`

Rename the guest persistence surface from "workspace" to "persist":

- guest mount path: `/workspace` -> `/persist`
- default named volume: `dx-workspace` -> `dx-persist`
- host configuration var: `DX_WORKSPACE_VOLUME` -> `DX_PERSIST_VOLUME`
- guest shell env var: remove `WORKSPACE`, add `PERSIST`
- user-facing labels/docs/tests: "workspace" -> "persist" where the word refers
  to the persistent guest volume

Scope is guest persistence only. Do not rewrite host checkout paths just because
this repository lives under a host path such as `/workspace/git/dxe`. The only
`/workspace/...` references to change are paths that resolve inside the guest.

## Review Notes

The original checklist was directionally right, but it needed sharper guardrails:

- The volume rename is data-risky. Shipping `dx-persist` without a migration or
  a first-run guard can strand a user's existing work in `dx-workspace`.
- The env-var rename is externally visible. Existing `.env` files may set
  `DX_WORKSPACE_VOLUME` or `DX_WORKSPACE_PATH`; silently ignoring them would be
  surprising.
- The old `DX_WORKSPACE_PATH` was not truly safe to override because guest
  bootstrap, Home Manager config, and `dx-ai` hardcoded `/workspace`. Remove
  path configurability instead of renaming it to a new variable that is still
  not truly supported.
- `~/workspace` and `$WORKSPACE` are user-facing, and "workspace" is reserved
  for a future current-directory mount. Remove them now; do not keep transition
  aliases.
- Use the actual repo path for guest configuration:
  `container/aarch64-darwin-apple-container-dx-nixos-25.11/...`.

Resolved policy for this change:

- New code should use only `DX_PERSIST_VOLUME`, fixed guest path `/persist`, and
  guest env var `PERSIST`.
- Do not accept `DX_WORKSPACE_VOLUME` or `DX_WORKSPACE_PATH` as normal lifecycle
  aliases. If they are set, fail early with a clear message telling the user to
  rename `DX_WORKSPACE_VOLUME` to `DX_PERSIST_VOLUME` and remove
  `DX_WORKSPACE_PATH`.
- Users who need to migrate a custom old volume should run the migration helper
  with `DX_LEGACY_WORKSPACE_VOLUME=<old>` and `DX_PERSIST_VOLUME=<new>`.
- Do not keep `~/workspace`, `$WORKSPACE`, or any runtime compatibility alias.

## 1. Host Variables And Defaults

Update [bin/dx-lib.sh](bin/dx-lib.sh):

- Replace the canonical exports:
  - `DX_WORKSPACE_VOLUME` -> `DX_PERSIST_VOLUME`, default `dx-persist`
  - remove `DX_WORKSPACE_PATH`; do not introduce `DX_PERSIST_PATH`
- Add a fail-fast deprecation guard:
  - if `DX_WORKSPACE_VOLUME` is set, tell the user to rename it to
    `DX_PERSIST_VOLUME`
  - if `DX_WORKSPACE_PATH` is set, tell the user `/persist` is now fixed and the
    old path override must be removed
- Update `dx_bootstrap_launch_command` to create `/persist`, not the old path.

Suggested shape:

```bash
if [ -n "${DX_WORKSPACE_VOLUME:-}" ] || [ -n "${DX_WORKSPACE_PATH:-}" ]; then
    echo "Error: workspace persistence variables were renamed." >&2
    echo "Use DX_PERSIST_VOLUME for the persistent volume and remove DX_WORKSPACE_PATH; /persist is fixed." >&2
    exit 1
fi
export DX_PERSIST_VOLUME="${DX_PERSIST_VOLUME:-dx-persist}"
```

Keep the final `rg` sweep honest: any remaining `DX_WORKSPACE_*` references
should be limited to this deprecation guard, migration docs/tests, or an
explicit legacy note.

## 2. Data Migration

Add a migration helper before changing the default volume in normal lifecycle
flows.

Recommended helper: `bin/dx-migrate-persist`

Behavior:

- Source `bin/dx-lib.sh`.
- Treat `DX_LEGACY_WORKSPACE_VOLUME` as the old source volume, defaulting to
  `dx-workspace`.
- Treat `DX_PERSIST_VOLUME` as the destination volume, defaulting to
  `dx-persist`.
- No-op if the legacy source volume does not exist.
- Create the destination volume if missing.
- Abort if the configured container is running. Copying a mounted writable
  volume can race with user writes.
- Mount source read-only and destination read-write in a temporary container
  from `$DX_IMAGE`, then copy with `cp -a /old/. /new/`.
- Preserve ownership, symlinks, dotfiles, and empty directories.
- Add a hidden sentinel in the destination, for example
  `/new/.dxe-persist-migrated-from`, after a successful copy.
- Be idempotent:
  - old missing: success/no-op
  - destination empty: copy
  - destination already has the matching sentinel: success/no-op
  - destination non-empty without the sentinel: abort by default
- Never delete `dx-workspace` automatically. Print the explicit cleanup command
  after successful verification, such as `container volume rm dx-workspace`.
- Treat this as an upgrade-only helper. Keep it while users may still have
  `dx-workspace`, then deprecate and remove it once the project no longer needs
  to support that old default volume.

Lifecycle guard:

- Update `bin/dx-create-volumes` so an upgrade cannot silently create and use an
  empty `dx-persist` while `dx-workspace` exists. Fail with a clear message
  telling the user to run the temporary migration helper.

Tests:

- Add a non-default migration test with throwaway volume names. Seed an old
  volume with regular files, dotfiles, a nested directory, and a symlink; run the
  helper; assert the new volume has the same contents and the old volume still
  exists.
- Test the collision path: a non-empty destination without the sentinel must
  abort unless an explicit merge/force mode is implemented.

## 3. Host Scripts In `bin/`

Update these scripts to use `DX_PERSIST_*` and user-facing "persist" language:

- `bin/dx-create-container`
  - mount `"$DX_PERSIST_VOLUME:/persist:rw"`
  - update the volume comment from `dx-workspace -> /workspace` to
    `dx-persist -> /persist`
- `bin/dx-create-volumes`
  - ensure `$DX_PERSIST_VOLUME`
  - add the migration guard from section 2
- `bin/dx-destroy-volumes`
  - include `$DX_PERSIST_VOLUME`
  - update the irreversible warning label to use `/persist`
- `bin/dx-factory-reset`
  - update comments and prompt text from `/workspace` to `/persist`
- `bin/dx-recreate`
  - update comments and status text from `/workspace` to `/persist`
- `bin/dx-put`
  - set the default destination to `/persist/inbox/`
- `bin/dx-status`
  - use `df -h /persist` instead of hardcoded `/workspace`
  - change the output label from `Workspace:` to `Persist:`
- `bin/dx-reclaim`
  - report `$DX_PERSIST_VOLUME`
  - trim `/persist`
  - update any "workspace" labels in output

## 4. Guest Bootstrap And Runtime Config

Base path:
`container/aarch64-darwin-apple-container-dx-nixos-25.11/`

Update `bootstrap.sh`:

- Rename `setup_workspace()` to `setup_persist()`.
- Change top-level ownership setup from `/workspace` to `/persist`.
- Update all persistent home paths:
  - `/workspace/home/dx/.config/gh` -> `/persist/home/dx/.config/gh`
  - `/workspace/home/dx/.local/share/keyrings` ->
    `/persist/home/dx/.local/share/keyrings`
  - `/workspace/home/dx/.gemini`, `.claude`, `.claude.json`, `.codex` ->
    `/persist/home/dx/...`
- Update comments that describe the persistent volume.
- Create the canonical home symlink:
  - `ln -sfnT /persist /home/dx/persist`
- Do not create `/home/dx/workspace` or `~/workspace`. That name is reserved
  for a future current-directory mount.
- Update the main call from `setup_workspace` to `setup_persist`.

Update `home/shell.nix`:

- Nushell env file: `$env.PERSIST = "/persist"`.
- POSIX session variables: `PERSIST = "/persist";`.
- Remove `$env.WORKSPACE` and `WORKSPACE`.
- Update the `usage` alias to
  `/persist/git/agent-stats/run-stats.sh`.

Update `scripts/dx-ai.sh`:

- Replace all persisted credential/config paths under `/workspace/home/dx` with
  `/persist/home/dx`.
- Keep its persisted paths in sync with the AI-config block in `bootstrap.sh`.
- Use a small local variable if it reduces repeated path strings, for example
  `persist_home=/persist/home/dx`.

## 5. Documentation And Existing Plans

Update [README.md](README.md):

- Normal workflow: "Use `/persist` inside the guest."
- Lifecycle principle: `/nix` and `/persist` survive recreates.
- `dx-status` description: "persist" instead of "workspace".
- Reclaim docs:
  - `dx-persist` volume
  - `fstrim -v` on `/nix` and `/persist`
  - "This does not delete persisted files" instead of "workspace files"
- Configuration table:
  - `DX_PERSIST_VOLUME`, default `dx-persist`
  - remove `DX_WORKSPACE_VOLUME` and `DX_WORKSPACE_PATH`
  - do not add `DX_PERSIST_PATH`; `/persist` is the fixed supported guest path
  - mention that setting old `DX_WORKSPACE_*` variables now fails with a rename
    message
- Isolated lifecycle example:
  - `DX_PERSIST_VOLUME=dx-lifecycle-persist`
- GitHub CLI persistence:
  - `/persist/home/dx/.config/gh`
- Factory reset/troubleshooting:
  - `/persist` instead of `/workspace`
- Add a migration subsection that tells existing users exactly when to run
  `bin/dx-migrate-persist` and how to verify before deleting `dx-workspace`.
- Do not document `~/workspace` or `$WORKSPACE` as compatibility surfaces.

Update [plan.md](plan.md):

- Rename guest-path and default-volume references that refer to this persistent
  guest storage.
- Do not rewrite unrelated host checkout examples unless they are actually
  guest paths.

## 6. Tests And Profiles

Rename the section 16 test with `git mv`:

- `tests/test_section16_workspace_persistence.sh` ->
  `tests/test_section16_persist_storage.sh`

Update `tests/run_all_tests.sh` to call the renamed file.

Update profiles:

- `tests/profiles/dx-test.env`:
  - `DX_PERSIST_VOLUME=dx-test-persist`
- `tests/profiles/dx-tinty.env`:
  - `DX_PERSIST_VOLUME=dx-tinty-persist`
- `tests/profiles/default.env`:
  - commented `DX_PERSIST_VOLUME=dx-persist`
  - remove the old `DX_WORKSPACE_VOLUME` example

Update section 16 checks:

- Static checks:
  - `DX_PERSIST_VOLUME=.*dx-persist`
  - no `DX_PERSIST_PATH` export exists
  - `dx-create-container` references `DX_PERSIST_VOLUME` and mounts `/persist`
  - `dx-create-volumes` ensures the persist volume exists
  - `shell.nix` declares `PERSIST`
  - `shell.nix` does not declare `WORKSPACE`
  - `bootstrap.sh` creates `/home/dx/persist` and does not create
    `/home/dx/workspace`
  - `dx-lib.sh` rejects `DX_WORKSPACE_VOLUME` and `DX_WORKSPACE_PATH`
- Runtime checks:
  - host has `$DX_PERSIST_VOLUME`
  - `/persist` is a separate filesystem from `/`
  - `dx` can write to `/persist`
  - `~/.config/gh` points to `/persist/home/dx/.config/gh`
  - nushell exposes `PERSIST=/persist`
  - destructive persistence markers live under `/persist`

Update other tests:

- `tests/test_section3_bootstrap.sh`
  - persisted Claude JSON and GitHub CLI paths
- `tests/test_section6_tools.sh`
  - `dx-ai` persisted paths
- `tests/test_section9_host_scripts.sh`
  - `dx-reclaim` uses `DX_PERSIST_VOLUME` and fixed `/persist`
  - host scripts do not export or consume `DX_PERSIST_PATH`
- `tests/test_section10_docs.sh`
  - README path and variable assertions
- `tests/test_section11_validate_fresh.sh`
  - persistence marker path
- `tests/standalone_test_factory_reset.sh`
  - inspect `$DX_PERSIST_VOLUME`

Add one negative/static sweep test so stale canonical names do not creep back in:

```bash
rg -n '/workspace|dx-workspace|DX_WORKSPACE|WORKSPACE' \
  --hidden -g '!.git' -g '!workspace-persist.md'
```

The expected remaining matches should be only the deprecation guard, migration
helper/docs/tests, and explicit legacy text. There should be no runtime
`~/workspace`, `$WORKSPACE`, or `DX_PERSIST_PATH` references.

## 7. Verification

Run focused static tests first:

```bash
tests/run_all_tests.sh --section=3 --skip-integration
tests/run_all_tests.sh --section=6 --skip-integration
tests/run_all_tests.sh --section=9 --skip-integration
tests/run_all_tests.sh --section=10 --skip-integration
tests/run_all_tests.sh --section=16 --skip-integration
```

Then run the full suite:

```bash
tests/run_all_tests.sh
```

Smoke-test the migration on throwaway volumes before recommending it to users.
For a real upgrade, verify the copied data through the new `/persist` mount
before deleting `dx-workspace`.
