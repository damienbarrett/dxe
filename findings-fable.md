# Repository review: refactoring and improvement opportunities (Fable)

Reviewed on 2026-09-29 at commit `4e8c5cc` (`main`), clean tree apart from the untracked `findings-astra.md` and `findings-muse.md`.

Scope: host orchestration (`bin/`, `bin/lib/`), the guest tree (`container/aarch64-darwin-apple-container-dx-nixos-26.05/`, written `G/` below: bootstrap modules, `scripts/`, the flake and Home Manager modules), the test suite and coverage gate (`tests/`), CI, and the root plan documents.

Method: every host library and entrypoint was read in full; the guest shell, the Nix tree and the test suite were each read in full by a dedicated pass whose claims were then re-checked line by line against the tree; static checks and the container-free test tier were run (see "Validation"); four claims were reproduced with fake boundaries or offline Nix evaluation. Line numbers refer to the commit above.

This note complements `findings-astra.md` (correctness defects F1–F11, refactors R1–R4) and `findings-muse.md` (structure A–F). Where they already prove a point, the ID is cited rather than the proof repeated. Where this review extends, quantifies, corrects or disagrees with them, it says so.

Every recommendation is shaped for the constitution's workflow: **Red** (the failing behavioural test to write first, naming fixture and assertion), **Green** (the smallest change that passes it), **Refactor** (the structural follow-through, with the new test as the safety net). Nix recommendations use standard flake and Home Manager idioms and were checked against the pinned inputs in the lock file.

## Validation and limitations

| Check | Result |
| --- | --- |
| `bash -n` over CI's file selection (`bin`, `tests`, `container`) | Passed, every file |
| ShellCheck **0.11.0** `--severity=warning` over all production shell (`bin/`, `container/`) | **Clean: zero findings.** CI pins 0.10.0 because 0.11.0 crashes on the import-purity construct; on this tree the crash affects exactly two files, `tests/test_refactor_contracts.sh:29` and `tests/test_section9_host_scripts.sh:20` (the CI comment names only the first). Every other test file is clean too. |
| `tests/run_all_tests.sh --skip-integration` | Ran in 51 s; 17 of 33 suites reported failures. **Every failure was traced to this review sandbox, not to the code**: it has no `/bin/bash` (all `bin/dx*`, `tests/lib/audit-flake-lock.sh` and every fake written by `tests/lib/fake-tools.sh:12` use `#!/bin/bash`), and fixtures that pin `PATH="$dir:/usr/bin:/bin"` lose the GNU tools this sandbox only has in the Nix store. Suites that avoid both passed in full: sections 0, 1, 2, 3 (194 passed), 4, 5, 7, 8, 13, 15, 17 (95 passed), 28 (the backup selector, 70 passed) and 32 (the boundary audit). The one non-environmental failure is section 10's `plans.md` contract rejecting the two untracked findings files (it will reject this one too; see E2). |
| `nix eval --offline` of `homeConfigurations.dx-{aarch64,x86_64}-linux.activationPackage` and `packages.x86_64-linux.ai-tools`; `nix flake show` | Evaluate successfully. Five evaluation warnings (C2). No `checks` output exists (C1). The Nix pass also verified, in a scratch copy, that `homeConfigurations.broken = throw "BOOM"` still passes `nix flake check --all-systems`. |
| Reproduction: docker-ssh tunnel state under an unreachable host (A1) | Reproduced with a fake `ssh` and the real `bin/lib/`; transcript in A1 |
| Reproduction: backup deny-list glob expansion (B5) | Reproduced: from a directory containing `result-bin`, `p/result-abc` is **not** denied; from `/` it is |
| Astra F4 (remote lock never acquired) | Confirmed by search: `dx_runtime_docker_lock_acquire` has no caller outside its own file |
| kcov run, Bash 3.2 job, `nix build`, live and destructive tiers | Not run: kcov, macOS Bash 3.2 and a container runtime are unavailable here |

Priorities: **High** blocks or taxes the Red → Green → Refactor loop, or hides a real failure mode; **Medium** is a structural cost that compounds; **Low** is mechanical.

## Assessment

The architecture the two earlier reviews describe is sound and should be kept: thin entrypoints over sourceable libraries, one runtime dispatcher with two adapters, data-only configuration, immutable bootstrap generations, an idiomatic flake, and a large body of tests that fake the real boundaries rather than the code under test.

Read against the constitution (TDD, 100% coverage, behaviour over parsing), the repository's most expensive problems are not the god-files. They are the things that make writing the *next* failing test slow, and the places where "100%" is measured over the wrong set:

1. **A third of the production shell is outside the coverage gate by declaration.** `tests/coverage/exclusions.txt` exempts `bin/dx*`, `bootstrap.sh` and `scripts/*.sh`: 4,142 of 11,686 production lines (35%). The six largest entrypoints carry 727 executable lines no gate measures, and `scripts/dx-ai.sh` (663 lines) holds two of the High findings below. Logic drifts toward exempt files because that is where adding it costs nothing (A4, B7).
2. **The harness makes a failing test cost more than the fix.** Results live in shell counters that subshells lose, there is no capture helper, seven suites define their own assertion vocabulary, registering a file touches up to seven places, and the ratchet then reports the new test as a regression (D1–D3).
3. **The Nix side is checked by nothing until a guest boots.** The flake exports no `checks`, so `nix flake check` walks neither Home Manager configuration; five evaluation warnings (three renamed options, a package removal notice, a nixpkgs-instance mismatch) pass CI silently (C1, C2).
4. **Implicit protocols with no pinning test.** `dx-start-container` parses `dx-sync-bootstrap`'s prose; the guest publication lock is pasted in three places and has already drifted; local tunnel state is keyed by a value fetched from the NAS on every call and the failure is swallowed (A1–A3, B3).
5. **Two guest paths fail open in ways that lose data or brick a boot**: a corrupt Claude `settings.json` is replaced with an empty file, and a failed `mount`/`mkfs` is reported as a completed phase (B1, B2).

The order that follows: build the harness, fix the metric and add the Nix `checks` first (two or three days, no production change); land the guest correctness fixes with the fixtures that are by then cheap; open the seams (main-guarded entrypoints, injectable waits, one config table, `bootstrap_phases`); pin the protocols; then the structural splits (`refactor-v2-final.md` with the corrections in B6, the Docker adapter, `dx-ai.sh`) and the Astra F-series.

## Relationship to the earlier reviews

