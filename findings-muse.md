# Repository review: refactoring and improvement opportunities (Muse)

Reviewed on 2026-09-29 at commit `4e8c5cc` (`main`), branch `main`, clean tree except untracked `findings-astra.md`.
Scope: host orchestration (`bin/`, `bin/lib/`), guest (`container/aarch64-darwin-apple-container-dx-nixos-26.05/`), tests (`tests/`), CI (`.github/workflows/ci.yml`), docs (`docs/`, root `*.md`).
Method: static reading + `wc -l` sizing + `git log` history; no live container, no Nix build, no ShellCheck/kcov run. Complements `findings-astra.md` (which covers correctness defects F1–F11); this note focuses on structure, duplication, and maintainability. Where they overlap I cite the Astra ID instead of repeating the proof.

## Assessment

Preserve the current boundaries: thin `bin/dx-*` entrypoints over sourceable `bin/lib/`, runtime dispatcher (`dx-runtime.sh`) with Apple/Docker adapters, data-only config profiles, immutable bootstrap generations, tiered tests with fake boundaries, and the single-line `Containerfile`. Those are the reason the repo survived Branches 1–18 and QNAP Phases 0–7 without a rewrite.

The cheapest high-leverage work is not a new feature:

1. Split the two god-files (`bin/lib/dx-runtime-docker.sh` 1109 lines, `container/.../bootstrap/base-and-storage.sh` 1004 lines) along seams the code already hints at.
2. Fix the coverage scope-share metric that punishes adding tests (`tests/coverage/ratchet.env` 1313 lines, 1312 comments).
3. Unify test registration (four runners with hand-maintained lists, already drifted) and split the 2916-line Docker adapter test.
4. Retire or park the plan sprawl (`plans.md` + 5 root plan docs + `docs/refactor/` + `docs/evidence/`) now that consolidation Branches 1–17 are done.
5. Rename or alias the arch-specific container path, now that the flake is arch-neutral.

No wholesale rewrite, no shell replacement, no broad Nix migration until 1–4 land. `refactor-v2-final.md` and `declarative-nix-plan-a.md` are correctly parked behind Branch 12 / Q7; do them as small increments per `checkout-consolidation-plan.md` Branch 13, not as phase stacks.

## Strengths to keep

- `bin/dx` (24 lines) is a linear idempotent orchestrator; every lifecycle script is idempotent toward its end state (`README.md:21-27`, `docs/lifecycle.md`).
- `bin/dx-lib.sh` (25 lines) is facade-only with fixed source order and `# shellcheck source=` annotations.
- `bin/lib/dx-runtime.sh` (236 lines) is dispatcher-only; all 30 ops are one-line `dx_runtime_dispatch` passthroughs.
- `Containerfile` is 1 line (`FROM nixos/nix:2.34.7@sha256:bf1d...`); all tooling is guest-side Nix (`flake.nix:60-95`, `bootstrapEssentials:106-121`).
- `bootstrap.sh` (49 lines) is an ordered phase list; each phase lives in its own `bootstrap/*.sh` module.
- Config profiles are bounded `NAME=value` data, never sourced (`bin/lib/dx-config.sh:66-172`, `docs/configuration.md`); `dx-profile` sources only `dx-config.sh`.
- Tests prove `--skip-integration` truthfulness, SIGPIPE-under-pipefail handling, and import purity (`test_section20_skip_integration.sh`, `test_refactor_contracts.sh`).
- Migration gates require observation, not elapsed time (`docs/refactor/migration-gates.md`).

## Findings

### A. Host layer (`bin/`, `bin/lib/` — 3986 + 2287 lines)

**A1. Two fat entrypoints break the thin-wrapper rule.**
`bin/dx-mount` (245 lines), `bin/dx-sync-bootstrap` (208 lines), `bin/dx-status` (176 lines) are 7–10× the median entrypoint (`bin/dx-stop-container` 8 lines, `dx-create-keys` 13 lines). `dx-mount` embeds its own `fail()` at `:26` (vs `return` in `dx-forward:15`/`dx-reverse:15`), manifest parsing, and lifecycle calls. Extract a `dx-mount-plan.sh` consumer + `dx-status` probe helpers into `bin/lib/` so entrypoints stay orchestration-only per `docs/lifecycle.md`'s "wrappers-only-orchestrate" principle.

