# Repository review: findings and refactoring opportunities

Reviewed on 2026-09-29 at commit `4e8c5cc`. This is a review of the current implementation, rather than a restatement of the earlier refactor assessment.

## Assessment

The repository has a useful architectural foundation: small lifecycle entrypoints, sourceable libraries, explicit runtime adapters, configuration snapshots, immutable bootstrap generations, and substantial behavioral testing. Preserve those boundaries. A wholesale rewrite would add risk without addressing the most important problems.

The highest-priority work is to strengthen backup completeness and resource ownership checks, and to connect the remote locking implementation to the lifecycle it is intended to protect. Several safeguards are well tested in isolation but incomplete at their call sites.

The review covered host configuration and lifecycle orchestration, both runtime adapters, bootstrap publication and storage, backup/restore, the Nix flake, test runners, CI, and supporting documentation. It was not an exhaustive review of every editor or theme setting.

### Validation and limitations

| Check | Result |
| --- | --- |
| `bash -n` across shell files in `bin`, `tests`, and `container`, using CI's file selection | Passed |
| `bash tests/test_persist_backup_select.sh` | **70 passed, 0 failed, 0 skipped**, after exposing the environment's existing Nix-store `gawk` and `gnutar` binaries through `PATH` |
| `nix flake check --offline --no-build --no-write-lock-file` for the guest flake | Passed; explicitly reported that `aarch64-linux` was omitted |
| Same Nix check with `--all-systems` | Passed for both architectures |
| Explicit `nix eval --offline --no-write-lock-file --raw` of each architecture's `homeConfigurations.dx-<system>.activationPackage.drvPath` | Passed for both architectures; evaluation only, no build or activation |
| Targeted temporary fixtures and stubbed runtime calls | Reproduced the defects identified as such below; no real runtime was contacted |
| Full container-free runner | Could not start directly: this review environment lacks `/bin/bash`, although Bash is available elsewhere |
| ShellCheck, kcov, Bash 3.2, real Apple/Docker lifecycle and restore drills | Not run; the required tools/runtime environments were unavailable |

The initial selector-test attempt also encountered a missing `awk`; its failures were environmental and the rerun above passed. No production scripts were changed. Runtime-dependent consequences below are distinguished from local reproductions.

Priority convention: **P1** addresses data integrity or unintended mutation; **P2** addresses correctness, recovery, or important validation gaps. “Reproduced” means a local fixture or recording stub demonstrated the behavior, not that a live guest was changed.

## Findings

### F1 — P1: An incomplete backup scan can delete the last backed-up copy

**Evidence:** [backup selector](container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh), especially `dx_pbs_emit_found_list` (line 269), `dx_pbs_list_driver` (375), and `dx_pbs_list_outside_repos` (422); [dx-backup](bin/dx-backup), lines 61–93; [backup library](bin/lib/dx-backup.sh), `dx_backup_diff` and `dx_backup_remove_paths`.

Directory traversal errors are hidden with `2>/dev/null`, failures are not consistently propagated, and entries whose metadata cannot be obtained can be skipped. The selector's standalone entrypoint enables `nounset` and `pipefail`, but not `errexit`; the driver can subsequently print its summary and return success. The host interprets any path missing from the new listing as no longer at risk and removes it from the mirror.

**Reproduced:** Back up a fixture containing `private/work`, make `private/` unreadable with `chmod 000`, and select again. The second scan exits **0** with an empty listing. `dx_backup_diff` puts `private/work` in the removal list. A transient permissions problem is therefore sufficient to schedule deletion of a valid backup.

**Recommendation:** Make scan completeness an explicit contract. Abort the backup on traversal, Git-query, stat, or hashing errors; report the affected path. Do not remove mirror entries or publish a manifest unless the entire selection succeeded. Check subprocess and process-substitution results explicitly rather than relying solely on `set -e`.

**Regression tests:** Permission-denied subtree, failed `find`, disappearing file, failed hash, and failed Git inspection must leave the prior mirror and manifest intact. Run permission tests as an unprivileged user so root does not mask the failure.

### F2 — P1: Local-only commits on detached HEAD are omitted from backups

**Evidence:** [backup selector](container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh), `dx_pbs_repo_at_risk_whole`, lines 117–123, and `dx_pbs_repo_clean_set`, lines 131–140.

