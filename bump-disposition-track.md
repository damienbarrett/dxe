# Bump disposition execution tracking

## Purpose

This is an hourly, read-only observer log for execution of
`bump-disposition-plan.md`. It records repository-visible progress, risks, and
actionable improvements without changing the candidate implementation.

This file is not the plan's external, SHA-bound validation evidence. The
candidate's gate logs still belong in the execution record's evidence directory
outside both worktrees.

## 2026-08-30 21:41 NZST — baseline checkpoint

### Observed progress

- Step 0's preservation and rebase objectives are complete.
  `bump/lock-refresh` is clean at `286d3fc` (`Preserve the validated stable lock
  refresh`), whose parent is current `main` at `3ce623b`.
- The candidate differs from `main` in exactly
  `container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.lock`, with 12
  insertions and 12 deletions. The refresh is therefore no longer held only as
  an unstaged worktree change.
- The disposition plan has incorporated the second review's findings in the
  main worktree. Separate follow-up artifacts now exist for the post-remount
  trust root and the image-pin collision.
- No maintenance-window execution is visible yet. The execution record remains
  unfilled, and no waiver, frozen candidate tip, gate results, landing, or
  primary promotion is recorded.

### Findings and recommendations

1. **Good stopping point:** preserving the raw lock as its own clean commit
   follows the plan and keeps the dependency change independently auditable and
   revertible.
2. **Do not begin the destructive or promotion phases yet:** the decision
   maker, window, external evidence directory, candidate tip, and rollback set
   are still unfilled. The plan correctly treats any one of these omissions as
   a reason not to start.
3. **Re-freeze after the documentation stack lands:** the revised plan and both
   follow-up artifacts are currently outside `bump/lock-refresh`. If they are
   committed on `main`, rebase the candidate again, rerun the mechanical lock
   audit, and record the new immutable tip before validation.
4. **Remove the stale historical filename reference:** this checkpoint removes
   `bump-disposition-review.md` at the user's request because its findings are
   incorporated. Before committing the revised plan, replace its remaining
   reference to that now-removed file with a self-contained phrase such as
   “the second independent review”.
5. **Keep observer output separate from gate evidence:** this tracking file
   makes the main worktree dirty while monitoring is active. Do not copy it into
   the candidate as validation evidence, and ensure the exact worktree used by
   `tests/release-check.sh` is clean at each freeze.

## 2026-08-30 22:42 NZST — hourly checkpoint

### Observed progress

- A new executable `tests/lib/audit-flake-lock.sh` now implements most of Gate
  group A. On the real base and candidate locks it passes under the repository's
  macOS Bash 3.2 and reports exactly the expected four changed nodes, including
  full revisions, `narHash` values, and timestamps.
- The plan's stale reference to the removed review file has been corrected.
- The raw candidate remains clean and unchanged at `286d3fc`; its lock SHA-256
  remains `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9`.
- The audit helper, revised plan, and follow-up plans remain outside the
  candidate commit stack. The execution record is still unfilled, so there is
  still no frozen candidate or maintenance-window gate evidence.

### Findings and recommendations

1. **High — add Red → Green behavioral tests for the audit helper.** Nothing
   currently references `audit-flake-lock.sh`, so neither `run_all_tests.sh` nor
   a focused suite exercises its failure behavior. Add a dispatched test with
   fixture mutations for every Gate A condition. The first red cases should
   target the fail-open cases below; then make the minimum helper changes and
   refactor only while those cases stay green.
2. **High — require the exact expected changed-node set.** The helper currently
   passes when no nodes change and only emits a notice when an allowlisted node
   is absent. For this candidate, require the changed set to equal
   `{flake-parts, home-manager, nixpkgs, nixvim}`. A no-op, partial refresh, or
   renamed/missing expected node must fail rather than produce valid Gate A
   evidence.
3. **High — compare the whole normalized document, including path presence.**
   Replacing the candidate's three allowed fields with base values can mask a
   deleted allowed field, while extra top-level fields are not checked at all.
   First assert that every allowed leaf exists with the expected JSON type, then
   normalize only those leaves and require canonical equality of the complete
   documents. This makes “anything outside the allowlist” mechanically true.
4. **Medium — call structural equality what it is.** Assertion 7 parses and
   compacts each node with `jq`, so it proves JSON-content equality, not
   byte-for-byte source equality. Prefer canonical `jq -S -c` structural
   equality and update the message/plan wording; raw whitespace and object-key
   order are not meaningful lock semantics.
5. **Before freezing, integrate the audit path deliberately.** If the helper is
   a repository artifact, land it with its focused tests and dispatch wiring,
   then rebase the lock branch and freeze the resulting complete tip. Also name
   the helper invocation in Gate A so the executable procedure cannot drift
   back into prose.

## 2026-08-30 23:43 NZST — hourly checkpoint

### Observed progress

- No repository-visible implementation progress occurred since 22:42. The
  audit helper is unchanged from 21:46, the revised plan is unchanged from
  22:12, and no focused audit test or dispatch reference exists.
