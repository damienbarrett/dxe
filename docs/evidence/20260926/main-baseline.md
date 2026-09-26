# `main` baseline evidence — 2026-09-26

Step 4 ("Baseline check of `main`") of the DXE consolidation plan. This is a
factual record: commands run, exit codes, and observed output. No changes
were made to the repository or its production code during this check.

*Sanitised for the repository: run logs referenced below are retained
privately (not committed); no key material or fingerprints appear here.
All commands, results, skips and timings are unchanged from the original
record.*

## Subject

- Commit: `bd2418fd949d49f68b61a5f24dfa7de5745d0978` — "Re-measure the
  scope-share ratchet after removing the test-image fetchurl fixture"
  (`main`, checked out, clean working tree).
- `flake.lock` sha256:
  `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9`
  (`container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.lock`).
- Host: macOS ProductVersion 27.0, BuildVersion 26A428.
- `container CLI version 1.4.1 (build: release, commit: 9a8917c)`.

## Profile confirmation (dx-test)

`./bin/dx-profile dx-test env | grep '^DX_'` resolved:
`DX_CONTAINER_NAME=dx-test`, `DX_IMAGE=dx-test-nixos`, `DX_SSH_PORT=2299`,
`DX_NIX_VOLUME=dx-test-nix`, `DX_BOOTSTRAP_VOLUME=dx-test-bootstrap`,
`DX_PERSIST_VOLUME=dx-test-persist`, `DX_SSH_KEY=.../dx-test_key`,
`DX_SSH_KEY_PUB=.../dx-test_key.pub`. All resolved to `dx-test-*` names; no
`dx-host`/`dx-opencode` resource was ever named by a destructive command in
this check.

## Starting state

- `container list --all`: `dx-host` (stopped, `dx-nixos-26.05:latest`),
  `dx-test` (stopped, `dx-test-nixos:latest`), `dx-opencode` (stopped,
  `dx-opencode-nixos:latest`), `buildkit` (running, Apple's builder helper).
- `container volume list`: `dx-nix`, `dx-opencode-bootstrap`, `dx-bootstrap`,
  `dx-persist`, `dx-test-bootstrap`, `dx-test-persist`, `dx-test-nix`,
  `dx-opencode-nix`, `dx-opencode-persist`.
- `container image list`: `dx-nixos-26.05`, `dx-opencode-nixos`,
  `dx-test-nixos` all at digest `bd3097c1c59b` (same image content reused
  across profiles pre-reset — expected, all three build from the identical
  Containerfile/flake pin), plus scratch/base images unrelated to this check.

## Gate 2 (G2) — coverage

Command: `bash tests/run-coverage-linux.sh` (Apple `container` provider,
`dxe-kcov:ubuntu-24.04`), run detached; run logs retained privately in
the private recovery archive.

**Result: PASS.** `covered=100% scope_share=21.43%`. "Results: 55 passed, 0
failed, 0 skipped" immediately precedes the `covered=` line; exit 0 (no
`dxe-kcov` container process remained after completion). 320 "✓ PASS" lines
total across the whole coverage-suite run, 0 "✗ FAIL"/"FAIL:" lines. Matches
the values recorded in Branch 3's final commit exactly.

Note: 4 lines in the log read "Error: refusing to use ... sentinel/identity
marker; expected an absent or regular-file path: ..." — these are printed BY
THE CODE UNDER TEST as part of its own negative-path test fixtures
(hostile/malformed-input assertions), not real failures; confirmed by the 0
FAIL count.

## Fresh-guest reset (dx-test)

`./bin/dx-profile dx-test ./bin/dx-factory-reset --force` — stdout:
```
Performing factory reset...
Removing container dx-test...
dx-test
Removing image dx-test-nixos...
Reclaimed 2.16 GB in disk space
Removing volume dx-test-nix...
dx-test-nix
Removing volume dx-test-persist...
dx-test-persist
Removing volume dx-test-bootstrap...
dx-test-bootstrap
Removing SSH keypair (~/Development/dxe/dx-test_key, ~/Development/dxe/dx-test_key.pub)...
Factory reset complete.
```
Exit 0.

