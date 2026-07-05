# Complete Base-Image and NixOS 26.05 Bump Plan

## Executive finding

The repository implementation is substantially complete:

- the community `nixpkgs/nix-flakes` base has been replaced with the official,
  digest-pinned `nixos/nix` base;
- the source, lock file, defaults, tests, and documentation have been bumped
  from NixOS 25.11 to 26.05;
- compatibility failures found by the official-base and 26.05 canaries have
  been fixed;
- the dual-base design in `flakes-to-nix.md` was deliberately superseded and
  is not missing implementation.

The destructive canary and primary changeover have already been executed.
The remaining work is documentation closure, a recorded post-Tinted full-suite
run, repeatable Tinted runtime coverage, and several hardening items that both
plans explicitly deferred. Do not reintroduce dual-base support or repeat the
destructive changeover to complete this bump.

This audit was made against `main` at commit `37efce9` on 2026-07-05.

## Independent review disposition

`complete-bump-review.md` was checked finding-by-finding against the current
tree. Its authorship caveat matters: its author also authored the
implementation, so it is an independent review of this audit document, not an
independent implementation review.

- **Accepted:** R-01, R-03, R-05, R-06, R-08, R-09, and R-10.
- **Accepted with clarification:** R-02. The Nushell failure was found through
  live testing on the `dx-test` Stage-B canary, not the formal
  `nixos-2605.env` Phase-3 path described by `plan.md` (that profile does not
  exist in the tree). The document should distinguish those paths instead of
  saying simply that Phase 3 both ran and did not run.
- **Accepted, but the review's narrowing is rejected:** R-04 correctly finds
  that `--skip-integration` performs live work. Section 16 checks the flag only
  around its migration-helper subtest; it then continues into live persistence
  checks. Sections 15, 16, and 17 therefore all need an outer live-check skip.
- **Accepted as session execution evidence, not durable raw evidence:** R-07
  records successful Stage-A, Stage-B, and primary full-suite runs. That is
  enough to avoid repeating the destructive canary/changeover. The remaining
  validation gap is one recorded full-suite run against the current
  post-`37efce9` primary plus a post-Tinted flake check.
- **Accepted with a narrower implementation:** R-13 correctly diagnoses
  project.nvim's empty-history warning as an unconditional direct
  `vim.notify(..., WARN)` with no configuration switch. Keep the proposed
  config-local suppression, but match the complete message and WARN level
  exactly instead of filtering on two substrings. This preserves unrelated
  project.nvim and Neovim notifications.
- **Accepted as session evidence:** Round 2 records section 18 passing 55/55
  on the normal host. The earlier 54/55 sandbox result no longer requires a
  separate rerun, although the host result is still an attributed execution
  record rather than retained raw output.

Round 2 also correctly stresses that incorporating findings into this
document does not implement them. At `37efce9`, every P0 source/documentation
change below remains open in the repository.

Round 3 found no new inaccuracies and re-verified the refined R-13 filter.
Treat this document as a converged, decision-complete specification: do not
request another review round unless the repository or requirements change.
The next useful work is execution of the ordered P0/P1 items, not further
expansion of the plan.

## Implemented

### Official base-image changeover

- `Containerfile` contains one non-blank line and uses the official base:

  ```text
  FROM nixos/nix:2.34.7@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
  ```

- The Nix version was realigned from 2.31.5 to 2.34.7 as part of the 26.05
  release bump, and the exact `tag@digest` line is enforced by section 2.
- No `DX_BASE`, `DX_CONTAINERFILE`, `Containerfile.nix`, flavor-specific
  resource names, or coexistence machinery was added.
- Both temporary old-base guards exist and are behaviorally tested:
  `guard_old_base` in `bootstrap.sh` and its host-side twin in
  `bin/dx-start-container`.

### Bootstrap compatibility

The original base-agnostic changes and all canary findings are implemented:

- `#!/usr/bin/env bash` bootstrap entry;
- `useradd ... -s /bin/sh`;
- root essentials profile discovery before the reinstall skip gate;
- post-install essentials PATH refresh;
- symlinked `/etc/{passwd,group,shadow,gshadow}` materialization;
- `/usr/bin/bash` link for non-interactive SSH without creating `/bin/bash`;
- guest `/etc/os-release` publication from the pinned flake release;
- longer bounded activation waits and preserved activation failure status.

These changes have static and behavioral coverage in section 3.

### Lifecycle safety and tests

- `dx-mount --container NAME --destroy` supports orphan cleanup authorized by
  the identity marker.
- New markers are write-once resource manifests; legacy markers remain
  legacy.
- `--print-destroy-plan`, safe-name validation, recorded-name checks,
  manifest mismatch refusal, and default-resource guards are implemented.