**Confirmed by independent reading:** Astra F3 (stop/kill/start address the name with no ownership read, `dx-runtime-docker.sh:608–624`), F4 (lock acquisition has no production caller), F8 (`dx-create-container:84` interpolates `DX_BOOTSTRAP_PATH` into a program, contradicting the project's own D6 rule "configuration is never interpolated into generated executable text"), F10; Muse A1–A6, B1–B5, B7, C1–C2, D1–D5, E2–E4, F1–F3.

**Extended with numbers or proof:** Astra R1/Muse D2 (the ratchet arithmetic, D3); Astra R3 (the duplicated publication protocol has *already* drifted, diff in A3, and there is a third, weaker copy in `dx-ai.sh`, B3); Muse A1/Astra R1 (the coverage-exempt share and per-file executable counts, A4); Muse B3/Astra F6 (the deny-list is not only duplicated, its patterns are glob-expanded against the CWD, reproduced in B5); Muse B4 (the inventory diff, C3).

**Corrected:**

- Muse D1 and Astra R2 say the local `unit/static` tier "stops at 32 (omits 33)". It also omits **0, 4, 19 and 24**, all container-free and all run by CI (D2).
- Astra F11 and Muse E1 say CI evaluates only x86_64 Nix. `tests/test_section5_nix.sh:80` does evaluate `dx-aarch64-linux.activationPackage` on CI (with `|| true` and stderr discarded). What nothing evaluates is `dx-x86_64-linux` (the QNAP guest) and `packages.aarch64-linux.ai-tools`. `--all-systems` closes the second gap only; only a `checks` output closes the first (C1).
- Muse B6 treats the `agy` pin skew as undocumented drift. It is enforced: `test_section6_tools.sh:210–212` asserts the literal aarch64 version, URL and hash and nothing asserts x86_64, so the skew is the only state CI accepts (C6).

**One sequencing disagreement.** `plans.md` records an undecided conflict between `declarative-nix-plan-a.md` #12 (replace the ratio) and `refactor-v2-final.md` Phase 4 (re-measure the ratio). Muse recommends finishing v2 Phases 1–3 on the current metric and then changing it. This review recommends the reverse. v2's own phase gates *add tests* (the "verified clean skip writes no marker" test, the mode-tagged record readers), and under the current ratio each of those looks like a regression and forces a `ratchet.env` edit. The metric change is half a day with its own Red test (D3); doing it first removes friction from everything after it, including v2. v2 also needs the corrections in B6 before its Phase 1 is executable as written.

**Not repeated here:** the Astra F-series fixes. They are correct and belong in step seven of the sequence, because each needs a fault-injection fixture (permission-denied subtree, failed `find`, truncated archive, stale lease) that the harness in D1/D5 turns from forty lines into ten.

## Findings

### A. Host layer (`bin/`, `bin/lib/`)

#### A1 — Local tunnel state is keyed by a remote round trip, and the failure is swallowed (High, reproduced)

**Evidence.** `bin/lib/dx-tunnel.sh:33–39`:

```sh
dx_tunnel_key() {
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        printf '%s:%s:%s:%s' "$1" "$DX_CONTAINER_NAME" "$2" "$(dx_runtime_host_identity)"
```

`dx_runtime_host_identity` for docker-ssh (`dx-runtime-docker.sh:393–396`) calls `dx_runtime_docker_discover_daemon_id`, an SSH round trip (`:320–336`) unless the ID is already cached in this process. Every socket, metadata and lock path derives from that key (`dx-tunnel.sh:40–43`). A failing command substitution inside a `printf` argument does not abort under `set -e`, so on an unreachable host the identity segment silently becomes empty and every path changes.

**Reproduced** with a fake `ssh` (answers Docker discovery and `docker info` while "up", exits 255 while "down") and the real libraries:

```text
reachable:   key=forward:dx-qnap:8080:docker-ssh:nas:DAEMON123
             metadata written: m-53476a33bc.meta
unreachable: key=forward:dx-qnap:8080:        <- identity segment empty
unreachable dx_tunnel_list:
  ssh: connect to host nas port 22: No route to host   (x3, one per key computation)
  Orphan dx-forward metadata for port 8080: .../s-4a71df62fd.sock.meta
```

The live tunnel's record is reported as an orphan at a path that never existed. `dx-forward --stop 8080` then reports "No dx-forward forward found" while the SSH master still holds the port, and `dx-forward 8080` refuses with "already in use and is not managed by dx-forward". This is exactly the moment (NAS unreachable) an operator wants to tear tunnels down; `--list` also costs three SSH dials per entry.

`dx_backup_resolve_dir` (`dx-backup.sh:64–72`) and `dx_ssh_known_hosts_dir` (`dx-ssh-common.sh:29–33`) use the same segment; both fail closed because their callers run under `set -e` with a plain assignment, so they are slow but not wrong. The tunnel path is the one that fails open.

**Red.** In `tests/test_section19_reverse_forward.sh`, with `DX_RUNTIME=docker-ssh` and a transcript-recording fake `ssh`: write metadata for `forward 8080` while the fake is reachable; flip the fake to exit 255; assert (a) `dx_tunnel_list forward` names port 8080 at the *same* socket path as before, (b) `dx_tunnel_stop forward 8080` removes it, (c) the fake recorded zero `ssh` calls during (a) and (b). All three fail today.

**Green.** Make the identity segment fail closed and cacheable: `dx_runtime_docker_discover_daemon_id` writes the daemon ID to `${XDG_STATE_HOME:-$HOME/.local/state}/dxe/$DX_CONTAINER_NAME/host-identity` (0600, atomic rename) when it succeeds; `dx_runtime_docker_host_identity` reads that file before dialling; `dx_tunnel_key` becomes `identity="$(dx_runtime_host_identity)" || return 1` and callers propagate the status. No behaviour change for Apple.

**Refactor.** One `dx_profile_state_segment` in `dx-host-util.sh` returns the per-profile local path segment for tunnels, backups and known-hosts, so the three call sites cannot diverge; the identity becomes a parameter passed down from the entrypoint rather than a call made inside a path helper.

#### A2 — Two lifecycle scripts communicate through human-readable stdout (Medium)

**Evidence.** `bin/dx-start-container:22–51` captures `dx-sync-bootstrap`'s stdout, reprints it, and hands it to `dx_bootstrap_sync_published_generation` (`dx-container.sh:249–265`), which pattern-matches the literal `"Bootstrap generation "*" is ready."` to decide whether to run the bounded publication confirmation (`dx_bootstrap_confirm_publication`: the D7 option-3 guarantee that a start fails if the guest is not running what was just published). The unchanged-content path is recognised by the *absence* of that phrase (`dx-sync-bootstrap:81` prints "stays current").

**Why it matters.** Any wording edit to a user-facing message in the sync silently downgrades the start's strongest guarantee to a warning: the parser returns 1 for "matching neither message", which is the *skip* path. No test pins the coupling from the start side.

**Red.** `tests/test_section9_host_scripts.sh`: run `bin/dx-start-container` with a fake `dx-sync-bootstrap` (a fixture copy of `bin/`, or a `DX_SYNC_BOOTSTRAP` override) whose success line reads `Published bootstrap generation X.`, and a fake runtime whose lease never matches; assert the start **fails** (confirmation should run and time out). Today it exits 0 with a drift warning.

**Green.** Give the sync a data channel: `dx-sync-bootstrap --result-file PATH` writes `outcome=published|unchanged` and `generation=<id>` in the repository's bounded `NAME=value` grammar (read with the config-file reader, never sourced). `dx-start-container` reads that file; prose stays prose.

**Refactor.** Move the sync body into `bin/lib/dx-bootstrap-sync.sh` as `dx_bootstrap_sync <container> <source> <path>` returning 0 for published, 3 for unchanged, generation on stdout; both entrypoints call it; delete the string parser. This also brings 161 executable lines under the coverage gate (A4).

#### A3 — The guest publication lock protocol is embedded twice and has already drifted (Medium; extends Astra R3)

**Evidence.** The launcher heredoc in `dx_bootstrap_launch_command` (`dx-ssh-common.sh:291–385`) and the sync's `sh -c` program (`dx-sync-bootstrap:89–206`) each carry `process_start`, the publication-lock loop, the owner-file write and the release. A whitespace-normalised diff of the two lock sections:

```diff
< || [ "$owner_boot" != "$boot" ] || [ -z "$live_start" ] || [ "$owner_start" != "$live_start" ]; then
---
> || [ "$owner_boot" != "$boot" ] || [ "$owner_start" != "$live_start" ]; then
```

plus differing error wording and path variables. They are equivalent today only because `owner_start` is checked non-empty earlier; the next edit to one copy has no test forcing the other to follow. A third, weaker copy lives in `G/scripts/dx-ai.sh:130–139` (B3). All three are quoted strings or coverage-exempt files, so kcov measures none of them.

**Red.** A behavioural contract that runs each lock loop (extracted by function name from each rendering) against the same fixture: a fake `/proc/<pid>/stat` tree, a lock held by a live owner, by an owner from a previous `boot_id`, by a reused PID, and an ownerless lock directory; assert identical outcomes and stderr. As a cheaper first guard: assert the two host renderings are byte-identical (fails today on the diff above).

**Green.** Render both from one source: `bin/lib/dx-bootstrap-protocol.sh` exposes `dx_guest_publication_protocol_snippet` (a `cat <<'EOF'`); the launcher and the sync concatenate it in front of their own logic.

**Refactor.** Ship the snippet as `G/scripts/lib/dx-publication.sh` inside every generation so the sync and `dx-ai` can source it once a generation exists, keeping the rendered copy only for the launcher's first contact, with a contract test asserting the shipped file and the rendered snippet are identical.

#### A4 — 35% of production shell is exempt from the coverage gate, and entrypoints cannot be sourced by tests (High; extends Muse A1 and Astra R1)

**Evidence.** `tests/coverage/exclusions.txt` exempts `bin/dx*` ("pure logic lives in bin/lib"), `container/**/bootstrap.sh` and `container/**/scripts/*.sh`. Measured on this tree:

| Set | Lines |
| --- | ---: |
| Covered scope (`bin/lib`, `bootstrap/`, `scripts/lib`) | 7,544 |
| Exempt host entrypoints (`bin/dx*` minus `dx-lib.sh`) | 2,262 |
| Exempt guest (`bootstrap.sh`, `scripts/*.sh`) | 1,880 |
| **Exempt share of production shell** | **35%** |

Executable (non-comment, non-blank) lines in the largest exempt entrypoints: `dx-mount` 225, `dx-sync-bootstrap` 161, `dx-status` 112, `dx-herdr` 88, `dx-create-container` 71, `dx-wait-ssh` 70. `dx-status` alone makes 18 runtime calls across five sections, each swallowing errors differently. The premise in `exclusions.txt` stopped being true around `dx-mount`. Only `dx-forward` and `dx-reverse` use the sourceable main guard (`if [ "${BASH_SOURCE[0]}" = "$0" ]; then forward_main "$@"; fi`, `dx-forward:44`); every other entrypoint executes at top level on source, so a test can only run it as a subprocess with fakes on `PATH`, never call one of its functions.

**Why it matters.** The constitution's 100% is measured over a shrinking denominator. New behaviour placed in an entrypoint is free of the gate; placed in a library it pays the ratchet (D3). That is the wrong incentive, and it is why `dx-mount` grew to 245 lines while `dx-mount-plan.sh` stayed pure.

**Red.** A contract test (tier unit) that sources each `bin/dx*` and asserts (a) no output, (b) no exit, (c) a function `<name>_main` exists. Fails today for every entrypoint except the two tunnel CLIs.

**Green.** Mechanical: wrap each entrypoint body in `<name>_main() { … }` plus the guard, one file per commit, starting with the six above. Behaviour is unchanged; the existing subprocess tests are the safety net.

**Refactor.** Remove `bin/dx*` from `exclusions.txt` one file at a time as its main lands (kcov's `--include-path` then measures it, because the tests already execute it), and let D3's ceiling metric make the exempt count monotonically decrease. Do the same for `G/scripts/dx-ai.sh` after B7.

#### A5 — The configuration registry is four hand-synced lists, and the validator accepts unknown names (Medium; extends Muse C2)

**Evidence.** `bin/lib/dx-config.sh` defines each field in four places that must agree: `DXE_CONFIG_FIELDS` (`:6`), `dx_config_path_field` (`:15–20`), `dx_config_default` (`:22–64`), `dx_config_validate_value` (`:66–147`), with a fifth in `docs/configuration.md` (checked by section 10) and a sixth in `test_refactor_state_machines.sh`. Two consequences:

- `dx_config_validate_value` has no default arm, so `dx_config_validate_value DX_NOT_A_FIELD anything` returns **0**. Production is protected only because `dx_config_set_resolved` checks `dx_config_is_field` first; `bin/dx-restore:38` calls the validator directly, and a future caller with a typo passes silently.
- `DX_BOOTSTRAP_SOURCE`'s default (`:36`) reads `${DX_CONTEXT_DIR:-…}` and is correct only because `DX_CONTEXT_DIR` precedes it in the `:6` string. Nothing documents or tests that ordering dependency.

**Red.** Two cases in `test_refactor_state_machines.sh`: `dx_config_validate_value DX_NOT_A_FIELD x` must return non-zero (fails today); resolving with `DXE_CONFIG_FIELDS` re-ordered so `DX_BOOTSTRAP_SOURCE` comes first must still yield the context-dir default (fails today).

**Green.** Add `*) return 1 ;;` to the validator; derive `DX_BOOTSTRAP_SOURCE`'s default from `dx_config_default DX_CONTEXT_DIR` rather than the environment.

**Refactor.** One table, `DXE_CONFIG_REGISTRY`, one line per field: `NAME<TAB>kind<TAB>default`, `kind` ∈ `enum:a,b`, `name`, `image`, `port`, `posint`, `size`, `abspath`, `optpath`, `optname`. The four functions become lookups plus one validator per kind. Generate the `docs/configuration.md` defaults table from the same registry (a `docs/gen-config-table.sh` and a section 10 assertion that the committed table equals the generated one). Bash 3.2-clean: a string and `case`, no associative arrays.

#### A6 — Seven hand-written bounded-wait loops, none with an injectable clock (Medium)

**Evidence.** `bin/dx-wait-ssh:100–147` (`SECONDS`-based), `dx-container.sh:90–98` (`container_wait_stopped`), `dx-container.sh:285–300` (`dx_bootstrap_confirm_publication`), `dx-host-util.sh:101–136` (`dx_lock_acquire`), `dx-sync-bootstrap:9` (a hard-coded 30-iteration `container_is_running` loop that ignores `DX_BOOTSTRAP_WAIT_TIMEOUT`), `dx-sync-bootstrap:13–16`, and the launcher's grace loop (`dx-ssh-common.sh:349–358`). Each polls with a literal `sleep 1`. The suite pays with real sleeps (`test_bootstrap_publication.sh:293 sleep 2`, `test_refactor_state_machines.sh:341 sleep 0.2`; D10) and with the timing-flaky probes Muse D5 lists.

**Red.** `tests/test_host_util.sh`: `dx_wait_until 3 1 false` with a fake `sleep` that records calls and advances a fake clock returns 1 after exactly three recorded sleeps; `dx_wait_until 3 1 pred` where `pred` succeeds on its second call returns 0 after one sleep. Fails today: no such function.

**Green.** `dx_wait_until <timeout> <interval> <cmd…>` in `dx-host-util.sh` using `${DX_SLEEP:-sleep}`; Bash 3.2-clean, pure.

**Refactor.** Migrate the seven loops one per commit, keeping each site's messages verbatim. `dx-sync-bootstrap:9` gets `DX_BOOTSTRAP_WAIT_TIMEOUT` instead of the magic 30. Tests that sleep to synchronise then run with `DX_SLEEP=:` and a scripted predicate.

#### A7 — Mechanical duplication and stale comments (Low)

- `bin/dx-forward` and `bin/dx-reverse` are 44-line mirror images. One `dx_tunnel_cli <direction> "$@"` in `dx-tunnel.sh` and two two-line entrypoints. Red: the existing section 19 argument-parsing cases against the merged function for both directions.
- `bin/lib/dx-runtime-docker.sh`: 27 functions open with `bin="$(dx_runtime_docker_require_bin)" || return 1` and then call `dx_runtime_docker_ssh_exec "$bin" …`. One `dx_runtime_docker_cli() { local bin; bin="$(dx_runtime_docker_require_bin)" || return 1; dx_runtime_docker_ssh_exec "$bin" "$@"; }` collapses the fifteen passthroughs to one line each and is the natural first commit of Muse A2's split. Red: record the fake-ssh transcript for every adapter operation before the change and assert byte-equality after.
- `dx_nix_volume_claim_*` (`dx-container.sh:301–378`, 78 lines of runtime-neutral local claim state) live in the file whose header says "Apple Container adapter"; move to `bin/lib/dx-claims.sh` when `refactor-v2-final.md` §4 touches them.
- Stale text: `bin/dx-lib.sh:2` still calls itself a "compatibility facade for host commands that have not yet migrated" (the migration finished); `bin/dx-nix-disk:21–24` describes a design that no longer exists.

### B. Guest layer (`G/bootstrap/`, `G/scripts/`)

#### B1 — `dx_ai_setup_credentials` replaces a corrupt `settings.json` with an empty file (High, verified)

**Evidence.** `G/scripts/dx-ai.sh:529–530`:

```sh
settings="$persist_home/.claude/settings.json"; [ -s "$settings" ] || printf '%s\n' '{}' > "$settings"
if ! jq -e '.statusLine' "$settings" >/dev/null 2>&1; then tmp="$settings.tmp.$$"; jq '. + {statusLine: …}' "$settings" > "$tmp"; mv "$tmp" "$settings"; fi
```

`jq -e '.statusLine'` fails both for "key absent" and "not JSON". On unparseable input the second `jq` writes zero bytes to `$tmp` and `mv` clobbers the user's Claude settings. The function is called in `||` context (`:655`), so `errexit` is suspended inside it. No test covers a non-JSON settings file.

**Red.** Fixture `$persist/.claude/settings.json` = `{not json`; run `dx_ai_setup_credentials "$persist" "$home"`; assert exit ≠ 0, stderr contains `Error:` naming the file, and the file's bytes are unchanged.

**Green.** Gate on `jq -e 'type=="object"'`; write to `$tmp`, require `[ -s "$tmp" ]`, `mv` only on success, else print and return 1.

**Refactor.** `dx_ai_merge_json_setting <file> <filter>`; reuse for the `.claude.json` seeding.

#### B2 — `prepare_nix_volume_impl` runs with `errexit` suspended and never checks `mkfs`, `truncate` or `mount` (High, verified)

**Evidence.** `G/bootstrap/base-and-storage.sh:961` `if prepare_nix_volume_impl "$@"; then` (Bash ignores `-e` inside a function invoked as an `if` condition). Unchecked privileged commands: `:925`, `:927` (`mkfs.btrfs`/`mkfs.ext4`), `:936` (`truncate -s "$disk_size" "$dev"`), `:938`, `:940`, `:948` (`mount -t "$fs_type" -o "$mount_opts" "$dev" /mnt/tmp-nix`). Only `umount` (`:920`) is checked.

**Why it matters.** A failed `mount` (a mount option rejected by an older kernel, a failed `mkfs`) still sets `DX_NIX_VOLUME_ROOT=/mnt/tmp-nix` (`:950`), and `prepare_nix_volume` prints "completed". `populate_prepared_nix_volume` then finds no `store` (`:655`) and `nix_seed_volume` tars the entire image store into the ephemeral rootfs before `umount "$volume_root"` (`:671`) aborts bootstrap with a misleading "not mounted". On the next restart `/mnt/tmp-nix/store` exists in the writable layer, so the guest is bricked until recreate. The suite stubs `mount(){ :; }` (four times in section 3, four in sourceable coverage) but never a *failing* mount, mkfs or truncate.

**Red.** Reuse the existing `findmnt`/`blkid`/`is_block_device`/`mkfs` stubs; add `mount(){ echo 'mount: wrong fs type' >&2; return 32; }` and a `tar(){ echo MUST-NOT-TAR; }` sentinel; call `prepare_nix_volume`; assert exit ≠ 0, stderr names `mount`, `DX_NIX_VOLUME_ROOT` is unset, and the sentinel is absent after a following `populate_prepared_nix_volume`.

**Green.** `|| { echo "Error: …" >&2; return 1; }` on each of the six lines.

**Refactor.** `dx_nix_format_device <dev> <fs>` and `dx_nix_mount <dev> <fs> <opts> <mountpoint>`; the wrapper at `:958–969` stays as the only timing layer. Constitution rule 3 applies: `mount`/`mkfs` need `CAP_SYS_ADMIN`, which the kcov container lacks, so record in `validation-matrix.md` that these stubs are validated on the live tier only, and pin the exact argv the stubs receive (the `MUST-NOT-MOUNT` sentinel style at `test_section3:1416` is the right shape).

#### B3 — `dx-ai`'s publication lock is a weaker copy of the launcher's, and every copy's stale takeover is non-atomic (Medium, verified)

**Evidence.** `G/scripts/dx-ai.sh:130–139` versus the launcher (`bin/lib/dx-ssh-common.sh:307–331`). The launcher reclaims an *ownerless* lock directory (`:319–322`) and writes the owner via tmp + `mv` (`:328–331`); `dx-ai` does neither, so a `SIGKILL` between `mkdir "$lock"` (`:130`) and `printf … > "$lock/owner"` (`:139`) leaves a directory every later run treats as held: a 30 s wait and "timed out" until someone `rmdir`s it by hand. In all three copies the stale takeover (`rm -f "$lock/owner"; rmdir "$lock"`, `dx-ai:134`, launcher `:317`, sync `:121`) is non-atomic: contender B, having read a stale owner, can delete A's freshly written owner and `rmdir` A's lock, yielding two holders.

**Red.** (a) fixture `mkdir "$lock"` with no owner and `sleep(){ :; }`; assert `dx_ai_lock_acquire "$lock" "$proc_root"` succeeds and writes an owner. (b) a `reclaim` primitive contract: given a stale owner it must rename the lock directory aside (`mv -T "$lock" "$lock.reclaim.$$"`) and return failure when the rename loses (simulate with a pre-existing target).

**Green.** Add the ownerless branch and tmp + `mv` owner write; do stale takeover by rename-then-remove.

**Refactor.** One contract fixture run against all three implementations (A3); move `dx-ai`'s copy to `G/scripts/lib/dx-lock.sh` (in kcov scope, unlike `scripts/*.sh`).

#### B4 — `dx-ai` fails silently on its staging and publish path, and never reclaims orphaned stages (Medium)

**Evidence.** Bare `return 1` with no message at `G/scripts/dx-ai.sh:127–129`, eleven times in `dx_ai_stage_generation` (`:242–262`) and eleven across `dx_ai_publish_pointer`/`dx_ai_publish_generation` (`:471–503`); `dx_ai_main` propagates with no text (`:646`, `:651`). `dx_ai_validate_publish_generation "$stage" || return 1` (`:495`) fires *after* a successful multi-minute `nix profile add` if any `profile/bin/<tool>` is missing, and the user sees exit 1 and nothing else; the only test of the path discards output (`test_section17_dx_ai_runtime.sh:164`). Stages are named `.staging-<id>` (`:245`); `dx_ai_collect_generations` iterates `"$state/generations"/*` (`:480`), which never matches dot-names, and cleanup is trap-only (`:627`), so a `SIGKILL`/OOM/host stop leaves the stage, whose `profile-1-link` Nix has registered under `/nix/var/nix/gcroots/auto`: every orphan pins a full closure across every `nix-collect-garbage`. `dx_ai_collect_generations` has no direct test. `dx_ai_publish_pointer:472–473` refuses a leftover `.current.<pid>` silently, and PIDs restart per container boot.

**Red.** (1) With the existing `nix()` stub, delete one tool from the staged profile; run `dx_ai_main`; assert stderr contains `Error:` and the missing path. (2) Fixture `generations/.staging-old/profile -> /nix/store/x`; run collection under the lock; assert `.staging-old` is gone.

**Green.** A `dx_ai_fail <msg>` helper at each return; collection removes every `.staging-*` other than the current run's (safe by construction: staging only ever happens under the publication lock).

**Refactor.** B7.

#### B5 — Deny-list patterns are glob-expanded against the current directory before matching (Medium, reproduced; extends Muse B3 and Astra F6)

**Evidence.** `G/scripts/lib/dx-persist-backup-select.sh:67` `for pattern in $DX_PBS_BUILTIN_PATH_DENY $DX_PBS_EXTRA_DENY; do` and `:82` `for pattern in $DX_PBS_BUILTIN_COMPONENT_DENY; do`. A `for` word list undergoes pathname expansion. The `case … in $pattern)` at `:73` and `:86` is safe (case patterns are not expanded), and the `SC2254` comment is right about *that* line only; nothing sets `-f`. **Reproduced:** from a directory containing `result-bin`, `dx_pbs_path_denied p/result-abc` returns 1 (not denied) because `result-*` expanded to `result-bin`; from `/` it returns 0. The selector never `cd`s, so its working directory is whatever `container exec`/`docker exec` supplies. The same list is hand-expanded as `find` predicates at `:228–235`, `:237–244`, `:434–440`, `:442–448`; `DX_PBS_EXTRA_DENY="$*"` at `:378` is the word-splitting half Astra F6 names. Bash 3.2 applies: `bin/lib/dx-backup.sh:24` sources this file on the macOS host and `run-bash32-tests.sh:13–15` runs it under 3.2. Indexed arrays, `+=` and the `"${a[@]+"${a[@]}"}"` idiom (already used at `:234`) are 3.2-safe.

**Red.** (a) `cd` into a temp dir containing `result-bin`; assert `dx_pbs_path_denied "p/result-abc"` returns 0. (b) An equivalence property: for a fixture containing every deny name, `dx_pbs_walk_repo_files` and `dx_pbs_list_outside_repos` list exactly the entries `dx_pbs_path_denied` accepts. (c) An extra pattern containing a space is honoured as one pattern.

**Green.**

```sh
DX_PBS_BUILTIN_COMPONENT_DENY=(node_modules target .direnv result 'result-*' __pycache__ .cache dist build .venv .tox .pytest_cache .mypy_cache .pnpm-store '.Trash-*' .tmp)
DX_PBS_BUILTIN_PATH_DENY=('home/dx/.local/state/dx-ai/generations/*/profile' home/dx/.gemini/antigravity-cli)
DX_PBS_EXTRA_DENY=()          # dx_pbs_list_driver: shift 2; DX_PBS_EXTRA_DENY=("$@")
DX_PBS_COMPONENT_PRUNE=()
for _p in "${DX_PBS_BUILTIN_COMPONENT_DENY[@]}"; do
    [ "${#DX_PBS_COMPONENT_PRUNE[@]}" -eq 0 ] || DX_PBS_COMPONENT_PRUNE+=(-o)
    DX_PBS_COMPONENT_PRUNE+=(-name "$_p")
done; unset _p
```

then iterate `"${DX_PBS_BUILTIN_PATH_DENY[@]}" "${DX_PBS_EXTRA_DENY[@]+"${DX_PBS_EXTRA_DENY[@]}"}"` and use `find … \( "${DX_PBS_COMPONENT_PRUNE[@]}" … \) -prune -o …` at all four sites.

**Refactor.** Delete the four literal `find` blocks; the module comment's "Bash 3.2 subset" stays true.

#### B6 — `refactor-v2-final.md` is the right plan, stale in seven checkable ways (Medium)

The plan's direction (thread identity plus publish decision plus profile target; mode-tagged volume record; one claim epilogue) is correct. Before Phase 1 is executable:

1. Its line references are from the 695-line file; the file is 1,004 lines. Today: identity assignments `:531`, `:541`, `:656`; the skip `:538`; early return `:625`; the `unset` `:633`; restore `:408`; roots `:462`.
2. Phase 1's "fix `local expected="$(…)"` at `:283`" is already done (`:283–284`); a grep for `local \w+="?\$\(` over all guest shell finds nothing. Drop the item.
3. Contract 3 has two modes; the code has three. Direct-volume sets `DX_NIX_VOLUME_ROOT=/nix` and `DX_NIX_VOLUME_IN_PLACE=true` (`:845–847`, read at `:640`). Add `mode=in-place` (requires `root=/nix`, rejects device, filesystem type and options) or the record rejects every QNAP boot. **Red:** a record-reader test with `mode=in-place`.
4. Contract 1 misses a fourth role: `DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$roots_identity" nix_install_image_essentials_root …` at `:807` and `:827` smuggles the value as a positional through the environment. A real fourth argument removes it, and the "clean skip writes no marker" gate must be mode-aware (direct-volume never writes `.dx-image-store-identity`, `:744–746`).
5. No contract covers the durable-identity protocol: `DX_NIX_DURABLE_UID/GID` and `DX_NIX_IDENTITY_MIGRATION_REQUIRED` are set in `base-and-storage.sh:236–267`, mutated in `system.sh:158–159,179–180`, consumed at `base-and-storage.sh:286,310,324`; `DX_PERSIST_IDENTITY_MIGRATION_REQUIRED` (`:260–261`) is write-only in production. Add contract 5: `record_durable_nix_identity` returns a `uid:gid` plus `migrate=<bool>` record, `create_user` takes it and returns the final identity.
6. The test-convenience owner fallback in production (`:651–652`, `:768–769`, `id -u dx 2>/dev/null || printf '%s' 0`) goes with the same threading: `bootstrap_main` resolves the owner once after `create_user` and passes it.
7. Phase 2's deletion of `setup_nix_volume{,_impl}` (`:974–988`) is still correct: no production caller, only nine dead-code probes in `test_sourceable_coverage.sh:691–772` that keep the ratchet green.

Definition-move matrix for Phase 4 (source order top to bottom after `common.sh`), along the mode/concern seams the file's own growth exposed (direct-volume `684–849` and the collision check `546–615` are already self-contained):

| Module | Functions (current lines) | Depends on |
| --- | --- | --- |
| `nix-identity.sh` | `record_durable_nix_identity` 230–270, `migrate_durable_nix_identity_if_needed` 278–325, `publish_nix_volume_image_identity` 692–706 | common |
| `nix-profile.sh` | 373–393, 395–402, 408–457 | common |
| `nix-import.sh` | 66–228, 337–367, 462–634 | identity, profile (via the globals Phases 1–2 remove) |
| `nix-volume-apple.sh` | `is_block_device` 64, apple body of `prepare_nix_volume_impl` 873–956, remount tail of `populate_prepared_nix_volume` 648–682 | import, identity |
| `nix-volume-direct.sh` | 837–849, 762–830 | import, identity |
| `nix-volume.sh` | dispatch 864–872, 636–647, `prepare_nix_volume` 958–969 | apple, direct |
| stays (rename `base.sh`) | `install_essentials` 4–42, `link_system_bash` 51–57, `configure_single_user_nix` 991–1004 | common |
| delete | 974–988 | — |

#### B7 — `dx-ai.sh`: the split's seams, the ×7 release epilogue and the ×4 library loader (Medium; extends Muse B7)

**Evidence.** Responsibilities by line: library loaders `23–60`, `165–180`; usage `62–76`; process identity and lock `87–142`; `agy` pin `151–157`, `203–238`; generation staging/validation/publish/GC/recover `240–264`, `414–517`; cache-miss policy `274–406`; install `408–412`; credentials/keyring/herdr post-install `519–587`; verify `589–607`; orchestrator `609–661`. The release epilogue `dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM` appears at `:630`, `:636`, `:643`, `:644`, `:646`, `:651`, `:654`; the fifteen-line three-candidate library loader appears four times (`dx-ai.sh:23–38`, `:45–60`, `:165–180`, `G/scripts/dx-keyring.sh:14–29`). `scripts/*.sh` is exempt from kcov while `scripts/lib/` is in scope, so the split is also how this logic enters the gate.

**Red.** For each injected failure (stage, update, ensure-cached, install, publish) assert after `dx_ai_main` that `[ ! -d "$lock" ]` and `[ ! -e "$stage" ]`; lock release on failure is not asserted today.

**Green.** `dx_ai_run_locked <lock> <fn> args…` that acquires, runs and releases once; `dx_ai_load_library <probe-fn> <basename>` used by all four loaders.

**Refactor.** `scripts/lib/dx-ai-lock.sh` (87–142, unified with A3/B3), `dx-ai-generation.sh` (240–264, 414–517), `dx-ai-pin.sh` (151–157, 203–238), `dx-ai-cache-policy.sh` (274–406), `dx-ai-post-install.sh` (519–587); `dx-ai.sh` keeps usage and main.

#### B8 — `bootstrap_main`'s phase order is asserted by comparing grep line numbers, and the function cannot be run (Medium)

**Evidence.** `tests/test_section3_bootstrap.sh:1433–1444` greps line numbers of phase names and compares them; `G/bootstrap.sh:33` `exec "$(command -v sshd)" -D -e -p 2222` makes `bootstrap_main` unrunnable in a test. It is the only guest test that parses source text (besides the deliberate `DX_AI_TOOLS` sync contract).

**Red.** Source `bootstrap.sh`; shadow every phase function with `name(){ printf '%s\n' "$FUNCNAME" >> "$log"; }`; call `bootstrap_phases`; assert the log equals the documented order and that `verify_remount_prerequisites` sits between populate and restore.

**Green.** Split `bootstrap_phases()` (lines 10–30) from `bootstrap_main()` (env, phases, exec).

**Refactor.** Delete the grep test; the `Bootstrap phase: … completed in Ns` lines become assertable per phase.

#### B9 — "Relocate a live directory into `/persist` and link" is implemented four times, and AI-credential linking twice with a behavioural divergence (Medium)

**Evidence.** `G/bootstrap/persistence.sh:139–165` (gh), `:284–324` (herdr config), `:327–356` (herdr state, byte-identical to the previous block except names), `G/scripts/lib/dx-opencode-persistence.sh:72–100`. AI credentials: `G/bootstrap/activation.sh:275–287` (root, `run_as_dx "ln -sfn …"`, no `-T`) versus `G/scripts/dx-ai.sh:523–528` (dx, `ln -sfnT`). When `~/.claude` is a real directory, `ln -sfn` creates `~/.claude/.claude -> /persist/…` and reports success; `ln -sfnT` fails, but in `||` context (`:655`) the failure is swallowed and the function returns 0.

**Red.** Fixture with `$home/.claude` as a real, non-empty directory; run both entry points; assert either relocation into `$persist/.claude` (conflicts renamed as `:80–81` already does) or a loud non-zero failure, and that the end state has `$home/.claude` as the intended symlink.

**Green.** One `dx_persist_relocate_dir <live> <persistent> <backup-parent> <label>` in `scripts/lib` (root/dx-agnostic; ownership fix-up via an optional callback, as `dx_opencode_prepare_directory` already does with `declare -F`).

**Refactor.** gh, herdr ×2, opencode and both AI-credential sites call it; delete the copies.

#### B10 — 23 `run_as_dx` sites interpolate paths into a `bash -c` string; the argv form already exists (Low–Medium; extends Astra F8 and D6 to the guest)

**Evidence.** `G/bootstrap/persistence.sh:165` `run_as_dx "ln -sfnT '$persistent_gh' '$home_gh'"`, `:324`, `:356`; `G/bootstrap/activation.sh:87,159,168,177,184,238,241,284–287`; `G/bootstrap/common.sh:97,103`; `G/bootstrap/base-and-storage.sh:134,537,591,822`. `run_as_dx_with_timeout` (`common.sh:206–212`) is already the argv form; `run_as_dx` (`:199–204`) is the only reason `bash -l -c` is involved, and `PATH` is set explicitly anyway.

**Red.** A fake `setpriv` on `PATH` that records `"$@"`; call `setup_gh_persistence` with a fixture path containing a space and an apostrophe; assert the recorded argv holds the path as one element.

**Green.** `run_as_dx_argv() { setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" "$@"; }` and migrate the twelve `ln`/`test`/`mkdir` sites.

**Refactor.** Keep the string form only for the `nix …` sites that want a login shell, and pass `bash -lc` explicitly there.

#### B11 — Smaller guest items (Low)

- kcov line attribution shapes production code: twelve "kcov" comments, four single-line `done < <(…)` loops (`base-and-storage.sh:492,527,613,816`), `KCOV_SUBSHELL_TERMINATOR` markers. One shape leaks: `G/bootstrap/herdr-config.sh:48` `exec 3< "$template"` … `:91` `exec 3<&-` with a `return 1` at `:83` inside the loop leaves fd 3 open in the bootstrap process, inherited by `exec sshd`; the flush calls at `:51`, `:63` are unchecked, so a duplicate scalar prints an error and parsing continues. The guest is Bash 5, so `mapfile -t lines < "$template"` is fine here (the 3.2 rule binds `bin/` only, `refactor-v2-final.md:46–51`). Red: on the isolated Linux runner, a duplicate-scalar template returns non-zero and `[ ! -e /proc/$$/fd/3 ]`.
- Dead and write-only artefacts: `setup_nix_volume{,_impl}` (`base-and-storage.sh:974–988`); `DX_PERSIST_IDENTITY_MIGRATION_REQUIRED` (`:260–261`); the `/etc/fstab` block (`:674–681`, nothing runs `mount -a`); the `export`s at `:847`, `:954` (same shell reads them).
- One-liners: `materialize_auth_files` uses `rm "$file"; mv "$tmp" "$file"` (`system.sh:122–123`) where `mv -f` alone is atomic; `configure_ssh:321–322` uses `DX_PUB_KEY` as a regex and rewrites `authorized_keys` wholesale, dropping user-added keys; `dx_keyring_start:189–190` prints "started" when `gnome-keyring-daemon` failed; `NU_PATH` at `activation.sh:315` is an unintended global.

**Testability of the guest (what would let these be unit-tested).** The established seam is function shadowing of binaries (section 3 shadows `chown` ×21, `run_as_dx` ×20, `nix` ×10, `install` ×9, `stat` ×8, `findmnt` ×6, `mount`/`umount` ×4 each, `mkfs.*` ×3, `truncate` ×3). A `DX_MOUNT_CMD` variable would add nothing over that. What is missing is different: hardcoded system paths force tests to intercept commands instead of paths (`populate_prepared_nix_volume`: `/nix` `:672`, `/etc/fstab` `:674–681`, `/mnt/tmp-nix` `:947–950`, `/var/lib/dx-nix-raw` `:874`; `configure_single_user_nix` `:993–1003`; `configure_release_identity` `system.sh:41`; `configure_timezone` `:90–91`; `create_user` sudoers `:193–203`; `configure_ssh` `:315–364`; `configure_guest` `activation.sh:230–241,257–287,315–322`; `setup_tmux_persistence` `persistence.sh:174`). The repository already has the right pattern in three styles (`setup_persist "${1:-/persist}"`, `dx_persist_host_keys /etc/ssh /persist/etc/ssh`, `DX_AUTH_ROOT`/`DX_LINK_ROOT`/`DX_NIX_OWNERSHIP_ROOT`); pick positional-with-production-default everywhere. Real-boundary validation (constitution rule 3) exists for `nix copy` (`test_nix_store_import.sh:582–604`) and persist storage (`test_section16:193`); none for `setpriv`/`chown`/`mount`. The kcov runner is root inside a container, so `run_as_dx` and `chown` stubs can be validated there once against a real unprivileged uid behind a `requires_root` gate; `mount`/`mkfs` stay live-only, and `validation-matrix.md` should say so.

### C. Nix (`G/flake.nix`, Home Manager modules, NixVim)

Overall the flake is idiomatic and should be preserved as-is in its bones: `forEachSystem = genAttrs supportedSystems` over `nixpkgs.lib` with no flake-utils dependency (`flake.nix:37–38`); `homeConfigurations."dx-<system>"` plus a `dx` alias that is the *same* derivation (`:255–257`); `builtins.fromJSON (builtins.readFile ./pins/agy.json)` with null-by-construction for unsupported systems (`:40`, `:137–139`, `:183–185`) and SRI hashes; `pkgs.formats.toml` for tinty (`theme.nix:49,81–82`); `lib.hm.dag.entryAfter [ "linkGeneration" ]` (`:115`); `programs.tmux` fully typed; NixVim through `plugins.*`, `opts`, `keymaps` with `action.__raw`; bootstrap invoking the flake by locked reference (`common.sh:88`, `activation.sh:39–46`); no `builtins.currentSystem`, no `--impure`, no `fetchTarball`, path literals throughout. The findings are about what is *not checked* and about three places where hand-rolled code sits beside a typed option.

#### C1 — Home Manager activation packages are not flake `checks`; the CI Nix gate asserts nothing about them (High, verified)

**Evidence.** `.github/workflows/ci.yml:34` runs `nix flake check --no-build`; `G/flake.nix:244–258` exports only `devShells`, `packages` and `homeConfigurations` (confirmed with `nix flake show`). `nix flake check` does not walk `homeConfigurations` (its "checking flake output 'homeConfigurations'…" line asserts nothing). Verified in a scratch copy: `homeConfigurations.broken = throw "BOOM"` passes `nix flake check --all-systems`. The x86_64 QNAP configuration and the Apple `ai-tools` closure are therefore evaluated for the first time on a live guest at boot (`G/bootstrap/activation.sh:39–46`). `tests/test_section5_nix.sh:79–80` evaluates the ARM tree but with `|| true` and stderr discarded, so an evaluation error surfaces as a misleading "same derivation" failure.

**Red.** Replace `test_section5_nix.sh:79–85` with a loop over `supportedSystems` that requires `nix eval --raw "$CONTAINER_DIR#checks.$system.home-activation.drvPath"` to succeed *without* `|| true`, plus `checks.$system.ai-tools`. Fails today: no `checks`.

**Green.**

```nix
# inside perSystem, after packages and homeConfiguration are bound:
checks = {
  home-activation = homeConfiguration.activationPackage;   # full HM evaluation per system
  inherit (packages) ai-tools;                              # the agy derivation per system
  alias-is-identity =
    assert self.homeConfigurations.dx.activationPackage.drvPath
        == self.homeConfigurations."dx-aarch64-linux".activationPackage.drvPath;
    pkgs.emptyFile;
};
# top level:
checks = nixpkgs.lib.mapAttrs (_: out: out.checks) perSystemOutputs;
```

CI: `nix flake check --no-build --all-systems …` (13 s warm here). `tests/test_section0_lint.sh:29` asserts the literal `nix flake check --no-build` and changes with it.

**Refactor.** Delete the now-redundant `nix eval` calls at `test_section5_nix.sh:54–77`; keep section 5's static lock assertions.

#### C2 — Evaluation warnings are not gated: three renamed options, a package removal notice, and a second nixpkgs instance for NixVim (Medium, verified)

**Evidence** (all reproduced here with `nix eval --offline`):

- `trace: warning: The option programs.git.userEmail … has been renamed to programs.git.settings.user.email`, likewise `userName` and `extraConfig` (`G/home/tools.nix:8`). Renamed options are removed a release later.
- `evaluation warning: The nixpkgs.source default value has been affected by your flake input follows … remove inputs.nixvim.inputs.nixpkgs.follows or explicitly define nixpkgs.source`: `G/flake.nix:196` builds nvim with `nixvim.legacyPackages.${system}.makeNixvim`, and `G/nixvim.nix:1–3` takes `pkgs` and never uses it, so NixVim instantiates a third nixpkgs per system (six per `--all-systems` evaluation) with a different `allowUnfree` from Home Manager's.
- `evaluation warning: Package 'gemini-cli-0.47.0' … removal: … Gemini CLI was replaced by Antigravity CLI` (pulled by `flake.nix:180`). `G/scripts/dx-ai.sh:7` `DX_AI_TOOLS` demands `gemini`, and `dx-ai.sh:270` runs `nix flake update nixpkgs-unstable` **on the guest**: the next unstable bump turns `ai-tools` into an evaluation error at `dx-ai update` time, on the guest, with nothing in CI having warned.

**Red.** A warnings contract in section 5: evaluating `checks.<system>.home-activation` and `checks.<system>.ai-tools` must print zero lines matching `^(trace: warning|evaluation warning)`. Prints five today.

**Green.** `programs.git.settings = { user.email = …; user.name = …; … }`; `nvim = nixvim.legacyPackages.${system}.makeNixvimWithModule { inherit pkgs; module = ./nixvim.nix; }` with `nixvim.nix` reduced to a plain module (`{ imports = […]; viAlias = true; vimAlias = true; }`), which the pinned NixVim's `makeNixvimWithModule` sets as `nixpkgs.pkgs = lib.mkDefault pkgs` and so reuses Home Manager's instance and silences the warning; for gemini, either pin it out of `aiPackages`, `DX_AI_TOOLS` and `bin/dx-herdr`'s message together (`test_refactor_contracts.sh:169–170` ties them) or make the nixpkgs `problems` setting a hard error so the flake refuses to evaluate rather than the guest discovering it.

**Refactor.** A scheduled CI job that runs `nix flake update nixpkgs-unstable` in a scratch copy and evaluates `checks.*.ai-tools`, mirroring what the guest does at `dx-ai.sh:270–319`.

#### C3 — Four package lists, five duplicated packages, one duplicate file definition, five unverified commands (Medium, verified; extends Muse B4)

**Evidence.** `G/flake.nix:60–95` `dxPackages`, `:106–121` `bootstrapEssentials`, `:179–193` `aiPackages`, and a fourth neither review named: `G/home.nix:8–13` `home.packages = with pkgs; [ starship fish nushell nodejs ]`. Evaluating `config.home.packages` shows `fish`, `git`, `man-db`, `nushell` and `tmux` each **twice** (the `programs.*` modules already add them); `starship` is a bare package with no `programs.starship`. `G/home.nix:21` and `G/home/tools.nix:158–159` both define `home.file.".local/lib/dx/dx-keyring.sh".source` (it evaluates only because both resolve to the same path). The inventory contract (`G/scripts/dx-verify-inventory.sh:9–21`, "keep in sync by hand") is one-directionally stale: all 21 inventory commands have a provider, but the user-facing commands `man`, `tput`/`clear`, `starship`, `node`/`npm`/`npx`, `fish` and `nu` are installed and never verified. `test_refactor_contracts.sh:154,201` scrape the flake with `sed` to check the other two lists.

**Red.** `checks.<system>.inventory`, reverse direction: every user-facing command declared in Nix must be in the printed inventory. Fails today for the five above.

**Green.** One mapping consumed by both sides:

```nix
# G/guest-tools.nix — nixpkgs attribute -> the user-facing commands it must provide ([] = library/data only)
{ ripgrep = [ "rg" ]; go-task = [ "task" ]; openssh = [ "ssh" ]; man-db = [ "man" ]; cacert = [ ]; nix-direnv = [ ]; /* … */ }
```

```nix
guestTools = import ./guest-tools.nix;
dxPackages = map (n: pkgs.${n}) (lib.attrNames guestTools);
requiredInventory = lib.concatLists (lib.attrValues guestTools) ++ [ "nvim" ];
checks.inventory = pkgs.runCommand "dx-inventory" { env = packages.default; } ''
  for t in ${lib.escapeShellArgs requiredInventory}; do
    [ -x "$env/bin/$t" ] || { echo "missing: $t" >&2; exit 1; }
  done; touch $out
'';
```

and hand the list to the script through `runtimeEnv` (C5) instead of the literal at `dx-verify-inventory.sh:21`. This check builds `dx-tools` (substitutable on the x86_64 runner), so run it as `nix build .#checks.x86_64-linux.inventory` beside the eval-only gate.

**Refactor.** Remove `fish`/`nushell` from `home.nix:10–11`; move `starship` to `programs.starship` (C4); delete `home.nix:21`; retire the `sed` scrapes in favour of `nix eval --json` contracts over `packages.*.bootstrap-essentials.paths`.

#### C4 — Shell integration is hand-rolled three times where typed Home Manager options exist (Medium; verified against the pinned release-26.05 modules)

**Evidence.** `G/home/shell.nix:20–33` (bash), `:64–78` (fish), `:103–111` (nushell) each re-implement the yazi `y` wrapper, the direnv hook and `starship init`; `PATH` is prepended at `:7`, `:61`, `:124` and again in `home.sessionVariables.PATH` at `:143`; `:98–101` assigns the whole nushell `$env.config` record; `G/home/tools.nix:115–118` is raw `lazygit/config.yml` text. Already drifted: bash guards with `command -v`, fish with `type -q`, nushell has neither starship nor direnv and no comment saying that is intended. In the pinned Home Manager: `programs.starship` writes `starship.toml` only when `settings`/`presets` are non-empty (so `enable = true` does not collide with `dx-theme-write-tool-themes.sh` owning that file); `programs.yazi.shellWrapperName`; `programs.direnv.nix-direnv.enable`; `programs.lazygit.settings`; `home.sessionPath` renders through `prependToVar` (prepends, so the `dx-ai` profile still wins); `programs.nushell.settings` are flattened and assigned one by one (no clobber). `tests/test_section6_tools.sh` holds 49 text assertions over these files.

**Red.** A behavioural check over the built file tree, no VM needed:

```nix
checks.bash-integration = pkgs.runCommand "bash-integration"
  { nativeBuildInputs = [ pkgs.bashInteractive pkgs.direnv pkgs.starship pkgs.yazi ]; } ''
  export HOME=$(mktemp -d); cp -r ${homeConfiguration.config.home-files}/. $HOME/
  bash -ic 'declare -F y _direnv_hook >/dev/null && [ "$STARSHIP_SHELL" = bash ]' && touch $out
'';
```

Passes for bash today; the fish and nushell variants are the Red (nushell fails).

**Green.**

```nix
programs.starship.enable = true;                                  # settings deliberately empty: dx-theme owns starship.toml
programs.direnv = { enable = true; nix-direnv.enable = true; };   # replaces flake.nix:86-87 bare packages
programs.yazi = { enable = true; shellWrapperName = "y"; };
programs.nushell.settings = { show_banner = false; edit_mode = "vi"; };
programs.lazygit.settings.gui.nerdFontsVersion = "3";
home.sessionPath = [ "/persist/home/dx/.local/state/dx-ai/current/profile/bin" "$HOME/.local/bin" ];
```

Set `enableNushellIntegration` explicitly on all three so the decision is recorded rather than inherited.

**Refactor.** Delete the per-shell blocks and the `sessionVariables.PATH` line; replace `test_section6_tools.sh:222,224` with the check above.

#### C5 — Guest scripts are copied with `home.file` and depend on ambient `PATH`; `writeShellApplication` gives `runtimeInputs` and a ShellCheck gate (Medium)

**Evidence.** `G/home/tools.nix:134–137,161–182` and `G/home/theme.nix:90–113`: every command is `home.file.".local/bin/x" = { executable = true; source = ../scripts/x.sh; }` with `#!/usr/bin/env bash`. `G/scripts/dx-theme-write-tool-themes.sh:9–10` hand-rolls `runtimeInputs` (`if ! command -v tinty … && [ -x "$HOME/.nix-profile/bin/tinty" ]; then PATH=…`). Whether `dx-theme` finds `tinty` depends on which shell rc ran first when tmux's `run-shell -b` (`tools.nix:81`) or the activation hook (`theme.nix:115–127`) invokes it. `scripts/*.sh` is exempt from kcov and from any ShellCheck-in-Nix. The pinned nixpkgs `writeShellApplication` takes `runtimeInputs`, `runtimeEnv`, `bashOptions` and runs ShellCheck in `checkPhase`.

**Constraint to keep.** `dx-ai.sh:18–30` must stay loadable raw from the bootstrap volume, and tests source the raw files: keep `scripts/*.sh` as the source of truth and wrap only the installed copy; source-only libraries under `.local/lib/dx/` stay `home.file.source`.

**Red.** `checks.scripts-hermetic`: run `${home-files}/.local/bin/dx-theme-restore` (and the copy hook) with `PATH=/var/empty` and `HOME=$TMP`; fails today on `tinty: command not found`.

**Green.**

```nix
let dxScript = name: file: runtimeInputs: pkgs.writeShellApplication {
  inherit name runtimeInputs;
  text = builtins.readFile file;
  bashOptions = [ ];       # the scripts set their own -e/-u; keep behaviour identical
};
in {
  home.file.".local/bin/dx-theme".source =
    lib.getExe (dxScript "dx-theme" ../scripts/dx-theme.sh [ pkgs.tinty pkgs.jq pkgs.gnused ]);
}
```

If 26.05's ShellCheck 0.11 trips the `x="$(source f)"` crash on one script, set `checkPhase = ""` for that script rather than abandoning the mechanism.

**Refactor.** Delete `dx-theme-write-tool-themes.sh:8–11`; the `home.file` blocks collapse to one `lib.mapAttrs'` over a `{ name = { file; deps; }; }` table.

#### C6 — `agy` pin: consumption is idiomatic, but the ARM pin is frozen by a value test (Medium; corrects Muse B6)

**Evidence.** `tests/test_section6_tools.sh:210–212` asserts the literal aarch64 version `1.0.5`, its URL and its hash; nothing asserts the x86_64 entry (`1.2.12`, `pins/agy.json:7–11`). `dx-ai update` on the QNAP can move the x86_64 pin freely while moving the aarch64 pin fails CI: the skew is the only state CI accepts. Derivation noise: unused `rec` at `flake.nix:139`; a custom `unpackPhase` (`:158–162`) re-implementing stdenv's `.tar.gz` handling; no `meta` (`license`, `platforms`, `mainProgram`, `sourceProvenance`) on a prebuilt unfree binary; `buildInputs = [ pkgs.stdenv.cc.cc ]` (`:156`) where the autoPatchelf convention is `stdenv.cc.cc.lib`.

**Red.** Replace the value assertions with a shape contract, as a pure Nix check:

```nix
checks.agy-pin-shape = let
  arch = { aarch64-linux = "linux-arm"; x86_64-linux = "linux-x64"; };
  ok = s: p: p == null || (lib.hasPrefix "sha512-" p.hash && lib.hasInfix p.version p.url && lib.hasInfix arch.${s} p.url);
in assert lib.all (s: ok s (agyPin.${s} or null)) supportedSystems
      && lib.all (s: lib.elem s supportedSystems) (lib.attrNames agyPin);
   pkgs.emptyFile;
```

**Green.** Slim the derivation: drop `rec` and `unpackPhase`, set `sourceRoot = "."`, add `meta = { mainProgram = "agy"; license = lib.licenses.unfree; sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]; platforms = lib.attrNames (lib.filterAttrs (_: v: v != null) agyPin); }`, so "wrong arch" is an evaluation error even if the `null` guard is bypassed.

**Refactor.** Record whether the version gap is intentional (a `"note"` key the shape check ignores); `dx-ai.sh:229–236` already merges per-system keys, so unifying is one `dx-ai update` on the Apple guest once the test no longer forbids it.

#### C7 — NixVim: raw Lua where typed modules exist, one double `setup()`, one no-op (Low)

**Evidence.** `G/nvim/extra_plugins/ts-context-commentstring.nix:7–14` calls `require('Comment').setup({ pre_hook = … })` after `plugins.comment.enable` (`nvim/plugins/comment.nix:2–4`) already emitted `require('Comment').setup(...)`; the second call silently replaces whatever `plugins.comment.settings` produces. The pinned NixVim has `plugins.ts-context-commentstring` and `plugins.comment.settings.pre_hook` with exactly this example. `G/nvim/plugins/vim-tmux-navigator.nix:14,19` uses `extraPlugins` plus a global where `plugins.tmux-navigator.settings.no_mappings` exists. `G/nvim/extra_plugins/undotree.nix:3` `plugins.undotree.enable = false;` is a no-op and misleading (NixVim's module is a different plugin). `outline.nix:4–13` `buildVimPlugin { name = …; doCheck = false; }` is justified (no module) but should use `pname`/`version` and keep the require-check unless it fails.

**Red.** NixVim's own harness: `nixvim.lib.${system}.check.mkTestDerivationFromNixvimModule` with `extraConfigLua = "assert(require('Comment.config'):get().pre_hook, 'pre_hook lost')"` as `checks.nvim`; it fails once the raw second `setup` is removed unless the typed option carries it. This also replaces the source-text assertions at `test_section8_nixvim_config.sh:19–22`.

**Green.** `plugins.ts-context-commentstring.enable = true; plugins.comment.settings.pre_hook = "require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook()"; plugins.tmux-navigator = { enable = true; settings.no_mappings = 1; };`

**Refactor.** Delete `undotree.nix:3`; make "no upstream module" the stated admission criterion for `extra_plugins/`.

#### C8 — `allowUnfree = true` on both nixpkgs instances; six instantiations per full evaluation (Low)

`G/flake.nix:49–57` imports nixpkgs twice per system with `config.allowUnfree = true`; the stable instance needs none of it (`dxPackages` and `bootstrapEssentials` are free); NixVim adds a third (C2). Red: in a scratch copy, `packages.x86_64-linux.default` still evaluates with `allowUnfree = false`, and `ai-tools` fails naming the unfree package. Green: stable as `nixpkgs.legacyPackages.${system}`; unstable with `config.allowUnfreePredicate = p: builtins.elem (lib.getName p) [ … ]`, which also documents which packages are unfree.

#### How the Nix side gets behavioural tests

1. **Eval-only `checks`, `--all-systems`** (C1): `home-activation`, `ai-tools`, `alias-is-identity`, `agy-pin-shape`, plus the warnings contract (C2). Pure, seconds, no build.
2. **`runCommand` checks over `config.home-files`** (C3–C5): inventory, shell integration, hermetic scripts, shebangs (`head -1 ${home-files}/.local/bin/* | grep -v '^#!/nix/store'` once wrapped). `nix build .#checks.x86_64-linux.<name>` on the Linux runner; substitution makes them cheap.
3. **NixVim's harness** (C7): `mkTestDerivationFromNixvimModule` launches headless nvim.
4. **Pure-function unit tests** with `nix-unit` or `namaka` (both in the 26.05 pin): `dxThemes` (`theme.nix:8–42`: every alias maps to a `base16-` scheme, `preferredSchemes` has no duplicates), the `agy` pin shape, the `guest-tools.nix` mapping.
5. **Lint as `checks`**: `statix`, `deadnix`, `nixfmt` (the RFC formatter; `nixfmt-rfc-style` is not a 26.05 attribute), or `treefmt` wrapping all three.
6. **A VM test** (`pkgs.testers.runNixOSTest`) for bootstrap ordering is feasible on the Ubuntu runner (KVM) but not on the Apple host; it belongs after D3, since it moves behaviour out of kcov's scope.

Keep the two live gates (`test_section5_nix.sh:101–160`, `test_section8:97+`) as the only places a real guest is required.

**`declarative-nix-plan-a.md`, in one line:** its line references predate the arch-neutral refactor but the substance holds. Adopt #16 first (as C1; its "evaluated by nothing" is wrong for ARM and right for x86_64), then #17, #5 (both halves: `programs.btop` defines only `text`, so `xdg.configFile."btop/btop.conf".force = true` merges beside it), #6 (as C4), #7 (verified: `sessionPath` prepends), #1; #13 is idiomatic (26.05's ShellCheck is 0.11, so use an older input or `overrideAttrs`); defer #8 (a format-preserving TOML merge is not a Nix job); #12 is D3.

### D. Tests and coverage (`tests/`)

Each count below was computed with a stated `grep` and is reproducible.

#### D1 — Assertion results are process-local counters, and there is no capture helper (High)

**Evidence.** `tests/test_helpers.sh:175–185`: `test_pass`/`test_fail` increment `TESTS_PASSED`/`TESTS_FAILED` in the calling shell, so an assertion inside `( … )` is lost; `test_refactor_contracts.sh:118–138` exists only to prove that bug can still be caught. The idioms this forces: 146 `if (` blocks in `test_docker_runtime_adapter.sh`, 130 `[ "$?" -eq 0 ] && test_pass` lines, and `&& test_pass "X" || test_fail "X"` 176 times across the suite (1,066 `test_fail` strings, almost all copies of the adjacent `test_pass`). There is no helper that runs a command and captures stdout, stderr and exit status; each suite re-invents `set +e; out="$(cmd 2>&1)"; rc=$?; set -e` (`test_section23_herdr.sh:51–56`, `test_dx_backup.sh:133–136`, `test_dx_restore.sh:106–109`). Only ~254 of 1,066 `test_fail` calls embed captured output, so a Red failure usually prints its label and nothing else. Seven suites define their own vocabulary (`expect_ok`/`expect_reject` byte-identical in `test_refactor_state_machines.sh:23–24` and `test_docker_runtime_adapter.sh:38–39`; `expect_failure` in section 17; `check`/`reject` with a private counter and a different exit path in `test_refactor_contracts.sh:7–8`; `[PASS]`/`[FAIL]` in `tests/lib/audit-flake-lock.sh:46–51`): four output formats and three exit-code conventions.

**Red.** `tests/test_harness.sh` (tier unit): `expect_exit 3 bash -c 'exit 3'` passes; `( expect_exit 0 false )` in a subshell still fails the run; a failing `expect_stdout` prints the captured stdout. All fail today.

**Green.** `tests/lib/harness.sh`, import-pure and Bash 3.2-clean: `it`, `expect_exit`, `expect_stdout`, `expect_stderr`, `expect_file_eq`, `skip --class`, `finish`, recording one line per case to an append-only results file named by `$DXE_TEST_RESULTS` (works from subshells and background jobs); `finish` summarises and exits non-zero on any failure **or on zero recorded cases**.

**Refactor.** Keep `test_pass`/`test_fail` as shims over the results file so the other 37 suites keep passing unchanged; migrate `test_dx_backup.sh` (579 lines, already pure fake-boundary) as the template; delete the private vocabularies as each suite migrates.

#### D2 — Registering one test touches up to seven places, and the local tier omits five sections CI runs (High; corrects Muse D1 and Astra R2)

**Evidence.** `tests/run-tier.sh:11` lists `1 2 3 5 6 7 8 10 13 14 15 16 17 20 21 22 23 25 26 27 28 29 30 31 32`. Besides 33 it omits **0** (lint), **4** (ssh: seven container-free assertions), **19** (reverse/forward) and **24** (`test_herdr_config_persistence.sh`, registered at `run_all_tests.sh:115`, fully container-free); CI runs all of them. `run_all_tests.sh:33` still advertises `(0-27)`; `run-bash32-tests.sh:9–19` and `run-coverage-contracts.sh:5–15` are two more hand lists; `test_refactor_contracts.sh:81–116` polices only `run_all_tests.sh` against a literal list at `:113`, so a `test_foo.sh` outside that list is invisible. The eighth touch point is the paragraph a new test forces into `ratchet.env` (D3). `docs/refactor/baselines.md:58` targets "no test file over ~400 lines"; 18 of 38 exceed it.

**Red.** A contract test that globs `tests/test_*.sh`, reads a `# tier:` header, and fails for any file with zero or more than one tier. Fails today.

**Green.** `# tier: unit|host-contract|live|destructive` and `# bash32: yes|no` headers; `tests/run.sh --tier X` selects by header and runs each file once in its own process; the four runners become one-line wrappers.

**Refactor.** Delete `KNOWN_SECTIONS` and the B2 literal list; fix `--help`; split `test_docker_runtime_adapter.sh` along its own thirty `# ---` section headers.

#### D3 — The coverage ratchet counts comments and tests; a two-number replacement with its own Red test (High; confirms Muse D2 and Astra R1 with the arithmetic)

**Evidence.** `tests/run-coverage-linux.sh:64` `scope_lines` is `wc -l` over the scope; `:65` `total_lines` is `wc -l` over `bin`, **`tests`** and `container`; `:66` `share = scope*10000/total`. `ratchet.env` is 1,313 lines of which 1,312 are comments and one is `scope_share_basis_points=2097`; its last paragraph rebaselines because eight new test cases outweighed a fourteen-line library change. Because `wc -l` counts comments, the 482 comment lines in `dx-runtime-docker.sh` inflate the numerator. `coverage.json` already carries kcov's executable `total_lines`/`covered_lines` per file (parsed at `:51` and `:59` for the percentage) and the ratchet never uses them. The 100% gate (`:52–62`) and the "no scope file omitted" check (`:41–50`) are correct and stay.

**Replacement** (two numbers from data the run already produces, in a sourceable `tests/lib/coverage-metric.sh`):

1. `scope_exec_lines` = Σ kcov `total_lines` over scope files. Must not fall below baseline unless `exclusions.txt` changes in the same commit. Immune to tests and comments; still catches logic leaving `bin/lib`.
2. `unscoped_prod_exec_lines` = non-comment, non-blank lines over the excluded production set (`bin/dx*`, `bootstrap.sh`, `scripts/*.sh`). A ceiling: must not rise. This is D1's "two numbers" intent measured against production only, and the mechanism that makes A4 and B7 ratchet automatically.

`ratchet.env` shrinks to two `key=value` lines; the history moves to `docs/evidence/`.

**Red.** `tests/test_coverage_metric.sh` (tier unit, no kcov): a fixture tree with a fake `coverage.json`, `bin/lib/x.sh`, `bin/dx-x`, `tests/t.sh`. Assert (a) appending 200 lines to `tests/t.sh` leaves both numbers unchanged (fails today: share drops); (b) appending 50 `#` lines to `bin/lib/x.sh` leaves both unchanged (fails today: share rises); (c) moving 10 executable lines from `bin/lib/x.sh` into `bin/dx-x` lowers (1) and raises (2) so the gate fires; (d) `ratchet.env` has exactly one non-comment line per key and at most ten lines.

**Green.** `dx_coverage_metric <root> <coverage.json>`; `run-coverage-linux.sh:64–69` calls it.

**Refactor.** Retire `scope_share_basis_points`; close the `plans.md` #12-vs-Phase-4 conflict by recording that v2 Phase 4 re-measures these two numbers.

#### D4 — `test_helpers.sh` breaks the import-purity rule the suite enforces on production (Medium)

**Evidence.** `tests/test_helpers.sh:4` runs `set -uo pipefail` in the sourcing shell, exactly what `test_section9_host_scripts.sh:17` and `test_refactor_contracts.sh:26–33` fail a `bin/lib/*.sh` for. `:75` re-assigns the caller's `SCRIPT_DIR`; `:77–84` hard-codes `CONTAINER_DIR` to the architecture-named path and exports six `FLAKE_*`/`*_NIX` variables into every subprocess the tests spawn; `:90` sources production code before any assertion helper exists; `:245` sources `lib/tmux-probes.sh` (live-only) into container-free suites. `stdin_matches` is duplicated at `test_sourceable_coverage.sh:21` because that file cannot source helpers.

**Red.** Extend `test_refactor_contracts.sh:26–33`'s `$-` check to `tests/lib/*.sh` and `tests/test_helpers.sh`. Fails today.

**Green.** Move the `set` into each suite (or the runner); make `CONTAINER_DIR` a function (`dx_test_guest_dir`, which also makes Muse B5's rename a one-line change); stop sourcing production from the helper.

**Refactor.** Fold `tmux-probes.sh` sourcing behind `requires_container`.

#### D5 — Fakes: one shared library, but the runtime fakes are re-written per suite and the built-in transcript truncates (Medium)

**Evidence.** `tests/lib/fake-tools.sh` (79 lines) is good where it exists: `fake_ssh_write` decodes the base64 guest body so fixtures assert what the guest was asked to do (`:16–47`); `fake_qnap_ssh_write` evaluates the joined command locally with an optional argv log (`:49–79`). Only 9 of 38 suites use it. There is no shared `container`/`docker` fake: near-identical pass-through `container` fakes at `test_dx_backup.sh:38–58` and `test_dx_restore.sh:21–41`, a third at `test_bootstrap_publication.sh`, an inline one at `test_section9_host_scripts.sh:160–175`, three copies of a four-line `write_stub`. `test_docker_runtime_adapter.sh` alone holds **105** fake `docker` bodies, 111 `fake_qnap_ssh_write` calls, 126 `PATH="$dir:/usr/bin:/bin"` pins, and the `"version --format") echo "27.3.1"` arm 20 times. Argv recording uses six different environment names for one concept. `fake-tools.sh:73` writes the log with `>` not `>>`, so only the last `ssh` call survives: a test asserting "no second call was made" cannot use it. "Fail on the Nth call" is done by counting log lines by hand (`:285–305`).

**Why it matters.** Every Astra F-series fix needs a fault-injection fixture. At ~15 lines of fake body plus PATH ritual per case, that is why the adapter test is 2,916 lines and why those fixtures have not been written.

**Red.** In `tests/test_harness.sh`: `with_fake_runtime docker` records two invocations to `$FAKE_TRANSCRIPT` (one `%q`-quoted argv per line, appended) and `fake_fail_nth docker 2 42` makes the second call exit 42. Fails today.

**Green.** Implement in `harness.sh` with `"$dir:/usr/bin:/bin"` as the only PATH convention (the one the adapter test adopted after a real `/usr/bin/docker` leaked in on CI, `:47–50`) and `expect_transcript 'exec -i -u dx …'`.

**Refactor.** Replace the `dx_backup`/`dx_restore` fakes with `with_fake_container --persist "$FIXTURE/persist"`, then shrink the 105 adapter bodies section by section.

#### D6 — Function-override stubbing after `source` leaks between cases (Medium)

**Evidence.** Top-level overrides of coreutils and boundary commands: 95 in `test_sourceable_coverage.sh`, 80 in `test_section3_bootstrap.sh`, 31 in `test_nix_store_import.sh`, 14 each in sections 17 and 23. `test_section17_dx_ai_runtime.sh:50–52` redefines `mv` at top level and never `unset -f`s it, so every later case in a 1,407-line file runs under the override; `test_refactor_state_machines.sh:219–225` shows the correct discipline. Overriding `stat` shadows the `stat` inside `test_helpers.sh:30–32 file_mode`. A function override cannot reach an entrypoint run as a subprocess, so the same boundary is faked two ways depending on whether a test sources or execs (`container` is a function at `test_refactor_contracts.sh:62`, an executable at `test_dx_backup.sh:38`). Constitution rule 3: the `chown`/`install`/`useradd` overrides in section 3 have their real-boundary counterpart in `test_nix_store_import.sh`; the `nix`/`mv`/`kill` overrides do not.

**Red.** A contract test that finds column-0 `<coreutil>() {` definitions outside a subshell in `tests/test_*.sh`; fails today on `test_section17_dx_ai_runtime.sh:50`.

**Green.** Wrap that block in a subshell or `unset -f` in a trap.

**Refactor.** For boundaries both sourced and exec'd tests need (`container`, `ssh`, `docker`, `chown`), use the PATH fake from D5 so one fixture serves both.

#### D7 — Source-text assertions: 388 remain; which to convert and which to keep (Medium)

**Evidence.** 388 `assert_file_contains`-family calls out of ~1,801 assertions (21.5%), down from the 492 baselined in `docs/refactor/baselines.md:58`. Sections 14, 6, 10 and 3 hold 263; about half target `.nix`/docs/Containerfile (legitimate contracts), half target executable shell.

Convert first (the fake each needs already exists in the same file):

1. `test_section3_bootstrap.sh:499–504`: six literal checks for `'Bootstrap phase: … completed in'`; drive the phase reporter the way `:127–136` drives `install_essential_packages` and assert stdout.
2. `test_section3_bootstrap.sh:491–496`: `assert_file_not_contains activation.sh 'chown -R dx:dx /home/dx'` ×6, evaded by `chown -R "dx:dx"`; `:145–159` already runs `dx_ensure_tree_owner` with a recording `chown` fake.
3. `test_section9_host_scripts.sh:212–213`: `dx-wait-ssh` "contains `print_container_logs 5`"; `:230–247` already drives `dx-wait-ssh` with fakes and captures `out`.
4. `test_section23_herdr.sh:367–369`: `dx-herdr` contains/does-not-contain function names; `:69–73` already decodes the guest command via `DX_FAKE_GUEST_CMD`.
5. `test_section17_dx_ai_runtime.sh:1084–1085`: a grep for call shape; stub the function to `return 1` and assert main still exits 0.
6. `test_section4_ssh.sh:8–13` and its duplicate `test_section13_final_review.sh:44–49` assert `sshd_config` literals twice; render via `configure_ssh` into a fixture and check once (or `sshd -T -f`).

Keep as architectural contracts, gathered into one `tests/test_contracts_source.sh` so text assertions are a reviewed set: `test_runtime_boundary_audit.sh` (it proves its detector red/green on fixtures before scanning); `test_refactor_contracts.sh:140–170` and `:185–229`; `test_section2_containerfile.sh:66–72`; `test_section0_lint.sh:19–33`; the "no production test seam" checks.

**Red.** Rewrite item 1 as a behavioural case and confirm it passes only after the literal assertion is deleted.

#### D8 — `test_sourceable_coverage.sh` is a coverage driver with no assertions (Medium)

**Evidence.** 2,109 lines; zero `test_pass`; **149** `|| true`, 136 of them `>/dev/null 2>&1 || true`; runs only inside the kcov image (`run-coverage-contracts.sh:14`). Its probes execute lines (raising the 100% figure) while discarding every outcome, the case `constitution.md:3` warns against.

**Red.** A contract test asserting the file (or its successors) contains no `|| true` whose left side is a scope function call; record 149 as the baseline and ratchet it down.

**Green.** Replace each `f >/dev/null 2>&1 || true` with `expect_exit N f` / `expect_stderr 'Error: …' f` so the negative branch's *message* is asserted.

**Refactor.** Move probes into the behavioural suite that owns the function (the config parser cases at `:51–102` belong beside `test_refactor_state_machines.sh:41–78`, which already tests them with `expect_reject`); drop the nine dead-code probes for `setup_nix_volume` (B6.7).

#### D9 — Isolation is per-author: HOME, the config snapshot, guest `/tmp`, and git state (Medium)

**Evidence.** `test_helpers.sh:34–61` (`dx_real_ssh_known_hosts_snapshot`) exists because a test once wrote into the real `~/.local/state/dxe`; nothing enforces its use. Sourcing `bin/dx-forward` at `test_section9_host_scripts.sh:129` resolves the developer's real configuration into the shell, so a sixteen-line comment plus an `unset DXE_CONFIG_RESOLVED …` loop is repeated five times in `test_refactor_state_machines.sh` and six in `test_sourceable_coverage.sh`. `test_section12_validate_linux.sh:119–175` uses fixed guest paths `/tmp/test-dx-profile` without `$$`. `test_section1_secrets.sh:46` reads the real checkout's `git status`; `test_section12:64–65` ships `git archive HEAD` to the guest, so an uncommitted Red test is invisible to the guest tier. No suite writes into the repository tree (checked).

**Red.** After `with_fixture`, `$HOME`, `$XDG_STATE_HOME` and `$TMPDIR` are under the fixture, `DXE_CONFIG_RESOLVED` is unset, and the run fails if `~/.local/state/dxe` changed.

**Green.** Implement in `harness.sh`; `finish` runs the known-hosts snapshot diff automatically.

**Refactor.** Delete the twelve hand-written `unset` loops and the ad-hoc `HOME=` assignments.

#### D10 — Timing assumptions in the unit tier (Low–Medium)

**Evidence.** `test_bootstrap_publication.sh:293 sleep 2`; `test_refactor_state_machines.sh:341 sleep 0.2`; `test_sourceable_coverage.sh:1156–1158` backgrounds `exec -a … sleep 60` then sleeps 1 before matching argv; live tier: thirteen sleeps in `test_section23_herdr.sh:942–1129`, several a fixed `sleep 1` after `herdr server stop` instead of polling for exit; `test_section19_reverse_forward.sh:144` picks a port in a 500-slot window shared with any other process.

**Red.** Replace `test_bootstrap_publication.sh:293` with a readiness marker the fake launcher writes when it reaches its wait; assert the publish happened after the marker.

**Green.** Same for `state_machines:341` (the fake `ssh -O check` can signal).

**Refactor.** `harness.sh` provides `wait_until 'cond' 10` and `wait_for_pid_exit`; a contract test forbids bare `sleep N` in unit-tier files (four hits today). A6's `DX_SLEEP` seam removes most of the need.

#### D11 — Ordering dependencies and silent skips make a green run ambiguous (Low)

**Evidence.** `run_all_tests.sh:112–114`: section 23 must run after section 17 "or the live probe is doomed to skip"; `--section=23` alone on a fresh guest skips silently. `test_skip` (`test_helpers.sh:187–191`) only increments a counter and `exit_with_code` (`:306–308`) reads `TESTS_FAILED` only, so a suite whose every case skipped, or a suite with zero assertions (D8), exits 0. `SKIP_INTEGRATION` is checked by hand in twelve suites and never in `requires_container`.

**Red.** `finish` exits 3 when zero cases were recorded; `run.sh` fails when a suite recorded only skips without a `# skip-ok:` header.

**Green.** `skip "reason" --class live|linux-root|destructive` recorded to the results file.

**Refactor.** `requires_container` honours `SKIP_INTEGRATION` centrally; make the 17→23 dependency an explicit `# after: 17` header, or have 23 install what it needs.

### E. CI and documentation

#### E1 — ShellCheck pin: correct, but the comment is one file short (Low; extends Muse E2)

0.11.0 was run here over the whole tree: production is clean, and the crash hits exactly `test_refactor_contracts.sh:29` and `test_section9_host_scripts.sh:20` (both `output="$(source "$library")"`). `ci.yml:18–22` and `validation-matrix.md:76–80` name only the first. Record both, and have section 0 fail loudly when the local binary is absent and `--strict` is passed, so CI is not the only place lint ever runs.

#### E2 — The `plans.md` contract rejects review notes at the repository root (Low)

`test_section10_docs.sh:27–66` requires every root `*.md` except `README.md`, `constitution.md` and `plans.md` to appear under exactly one status in `plans.md`. The two earlier findings files fail it today and this file will too. The contract is right; the fix is a home for reviews: `docs/reviews/<date>-<name>.md`, indexed from `docs/reviews/README.md` (Muse F2's docs map is the natural link), with section 10's `maxdepth 4` link check still covering them. Red: a section 10 case asserting root-level `findings-*.md` are absent and `docs/reviews/` is indexed.

#### E3 — The container-free tier assumes `/bin/bash` and system tool directories (Low)

Every fake written by `tests/lib/fake-tools.sh:12` and `tests/lib/audit-flake-lock.sh` use `#!/bin/bash`; the adapter test alone pins `PATH="$dir:/usr/bin:/bin"` 126 times. On macOS and Ubuntu that is fine; on a NixOS or nix-profile host (this review's guest is one) the tier cannot run at all, which is why a developer working *inside* the DXE guest cannot run the host contracts there. Red: `tests/test_harness.sh` runs a fake written by the harness under `env -i PATH=/var/empty bash` and asserts it executes. Green: fakes use `#!/usr/bin/env bash` and the harness pins `PATH="$dir:$(dirname "$(command -v bash)"):/usr/bin:/bin"`. `bin/dx*` keep `#!/bin/bash`: that is the Bash 3.2 contract.

## Suggested sequence

Each step is Red → Green → Refactor per finding; none changes production behaviour until step 2.

1. **Harness, registration, metric, Nix checks (D1, D2, D3, D5, C1, C2; two to three days).** No production change. Every later Red test becomes ten lines instead of forty, the local tier matches CI, adding a test stops looking like a regression, and the Home Manager tree is evaluated in CI for both architectures with warnings as failures.
2. **Guest correctness with the new fixtures (B1, B2, B5, then A1).** Each is a data-loss or bricked-boot shape with a reproduction and a ten-line Red now.
3. **Seams (A4, A6, A5, B8, D4, D9).** Main-guarded entrypoints (start with `dx-mount`, `dx-sync-bootstrap`, `dx-status`), `dx_wait_until`, the config registry table, `bootstrap_phases`, an import-pure helper, automatic fixture isolation. Each removes `bin/dx*` or `scripts/*.sh` lines from the exempt set, which D3's ceiling then ratchets.
4. **Protocol pins (A2, A3, B3).** One rendered publication protocol, one lock contract fixture run against all three copies, a data channel between sync and start.
5. **Nix hygiene (C3–C8).** Each lands with its `checks` entry; the `sed` scrapes and the 49 text assertions in section 6 retire as they go.
6. **Structural splits.** `refactor-v2-final.md` Phases 0–3 with the B6 corrections, then Phase 4 along the B6 matrix; `dx-ai.sh` per B7 (with B4, B9, B10 folded in); the Docker adapter per Muse A2 starting from A7's helper; D7's conversions and D8's probe migration as each module is touched.
7. **Astra F1–F10** with fault-injection fixtures (D5); F11 is closed by C1.
8. **Documentation and retirement (E1, E2, Muse F1).** Retire `checkout-consolidation-plan.md` after Phase 7's live steps, move review notes under `docs/reviews/`, record the v2/#12 ordering decision in `plans.md`.

Keep throughout: the runtime boundary and its audit, immutable bootstrap generations, Bash 3.2 for `bin/` only, data-only profiles, the `Bootstrap phase:` lines byte-identical, the pipefail/SIGPIPE discipline, and the self-proving contract tests. Those are the reason the repository survived eighteen branches and seven QNAP phases without a rewrite.

## Appendix: numbers consulted

| Measure | Value |
| --- | ---: |
| Commits on `main` (2026-05-03 → 2026-09-29) | 506 |
| Most-changed file in history | `tests/coverage/ratchet.env` (72 commits) |
| Production shell lines (host + guest) | 11,686 |
| … inside the kcov scope | 7,544 |
| … exempt by `exclusions.txt` | 4,142 (35%) |
| `bin/lib/dx-runtime-docker.sh` | 1,109 lines, 55 functions, 482 comment lines, 27 `require_bin` preambles |
| `G/bootstrap/base-and-storage.sh` | 1,004 lines (695 when `refactor-v2-final.md` was written) |
| `G/scripts/dx-ai.sh` | 663 lines, 22 silent `return 1`, 7 copies of the release epilogue |
| Test suite (`tests/`, all `.sh`) | 22,956 lines, 38 suites, 18 over 400 lines |
| Assertions / source-text assertions | ~1,801 / 388 (21.5%) |
| `test_docker_runtime_adapter.sh` fake `docker` bodies | 105 |
| `test_sourceable_coverage.sh` `\|\| true` | 149 (zero assertions) |
| `ratchet.env` | 1,313 lines, 1,312 comments, one value |
| Nix evaluation warnings on the activation package + `ai-tools` | 5 |
| Duplicated `home.packages` entries | 5 (`fish`, `git`, `man-db`, `nushell`, `tmux`) |
| Installed user commands absent from the inventory contract | 5 (`man`, `starship`, `node`, `fish`, `nu`) plus `tput`/`clear` |
| Root plan and finding documents | 3,564 lines; `docs/evidence` 664 K; `docs/refactor` 476 K |