Whole-repository selection checks `git log --branches --not --remotes`. It does not include detached `HEAD`. A commit reachable only from detached HEAD is therefore classified as safe when the named branches are already represented by remote-tracking refs. The subsequent clean-file calculation uses that same detached HEAD and excludes its committed files; `.git` is also excluded on this path.

**Reproduced:** Create an initial commit, record it as `origin/main`, detach HEAD, modify a file, and commit again without creating a branch. The selector classifies the repository as safe and produces **zero backup entries** despite the local-only commit.

**Recommendation:** Include `HEAD` in the reachability calculation and define the retention policy for stash and local tag refs as well. A repository whose reachability cannot be established should be retained conservatively or cause a reported failure. Document that remote-tracking refs are the local evidence being used; they are not a live guarantee that a remote still retains the objects.

**Regression tests:** Detached local commit, ordinary unpushed branch, stash-only work, local-only tag, and failed Git query. At minimum, a detached local commit must retain both its content and the Git objects needed to recover it.

### F3 — P1: Docker ownership is checked after some mutations, and not before reuse

**Evidence:** [container wrappers](bin/lib/dx-container.sh), `container_ensure_volume` at line 69; [dx-create-container](bin/dx-create-container), lines 8–11; [dx-destroy-container](bin/dx-destroy-container), lines 13–23; [Docker adapter](bin/lib/dx-runtime-docker.sh), existence queries at 440–449, start/stop/kill at 608–624, and label verification at 664–675.

An existing volume is accepted on existence alone. An existing container makes create return success without validating its labels. Start, stop, and kill also address the configured name directly. In particular, `dx-destroy-container` can stop a foreign same-named container before the later delete operation rejects its ownership.

Volume reuse has a more serious consequence: a mistaken profile can attach another resource's volume and allow guest bootstrap to modify it, even though deletion would have been refused. A local Nix-volume claim does not establish remote ownership or protect the persist/bootstrap volumes.

**Reproduced at the adapter boundary:** Calling the stop adapter with a recording transport emits only `docker stop <name>`; there is no ownership lookup. Inspection of the orchestration confirms stop precedes delete validation. Also, `dx_runtime_docker_verify_labels` accepts schema `999` when managed/profile/role match: it reads but does not validate `schema`, and does not inspect the system label.

**Recommendation:** Establish one “owned resource” check before adoption, writable attachment, start, stop, kill, and delete. Validate the supported schema and relevant architecture label. Preserve the existing whole-operation destructive preflight, but move the first ownership check ahead of every mutation. Keep “absent” distinct from “could not inspect.”

**Regression tests:** Foreign or unlabelled running container must receive zero stop/kill/delete calls; foreign volumes must receive zero writable attachments; unknown schema and incompatible system must be refused.

### F4 — P1: The remote lifecycle lock is implemented but never acquired

**Evidence:** [Docker adapter](bin/lib/dx-runtime-docker.sh), `dx_runtime_docker_lock_acquire` at line 1025; [dx-lock](bin/dx-lock); [dx](bin/dx), [dx-recreate](bin/dx-recreate), and the create/start/destroy entrypoints.

A search of production code finds a definition of `dx_runtime_docker_lock_acquire`, but no invocation. `dx-lock` exposes status and release, not acquisition. Consequently, the presence of the lock implementation and its tests does not serialize real lifecycle operations. Two controllers can run overlapping create/recreate/destroy sequences.

The existing Nix claim is controller-local at `$HOME/.dx-cache/nix-volume-claims/<volume>`. It cannot exclude a second controller and is not scoped by remote daemon, so it also conflates identically named volumes on different targets.

**Recommendation:** Add an operation-level lock boundary used by all mutating entrypoints. Define nested-command ownership so an orchestrator acquires once and its children inherit an owner token. Release only the matching acquisition on normal exit and handled signals; preserve operator recovery after an ungraceful interruption. Account explicitly for first-run image creation, since the current lock container requires an existing image. Scope local claims by runtime/daemon identity too.

**Regression tests:** Two controllers targeting the same profile cannot mutate concurrently; different daemons remain independent; direct entrypoint calls are protected; nested calls do not deadlock; interrupted ownership is reported rather than silently stolen.

### F5 — P2: Atomic manifests do not make the backup mirror transactional

**Evidence:** [dx-backup](bin/dx-backup), lines 82–94; [backup library](bin/lib/dx-backup.sh), `dx_backup_fetch_paths` at 249 and `dx_backup_write_manifest_atomic` at 301.

