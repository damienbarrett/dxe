# Keyring bootstrap recreate defect (Branch 15, `fix/keyring-bootstrap-recreate`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 15.
No home directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `fix/keyring-bootstrap-recreate`, from `main` `bf49f4d` (includes
Branch 14). Commits, in order: `8b754d4` (resolve keyring binaries
explicitly on recreate; warn instead of failing, policy B), `d9159de`
(docs/plan), `15ddbaf` and `c26ad20` (two coverage-fixture regressions
`run-coverage-linux.sh` caught for real, both in the tests that exercised
the old resolution mechanism, fixed to exercise the new one), `bb073ba`
(ratchet re-measurement), `f922434` (a live-tier regression in the new
Section 3 test's own fixture, found by `tests/run-tier.sh live` and fixed;
also fixes a home-directory path this file had in its validation-method
note), `9514fd2` (ratchet re-measurement).

## What changed and why

Found on Branch 14's live gate (2026-09-27): `./bin/dx-profile dx-test
./bin/dx-recreate` on a guest whose `/persist` already held a published AI
generation failed in bootstrap right after Home Manager activation:

```
Setting up D-Bus keyring service for credential persistence...
Error: dbus-daemon not found on dx's PATH; cannot start the keyring service. Home Manager activation must install it before setup_keyring_service runs.
```

`dbus`/`gnome-keyring` are declared only in `flake.nix`'s `aiPackages`, so
they exist only in the published AI generation's isolated profile
(`/persist/home/dx/.local/state/dx-ai/current/profile/bin`); Home Manager's
own profile (`homeConfigurations.dx`, `dxPackages`) never installs either
one — confirmed by reading `flake.nix` (dxPackages vs. aiPackages) and
`home/shell.nix` (the generation-profile `PATH` prepend is only ever added
by `programs.bash.profileExtra`/`home.sessionVariables`, never by a package
declaration Home Manager itself installs). `setup_keyring_service` resolved
`dbus-daemon` via `run_as_dx 'command -v dbus-daemon'`, i.e. dx's
login-shell `PATH`. A plain `dx-stop-container`/`dx-start-container` cycle
resolved it (the 2026-09-26 `dx-host` promotion worked); a `dx-recreate`
(fresh `/home/dx`) did not.

**Live diagnosis of the precise start-vs-recreate difference (Increment 1,
first paragraph).** dx-test was freed by the coordinating session partway
through this work (a fresh guest at the profile default, created from
Branch 8's tree, unfixed keyring lookup, no AI generation yet). Reproduction
plan: opt the guest in for real (`DX_TEST_DESTRUCTIVE=1 ...
tests/run_all_tests.sh --section=17`, 99/0/0, a real `dx-ai` run from cache
published a working AI generation with the keyring running), capture the
resolution facts while the guest was up, then `dx-recreate` on the same
unfixed bootstrap.

Facts captured live (`container exec` reproducing exactly what
`run_as_dx`'s `bash -l -c` does): the login shell's `PATH` did contain the
AI generation's `bin` directory (prepended twice, once via
`programs.bash.profileExtra`'s literal `export PATH=...` line and once via
`home.sessionVariables`), and `command -v dbus-daemon` resolved cleanly to
the generation profile. `~/.bash_profile`/`~/.profile`/`~/.bashrc` are
Home-Manager-managed symlinks into a `home-manager-files` store path;
`~/.bash_profile`'s entire content is `[[ -f ~/.profile ]] && . ~/.profile`,
so bash's login-file search order (which prefers `.bash_profile`) still
reaches the same `PATH`-setting content either way. `~/.profile` sources an
absolute-store-path `hm-session-vars.sh` first, then exports the literal
`PATH=/persist/.../dx-ai/current/profile/bin:$HOME/.nix-profile/bin:...`
line unconditionally -- this does not depend on `~/.nix-profile` resolving
to anything for its first (AI-generation) component to be correct.

**`dx-recreate` on this same unfixed bootstrap then did NOT reproduce the
reported failure.** Full sequence identical to a normal boot up to and
including "Bootstrap phase: Home Manager activation completed in 1s",
immediately followed by "Setting up D-Bus keyring service..." /
"Bootstrap phase: keyring persistence completed in 0s." -- no error, no
warning; sshd started normally. Post-recreate, the keyring address and
`.profile`/`.bash_profile`/`.nix-profile` were all freshly (re)created,
pointing at the same store paths as before.

Compared against the original failure logs from Branch 14's live gate (two
runs, both failed identically): every step up to and including "Bootstrap
phase: Home Manager activation completed in Ns" is structurally identical
across all three runs (two failures, one success) -- including the retry,
which was just as fast (1s) as this session's successful run, ruling out
activation *timing* as the differentiator. No difference in the log text
itself points at a distinguishing precondition.

**Conclusion, reported rather than guessed further:** this looks like a
race or visibility condition around Home Manager's freshly-written
`~/.profile`/`~/.bash_profile` symlinks (or the store paths they point at)
becoming reliably visible to a brand-new process immediately after Home
Manager's own activation script exits, rather than a deterministic
ordering defect in `configure_guest` -- `run_home_manager_activation`
already ran unconditionally before `setup_keyring_service` in both the
failures and this success, so the *ordering* itself was never the variable.
This was not chased further with additional instrumentation of the pre-fix
bootstrap (would need modifying and republishing it again, counter to the
"do not retry" instruction this diagnosis ran under). It does not affect
the fix's correctness: `dx_resolve_keyring_bin` checks fixed absolute paths
directly and does not depend on `~/.profile`/login-shell PATH at all,
immune to whatever this race is.

## The fix

1. `dx_resolve_keyring_bin` (new, `bootstrap/persistence.sh`) checks two
   fixed locations directly for a given binary name -- the published AI
   generation's profile first, dx's Home Manager profile as a fallback --
   instead of asking dx's login shell to resolve it on `PATH`. Mirrors
   `scripts/dx-ai.sh`'s own `dx_ai_ensure_keyring`, which already resolves
   and starts the same two services the same way for `dx-ai`'s own runs.
2. **Failure policy B (user decision, 2026-09-27): degrade loudly, not
   fatally.** If neither binary can still be resolved, `setup_keyring_service`
   logs an explicit `Warning:` naming what was missing and that `dx-ai` will
   start the keyring on its next run, and returns success so bootstrap
   continues to sshd. Option A (keep it fatal) was rejected.
3. Corrected the stale comments (at `setup_keyring_service`'s definition and
   its `configure_guest` call site) that said Home Manager installs
   `dbus-daemon` into dx's profile.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | green, 99/0/0 (`tests/run-bash32-tests.sh`, mac host) |
| G1 syntax | `find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \) -print0 \| xargs -0 -n1 bash -n`: clean |
| G1 pinned ShellCheck 0.10.0 | CI's exact file set, throwaway `nixos/nix:2.34.8`, self-contained clone: exit 0, no warnings |
| G1 container-free contracts (runner-matched) | `ubuntu:24.04` + apt shellcheck/jq/git, self-contained clone (not the worktree -- see note below), `tests/run_all_tests.sh --skip-integration`: "All tests PASSED!", exit 0 |
| G1 `test_refactor_contracts.sh` | green (folded into the same container run, chained with `&&`) |
| G2 coverage | `tests/run-coverage-linux.sh`: `covered=100% scope_share=17.91%`, exit 0; ratchet re-measured on a clean `git archive HEAD` export of the finished tip: 4,212 / 23,506 = 1791 bp (committed in `9514fd2`) |
| G3 Nix | not applicable -- no `.nix` file changed (confirmed: no `flake.nix`/`flake.lock` in the diff) |
| G4 live | `dx-test`, green -- see "Live results" below |
| G5 CI | pending push |

**Note on validation method:** a git worktree's `.git` is a file pointing at
the main repository's `.git/worktrees/<name>` outside the worktree itself,
so bind-mounting only the worktree into a throwaway container breaks any
test that shells out to `git` (e.g. `test_section6_tools.sh`'s "guest dx-ai
script is tracked for flake source inclusion", which failed the first time
for exactly this reason -- an environment artifact of the validation
method, not a defect). Re-validated against a disposable `git clone` of the
worktree instead, which is fully self-contained.

## Red/green (code-level, Increment 1's second paragraph / Increment 2)

Red: `tests/test_section3_bootstrap.sh`'s dbus-daemon diagnostic test and a
new recreate-resolution test, run against the unchanged production code
(production files stashed, container `run_all_tests.sh --skip-integration
--section=3`), both failed for the intended reason:

```
✗ FAIL: setup_keyring_service warns loudly and lets bootstrap continue when dbus-daemon is unresolvable, instead of dying (rc=1, output=[Setting up D-Bus keyring service for credential persistence...
Error: dbus-daemon not found on dx's PATH; cannot start the keyring service. Home Manager activation must install it before setup_keyring_service runs.])
✗ FAIL: setup_keyring_service resolves dbus-daemon and gnome-keyring-daemon from the published AI generation's profile on a fresh recreate, not dx's login-shell PATH (rc=1, setpriv_calls=[], output=[Setting up D-Bus keyring service for credential persistence...
Error: dbus-daemon not found on dx's PATH; cannot start the keyring service. Home Manager activation must install it before setup_keyring_service runs.])
```

(plus `dx_resolve_keyring_bin is directly sourceable` failing, since the
function did not exist yet). 3 failures, all expected; 134 other Section 3
assertions unaffected.

Green: same run with the fix restored -- 137 passed, 0 failed in Section 3.
The rewritten dbus-daemon test now asserts `rc=0` plus a `Warning` naming
`dbus-daemon`; the new recreate test asserts `rc=0` and that `setpriv` was
invoked with the exact generation-profile paths for both `dbus-daemon` and
`gnome-keyring-daemon`:

```
--reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx /persist/home/dx/.local/state/dx-ai/current/profile/bin/dbus-daemon --config-file=/persist/home/dx/.local/state/dx-ai/current/profile/share/dbus-1/session.conf --fork --print-address
--reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dxe-recreate-bus /persist/home/dx/.local/state/dx-ai/current/profile/bin/gnome-keyring-daemon --unlock --start --components=secrets
```

proving the fallback (dx's login-shell PATH) was never used.

## Live results (Increment 3, G4)

All run against `dx-test` (fresh guest, profile default 12 GB) after
syncing the fix (`dx-start-container` from this branch onto the
already-opted-in, unfixed-bootstrap guest, then a plain stop/start to pick
up the newly published generation -- publishing alone does not restart an
already-running container).

1. **`dx-recreate` on the fixed bootstrap:** completed cleanly. `container
   logs` shows "Setting up D-Bus keyring service for credential
   persistence..." / "Bootstrap phase: keyring persistence completed in
   0s." with no `Warning`/`Error`; `dx-wait-ssh` succeeded; the keyring
   address was fresh and live, and `dbus-daemon` was confirmed resolving
   from `/persist/home/dx/.local/state/dx-ai/current/profile/bin`.
2. **`DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test tests/run_all_tests.sh
   --section=17`:** 99 passed, 0 failed, 0 skipped -- `dx-ai` completes
   inside the guest, ensures the D-Bus keyring service, all six AI tools
   available, keyring address written.
3. **`tests/run-tier.sh live`:** every test file passed with 0 failures
   except `test_section3_bootstrap.sh`, which hit one regression: the new
   recreate-resolution test's fixture setup unconditionally
   `mkdir -p /persist/home/dx/...`, and this "live" invocation runs Section
   3 directly on the coordinating session's Mac (not inside a container),
   where creating a new top-level directory under the read-only root
   filesystem is refused ("mkdir: /persist: Read-only file system"),
   aborting the file under `set -e` before its own Results summary printed.
   Fixed in `f922434` (guard on whether the `mkdir` actually succeeds, not
   just on whether the directory already exists; skip with a clear reason
   when it cannot). Re-verified in isolation on the same host:
   `bash tests/test_section3_bootstrap.sh` exits 0, 136 passed, 0 failed, 1
   skipped (the new probe skips there; the policy-B "warns loudly" test
   still passes). Every other file in the same live-tier run (Sections
   0-27, `test_bootstrap_publication.sh`, `test_refactor_state_machines.sh`,
   `test_nix_store_import.sh`, `test_herdr_config_persistence.sh`) passed
   with 0 failures; the full tier was not re-run end-to-end after this
   one-line test fix (a targeted re-verification plus the unaffected
   container-based G1/G2 re-runs, both green against the true final tip,
   were judged sufficient rather than re-spending ~40 minutes of contended
   host time re-deriving already-green results).
4. **Idempotence: a second `dx-recreate` + `dx-wait-ssh`:** also completed
   cleanly, same signature as the first (no warning, fresh live keyring
   address, `.profile`/`.bash_profile`/`.nix-profile` freshly recreated
   pointing at the same store paths).
5. `dx-test` was cold-stopped at the end, per the plan; volumes and the AI
   generation are left in place.

No lifecycle command was refused by the permission classifier at any point.
`dx-host` and the NAS were never touched.