**A2. Docker adapter is a god-file; Apple adapter is a passthrough.**
`dx-runtime-docker.sh` is 1109 lines / 55 funcs (transport + discovery + identity/ownership + lifecycle + locks + health). `dx-runtime-apple.sh` is 271 lines / 28 funcs, mostly one-line `container ...` passthroughs. Natural seams already exist: `quote_argv:50-58` + `ssh_option_argv:65-70` + `ssh_raw/exec:80-96` (transport), existence/label checks at `440-449` + `664-675` (identity), `608-624` (lifecycle), `1025` (lock). Keep one `dx_runtime_docker_*` facade; move each seam to its own file. See also Astra R3.

**A3. Boilerplate ×34 with no helper.**
Every executable repeats `SCRIPT_DIR=...BASH_SOURCE` + `source dx-lib.sh` (`dx-enter:4-5`, `dx-stop-container:4-5`, etc.). Only `dx-profile:5-8` diverges (sources `dx-config.sh` alone). A single `bin/lib/dx-entry.sh` preamble or a checked generator would remove ~70 lines of copy-paste and one drift vector.

**A4. Preflight and state-setup duplication.**
`container_exists/is_running` preflights repeat in `dx-sync-bootstrap:8-10`, `dx-wait-ssh:71,80`, `dx-status:48-68,134-146`, `dx-tunnel.sh:207-208`. `KnownHosts/prepare_state` symlink + `dx_path_uid` + `0700` repeats in `dx-ssh-common.sh:41-49` vs `dx-tunnel.sh:46-60`. `COPYFILE_DISABLE=1 tar --exclude '._*'` repeats in `dx-backup.sh:272,506` + `dx-put`. The SSH-opts idiom `opts_stream=$(dx_ssh_common_options)||return` + `while read <<<"$opts_stream"` is copied 4× (`dx-ssh-common.sh:60-66,184-191,279-282`, `dx-tunnel.sh:111-120`). Extract one `dx_require_running_container`, one `dx_prepare_state_dir`, one `dx_tar_create` helper.

**A5. Inconsistent error surface.**
`set -euo pipefail` is correctly on line 2 of all 35 executables and off in libraries (intentional sourceable design). But failure reporting mixes `|| { echo "Error: ..." >&2; return 1/exit 1; }`, bare `fail()`, and `dx_ssh_common_options||return` without message. No shared `dx_die`/`dx_warn` with exit-code contract. Pipefail pitfalls are annotated ad hoc (`dx-container.sh:58-61`, `dx-runtime-apple.sh:49-52` explain why `grep -F -x >/dev/null` not `-q`). Centralize one die/warn helper; keep the existing comments that explain *why* a construct is pipefail-safe.

**A6. Bash 3.2 shims are scattered.**
`" years of "${arr[@]+...}"` idiom (`dx-runtime-apple.sh:159-168`), `cut`-not-`awk` (`dx-persist-backup-select.sh:145-188`), `:`-vs-`;;` kcov concessions (`dx-config.sh:84`, `dx-backup.sh:486`), single-line `awk/sh -c` for attribution (`dx-backup.sh:146-151,458-461,493-496`). Document the allowed shim set once (as `refactor-v2-final.md:46-51` already scopes: no `declare -A`/namerefs/`mapfile`/`local var=$(...)` in `bin/` only) and lint for violations instead of re-discovering them per file.

### B. Guest layer (`container/...` — 5389 shell + 259-line flake)

**B1. `base-and-storage.sh` (1004 lines) couples five responsibilities.**
Staging, copy/verify, identity, GC roots, markers, and volume lifecycle share five exported globals (`DX_NIX_VOLUME_*`) plus `DX_NIX_PENDING_IMAGE_STORE_IDENTITY` with three encoded roles (value + "pending" + "complete"; see `refactor-v2-final.md:55-80`). `refactor-v2-final.md` Phases 1–2 already specify the fix (thread identity + publication decision + profile target positionally; mode-tagged non-sourceable volume record). Endorse that plan; do not invent a new one. Gate on its "verified clean skip writes no marker" test.

**B2. Marker protocol is re-implemented per volume.**
`dx_validate_atomic_marker_path:15-22` + `dx_publish_atomic_marker:28-37` in `bootstrap/common.sh` are correct, but each volume (`.dx-owner-layout-v1`, `.dx-durable-identity-v1`, `.dx-image-store-identity`, `.dx-image-identity-v1`, herdr `.dxe-persistence-ready`) re-does temp-file + validate + rename + chown. `refactor-v2-final.md` Phase 5 proposes a typed dispatcher (type → validator internally, never type + validator as independent args). Adopt it; a helper that lets one marker be published as another is a data-loss bug, not style.

