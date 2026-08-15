# `dx-herdr` implementation review

Initially reviewed 2026-08-03 against `herdr-plan.md`. The original blockers and
findings were subsequently remediated and live-tested; that history is retained
below.

**Current verdict, 2026-08-04: remediation and the final isolated live gate are
complete; no known R1–R5 blocker remains.** The three high-severity and two
medium follow-up defects are fixed, their focused regressions pass, a freshly
factory-reset `dx-test` booted successfully, the updated Home Manager generation
was activated through `dx-recreate`, the complete live suite exited 0, and the
isolated Linux sourceable-shell coverage ratchet is at 100%. The low-priority R6
inventory/snapshot-cleanup opportunities and documented opt-in skips remain;
they are not merge blockers.

The original review and its live evidence are retained below. Claims in the
R1–R6 analysis describe the pre-remediation working tree; the status table and
validation results immediately below are the current source of truth.

## Post-review corrections (2026-08-04, later)

An independent re-assessment re-ran every tier and found four defects in the
remediation itself, plus two stale claims in this document. All are fixed.

| # | Finding | Fix |
| --- | --- | --- |
| P1 | The coverage ratchet was **lowered below the tree's actual value**. `ratchet.env` recorded 1953 bp from a mid-change measurement (2,187 / 11,196) that was never re-taken; the finished branch measured 1968. The gate was carrying 15 bp of unearned slack and would have passed a real ~18-line regression in silence | Baseline re-measured against the *completed* tree (2,348 / 11,992 = **1957 bp**) with the mid-change hazard recorded in the file |
| P2 | `dx_ssh_append_common_options` was dead production code retained **solely to keep a coverage probe green** — its own comment said so — and had silently drifted from the real options (no `-i`, `IdentitiesOnly`, or `ConnectTimeout`) | Function and its probe deleted. The gate must be satisfied by exercising live code, never by preserving dead code |
| P3 | R4 fixed nested-quote breakage for the workdir but **not for the command body**, which was still interpolated into the single-quoted `bash -l -c '...'` program. A body containing `'` failed `bash -n`; only caller luck (no apostrophes) hid it | `dx_guest_bash_command` now base64-transports the body through `DX_GUEST_CMD_B64` and `eval`s it guest-side, sharing one `dx_guest_base64` encoder with the workdir. `eval` rather than a pipe into `bash -l` is required: interactive callers need the pty on stdin |
| P4 | `DX_AI_TOOLS` became **load-bearing without a guard**. It drives `dx_ai_validate_generation` and `dx_ai_verify`, so a name added there but missing from `flake.nix`'s `aiPackages` makes *every* generation fail validation — a worse failure mode than the cosmetic duplication F13 described | Contract test ties `DX_AI_TOOLS` to `aiPackages` (prefix match, since these are binary names and `claude` ships in `claude-code`) and to `dx-herdr`'s user-facing install message. Verified to fail on a deliberately drifted list |

Fixing P3 exposed a fifth issue worth recording: **every fake `ssh` in the suite
matched plaintext substrings of the remote command**, so the moment the body
became opaque, five Section 23 assertions failed. They were not wrong to fail —
they were reading the wrapper, not what the guest was asked to do. The fakes now
share `fake_ssh_write`, which decodes the payload exactly as the guest's inner
bash does and exposes `DX_FAKE_GUEST_RAW` (assert the boundary) separately from
`DX_FAKE_GUEST_CMD` (assert the request). This is the same fixture-versus-guest
pattern the L-series section names, caught one layer up.

Two corrections to this document's own claims:

- **The Section 22 `/proc` blocker is stale.** `run-tier.sh unit/static`,
  `host-contract`, and `run-bash32-tests.sh` all exit **0** on the macOS host.
  The aggregate does not stop anywhere.
- **`covered=100%` does not cover R5's code.** The gate's scope is `bin/lib`,
  `bootstrap/`, and `scripts/lib`; `scripts/dx-ai.sh` is outside it, so
  `dx_ai_boot_id`, the `dx_ai_process_start` rewrite, and `--supports` are
  exercised by Section 17 but not gated at 100%.

Post-fix validation: unit/static, host-contract and Bash 3.2 tiers all exit 0;
isolated Linux coverage **`covered=100%`, scope share `19.57%`**;
`git diff --check` clean. Live on `dx-host`: the new body transport carries
`echo "it's fine" && printf '%s\n' 'quoted arg'` to the guest and runs it
correctly (rc=0), and the interactive builder path attaches and returns rc=0.

### L6 is not merely a workflow property

L6 was recorded below as "Documented — start twice". It is not that benign, and
it cost a real boot on 2026-08-04: a `dx-recreate` on **`dx-host`** ran the
*previous* generation, hit the pre-existing L1 defect, and died silently at
"Setting up D-Bus keyring service...". The guest entrypoint's wait loop exits as
soon as `$root/current` exists — which it always does after any earlier sync —
so **every `dx-recreate` following a bootstrap edit runs stale code**. A second
`dx-start-container` booted the fixed generation and reached "Guest bootstrap
complete".

Two consequences worth stating plainly: the trap is documented only in this
review file, not in `docs/` or `README.md`; and until this work is committed,
**`main` alone cannot boot an AI-tools-enabled guest at all**, because the L1
fix exists nowhere else.

## Follow-up remediation status (2026-08-04)

| # | Sev | Status | Current implementation/evidence |
| --- | --- | --- | --- |
| R1 | High | Fixed | Persistence rejects symlinks at the persistent mount/home boundary, both base directories, `.local` ancestors, immediate parents, final targets, and readiness markers before mutation. Adversarial fixtures cover `/persist/home`, `.local`, final targets, and outside-marker preservation |
| R2 | High | Fixed | Every persistence mutation and both `run_as_dx` link operations propagate failure explicitly. A forced first-link failure returns non-zero and never reaches state linking |
| R3 | High | Fixed | Bootstrap remains warning-only, but activation invalidates stale markers safely, verifies both links/config, and publishes readiness atomically. `dx-herdr` checks real non-symlink persistent targets, exact home links, config, and marker before package probing or attach |
| R4 | Medium | Fixed | The shared SSH builder base64-transports `DX_GUEST_WORKDIR` across the login-shell boundary and decodes it inside Bash. Apostrophe/newline/space/leading-dash structure tests and an end-to-end local command probe pass |
| R5 | Medium | Fixed | `dx-ai` parses `/proc/<pid>/stat` field 22 in Bash (including complex command names), prefers the kernel boot UUID, falls back to an explicitly tagged `/proc/stat` `btime`, and fails closed without either complete identity. Existing UUID owner records remain compatible |
| R6 | Low | Mostly fixed | `dx-herdr` enforces exact help arity and `docs/guest.md` now describes immutable `/guest-bootstrap`, mutable generations, and readiness preflight. Inventory consolidation and two destructive/upstream snapshot acceptance cases remain optional follow-up work |

### Remediation validation

| Check | Current result |
| --- | --- |
| `git diff --check` | Pass |
| Bash syntax over changed Herdr/SSH/bootstrap/test files | Pass |
| Section 23, `--skip-integration` | **39 passed, 0 failed, 1 live skip** |
| Section 9 / host scripts | **76 passed, 0 failed** |
| Section 10 / docs | **98 passed, 0 failed** |
| Section 17 / `dx-ai`, offline | **21 passed, 0 failed, 1 live skip** |
| Section 17 / `dx-ai`, live | **32 passed, 0 failed, 0 skipped** |
| Section 23 / Herdr, live | **44 passed, 0 failed, 0 skipped** |
| Host-contract tier | **24 passed, 0 failed** |
| Complex workdir command execution | Pass with apostrophe, newline, spaces, and a leading-dash basename |
| Isolated Linux coverage | **Pass: `covered=100%`, scope share `19.68%`** |
| Aggregate `run-tier.sh unit/static` | Reconfirmed 2026-08-04: affected sections pass; aggregate later stops in the pre-existing macOS `/proc`-dependent Section 22 lock test |
| Aggregate `run-bash32-tests.sh` | Reconfirmed 2026-08-04: Section 9 passes **76/0/0** and Section 18 passes **24/0/0** under Bash 3.2; aggregate later stops at the same pre-existing `/proc` test |
| Fresh `dx-test` factory-reset bootstrap | **Pass** — authenticated SSH ready after approximately 421 s; Herdr persistence links, ownership, modes, and readiness marker verified |
| Updated `dx-test` recreate | **Pass** — authenticated SSH ready after 62 s with persistent volumes/keys preserved and the new Home Manager `dx-ai` store generation active |
| Complete live suite on `dx-test` | **Pass (exit 0, all dispatched sections)** |

