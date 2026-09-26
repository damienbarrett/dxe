# Herdr acceptance tests (Branch 7, `test/herdr-acceptance`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 7:
the two missing acceptance cases from the completed Herdr review (removed;
see Git history), tracked as Q3 (resolved 2026-09-26: do both). No home
directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `test/herdr-acceptance`, from `main` `9711f9e`. Commits, in order:
`14ffd17` (corrupt/too-new snapshot recovery), `ee6eadc` (history-cleanup
marker deletion, plus one Section 10 docs assertion), `3b11075` (ratchet
rebaseline 1843 → 1821 bp). Both acceptance tests are characterisation
tests: they passed immediately against unchanged production code, so
neither commit changes any file under `bin/`, `bin/lib/`, or `container/`.

## Guest

`dx-test` only, via `./bin/dx-profile dx-test <cmd>` with
`DX_CONTAINER_MEMORY=24576`. It already had Herdr installed
(`herdr 0.9.1`). Started/waited/stopped as needed; never factory-reset or
recreated; `dx-ai` was never run on it; `dx-host` was never touched.

## Herdr's non-interactive CLI, discovered live (not guessed)

Via `herdr --help` and its subcommand help, run over `bin/dx-ssh`
(`bin/dx-herdr` is never invoked in a test — it attaches a TTY):

- `herdr server` runs the headless server in the foreground (backgrounded
  here with `nohup ... & disown`); `herdr server stop` is the documented
  cold stop; `herdr status --json` reports `server.running`.
- `herdr workspace create --label <text>` creates a workspace, tab, and one
  shell pane in a single call and prints the new `pane_id` — the smallest
  reliable way to get a usable pane non-interactively.
- `herdr pane run <pane_id> <cmd>` types text plus Enter into a pane in one
  call (the smallest reliable way to inject pane input non-interactively);
  `herdr pane read --lines N <pane_id>` reads back rendered pane content.
- `herdr pane process-info --pane <id>` reports the pane's foreground
  `shell_pid`, used to observe process liveness directly.

## The two persisted files are separate, and that matters

`~/.config/herdr/session.json` (topology: workspaces/tabs/panes, ids,
geometry) and `~/.config/herdr/session-history.json` (a wholesale-replaced
snapshot of each pane's rendered scrollback, `{"version": N, ...}` —
observed live to be `version: 3` on herdr 0.9.1) are independent files.
With `session.json` absent, herdr never attempts to parse
`session-history.json` at all — there is no topology to attach restored
content to. So each acceptance case below first creates one real
workspace/pane (producing genuine copies of both files), seeds it with a
marker, and corrupts/version-bumps only `session-history.json` before
restarting — the realistic precondition of an existing Herdr user, not an
artificially "blank slate" one.

Measured snapshot-write latency: in one measurement, a fresh pane marker
landed in `session-history.json` five seconds after being written (a
periodic background writer, not synchronous). Both live tests poll with a
bound rather than a fixed sleep.

## Case 1 — corrupt/too-new snapshot degrades to a fresh, usable pane

For each of two sub-cases (`corrupt`: garbage bytes overwrite
`session-history.json`; `toonew`: a genuine snapshot's real `version`
field is bumped by 1,000,000 via `jq '.version += 1000000'`, not
hand-authored):

1. Cold-stop any running server; back up any pre-existing
   `session.json`/`session-history.json`.
2. Start the server, create a workspace/pane, seed it with a marker, poll
   until the marker lands in `session-history.json` (proves the
   precondition — a real snapshot exists before it's corrupted).
3. Cold-stop; corrupt or version-bump only `session-history.json`
   (`session.json`, the topology, is left alone).
4. Restart the server; poll until it reports running.
5. Confirm the same pane's content no longer shows the seed marker (fresh,
   not restored), then prove it usable: run a new command in it and read
   the output back.
6. Confirm the bad `session-history.json` file's checksum is unchanged
   (neither renamed nor deleted).
7. Cold-stop, restore the backed-up files, remove temp logs.