Changed files are extracted directly over `current/`. Only the manifest is published atomically. If a stream fails partway through extraction, the last successful backup may already be partly overwritten while its old manifest remains. Concurrent backup processes can also interleave extraction, removal, and manifest replacement. Restore reads the physical mirror rather than a committed snapshot, so it can observe that intermediate state.

This is a code-path finding; interruption and concurrency were not exercised against a live runtime.

**Recommendation:** Add a per-backup lock shared appropriately with restore. Stage and validate transferred content before replacing committed data. For whole-backup consistency, publish a new generation with an atomic pointer change and retain the previous generation; use safe copy-on-write facilities where available, without mutating hardlinked files in place. Check extracted files against the selection's hashes before committing, so changes between listing and transfer cannot silently misdescribe the snapshot.

**Regression tests:** Truncated archive after the first changed file, interrupted publication, overlapping backups, file changing during transfer, and restore during backup. The previous committed snapshot must remain usable.

### F6 — P2: A missing explicit backup exclude file does not abort the command

**Evidence:** [dx-backup](bin/dx-backup), lines 38–44; [backup library](bin/lib/dx-backup.sh), `dx_backup_read_exclude_patterns`.

The exclude reader correctly returns failure for a nonexistent explicit file, but it runs inside `done < <(...)`. The surrounding loop does not propagate that process substitution's exit status. Backup continues with an empty extra deny-list after printing an error. That can copy data the operator explicitly intended to exclude.

**Reproduced:** Point the reader at an absent temporary path and execute the same loop. It prints the error, but the loop returns **0**, with zero patterns.

**Recommendation:** Read and validate the exclude file into a temporary file or checked command result first, then populate the array. Treat an explicit unreadable path as fatal before requesting the guest listing. Also preserve patterns as individual records: the selector currently joins extra patterns with `$*` and word-splits them, so a pattern containing spaces loses its boundaries.

**Regression tests:** Explicit missing/unreadable file aborts before guest access; absent optional default remains allowed; a pattern containing spaces is passed and matched as one pattern.

### F7 — P2: The Docker healthcheck accepts stale leases as proof of health

**Evidence:** [dx-create-container](bin/dx-create-container), line 84; [bootstrap launcher](bin/lib/dx-ssh-common.sh), lines 370–384; [bootstrap entrypoint](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh), lines 10–39.

The healthcheck tests whether any filename matches the current generation. It does not read the lease's boot ID, PID, or process start time. The launcher publishes the lease before bootstrap starts its storage, configuration, and activation work. A lease alone therefore establishes neither current process ownership nor completed bootstrap.

**Reproduced:** A temporary `current -> generations/review` symlink and a stale `review.999999` file are enough for the exact health command to exit **0**, with no bootstrap or guest process.

**Recommendation:** Decide whether this signal means generation ownership or application readiness, and label it accordingly. In either case validate the full lease identity. For readiness, publish a completion marker tied to that identity only after required activation/verification succeeds, or add a local service probe. Preserve independence from the external SSH network path.

**Regression tests:** Stale lease, PID reuse, restart before publication, hung activation, and successful completed bootstrap. A stopped process's durable filename must not imply health.

### F8 — P2: The generated healthcheck turns a configured path into shell code

**Evidence:** [dx-create-container](bin/dx-create-container), line 84; [configuration validator](bin/lib/dx-config.sh), lines 137–139 and configuration resolution at 256–302.

`DX_BOOTSTRAP_PATH` is interpolated into the shell program that Docker later executes. Environment-supplied path values are checked only for an initial `/`; the stricter config-file parser does not constrain those values. Literal command substitutions or quotes inside a valid path acquire shell meaning when the healthcheck runs.

**Reproduced harmlessly:** A path ending in the literal text `$(printf injected >&2)` passes field validation. Executing the generated health program prints `injected`, demonstrating evaluation of the path as code. No live container was involved.

**Recommendation:** Use a fixed probe program with the path transported as data through a safely encoded argument or environment field. Apply the existing data/code boundary discipline used by the bootstrap launcher. Do not rely on the assumption in the current comment that the path is fixed and never user data; it is a registered configuration field.

**Regression tests:** Spaces, apostrophes, dollar signs, command-substitution text, and backslashes remain literal path characters, and no injected side effect occurs. Include environment overrides, not just `.env` parsing.