### Final isolated live revalidation

The final merge gate used only the `dx-test` profile (container `dx-test`, image
`dx-test-nixos`, SSH port 2299, and `dx-test-*` volumes/keys). The primary
`dx-host` profile was not restarted or mutated.

The canary was first factory-reset, including its isolated volumes and keypair,
then bootstrapped from an empty state. The initial bootstrap reached
authenticated SSH and produced the declared Herdr layout:

```
/home/dx/.config/herdr      -> /persist/home/dx/.config/herdr
/home/dx/.local/state/herdr -> /persist/home/dx/.local/state/herdr
targets:                    drwx------ (0700) dx:dx
.dxe-persistence-ready:     -rw------- (0600) dx:dx
```

That first live suite found one additional portability defect in R5's first
implementation: the Apple-container guest did not expose `awk` at that early
runtime boundary and, during the failing boot, did not expose
`/proc/sys/kernel/random/boot_id` even though `/proc/stat` contained `btime`.
`dx-ai` therefore failed safely with `cannot identify lock owner process`, but
could not publish the bundle. The remediation removed the `awk` dependency,
added the tagged `btime:<epoch>` fallback, retained raw UUID compatibility, and
kept the fail-closed behaviour when neither identity is available. Focused
fixtures cover complex `/proc/<pid>/stat` command fields, UUID identity,
`btime`, acquisition with the fallback, and total identity failure without
reclaiming an existing lock.

One deployment lesson also surfaced: `dx-sync-bootstrap` publishes the new
immutable source generation, but it does not replace a Home Manager-installed
`~/.local/bin/dx-ai` already pointing into the Nix store. The first retry still
executed that stale store path. This is not a runtime defect in `dx-herdr`; a
`dx-recreate` is required to activate changes to Home Manager-installed helper
scripts. After recreation, the resolved store path changed, the helper reported
Herdr capability, and its live PID/boot identity probe succeeded.

Final evidence:

- focused Section 17 live: **32 passed, 0 failed, 0 skipped**;
- focused Section 23 live: **44 passed, 0 failed, 0 skipped**;
- complete `tests/run_all_tests.sh` live tier under `dx-test`: **exit 0, all
  tests passed**;
- Section 17 inside the complete tier: **32/0/0**;
- Section 23 inside the complete tier: **44/0/0**;
- isolated Linux coverage: **`covered=100%`, scope share `19.68%`**;
- `git diff --check` and Bash syntax checks: **pass**.

The full run's skips were the repository's existing explicit platform,
destructive opt-in, or inconclusive probes (for example ShellCheck/Nix absent on
the macOS host, Linux-only Section 12, destructive persistence/tmux checks, and
one inconclusive project-history data probe). No Herdr or `dx-ai` live assertion
was skipped.

## Follow-up findings that prompted remediation (historical pre-fix analysis)

| # | Sev | Finding at review time | Reproduction before the fix |
| --- | --- | --- | --- |
| R1 | High | Persistence hardening followed symlinked ancestors | `setup_herdr_persistence` returned 0 and created `state/herdr` through a symlinked `$persist_home/.local` |
| R2 | High | Intermediate persistence failures were swallowed | First home-link operation returned 1, state linking was still reached, and the function returned 0 with the config link absent |
| R3 | High | A failed non-fatal activation was invisible to `dx-herdr` | Bootstrap logged a warning and continued while the wrapper could launch without the documented persistence layout |
| R4 | Medium | The shared SSH command builder broke on a valid workdir containing `'` | Generated command failed `bash -n` with exit 2 |
| R5 | Medium | Missing boot IDs made the `dx-ai` lock owner record unsafe | A simulated live owner was reclaimed immediately when `dx_ai_boot_id` returned empty |
| R6 | Low | Small CLI/docs/acceptance gaps remained | `dx-herdr --help trailing` exited 0 and docs inaccurately described updating `/guest-bootstrap` |

The detailed R1–R6 sections below intentionally preserve the original
reproductions and recommendations. Those recommendations have been implemented
except for the explicitly retained low-priority R6 opportunities.

### R1 — High: only immediate symlink components are rejected

[`setup_herdr_persistence`](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/persistence.sh)
checks these paths with `-L` before mutation:

```
$persist_home/.config
$persist_home/.local/state
$home/.config
$home/.local/state
the two final Herdr targets
```

It does **not** check `$persist_home`, `$persist_home/.local`, `$home`, or
`$home/.local`. Those are ancestors of paths later passed to root-run `mkdir`,
`chown -R`, and `chmod`. `/persist/home/dx` is owned by `dx`, so a prepared
`.local` symlink is within the user-controlled threat boundary this hardening is
supposed to close.

Focused reproduction against a disposable tree:

```
ancestor_symlink_rc=0 outside_state_created=yes
```

The test symlinked `$persist_home/.local` to an outside directory. Activation
accepted it and created `outside/state/herdr`. The existing Section 23 cases
cover a symlinked final target and an immediate `.config` parent, but not an
ancestor.

**Recommendation:** validate every component from each trusted root to the
target without dereferencing it (or open/traverse with no-follow semantics),
and add `.local` plus base-directory cases to the behavior tests. At minimum,
explicitly reject symlinks at `$persist_home`, `$persist_home/.local`, `$home`,
and `$home/.local` before the first mutation.

### R2 — High: non-fatal activation suppresses failures inside persistence setup

`configure_guest` invokes:

```bash
dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2
```

In Bash, invoking a function in an `||` list disables `errexit` for commands in
that function call chain. `setup_herdr_persistence` relies on ambient
`set -e` for most `mkdir`, `mv`, `chown`, `chmod`, and `run_as_dx` operations
instead of guarding each one. A failed config-side link can therefore be
ignored, the state-side work can succeed, and the function can return success.

Focused reproduction:

```
partial_failure_rc=0 config_link=no state_call_reached=yes
```

The first `run_as_dx` was forced to fail and the second to succeed. Setup
reported success with `~/.config/herdr` absent. This is a partial activation,
not merely a diagnostic problem: Herdr can then use an ephemeral home path
while the bootstrap believes persistence is ready.

**Recommendation:** make every mutating operation explicitly checked with
`|| return 1` (including both link operations), rather than depending on
ambient `errexit`. Add a regression test that fails the first link and asserts
non-zero status, no continuation into state setup, and a visible warning from
`configure_guest`.

### R3 — High: `dx-herdr` does not verify that persistence activation succeeded

Making Herdr activation non-fatal is proportionate — optional configuration
must not prevent SSH from starting — but the failure is only written to the
bootstrap log. [`dx-herdr`](bin/dx-herdr) probes whether `herdr` exists and
whether `dx-ai` supports it; it never checks that `~/.config/herdr` and
`~/.local/state/herdr` are the expected persistent symlinks.

Consequently, any real setup failure (including R1/R2, ownership failure, or a
future filesystem error) can be followed by a successful attach whose state
does not meet the persistence guarantees in `docs/guest.md`.

**Recommendation:** publish an activation-ready marker only after both links,
the seeded config, ownership, and modes are verified. Have `dx-herdr` preflight
that marker/layout and fail with a repair diagnostic rather than silently
starting an ephemeral session. A warning-only bootstrap and a fail-closed
feature entry point give the desired blast radius without risking session data.

### R4 — Medium: the remote command boundary is not quote-safe for workdirs

`dx_guest_workdir_snippet` uses `printf %q`, then
`dx_guest_bash_command` interpolates the result inside another single-quoted
`bash -l -c '…'` argument. `%q` protects a token for direct Bash parsing; it
does not make that token safe inside an already-open single-quoted string.

For `DX_GUEST_WORKDIR=/tmp/dxe-review-o'clock`, the generated command contains:

```
bash -l -c 'cd /tmp/dxe-review-o\'clock && true'
```

and fails syntax validation (`quoted_workdir_parse_rc=2`). `dx-mount` derives
the workdir from a real repository path and emits it with `%q`, so apostrophes
and newlines are representable inputs, not forbidden configuration values.

**Recommendation:** transport the workdir and command as positional data or a
base64 payload rather than nesting shell quoting. Add workdir fixtures covering
apostrophes, newlines, spaces, and leading dashes to both interactive `dx-ssh`
and `dx-herdr` boundary tests.

### R5 — Medium: `dx_ai_boot_id` turns missing identity data into lock stealing

The new `dx_ai_boot_id` deliberately returns empty when
`/proc/sys/kernel/random/boot_id` is unavailable. `dx_ai_lock_acquire` then
writes an owner record whose first tab-separated field is empty. Bash `read`
with whitespace `IFS` does not preserve that leading empty field, and the next
owner check also compares the recorded value with an empty current boot ID.
The record is therefore treated as stale even when the PID/start identity is
live.