**Result, both sub-cases:** server comes up and stays up (never hangs,
never exits non-zero), the pane is fresh and immediately usable, and the
bad file is left completely untouched. `~/.config/herdr/herdr-server.log`
(distinct from the backgrounded process's own stdout banner) records:

- Corrupt: `WARN herdr::persist::io: failed to parse session history file,
  ignoring err=expected ident at line 1 column 2`
- Too-new: `WARN herdr::persist::io: session history file is from a newer
  herdr version, ignoring file_version=<real_version+1000000>
  supported=3`

**Verdict on "reports/renames/deletes":** herdr *reports* the bad file via
its server log and otherwise ignores it; it neither renames nor quarantines
it, and — critically — it never deletes user data. No decision needed:
this is the documented degrade-gracefully behaviour the acceptance
criterion asked for, already correct in the installed `herdr 0.9.1`.

## Case 2 — the documented history-cleanup path removes the saved marker

Follows `docs/guest.md`'s "Herdr session persistence" cleanup steps
exactly: (1) an intentional cold stop, (2) delete `session-history.json`,
(3) start Herdr again and confirm the new session shows no restored
contents.

1. Cold-stop, back up pre-existing state files, start the server, create a
   workspace/pane, capture its `shell_pid` via `herdr pane process-info`.
2. Write a known, non-secret marker (`DXE-HERDR-B7-MARKER-<pid>`) into the
   pane via `herdr pane run`; poll until it lands in
   `session-history.json` (precondition proof).
3. Cold-stop (`herdr server stop`); confirm the captured `shell_pid` no
   longer answers `kill -0` (was alive immediately before the stop, gone
   immediately after — "No such process").
4. Delete `session-history.json` (the documented step); restart the
   server.
5. Read the same pane: confirm the marker is not present in its restored
   content.
6. `grep -rl <marker> /persist/home/dx/.config/herdr
   /persist/home/dx/.local/state/herdr`: no hits, across every file under
   both persisted directories, not just `session-history.json` itself.
7. Cold-stop, restore backed-up files, remove temp logs.

**Result:** marker captured before cleanup (precondition held), pane
process genuinely terminated by the cold stop, restarted session shows no
restored marker content, and the marker is gone from every file under both
persisted Herdr directories. `docs/guest.md`'s claim ("anything running in
an attached pane is terminated, not preserved or migrated") matches this
live observation exactly — it does not overclaim preservation or
migration, and Section 10 now pins that exact sentence
(`tests/test_section10_docs.sh`) so it can't drift.

**No decision needed:** the documented cleanup path already does what it
says; this is a characterisation test.

## Gates

| Gate | Result |
| --- | --- |
| G1 syntax | `find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \) -print0 \| xargs -0 -n1 bash -n`: exit 0 |
| G1 bash32 | `/bin/bash tests/run-bash32-tests.sh` on macOS bash 3.2.57: 99 passed, 0 failed (this file's own Section 23 is a live/container test and is not part of this curated bash-3.2 subset; a bash-3.2 parser bug this branch's own new code first tripped over — see below — was fixed and re-verified against the real extracted block under `/bin/bash` 3.2.57) |
| G1 container-free contracts (runner-matched) | Throwaway `dxe-scratch-b7-lint-81609` (`dxe-kcov:ubuntu-24.04`), apt-installed `shellcheck 0.9.0`/`jq 1.7.1` (confirmed matching the GitHub runner), `bash tests/run_all_tests.sh --skip-integration`: **All tests PASSED!** (re-run clean after removing a stray, gitignored `tests/coverage/out/` artifact left over from earlier, unrelated work in the same shared checkout — never present in an actual CI checkout) |
| G1 pinned ShellCheck 0.10.0 | Throwaway `dxe-scratch-b7-nix-81609` (`nixos/nix:2.34.8`, `-m 6g`), CI's exact command (`find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \) -print0 \| xargs -0 nix shell nixpkgs/nixos-25.05#shellcheck --command shellcheck --severity=warning`): clean, no warnings on any file this branch touched |
| G2 coverage | `tests/run-coverage-linux.sh` via Apple `container` (existing `dxe-kcov:ubuntu-24.04` image): `covered=100% scope_share=18.21%`. Ratchet re-measured: 1843 → 1821 bp (`3b11075`; both new tests are outside the declared kcov scope, the documented test-dilution edge) |
| G3 Nix | Skipped: no file under `container/` changed by this branch; confirmed via `git diff --stat 9711f9e..HEAD -- container/` (no output) |
| G4 Live | `dx-test`, see below |
| Dual-target gate stand-in | `bash tests/test_section27_qnap_scripts.sh`: 99 passed, 0 failed. `DXE_QNAP_HOST=qnap-dxe bash tests/qnap/phase0-spike.sh --dry-run --with-container-restart` was **blocked** by this session's own auto-mode permission classifier ("Modify Shared Resources") for naming the real QNAP host alias even under `--dry-run`; not run, not worked around. Nothing in this branch's diff touches `tests/qnap/`, `bin/`, `bin/lib/`, or `container/`, so the risk of a regression there is low, but this half of the stand-in is unconfirmed and needs the coordinating session to either run it or grant the permission |

## Live validation on `dx-test`

`DX_CONTAINER_MEMORY=24576 ./bin/dx-profile dx-test bash
tests/run_all_tests.sh --section=23`: **44 passed, 0 failed, 0 skipped**,
run three times back to back with identical totals each time (repeatability
proof). Guest state confirmed clean after every run: `herdr status --json`
reports `server.running: false`; no leftover `session.json`/
`session-history.json` beyond each test's own restored pre-test state; no
leftover `/tmp/dxe-b7-*` files; no marker text anywhere under
`/persist/home/dx/.config/herdr` or `/persist/home/dx/.local/state/herdr`.
`tests/test_section10_docs.sh`: 144 passed, 0 failed, locally.

Both new live tests were red/green proven to bite: each assertion was
temporarily changed to an unmatchable pattern, re-run against the live
guest to confirm it failed for the intended reason (captured diagnostic
output included in each commit body), then reverted and re-confirmed
green.

`dx-test` stopped at the end of the task
(`./bin/dx-profile dx-test bin/dx-stop-container`).

## Findings requiring a decision

None. Both acceptance cases found already-correct behaviour in the
installed `herdr 0.9.1`; neither test needed a production-code fix.

## Bash-3.2 parser bug found and fixed along the way

Building the live test's guest-side script as `VAR="$(cat <<'EOF' ...
EOF)"` — a heredoc nested directly inside a `$(...)` command substitution,
itself inside an `if` block whose body has its own nested
`if`/`then`/`else`/`fi` — caused macOS's `/bin/bash` 3.2.57 (this repo's
own `bash-3-2` CI tier) to expand a heredoc-internal `$MODE` reference in
the *outer* (host) shell instead of passing it through literally, tripping
`set -u` ("MODE: unbound variable") before any guest connection was even
attempted. Reproduced in isolation with the real extracted code (`run_guest`
stubbed to a no-op) and confirmed bash-3.2-specific. Fixed by staging the
heredoc through a temp file via a plain redirect
(`cat > "$file" <<'EOF' ... EOF`) instead of directly inside a command
substitution, then reading the file's contents into the variable
separately — verified clean under `/bin/bash` 3.2.57 with the real block.
Not a production-code change; recorded here since it is exactly the kind
of bash-3.2 pitfall future edits to this test file should avoid.