### F9 — P2: Restore directory selection corrupts valid path names

**Evidence:** [backup library](bin/lib/dx-backup.sh), `dx_backup_restore_targets`, lines 336–356.

For directory arguments, the function inserts the user-supplied path directly into `sed "s#^\\.#$path#"`. `&`, backslashes, and the `#` delimiter have special meaning in this replacement program even though they are valid filename characters.

**Reproduced:** A mirror containing `a&b/item`, selected with directory argument `a&b`, emits `a.b/item`. A `#` can also break the sed expression. This can fail a restore or select an unintended existing mirror path.

**Recommendation:** Join paths as data with a `read -r` loop and `printf`, rather than a dynamically constructed sed expression. Use a single path enumeration/validation contract for explicit file arguments, directory arguments, and whole-mirror restores. Reject unsupported tab/newline names explicitly rather than silently misparsing them.

**Regression tests:** Directories with `&`, `#`, backslashes, spaces, and leading hyphens; overlapping selections should not produce duplicate transfer entries.

### F10 — P2: Cross-field validation does not enforce the runtime/storage relationship

**Evidence:** [configuration registry](bin/lib/dx-config.sh), defaults at 23–27 and `dx_config_validate_cross_fields` at 157–176; [Docker create adapter](bin/lib/dx-runtime-docker.sh), lines 533–545; [storage bootstrap](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh), `prepare_nix_volume_impl` at 864.

Cross-field validation currently checks only the relationship between runtime and remote host. A Docker profile can retain the default `apple-image` storage mode even though the Docker adapter mounts its store directly at `/nix` without Apple's staging/mount capabilities. The host accepts this combination and can create resources before guest bootstrap attempts the incompatible path. The registry also does not require the three volume roles to have distinct names.

**Reproduced:** `DX_RUNTIME=docker-ssh`, a nonempty remote host, `DX_GUEST_SYSTEM=x86_64-linux`, and `DX_NIX_STORAGE_MODE=apple-image` pass `dx_config_validate_cross_fields`.

**Recommendation:** Define and enforce a small compatibility matrix during resolution: supported runtime/storage pairs, applicable architecture constraints, and distinct volume roles. Either derive dependent defaults from runtime or require explicit values with a clear early error. Keep actual remote architecture detection as a separate preflight check.

**Regression tests:** Invalid combinations fail before any runtime call. Valid Apple and Docker profiles retain their existing behavior, including configuration-snapshot inheritance.

### F11 — P2: CI's Nix evaluation omits the primary Apple guest architecture

**Evidence:** [CI workflow](.github/workflows/ci.yml), line 34; [flake](container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.nix), `supportedSystems` and `homeConfigurations`; [validation matrix](docs/refactor/validation-matrix.md).

CI runs `nix flake check --no-build` on an x86_64 Linux runner without `--all-systems`. The flake now supports both architectures, but the default command omits ARM. Checking the custom `homeConfigurations` output also does not replace explicitly forcing evaluation of each activation derivation.

**Reproduced:** The CI-shaped command passes and prints `The check omitted these incompatible systems: aarch64-linux`. Adding `--all-systems` passes for the present tree. This is a regression-detection gap, not evidence that today's ARM outputs are broken.

**Recommendation:** Add `--all-systems` and explicit evaluation of `homeConfigurations.dx-aarch64-linux.activationPackage.drvPath` and its x86_64 counterpart, or expose those derivations through flake `checks`. Continue separating evaluation from native builds and live bootstrap tests. Update the validation matrix, which still says the flake pins one architecture and describes all Nix builds as Mac-only.

**Regression tests:** Deliberately break an ARM-only package and a Home Manager module; each must fail the appropriate CI evaluation gate without requiring a cross-architecture build.

## Refactoring opportunities

### R1 — Measure production coverage without penalizing tests or rewarding comments

[run-coverage-linux.sh](tests/run-coverage-linux.sh), lines 64–68, divides sourceable-library text lines by all shell text lines, **including tests**. This ratio decreases when tests are added and increases when comments are added inside covered libraries. It measures neither executable coverage nor the share of production behavior tested.

[ratchet.env](tests/coverage/ratchet.env) is now **1,313 lines, of which 1,312 are comments**, largely recording baseline adjustments. The file itself acknowledges that adding tests looks like a regression. Source also contains formatting concessions made only to satisfy kcov attribution, such as large single-line programs and commands attached to `done`.

