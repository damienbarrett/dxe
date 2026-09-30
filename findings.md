# Consolidated findings plan (2026-09-29)

Consolidates three independent reviews of the repository at `4e8c5cc`:
[`docs/reviews/2026-09-29-astra.md`](docs/reviews/2026-09-29-astra.md)
(correctness defects F1–F11, refactors R1–R4),
[`docs/reviews/2026-09-29-muse.md`](docs/reviews/2026-09-29-muse.md)
(structure A–F) and
[`docs/reviews/2026-09-29-fable.md`](docs/reviews/2026-09-29-fable.md)
(Red/Green/Refactor shaping, corrections to the other two, Nix and test
harness). The reviews are the evidence; this file is the executable plan and
the running record. Each item cites the review IDs it consolidates so the
proof is one link away rather than repeated here.

Revisit trigger: when every work package below is marked done or deferred,
or when a live gate on `dx-test` / the QNAP canary contradicts an assumption
recorded in the Decisions section.

Branch: `refactor/findings-2026-09-29` (from `docs/model-reviews-20260929`).

## Workflow and constraints

- Every item is **Red → Green → Refactor** (`constitution.md`). Red is a
  behavioural test that fails on the current tree; Green is the smallest
  change that passes it; Refactor follows with that test as the net. One
  commit per Red/Green pair where practical, one per Refactor.
- Keep: thin entrypoints over sourceable `bin/lib/`; the runtime dispatcher
  with two adapters and its boundary audit; immutable bootstrap generations;
  data-only profiles (never sourced); Bash 3.2 for `bin/` only; the guest is
  Bash 5; `Bootstrap phase:` lines byte-identical; pipefail/SIGPIPE
  discipline; self-proving contract tests.
- Idiomatic Nix where pragmatic: typed Home Manager options over hand-rolled
  shell, flake `checks` over ad-hoc `nix eval`, one package/command mapping.
- Tests validate behaviour. Source-text assertions are allowed only as
  reviewed architectural contracts (WP8.4 gathers them).

### What can be verified where

| Gate | Local (this macOS host, Bash 3.2, Apple `container` running) | CI |
| --- | --- | --- |
| Container-free suite (`tests/run_all_tests.sh --skip-integration`) | yes | yes |
| Bash 3.2 host contracts | yes (the host shell *is* 3.2) | macos-15 |
| ShellCheck | yes, CI's pinned 0.10.0 via `nix shell nixpkgs/nixos-25.05#shellcheck` inside the `nixos/nix` container (scratch helper `shellcheck.sh`; reproduces CI's findings exactly) | pinned 0.10.0 |
| kcov coverage + ratchet | probably, via the Apple runtime (`run-coverage-linux.sh` accepts it as provider); unverified until WP1.1 lands | ubuntu-24.04 |
| Nix evaluation / `checks` | yes, via the Apple runtime: `container run --rm --memory 8g -v <guest>:/src:ro nixos/nix:2.34.8 sh -c 'nix --extra-experimental-features "nix-command flakes" flake check --no-build --no-write-lock-file --all-systems /src'` (1 GB default memory gets OOM-killed at NixVim) | ubuntu-24.04 |
| Live guest (`dx-test`) | Apple runtime available | manual only |

Items whose Red can only fail on CI (kcov, Nix) are marked **CI-verified**:
the test is written and reasoned locally, and the commit is confirmed by the
next CI run before the item is marked done.

### Baseline (2026-09-29, `d715f48`, container-free suite on this host)