- `main` remains at `3ce623b`; the clean raw-lock branch remains at `286d3fc`
  with the same one-file delta. No waiver, compatibility fix, candidate freeze,
  gate evidence, landing, or primary promotion is visible.
- Every required execution-record field remains unfilled. This means any work
  happening outside the repository cannot yet be attributed to a declared
  evidence destination or immutable candidate.

### Findings and recommendations

1. **The three audit-helper findings from 22:42 remain open.** Do not treat the
   current happy-path `AUDIT: PASS` as Gate A evidence until negative behavior
   tests prove exact changed-node equality, allowed-field presence, and
   whole-document closure.
2. **Use the current fail-open behavior as the next Red step.** Add a focused
   test that expects a no-op lock pair, a partial refresh, a deleted allowed
   field, and an extra top-level field to fail. It should fail against the
   current helper for the diagnosed reasons. Then implement Green and wire the
   suite into the established dispatcher before refactoring.
3. **Do not freeze or start expensive gates while the record is blank.** At
   minimum, name the decision maker, maintenance window, external evidence
   directory, raw-lock SHA, proposed tip, and complete rollback set first.
4. **Interpret this checkpoint narrowly.** It proves no worktree or commit
   delta during the hour; it does not prove that an external validation process
   is absent or stopped. Only recorded, SHA-bound results should affect the
   promotion decision.

## 2026-08-31 00:43 NZST — hourly checkpoint

### Observed progress

- A second consecutive hour produced no repository-visible delta. `main`, the
  clean `286d3fc` raw-lock branch, the audit helper, the plan, and all blank
  execution-record fields are unchanged.
- A process snapshot briefly found two external-agent watcher shells referring
  to `scratchpad/recreate1.log` and polling `pgrep -f 'bin/dx-recreate'`. It did
  not reveal a distinct `dx-recreate` process. The referenced scratchpad log was
  absent when inspected, and a follow-up process query was unavailable, so this
  is not authoritative evidence of a running or completed recreate.
- The focused audit tests and dispatcher integration recommended at 22:42 and
  23:43 still do not exist.

### Findings and recommendations

1. **High — do not monitor gates with a broad command-line substring.** Each
   watcher command itself contains `bin/dx-recreate`, so `pgrep -f` can match the
   watcher (or another watcher) after the real child exits. Launch the gate with
   an explicit PID/session handle, retain its exit status, and observe that
   exact handle (`wait`, `kill -0`, or an equivalent exact-PID check).
2. **High — missing scratchpad output is not gate evidence.** A recreate can be
   credited only when its complete log and exit status are preserved in the
   declared external evidence directory and bound to the candidate SHA and lock
   hash. Do not infer success from a watcher ending or a process name
   disappearing.
3. **The audit helper is still not ready to freeze.** Its happy path remains
   useful exploratory evidence, but the exact-delta negative tests and
   fail-closed implementation changes remain the next TDD step.
4. **Pause candidate-affecting work until the execution record is filled.** If
   the observed recreate was part of this plan, it ran before a declared window,
   evidence destination, or immutable candidate and must be rerun after freeze;
   if it was unrelated, label it separately so it cannot be mistaken for a
   promotion gate.

## 2026-08-31 01:43 NZST — hourly checkpoint

### Observed progress

- A third consecutive hour produced no repository-visible delta. All commit
  identities, candidate contents, implementation/document timestamps, blank
  execution-record fields, and missing audit-test/dispatch artifacts are
  unchanged.
- No exact live gate handle could be verified at this checkpoint; process-list
  access was unavailable. The broad watchers observed at 00:43 remain
  insufficient evidence regardless of whether they still exist.
- A direct behavioral probe confirmed that
  `tests/lib/audit-flake-lock.sh <base> <base>` exits 0 and prints `AUDIT: PASS`
  while explicitly reporting that no nodes changed.

### Findings and recommendations

1. **The repository-visible execution is paused before candidate freeze.** This
   is a safe state for the primary, but none of Gate groups A–D can be credited
   and the plan remains open.
2. **Turn the confirmed no-op pass into a focused Red test.** Candidate-specific
   Gate A requires the exact inventoried refresh, not merely confinement of any
   changes that happen to exist. Either make the helper require an expected
   changed-node set or keep it generic and add a mandatory candidate-specific
   wrapper assertion. In both designs, a no-op or partial candidate must fail
   the gate.
3. **Resume in dependency order:** first add and dispatch the negative audit
   tests, then make the helper fail closed, then commit the revised plan and
   follow-up artifacts, rebase the raw-lock branch, and only then fill/freeze the
   execution record. Starting live or destructive work sooner would create
   evidence for the wrong tree.
4. **Do not treat elapsed time as validation.** The unchanged clean branch and
   stable lock hash preserve the candidate, but they do not replace any
   repository, Nix, reused-volume, fresh-volume, or running-generation gate.