The focused probe returned:

```
missing_boot_id_acquire_rc=0 prior_live_owner_replaced=yes
```

This does not affect the normal NixOS guest, where `/proc` supplies a boot ID,
but it contradicts the helper's stated sandbox/macOS tolerance and makes
concurrent sourced/test use unsafe.

**Recommendation:** either fail lock acquisition when required identity fields
cannot be obtained, or define an explicit versioned fallback record that uses
PID/start identity without an ambiguous empty field. Add a two-owner test for
the missing-boot-ID path.

### R6 — Low: remaining contract and documentation opportunities

- `dx-herdr --help trailing` currently exits 0; the declared
  `dx-herdr [--help]` grammar should reject all extra arguments with 64.
- `docs/guest.md` says `dx-ai` updates `nixpkgs-unstable` "in
  `/guest-bootstrap`", while `dx-ai` stages and publishes a mutable generation
  under `/persist/home/dx/.local/state/dx-ai` and deliberately never modifies
  the published bootstrap. Describe `/guest-bootstrap` as the immutable source.
- F13 remains partial: the five-tool inventory is still repeated in Nix, the
  host install message, and prose.
- The corrupt/too-new snapshot recovery and the deletion half of pane-history
  cleanup remain unautomated acceptance cases.

**Current status:** the CLI arity and `/guest-bootstrap` documentation defects
are fixed, and readiness preflight is documented. The inventory consolidation
and two live acceptance cases remain low-priority follow-up opportunities; they
do not reopen R1–R5.

### Validation at discovery time (historical)

| Check | Result before R1–R6 remediation |
| --- | --- |
| `git diff --check` | Pass |
| Bash syntax over changed Herdr/SSH/bootstrap/test files | Pass |
| Section 23, `--skip-integration` | **31 passed, 0 failed, 1 live skip** |
| Section 9 under Bash 3.2 | **74 passed, 0 failed** |
| Aggregate `run-tier.sh unit/static` | Did not complete: Section 22 fails on this macOS host with the pre-existing `/proc`-dependent `cannot identify lock owner process` |
| Aggregate `run-bash32-tests.sh` | Same later Section 22 `/proc` failure; Herdr/SSH Section 9 passed first |
| Nix evaluation, coverage, live `dx-test` | Not re-run in this follow-up; the successful prior runs below remain recorded, but do not cover R1–R5 |

The three focused reproductions used disposable temporary trees and did not
touch guest/container state. At that discovery checkpoint, no implementation
files had yet been changed.

## Prior remediation status (historical)

Updated earlier on 2026-08-04. Every finding from the *original* review was
implemented, and all tiers passed at that checkpoint, including the **live tier
on `dx-test` (exit 0, all sections)**. This table remains useful evidence for
the resolved B/F/L items, but it predates follow-up findings R1–R6 and is not
the current merge verdict.

| Tier | Result |
| --- | --- |
| `run-tier.sh unit/static` | All passed |
| Bash 3.2 (`run-bash32-tests.sh`) | 55 passed, 0 failed |
| Coverage (`run-coverage-linux.sh`) | exit 0, `covered=100%` |
| `nix flake check` on the committed lock | Passes (was `undefined variable 'herdr'`) |
| Real `aarch64-linux` closure build | Built in-guest; `herdr --version` → `0.7.5` |
| **Live tier on `dx-test`** | **exit 0 — all sections passed**, Herdr live block included |
| `git diff --check` | Clean |

| # | Status | Evidence |
| --- | --- | --- |
| B1 | Fixed | Lock bumped to `23ba3b80…` (2026-08-03); only `nixpkgs-unstable` moved. `nix flake check` on the committed lock now passes; `ai-tools` closure built in `dx-test`; `herdr --version` → `0.7.5`, `AGPL-3.0-or-later` |
| B2 | Fixed | `test_bootstrap_publication.sh` restored; Herdr moved to section **23** rather than renumbering; a contract test now fails if any suite is undispatched or any `KNOWN_SECTIONS` entry is orphaned |
| F1 | Fixed | All guest commands cross `env … bash -lc`. Proven live: `command -v ls` → `rc=0` + token, bogus command → `rc=1` (raw form previously returned 1 for both) |
| F2 | Fixed, proven live | Probe emits `DX_HERDR_PRESENT`; ssh 255 routes to a distinct unreachable diagnostic instead of advising `dx-recreate`; key checked before probing. Live on `dx-test`: a closed port yields *"could not reach the DX guest over SSH"*, while a genuinely stale helper still yields the D1 `dx-recreate` diagnostic with no install attempted |
| F3 | Fixed | `exec` dropped, status captured and returned, cleanup runs; double "Connecting…" removed; dead `quiet` parameter deleted |
| F4 | Fixed | `dx_activate_herdr` now runs unconditionally in `configure_guest`, outside the AI-tools guard |
| F5 | Fixed | `-L` rejection on both persistent targets and their parents before any mutation; `chown -h`; backups get explicit `dx:dx` + `0700` |
| F6 | Fixed | Assertions branch in the parent shell. Section 23 now counts 31 offline assertions rather than silently retaining only 3. Verified by deliberate breakage in both directions |
| F7 | Fixed | Table-scope-aware two-pass pure-Bash seeder; atomic `mktemp` + `mv` publication; fail-closed on constructs it cannot parse. The reproduced corruption cases are covered |
| F8 | Fixed | Success-path lock release and trap clearing restored, with a sourced success-path test |
| F9 | Fixed | Deleted `malicious` legacy-keyring probe restored; Herdr probes extended to the new branches |
| F10 | Fixed | One source of truth for options/env prefix/workdir snippet; `bin/dx-herdr` contains no `ssh` invocation (contract-tested) |
| F11 | Fixed | Both `HERDR_*` assignments removed per plan H3 |
| F12 | Fixed | `cleanup_osc` → `dx_ssh_cleanup_osc`; pointless `export TERM` removed |
| F13 | Partial | Collapsed to one `DX_AI_TOOLS` declaration inside `dx-ai.sh`. The list still appears literally in `flake.nix`, `bin/dx-herdr`'s install message, and `docs/guest.md` prose |
| F14 | Fixed | False "prompt to install" corrected; sensitive-output warning, cleanup procedure, cold-upgrade workflow and AGPL note added, with docs-contract assertions |
| F15 | Fixed | `--supports` arity is now a usage error (64); EOF blank line removed |

Offline tier results: coverage gate `covered=100%` (exit 0, `dx-ssh-common.sh`
5.26% → 100%), `run-tier.sh unit/static` all passed, Bash 3.2 55 passed,
`git diff --check` clean.

**A historical kcov constraint that shaped this remediation.** The bash tracer
credits only the *starting line of a simple command*. Two consequences surfaced:

- A multi-line quoted program (the original `awk` seeder) is one simple command,
  so every interior line read as permanently uncovered. That implementation was
  later removed after live validation showed `awk` was unavailable during early
  bootstrap; the current seeder is pure Bash.
- `done < "$file"` is not a simple command, so a loop terminator carrying a
  redirection is reported executable-but-never-hit and blocks the 100% gate on
  its own. The seeder therefore uses explicit file descriptors
  (`exec 3< …` / `exec 4> …`) and bare `done` lines.

The explicit-FD loop shape remains in the current pure-Bash seeder. Replacing it
with a redirected `done` line will silently fail the coverage gate.

Two defects were introduced *by this remediation* and then fixed: the SSH
refactor added eight library functions with no coverage probes, and the new F8
test tripped `dx_ai_main`'s root guard inside the coverage container. Both are
recorded here because the coverage gate caught them and a reviewer should know
the gate earned its keep.

### Live validation: three boot-blocking defects, found in sequence

Live validation on `dx-test` uncovered three separate defects, each masked by
the previous one. They are recorded in the order they surfaced, because that
order is the useful part: **each fix revealed the next failure**, and none of
them was visible to a green offline suite.

