# Keyring bootstrap recreate defect (Branch 15, `fix/keyring-bootstrap-recreate`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 15.
No home directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `fix/keyring-bootstrap-recreate`, from `main` `bf49f4d` (includes
Branch 14). Commits, in order: `8b754d4` (resolve keyring binaries
explicitly on recreate; warn instead of failing, policy B) plus a following
docs/plan commit and a ratchet re-measurement (see the plan's Branch 15
section for the final commit list once landed).

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
first paragraph):** _pending -- dx-test was occupied by another branch's
live gate for the first part of this work. This section is completed once
the live run below happens; see the plan's Branch 15 section / this
branch's progress file
(`~/dxe-recovery/progress/branch-15-keyring-bootstrap-recreate.md`) for the
live-tier commands and results once run._

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
| G1 pinned ShellCheck 0.10.0 | CI's exact file set, throwaway `nixos/nix:2.34.8`: _fill in after the re-run against the clean clone completes_ |
| G1 container-free contracts (runner-matched) | `ubuntu:24.04` + apt shellcheck/jq/git, self-contained clone (not the worktree -- see note below), `tests/run_all_tests.sh --skip-integration`: _fill in_ |
| G1 `test_refactor_contracts.sh` | _fill in_ |
| G2 coverage | `tests/run-coverage-linux.sh`: _fill in_; ratchet re-measured on a clean export: _fill in_ |
| G3 Nix | not applicable -- no `.nix` file changed |
| G4 live | `dx-test`, pending (dx-test was occupied when this work started) |
| G5 CI | pending push |

**Note on validation method:** this worktree's `.git` points at
`/Users/damien/Development/dxe/.git/worktrees/wt-branch-15`, an absolute
host path outside the worktree directory itself, so bind-mounting only the
worktree into a throwaway container breaks any test that shells out to
`git` (e.g. `test_section6_tools.sh`'s "guest dx-ai script is tracked for
flake source inclusion", which failed the first time for exactly this
reason -- an environment artifact of the validation method, not a defect).
Re-validated against a disposable `git clone` of the worktree instead,
which is fully self-contained.

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

_Pending -- dx-test occupied by another branch's live gate when this work
started. Filled in once run: `dx-recreate` completion, `dx-wait-ssh`,
keyring running (or the documented warning + reachable guest under policy
B), Section 17 destructive (`DX_TEST_DESTRUCTIVE=1 ... --section=17`), full
live tier (`tests/run-tier.sh live`), and a second `dx-recreate` +
`dx-wait-ssh` for idempotence._
