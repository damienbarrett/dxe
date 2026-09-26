# OpenCode re-landing (Branch 6, `feat/opencode`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 6:
re-landing OpenCode as one complete delivery after Branch 2's revert. No
home directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `feat/opencode`, from `main` `08700a8`, rebased onto `main` `d5ca161`
before landing (commit ids below are the rebased ones; the pre-rebase ids
appear only in the private consolidation ledger). Commits, in order:
`0cec55a` (original support), `c7175d3` (persistence helper), `6ebd283`
(activation/dx-ai wiring), `81973e6` (per-generation manifests), `c2f24d6`
(docs), `8b6e253` (ShellCheck SC2120 fix), `13a3d14` (ratchet rebaseline
1910→1921), `9f46e8f`/`326581c` (coordinating-session plan updates, folded
in since they touch the same file), `3a84acc` (loader coverage),
`aa3ef16` (backlog item), `4ee8f7f` (ratchet rebaseline 1921→1917).

## Gates

| Gate | Result |
| --- | --- |
| G1 bash32 | `bash tests/run-bash32-tests.sh` on macOS `/bin/bash` 3.2: 69 passed, 0 failed |
| G1 container-free contracts (runner-matched) | Throwaway `dxe-scratch-b6-<pid>-g1ubuntu` (`ubuntu:24.04`, `-m 4g`), apt-installed `git`/`shellcheck`/`jq` (confirmed ShellCheck 0.9.0, matching the GitHub runner), `git clone --local --no-hardlinks /work` (plain `--local` fails: `/work` is a read-only bind mount, cross-device hardlinks are refused), `SKIP_INTEGRATION=true bash tests/run_all_tests.sh --skip-integration`. First run caught a real ShellCheck SC2120 on `dx-ai.sh` (fixed in `8b6e253`); second run on a fresh clone at that commit: fully green, Section 0 visibly ran ShellCheck per file (not silently skipped) |
| G1 pinned ShellCheck 0.10.0 | Throwaway `dxe-scratch-b6-<pid>-g1nix` (`nixos/nix:2.34.8`, `-m 6g`), clean `git archive HEAD \| tar -x` export, CI's exact command (`find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \) -print0 \| xargs -0 nix shell nixpkgs/nixos-25.05#shellcheck --command shellcheck --severity=warning`): confirmed ShellCheck 0.10.0, exit 0, no warnings |
| G1 syntax | CI's `bash -n` over the same file set: exit 0 |
| G2 coverage | `tests/run-coverage-linux.sh` via Apple `container` (`-m 6g`, existing `dxe-kcov:ubuntu-24.04` image; the script's own provider path has no memory flag, so it was invoked directly with one added): `covered=100%`. Ratchet re-measured across the branch: 1910 → 1921 bp (`13a3d14`, OpenCode's own new scope lines: the persistence helper plus its activation/persistence.sh wiring) → 1917 bp (`4ee8f7f`, test-dilution from the loader-coverage commit, the file's documented acceptable edge). Final confirmed run: `covered=100% scope_share=19.17%` |
| G3 Nix | `nix flake check --no-build --no-write-lock-file ./container/aarch64-darwin-apple-container-dx-nixos-26.05` in the same 6 GB `nixos/nix:2.34.8` container: "all checks passed!"; `flake.lock` sha256 (`ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9`) unchanged before/after |
| G4 Live | `dx-test`, see below |
| G5 CI | Not applicable: this branch is local only (per the standing brief, subagents do not push) |

Section 10 (`test_section10_docs.sh`) is part of `run_all_tests.sh` and
was green in every run, including the G1 Ubuntu container run.

**Skip, with covering gate:** a standalone host-side Section 12 run (the
isolated `nix profile add` build check Appendix C's fuller G3 also asks
for) was not run in its own container. The task's own gate list asked for
`nix flake check --no-build` (evaluation only, already done) plus Section
10 (already done), not Section 12 specifically, and `--no-build` cannot by
itself prove `opencode` actually resolves and builds against the pinned
`nixpkgs-unstable`. The live `dx-test` opt-in below is a strictly stronger
substitute: it runs the real `nix profile add ... #ai-tools` inside guest
activation, for real, which is exactly what Section 12 would otherwise
approximate on an isolated host profile.

## Changed-code coverage: `scripts/dx-ai.sh` (outside kcov scope)

`scripts/dx-ai.sh` lives under guest `scripts/`, not `scripts/lib/`, so it
is outside kcov's declared scope (`bin/lib`, guest `bootstrap/`, guest
`scripts/lib`). `git diff --stat 08700a8..HEAD -- .../scripts/dx-ai.sh`:
126 insertions, 17 deletions. Every changed behaviour, mapped to its test:

| Changed behaviour | Test(s) |
| --- | --- |
| `DX_AI_TOOLS` gains `opencode` | Section 17 "--supports opencode exits 0 with no stdout"; `test_refactor_contracts.sh`'s F13 contract (`DX_AI_TOOLS`/`aiPackages`/`dx-herdr` install message stay consistent); Section 6 "opencode is in aiPackages" |
| `DX_AI_LEGACY_TOOLS` (new) | Section 17 "AI recovery accepts a legacy predecessor using its own five-tool inventory", "a legacy generation predates the tools manifest" |
| `DX_AI_HERDR_INTEGRATIONS` gains `opencode` | Section 17's Herdr-integration battery (`all_missing`/`all_current`/`all_outdated` fixtures plus the dedicated opencode-outdated case) |
| `dx_ai_load_opencode_persistence`, candidate 1 (colocated `lib/`) | Exercised implicitly by every `dx_ai_setup_credentials` call in Section 17 (`$AI_SCRIPT` is sourced straight from the guest tree in every test) |
| ...candidates 2 (`~/.local/lib/dx/`), 3 (bootstrap volume), fail-closed | Section 17's three dedicated loader tests, each run in its own fresh `bash` process against a standalone copy of `dx-ai.sh` with no `lib/` sibling |
| `dx_ai_usage` text mentions OpenCode | Not independently asserted (cosmetic help text; the pre-change wording had no test either) |
| `dx_ai_stage_generation` writes `.tools-manifest` | Section 17 "AI staging records the complete generation-local tool manifest" |
| `dx_ai_generation_tools` (new) | Section 17's manifest battery: absent-manifest legacy fallback, and each of the seven malformed-manifest shapes (empty, invalid-tail, duplicate, dot, dotdot, symlink, directory) rejected |
| `dx_ai_validate_generation` now manifest-aware | Covered indirectly by every publish/recover call in the pre-existing staging/publish/recovery battery, and directly by the manifest-corruption battery |
| `dx_ai_validate_publish_generation` (new) | Section 17 "AI publication rejects a candidate missing its declared opencode executable" / "... accepts the same candidate after its opencode executable is added" |
| `dx_ai_publish_generation` calls it | Same two tests, plus the pre-existing "AI publication atomically advances current and retains predecessor" |
| `dx_ai_setup_credentials`: `(persist_home, home)` params, OpenCode wiring, `ln -sfnT` hardening on the four legacy links | Section 17's credentials battery: fresh fixture, idempotent repeat, unsafe-ancestry end-to-end refusal, dedicated hardening test |
| `dx_ai_setup_credentials`'s call site now passes explicit args | Runner-matched ShellCheck 0.9.0 caught the SC2120 this created (`8b6e253`'s own red/green); exercised functionally by every live guest `dx-ai` run below |
| `dx_ai_verify(generation)` rewritten | Section 17: legacy generation-local inventory, rejects a missing generation executable despite a PATH fallback, rejects a malformed inventory before reporting any tool |
| `dx_ai_main`'s two call sites pass `"$state/current"` to `dx_ai_verify` | Known minor gap: the F8 sourced-`dx_ai_main` test stubs `dx_ai_verify`, so it does not check which argument was passed. Low risk (one-line change, `dx_ai_verify`'s own behaviour is thoroughly tested standalone); the live guest runs below exercise the real call sites end to end (both the fresh-opt-in `dx-ai` run and the `--recover` run report the correct generation's tools) |

`bin/dx-herdr`'s install-message line is covered by the F13 contract.
`flake.nix`'s `aiPackages` line is covered by Section 6 and proven to
build by the live opt-in below. `home/tools.nix`'s `home.file` addition is
covered by `nix flake check` (G3) and, for the installed file actually
landing at the right path, by the live opt-in.

## Live validation on `dx-test`

Containers/resources: `dx-test` (container), image `dx-test-nixos`,
volumes `dx-test-nix`/`dx-test-persist`/`dx-test-bootstrap`, key
`dx-test_key`(`.pub`) — all via `./bin/dx-profile dx-test <cmd>`. `dx-host`
and `dx-opencode` were never touched.

### (a) Fresh opt-in gate

`./bin/dx-profile dx-test ./bin/dx-factory-reset --force`,
`dx-create-keys`, then the layered bring-up (`dx-create-image`,
`dx-create-volumes`, `dx-create-container`, `dx-start-container`,
`dx-wait-ssh`; each detached, logged, polled). Confirmed before opt-in:
`opencode` absent (`command -v opencode`, exit 1), no AI generation yet.

`DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test bash
tests/run_all_tests.sh --section=17`:

- **First attempt failed for an infrastructure reason, not an OpenCode
  defect.** It reached `dx-ai`'s real `nix profile add ... #ai-tools` and
  that failed building `codex-0.157.0` from source: `rustc was terminated
  by a deadly signal` while compiling `codex-core`/`codex-tui`, under
  `dx-test`'s then-default 12 GB / 4 CPU container. Root-cause diagnosis
  (three possibilities considered, per a request to rule out a harness
  timeout):
  - *Not* a harness/SSH timeout: the SSH invocation
    (`bin/lib/dx-ssh-common.sh`) sets only `ConnectTimeout` (bounds the
    handshake, not command duration); there is no `ServerAliveInterval`
    or similar that could kill a long remote command from the host side.
    The captured output ends with Nix's own conclusive verdict
    (`error: Cannot build '.../codex-0.157.0.drv'. Reason: builder
    failed with exit code 101.` then `error: Cannot build
    '.../dx-ai-tools.drv'. Reason: 1 dependency failed.`) — text Nix
    only emits once the builder process has actually exited and the
    daemon has given up, not something a client-side timeout could fake.
  - *Is* a genuine build failure: "terminated by a deadly signal" from a
    large parallel (`cargo -j 4`) Rust build under a memory-constrained
    container is the Linux OOM killer's signature.
  - *Not* a defect in the re-landed code: `codex` is one of the five
    *original* optional tools, untouched by this branch. `nix profile
    add` installs a profile's whole closure atomically, so `codex`
    failing blocks the entire `#ai-tools` output including `opencode`
    regardless of whether `opencode` itself would have built cleanly —
    which is why the failure surfaced as "dx-ai completes successfully
    inside the guest," not anything OpenCode-specific.
  - No orphaned-process risk: the container was fully destroyed (not
    merely restarted) before the retry, so nothing from the first attempt
    could still be running in the second attempt's fresh container.
  - First (failed) attempt: 20:31–21:06 NZST (~35 min) before the OOM
    kill.
- **Mitigation (routine, reversible, `dx-test`-only, not a repository
  default change):** recreated `dx-test`'s container+image only (volumes
  and keys preserved) with `DX_CONTAINER_MEMORY=24G` as an environment
  override for the `dx-test` profile invocations only (`tests/profiles/dx-test.env`
  itself was not edited); confirmed via `container list --all` before
  (12288 MB) and after (24576 MB). Host has 64 GB total.