- The mandatory locked-input release oracle exists in section 5:
  `nix eval --raw --no-update-lock-file --inputs-from /guest-bootstrap
  nixpkgs#lib.version`.
- README, `plan.md`, `mount-git.md`, and the superseded header in
  `flakes-to-nix.md` were updated for the single-base design.

### NixOS 26.05 bump

- The context directory, stable flake branches, lock file,
  `home.stateVersion`, default image/context names, release assertions, and
  base-image pin now target 26.05.
- The 26.05 compatibility fixes are committed:
  - `neofetch` replaced by `fastfetch`;
  - redundant `ghostty.terminfo` removed after the ncurses collision;
  - Nushell `$nu.home-path` migrated to `$nu.home-dir`;
  - Tinted Neovim migrated from the deprecated `tinted-colorscheme` shim to
    the current `tinted-nvim` API in commit `37efce9`.
- README now contains a reusable release-bump runbook.

### Changeover file-transfer reliability

- Commit `c63079f` fixed `dx-get` and `dx-put` directory copy-as/copy-into
  semantics, so `/persist` salvage and restore can use a destination name that
  differs from the source basename.
- `dx-put` now excludes macOS AppleDouble `._*` sidecars, preventing those
  metadata files from corrupting Git pack indexes in the guest.
- Section 9 behaviorally covers renamed directory transfers, copy-into
  behavior, and AppleDouble exclusion. These fixes are part of the evidence
  supporting the changeover runbook's salvage procedure.

## Intentionally not implemented

The following `flakes-to-nix.md` work is obsolete rather than incomplete:

- dual Containerfiles and a `DX_BASE` selector;
- `-f`/`DX_CONTAINERFILE` image-build plumbing;
- cross-flavor image, container, and volume guards;
- flavor-specific side-container resources;
- staged default flipping and old-to-new-to-old flavor transitions;
- in-place migration between the flakes and official bases.

`flakes-to-nix.md` is design history. Only its independent hardening items
remain relevant.

## Remaining work to complete the bump

### P0 — Correct the documentation record

1. Fix the contradiction in README's “One release pin” section:
   it currently says root bootstrap essentials are installed with
   `--inputs-from /guest-bootstrap --no-update-lock-file`, then correctly says
   a few lines later that this follow-up is not implemented. The latter is
   true: `install_essentials` still uses registry-resolved `nixpkgs#...`.
2. Replace that section's broad `nix flake update` shortcut with the targeted
   command used by the full runbook, with an explicit flake path:
   `nix flake update nixpkgs nixvim home-manager --flake <context-dir>`.
   The broad command would also refresh `nixpkgs-unstable`, contradicting the
   stated goal of leaving the optional AI package set unchanged during the
   stable release bump; omitting `--flake` also fails when invoked from the
   repository root, which is not itself a flake.
3. Correct two stale cross-references in README's new “Upgrade / Bump”
   runbook:
   - the introduction says the destructive apply is step 6; it is step 7;
   - the static-check warning says activation failures surface at the canary
     in step 5; the canary is step 6.
4. Update `plan.md`'s Phase-3 status wording. Record that the `dx-test`
   Stage-B live canary ran and found the Nushell break. The separately
   specified `tests/profiles/nixos-2605.env` was never added and its rollback
   rehearsal was not run; mark that path superseded by the isolated
   `dx-test` canary and destructive fresh-rebuild strategy rather than adding
   a release-specific profile after promotion.
5. Do not mark the historical checklists in `nix-base-plan.md` complete unless
   there is retained evidence for the operational steps.

### P0 — Make `--skip-integration` truthful

The review run found that `tests/run_all_tests.sh --skip-integration` still
performs live work when a guest is running:

- section 15 proceeds from static Nushell checks into SSH/SCP probes;
- section 16 skips its migration-helper integration block but still proceeds
  into live persistence checks;
- section 17 runs the side-effectful `dx-ai` installer, including network,
  keyring, and persistent-state changes.

Add an explicit `SKIP_INTEGRATION=true` exit between static and live blocks in
sections 15 and 16, and before guest discovery in the all-live section 17.
Retain all static assertions. Add stub-based regression coverage proving that
the skip path invokes no guest, SSH, SCP, container, or `dx-ai` command.

### P0 — Close the validation record with one current run

The independent review records the following completed session runs:

- Stage A: fresh official-base/25.11 `dx-test`, 20-section profile-aware suite,
  restart, and same-base recreate cycle, all green;
- Stage B: fresh 26.05 `dx-test` on the 2.34.7 pin, full suite green, release
  oracle returning 26.05, and matching `/etc/os-release`;