| # | Defect | Origin | Status |
| --- | --- | --- | --- |
| L1 | `setup_keyring_service` runs before Home Manager installs `dbus-daemon`; bare assignment under `set -e` kills bootstrap **silently** | Pre-existing (commit `59c7b7b`) | Fixed — reordered behind an `ai_tools_enabled` flag, plus an explicit diagnostic |
| L2 | `setup_herdr_persistence` leaves home-side parents root-owned, so `run_as_dx "ln -sfnT …"` fails `Permission denied` | **This Herdr work** — violates a plan requirement | Fixed — parents chowned `dx:dx`; `0700` applied only to directories the function creates |
| L3 | A recreate run while the L2 fix was still being written re-ran the old bootstrap and reproduced L2's error, briefly suggesting the fix had failed | Process, not code | Resolved — a clean publish + restart boots to completion |
| L4 | The guest **restarts mid-install** during `dx-ai`, killing the SSH connection; `dx-herdr` reports `failed to install AI tools bundle` after ~7s | Transient — guest was mid-recovery from a reformatted Nix volume | **Did not recur.** A retry on a healthy guest installed the full bundle in 126 s with the guest staying up |
| L5 | `awk` is not on `PATH` at activation time, so the new seeder fails, the failure propagates, and **bootstrap dies**. The diagnostic blames the user's TOML | **This remediation** — F7 + F9 + F4 interacting | **Fixed and verified live** — seeder rewritten in pure bash, activation made non-fatal |
| L6 | `dx-start-container` starts the guest *before* syncing, so one start after an edit runs the **previous** bootstrap generation and a fix appears not to work | Pre-existing workflow property | Documented — start twice, or check the generation id in the log |
| L7 | Additions to the essentials profile never reach a guest that already has one (`install_essentials` is gated on `command -v useradd`) | Pre-existing | Documented — the `awk` dependency was removed rather than satisfied |

Verified live on `dx-test` after the L5 fix, on a guest that reached
"Guest bootstrap complete" with no activation warning:

```
~/.config/herdr      -> /persist/home/dx/.config/herdr        (dx:dx)
~/.local/state/herdr -> /persist/home/dx/.local/state/herdr   (dx:dx)
targets:      drwx------ (0700) dx:dx
config.toml:  -rw------- (0600) dx:dx, readable as dx
  [experimental] pane_history = true
  [advanced]     scrollback_limit_bytes = 10000000
```

That closes **F4, F5 and F7 against a real guest**, and confirms F7's
silent-broken-state risk — a root-owned config the `dx` user cannot read — does
not occur.

#### L2 — a finding this review missed

The plan states plainly: *"Create both persistent targets and their home-side
parents as `dx:dx`, mode 0700."* That was not implemented, and this review did
not catch it. The omission breaks **every fresh guest boot**, and it was only
masked because L1 killed the bootstrap earlier.

**It was also invisible to the test suite, and could not have been otherwise.**
The bootstrap fixtures stub the privilege boundary away:

```bash
chown() { :; }; run_as_dx() { :; }
```

With both as no-ops, an unchowned directory and a correctly chowned one are
indistinguishable, so a root-vs-`dx` permission bug cannot fail a test. 100%
line coverage held throughout. Line coverage proves a line *ran*, not that it
ran under the guest's privilege conditions. The regression test added for L2
therefore models the boundary — the `chown` stub tracks simulated ownership and
`run_as_dx` refuses writes into directories the simulated `dx` does not own.

#### L5 — three correct fixes combining into a boot failure

```
activation.sh: line 217: awk: command not found
Error: /persist/home/dx/.config/herdr/config.toml has TOML this seeder cannot
       update safely (quoted/dotted keys, array tables, or multi-line values);
       left unmodified.
```

Each change was right on its own:

1. **F7** rewrote the seeder to use `awk` and to fail closed rather than
   partially rewrite a config.
2. **F9/F7** removed the `|| true` that was masking failures.
3. **F4** made activation run unconditionally on every bootstrap.

Composed, they mean that at the point in bootstrap where activation runs `awk`
is not on `PATH`, seeding fails, the failure propagates, and the guest never
boots. **Seeding an optional tool's config file must not be able to stop the
guest from booting** — that is a proportionality failure, and it is the direct
result of this review demanding that masked failures be surfaced without also
asking where the failure should stop.

The diagnostic compounds it: a missing binary was reported as malformed user
TOML, sending a reader to inspect a file that is perfectly correct.

**Why it was intermittent.** `base-and-storage.sh` installs the early
essentials profile — `coreutils`, `gnused`, `gnugrep`, `which`, `util-linux`,
and no `gawk`. An earlier boot *did* seed the file correctly, but only because
that guest's Nix store still happened to carry `awk` from previous work. When
the volume was reformatted, the accident vanished. The dependency was always
broken; it was masked by store state, which is the worst kind of intermittent.

**Fixed — but not on the first attempt.** The obvious fix was to add
`nixpkgs#gawk` to the essentials list. Published, rebooted, and the guest failed
**identically**, because of L7 below: the essentials install is gated on
`if ! command -v useradd`, so on any guest that already has a profile the whole
step is skipped and a newly added package never arrives. The fix was inert.

What actually resolved it:

1. **The `awk` dependency was removed**, not satisfied. `dx_seed_herdr_config`
   now does its two-pass table-scope parse in pure bash — no external
   interpreter, so it cannot be defeated by profile state. This follows the
   precedent already set by the bootstrap launcher, whose `process_start` is
   pure `sh` for exactly this reason. All four F7 behaviours were re-verified
   with `awk` absent from `PATH`: unrelated-table seeding, the commented-header
   case that must not emit a duplicate table, preserved user values, and
   fail-closed on unparseable TOML.
2. `dx_activate_herdr` is now invoked **non-fatally** in `configure_guest`: it
   warns loudly and bootstrap continues. Confirmed live — the guest reached
   "Guest bootstrap complete" while activation was still failing.

#### L7 — additions to the essentials profile do not reach existing guests