- **Retry: fully green.** Second (successful) attempt: 21:12–21:57 NZST
  (~45 min) for the complete `#ai-tools` build (codex, gemini-cli,
  claude-code, agy, herdr, opencode). **80 passed, 0 failed, 0 skipped.**
  Notable lines: "dx-ai completes successfully inside the guest",
  "opencode is available after dx-ai", "opencode config directory is
  symlinked to persist", "opencode data directory is symlinked to
  persist", all five legacy tools available. Directly verified on the
  guest: `opencode --version` → `1.18.31`; `readlink ~/.config/opencode`
  → `/persist/home/dx/.config/opencode`; `readlink
  ~/.local/share/opencode` → `/persist/home/dx/.local/share/opencode`.

**Backlog finding, recorded (not implemented) in
`checkout-consolidation-plan.md`'s "Observations from Branches 1–2"
section and reported to the user via the coordinating session:** `dx-ai`
refreshes `nixpkgs-unstable` at install time, so a fresh guest's first run
depends on the binary cache having every AI tool built for
`aarch64-linux` at whatever revision that lands on, and falls back to
building large Rust crates locally on a cache miss — which can OOM under
the profile's 12 GB default. This affects any guest opting into AI tools
at that default, `dx-host` included, regardless of OpenCode. Proposed
backlog item: "dx-ai cache-dependency / memory-aware build, or a pinned
AI lock," with the trade-off left to the user.

### (b) Full live tier

`unset DX_TEST_DESTRUCTIVE; DX_CONTAINER_MEMORY=24G ./bin/dx-profile
dx-test bash tests/run-tier.sh live`: **1247 passed, 0 failed, 8
skipped** across the whole tier, matching Branch 4b's earlier live-tier
baseline shape (1105/0/8; higher pass count now from this branch's added
tests). Section 19 (`dx-reverse`) included and green.

### (c) Retained-state migration