- primary: verified `/persist` salvage, factory reset, 26.05 rebuild,
  `OLD_BASE_ABSENT`, and a full green suite.

Do not repeat those destructive runs. They predate the committed Tinted fix,
and their detailed output is not retained in the repository. Close the
residual with:

1. Run `nix flake check --no-write-lock-file` in an official-base container
   with at least 8 GB of memory against commit `37efce9` or its completion
   successor.
2. Run one complete, profile-aware suite against the current `dx-host`
   without `--skip-integration`.
3. Repeat the explicit headless Tinted spot-check for absence of the
   deprecation and agreement between `vim.g.colors_name` and `tinty current`.
4. Record the command, date, commit, aggregate result, and key outputs:
   release oracle, `VERSION_ID`, old-base exclusion token, and Tinted
   `colors_name`.

### P1 — Commit repeatable Tinted Neovim runtime coverage

The committed configuration and static assertions are coherent, and section
14's static suite passes. Commit `37efce9` and the independent review record a
successful live spot-check: no deprecation and `colors_name` matching Tinty's
current scheme. The current tests still prove only configuration shape, so
the behavior is not repeatably protected.

Add live, profile-aware assertions that:

- Neovim starts without the
  `Deprecated module 'tinted-colorscheme' was loaded` message;
- `vim.g.colors_name` equals `tinty current` at startup;
- changing the scheme while a long-lived Neovim process is running updates
  `vim.g.colors_name`, proving `selector.watch = true`.

The live test must capture the original scheme and restore it with
`dx-theme apply "$original"` on every exit path.
Run section 14's live block after the regression lands; the destructive
canary and full primary suite do not need to be repeated solely for this test.

Refactor the untracked `tinted-nvim-plan.md` before retaining it:

- remove its stray closing code fence;
- add an “implemented in `37efce9`; live validation outstanding” status;
- replace its optional `project.nvim` discussion with a reference to the
  separate P1 warning fix below;
- replace the claim that `dx-recreate` is merely reactivation.
  `dx-recreate` removes the container and image while preserving volumes.
  A payload-only apply can use `dx-stop-container`, `dx-start-container`, and
  `dx-wait-ssh`.

### P1 — Remove project.nvim's empty-history warning

The remaining
`(project.util.history.write_history): No data available to write!` warning is
benign but unconditional. The shipped project.nvim calls
`vim.notify(message, vim.log.levels.WARN)` directly when it writes an empty
history, bypassing its disabled-by-default logging configuration. It fires on
dashboard/scratch sessions through the deferred write and `VimLeavePre`; no
project.nvim option suppresses it.

Keep this isolated from the base/release work and implement it in
`nvim/plugins/project-nvim.nix` through that module's `extraConfigLua`.
Capture the current notifier and drop only the exact known warning:

```lua
do
  local notify = vim.notify
  local empty_history =
    "(project.util.history.write_history): No data available to write!"

  vim.notify = function(msg, level, opts)
    if msg == empty_history and level == vim.log.levels.WARN then
      return
    end
    return notify(msg, level, opts)
  end
end
```

This exact message-and-level comparison is preferred over R-13's two
substring checks: `vim.notify` is global, so the filter should have the
smallest possible match surface. The tradeoff is deliberate brittleness: if a
future project.nvim release changes the module or message text, the warning
will visibly return instead of risking suppression of an unrelated warning.
Add project.nvim to the plugin-version watch list: on every version change,
re-read the emitted string and rerun the notification regression before
updating the exact match. Do not patch the immutable plugin source, disable
valid history writes, or suppress other warnings. The current config does not
install `nvim-notify` or `noice`; if a future plugin replaces `vim.notify`,
move this filter after that provider or wrap the final notifier from
`VimEnter`.

Add a live behavioral regression that uses isolated temporary Neovim state,
forces `project.util.history.write_history()` with no project data, and
asserts:

- the exact empty-history warning is absent;
- a control `vim.notify("dx-project-notify-control", WARN)` remains visible;
- a normal recognised-project session can still write history.

Land this with the Tinted runtime regression as one Neovim payload-polish
slice, then apply once with `dx-stop-container` → `dx-start-container` →
`dx-wait-ssh`. Neither change requires an image rebuild or destructive
changeover.

### P1 — Finish and track the audit artifacts

The audit documents are currently untracked. The evidence statement that only
`tinted-nvim-plan.md` was uncommitted became stale as soon as this plan and
its review were created.

- Correct `tinted-nvim-plan.md` as described above and retain it as
  implemented design history.
- Track `complete-bump-plan.md`, `complete-bump-review.md`, and the corrected
  Tinted plan together, or deliberately delete any document that is only
  scratch. Do not leave multiple untracked audit documents to drift.