Keep the executable-line gate, but calculate any scope metric against production code only, preferably executable lines. Track excluded production entrypoints explicitly. Move rebaseline history into an evidence record and keep configuration small. Add behavioral fault tests such as F1–F8 before pursuing more line-count improvements: all lines executing once does not prove that failure stops the caller.

### R2 — Consolidate test registration and make runtime contracts reusable

[run_all_tests.sh](tests/run_all_tests.sh), [run-tier.sh](tests/run-tier.sh), [run-bash32-tests.sh](tests/run-bash32-tests.sh), and [run-coverage-contracts.sh](tests/run-coverage-contracts.sh) maintain overlapping lists manually. They already differ: `unit/static` stops at section 32 and does not include section 33's Docker adapter suite; `host-contract` runs only sections 9 and 18. The main runner's help advertises sections 0–27 while its registry extends through 33. CI does run section 33 through the main runner, so this is specifically a local-tier drift problem.

Create one declarative test manifest with name, file, applicable tier, interpreter, and runtime requirements. Generate or select each runner's list from it, and reject unknown command-line options. Add a consistency check that every suite belongs to an intended tier.

Split the **2,916-line Docker adapter test** into transport, identity/ownership, lifecycle, locks, and health scenarios. Run shared adapter contract cases against both implementations where their semantics are meant to match. Retain runtime-specific tests for genuine platform differences. Migrate source-text assertions toward behavior when modifying the affected area; do not remove useful architectural audits merely because they inspect source.

### R3 — Extract shared protocols and keep current code comments focused on invariants

The Docker adapter is **1,109 lines**, including **482 comment lines**; the backup library is **512 lines**, including **249 comment lines**. Size alone is not the problem. Many comments narrate individual branches, increments, coordinating sessions, or historical alternatives already recorded elsewhere, making the current contract harder to locate.

Useful extraction boundaries are Docker transport/discovery, identity/ownership, lifecycle operations, and locking. Keep one public adapter facade. Move historical narratives into existing decision/evidence documents and retain concise explanations of invariants, failure behavior, and platform constraints beside the code.

Two concrete duplication targets are the publication-lock/process-identity protocol repeated in [dx-sync-bootstrap](bin/dx-sync-bootstrap) and [dx-ssh-common.sh](bin/lib/dx-ssh-common.sh), and the backup deny-list repeated across its matcher and several `find` expressions. Render first-contact shell programs from a shared host-side source where needed; do not introduce a dependency on guest files that have not yet been published. Generate traversal predicates from the same deny-list data used by the matcher.

### R4 — Reduce remote round trips and quadratic work in restore

[dx_backup_restore_push](bin/lib/dx-backup.sh), lines 468–511, builds a directory list using repeated string searches and `dirname` subprocesses, passes the entire directory list as command arguments, and performs a separate runtime `chown` for every restored file. Over Docker SSH, a large restore can therefore require tens of thousands of sequential SSH calls, even though the content transfer is batched. The hash-status side already has a file-list threshold to avoid argument limits; the directory-creation side does not.

Generate and deduplicate parent directories in one pass, ship a bounded list through the existing unidirectional transport, and apply ownership in one guest operation with explicit symlink semantics. Avoid transferring or re-owning entries classified as identical when that matches the intended metadata policy. Add a large-tree recording test that asserts bounded runtime-call counts, plus a real isolated restore measurement before changing transport behavior.

## Suggested implementation sequence

1. **Backup correctness:** Add failing fixtures for F1 and F2, then fix completeness propagation and ref reachability. Include F6 and F9 while those boundaries are under review. Verify with an isolated backup/restore drill.
2. **Resource safety:** Enforce F3's ownership check before the first mutation, validate schema/system, and add F10's configuration matrix.
3. **Concurrency and recovery:** Connect lifecycle locks in F4 and make backup publication recoverable in F5. Exercise contention and interruption, including direct entrypoint invocation.
4. **Health and validation:** Fix F7/F8 together, extend Nix evaluation in F11, and consolidate test registration.
5. **Maintenance and performance:** Revise the coverage metric, extract duplicated protocols, shorten historical comments, and batch restore operations. Preserve behavior with the strengthened contracts established above.

Keep each change reviewable and retain the existing runtime boundary, immutable bootstrap-generation model, Bash 3.2 host compatibility, and data-only configuration format. These are assets to build on.