**B3. Deny-list defined once, expanded 4× by hand.**
`DX_PBS_BUILTIN_COMPONENT_DENY:46` + `BUILTIN_PATH_DENY:54` in `dx-persist-backup-select.sh` are re-expanded as literal `find -name` clauses at `228-234,237-244,434-439,442-448`. Generate traversal predicates from the same array the matcher uses. Same for `PATH`-vs-`find` drift between host `dx-backup.sh` and guest selector (Astra F6 shows the `$*` word-splitting half of this).

**B4. Inventory lists hand-synced.**
`flake.nix:60-95` (`dxPackages`) vs `dx-verify-inventory.sh:21` (`DX_REQUIRED_INVENTORY`) vs `bootstrapEssentials:106-121` vs `DX_AI_TOOLS:7` in `dx-ai.sh` carry "keep in sync by hand" comments. `test_refactor_contracts.sh` already checks both directions for `bootstrapEssentials` and `DX_AI_TOOLS` vs `aiPackages` — extend that contract to the inventory list or generate the inventory from the flake.

**B5. Arch-specific path for arch-neutral content.**
`container/aarch64-darwin-apple-container-dx-nixos-26.05/` still names Apple-silicon despite `flake.nix:37-38` supporting `aarch64-linux` + `x86_64-linux` and QNAP Phase 4 proving native x86_64 boots. Rename to `container/dx-nixos-26.05/` (or add a symlink + deprecation shim) before more docs/CI hardcode the old path. CI's `nix flake check` path arg, `dx-backup.sh:24`'s selector source line, and ~10 docs links all embed it.

**B6. `agy` pin skew undocumented.**
`pins/agy.json` pins aarch64 1.0.5 vs x86_64 1.2.12. Either unify or record why the skew is intentional; a per-arch version gap in an AI tool is a supply-chain question, not just a version number.

**B7. `dx-ai.sh` (663 lines) + `dx-theme-write-tool-themes.sh` (600 lines) are the next god-files after `base-and-storage.sh`.**
`dx-ai.sh` mixes lock/boot-id (`105-117`), process-start (`87-99`), generation GC, `--recover`, and source-miss fallback. Theme writer mixes per-tool renderers. Both are excluded from kcov (`exclusions.txt`), so they grow without a coverage backstop (see D2). Prioritize `dx-ai.sh` after B1–B2; theme writer can wait.

### C. Config (`bin/lib/dx-config.sh` — 303 lines, 40 fields)

**C1. Cross-field matrix is one check short.**
`dx_config_validate_cross_fields:157-176` checks runtime↔remote-host but not runtime↔storage-mode or volume-role distinctness. Astra F10 reproduces `docker-ssh` + `apple-image` passing validation then failing in guest bootstrap. Add the 3-row compatibility matrix (runtime × storage × arch) during resolution; fail before any runtime call. Keep `${DX_PROJECT_ROOT}`-only expansion and the hostile-input rejections — those are correct.

**C2. Defaults are documented but not generated.**
`docs/configuration.md:165` lists every default; `test_section10_docs.sh` asserts every `DXE_CONFIG_FIELDS` entry appears in docs. That test is load-bearing — keep it — but consider generating the defaults table from `dx-config.sh:23-27` to remove the second source of truth.

### D. Tests + coverage (`tests/` — 21861 lines across `test_*.sh`)

**D1. Four runners, four hand-maintained lists, already drifted.**
`run_all_tests.sh` (144 lines, `KNOWN_SECTIONS 0..33`), `run-tier.sh` (26 lines), `run-bash32-tests.sh`, `run-coverage-contracts.sh` each list sections independently. `unit/static` stops at 32 (omits 33 Docker adapter); `host-contract` runs only 9+18; help advertises 0–27 while registry extends to 33 (Astra R2 confirms). Only `test_refactor_contracts.sh:B2` pins dispatch-completeness. Fix: one declarative manifest (`name → file → tier → interpreter → runtime-reqs`); generate/select each runner's list from it; reject unknown `--section=` (already done in `run_all_tests.sh`) everywhere; add a consistency check that every suite belongs to exactly one tier.