## 2026-08-31 02:43 NZST — hourly checkpoint

### Observed progress

- A fourth consecutive hour produced no repository-visible delta: `main` is
  still `3ce623b`, the clean raw-lock branch is still `286d3fc`, the candidate
  still has the same one-file lock delta, and all execution-record fields remain
  blank.
- The audit helper remains untested and undispatched. No waiver, freeze record,
  gate output, landing, or promotion artifact appeared.
- Exact process inspection was unavailable again because the host process
  service failed, so there is no new authoritative live-gate evidence.

### Findings and recommendations

1. **No new technical finding supersedes the earlier review.** The open
   exact-delta, path-presence, whole-document, TDD, evidence-capture, and
   exact-process-handle recommendations remain required before Gate A or any
   later gate can be credited.
2. **Resume at the smallest proven Red boundary:** a dispatched behavior test
   rejecting the helper's confirmed no-op pass. Do not resume with another live
   recreate; it would still target an unfrozen tree with no declared evidence
   destination.
3. **Make process observability part of the evidence procedure.** The executor
   should record the launched PID/session identifier, command, start time,
   candidate SHA, exit status, and durable log path. Host-wide process discovery
   is neither reliable enough nor specific enough to reconstruct those facts
   afterward.

## 2026-08-31 03:43 NZST — hourly checkpoint

### Observed progress

- A fifth consecutive hour produced no repository-visible delta. The branch
  SHAs, one-file lock change, untracked audit helper, document timestamps,
  absent focused test, and blank execution record are all unchanged.
- There is still no durable, SHA-bound evidence for any repository, Nix,
  canary, destructive, landing, or primary gate.

### Findings and recommendations

1. **No new finding changes the disposition:** execution remains safely paused
   before freeze, and every substantive recommendation from 22:42–02:43 remains
   open.
2. **If the executor session is expected to be active, inspect that session
   directly.** Five hours without a worktree, commit, test, record, or durable
   log delta is stronger evidence of a paused workflow than of a long-running
   gate, but it is not proof that the agent process terminated.
3. **Restart from the recorded TDD boundary, not from live validation:** add the
   no-op/partial-delta Red tests, make Gate A fail closed, integrate and rebase,
   then fill and freeze the execution record before running expensive gates.

## 2026-08-31 04:43 NZST — hourly checkpoint

### Observed progress

- A sixth consecutive hour produced no repository-visible delta. The newest
  non-tracking artifacts remain the audit helper from 21:46 and revised plan
  from 22:12 on 2026-08-30.
- `main` and `bump/lock-refresh` remain at `3ce623b` and `286d3fc`
  respectively; the candidate remains clean and safely preserved, but no plan
  gate has advanced.

### Findings and recommendations

1. **Treat the workflow as paused, not actively executing, until an exact agent
   or gate handle proves otherwise.** Six hours without a commit, worktree,
   focused-test, execution-record, or durable-evidence delta is sufficient to
   stop describing repository-visible progress as active.
2. **Confirm or restart the executor session if uninterrupted execution was
   intended.** The restart point is deterministic and non-destructive: create
   the focused audit Red cases documented above. Do not discard or recreate the
   clean raw-lock branch.
3. **All promotion blockers remain open.** No Gate A–D, landing, rollback, or
   primary-adoption conclusion can be drawn from the unchanged state.

## 2026-08-31 05:43 NZST — hourly checkpoint

### Observed progress

- Execution resumed. `main` advanced from `3ce623b` to `59b0494` (`Fold the
  second review into the bump disposition plan`), committing the revised plan,
  review removal, two follow-up plans, and lock-audit helper.
- `bump/lock-refresh` was cleanly rebased and is now `8ff05d8`, whose parent is
  exactly `59b0494`. It still differs from `main` only in `flake.lock`, and the
  lock SHA-256 remains
  `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9`.
- The helper commit records `bash -n` success and explicitly says mandatory
  ShellCheck has not run. It describes three manual tampering checks, but no
  focused test or dispatcher reference was committed.
- The execution record remains unfilled. In particular, `8ff05d8` is the new
  raw-lock commit after rebase; it is not yet the candidate tip because the
  required waiver and any audit correction are absent.

### Findings and recommendations

1. **Good — the integration topology now follows the plan.** The documentation
   stack landed first, the lock commit was rebased onto it, the linked worktree
   is clean, and the exact one-file/hash invariants survived.
2. **High — ad hoc tampering is not a TDD substitute.** Commit `59b0494` landed
   the audit helper without durable behavior tests. Add a forward test/fix
   commit that demonstrates Red on the confirmed no-op pass plus partial delta,
   deleted allowed field, and extra top-level field; then make Green and wire
   the suite into the established dispatcher. Do not rewrite or weaken the test
   to preserve the helper's current behavior.
3. **Do not freeze `8ff05d8` as the final candidate.** It is the raw-lock audit
   anchor. The final candidate must also contain the digest-qualified waiver and
   the audit test/fix stack, and every gate must name that later immutable tip.