`install_essentials` in `base-and-storage.sh` is wrapped in
`if ! command -v useradd >/dev/null 2>&1`. The guard is deliberate and its
rationale is sound (re-running `nix profile install` on every boot can conflict
with the profile's own earlier contents). The consequence is not obvious
though: **adding a package to that list has no effect on any guest that already
has an essentials profile** — only a guest with a fresh Nix store ever installs
it.

Anything the bootstrap needs must therefore either be in the base image, be
installed by a step that is not skipped, or not be needed at all. The third
option is the one taken here.

Point 3 is the general lesson. This review demanded that masked failures
(`|| true`) be surfaced — correctly — but did not say **where a surfaced
failure should stop**. Surfacing an error and choosing its blast radius are two
separate decisions; making only the first turns "Herdr config was not seeded"
into "the guest does not exist".

**The pattern worth naming.** This is the third defect here that a green suite
could not see, each for the same underlying reason — the fixture environment
differs from the guest:

| Defect | What the fixture provided that the guest did not |
| --- | --- |
| L2 | `chown`/`run_as_dx` stubbed to no-ops, erasing the privilege boundary |
| Coverage-container failure | Tests ran as root, so a root guard fired early |
| L5 | `awk` always present on the test host |

100% line coverage held throughout all three. Coverage proves a line executed;
it says nothing about whether it executed under the guest's environment.

#### L4 — the guest dies during the bundle install

With the layout verified and a Herdr-aware helper in place, the first-install
path was exercised for real. The wrapper behaved **correctly** right up to the
failure, which is itself the evidence that F1/F2 and the new `--supports` probe
work end-to-end against a live Nushell guest:

```
Herdr is not installed in the guest.
Installing optional AI tools bundle (codex, gemini, claude, agy, herdr)...
This may take a while on first install.
Refreshing Antigravity CLI manifest...
Pinned agy 1.1.10 from upstream manifest.
Updating nixpkgs-unstable...
Connection to 127.0.0.1 closed by remote host.
Error: failed to install AI tools bundle containing Herdr.
```

`ELAPSED=7s`, exit 1. The connection did not merely drop — **the container
restarted**: its start time and IP both changed, and it began re-running
bootstrap from scratch. `sshd` runs as the foreground process, so anything that
kills it ends the container.

This is *not* a `dx-herdr` defect: the wrapper streamed the attempt, detected
the failure, and propagated a truthful non-zero status, which is exactly the
contract the plan specifies for a failed install. The fault is in what happens
to the guest during a full `dx-ai` bundle build.

**Consequence for the plan:** open measurement 2 (cold `dx-herdr` install
duration, the number decision H5 rests on) **cannot be taken** until this is
resolved, and neither can measurement 3, which needs a real Herdr session. The
7s figure above is a crash, not an install time — do not cite it as one.

#### L6 — a publication race that makes fixes look ineffective

`dx-start-container` **starts the container first and calls
`dx-sync-bootstrap` afterwards** (`bin/dx-start-container:20`). The guest's
bootstrap therefore begins with whatever generation was already current, while
the freshly published one lands underneath it. A single start after editing the
repo runs the **previous** generation.

Observed directly: after the L5 fix was published as generation
`20260804T003111Z-34685`, the boot that followed ran
`20260803T205002Z-96364` and reproduced the pre-fix `awk` failure exactly. The
fix looked ineffective when it had simply not been used yet. A second start
picks up the new generation.

This is the same trap as L3, which is why L3's wrong "deadlock" diagnosis was
so tempting: both present as *"I fixed it, the guest still fails identically."*
The distinguishing evidence is cheap — the generation id is printed in the
bootstrap log:

```
$ container logs dx-test | grep -oE 'generations/[0-9TZ-]+' | tail -2
```

If that id is not the generation you just published, you are looking at stale
code, not a failed fix. Worth surfacing in the workflow rather than leaving to
be rediscovered.

#### L3 — a wrong diagnosis, corrected

When a recreate reproduced L2's exact error *after* the fix was in the working
tree, the obvious inference was a bootstrap-delivery deadlock: the guest runs
the payload in `$DX_BOOTSTRAP_VOLUME`, that volume survives recreation, and
`dx-sync-bootstrap` needs a live container — so a guest whose bootstrap dies
could never receive the fix for the thing killing it.

**That inference was wrong.** `bin/dx-start-container:20` calls
`dx-sync-bootstrap` on every start, so the payload *is* republished from the
repo each time and no deadlock exists. The real cause was mundane: the recreate
was launched while the fix was still being written, so it published and ran an
incomplete tree.

Recorded because the wrong explanation was plausible, self-consistent, and
would have sent someone rearchitecting a delivery path that works correctly.
The check that settles it is one line: `grep -n dx-sync-bootstrap
bin/dx-start-container`.

### The first blocking defect in detail (not a Herdr finding)

`configure_guest` calls `setup_keyring_service` **before**
`run_home_manager_activation`, but that function does

```bash
dbus_bin="$(run_as_dx 'command -v dbus-daemon')"
```

and `dbus-daemon` only enters `dx`'s profile *via* Home Manager activation. On a
recreate `/home/dx` is ephemeral, so the substitution fails, and as a bare
assignment under `set -euo pipefail` it kills the whole bootstrap **with no
diagnostic at all** — the container simply ends `stopped`, logs stopping at
"Setting up D-Bus keyring service for credential persistence...".

This is **pre-existing and unrelated to Herdr** — `setup_keyring_service` is
byte-identical to `HEAD`. It fires only when the AI-tools guard is true, which
is why it went unnoticed. Its reach is wider than this task: it breaks
`dx-recreate` on **any** AI-tools-enabled guest including `dx-host`, and it
breaks the plan's own H8 upgrade path (`dx-recreate` → `dx-ai` → `dx-herdr`),
so Herdr's documented refresh workflow could not work until it is fixed.

Ruled out before concluding: the SIGBUS/corrupt-store pattern (`nix store
verify` clean on `dbus` and `gnome-keyring`) and the known `dx-wait-ssh`
false-stop (the log never reaches "Guest bootstrap complete").

Approved fix: hoist `setup_keyring_service` to after
`run_home_manager_activation` behind an `ai_tools_enabled` flag, and replace the
silent death with an explicit diagnostic.

### Previously open at the remediation checkpoint

This list predates follow-up findings R1–R6. Items that remain relevant are
restated in R6; the statement that nothing blocks merge is superseded.

- **F13 (partial)** — the tool inventory is one declaration inside `dx-ai.sh`,
  but still appears literally in `flake.nix`, `bin/dx-herdr`'s install message,
  and `docs/guest.md` prose.
- **Two acceptance items untested**: corrupt / too-new snapshots degrading to a
  fresh session (needs fabricated snapshot files), and the *removal* half of the
  documented history cleanup (the cold-stop half is proved).
- **`dx-host` still carries the L1 defect** until it is next recreated. The fix
  is in the repo, so its next `dx-recreate` picks it up — but until then, a
  `dx-recreate` on `dx-host` will fail the same way `dx-test` did. This is the
  one item with reach beyond this branch.
- `session-history.json` is mode `0644` (see below) — upstream behaviour,
  recorded rather than changed.

### What this took, honestly

Seventeen review findings were implemented against a green offline suite. The
live tier then found **eight** further issues, and the split matters:

| Origin | Items |
| --- | --- |
| Introduced by this remediation | L2 (root-owned home parents), L5 (`awk` dependency + boot-fatal failure), L8 (fixtures hard-coded to the default profile) |
| Genuine pre-existing defects | L1 (keyring before Home Manager — also affects `dx-host`), L7 (essentials additions never reach existing guests) |
| Workflow traps, not code defects | L6 (start-before-sync runs the previous generation), plus the known `dx-wait-ssh` false-negative |
| My own misdiagnosis | L3 ("bootstrap-delivery deadlock" — no such thing) |
| Transient, did not recur | L4 (guest restart mid-install) |

The uncomfortable part: **100% line coverage and a fully green suite held
through L2, L5, L8 and the root-guard failure.** Four real defects — one of
which broke every fresh guest boot — sat behind a passing test run, every time
because a fixture asserted against conditions that do not exist on the guest:
no-op `chown`/`run_as_dx`, tests running as root, `awk` always installed, and a
hard-coded container name. Coverage proves a line executed. It does not prove
it executed in the environment that matters.

## Plan measurements — all three recorded

The plan lists three "Open measurements … facts to record after
implementation". All were taken on `dx-test`.

| # | Measurement | Result |
| --- | --- | --- |
| 1 | Does the chosen lock revision substitute on a cold `aarch64-linux` store? | **Yes.** `herdr` is fetched, not built: 6.4 MiB download / 20.2 MiB unpacked from `cache.nixos.org`. Decision **H5 faces no cold Rust build** |
| 2 | Cold `dx-herdr` install duration — "the number that decides whether H5 stands" | **126 s** end-to-end for the whole `dx-herdr` invocation, on a store that had been reformatted (so close to cold). The bundle installed and `dx-ai` verified all five tools |
| 3 | Measured size of the persisted Herdr directories — the evidence base for C1 | **`~/.config/herdr` = 36 K, `~/.local/state/herdr` = 96 K (~132 K total)** after a real session with `pane_history` enabled |

**Measurement 3 supports C1's "build no pruner" decision.** 132 K after a live
session, with `session-history.json` at 539 bytes, is nowhere near warranting a
retention pruner. The plan's reasoning holds: `session-history.json` is
replaced per snapshot rather than appended, and the real bound is the per-pane
byte cap.

**Measurement 2 supports H5** (install without confirming). 126 s is a wait, not
an ordeal, and it is dominated by substituted downloads rather than compilation.

The live layout also matches the plan's "Corrected state layout" exactly,
including the socket placement the plan had to correct from an earlier draft:

```
~/.config/herdr/   config.toml  session.json  session-history.json
                   herdr.sock  herdr-client.sock   (both srw------- 0600)
                   herdr-server.log  herdr-client.log  release-notes.json
~/.local/state/herdr/  agent-detection/     (H9: rules fetched from herdr.dev)
```

`herdr session list` under a pty reports exactly one session, `default`,
`running`, with its socket at `~/.config/herdr/herdr.sock` — confirming both
the H7 "default session only" contract and the plan's conclusion that sockets
live beside session data rather than needing a separate ephemeral tree.

## Live acceptance list

Driven through Herdr's own non-interactive CLI (`herdr pane run` / `read` /
`process-info`, `herdr server stop`) rather than by simulating keystrokes.

| Acceptance item | Result |
| --- | --- |
| Exact version and declared licence | **`herdr 0.7.5`**, `AGPL-3.0-or-later` (nixpkgs `meta.license.spdxId`) |
| Pane marker survives SSH disconnect / reattach | **Proved.** A marker written in one SSH session was read back over a **separate** connection — each `dx-ssh` call is its own connection, so this is the disconnect case exactly. Pane shell PID `800`, stable across reads |
| Wrapper starts only the default session | **Proved.** `herdr session list` → one session, `default` |
| Wrapper rejects every argument | **Proved live** — `--session foo` and `extra` both exit 64 |
| Pane history is durably captured | **Proved.** After a cold `herdr server stop`, the marker is present in `/persist/…/session-history.json` |
| Stale-helper case gives the recreate diagnostic, no install attempted | **Proved live** (Phase 1) |
| Transport failure is distinguished from a missing capability | **Proved live** (Phase 1) — F2 |
| Failed install is attempted once and propagates its failure | **Proved live** — the first attempt failed and `dx-herdr` returned non-zero with a truthful message, without retrying |
| First install with a Herdr-aware helper streams one attempt and installs | **Proved** — 126 s, all five tools verified |
| Marker survives container restart with declared ownership/modes | **Proved.** After a full stop/start cycle the marker is still in `/persist/…/session-history.json`, both symlinks are recreated `dx:dx`, and the seeded `config.toml` is unchanged |
| Corrupt / too-new snapshots degrade to a fresh session | **Not tested** — would require fabricating snapshot files |
| Documented history cleanup removes the marker | **Not tested** — the cold-stop half is proved; the removal half is not |