Post-reset inventory: `container list --all` showed only `dx-host` (stopped),
`dx-opencode` (stopped), `buildkit` (running) — `dx-test` container gone.
`container volume list` no longer listed `dx-test-nix`, `dx-test-persist`,
`dx-test-bootstrap`; the six other volumes (`dx-nix`, `dx-bootstrap`,
`dx-persist`, `dx-opencode-*`) were unchanged. `container image list` no
longer listed `dx-test-nixos`; `dx-nixos-26.05` and `dx-opencode-nixos`
remained at their prior digest. `dx-test_key`/`dx-test_key.pub` removed from
disk; `dx_key`/`dx_key.pub` (the `dx-host` key) untouched throughout —
verified present, unread, unmodified.

## SSH key re-creation

Per `docs/lifecycle.md` layer 1 and `bin/dx-create-keys`
(`ssh-keygen -t ed25519 -f "$DX_SSH_KEY" -N ""`, idempotent — skips if the
file exists): ran `./bin/dx-profile dx-test ./bin/dx-create-keys`. Fresh
ed25519 keypair generated at `dx-test_key`/`dx-test_key.pub`. Not copied
or reused from `dx_key`; no key material or fingerprint is reproduced
here.

## Live tier, attempt 1 — run without a guest (recorded for completeness)

Command: `./bin/dx-profile dx-test bash tests/run-tier.sh live`, detached
(run log retained privately). Finished in well under a minute (no Nix
activity at all) with **EXIT=1**.

**Diagnosis:** the live tier never created or started the `dx-test` guest.
`tests/test_section11_validate_fresh.sh` gates its entire body
(`dx-create-image`, `dx-create-container`, `dx-start-container`, the
bootstrap wait, and every guest probe) behind
`if ! requires_container; then exit 0; fi`.
`requires_container()` (`tests/test_helpers.sh:171-177`) requires
`dx-test` to *already* be running (`container list --quiet | grep -x
"$DX_CONTAINER_NAME"`). On a truly fresh profile (post factory-reset, no
container object exists at all) this is always false, so Section 11 exited
immediately without ever calling `dx-create-image` et al. Every later
guest-dependent section then correctly SKIPPED its own guest-dependent
checks through the same gate (proper, graceful behaviour for those).