**D2. Coverage metric punishes tests, rewards comments.**
`run-coverage-linux.sh:64-68` divides sourceable-library text lines by *all* shell text lines *including tests*. Adding tests lowers the ratio; adding comments inside covered libs raises it. `ratchet.env` says so explicitly and is now 1313 lines / 1312 comments of rebaseline history. Keep the 100% executable-line gate (kcov over `bin/lib` + `bootstrap/` + `scripts/lib`); replace the scope-share ratio with a ceiling on uncovered production lines (as `declarative-nix-plan-a.md` #12 proposes) or drop it to an informational trend. Move rebaseline history to `docs/evidence/`; keep `ratchet.env` to one number + pointer. Recorded conflict with `refactor-v2-final.md` Phase 4 gate stands — decide ordering before Branch 13 (recommendation: finish v2 Phases 1–3 on the current metric, then change the metric once).

**D3. Two test god-files.**
`test_docker_runtime_adapter.sh` (2916 lines) covers transport + identity + lifecycle + locks + health in one file. `test_sourceable_coverage.sh` (2109 lines) exceeds the module it covers; `refactor-v2-final.md` Phase 4 already plans its split (identity / import-volume / claims / helpers + one aggregate entry CI runs once). Endorse; add shared-transport contract cases run against both adapters where semantics should match, keeping runtime-specific cases separate.

**D4. Behavioral gaps behind the 100%.**
Astra F1–F9 are all cases where lines execute once but failure doesn't stop the caller (traversal errors hidden with `2>/dev/null`, `done < <(...)` swallowing exclude-reader failure, `sed` path injection, stale-lease healthcheck). Add fault-injection fixtures (permission-denied subtree, failed `find`/hash/Git, truncated archive, stale lease, metacharacter paths) before chasing more line-count. The existing `requires_container` + fake-`ssh`/`docker` harness already supports this pattern (`test_section20` proves it).

**D5. Flaky and slow probes in backlog, not in plan.**
`checkout-consolidation-plan.md:359-394` lists four real items with no branch: tmux-resurrect timing-flaky probe, missing `dx-status` keyring line (fixture answers every exec identically), O(n²) `dx-restore --dry-run` over 60k targets (13+ min), Section 27 fake-`ssh` hanging on open stdin. Each is small, specified, and testable — promote them to `plans.md` with owners or explicitly defer; a backlog section in a consolidation plan is where they go stale.

### E. CI (`.github/workflows/ci.yml` — 48 lines)

**E1. Nix evaluation omits the primary guest arch.**
`nix flake check --no-build` on x86_64 Linux without `--all-systems` prints `The check omitted these incompatible systems: aarch64-linux` and passes (Astra F11 reproduces). Add `--all-systems` + explicit `nix eval ... homeConfigurations.dx-aarch64-linux.activationPackage.drvPath` and the x86_64 counterpart, or expose those derivations via flake `checks`. Update `docs/refactor/validation-matrix.md`, which still says the flake pins one arch and all Nix builds are Mac-only.

**E2. ShellCheck pin drift.**
CI pins `nixos-25.05#shellcheck` (0.10.0; comment documents 0.11.0 crash on `x="$(source f)"`) while the guest pins `nixos-26.05`. The pinning rationale is sound; record a revisit trigger (re-test 0.11.x quarterly) so the workaround doesn't fossilize. Local dev has no ShellCheck (`test_section0` silently skips) — CI is the only lint gate; document that in `docs/troubleshooting.md` or fail loudly locally when the binary is absent and `--strict` is passed.

**E3. `bash -n` glob is correct but fragile.**
`find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \)` auto-covers new modules (good — `refactor-v2-final.md:393-395` calls this out). Keep the glob; never replace with a hardcoded list when Phase 4 splits modules.

**E4. Single-runner coverage.**
`ubuntu-24.04` + `macos-15` only; no QNAP/`docker-ssh` live, no NixOS-container coverage beyond the kcov image. That matches D3's "Apple Container needs mac virtualization" constraint — keep CI hermetic, keep live/destructive/Nix-build as manual mac-only gates, but say so in one place (`validation-matrix.md`) instead of three.

### F. Docs + plans (root `*.md` + `docs/`)

**F1. Plan sprawl after a successful consolidation.**
`plans.md` (98 lines, status checked 2026-09-26) indexes 5 root plans: `checkout-consolidation-plan.md` (630 lines, trimmed 2026-09-27, remaining = Phase 7 live steps + Branch 13), `qnap-dxe-plan.md` (Phases 0–6 landed, Phase 7 code landed, live steps pending), `store-trust-plan.md` (resolved on Branch 12, awaiting pin-bump proof), `declarative-nix-plan-a.md` (unadopted audit), `refactor-v2-final.md` (435 lines, open). Plus `docs/refactor/` (decisions D1–D7, checklists, `migration-gates.md`, `validation-matrix.md`, `baselines.md`) and dated `docs/evidence/`. Retire `checkout-consolidation-plan.md` fully once Phase 7 live steps complete; park or reject the two Branch 13 proposals per Q7 (recommendation in-plan is sound: park v2 until Branch 12 proves out, accept declarative-Nix item-by-item). Until then every root plan needs the `Revisit trigger:` `plans.md` already requires — two entries lack owners for the #12-vs-Phase-4 conflict.

**F2. `README.md` (146 lines) is at its cap.**
`test_section10_docs.sh` enforces `<250 lines` and link/docs-field coverage. README is fine at 146, but `docs/lifecycle.md` (494 lines) and the refactor/evidence tree are where newcomers drown. Add one `docs/README.md` or `docs/map.md` (entry points → operating docs → historical decisions → dated evidence) rather than growing README.

**F3. Stale cross-references.**
`README.md:140-146` references removed `refactor-plan.md` and `plan.md` via Git history (correct) but also points to `docs/refactor/validation-matrix.md` test tiers that no longer match CI's `--all-systems` gap (E1). `docs/release-maintenance.md`'s August alignment waiver is re-scoped but Branch 12's "awaiting live application to the primary" step has no date/owner. Sweep docs links (`test_section10` checks local markdown links resolve — extend it to flag `plans.md`-indexed but removed files).

## Suggested implementation sequence

1. **Metrics and registration (half-day each, no behavior change).**
   D2 (replace scope-share ratio or demote to informational; shrink `ratchet.env`), D1 (single test manifest; fix tier drift), E1 (`--all-systems` + explicit activation evals). Each is reviewable in isolation and unblocks honest measurement of everything below.
2. **God-file seams (one commit per seam, red-green-refactor).**
   B1–B2 (`refactor-v2-final.md` Phases 1–3: thread identity/decision/profile-target, mode-tagged volume record, one claim cleanup epilogue), then A2 (Docker adapter split: transport → identity → lifecycle → locking), then B7 (`dx-ai.sh` split). Re-measure the (fixed) ratchet at each landing per Phase 4 gate 1.
3. **Duplication sweeps (small, mechanical).**
   A3–A4 (entry preamble, `dx_require_running_container`, unified state-dir + tar helpers), B3 (generated `find` predicates from deny-list), B4 (generated or contract-checked inventory), C1 (runtime×storage×arch matrix). Include Astra F6/F8/F9 while those boundaries are open (exclude-file propagation, healthcheck quoting, restore path joining).
4. **Correctness backstop (Astra F1–F5, F7, F10).**
   Backup completeness contract, detached-HEAD reachability, ownership-before-mutation, operation-level lifecycle lock, transactional manifest/generation publish. These need the seams from (2); doing them first risks merge conflicts with v2 threading.
5. **Docs and retirement.**
   F1 (retire consolidation plan after Phase 7 live steps; resolve Q7 park/reject/item-wise), B5 (container path rename), F2 (docs map), D5 (promote or defer the four backlog probes with owners). Keep `constitution.md`'s Red→Green→Refactor + behavior-over-parsing rule; add the "prove which generation ran" lease check (`refactor-v2-final.md:386-390`) to every live gate description.

Keep each change reviewable, retain the runtime boundary, immutable bootstrap generations, Bash 3.2 host compatibility, and data-only profiles. Those constraints are assets, not friction.

## Appendix — sizes consulted

| Path | Lines | Note |
| --- | --- | --- |
| `bin/lib/dx-runtime-docker.sh` | 1109 | largest host file |
| `container/.../bootstrap/base-and-storage.sh` | 1004 | largest guest file |
| `container/.../scripts/dx-ai.sh` | 663 | next guest god-file |
| `container/.../scripts/dx-theme-write-tool-themes.sh` | 600 | excluded from kcov |
| `container/.../scripts/lib/dx-persist-backup-select.sh` | 536 | deny-list ×4 |
| `bin/lib/dx-backup.sh` | 512 | host backup lib |
| `tests/test_docker_runtime_adapter.sh` | 2916 | largest test |
| `tests/test_sourceable_coverage.sh` | 2109 | >2× its module |
| `tests/test_section3_bootstrap.sh` | 1631 | bootstrap suite |
| `tests/coverage/ratchet.env` | 1313 | 1312 comments |
| `bin/` entrypoints total | 2287 | `dx-mount` 245 max |
| `bin/lib/` total | 3986 | 10 files |
| `tests/test_*.sh` total | 21861 | 39 suites |