### L8 — the new tests only worked under the default profile

The first full live-tier run failed four Section 23 assertions, all with the
same message: `Error: Container dx-test is not running.` The fake `container`
command in those fixtures was hard-coded to `echo "dx-host"`, so
`container_is_running "$DX_CONTAINER_NAME"` never matched when the suite ran
under the **`dx-test` profile** — which is exactly how the live tier is meant to
be run, and how the plan's validation matrix requires it ("Live isolated: on
`dx-test`, before `dx-host`").

Every earlier run of this section had used the default profile, where
`DX_CONTAINER_NAME` happens to be `dx-host`, so the fixtures passed for the
wrong reason. Fixed by interpolating `$DX_CONTAINER_NAME` instead of a literal;
the section now passes under both profiles, which is the property that was
actually wanted.

A fourth instance of the same pattern: the fixture encoded an assumption about
its environment that did not hold where the code really runs.

### Two live-tier failures that were not defects

`test_section11_validate_fresh` and `test_section4_ssh` each failed once with
`Timeout waiting for authenticated SSH` / `kex_exchange_identification:
Connection reset by peer`. The guest had in fact reached "Guest bootstrap
complete" and was healthy; the probe simply ran while a post-reformat bootstrap
was still re-downloading the world. Re-run against a settled guest, section 4
passes 10/10.

This is the known pre-existing `dx-wait-ssh` false-negative (a single-sample
check that can report failure on a healthy boot under load) — **not** a
regression from this work, and worth distinguishing rather than counting as a
live-tier failure.

### One observation worth recording

`session-history.json` is created by Herdr as **`-rw-r--r--` (0644)**, not
`0600`. It is effectively private because its parent directory is `0700 dx:dx`,
so this is not an exposure today — but the plan's own sensitive-output warning
notes this file serialises visible terminal output, including anything pasted
or printed. The privacy therefore rests entirely on the directory mode, not the
file mode. That is upstream Herdr's behaviour, not something this remediation
introduced, and worth knowing before anything relaxes that directory.

## Original findings (historical)

| # | Sev | Finding | vs. previous review |
| --- | --- | --- | --- |
| B1 | Blocker | Committed `flake.lock` cannot provide `herdr` | Confirmed **in-guest**; radius corrected |
| B2 | Blocker | `test_bootstrap_publication.sh` dropped from the suite; sections renumbered | **New** |
| F1 | High | Guest probes are Nushell-parsed, so `dx-herdr` always fails | **Proven in-guest**; worse than reported |
| F2 | High | Every SSH failure is reported as "lacks Herdr capability" | **New** |
| F3 | High | `exec` destroys the OSC trap; `dx-ssh` also double-prints and has a dead `quiet` arg | Expanded |
| F4 | High | First installation never activates persistence | Confirmed |
| F5 | High | Root follows user-controlled symlinks during activation | Confirmed, severity recalibrated |
| F6 | High | Most new assertions cannot fail the suite | Confirmed with hard evidence |
| F7 | High | TOML seeding can emit a duplicate table and break config parsing | **Corrected — worse than reported** |
| F8 | Medium | Successful `dx-ai` updates no longer release their lock | Confirmed, radius narrowed |
| F9 | Medium | An existing coverage probe was deleted, not added to | **New** |
| F10 | Medium | The refactor created the duplication it was meant to remove | **New** |
| F11 | Medium | `HERDR_*` set empty rather than unset — and not needed at all | Expanded |
| F12 | Low | Unnamespaced `cleanup_osc`; pointless `export TERM` | **New** |
| F13 | Low | Tool inventory now duplicated in six places | **New** |
| F14 | Low | Documentation contradicts the implementation | Confirmed |
| F15 | Low | `--supports` ignores trailing arguments; blank line at EOF | Partly new |

---

### B1 — Blocker: the committed lock cannot provide `herdr`

`flake.nix` adds `herdr` to `aiPackages` (line 111), but `flake.lock` is still on
`nixpkgs-unstable` rev `27ac479f…` (`lastModified` 1780096917), the revision
`herdr-plan.md` records as predating the package.

**Executed in the `dx-test` guest**, against the committed lock:

```
$ nix eval github:nixos/nixpkgs/27ac479f103acfd70925b4a1e5fb1ea61887a66a#legacyPackages.aarch64-linux.herdr.version
error: flake … does not provide attribute '…herdr.version'
       Did you mean one of feedr, herbe, herqq, hexd or serd?

$ nix flake check --no-build --no-write-lock-file      # on the committed lock
checking derivation packages.aarch64-linux.default...   ← OK
checking derivation packages.aarch64-linux.ai-tools...
error: undefined variable 'herdr'
       at …/flake.nix:111:9
```

Two useful facts fall out of that run:

- **Nothing else in the flake is wrong.** `devShells.default` and
  `packages.default` evaluate cleanly and the check reaches `ai-tools` before
  failing. The lock bump is the whole Nix-side fix; no other flake work is
  pending.
- **The bump target is known.** Current `nixpkgs-unstable` — rev
  `a5cbcfe954791221bfffe2307f7d1a1bf61a871e`, 2026-08-02 — provides
  `herdr` **0.7.5** with `meta.license.spdxId = "AGPL-3.0-or-later"`. That is an
  independent confirmation of the plan's C2 licence correction, from nixpkgs
  metadata rather than from upstream's repository page.

**Correction to the previous review.** It said only that CI's locked
`nix flake check` fails. Two more consequences matter, and one non-consequence
is worth stating so nobody over-reacts:

- Section 12's `nix profile add …#ai-tools` evaluates the committed lock and
  will fail on Linux — the live tier breaks, not just CI.
- Runtime `dx-ai` is **not** broken: `dx_ai_update_flake` runs
  `nix flake update … nixpkgs-unstable` inside the staged generation before
  building, so a real guest resolves a revision that does have `herdr`. Do not
  cite this blocker as "dx-ai is bricked".

Fix: bump and commit the lock to a reviewed revision (the one above is a
candidate), then record whether it substitutes on a cold `aarch64-linux` store
(Open measurement 1 in the plan).

### B2 — Blocker: a test file was silently dropped from the suite

`tests/run_all_tests.sh` reassigned section numbers to make room for Herdr:

```diff
-run_test "…/test_refactor_state_machines.sh" "21"
-run_test "…/test_bootstrap_publication.sh"   "22"
+run_test "…/test_section21_herdr.sh"          "21"
+run_test "…/test_refactor_state_machines.sh"  "22"
```

`test_bootstrap_publication.sh` now has no entry in `run_all_tests.sh` at all.
It survives only because `run-coverage-contracts.sh` invokes it directly, so
`run-tier.sh live` (which is just `run_all_tests.sh`) no longer covers bootstrap
publication, and `--section=22` silently means a different test than it did
before. Any documentation, CI job, or habit that names section 22 now selects
the wrong suite.

Fix: give Herdr the next free number (23) rather than renumbering, restore
`test_bootstrap_publication.sh` to the runner, and add a contract assertion that
every `tests/test_section*.sh` and every file named in `KNOWN_SECTIONS` is
dispatched exactly once — this class of loss should not be reviewable-by-eye.

### F1 — High: the wrapper's probes are parsed by Nushell, so `dx-herdr` always fails

`activation.sh:117-125` runs `usermod -s "$NU_PATH" dx`, making Nushell the dx
login shell. `ssh host "…"` hands the command string to that login shell.
`bin/dx-herdr:48,50,67` send:

```bash
ssh … "command -v herdr >/dev/null 2>&1"
ssh … "dx-ai --supports herdr >/dev/null 2>&1"
```

**Proven against the running `dx-test` guest** with raw `ssh` (not `bin/dx-ssh`,
which wraps everything in `bash -lc`), using `dx-herdr`'s own option set:

```
$ ssh … dx@127.0.0.1 'echo hello'                      → hello, exit 0   (control)
$ ssh … dx@127.0.0.1 'command -v ls >/dev/null 2>&1'    → exit 1
    Error: nu::parser::shell_outerr
      x The '2>&1' shell operation is 'out+err>' in Nushell.
$ ssh … dx@127.0.0.1 'dx-ai --supports herdr >/dev/null 2>&1'  → exit 1, same error

$ getent passwd dx
dx:x:30033:30001::/home/dx:/home/dx/.nix-profile/bin/nu
```