4. **Refresh the execution-record identities when it is filled.** The previous
   `main` is now `59b0494`, and the raw lock commit is now `8ff05d8`; the older
   `3ce623b`/`286d3fc` pair is historical evidence only.
5. **Keep the mandatory lint gate open.** Run the helper through the pinned
   ShellCheck 0.10.0 path in the guest and preserve its output before crediting
   Gate group B.

## 2026-08-31 06:43 NZST — hourly checkpoint

### Observed progress

- `main` advanced through six focused commits to `c0ab55e`. The work includes
  pre-existing host-suite fixes, fail-closed Gate A behavior with a dispatched
  Section 26 suite, recorded smoke results, repository-wide ShellCheck cleanup,
  and documentation of a flaky Section 16 result.
- Gate A's four identified fail-opens were addressed with an explicit Red →
  Green record. Section 26 currently reports 21 passed / 0 failed locally, and
  the helper now requires the exact expected node set and validates allowed-leaf
  presence and top-level key closure.
- `bump/lock-refresh` was rebased again and is clean at `af758ea`, directly on
  `c0ab55e`, with the same sole lock-file delta and lock hash.
- The recorded smoke table still has coverage, all four Nix builds, and the
  fresh-volume path unrun. Reused-volume Gate D is red at 1040 passed / 2
  failed / 9 skipped, and the waiver/final candidate/execution record remain
  incomplete.

### Findings and recommendations

1. **Blocker — Section 26 is not fresh-clone reproducible.** Its candidate
   fixture is loaded with `git show 8ff05d8:...`, but `8ff05d8` is no longer
   contained by `main`, `bump/lock-refresh`, any local/remote ref, or either
   branch's ancestry after the rebases; it survives only in local reflogs. The
   local 21/0 result therefore depends on developer repository state and will
   fail after clone/GC. Check immutable base/candidate JSON fixtures into the
   test tree (or generate them self-contained), remove reflog-only SHA
   dependencies, and prove Section 26 in a fresh clone before crediting Gate B.
2. **Blocker — Gate D is red, regardless of causality.** Showing the Section 16
   race also occurs on the pre-refresh primary correctly separates it from the
   lock bump, but the plan says both canary states are required and the tip does
   not land unless they are green. Repeating a 1-in-5 flake until lucky would
   not validate behavior. Fix the race and preserve the helper's diagnostics in
   a separate TDD commit on `main`, rebase the raw lock, then rerun Gate D. If
   that work is declined, park rather than promote.
3. **High — all recorded identities are stale again.** The plan still names
   previous main `759240f`, raw lock `8ff05d8`, and smoke anchor `7f97613`; the
   authoritative pair is now `c0ab55e` / `af758ea`. Update identities only
   after the fixture and migration blockers land, because each new commit and
   rebase invalidates the freeze again.
4. **High — the latest bootstrap changes lack a live boot.** Commit `ca265ec`
   explicitly says its bootstrap edits landed after the recorded recreate.
   Those changes are now beneath `af758ea`, so prior running-generation and
   reused-volume observations do not cover the current tree. Both canary paths
   and the three-fact proof must be rerun on the eventual frozen tip.
5. **Good — do not lose the audit TDD structure while fixing portability.** The
   negative cases and dispatcher wiring are the right behavioral contract; fix
   only fixture provenance and any genuinely missing closure case rather than
   weakening the assertions.

## 2026-08-31 09:08 NZST — combined 07:43/08:43 checkpoint

The external Docker Hub verification overran the 08:43 boundary. Repository
snapshots at 07:43 and 09:08 are identical, but no intermediate snapshot was
taken; this entry records that limitation rather than inventing one.

### Observed progress

- The Section 26 portability fix is in progress on `main`: the test now uses
  checked-in `base.lock` and `candidate.lock` fixtures instead of unreachable
  commit `8ff05d8`. Their SHA-256 values exactly match the authoritative old and
  refreshed locks, their diff is the expected 12 insertions / 12 deletions, and
  the focused suite remains green at 21 / 0.