**Finding, procedure corrected:** the first attempt seeded real
pre-existing OpenCode content at the live path and then ran `dx-recreate`
(destroy + layered bring-up) — but `dx-recreate` destroys the container,
and `/home/dx` is part of the container's own ephemeral root filesystem,
not a persisted volume (`dx-create-container` mounts only the Nix,
persist, and bootstrap volumes). The destroy step wiped the seeded live
content *before* the new container's activation ever ran, so there was
nothing left to migrate — expected, not a bug: the scenario this
migration targets is a guest whose container was stopped and restarted
(or rebooted), not destroyed. Corrected procedure below uses
`dx-stop-container` + `dx-start-container` on the *same* container
instance, which preserves `/home/dx` while still re-running activation
from scratch.

**Repeatable procedure** (real production code throughout, no test
stubs; a copy also lives in this record's own working notes):

```sh
# Step 1: construct a real five-tool predecessor generation.
# nix profile add's own profile/bin is itself a symlink into an
# immutable, atomic Nix store closure, so an existing generation's
# opencode entry cannot be selectively deleted from it. Build a separate,
# real profile/bin directory whose five entries are symlinks straight to
# each tool's own resolved /nix/store binary instead.
./bin/dx-profile dx-test ./bin/dx-ssh \
  'readlink /persist/home/dx/.local/state/dx-ai/current'
CUR=<current-generation-id>       # from the command above
GENDIR=/persist/home/dx/.local/state/dx-ai/generations
./bin/dx-profile dx-test ./bin/dx-ssh "
set -e
mkdir -p $GENDIR/legacy-five-tool/profile/bin $GENDIR/legacy-five-tool/pins
cp -a $GENDIR/\$CUR/flake.nix $GENDIR/\$CUR/flake.lock $GENDIR/legacy-five-tool/
cp -a $GENDIR/\$CUR/pins/agy.json $GENDIR/legacy-five-tool/pins/
printf '' > $GENDIR/legacy-five-tool/.predecessor
for t in codex gemini claude agy herdr; do
  target=\$(readlink -f $GENDIR/\$CUR/profile/bin/\$t)
  ln -s \"\$target\" $GENDIR/legacy-five-tool/profile/bin/\$t
done
"
# Repoint the real current generation's own .predecessor at the legacy
# one (brief chmod u+w -- generations are published read-only).
./bin/dx-profile dx-test ./bin/dx-ssh "
chmod u+w $GENDIR/\$CUR/.predecessor
printf 'legacy-five-tool' > $GENDIR/\$CUR/.predecessor
chmod u-w $GENDIR/\$CUR/.predecessor
"
# Verify against the real, unmodified production code first.
./bin/dx-profile dx-test ./bin/dx-ssh "
source ~/.local/bin/dx-ai
dx_ai_validate_generation $GENDIR/legacy-five-tool && echo VALID
dx_ai_generation_tools $GENDIR/legacy-five-tool
"

# Step 2: seed real pre-existing OpenCode content at both live and
# persistent paths, including a same-named conflict against real content
# OpenCode itself already wrote (e.g. cli.json, from a prior real run).
./bin/dx-profile dx-test ./bin/dx-ssh '
rm ~/.config/opencode ~/.local/share/opencode
mkdir -p ~/.config/opencode ~/.local/share/opencode
echo "live-only-marker-content" > ~/.config/opencode/live-only.txt
echo "live-data-marker-content" > ~/.local/share/opencode/live-only-data.txt
echo "LIVE-CONFLICT-CONTENT" > ~/.config/opencode/cli.json
'

# Step 3: restart the SAME container (not destroy/recreate).
DX_CONTAINER_MEMORY=24G ./bin/dx-profile dx-test ./bin/dx-stop-container
DX_CONTAINER_MEMORY=24G ./bin/dx-profile dx-test ./bin/dx-start-container
DX_CONTAINER_MEMORY=24G ./bin/dx-profile dx-test ./bin/dx-wait-ssh

# Step 4: verify survival, conflict preservation, and ownership.
./bin/dx-profile dx-test ./bin/dx-ssh '
readlink ~/.config/opencode; readlink ~/.local/share/opencode
cat /persist/home/dx/.config/opencode/live-only.txt
cat /persist/home/dx/.local/share/opencode/live-only-data.txt
cat /persist/home/dx/.config/opencode/cli.json
for f in /persist/home/dx/.config/opencode/.dxe-conflict-cli.json.*; do
  echo "$f:"; cat "$f"
done
stat -c "%U:%G %a %n" /persist/home/dx/.config/opencode /persist/home/dx/.local/share/opencode
stat -c "%F %n" ~/.config/opencode ~/.local/share/opencode
'

# Step 5: recover to the legacy five-tool generation and prove it runs.
./bin/dx-profile dx-test ./bin/dx-ssh 'dx-ai --recover'
./bin/dx-profile dx-test ./bin/dx-ssh '
readlink /persist/home/dx/.local/state/dx-ai/current
PATH="/persist/home/dx/.local/state/dx-ai/current/profile/bin:$PATH"
for t in codex gemini claude agy herdr; do echo "== $t =="; "$t" --version; done
test ! -e /persist/home/dx/.local/state/dx-ai/current/profile/bin/opencode \
  && echo "opencode correctly absent"
'
```

**Result — all real, on the live guest, no fixtures:**

- Legacy generation validated against the real, unmodified
  `dx_ai_validate_generation`/`dx_ai_generation_tools`: `VALID`, tool list
  exactly `codex gemini claude agy herdr`.
- After the stop/start restart: both live paths are correct symlinks
  again; `live-only.txt`/`live-only-data.txt` present under `/persist`
  with their original content (migration happened); the persisted
  `cli.json` — OpenCode's own real config,
  `{"plugins": ["./herdr-opencode"]}` — is **unchanged**; the live-side
  conflicting `cli.json` survived as
  `/persist/home/dx/.config/opencode/.dxe-conflict-cli.json.1` containing
  `LIVE-CONFLICT-CONTENT` (nothing lost); ownership `dx:dx`, mode `700`
  on both persistent OpenCode directories; no leftover real directories
  at the live paths.
- `dx-ai --recover`: `Recovered AI generation legacy-five-tool (from
  <the real 6-tool generation id>).` `dx_ai_verify` (real, unmodified
  code) reported exactly the five legacy tools against
  `.../current/profile/bin/*` — no `opencode` line.
- All five recovered binaries executed with `current/profile/bin`
  prepended to `PATH`: `codex-cli 0.157.0`, `gemini 0.47.0`, `claude
  2.1.281 (Claude Code)`, `agy 1.2.11`, `herdr 0.9.1`. `profile/bin/opencode`
  confirmed absent from the recovered generation.

### (d) Guest stopped

`./bin/dx-profile dx-test ./bin/dx-stop-container`: confirmed stopped via
`container list --all`.

## Skips and their covering gates

| Skip | Reason | Covering gate |
| --- | --- | --- |
| Standalone host-side Section 12 (`nix profile add` build check) | Task's gate list asked for `nix flake check --no-build` + Section 10, not Section 12; `--no-build` cannot prove a package actually builds | Live `dx-test` opt-in (step a) runs the same build for real, inside guest activation — a strictly stronger proof |
| G5 CI (at the branch's own tip) | The subagent's branch was local only; subagents do not push | G5 ran on the rebased branch before `main` was fast-forwarded — see "Landing" below |
| `dx_ai_main`'s `dx_ai_verify "$state/current"` argument, specifically | The F8 sourced-`dx_ai_main` test stubs `dx_ai_verify` entirely | `dx_ai_verify`'s own behaviour is thoroughly unit-tested; both live guest runs (fresh opt-in and `--recover`) exercise the real call sites end to end and report the correct generation's tools each time |

## Landing (2026-09-26)

Rebased onto `main` `d5ca161`, which had meanwhile gained the QNAP Phase 0
spike fixes and their Section 27 tests (`tests/qnap/`,
`tests/test_section27_qnap_scripts.sh`, `qnap-dxe-plan.md`, `ratchet.env`).
The only textual overlap was `tests/coverage/ratchet.env`, resolved by
keeping both sides' entries; the rebased tree's `bin/`, `container/`,
`docs/` and this branch's test files are byte-identical to the
live-validated pre-rebase tip (`git diff --quiet <pre-rebase tip> HEAD --
bin container docs tests/test_section17_dx_ai_runtime.sh
tests/test_sourceable_coverage.sh tests/test_section3_bootstrap.sh
tests/test_section6_tools.sh tests/test_section12_validate_linux.sh` is
empty), so the G4 live results above stand for the rebased commits without
a second live run. `flake.lock` unchanged against `main`.

Re-checked on the rebased tree by the coordinating session: bash-3.2 suite
99/0/0 (it now includes Section 27); Section 27 99/0/0; both Phase 0
scripts' `--dry-run` still print their full command lists (the QNAP
non-regression stand-in required by Appendix C's dual-target gate, since no
QNAP guest exists yet). Ratchet re-measured on a clean export of the rebased
tip: 4,158 / 22,559 = 1843 bp (`ratchet.env` entry dated 2026-09-26).
G5: GitHub Actions ran on the pushed rebased branch (both jobs green) before
`main` was fast-forwarded to it. The Appendix D promotion of OpenCode to
`dx-host` remains a separate, explicit user decision.