- 33 suites ran; 3 failed, all pre-existing:
  - Section 10: the three root `findings-*.md` are not indexed in
    `plans.md` (closed by WP0).
  - `test_dx_restore.sh`: two 60,000-target timing assertions (the dev-host
    `fork()` cost the test's own comment describes; WP6.9 / Muse D5).
  - `test_runtime_boundary_audit.sh`: scans an untracked, git-ignored
    `bin/.claude/settings.local.json` (WP1.9: audit only tracked shell).
- Everything else green, including section 33 (Docker adapter, 179 cases).

## Status vocabulary

`[ ]` not started · `[~]` in progress · `[x] <sha>` landed · `[-]` deferred
(reason recorded inline) · **CI-verified** as above.

## Finding register

Every review ID and where it lands.

| Review ID | Item | Review ID | Item | Review ID | Item |
| --- | --- | --- | --- | --- | --- |
| Astra F1 | WP6.1 | Muse A1 | WP4.1 | Fable A1 | WP3.4 |
| Astra F2 | WP6.2 | Muse A2 | WP8.3 | Fable A2 | WP5.1 |
| Astra F3 | WP6.4 | Muse A3 | WP4.5 | Fable A3 | WP5.2 |
| Astra F4 | WP6.5 | Muse A4 | WP4.5 | Fable A4 | WP4.1 |
| Astra F5 | WP6.6 | Muse A5 | WP4.5 | Fable A5 | WP4.3 |
| Astra F6 | WP3.3 | Muse A6 | WP9.5 | Fable A6 | WP4.2 |
| Astra F7 | WP6.7 | Muse B1 | WP8.1 | Fable A7 | WP8.3 |
| Astra F8 | WP6.8 | Muse B2 | WP8.1 | Fable B1 | WP3.1 |
| Astra F9 | WP6.3 | Muse B3 | WP3.3 | Fable B2 | WP3.2 |
| Astra F10 | WP4.3 | Muse B4 | WP7.3 | Fable B3 | WP3.5 |
| Astra F11 | WP2.1 | Muse B5 | WP9.4 | Fable B4 | WP3.6 |
| Astra R1 | WP1.5 | Muse B6 | WP7.6 | Fable B5 | WP3.3 |
| Astra R2 | WP1.4, WP8.4 | Muse B7 | WP8.2 | Fable B6 | WP8.1 |
| Astra R3 | WP5.2, WP8.3 | Muse C1 | WP4.3 | Fable B7 | WP8.2 |
| Astra R4 | WP6.9 | Muse C2 | WP4.3 | Fable B8 | WP4.4 |
| | | Muse D1 | WP1.4 | Fable B9 | WP8.2 |
| | | Muse D2 | WP1.5 | Fable B10 | WP8.2 |
| | | Muse D3 | WP8.4 | Fable B11 | WP8.2 |
| | | Muse D4 | WP6 (all) | Fable C1 | WP2.1 |
| | | Muse D5 | WP6.9, WP9.6 | Fable C2 | WP2.2 |
| | | Muse E1 | WP2.1 | Fable C3 | WP7.3 |
| | | Muse E2 | WP9.3 | Fable C4 | WP7.4 |
| | | Muse E3 | keep as is | Fable C5 | WP7.5 |
| | | Muse E4 | WP9.3 | Fable C6 | WP7.6 |
| | | Muse F1 | WP9.1 | Fable C7 | WP7.7 |
| | | Muse F2 | WP9.2 | Fable C8 | WP7.8 |
| | | Muse F3 | WP9.2 | Fable D1 | WP1.1 |
| | | | | Fable D2 | WP1.4 |
| | | | | Fable D3 | WP1.5 |
| | | | | Fable D4 | WP1.6 |
| | | | | Fable D5 | WP1.2 |
| | | | | Fable D6 | WP1.8 |
| | | | | Fable D7 | WP8.4 |
| | | | | Fable D8 | WP8.4 |
| | | | | Fable D9 | WP1.3 |
| | | | | Fable D10 | WP1.7 |
| | | | | Fable D11 | WP1.3 |
| | | | | Fable E1 | WP9.3 |
| | | | | Fable E2 | WP0 |
| | | | | Fable E3 | WP1.2 |

## Decisions

- **D-1 Metric before v2 Phase 4.** Closes the `plans.md` conflict between
  `declarative-nix-plan-a.md` #12 and `refactor-v2-final.md` Phase 4: the
  two-number metric (WP1.5) lands first; v2 Phase 4 re-measures those two
  numbers. Rationale: Fable's argument that v2's own gates add tests, which
  the current ratio reports as regressions.
- **D-2 Reviews live under `docs/reviews/`.** Root `*.md` stays reserved for
  plans indexed by `plans.md`; reviews are evidence and are indexed by
  `docs/reviews/README.md`.
- **D-3 Fable's sequence, Astra's F-series after the seams.** All three
  reviews agree the F-series needs fault-injection fixtures; those are cheap
  only after WP1. Exceptions pulled forward because they are data-loss
  shapes with a ten-line Red already: F6 (into WP3.3) and F10 (into WP4.3).
- **D-4 Corrections adopted from Fable.** `unit/static` omits sections 0, 4,
  19, 24 and 33 (not just 33); section 5 already evaluates the ARM tree, so
  `--all-systems` alone does not close Astra F11 (a `checks` output does);
  the `agy` skew is pinned by a value test, not undocumented.

## Work packages

### WP0 — Plan bookkeeping (no production change)

- [x] **WP0.1** Move `findings-{astra,muse,fable}.md` to
  `docs/reviews/2026-09-29-<name>.md`; add `docs/reviews/README.md`
  index; index this file in `plans.md` under Open plans. *Red:* section 10
  case asserting no root `findings-*.md` exists and `docs/reviews/README.md`
  links every file in `docs/reviews/`. (Fable E2)

### WP1 — Test foundations (no production change)

- [x] (this commit) **WP1.1** `tests/lib/harness.sh`: import-pure, Bash 3.2-clean;
  `it`, `expect_exit`, `expect_stdout`, `expect_stderr`, `expect_file_eq`,
  `skip --class`, `finish`; results recorded one line per case to an
  append-only file (`$DXE_TEST_RESULTS`) so subshell assertions survive;
  `finish` exits non-zero on any failure or zero cases. `test_pass`/`test_fail`
  become shims. *Red:* `tests/test_harness.sh` (`expect_exit 3 bash -c 'exit
  3'` passes; `( expect_exit 0 false )` still fails the run; a failing
  `expect_stdout` prints the capture). (Fable D1)
- [x] ad7fea8 **WP1.2** Shared runtime fakes: `with_fake_runtime docker|container|ssh`
  appending one `%q` argv per line to `$FAKE_TRANSCRIPT`; `fake_fail_nth`;
  `expect_transcript`; fakes use `#!/usr/bin/env bash`; single PATH
  convention. Fix `fake-tools.sh:73` `>` → `>>`. *Red:* two recorded
  invocations, second exits 42. (Fable D5, E3)
- [x] ca1681f **WP1.3** Fixture isolation and skip semantics: `with_fixture` puts
  `HOME`, `XDG_STATE_HOME`, `TMPDIR` under the fixture, unsets
  `DXE_CONFIG_RESOLVED`, `finish` diffs the known-hosts snapshot; `skip
  --class live|linux-root|destructive` recorded; a suite that records only
  skips fails unless `# skip-ok:`. (Fable D9, D11)
- [ ] **WP1.4** Test registration: `# tier:` and `# bash32:` headers on every
  `tests/test_*.sh`; `tests/run.sh --tier X` selects by header; the four
  runners become wrappers; `--help` fixed; contract test fails on a file with
  zero or two tiers. *Red:* header contract fails today. (Fable D2, Muse D1,
  Astra R2)
- [x] bf866c8 (floor set 2026-09-30) **WP1.5** Coverage metric: `tests/lib/coverage-metric.sh` computing
  `scope_exec_lines` (Σ kcov `total_lines` over scope, floor) and
  `unscoped_prod_exec_lines` (non-comment lines in the exempt production set,
  ceiling); `ratchet.env` shrinks to two lines, history to
  `docs/evidence/20260929/ratchet-history.md`. *Red:*
  `tests/test_coverage_metric.sh` with a fixture `coverage.json` (adding test
  lines and comment lines changes nothing; moving 10 exec lines into
  `bin/dx-x` fires both). **CI-verified** for the live numbers. (Fable D3,
  Muse D2, Astra R1)
- [x] 34838b5..5e039e8 **WP1.6** `test_helpers.sh` import purity: no `set` in the sourcing
  shell, `CONTAINER_DIR` via `dx_test_guest_dir`, no production sourcing from
  the helper. *Red:* extend the `$-` contract to `tests/lib/*.sh` and
  `test_helpers.sh`. (Fable D4)
- [x] 6d05c4e..d47aae8 **WP1.7** Replace unit-tier `sleep`s with readiness markers; harness
  `wait_until`; contract forbids bare `sleep N` in unit-tier files. (Fable D10)
- [x] a201a80 **WP1.8** Contract: no column-0 coreutil override outside a subshell in
  `tests/test_*.sh`; fix `test_section17:50`. (Fable D6)
- [x] 862ede8 **WP1.9** `test_runtime_boundary_audit.sh` scans git-tracked shell only
  (baseline failure on an ignored `.claude/settings.local.json`).

### WP2 — Nix checks in CI (no guest behaviour change)

- [x] fb705a9+cabac33 **WP2.1** Flake `checks` per system: `home-activation`, `ai-tools`,
  `alias-is-identity`; CI runs `nix flake check --no-build --all-systems`;
  section 5 requires `checks.<system>.home-activation.drvPath` without
  `|| true`; section 0's literal updated; `validation-matrix.md` corrected.
  **CI-verified.** (Fable C1, Astra F11, Muse E1)
- [x] 3b7cac8 **WP2.2** Warnings contract: evaluating the checks prints zero
  `trace: warning|evaluation warning` lines. Green: `programs.git.settings`,
  `makeNixvimWithModule { inherit pkgs; }`, decide gemini (pin out or hard
  error). **CI-verified.** (Fable C2)

### WP3 — Correctness with reproductions (guest and host)

- [x] 0416271+758caf9 **WP3.1** `dx_ai_setup_credentials` must not clobber a non-JSON
  `settings.json`. *Red:* fixture `{not json`; exit ≠ 0, `Error:` names the
  file, bytes unchanged. Refactor: `dx_ai_merge_json_setting`. (Fable B1)
- [x] e2a2b8b+18b506e **WP3.2** `prepare_nix_volume_impl` checks `mkfs`, `truncate`, `mount`.
  *Red:* failing `mount` stub + `tar` sentinel; exit ≠ 0, `DX_NIX_VOLUME_ROOT`
  unset, sentinel never fires. Record mount/mkfs stubs as live-only in
  `validation-matrix.md`. (Fable B2)
- [x] ce1b719+e7944e0+ba21e14 **WP3.3** Deny-list as arrays, `find` predicates generated from them,
  extra patterns passed as records not `$*`; explicit missing exclude file
  aborts before guest access. *Red:* (a) CWD containing `result-bin` still
  denies `p/result-abc`; (b) walk/list equivalence with `dx_pbs_path_denied`;
  (c) pattern with a space honoured; (d) `dx-backup` with an absent explicit
  exclude file exits non-zero before any guest call. (Fable B5, Astra F6,
  Muse B3)
- [ ] **WP3.4** Tunnel key identity fails closed and is cached. *Red:*
  section 19 with fake `ssh` flipped to 255: list names the same socket, stop
  removes it, zero `ssh` calls. Green: daemon-id state file + `|| return 1`.
  (Fable A1)
- [x] 2295206+5326b9e **WP3.5** `dx-ai` lock: ownerless directory reclaimed; owner written
  via tmp+mv; stale takeover by rename-then-remove. *Red:* ownerless lock
  acquired; reclaim loses when target exists. (Fable B3)
- [x] 168d3e8 **WP3.6** `dx-ai` failure messages and orphan-stage GC. *Red:* missing
  staged tool → stderr `Error:` with path; `.staging-old` removed under the
  lock. (Fable B4)

### WP4 — Seams

- [x] a570257..32dc43d **WP4.1** Main-guarded entrypoints: `<name>_main` + `BASH_SOURCE`
  guard, one file per commit, starting `dx-mount`, `dx-sync-bootstrap`,
  `dx-status`, `dx-herdr`, `dx-create-container`, `dx-wait-ssh`; then the
  rest. Remove each from `exclusions.txt` as it lands. *Red:* contract that
  sources each `bin/dx*` with no output, no exit, `<name>_main` defined.
  (Fable A4, Muse A1)
- [x] 3de5916..41822f3 **WP4.2** `dx_wait_until <timeout> <interval> <cmd…>` with `DX_SLEEP`;
  migrate the seven loops one per commit; `dx-sync-bootstrap` honours
  `DX_BOOTSTRAP_WAIT_TIMEOUT`. (Fable A6)
- [x] 2f734a7..b6ddceb **WP4.3** Config registry: validator rejects unknown names;
  `DX_BOOTSTRAP_SOURCE` default independent of field order; runtime × storage
  × arch compatibility matrix and distinct volume roles enforced at
  resolution; then one `DXE_CONFIG_REGISTRY` table and a generated defaults
  table for `docs/configuration.md`. *Red:* `DX_RUNTIME=docker-ssh` +
  `apple-image` rejected; `DX_NOT_A_FIELD` rejected. (Fable A5, Astra F10,
  Muse C1, C2)
- [x] b752e39+cdf4166 **WP4.4** `bootstrap_phases()` split from `bootstrap_main()`; the
  grep-line-number order test replaced by a shadowed-function log. (Fable B8)
- [ ] **WP4.5** Host duplication helpers: `dx_require_running_container`,
  `dx_prepare_state_dir`, `dx_tar_create`, `dx_die`/`dx_warn`, the SSH-opts
  reader; entry preamble documented (not generated); allowed Bash 3.2 shim
  set documented once. (Muse A3, A4, A5, A6)

### WP5 — Protocol pins

- [x] 53c4716+8315ff8 **WP5.1** `dx-sync-bootstrap --result-file` (`outcome=`, `generation=`
  in the config grammar); `dx-start-container` reads it; string parser
  deleted; sync body moves to `bin/lib/dx-bootstrap-sync.sh`. *Red:* reworded
  success line must still make start fail when the lease never matches.
  (Fable A2)
  *Design note (2026-09-30, agent research, no code yet):* new
  `bin/lib/dx-bootstrap-sync.sh` sourced after `dx-container.sh` holding
  `dx_bootstrap_sync <container> <source> <path>` (the whole sync body; the
  guest heredoc copied byte-for-byte; returns 0 published / 3 unchanged / 1
  error; generation id handed back by dynamic scoping so the "Syncing…"
  line keeps its real-time order), `dx_bootstrap_sync_result_write` (tmp +
  `mv -f`, two lines) and `dx_bootstrap_sync_result_read` (own bounded
  reader: exactly `outcome=` and `generation=`, never sourced; `dx-config.sh`
  is off-limits to that task). Trap found: once the tar pipeline lives in a
  function called as `f || status=$?`, errexit is suspended, so that one
  pipeline needs an explicit `if ! …; then return 1; fi`. Entrypoints: sync
  parses `--result-file`; start passes a mktemp path, reads it, and fails
  loudly when missing or malformed; delete `dx_bootstrap_sync_published_generation`
  and its two comment references in `dx-container.sh`. Tests: Red = fixture
  copy of `bin/` with a reworded fake sync + never-matching lease must fail
  the start (today: drift warning, exit 0); plus missing/malformed result
  file, missing source, lock held/timeout (`DX_SLEEP`); section 9's
  unit block for the deleted parser becomes read/write round-trip cases.
  Uncovered-today branches also worth cases: container absent, unsafe
  `DX_BOOTSTRAP_PATH`, entrypoint never ready.
- [ ] **WP5.2** One rendered publication-lock protocol
  (`bin/lib/dx-bootstrap-protocol.sh`) used by launcher and sync; one contract
  fixture (live owner, previous boot, reused PID, ownerless) run against all
  three copies including `dx-ai`; shipped as `scripts/lib/dx-publication.sh`.
  (Fable A3, B3, Astra R3)

### WP6 — Astra correctness series (fault-injection fixtures from WP1)

- [x] fc29467..1faf347 **WP6.1** Backup scan completeness is a contract: traversal/Git/stat/
  hash errors abort; no mirror removal or manifest publish unless the whole
  selection succeeded. *Red:* `chmod 000` subtree leaves mirror and manifest
  intact (run unprivileged). (Astra F1)
- [x] 321c4db **WP6.2** Detached-HEAD and stash/tag reachability in whole-repo
  selection. *Red:* detached local commit yields entries and `.git`. (Astra F2)
- [x] c1b0feb **WP6.3** Restore directory selection joins paths as data. *Red:*
  `a&b`, `#`, backslash, leading hyphen. (Astra F9)
- [x] d211eb8..dfa5864 **WP6.4** One owned-resource check before adopt/attach/start/stop/kill/
  delete; schema and system labels validated. *Red:* foreign running
  container receives zero stop/kill/delete calls; schema 999 refused. (Astra F3)
- [x] c9a7899..2ba5775 **WP6.5** Operation-level lifecycle lock acquired by every mutating
  entrypoint with nested-owner inheritance; local claims scoped by daemon
  identity. *Red:* two controllers cannot mutate concurrently; nested calls do
  not deadlock. (Astra F4)
- [x] ddb574b..ff4d2a0 **WP6.6** Transactional mirror: per-backup lock shared with restore;
  stage, verify hashes, publish generation by atomic pointer. *Red:*
  truncated archive leaves the previous snapshot usable. (Astra F5)
- [x] **WP6.7** Healthcheck validates full lease identity and a completion
  marker. *Red:* stale lease file → unhealthy. (Astra F7)
- [x] **WP6.8** Healthcheck program fixed; `DX_BOOTSTRAP_PATH` transported as
  data. *Red:* path containing `$(printf injected >&2)` produces no side
  effect. (Astra F8)
- [x] ce63dc7..324fbaf **WP6.9** Restore: one-pass parent-dir dedupe, bounded transport,
  single guest `chown`. *Red:* large-tree recording test asserting bounded
  runtime-call count; the baseline timing failures re-examined. (Astra R4,
  Muse D5)

### WP7 — Nix hygiene (each lands with its `checks` entry; CI-verified)

- [x] f11664c **WP7.3** `guest-tools.nix` mapping → `dxPackages`, inventory list and
  `checks.inventory`; duplicate `home.packages` and duplicate
  `dx-keyring.sh` definition removed; `sed` scrapes retired. (Fable C3, Muse B4)
- [x] f11664c **WP7.4** Typed shell integration: `programs.starship/direnv/yazi/
  lazygit`, `home.sessionPath`, `programs.nushell.settings`;
  `checks.<shell>-integration`. (Fable C4)
- [x] c6c7ebb **WP7.5** `writeShellApplication` wrappers for installed guest commands
  with `runtimeInputs`; `checks.scripts-hermetic`. (Fable C5)
- [x] 8e8f0b3 **WP7.6** `agy` pin shape check replaces value assertions; derivation
  slimmed with `meta`; skew note recorded. (Fable C6, Muse B6)
- [x] 8e7261f **WP7.7** NixVim typed modules for comment/ts-context/tmux-navigator;
  `checks.nvim` via `mkTestDerivationFromNixvimModule`. (Fable C7)
- [x] aa2e9b1 **WP7.8** `allowUnfreePredicate`; stable via `legacyPackages`. (Fable C8)

### WP8 — Structural splits

- [~] a1f9b2b..327f6bb (Phases 0-2 + C5) **WP8.1** `refactor-v2-final.md` Phases 0–4 with Fable B6's seven
  corrections (three-mode record incl. `in-place`, fourth positional for
  image-store identity, durable-identity contract, owner resolved once, dead
  `setup_nix_volume` deleted, line refs refreshed); Phase 4 split per the B6
  matrix. (Muse B1, B2, Fable B6)
- [x] 2cd212b..c156c0f **WP8.2** `dx-ai.sh` split into `scripts/lib/dx-ai-{lock,generation,
  pin,cache-policy,post-install}.sh`; `dx_ai_run_locked`;
  `dx_ai_load_library`; `dx_persist_relocate_dir` shared by gh/herdr/opencode/
  AI-credential sites; `run_as_dx_argv`; B11 one-liners. (Fable B7, B9, B10,
  B11, Muse B7)
- [x] 5142cd8..6892495 **WP8.3** Docker adapter split: `dx_runtime_docker_cli` first (byte-
  equal transcript Red), then transport / identity / lifecycle / lock files
  behind one facade; claims to `dx-claims.sh`; `dx-forward`/`dx-reverse`
  merged into `dx_tunnel_cli`; narrative comments moved to decisions.
  (Muse A2, Fable A7, Astra R3)
- [~] 012c39b+18022a6 (a) **WP8.4** Tests: split `test_docker_runtime_adapter.sh` on its
  section headers; `test_sourceable_coverage.sh` probes migrated to owning
  suites with asserted outcomes (`|| true` count ratcheted from 149); D7's six
  conversions; remaining source-text contracts gathered in
  `tests/test_contracts_source.sh`. (Fable D7, D8, Muse D3, Astra R2)

### WP9 — Docs and retirement

- [ ] **WP9.1** Retire `checkout-consolidation-plan.md` after Phase 7 live
  steps; resolve Q7 per D-1; every Open plan carries an owner for its
  revisit trigger. (Muse F1)
- [x] 267dcc0 **WP9.2** `docs/README.md` map (entry points → operating docs →
  decisions → evidence → reviews); stale cross-reference sweep; section 10
  flags `plans.md`-indexed but removed files. (Muse F2, F3)
- [x] d9a0b31 **WP9.3** CI notes: ShellCheck crash list names both files; section 0
  fails loudly with `--strict` when the binary is absent; hermetic-vs-live
  tiers stated once in `validation-matrix.md`. (Fable E1, Muse E2, E4)
- [ ] **WP9.4** Rename `container/aarch64-darwin-apple-container-dx-nixos-26.05/`
  to `container/dx-nixos-26.05/` once WP1.6's `dx_test_guest_dir` makes it a
  one-line test change. (Muse B5)
- [x] eab62eb **WP9.5** Stale text: `dx-lib.sh:2`, `dx-nix-disk:21–24`. (Fable A7,
  Muse A6)
- [x] 59dbb4a **WP9.6** Promote or defer the four backlog probes from
  `checkout-consolidation-plan.md` with owners. (Muse D5)

## Progress log

- **2026-09-29** Plan written; baseline recorded; branch created.
- **2026-09-29** WP0 landed: reviews moved to `docs/reviews/`, indexed; `findings.md` indexed in `plans.md`; section 10 green (158 cases). WP1.1 next.
- **2026-09-30** WP1.9 landed (862ede8): boundary audit scans git-tracked files only; baseline failure closed.
- **2026-09-30** WP1.5 landed (bf866c8): two-number metric, `ratchet.env` is 4 lines, history in `docs/evidence/20260930/`. Open: `scope_exec_lines_floor=0` until the first kcov run sets it (local run via the Apple runtime planned after WP1.1).
- **2026-09-30** WP2.1/WP2.2 landed (fb705a9, 3b7cac8, cabac33): flake `checks` for both systems (home-activation, ai-tools, bootstrap-essentials, alias-is-identity), CI `--all-systems`, zero evaluation warnings. Verified locally via the container runtime. Open decision for the user: keep gemini-cli (acknowledged removal notice) or drop it from `DX_AI_TOOLS` + `aiPackages`.
- **2026-09-30** WP3.1 landed (0416271, 758caf9): a non-JSON `settings.json` is refused, never clobbered; `dx_ai_merge_json_setting` extracted.
- **2026-09-30** WP3.2 landed (e2a2b8b, 18b506e): mkfs/truncate/mount failures abort `prepare_nix_volume` with `DX_NIX_VOLUME_ROOT` unset; `dx_nix_format_device`/`dx_nix_mount` extracted with pinned argv; `DX_NIX_RAW_PATH` override added for unprivileged fixtures (mirrors `DX_NIX_DISK_SIZE`); live-only validation of these stubs recorded in `validation-matrix.md`.
- **2026-09-30** WP4.4 landed (b752e39, cdf4166): `bootstrap_phases()` split from `bootstrap_main()`; phase order asserted by running it with shadowed phases; grep-line-number test deleted; six literal `Bootstrap phase:` assertions converted to behavioural cases (Fable D7 item 1). Correction to Fable B8: `bootstrap.sh` already carried the `BASH_SOURCE` guard (since 59c7b7b); only the phases/main split was missing.
- **2026-09-30** WP3.5/WP3.6 landed (2295206, 5326b9e, 168d3e8): ownerless lock reclaimed, owner written tmp+mv, stale takeover by rename-then-remove; lock moved to `scripts/lib/dx-ai-lock.sh` (kcov scope); `dx_ai_fail` at ~20 sites; `.staging-*` orphans collected; `dx_ai_run_locked` replaces the release epilogue. Section 17: 95 → 115. Caveat from the agent: the three lock-release-on-failure cases are regression tests, not reproductions (the old epilogues already released). Note for WP5.2: the reclaim uses GNU `mv -T`; macOS tests cover it only through a shim, so unify on a portable `[ ! -e "$reclaim" ] && mv` form when the three lock copies merge.
- **2026-09-30** WP3.3 landed (ce1b719, e7944e0, ba21e14): deny lists are arrays (no CWD glob expansion), extra patterns are records, `find` prune predicate generated once, a bad explicit exclude file aborts `dx-backup` before any guest call. Selector 70 → 77 cases, backup 47 → 50. Correction to Fable B5/Astra F6: both runtime adapters already carried patterns as separate argv; the join was inside `dx_pbs_list_driver` only.
- **2026-09-30** WP3.4 landed (addcb12, de9fefe): tunnel identity read from `~/.local/state/dxe/<container>/host-identity`, fails closed, zero dials on the tunnel path; `dx_profile_state_segment` shared by tunnels, backups and known-hosts; the adapter suite now isolates HOME (it had started writing real state). Accepted limitation to record: the daemon-id cache is scoped by container name only; every lifecycle preflight (`dx_runtime_docker_available`) still dials live and rewrites it, so only the tunnel path reads it without dialling, which is the intended fail-closed behaviour.
- **2026-09-30** WP1.1 landed: `tests/lib/harness.sh` (results file, `expect_*`, `skip --class`, `finish`), `test_helpers.sh` shims, suites 34 (harness) and 35 (coverage metric) registered in all runners. Verified serially: sections 34, 35, 9, 21, 3, 17, 10, 20, 19, 0, 13, 22, 33, 28, 29 + contracts + Bash 3.2. Two section 22 and one section 21 wall-clock cases fail on this host with and without the change (A/B tested): the host carries a load average near 370 from 59 long-running `agy` processes outside this work, so timing assertions here are not trustworthy (Fable D10); CI is the arbiter for them. `scope_exec_lines_floor` still 0: local kcov run next.
- **2026-09-30** First local kcov run (Apple runtime provider, image builds and runs): the isolated image had no `jq`, so section 17 failed 5 cases under coverage once WP3.1 made `dx_ai_setup_credentials` fail closed on an unparseable file (the old code silently emptied `settings.json` when `jq` was absent). `jq` added to `tests/coverage/Dockerfile`; rerun pending for the metric floor.
- **2026-09-30** WP4.1 landed (33 commits, through 32dc43d): every `bin/dx*` entrypoint has `<name>_main` and the `BASH_SOURCE` guard; the contract in `test_refactor_contracts.sh` sources each one from a scratch copy of `bin/` under fakes and a watchdog. Exclusions unchanged until measured; the agent found the probe must not source the real tree (`dx-create-keys` would write a real keypair into the checkout).
- **2026-09-30** WP4.3 landed (2f734a7, c6572ae, 4193b52, dc8ff21, b6ddceb): unknown fields rejected; `DX_BOOTSTRAP_SOURCE` default independent of field order; runtime × storage matrix (`apple:apple-image`, `docker-ssh:direct-volume` only) and pairwise-distinct volume roles enforced at resolution; one `DXE_CONFIG_REGISTRY` table backs the config API; `docs/gen-config-table.sh` generates the defaults table checked by section 10. The matrix exposed 17 adapter-suite fixtures that omitted the storage mode (fixed); all real QNAP profiles already set it.
- **2026-09-30** Second local kcov run: section 17 green with `jq`; the run then failed in `test_sourceable_coverage.sh` (~line 1923) because its probe of the dead `setup_nix_volume_impl` now hits WP3.2's real mount check inside the container. Deletion of the dead functions and their nine probes (Fable B6.7 / D8, WP8.1) pulled forward as its own task; coverage floor still unmeasured.
- **2026-09-30** WP6.1/WP6.2 landed (fc29467, d94da3d, 321c4db, 1faf347): the selector checks every find/git/stat/hash result, names each failing path, and exits non-zero; the standalone entrypoint has errexit; reachability is `git rev-list --all --not --remotes` (HEAD, stash and tags included; policy documented in the module: stash is at-risk, a local tag on a pushed commit is not, a query failure retains the whole repo and reports failure). Selector 77 → 94 cases, backup 50 → 53. Correction to Astra F1: `bin/dx-backup` already aborted on a failed listing (plain statement under errexit); the host test landed as a regression guard only.
- **2026-09-30** Dead `setup_nix_volume{,_impl}` and their nine coverage-only probes deleted (11f5480, WP8.1 item pulled forward); stale comment in `system.sh` updated.
- **2026-09-30** WP1.8 landed (a201a80): contract against column-0 coreutil overrides never unset, self-proven on fixtures. Correction to Fable D6: section 17's `mv()` was already unset (line 848 at the review commit); the one real offender was `test_refactor_contracts.sh`'s own `container()` fake. The `mv` shadow window was narrowed anyway.
- **2026-09-30** Third local kcov run failed in `test_refactor_contracts.sh`: every WP4.1 entrypoint probe fails under kcov because kcov's PS4 trace expands `${BASH_SOURCE}`, which is unset inside a `bash -c` program, so `set -u` aborts the nested probe before it sources anything (`_: line 1: BASH_SOURCE: unbound variable`). Reproduced in the image with and without kcov. Fix in progress: run nested probes from a file. Also found: the F6 self-test in the same file passed vacuously under kcov for the same reason (any crash satisfies "non-zero exit").
- **2026-09-30** WP1.2/WP1.3 landed (ad7fea8, ca1681f): `with_fake_runtime`, `fake_fail_nth`, `fake_respond`, `expect_transcript`; fakes use `#!/usr/bin/env bash`; the ssh argv log appends; `with_fixture` (exports `DXE_FIXTURE_DIR`, redirects HOME/XDG_STATE_HOME/TMPDIR, sweeps `DXE_CONFIG_*`); `finish` diffs real state, exits 3 on zero cases, refuses all-skip runs without `# skip-ok:`. `requires_container` keeps its AND semantics (OR would break section 20's own contract); the twelve hand-written SKIP_INTEGRATION checks stay for WP1.4.
- **2026-09-30** Entrypoint and F6 probes now run from files (kcov PS4/BASH_SOURCE); F6 additionally asserts the `1 failed` summary so a crash cannot satisfy it. Verified green under kcov in the image.
- **2026-09-30** Fourth local kcov run: contracts and sections 3/22 green under kcov; `test_persist_backup_select.sh` failed WP6.1's chmod-000 case because the image runs as root (Astra F1 warned about this). Fix in progress: drop privileges with `setpriv` when root, classed skip otherwise.
- **2026-09-30** Permission-denied case drops to uid 65534 via `setpriv` when root (classed skip without it); verified 94/94 as root under kcov in the image.
- **2026-09-30** WP4.2 landed (7 commits through 41822f3): `dx_wait_until` with `DX_SLEEP`; `container_wait_stopped`, `dx_bootstrap_confirm_publication`, `dx_lock_acquire`, both `dx-sync-bootstrap` loops migrated (the 30-iteration loop now honours `DX_BOOTSTRAP_WAIT_TIMEOUT`); `dx-wait-ssh` keeps its wall-clock loop by design and only takes the `DX_SLEEP` seam; the launcher grace loop is guest heredoc text (WP5.2). Suite 36 (`test_host_util.sh`) registered in all runners. Two small documented behaviour refinements in `dx_lock_acquire` (identity check up front; no double timeout message on symlink refusal).
- **2026-09-30** WP6.3 landed (945d15d, c1b0feb): restore directory selection joins paths as data through one `dx_backup_restore_list_prefixed`; tab/newline names rejected explicitly; overlapping selections de-duplicated. `DXE_SKIP_SLOW_TESTS=1` skips the two 60,000-target cases honestly (CI still runs them). Restore suite 45 → 48 (+2 skips under the flag).
- **2026-09-30** User decisions: (1) remove gemini-cli from `aiPackages`, `DX_AI_TOOLS` and the `dx-herdr` message (queued behind WP7.3/7.4, which owns `flake.nix`); (2) coverage floor from the local run; (3) push now and at each work-package boundary (pushed at e59346e); (5) WP6.2 retention policy kept; (6) WP4.3 matrix kept strict. Coverage cases for the registry heredoc (5b79360), the selector/lock branches (33a3ec6, c39da97) and the section 19 fixture (e59346e) landed; bootstrap storage happy paths (agent B2) pending, then re-measure and set the floor.
- **2026-09-30** Host load diagnosis: the 59 `agy` processes are tmux sessions `antigravity_scrape_<id>` created by `agent-stats` (`usage` alias → `run-stats.sh` → `bin/run-stats-rust`, cwd `agent-stats/rust`), one per `usage` run since 26 Sep, never killed. The Python scraper has `finally: kill_session()`; the Rust port evidently does not. Not this repository's bug; reported to the user.
- **2026-09-30** Host shutdown imminent: all in-flight agents told to commit WIP in their worktrees. Resume checklist: `git worktree list` for unmerged agent branches (WP7.3/7.4 Nix, WP8.3 adapter split, WP5.1 sync result file, WP6.7/6.8 healthcheck, WP1.6 helper purity, WP6.9 restore batching, B2 bootstrap coverage); cherry-pick each onto the branch; run the kcov gate via the Apple runtime on a fresh snapshot; set `scope_exec_lines_floor`; then gemini removal, WP1.4/1.7, WP5.2, WP6.4-6.6, WP7.5-7.8, WP8.1/8.2/8.4, WP9.
- **2026-09-30** WP7.3/WP7.4 landed (f11664c): `guest-tools.nix` mapping drives `dxPackages`, `checks.inventory`/`inventory-list`/`{bash,fish,nushell}-integration` (built for aarch64 in the container), typed starship/direnv/yazi/lazygit, `home.sessionPath`; duplicates removed. Open: section 14 case "test runner help advertises current section range" fails (expects the old `0-27` literal; help now says `0-36`; fix under WP1.4). Bootstrap coverage cases (B2) and WP5.1: designs only, saved in `docs/evidence/20260930/agent-design-notes.md` and the WP5.1 note; the fstab-append-as-root hazard is recorded there.
- **2026-09-30** WP1.6 partial (worktree `agent-a4bd6f9b4c5723dcf`, WIP commit 502a434, NOT cherry-picked: it leaves the contract red by design). Finding: `test_refactor_contracts.sh` sources each library inside `$(source …)`, a subshell, so its `$-`/IFS/PWD/umask/traps checks have never been able to observe a violation; only output/stderr/status cross the boundary. Resume: rewrite the purity probe as a file run via `bash probe` (kcov-safe) capturing before/after state in-process; then Green (a)-(e): drop `set -uo pipefail` from `test_helpers.sh` (all suites set their own), rename its `SCRIPT_DIR` to `DXE_TESTS_DIR`, `dx_test_guest_dir`, stop sourcing `dx-host-util.sh` there (seven suites need one `source` line: bootstrap_publication, section18, section23, section3, host_util, runtime_boundary_characterisation, section19), and a lazy `dxe_require_tmux_probes` for sections 6 and 14 (section 6 calls a tmux probe at unit tier with a fake, so `requires_container` gating would be wrong).
- **2026-09-30** WP8.3 steps 1-2 landed (transcript fixture `tests/fixtures/docker-adapter-transcript.txt` + `dx_runtime_docker_cli` collapsing 27 passthroughs; section 33: 181; the daemon-id cache write-failure branch now has a case). Resume at step 3 (split behind the facade; the boundary audit's adapter allow-list at `test_runtime_boundary_audit.sh` ~line 65 must learn the new files, which that task was told not to edit: lift that restriction), then steps 5 (`dx_tunnel_cli`) and 6 (comment history to decisions).
- **2026-09-30** WP6.9: design only (agent ran out of time); full plan with expected call counts in `docs/evidence/20260930/agent-design-notes.md`. Also found: `bin/dx-restore` currently pushes `identical` targets too.
- **2026-09-30** First CI run on the branch (36613061827, at e59346e): macOS Bash 3.2 job green; Linux job failed at ShellCheck (later steps skipped): `tests/test_persist_backup_select.sh` SC2218 (function used before its definition, many hits: the WP6.1 shadow functions), `tests/test_section3_bootstrap.sh` SC2128 (array expanded without index, ~18 hits, WP3.2/WP4.4 cases) and one SC1090. Fix these first next session, then re-check the later CI steps (contracts, coverage, Nix).
- **2026-09-30** WP6.7/WP6.8 landed (eff33a0): fixed probe program from `dx_bootstrap_health_command`, path via `--env` as data, full lease identity (generation, boot id, pid, start) plus a readiness marker `.locks/ready/<pid>.<start>` written by `bootstrap_main` after the phases. Section 22: 43. Follow-ups: section 9/33 cases for the two new helpers (bin/lib is in the kcov gate), register `dx_bootstrap_publish_ready_marker` in section 3's function list, a lifecycle.md paragraph on readiness semantics, and the `process_start` text is now in two heredocs (WP5.2 unifies).
- **2026-09-30 (resumed)** Local ShellCheck through the container runtime reproduces CI's 98 findings exactly; fan-out: ShellCheck fixes + P13 bootstrap coverage cases, gemini-cli removal, WP6.9 and WP5.1 from their saved designs, WP8.3 steps 3/5/6.
- **2026-09-30** WP9.2/9.3/9.6 landed (267dcc0, d9a0b31, 59dbb4a): `docs/README.md` map (section 10 requires every operating doc linked), both ShellCheck 0.11 crash sites named with a revisit trigger, section 0 `--strict`/`DXE_LINT_STRICT=1`, tier split stated once in `validation-matrix.md`, four backlog probes promoted into `plans.md` with owner and trigger.
- **2026-09-30** gemini-cli removed (eb38a47): out of `aiPackages`, `DX_AI_TOOLS`, the shell alias, `dx-herdr` message and `docs/guest.md`; the WP2.2 removal-notice acknowledgement deleted; `DX_AI_LEGACY_TOOLS` and `~/.gemini` persistence kept (the latter is agy's state dir). Flake check: all checks passed, zero warnings. Note: a subagent ran live-tier cases against `localhost:2222` (your running `dx-host`); auth failed, nothing changed; agents stay on `--skip-integration`.
- **2026-09-30** ShellCheck fixes (3526aa1) and the six P13 bootstrap coverage cases (8fbf24f, section 3: 205 → 219) landed; CI's ShellCheck is clean over the whole branch locally. Case (e) still touches the real `/etc/fstab` path (permission-denied here, real append as root in the image, restored from a snapshot); the seam is a follow-up.
- **2026-09-30** Sixth local kcov run on 8fbf24f: **100% line coverage of the scope**, every suite green in the image; the metric fired on the ceiling (exempt executable lines 3028 → 3173) because WP4.1's guards and WP6.7's marker lines are exempt-file code. Ceiling re-based to 3173 with the reason in `ratchet.env`; floor set to 3306. WP1.5 complete.
- **2026-09-30** CI run 36640705743 (18f5cdd): ShellCheck green on CI; the container-free step fails in five suites that pass on the Mac: section 16 (registry text assertion broken by the heredoc table), 31 (create argv golden lacks WP6.7's `--env DX_BOOTSTRAP_PATH`), 14 (stale `0-27` help literal), 33 (WP1.2 appended bash's real bin dir to the restricted fake remote PATH; on GitHub runners that is /usr/bin, which has docker), 20 (consequences of 16 and an unexplained section 17 exit 1 on Linux). Fixes in flight; Linux reproduction available via the kcov image.
- **2026-09-30** WP6.9 landed (ce63dc7, 0053d94, 324fbaf): restore push is bounded (2,000-file fixture: 2,005 → 8 runtime calls; ≤10 asserted), one awk ancestor pass, shipped lists over the existing threshold, one `chown -h` batch, `identical` targets no longer pushed, `dx_backup_ship_list` shared with the status pass. Restore suite 48 → 59.
- **2026-09-30** WP5.1 landed (53c4716, 8315ff8): `bin/lib/dx-bootstrap-sync.sh` (`dx_bootstrap_sync` 0/3/1, result file `outcome=`/`generation=` written tmp+mv and read by a bounded reader), `dx-sync-bootstrap --result-file`, `dx-start-container` fails loudly on a missing/malformed result; the prose parser is deleted. Section 22: 43 → 51, section 9: 138 → 148. Follow-up: `test_refactor_contracts.sh` still asserts the literal `cat >/dev/null` in `bin/dx-sync-bootstrap` (now satisfied by a comment); point it at the library when that file is next touched (WP1.6).
- **2026-09-30** WP8.3 complete (5142cd8, 5822504, de626d8, 6892495): adapter split into transport/identity/lifecycle/lock behind the facade (59 functions accounted for once; transcript fixture byte-identical); boundary audit exempts `dx-runtime-docker-*.sh` with a self-proof; `dx-forward`/`dx-reverse` are 6-line entrypoints over `dx_tunnel_cli` (10 pinned parsing cases); narrative comments moved to `docs/refactor/decisions/D8-docker-adapter-history.md`; the hand-rolled ssh fake no longer appends the real bin dir. Step 4 (claims to `dx-claims.sh`) deferred to WP8.1/8.2 territory. Incident: the agent ran the real `bin/dx-forward --stop-all` while capturing baselines and stopped a live tunnel on port 8420; briefs now forbid running `bin/dx*` against real state.
- **2026-09-30** CI Linux fixes landed (ba16605, d6aa174, cf426f1, d5ecd15) and confirmed in the image: sections 16, 20, 31, 33, 17 green on Linux; only section 14's stale help literal remains (WP7 agent has it). Root cause behind the section 17/20 mystery: `harness.sh` exports `DXE_TEST_RESULTS`, so a suite that runs other suites as child processes (section 20) shared one results file that each child then deleted; section 20 now blanks it per child, and the harness itself should mint a fresh file when a new top-level process inherits one (routed to WP1.7).
- **2026-09-30** WP1.7 landed (6d05c4e, 1eb7f3b, d4b7375, 2358cad, d47aae8): harness `wait_until`/`wait_for_pid_exit`; `DXE_TEST_RESULTS_OWNER` makes nested suite processes mint their own results file (section 20's workaround now redundant); section 22 has zero bare sleeps and its two elapsed-seconds cases assert through the `DX_SLEEP` transcript; a contract forbids bare `sleep N` in `# tier: unit` files plus the de-flaked list. Remaining bare-sleep inventory for WP1.4: sections 11, 14, 16, 17, 23 (13 hits), 27, sourceable coverage.
- **2026-09-30** WP8.1 Phases 0-2 and Contract 5 landed (a1f9b2b, 96ce338, c4a2d87, deabddd, 327f6bb): identity, publication decision, default-profile target and the Nix-volume state are threaded positionally or through four bounded scratch records under `DX_BOOTSTRAP_SCRATCH_DIR` (default `/run/dx-bootstrap`); eleven exported globals removed; the clean-skip-writes-no-marker gate is mode-aware. Section 3: 219 → 241. Deviation recorded in `refactor-v2-final.md`: sibling phases bridge through the scratch dir because `bootstrap_phases` must call phases uncaptured (WP4.4 test). Phase 3 is host-side (claims) and Phase 4 (file split) remain. Live-tier validation on `dx-test` is required before promotion: this changes bootstrap's runtime data flow.
- **2026-09-30** WP9.5 landed (eab62eb) and the EPIPE-drain contract now points at `dx-bootstrap-sync.sh` (0d94864).
- **2026-09-30** WP7.5-7.8 landed (c6c7ebb, 8e7261f, 8e8f0b3, aa2e9b1) plus the section 14 help-range fix (5b636d7): hermetic `writeShellApplication` wrappers for installed guest commands with `checks.scripts-hermetic`; `checks.agy-pin-shape` replaces the literal aarch64 pin assertions (the custom `unpackPhase` stays: the fetchurl name has no `.tar.gz` suffix on purpose); typed NixVim modules with `checks.nvim`; `allowUnfreePredicate` naming exactly claude-code and antigravity-cli. Real builds green on aarch64, eval green on both systems, zero warnings. WP7 complete.
- **2026-09-30** Seventh local kcov run (snapshot 327f6bb): suites green except two WP8.1 probes in `test_sourceable_coverage.sh` (:247, :1916); line coverage 95.6%: `dx-bootstrap-sync.sh` 29% and `dx-tunnel.sh` 87% despite sections 22/19 driving their entrypoints (suspect fixture copies of `bin/` outside kcov's include path), plus 8 lines in `common.sh`, 2 in `base-and-storage.sh`, 2 in `dx-backup.sh`. Coverage agent diagnosing with per-line reports in the image.
- **2026-09-30** WP6.6 landed (ddb574b, 785ad5d, 9832b25, 51a643e, ff4d2a0): backups publish as generations under `generations/<id>/` with hard-link carry-forward, a `current` symlink switched atomically after per-file hash verification, a per-mirror lock shared with restore, prune to two generations, and automatic in-place migration of a legacy mirror (real `current/` dir) on the first run. Backup suite 53 → 101, restore 59 → 64. Note for the live tier: `dx-host`'s existing mirror is legacy-shaped and will migrate on its first backup after promotion; verify on `dx-test` first.
- **2026-09-30** CI at 2d3a4fc: Syntax, ShellCheck and the container-free contracts step all green on Linux; the job now fails only at sourceable coverage (the gaps under repair), Nix evaluation not yet reached.
- **2026-09-30** WP6.4 landed (d211eb8, 7cda2f7, dfa5864): `dx_runtime_docker_resource_owned` before adoption, writable attachment, start, stop, kill and delete; schema and `io.dxe.system` validated; absent vs could-not-inspect distinct and fail-closed; Apple counterparts are documented no-ops (no per-object labels). Section 33: 181 → 196, section 9: 159. Transcript fixture gained three inspect lines. Live-only assumption recorded: Docker's exact "No such container/volume" wording.
- **2026-09-30** WP8.2 landed (2cd212b, 9f421f7, 4cc5dcf, c156c0f): `dx-ai.sh` split into `scripts/lib/dx-ai-{loader,generation,pin,cache-policy,post-install}.sh`; `dx_persist_relocate_dir` shared by gh/Herdr/OpenCode/AI-credential sites (fixes the nested `~/.claude/.claude` symlink); `run_as_dx_argv` with argv-form sites migrated; `dx_keyring_start` no longer claims "started" on failure; `NU_PATH` local. Section 17: 117 → 123, section 3: 245. Follow-up: the new `scripts/lib` files must be installed by Home Manager (`home/tools.nix`), not only via the bootstrap-volume fallback. Coverage fixes (70df1e4..75d263c) also landed; the coverage agent found kcov on this aarch64 VM does not count lines in forked child bash processes, which explains the sync/tunnel undercount; CI (x86_64) is the arbiter for those two files.
- **2026-09-30** Eighth local kcov run (snapshot 412550c, before WP8.2): all earlier gaps addressed; the run fails only in `test_dx_backup.sh` under Linux-as-root: a read-only-parent fixture root can write to, and a legacy generation id derived from an mtime that the test and the code compute differently on GNU `stat` (4 cases). Fix in flight, plus Home Manager wiring for the seven new `scripts/lib` files with a `guest-libs-installed` check.
- **2026-09-30** WP6.6 Linux fixture fixes landed (617e1c0: regular-file parent instead of a read-only dir; legacy id derived through `dx_pbs_stat_mtime` on both sides — the test's `stat -f %m || stat -c %Y` order dumped GNU filesystem info into the capture). Ninth kcov run then stopped in `test_sourceable_coverage.sh` (~774): WP8.2 routed `setup_gh_persistence` through `run_as_dx_argv`/`setpriv`, which the probe never stubbed; fix in flight. No coverage numbers from run 9.
- **2026-09-30** WP6.5 landed (c9a7899, 43ba0ab, 2ba5775): `dx_lifecycle_lock_acquire`/`_release` through neutral `dx_runtime_lock_*` dispatch; owner token `DXE_LIFECYCLE_LOCK_OWNER` inherited by children (one acquire/release per orchestration; `dx`/`dx-recreate` release before their final `exec`); Docker uses the lock-container protocol and reports owner + remedy on refusal; Apple a local mkdir lock under the profile state dir; first-run image guard precedes the lock; Nix-volume claims scoped by daemon identity. Section 33: 196 → 208, section 9: 164. `dx-lock --acquire` deferred (boundary-audit allow-list). Live-only: a real racing-controller gate. WP6 complete.
- **2026-09-30** Home Manager now installs every `scripts/lib/*.sh` (except the backup selector, which ships via the bootstrap volume) through one `readDir`-driven table, with `checks.guest-libs-installed` (a771ca6). Found: section 6 has seven `dx-ai.sh` text assertions broken by the WP8.2 split (its agent never ran section 6); fix in flight. Lesson: every guest-script change must run sections 6 and 17.
- **2026-09-30** Full container-free suite on a snapshot of c0a087c (host quiet, `DXE_SKIP_SLOW_TESTS=1`): 35 suites, 2,059 passed, 7 failed — all the known section 6 text assertions from the WP8.2 split. No other cross-package regression.
- **2026-09-30** WP1.6 landed (34838b5, 852c54c, 512076b, 5e039e8): the import-purity contract runs a real-subprocess probe file (proven on an impure fixture) and covers `tests/lib/*.sh` + `test_helpers.sh`; the helper no longer sets shell flags, clobbers `SCRIPT_DIR`, or sources production code (`dx_test_guest_dir`, `dxe_require_tmux_probes`); eight suites source `dx-host-util.sh` explicitly (section 9 needed it too for WP6.5's Apple lock cases). Section 6's seven dx-ai cases are behavioural again (7ec9d39): 118 passed.
- **2026-09-30** Sourceable-coverage probes re-pointed for WP8.2 (b970516): every site that now goes through `run_as_dx_argv` has a matching stub; the driver reaches its final line in the image with zero trap firings. Tenth gate run in progress on that snapshot.
- **2026-09-30** Full container-free suite on a snapshot of 7b79ed1: 35 suites, 2,066 passed, 0 failed, exit 0 (the first fully green full run on the branch; baseline on 2026-09-29 was 33 suites with 3 failing).
- **2026-09-30** Tenth gate run (snapshot f74863e): every suite passes under kcov; line coverage 95.4% with small gaps in 15 files (WP5.1/6.4/6.5/6.6/8.2 additions) plus `dx-bootstrap-sync.sh` at 31% (the guest program is a multi-line string, so kcov counts its lines as executable but bash never traces them; convert it to a quoted heredoc like the launcher's). Guest-side gaps assigned; host-side gaps queued behind WP8.4a (adapter suite ownership).
- **2026-09-30** CI at 7b79ed1: container-free step fails only in section 24 (`test_herdr_config_persistence.sh`, eight Herdr cases) on the Linux runner; the suite passes on macOS and is outside the kcov subset. Same WP8.2 class: fixtures shim `run_as_dx` but the publish now goes through `run_as_dx_argv`/`setpriv`. Fix in flight; also running the whole container-free suite inside the Linux image to catch anything else the kcov subset misses.
- **2026-09-30** Whole container-free suite inside the Linux image (snapshot 2bf945d): 35 suites, 2,155 passed, 10 failed = section 24's eight (fix in flight) + two section 6 `git ls-files` cases that cannot see a worktree's gitdir from the container (they pass on CI's real checkout). Nothing else Linux-only.
- **2026-09-30** Section 24 fixed for Linux (030b9bb): fixtures shim `run_as_dx_argv` too; on macOS the whole guest body is skipped (`uname` guard), which is why only CI saw it. Linux: 47 passed.
- **2026-09-30** WP8.4a landed (012c39b, 18022a6): the adapter suite is five standalone parts (transport 51, identity 42, lifecycle 44, lock 22, health 49) behind the one registered aggregate (208, labels identical); four Fable D7 source-text checks converted (dx-wait-ssh logs, dx-herdr guest command, dx-ai call shape, sshd_config rendered and validated with `sshd -T`, duplicate in section 13 removed). Left: WP8.4b (gather remaining source-text contracts, migrate sourceable-coverage probes to owning suites).
- **2026-09-30** CI at 030b9bb (run 36660473350): Linux container-free step green for the first time; the job stops at sourceable coverage with a per-file list identical to local run 10 (95.40%, same 17 files, same counts), so the local gate through the Apple runtime reproduces CI exactly, including `dx-bootstrap-sync.sh` at 30.67% (the string-literal guest program, not a fork-tracing artefact).
- **2026-09-30** Guest coverage gaps closed (fec3d57, 8008ecf, a0eea2d, 82c705e): section 17 → 137, section 3 → 256, section 23 → 35, one more `KCOV_LOOP_TERMINATOR`. Six lines remain that kcov structurally cannot mark (empty `pattern) ;;` arms ×3, a `{ … } > file` group's braces ×2, a backslash-continued module-level call); being rewritten to carry real commands rather than adding a marker. Section 16's stale-workspace scan needs the adapter part files exempted (in the same task).