- Run `git diff --check` before committing the documentation set.

### P1 — Validate the reusable README runbook

A targeted static pass during this assessment found the step-number and
re-lock-command defects listed under P0. After those corrections, review the
runbook command-by-command against the host scripts and next available release
before relying on it operationally. In particular verify:

- aligned Nix-version selection and manifest-list digest lookup;
- the ≥8 GB flake-check requirement and failure detection;
- targeted stable-input lock regeneration;
- clean-profile canary isolation;
- salvage, referrer-first cleanup, rebuild, and provenance gates.

This is a review of the reusable future procedure, not a reason to repeat the
completed 25.11→26.05 changeover.

### Conditional cleanup — temporary old-base guards

Retain both old-base guards by default. Source and local runtime names cannot
prove that every developer machine, custom profile, and side container has
changed over.

Remove the guards and their tests only after an explicit inventory confirms
all deployments use the official base. Land removal as a separate cleanup
commit and update README's changeover text at the same time.

## Deferred hardening that remains unimplemented

These are real gaps, but the plans classify them as independent follow-ups;
they do not invalidate the completed fresh rebuild.

### `.env` precedence and test seam

`bin/dx-lib.sh` still sources `.env` after inherited variables, allowing it to
overwrite process/profile values. `DX_ENV_FILE` does not exist.

The eventual fix should preserve process-environment precedence, add the
test-only/configurable env-file path, and cover conflicting and non-conflicting
variables. Until then, destructive runbooks must require an absent or fully
reviewed `.env` and a reviewed inherited `DX_*` environment.

### Bootstrap nixpkgs pin and provenance

Root bootstrap essentials still resolve `nixpkgs#...` through the global
registry. There is no persisted essentials provenance artifact. Implement
this only after reconciling the original proposal with the store-registration
problem below; do not copy the superseded design blindly.

### Reused-volume Nix pin safety: F-09 and F-10

`setup_nix_volume` still copies image store paths with `cp -a -n` and treats
copy errors as non-fatal:

- a reused volume can continue executing an older Nix binary instead of the
  new image's binary;
- copied store paths are not registered in the reused volume's Nix database
  and can be invisible to `nix path-info` or garbage collected.

There is no valid volume-reusing Nix image-pin bump procedure until both
defects have a Nix-supported closure-transfer/registration solution and an
old→new→old GC-survival test. Future pin-changing bumps must continue using
salvage plus full destroy-and-rebuild.

## Review evidence and limitations

- The tracked worktree was clean when the base-plan audit began.
- At the time of the independent-review incorporation,
  `complete-bump-plan.md`, `complete-bump-review.md`, and
  `tinted-nvim-plan.md` were all untracked. The Tinted implementation and
  static tests were committed as `37efce9`.
- `git diff --check` passed for the reviewed Tinted changes.
- Plan-specific static suites passed for the Containerfile, bootstrap, host
  scripts, docs, and Tinted configuration.
- The original review sandbox produced 54/55 in section 18 because it
  prevented `nc` from opening the loopback listener. Round 2 records a normal
  host rerun passing 55/55, so that validation item is satisfied.
- Direct `container exec` and the live section-5 oracle were blocked by the
  review sandbox. Resource listing showed running `dx-host` and `dx-test`
  containers using the 26.05 local images, but names alone are not provenance.
- The broad suite was stopped when `--skip-integration` unexpectedly entered
  section 17 and began the persistent `dx-ai` path.
- The independent review supplies a detailed session execution record for the
  Stage-A, Stage-B, and primary full-suite runs, but no raw logs are retained
  in the repository. This plan accepts that record and requires only the
  current post-Tinted run described above.
- The independent review's statement that section 16 already complies with
  `--skip-integration` is incomplete: only its migration-helper block skips;
  the live persistence block still runs.

## Completion criteria

The bump is complete when:

- README and `plan.md` state the implemented behavior without contradictions
  or stale step references;
- `--skip-integration` performs no live work in sections 15–17;
- the Tinted Neovim runtime behavior is committed as a repeatable test;
- Neovim suppresses only project.nvim's exact benign empty-history warning,
  with a regression proving unrelated notifications and real history writes
  still work;
- the post-Tinted flake check and one current full `dx-host` suite are green
  and recorded;
- all relevant static, flake, and live tests pass without unexplained skips;
- temporary old-base guards are either retained with their reason or removed
  after a recorded all-deployment inventory;
- deferred `.env`, bootstrap-provenance, and F-09/F-10 work remains clearly
  separated from the completed bump;
- the audit artifacts are either tracked or deliberately removed;
- no dual-base interface or migration machinery is introduced.