The second probe used `ls`, which certainly exists. **The exit status is a parse
failure, not an answer.** There are two independent breakages: Nushell rejects
`2>&1` at parse time, and even without redirection it has no `command` builtin —

```
$ ssh … dx@127.0.0.1 'command -v ls'
    Error: nu::shell::external_command
      x External command failed   Command `command` not found
      help: Did you mean `which`?
```

**The concrete outcome, which the previous review did not state:** the first
probe reports "absent", the second reports "no capability", and `dx-herdr`
unconditionally prints *"the installed dx-ai helper lacks Herdr capability …
run dx-recreate"* and exits 1. The command can never succeed, on any guest —
and this is independent of B1, so bumping the lock does not fix it.

This is a regression the refactor introduced by deletion: the comment removed
from `bin/dx-ssh` said exactly this —

> We explicitly invoke bash for the environment setup check to handle POSIX
> syntax (e.g. 2>&1) regardless of the user's default login shell
> (nushell/fish).

Note that the `dx-ai` install invocation (`ssh … "dx-ai"`) *does* work — it is a
bare external command. Only the redirecting probes break, which is precisely
why the fake-`ssh` tests pass: they match on substrings and never parse.

Fix: route every guest command through the same `env … bash -lc '…'` boundary
the interactive path uses. Red test first: a fake `ssh` that **rejects** any
remote string not beginning with the bash boundary, so a future raw probe fails
the suite.

### F2 — High: every SSH failure is misreported as a missing capability

Independently of F1, the two probes conflate "the command answered no" with
"the command could not run". A missing `$DX_SSH_KEY` (checked only later, inside
`dx_exec_interactive_ssh`), sshd not yet up, a wrong port, or a transport error
all produce the same *"run `dx-recreate`"* advice — the most destructive
remedy in the tool set, recommended on the strength of a connection error.

Fix: separate transport failure from probe answer. Require the probe to emit a
known token on success (`printf 'DX_HERDR_PRESENT\n'`) and treat any other
outcome as an SSH error with its own diagnostic; check the key before probing.

### F3 — High: `exec` destroys the terminal-cleanup trap, and `dx-ssh` regressed

`dx_exec_interactive_ssh` installs `trap cleanup_osc EXIT` and then calls
`exec ssh …`. A successful `exec` replaces the shell image, so the trap never
runs. This is not only a new-command defect: `bin/dx-ssh` still installs its own
OSC trap at the top of the file, and `exec` discards that one too. **Ordinary
`dx-ssh` lost its Apple Terminal colour restore**, which it had before this
change (previously plain `ssh -t …`, no `exec`).

Two further regressions in the same function, not previously reported:

- **Duplicate output.** `bin/dx-ssh:12` prints `Connecting to DX guest via
  SSH...`, then passes `false` for `quiet`, and the library prints the identical
  line again. Interactive `dx-ssh` now prints it twice.
- **The `quiet` parameter is dead.** No caller passes `true`; `dx-ssh` passes
  the string `false`, which is also the default. Either make `dx-ssh` stop
  printing its own copy and keep the parameter, or delete the parameter.

`dx_get_host_timezone` is likewise now called twice per interactive run (once in
`dx-ssh`, once in the library) — harmless, but a symptom of F10.

Fix: drop `exec`, run `ssh -t "${ssh_opts[@]}" …`, capture its status, run the
cleanup, and return that status. A pseudo-terminal test should assert the OSC
sequence appears on stderr after the remote command exits.

### F4 — High: first-time installation never enables persistence

`dx_activate_herdr` is called from `configure_guest` only inside the branch
guarded by "has the user already opted into AI tools?"
(`activation.sh:94-110`). On a fresh guest that guard is false. `dx-herdr` then
installs the bundle through `dx-ai`, and `dx-ai.sh` never activates Herdr.

So the first Herdr session writes into ordinary `/home/dx/.config/herdr` and
`~/.local/state/herdr`. It is worse than "does not survive recreation": the
*next* bootstrap finds real directories where symlinks belong and, depending on
what `/persist` already holds, either migrates them or moves them aside to a
timestamped backup — so the user's first session silently changes location.

Fix: activate the layout unconditionally during bootstrap (it is cheap and
idempotent by design), or have `dx-ai` perform the equivalent activation on
first install. Prefer the former; the plan's H4/H9 describe the layout as
guest-invariant, not as an AI-tools side effect.

### F5 — High: root follows user-controlled symlinks during activation

`setup_herdr_persistence` guards its persistent targets with
`[ -e "$p" ] && [ ! -d "$p" ]`. `-d` dereferences, so a **symlink to a
directory** passes as a legitimate target. Root then runs `mkdir -p`,
`chown -R dx:dx`, `chmod 0700`, and seeds `config.toml` through that path, and
`chmod` dereferences too. The dx user owns `/persist/home/dx/.config`, so it can
plant that symlink.

Calibrating honestly: this is a single-user guest and dx already owns the data,
so this is not a privilege boundary crossing in practice. It is still (a) a
root-mode mis-target that can `chmod 0700` a directory outside the intended
tree, and (b) a direct violation of the plan's "Reject unsafe symlink/
non-directory targets" requirement.

Fix: test both targets and their parents with `[ -L … ]` first and reject before
any mutation; use `chown -h`/`--no-dereference` where a symlink may be the
operand; give the timestamped backups explicit `dx:dx` ownership and `0700`.

### F6 — High: most new assertions cannot fail the suite

Confirmed empirically, not inferred. Section 21 prints thirteen `PASS` lines and
then summarises three:

```
$ SKIP_INTEGRATION=true bash tests/test_section21_herdr.sh
  ✓ PASS: …            (×13)
Results: 3 passed, 0 failed, 1 skipped
```

`test_pass`/`test_fail` increment shell-local counters in `test_helpers.sh`;
ten of the thirteen assertions run inside `( … )` subshells, so the increments
die with the subshell. A failure is discarded the same way — a minimal
reproduction gives a green exit:

```
$ ( test_fail "a failure inside a subshell" ); print_summary; exit_with_code
  ✗ FAIL: a failure inside a subshell
Results: 0 passed, 0 failed, 0 skipped
EXIT=0
```

Every meaningful Herdr behaviour test — argument rejection, the container guard,
the capability diagnostic, the install-and-attach path, all three TOML cases —
is in that category. Two of the three assertions added to Section 9 are too.

Also in this area:

- Section 21's live block `test_skip`s when Herdr is absent, and Section 21 runs
  before Section 17 installs the bundle, so it will normally skip.
- The dx-herdr help/rejection assertions are now duplicated verbatim in Section
  9 and Section 21.
- Section 21 is not in `run-bash32-tests.sh`. The plan permits this only because
  Section 9 carries the host contract — but Section 9 carries it in subshells,
  so the Bash 3.2 tier currently proves one assertion, not three.

Fix: subshells are only needed for `export PATH` and fake-tool isolation. Have
each block `exit` a status and let the parent assert on it
(`if ( … ); then test_pass …; else test_fail …; fi`), or export counters through
a file. Whichever is chosen, add a self-test asserting that a deliberately
failing assertion makes the runner exit non-zero.

### F7 — High: TOML seeding is not table-aware and can corrupt the file

`dx_seed_herdr_config` greps for key names anywhere in the file and matches
table headers with an exact-line regex. Three failure modes, all reproduced
against the real function:

| Input | Result |
| --- | --- |
| `[other]` containing both key names | File unchanged — **neither setting seeded** |
| `[experimental] # comment` header | A **second `[experimental]` table is appended** |
| `[experimental.nested]` with `pane_history` | Seeding skipped — setting never applied |

The middle case is the correction to the previous review, which reported only
"left unchanged". A duplicate table definition is a TOML *parse error*: herdr
will fail to load its configuration at all, so this path turns a valid user
config into a broken one.

```
$ # header with a trailing comment, after seeding:
[experimental] # mine
foo = 1

[experimental]        ← duplicate table
pane_history = true
```

Secondary defects in the same function:

- The append branches mutate in place with `>>`, so an interruption between the
  two blocks leaves a partially seeded file — the plan requires publishing one
  completed temporary file atomically.
- `"$config_file.tmp.$$"` is left behind if `awk` fails, and is created under
  root's umask (0644) before `chmod 0600` at the end.
- `chmod … 2>/dev/null || true` in the seeder and `chown -R … || true` in
  `dx_activate_herdr` mask their own failures. If the chown fails, the guest is
  left with a root-owned `0600` `config.toml` that dx cannot read — a silent,
  hard-to-diagnose broken state.