This run is recorded as **"live tier run without a guest"** and is not
representative of whether `main` builds/boots; it only demonstrates that the
test harness's Section 11 precondition cannot self-bootstrap a container
from a truly empty profile state when invoked this way. Two observations
from it (recorded here, not fixed, per the coordinating session's decision):

- **Observation A:** `tests/test_section4_ssh.sh` line 24 —
  `if requires_container && "$BASE_DIR/bin/dx-ssh" true; then test_pass ...;
  else test_fail ...; fi` — does not short-circuit to a skip the way every
  other of the 12 call sites of `requires_container()` does
  (`if ! requires_container; then <skip>; fi`). When `requires_container`
  returns false (already recording its own internal skip), the `&&` chain
  still falls through to the `else` branch and ALSO records a `test_fail` for
  the same underlying condition. Observed in the log: Section 4's "Results:
  11 passed, 1 failed, 1 skipped" — the 1 failed and 1 skipped are the same
  condition double-counted. This is the one genuine `FAIL` line in the
  attempt-1 log ("key-only SSH live probe succeeds").
- **Observation B:** Section 0 (lint) skipped ShellCheck on this macOS host
  because `shellcheck` is not installed here. This is expected and CI-only
  — ShellCheck was already separately validated with the pinned version in
  earlier consolidation work (Branch 1/1b/3) via a throwaway `nixos/nix`
  container.

## Guest bring-up (manual, per the corrected procedure)

Since the live tier cannot self-bootstrap from zero, the guest was brought
up directly with the same lifecycle layer scripts `bin/dx` runs before its
final `dx-ssh` exec, under the `dx-test` profile: `dx-create-image` →
`dx-create-volumes` → `dx-create-container` → `dx-start-container` →
`dx-wait-ssh`.

### Bring-up attempt 1 (run log retained privately)

- `dx-create-image`: fast (cached OCI export layers) → `dx-test-nixos:latest`
  built.
- `dx-create-volumes`: `dx-test-nix`, `dx-test-persist`, `dx-test-bootstrap`
  created.
- `dx-create-container`: `dx-test` created from `dx-test-nixos`.
- `dx-start-container`: `dx-test` started; bootstrap generation
  `20260926T021800Z-21789` synced from the repo's guest flake directory to
  `dx-test:/guest-bootstrap` and reported ready. No "drift" warning printed
  (expected — this is the container's first-ever generation, so running and
  published cannot differ).
- `dx-wait-ssh`: began polling ("Bootstrap wait limit: 5465s"). At ~92-100s
  elapsed (right as Home Manager activation began unpacking flake inputs
  `nix-community/home-manager`, `nixvim`, `flake-parts`, `nix-systems`) it
  printed **"Error: Container dx-test stopped before SSH became
  responsive."**, dumped the last 80 guest log lines, and the wrapper
  recorded **EXIT=1**.

**This was a false alarm, not a guest failure.** Immediately after,
`container list --all` showed `dx-test` STATE=`running`,
STARTED=`2026-09-26T02:18:00Z` — unchanged, never restarted — and a fresh
`container logs -n 200 dx-test` showed bootstrap had progressed far beyond
the snapshot (hundreds of further store paths, well into Home Manager
activation). The guest never stopped; it bootstrapped continuously the
whole time.

### FINDING 1 — production-code bug (recorded, not fixed here)

Root cause, precisely diagnosed: `bin/lib/dx-container.sh` defines
`container_is_running() { dx_container_list_names false | grep -F -x -q --
"$1"; }`. `grep -q` exits immediately after its first match and closes the
pipe's read end; `dx_container_list_names`'s `printf` loop can then hit
"printf: write error: Broken pipe" while still writing remaining lines
(exactly the lines seen in the log at the moments of the false failure).
Because `bin/dx-wait-ssh` runs under `set -o pipefail`, the **pipeline's**
exit status becomes printf's SIGPIPE failure rather than grep's success, so
`container_is_running` returns **false even though grep already matched**.
`container_exists` has the identical shape and the same bug. `dx-wait-ssh`'s
stopped-check (`container_exists "$DX_CONTAINER_NAME" && !
container_is_running "$DX_CONTAINER_NAME"`) then concludes the container
stopped and exits 1 — even though the guest was never stopped. This is
intermittent: it depends on whether grep's match completes before the
printf loop finishes writing its remaining lines (a race). `tests/
test_helpers.sh` already documents this exact SIGPIPE/grep-early-exit
pitfall for test code (its `stdin_matches` helper works around it), but the
production library `bin/lib/dx-container.sh` still has it. **This is
production code (`bin/lib/dx-container.sh`, consumed by `bin/dx-wait-ssh`
and other callers of `container_is_running`/`container_exists`); per the
coordinating session's decision it is out of scope to fix in this Step 4
task and is recorded here as Finding 1 for its own future branch.**

### Bring-up attempt 2 (run log retained privately)

Re-ran `./bin/dx-profile dx-test ./bin/dx-wait-ssh` alone (the container was
never recreated — same instance, `STARTED 2026-09-26T02:18:00Z`, that had
been bootstrapping continuously). One more benign "printf: write error:
Broken pipe" line appeared (same Finding-1 race, this time not fatal), then
one 31s progress tick showing Home Manager activation building `nixvim`,
`home-manager-path`, `man-paths`, `activation-script`, `man-cache`, then
**"Guest is ready." — EXIT=0.**

**Approximate bootstrap wall-clock:** `dx-start-container` began the sync at
14:17:59 NZST; attempt 1 ran ~100s before its false abort (~14:19:41);
attempt 2 started 14:21:22 and finished within roughly a further 1-2
minutes. End-to-end bootstrap (image already cached locally, all Nix store
paths served from cache.nixos.org with no source builds) took on the order
of **4-5 minutes wall clock** from container start to guest SSH-ready.

## Start-generation evidence

- `./bin/dx-profile dx-test ./bin/dx-status`: image `dx-test-nixos` digest
  `bd3097c1c59b`; container `dx-test` running, `192.168.64.49/24`, 4
  CPU/12288MB, started `2026-09-26T02:18:00Z`; SSH port 2299 OPEN on
  localhost; guest tools present
  (`/home/dx/.nix-profile/bin/{nvim,nix,tmux}`); persist volume `/dev/vdd`
  504G mounted, 1% used; no active tmux sessions.
- `container exec dx-test readlink /guest-bootstrap/current` =
  `generations/20260926T021800Z-21789`.
- `container exec dx-test sh -c 'ls -1 /guest-bootstrap/.locks/leases'` =
  `20260926T021800Z-21789.1` — matches the published generation exactly.
- **No drift.** This is the guest's very first boot of its very first
  published generation, so running and published are identical by
  construction. Neither bring-up log contains a
  "Warning: ... is running bootstrap generation X, but Y is now published"
  line (checked both logs for "drift" and "now published" — no matches),
  consistent with `dx_bootstrap_report_drift`'s guard requiring the two
  values to differ before it prints anything.
- `container exec dx-test uname -m` = `aarch64` — a genuine aarch64-linux
  guest, not emulated.
- `dx-test-nixos` image digest: `bd3097c1c59b` (content-addressed; same
  digest as `dx-nixos-26.05`/`dx-opencode-nixos` before the reset, since all
  three build from the identical Containerfile/flake pin — not
  profile-specific).

## Live tier, attempt 2 — against the running guest

Command: `./bin/dx-profile dx-test bash tests/run-tier.sh live`, detached
(run log retained privately). Launched 14:23:20 NZST.

(This section is being completed as the run progresses; see the running
per-section tally below, updated live.)

### Per-section results (run 2)

| Section | Passed | Failed | Skipped | Notes |
| --- | --- | --- | --- | --- |
| 0 (lint) | 9 | 0 | 1 | ShellCheck skip — not installed on this macOS host; CI-only, expected |
| 1 (secrets) | 12 | 0 | 0 | |
| 2 (Containerfile) | 16 | 0 | 0 | |
| 3 (sourceable bootstrap) | 131 | 0 | 0 | |
| 26 (flake.lock audit) | 21 | 0 | 0 | |
| 11 (validate from fresh) | 8 | 0 | 0 | **dx-create-image/container idempotent no-ops, dx-start-container, wait-ssh, dx-status, nvim headless, lazygit, tmux, and the stop/start persistence round-trip all PASSED against the real guest** |
| 4 (SSH) | 12 | 0 | 0 | key-only SSH live probe now PASSES (contrast attempt 1's FAIL with no guest) |
| 5 (pin Nix inputs) | (see live checks) | 0 | 0 | live guest checks: /etc/os-release NixOS 26.05, guest flake.lock nixos-26.05, guest nixpkgs#lib.version 26.05.* — all PASS |
| 6 (guest tooling) | 157 | 0 | 1 | live tmux/nvim Ctrl-h/j/k/l TmuxNavigate keybinding runtime checks PASS against the real guest |
| 7 (remove lazy.nvim) | 7 | 0 | 0 | |
| 8 (NixVim config) | 15 | 0 | 1 | |
| 9 (host contracts) | 100 | 0 | 0 | |
| 10 (docs contracts) | 142 | 0 | 0 | |
| 20 (--skip-integration truthfulness) | 10 | 0 | 0 | |
| 21 (refactor state machines) | 24 | 0 | 0 | |
| 22 (bootstrap publication) | 24 | 0 | 0 | transactional generation/lease/publication machinery, all PASS |
| 12 (host-agnostic guest bootstrap) | 0 | 0 | 1 | **SKIPPED — see Finding/Observation below** |
| 13 (final review) | 9 | 0 | 0 | live: no private keys tracked, flake.lock present, SSH hardening, passwordless sudo works for dx |
| 14 (Tinty theming) | 142 | 0 | 2 | |
| 15 (Nushell env) | 12 | 0 | 0 | |
| 16 (persist storage) | 39 | 0 | 1 | |
| 17 (dx-ai runtime) | 44 | 0 | 0 | **live `dx-ai` install completes successfully inside the real guest; `codex`, `gemini`, `claude`, `agy`, `herdr` all available afterward; agy OAuth-persistence fixes and persisted-Gemini-storage checks pass; D-Bus keyring address written** |
| 23 (Herdr integration) | 41 | 0 | 0 | live: herdr on PATH, `herdr --version` runs, `~/.config/herdr` and `~/.local/state/herdr` symlinked to `/persist`, `config.toml` has `pane_history = true` |
| 24 (Herdr config persistence) | 10 | 0 | 1 | skip: "Herdr merger and persistence execution need the guest Linux toolchain; covered by run-coverage-linux.sh and CI" — self-documented gate reference (G2) |
| 25 (Nix-store import) | 0 | 0 | 1 | skip: "requires root in the isolated Linux GNU-tar runner" — self-documented gate reference (G2 kcov; matches the task brief's own framing of this gate) |
| 18 (mount plans/manifests) | 24 | 0 | 0 | includes a deliberate "Error: unsafe or malformed legacy mount manifest: ..." line — printed by the code under test as a negative-path fixture (hostile-manifest rejection), not a real failure |
| 19 (reverse/forward runtime) | 7 | 0 | 0 | live: host loopback HTTP fixture reachable, `dx-reverse` starts/lists/tears down a real guest-to-host reverse forward, guest reaches the host fixture through it and loses access after `--stop` |

**Overall: "All tests PASSED!" — EXIT=0.**

### Post-run generation stability check

After the full live-tier run 2 (which restarted the container at least twice
— once via Section 11's stop/start persistence round-trip, and dx-wait-ssh
re-invocations elsewhere via `wait_for_ssh` in Sections 5/17/19 that do not
themselves restart the container but do re-confirm SSH):
`readlink /guest-bootstrap/current` = `generations/20260926T021800Z-21789`
and `.locks/leases` still lists exactly `20260926T021800Z-21789.1` — the
**same single generation** as right after the initial bring-up. No new
generation was published and no drift warning appeared anywhere in the log
(confirmed again with `grep -i "drift\|now published"` — no matches other
than the Section-9 unit tests exercising the drift-report function in
isolation). This confirms the content-hash-based resync dedup
(`dx_bootstrap_lease_generation` / the "re-syncing identical content
publishes no new generation" assertion covered in Section 22) held correctly
across every real restart in this run: identical bootstrap content, restarted
container, zero drift.

`container list --all` after the run: `dx-test` **running**,
`192.168.64.50/24`, started `2026-09-26T02:23:35Z` (later than the original
`02:18:00Z` — it was legitimately restarted by Section 11's own stop/start
test, which is expected). `dx-host` and `dx-opencode` remained **stopped**
throughout this entire task, untouched; `buildkit` remained running,
untouched. No `dxe-scratch-*` containers were created or left behind. Per
the task's instruction, `dx-test` is being left **running**, exactly as the
live tier left it — not stopped or destroyed.

### Observation — Section 12 does not run "in the guest"

`tests/test_section12_validate_linux.sh` ("Validate Host-Agnostic Guest
Bootstrap") skips with "Not running on Linux, skipping Section 12 tests".
This is a **host**-side `uname -s` check evaluated by the process directly
executing `run_all_tests.sh` — here, the macOS host running
`./bin/dx-profile dx-test bash tests/run-tier.sh live` — evaluated *before*
any container/guest interaction. It tests whether `bootstrap.sh` works when
invoked directly on a bare Linux host with no Apple `container` involved at
all; it only runs for real when the test-runner process is itself on Linux.
Checked: `grep -n "section12\|Section 12" tests/run-coverage-linux.sh`
returns nothing — the G2 gate (the `dxe-kcov` Ubuntu container) does not
invoke this section either. **So in this Step 4 baseline (macOS host running
both G2 and the live tier), Section 12's assertions were not exercised by
any gate that actually ran.** This is recorded factually as a coverage gap,
not fixed.

## G3 — Section 12 in the guest

Following Observation B above, Section 12 (`tests/test_section12_validate_linux.sh`)
was run for real inside `dx-test` (a genuine `aarch64-linux` guest with Nix),
which is what this test is designed for and what neither G2 nor either
live-tier attempt exercised.

**Method (test file not edited).** `tests/test_helpers.sh` computes
`BASE_DIR`/`CONTAINER_DIR`/`BOOTSTRAP` as plain unconditional path
assignments derived from the test file's own location
(`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`,
`BASE_DIR="$SCRIPT_DIR/.."`,
`CONTAINER_DIR="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"`) —
there is no environment-variable override for these. So the repository's
real relative layout (`tests/` next to `container/...` and `bin/lib/...`)
was copied into the guest instead:

1. `git archive HEAD | tar -x -C <scratchpad>/dxe-repo-snapshot` — a clean
   178-file, 1.3MB snapshot of every tracked file at `bd2418f` (no keys/
   secrets: those are gitignored, so `git archive` never includes them).
2. `./bin/dx-profile dx-test ./bin/dx-put <scratchpad>/dxe-repo-snapshot /tmp/dxe-baseline/`
   — copied via the repository's own `dx-put` helper (tar piped through
   `container exec`, not scp/ssh), landing at
   `/tmp/dxe-baseline/dxe-repo-snapshot/`, owned `dx:dx`. This is ephemeral
   guest state under `/tmp`, not `/persist` — nothing durable was added.
3. Command:
   ```
   container exec -u dx dx-test bash -lc \
     'cd /tmp/dxe-baseline/dxe-repo-snapshot && bash tests/test_section12_validate_linux.sh'
   ```
   Run detached, output redirected to a run log retained privately from
   the host side. Took under 90 seconds wall clock (warm
   Nix/cache.nixos.org cache from the earlier live tier run — `nix
   profile add` mostly hit already-fetched store paths).

**Result: 14 passed, 1 failed, 0 skipped. Exit 1.**

```
Testing: bootstrap.sh runs on Linux
✓ PASS: bootstrap.sh exists for Linux validation
Testing: nix profile add from flake
✓ PASS: Nix tools install through flake
✓ PASS: codex absent from default profile
✓ PASS: gemini absent from default profile
✓ PASS: claude absent from default profile
✓ PASS: agy absent from default profile
✓ PASS: herdr absent from default profile
Testing: nix profile add from ai-tools output
✓ PASS: Nix AI tools install through flake
✓ PASS: codex present in ai-tools profile
✓ PASS: gemini present in ai-tools profile
✓ PASS: claude present in ai-tools profile
✓ PASS: agy (Antigravity CLI) present in ai-tools profile
✓ PASS: herdr present in ai-tools profile
Testing: nvim --headless +q
✓ PASS: NixVim launches with nvim --headless +q
Testing: bootstrap idempotency
✗ FAIL: bootstrap.sh has idempotency checks
```

**14/1/0 — the substantive G3 checks all passed**: the `default` and
`ai-tools` flake outputs both install cleanly into separate `nix profile`s
inside the real guest, no AI CLI tool leaks into the `default` profile, all
five (`codex`, `gemini`, `claude`, `agy`, `herdr`) are present in the
`ai-tools` profile, and NixVim launches headless. The one failure is a stale
source-text assertion, not a defect in `main` — **Finding 4**.

**Finding 4 (recorded, not fixed, per instruction).** The failing assertion:
```sh
if grep -q "if.*grep.*bashrc\|if.*id -u" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh has idempotency checks"
else
    test_fail "bootstrap.sh has idempotency checks"
fi
```
(`tests/test_section12_validate_linux.sh:108`, `$BOOTSTRAP` =
`container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh`) is a
stale source-shape heuristic dating from when `bootstrap.sh` was a single
monolithic script. `bootstrap.sh` is now a 49-line thin orchestrator that
only defines `bootstrap_main()` (a fixed call sequence) and sources six
library files — `scripts/lib/dx-keyring.sh`, `bootstrap/common.sh`,
`bootstrap/base-and-storage.sh`, `bootstrap/system.sh`,
`bootstrap/persistence.sh`, `bootstrap/herdr-config.sh`,
`bootstrap/activation.sh` — before calling it. It contains neither literal
substring the regex looks for. The idempotency checks the assertion is
looking for do exist in `main`, just in the sourced modules: e.g.
`bootstrap/persistence.sh:32` reads
`if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then` (guarding
user/group creation so a re-run doesn't fail on an already-created `dx`
user), with further `id -u`/`id -g` guards in `bootstrap/system.sh` and
`bootstrap/activation.sh`. Because Section 12 runs in no gate that this
baseline (or, apparently, any prior CI run) actually exercises, this
assertion's rot went unnoticed after the monolithic-to-modules refactor
(matching Section 3's title, "Sourceable Guest Bootstrap"). Consistent with
this: Section 11's stop/start persistence round trip and the live tier's
several container restarts (recorded above, all drift-free, same
generation) directly demonstrate `main`'s guest bootstrap re-runs cleanly
and idempotently in practice. Per the coordinating session's instruction,
this is recorded here with its exact cause and NOT fixed in this task.

## Summary

On `main` (`bd2418f`), from a completely factory-reset `dx-test` profile
(container, image, all three volumes, and the SSH keypair destroyed and
recreated by the repository's own documented tooling):

- **G2 (coverage): PASS.** `covered=100% scope_share=21.43%`.
- **G3/G4 (live, fresh guest): PASS.** After a manual, non-interactive
  bring-up using the same lifecycle layer scripts `bin/dx` itself runs
  (`dx-create-image` → `dx-create-volumes` → `dx-create-container` →
  `dx-start-container` → `dx-wait-ssh`), the guest built and booted a real
  `aarch64-linux` NixOS 26.05 environment via Apple `container` in
  approximately 4-5 minutes of actual bootstrap time (warm `cache.nixos.org`
  cache, no source builds). The full `tests/run-tier.sh live` suite then ran
  against that guest end to end and reported **"All tests PASSED!" EXIT=0**
  — every section, including the ones that only run destructive/live guest
  work (Section 11's fresh-container validate-and-persist round trip,
  Section 17's real `dx-ai` install of `codex`/`gemini`/`claude`/`agy`/
  `herdr` inside the guest, Section 19's real reverse-tunnel networking
  test).
- **G3 — Section 12 in the guest: 14 passed, 1 failed, 0 skipped.** Run for
  real inside `dx-test` (see the dedicated section above). All the
  substantive checks passed (default/ai-tools flake outputs install into
  separate profiles, no AI tools leak into the default profile, all five AI
  CLIs present in the ai-tools profile, NixVim launches headless); the one
  failure is a stale source-text assertion (**Finding 4**), not a defect in
  `main` — recorded, not fixed.
- **Findings/observations recorded, neither fixed here** (per the
  coordinating session's decision — both are out of scope for this
  baseline-check task):
  - **Finding 1 (production code):** `bin/lib/dx-container.sh`'s
    `container_is_running`/`container_exists` can spuriously report "not
    running" due to a `grep -q` + `pipefail` SIGPIPE race against
    `dx_container_list_names`'s `printf` loop, which made `bin/dx-wait-ssh`
    falsely conclude a healthy, still-bootstrapping guest had stopped and
    exit 1. Reproduced once during this check; the guest was never actually
    affected (bootstrap continued uninterrupted) and a plain re-run of
    `dx-wait-ssh` succeeded normally once the false report cleared.
  - **Observation A (test scaffolding):** `tests/test_section4_ssh.sh`'s
    "key-only SSH live probe succeeds" check fails outright rather than
    skipping when the guest is absent (`if requires_container && cmd; then
    pass; else fail; fi`, unlike the other 11 `requires_container()` call
    sites which all skip). Only reachable/visible when the live tier is run
    against a container that was never brought up first (attempt 1 of this
    check); does not affect the successful attempt-2 run.
  - **Observation B (coverage gap):** `tests/test_section12_validate_linux.sh`
    ("Validate Host-Agnostic Guest Bootstrap") is gated on the *host's*
    `uname -s`, not the guest's, and is not exercised by either G2
    (`run-coverage-linux.sh`, which never references section 12 in its own
    script) or a macOS-run live tier — so its assertions were not exercised
    by any gate run in this baseline (now closed — see G3 above). This is a
    coverage gap to flag, not a behavioural bug in `main`.
  - **Finding 4 (test scaffolding, stale assertion):** Section 12's
    "bootstrap.sh has idempotency checks" check greps only the thin
    49-line `bootstrap.sh` orchestrator for patterns from before it was
    split into `bootstrap/*.sh` modules; the idempotency guards it's
    looking for exist in those modules (e.g. `bootstrap/persistence.sh:32`).
    Rotted unnoticed because Section 12 runs in no gate. See the dedicated
    section above for detail.
- No production code was changed. `dx-test` was stopped at the end of this
  task (`./bin/dx-profile dx-test ./bin/dx-stop-container`), with its
  volumes intact, after Section 12 was exercised in the guest. No
  `dxe-scratch-*` containers remain. `dx-host`/`dx-opencode` and their
  volumes/keys were never touched.

**Bottom line: `main` at `bd2418f` builds and runs correctly on a real,
from-scratch Apple `container` guest, and both the coverage gate and the
in-guest Linux/Nix gate are substantively green.** The only issues found are
three narrow test-harness gaps (Observations A/B, Finding 4) and one
intermittent, non-fatal, already-diagnosed production polling bug (Finding
1) in the host-side liveness check — none of which reflect a defect in the
guest build, boot, or runtime behaviour itself.