- A digest-qualified waiver is being drafted in the lock worktree. The official
  [Docker Hub tag record](https://hub.docker.com/v2/repositories/nixos/nix/tags/2.34.8)
  confirms the draft's external facts: tag `2.34.8`, manifest-list digest
  `sha256:1a711b619c8a713eff32c3f8d8781b3b4d0130cb91c0a57f67e87abfeeb90b01`,
  last update 2026-07-06, and a Linux arm64 image.
- Both changes remain uncommitted. `main` is still `c0ab55e`, the lock branch is
  still `af758ea`, the Section 16 flake remains unresolved, and no final
  candidate or filled execution record exists.

### Findings and recommendations

1. **Good — commit-owned fixtures are the correct portability repair.** Keep
   the exact hashes and real lock shape, commit the fixture files with the test
   update, and prove the suite from a fresh clone before restoring Gate B to
   green.
2. **Blocker — the waiver currently states evidence that does not exist in the
   authoritative record.** It says the refresh was “promoted” and all four
   outputs “were built”, while the plan says the candidate tip is unfilled,
   four builds are `NOT RUN`, and no landing occurred. It also describes the
   1040/2 Gate D result as a pass “apart from” failures. Rewrite it as a pending
   candidate waiver and cite only completed preliminary evidence; final
   SHA-bound gates belong in the external execution record.
3. **Blocker — Section 16 still prevents an all-green Gate D.** Its independent
   cause does not convert two failures into a pass. Repair the Apple Container
   race and retain diagnostic output under a focused Red → Green change on
   `main`, then rebase and rerun both canary states on the final tip.
4. **High — sequence the two dirty worktrees deliberately.** Finish the fixture
   and migration fixes on `main`; preserve/correct the waiver as its own branch
   commit; then rebase the lock/waiver stack, update the now-stale SHAs, fill the
   execution record, and freeze once. Do not run final gates against either
   current dirty worktree.
5. **Medium — correct the Section 26 key-order explanation.** `jq -S` sorts
   object keys, so assertion 6 treats key reordering as structurally equal, not
   changed. That is appropriate because JSON object order is non-semantic, but
   the test header and commit narrative currently say the opposite. Describe
   canonical structural equality accurately rather than claiming byte-level
   enforcement.
6. **Assign the waiver follow-up.** `image-pin-collision-plan.md` still has an
   unfilled owner even though the draft waiver expires into that work; name the
   owner before the waiver lands.

## 2026-08-31 10:09 NZST — hourly checkpoint

### Observed progress

- No repository-visible progress occurred since the 09:08 snapshot. The
  checked-in-fixture repair and waiver remain uncommitted and byte-unchanged;
  `main` remains `c0ab55e` and the dirty lock worktree remains at `af758ea`.
- Section 16 remains flaky/red, the execution record and follow-up owner remain
  unfilled, and coverage, four builds, and the fresh-volume gate remain unrun.

### Findings and recommendations

1. **The three blockers remain unchanged:** commit-owned fixture portability,
   truthful/pending waiver evidence, and deterministic all-green Gate D must be
   resolved before a freeze.
2. **Do not commit the waiver in its current wording.** Its external tag facts
   are verified, but its promotion/build/pass claims still contradict the
   repository's own gate table.
3. **Resume on `main` first.** Finish and commit the fixture repair and the
   focused Section 16 Red → Green change before rebasing/finalizing the waiver
   stack; this minimizes repeated candidate rewrites and invalidated evidence.

## 2026-08-31 11:10 NZST — hourly checkpoint

### Observed progress

- The fixture portability repair landed on `main` as `8945eba`. Its commit
  records 21/0 both in place and from a tree copy with no `.git`, plus fixture
  corruption rejection and clean ShellCheck 0.10.0. Gate A's test provenance is
  now durable.
- A focused Section 16 repair is in progress. `dx-migrate-persist` wraps its
  three idempotent `container run` calls in a bounded retry for the exact Apple
  runtime-client error, while the test now preserves integration diagnostics
  and adds deterministic fake-boundary cases for recovery, exhaustion, and a
  non-retryable genuine error.
- The non-live Section 16 path is green at 29 passed / 0 failed / 2 skipped,
  with both changed files clean under Bash 3.2 syntax.
- The lock branch remains at dirty `af758ea`, still based on pre-`8945eba`
  `c0ab55e`, with the unchanged waiver draft. It is not a frozen candidate.

### Findings and recommendations

1. **Good — the Section 16 fix is behavior-first and bounded.** Retrying only
   the observed real-boundary message, proving retry exhaustion, and proving a
   different error is not masked are the right Red → Green contracts. Retrying
   the sentinel read, destination read, and copy is safe because each is read-
   only or idempotent and the sentinel publishes only after copy success.
2. **High — resolve the new configuration knobs deliberately.**
   `DX_MIGRATE_RUN_MAX_ATTEMPTS` and `DX_MIGRATE_RUN_RETRY_DELAY` are supported
   runtime overrides but are absent from the central `DXE_CONFIG_FIELDS`
   registry, validation, profiles, and configuration documentation. Either
   register/document/test them like the existing activation retry controls, or
   keep production values fixed/private and inject timing through an explicit
   sourceable-function seam. Do not leave public-looking `DX_*` behavior outside
   the repository's resolve-once configuration model merely for test speed.
3. **Medium — preserve command diagnostics exactly.** The wrapper currently
   discards stderr when a retry eventually succeeds and discards stdout on a
   terminal failure. Replay captured stderr on success and both streams on the
   final failure (while preserving stdout-as-data semantics at command-
   substitution callers), then add a focused assertion so the retry layer does
   not silently narrow observability.
4. **Blocker — prove Green at the real boundary.** After focused tests and
   ShellCheck pass, run Section 16 enough times against Apple Container to cover
   the previously observed 1-in-5 race without a failure, then rerun the entire
   reused-volume Gate D on the eventual frozen candidate. Fake-boundary tests
   alone do not close the runtime gate.
5. **The waiver and sequencing findings remain open.** Correct its premature
   promotion/build/pass claims, assign the follow-up owner, finish the `main`
   fix, then commit the waiver and rebase the complete lock/waiver stack onto
   the resulting `main`. Refresh every recorded SHA afterward.
6. **The Section 26 key-order comment remains inaccurate.** The fixture repair
   fixed portability but retained the claim that `jq -S` detects object-key
   reordering; `-S` canonicalizes that ordering. Correct the explanation in a
   later documentation/test cleanup without changing the sound structural
   behavior.

## 2026-08-31 13:12 NZST — hourly checkpoint

### Observed progress

- The Section 16 repair landed as `5966c35`. Its focused fake-boundary cases
  cover one-race recovery, bounded exhaustion, and a distinct non-retryable
  error; the commit also records the required Red against the old helper, 29 / 0
  / 2 without live integration, and a real-boundary 40-run batch improving from
  1 failure to 0. This is materially stronger than repeating a flaky Gate D
  until it happens to pass.
- Coverage was re-measured against the completed tree at 100% covered scope and
  21.78% scope share. Commit `aeff59c` records all repository, Nix, build, and
  both canary gates green on frozen tip `03c4f5c`; reused and fresh-volume runs
  were each 1045 passed / 0 failed / 9 skipped, with three running-generation
  proofs.
- The lock and waiver were then rebased again and fast-forwarded locally to
  `main` at `27cce6f`; `main` and `bump/lock-refresh` now name that same commit
  and both carry lock hash `ee4d64dc…`. The branch worktree is clean. Remote
  `origin/main` remains at `3ce623b`.
- Promotion is not complete. `dx-test` publishes `ee4d64dc…`, but `dx-host`
  still publishes the previous `34f29312…` lock and its container has been
  running since 2026-08-24. The primary has therefore neither adopted the
  refresh nor supplied the required post-adoption proof and health evidence.

### Findings and recommendations

1. **Blocker — `27cce6f` is not the tip that passed the gates.** The validated
   `03c4f5c` is not an ancestor of `27cce6f`. After validation, `aeff59c` changed
   the plan, the lock/waiver stack was rebased into new commits, and `27cce6f`
   changed the waiver from draft to active before the fast-forward. The plan is
   explicit that every new commit invalidates the freeze. Halt before primary
   adoption, finish all metadata and implementation corrections, freeze the
   actual final tip, and write fresh evidence outside the worktrees; under the
   current plan that means rerunning every candidate gate, not treating a
   similar tree or docs-only delta as the same immutable tip.
2. **Blocker — the execution record was bypassed and is now contradictory.** It
   still says unfilled fields prevent starting, yet decision maker/date,
   window, evidence destination, candidate tip, and rollback set remain blank;
   it still names `759240f` / `8ff05d8` while the landed lock commit is
   `84e84e9`; and the status still describes an uncommitted refresh. Reconcile
   the record to the actual commit graph before a new freeze. In particular,
   identify the pre-landing main, the complete ordered rollback set, and an
   external evidence directory containing the SHA-bound raw command logs.
3. **High — the waiver does not meet its own plan's identity requirement.** It
   records the pinned image and external tag facts, but not the candidate's
   complete commit SHA or complete lock SHA-256 required at plan lines 364–365.
   Add both to the waiver, and assign the still-unfilled owner in
   `image-pin-collision-plan.md`, before refreezing.
4. **High — narrow the retry predicate to the contract claimed.** The commit
   says it retries the exact observed signature, but production matches the
   much broader substring `no runtime client exists`. A different failure that
   includes those words can therefore be retried and reported as the known
   stopped-container race. Add a Red case containing that substring but not
   the full observed `Error: no runtime client exists: container is stopped`
   signature, then match only the validated signature.
5. **Medium — finish the retry wrapper's interface design.** The two new
   `DX_MIGRATE_RUN_*` overrides bypass the central `DXE_CONFIG_FIELDS` registry,
   profiles, and configuration documentation, while successful attempts drop
   captured stderr and terminal failures drop captured stdout. Deliberately
   choose private fixed retry policy plus a test seam, or register and document
   supported knobs; preserve original stream diagnostics and test that
   behavior. These were raised before `5966c35` and remain unchanged.
6. **Primary adoption is the next destructive boundary, not a completed
   event.** Once one real final tip is green, run the clean-main preflight,
   recreate `dx-host`, prove its PID-1 lease/current generation/lock hash, run
   the agreed health checks, and only then declare convergence and clean up the
   linked worktree/ref. The untracked tracker currently also makes the primary
   `main` worktree non-clean; handle it explicitly rather than weakening or
   skipping the clean-tree guard.
7. **Low — retain the two documentation cleanups.** Correct Section 26's false
   `jq -S` key-order explanation, and update the plan from “Open” to an accurate
   execution/acceptance status only after the primary result is known.

## 2026-08-31 14:41 NZST — hourly checkpoint

### Observed progress

- No repository commit or execution-record update landed after `27cce6f`; both
  branch pointers, the stale identities, the unfilled follow-up owner, and the
  untracked tracker are unchanged.
- The primary was nevertheless recreated at 13:24 NZST. Its bootstrap log ends
  in successful Home Manager activation, guest-tool verification, and SSH
  startup; `dx-status` sees the expected image, open SSH port, tools, persisted
  volume, and tmux session.
- The primary's three-fact generation proof is now independently observable:
  PID-1 lease `20260831T012422Z-97852.1`, `current` generation
  `20260831T012422Z-97852`, and lock SHA-256 `ee4d64dc…`. Thus local `main`,
  `dx-test`, and `dx-host` now share the refreshed lock hash even though the
  repository evidence record does not say so.
- No active gate/adoption command was visible at snapshot time. `origin/main`
  remains at `3ce623b`, and the linked worktree/ref remain present.

### Findings and recommendations

1. **Good — the primary behavioral adoption appears successful.** Preserve the
   bootstrap log and the exact three-fact proof in the designated external
   evidence directory now, before logs rotate. Also record the agreed primary
   live checks and their raw outcomes; `dx-status` is encouraging but cannot be
   silently substituted for an unspecified acceptance set.
2. **Do not reflexively roll back a healthy primary solely to repair paperwork.**
   The observed running state matches the intended lock and basic health is
   green. Hold further promotion/cleanup mutations, reconcile the control record,
   and make an explicit accept-or-rollback decision with the missing rollback
   set available. An automatic destructive retry would add risk without erasing
   the fact that the original sequence bypassed its preconditions.
3. **The final-tip blocker remains.** The primary proves the lock hash, not that
   every required gate ran on repository tip `27cce6f`; those are separate
   claims. Consolidate the execution record, waiver identity, follow-up owner,
   tracker disposition, and retry-contract corrections into the intended final
   tree, freeze once, and rerun the plan's SHA-bound gates against that one tip.
   Preserve results outside Git so recording evidence does not invalidate the
   freeze again.
4. **The pre-window record violation remains material.** Candidate SHA, actual
   raw-lock SHA, decision date/window, evidence destination, rollback set, and
   previous-main identity are still absent or stale after both landing and
   primary adoption. Backfilling must describe what actually occurred, with
   timestamps and deviations, rather than rewriting history as though the
   fields had been filled beforehand.
5. **The retry review findings remain open.** Before the new freeze, add the
   substring-collision Red case and narrow the signature; decide whether the
   retry controls are private test seams or supported config; and preserve
   captured stdout/stderr semantics. This is the last low-cost point to repair
   them before the implementation is treated as accepted production behavior.
6. **Cleanup remains premature.** Keep the branch/worktree and rollback evidence
   until the corrected final tip, primary acceptance checks, and evidence audit
   are complete. Afterward, make the plan status truthful, decide whether remote
   publication is in this window, then remove only the clean linked worktree and
   handle the branch as recorded.

## 2026-08-31 15:43 NZST — hourly checkpoint

### Observed progress

- `main` advanced to `1222c08`, addressing the broad retry predicate identified
  at 13:12. A new focused case proves Red on the old helper: a distinct
  `no runtime client exists: permission denied` error was retried into apparent
  success (`rc=0`, four calls). Green matches the validated stopped-container
  signature and fails the distinct error immediately while retaining the three
  original retry cases.
- Independent review reran the non-live Section 16 suite at 30 passed / 0 failed
  / 2 skipped, with Bash 3.2 syntax and `git diff --check` clean. The commit also
  records green unit/static, host-contract, and guest ShellCheck.
- The same commit corrects the runbook's alignment probe from
  `/guest-bootstrap` to `/guest-bootstrap/current`. The old command rejects the
  compatibility lock symlink; the corrected read-only command was verified on
  the promoted primary and evaluates the locked Nix version as `2.34.8`.
- `bump/lock-refresh` remains at `27cce6f`, so `main` is now one implementation
  commit beyond the nominal candidate branch. The execution record and owner
  fields remain unchanged, and the primary continues to run the refreshed lock.

### Findings and recommendations

1. **Good — the signature finding is closed with real TDD.** The regression
   fails against the old predicate for the diagnosed masking behavior, the
   production change is one line, and the focused suite stays green. This is the
   minimum behavior change the plan calls for.
2. **Good — the runbook command was tested at its real boundary.** Retain the
   captured old-command failure and `2.34.8` Green result in external evidence.
   If this command is operationally critical beyond the window, add a durable
   integration contract at the layer that owns the published-generation
   symlink; a prose-only command can otherwise regress unnoticed.
3. **Blocker — refreeze after integrating `1222c08`.** The validated temporary
   tip and the branch now both predate a production-code change on `main`.
   Fast-forward or rebase the intended branch topology deliberately, complete
   the remaining corrections, then rerun all SHA-bound gates on one final tip.
4. **The retry interface findings remain open.** `DX_MIGRATE_RUN_*` still sits
   outside the central configuration contract, successful calls still discard
   captured stderr, and terminal errors still discard stdout. Resolve those
   contracts with focused tests before the new freeze.
5. **Medium — keep unrelated fixes independently revertible.** `1222c08`
   combines a production retry change with an unrelated runbook command repair.
   Both are sound, but the plan asks for independently revertible compatibility
   fixes. Before publication, consider splitting the commit while preserving
   its Red/Green provenance; otherwise name the coupling explicitly in the
   rollback set.

## 2026-08-31 17:00 NZST — catch-up checkpoint

The read-only Nix verification wait delayed the expected 16:43 observation.
This checkpoint records only state observed at 17:00; it does not invent an
intermediate snapshot.

### Observed progress

- `7e5389d` committed this observer log to `main`, making the primary worktree
  clean at that instant and preserving the review history. No other plan,
  implementation, owner, or evidence-record correction accompanied it.
- `main` is now `7e5389d`; `bump/lock-refresh` remains two commits behind at
  `27cce6f`; `origin/main` remains `3ce623b`. The live primary generation and
  refreshed lock remain unchanged and healthy.
- The commit message says the maintenance window is closed. The checked-in plan
  still says `Open`, explicitly says blank record fields prevent starting, and
  retains blank/stale decision, window, evidence, candidate, raw-lock, rollback,
  and owner data.

### Findings and recommendations

1. **Do not use `7e5389d` as closure evidence.** Committing the tracker resolves
   its untracked clean-tree issue, but it also creates another unvalidated tip
   while monitoring and plan reconciliation are still active. The file itself
   correctly says it is not the external SHA-bound gate record. Supply that
   record separately and do not conflate “external reviewer” with “external
   evidence directory.”
2. **High — correct two inaccurate claims in the new commit narrative.** The
   repository reflog places `59b0494` on `main` at 05:40 and the subsequent
   audit commits at 06:05–06:30; therefore the cited 23:43–04:43 checkpoints
   reporting `main` at `3ce623b` were contemporaneously correct, not six hours
   stale. Also, assertion 6 reads both nodes through `jq -S`, which sorts keys;
   reordering an allowlisted node is structurally equal. Assertion 7 is the
   separate order-sensitive check for `nixpkgs-unstable` and `systems`. Amend
   before publication or add a checked-in correction rather than permanently
   labelling accurate observations unreliable.
3. **The window cannot be called closed against the current definition of
   done.** There is still no one immutable final tip with all gates, no filled
   execution/rollback record, no owned image-pin follow-up, and no recorded
   primary acceptance set. Either finish those requirements or explicitly
   document a decision to deviate; silent omission is neither completion nor a
   revised plan.
4. **Recommended convergence sequence remains:** finish the retry interface and
   all metadata in one deliberate final tree; update the branch topology;
   freeze; store raw results outside both worktrees; rerun gates; re-prove the
   canary and already-healthy primary; then mark status complete and clean up.
   Avoid further evidence commits between freeze and acceptance.

## Correction, 2026-08-31

Two claims published in earlier commits of this series were wrong. Both were
checkable against this repository, and both are corrected here rather than left
standing.

**1. The reviewer's checkpoints were accurate; my commit said they were stale.**

`7e5389d` stated that checkpoints between 23:43 and 04:43 "reported `main` at
`3ce623b` and the audit helper as uncommitted for six hours after neither was
true". The reflog disproves it:

    59b0494 main@{2026-08-31 05:40:40 +1200}
    3ce623b main@{2026-08-30 19:03:26 +1200}

`main` was at `3ce623b` from 19:03 until 05:40. Every one of those checkpoints
was contemporaneously correct. The error was mine: I assumed the documentation
commit had landed hours earlier than it did, and then characterised an accurate
observer as unreliable in a published commit message.

**2. Node comparison is structural for allowlisted nodes, not order-sensitive.**

`1b9ca68` stated that a claim of merely structural comparison "is false:
reordering keys within a node already fails". That holds only for assertion 7,
which covers `nixpkgs-unstable` and `systems` via `jq -c`. Assertion 6, which
covers the allowlisted changed nodes, uses `jq -S` and sorts keys, so a
reordered allowlisted node compares equal. Verified: reordering `nixpkgs` exits
0, reordering `systems` exits 1.

The original refutation tested `systems` — an assertion 7 node — and
generalised from it. The reviewer's point stood for the assertion it was about.

No behaviour changes. `jq -S` is the right comparison for allowlisted nodes,
because key order carries no meaning in JSON; the defect was in how the
behaviour was described, not in the behaviour. Assertion 7's label is corrected
from "byte-for-byte identical", which `jq -c` does not provide since it
normalises whitespace, to "identical, field order included".