Fix: parse into table scope, build the complete file in a temp under the target
directory, `chmod`/`chown` it *before* `mv`, publish atomically, and fail closed
with a diagnostic when the existing file cannot be updated safely (as the plan
already specifies). Add the three table-scope cases above as red tests.

### F8 — Medium: successful `dx-ai` updates no longer release their lock

The success-path release was deleted:

```diff
-    dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM
     dx_ai_setup_credentials || return
```

Narrowing the radius from the previous review: as an executable the `EXIT` trap
installed at `dx-ai.sh:207` still fires at process exit, so the CLI does not
leak a lock between runs. The leak is real for **sourced** callers — the test
suite — which return from `dx_ai_main` holding the lock, a live `EXIT` trap, and
`$lock` still set; a second call then blocks on `dx_ai_lock_acquire`. It also
makes the success path the only exit that behaves differently from the four
explicit-release paths around it.

This change is unrelated to Herdr. Revert it and add the missing success-path
test rather than carrying it in this branch.

### F9 — Medium: an existing coverage probe was deleted to make room

`test_sourceable_coverage.sh` did not only gain Herdr probes; it lost one:

```
$ git show HEAD:tests/test_sourceable_coverage.sh | grep -c malicious   → 1
$ grep -c malicious tests/test_sourceable_coverage.sh                    → 0
```

The deleted probe wrote `malicious` into `/home/dx/.dx-keyring-env` to drive
`setup_keyring_service` into its `dx_keyring_read_legacy_env` failure branch —
`"refusing malformed legacy keyring environment file"` plus `return 1`. That
branch now appears to have no probe, so the 100% gate over `persistence.sh`
should fail. *Unverified locally:* the coverage tier needs a Linux container
(`DXE_COVERAGE_ISOLATED=1`), which was not available.

Restore the probe alongside the new ones and run the coverage tier before
merging; the gate is the reason this repo can trust its refactors.

### F10 — Medium: the refactor created the duplication it was meant to remove

The plan's instruction was "Reuse, don't clone, `dx-ssh` … Cloning guarantees
drift." After this change the SSH option array exists in four places —
`dx_ssh_append_common_options`, `dx_exec_interactive_ssh`, `bin/dx-ssh`'s
`SSH_OPTS` (still used by the arguments branch), and `bin/dx-herdr`'s own
`ssh_opts`. `GUEST_PATH`, `GUEST_SSL`, and the `printf %q` workdir snippet now
exist twice: as locals in the library and as globals in `dx-ssh`, which still
needs them for the non-interactive branch.

Fix: extract the *whole* boundary — options, environment prefix, and workdir
snippet — into one library used by both branches of `dx-ssh` and by `dx-herdr`,
and have the contract test assert that `bin/dx-herdr` contains no `ssh`
invocation of its own.

### F11 — Medium: `HERDR_*` is set empty rather than unset, and is not needed

`remote_env` contains `HERDR_SOCKET_PATH= HERDR_CLIENT_SOCKET_PATH=`. Three
problems, one of them decisive:

1. Plan H3 says explicitly: do **not** set these variables. Setting them empty
   is not "unsetting" — an empty string is a value herdr may try to use as a
   path.
2. The isolation is unnecessary: `ssh` forwards only `LANG`/`LC_*` by default
   and no `SendEnv` is configured, so a host `HERDR_*` never reaches the guest.
3. It is applied to *every* interactive session, including plain `dx-ssh` into
   tmux, which has nothing to do with Herdr.

Fix: remove both assignments. If a belt-and-braces boundary is still wanted,
use `env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH`, matching
[upstream's own guidance](https://github.com/ogulcancelik/herdr/blob/master/AGENTS.md).

### F12 — Low: library hygiene

`cleanup_osc` is defined inside `dx_exec_interactive_ssh` but, because Bash has
no local functions, lands in the caller's global namespace unprefixed — the
repo's convention for `bin/lib` modules is a `dx_`-namespaced surface.
`export TERM=${TERM:-xterm-256color}` mutates the caller's environment to no
effect, since the remote `env` prefix hardcodes `TERM=xterm-256color`.

### F13 — Low: the tool inventory is now duplicated six ways

`codex gemini claude agy herdr` appears in `flake.nix`, three separate places in
`dx-ai.sh` (`dx_ai_validate_generation`, `dx_ai_verify`, the `--supports` case),
`dx-herdr`'s user-facing install message, and `docs/guest.md`. The plan's slice
1 called for refactoring repeated inventories; nothing was refactored, and a
seventh copy will be added by the next tool.

### F14 — Low: documentation contradicts the implementation

`docs/guest.md` says `dx-herdr` "will check if `dx-ai` supports Herdr, prompt to
install the optional AI tools bundle, and attach" — but H6 and the code install
**without** confirmation. Still missing from the docs, all required by the plan:
the sensitive-pane-history warning, the cleanup procedure, the cold-upgrade
workflow (H8: `dx-recreate` → `dx-ai` → `dx-herdr`), and the AGPL note from C2.

### F15 — Low: small contract and hygiene items

- `dx-ai --supports herdr junk extra` returns 0 — the `--supports` case returns
  before the `[ "$#" -eq 0 ]` arity check. `--supports` with no tool returns 1,
  indistinguishable from "unsupported"; a usage error would be clearer.
- `git diff --check` reports `dx-ai.sh:230: new blank line at EOF`.

## Original validation actually performed (historical)

| Check | Result |
| --- | --- |
| `tests/test_section21_herdr.sh` (skip-integration) | Passes — but see F6; only 3 of 13 assertions count |
| `tests/test_section9_host_scripts.sh` | 59 passed, 0 failed |
| `tests/test_refactor_contracts.sh` | Passes |
| `dx_seed_herdr_config` table-scope probes | 3 failure modes reproduced (F7) |
| Subshell counter reproduction | Failure discarded, exit 0 (F6) |
| `git diff --check` | 1 warning (F15) |
| `nix flake check` on the committed lock (in `dx-test`) | **Fails**: `undefined variable 'herdr'` at `flake.nix:111` (B1) |
| `nix eval` of `ai-tools.drvPath` on the committed lock (in `dx-test`) | **Fails**: identical error (B1) |
| `nix eval` of `herdr` at the pinned rev (in `dx-test`) | Attribute does not exist (B1) |
| `nix eval` of `herdr` at current unstable (in `dx-test`) | `0.7.5`, `AGPL-3.0-or-later` — bump target identified |
| Raw-`ssh` probe parse behaviour (in `dx-test`) | **Fails unconditionally** — `nu::parser::shell_outerr` (F1) |
| ShellCheck / Section 0 | **Skipped — `shellcheck` not installed on this host** |
| Real `aarch64-linux` build | **Not run** — evaluation-only; no closure was built |
| Coverage tier | **Not run — needs `DXE_COVERAGE_ISOLATED=1` in a container** |
| Live Herdr behaviour tier | **Not run** — blocked behind B1 and F1 |

Guest checks ran against `dx-test` (the isolated profile), never `dx-host`, with
`--no-write-lock-file` throughout; the repository was not modified and nothing
was installed into the guest profile. Scratch work stayed in the guest's `/tmp`.

F1 and B1 are now settled empirically. **F4, F5 and F9 remain source-derived**:
they are consistent with the recorded design, but the coverage tier and a live
first-install run are what would confirm them. The plan's live acceptance list
cannot be started until B1 and F1 are fixed — every item on it routes through
either `herdr` being installable or `dx-herdr` being able to connect.

## Original suggested order (historical; completed)

1. **B2** and **F6** first. Until the suite can fail, nothing below is provable.
2. **F1**, **F2**, **F3** — the wrapper does not currently work, and `dx-ssh`
   regressed; fix them together in the SSH boundary, with F10's extraction.
3. **F7**, **F5**, **F4** — the persistence and seeding layer, red tests first.
4. **F8**, **F9**, **F11**, **F12** — revert the unrelated `dx-ai` lock change,
   restore the deleted probe, drop the `HERDR_*` assignments.
5. **B1** — bump and commit the lock (candidate:
   `a5cbcfe954791221bfffe2307f7d1a1bf61a871e`, which carries herdr 0.7.5,
   AGPL-3.0-or-later), re-run `nix flake check` on the committed lock, then the
   coverage, Bash 3.2 and live tiers, recording the plan's three open
   measurements. B1 is a one-line change and nothing else in the flake is
   broken — but it gates the entire live acceptance list, so do not leave it
   last in practice.
6. **F13**, **F14**, **F15** — inventory refactor and documentation, last.
