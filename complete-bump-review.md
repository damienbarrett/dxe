# Independent Review of `complete-bump-plan.md`

Reviewed: `complete-bump-plan.md` against the working tree at `main` / `37efce9`.

- **Round 1** (against the 248-line plan): findings R-01…R-10 below.
- **Round 2** (against the revised 354-line plan): the plan now
  incorporates most of round 1, pushes back on one finding (correctly — see
  R-04), and surfaces new defects in the README that round 1 had flagged as
  unreviewed. Re-verified against the same commit; the tree is unchanged.
- **Round 3** (this update, against the revised 421-line plan): the plan now
  absorbs all of round 2, including R-13, and *refines* the R-13 fix (see
  R-13). Re-verified against the same commit; **the tree is still unchanged at
  `37efce9`** — this is now the second consecutive round where the review was
  folded into the plan document with no repository change. See "Round 3
  verdict."

Method: each load-bearing claim was re-derived against the actual source,
tests, and git state rather than taken on trust — including claims the plan
makes *about this review* and about documentation this reviewer authored.

**Independence caveat (unchanged):** this reviewer authored the
implementation under audit, so this is an independent review of the **audit
document**, not of the implementation. A fully independent implementation
review should still come from someone who did not write the code.

## Round 2 verdict

The revised plan is **accurate, and now materially more complete than round
1's review**. It:

- correctly dispositions R-01, R-03, R-05, R-06, R-08, R-09, R-10 (accepted),
  R-02 (accepted with a valid clarification), and R-07 (accepted as session
  evidence);
- **correctly overturns R-04's narrowing** — section 16 does *not* honour
  `--skip-integration` for its live block; my "precision correction" was
  wrong (see R-04 below, now withdrawn);
- **acts on R-09** by reviewing the README "Upgrade / Bump" runbook I wrote
  and finding two real defects round 1 did not check (now R-11, R-12);
- reprioritises exactly as round 1 recommended: `--skip-integration` raised
  to P0, the Tinted runtime test lowered to P1.

**The one status point that matters most:** "implemented many
recommendations" means the **plan document** now records them — the **tree is
unchanged at `37efce9`**. No README, `plan.md`, or test fix has landed
(`git status` shows only the three untracked planning docs; `git log` HEAD is
still `37efce9`). Every P0 item — the doc contradictions (R-01, R-11, R-12,
R-02) and the `--skip-integration` code fix (R-04) — remains **open in the
repository**. The plan is now an accurate and well-ordered TODO; execution is
still pending.

## Round 4 — the plan was executed (2026-07-05)

The user directed "execute the plan." All P0 and P1 items were implemented,
verified, and committed; the deferred hardening (`.env` precedence, bootstrap
provenance, F-09/F-10) and guard removal were intentionally left out of scope
per the plan. This is the durable validation record the plan's P0 asked for
(previously only "session execution evidence").

**Commits landed on `main`:**

- `b8a6e8c` — P0 doc record: R-01 (essentials resolve through the global
  registry, not the lock), R-11 (targeted `nix flake update … --flake <ctx>`),
  R-12 (runbook step refs 7/6), R-02 (plan.md Phase-3 contradiction resolved;
  the never-built `nixos-2605.env` path marked superseded). Section 10: 70/70.
- `edb6a99` — P0 `--skip-integration`: `SKIP_INTEGRATION` exit before the live
  block in §15/§16/§17; new `tests/test_section20_skip_integration.sh`
  (stubs `container`/`ssh`/`scp`/`dx-ai`) proves the skip path invokes no
  guest command — **red 6/8 → green 8/8**; wired into `run_all` (help `0-20`).
  Split so the intermediate commit's tree is self-consistent (verified).
- `b61db36` — P1 nvim payload: exact-match `project.nvim` `vim.notify` filter
  (R-13) + live section-14 runtime assertions.
- `d26d15a` — R-14 (new, from the command-by-command runbook review): the
  static-gate glob `test_section$s*.sh` collided (s=1→10-19, s=2→20); fixed to
  `test_section${s}_*.sh` and added section 20 to the gate.

**Validation (recorded):**

- `nix flake check --no-write-lock-file` in an 8 GB container against HEAD →
  **`all checks passed!`**.
- **dx-test** full profile-aware `run_all_tests.sh` → **906 passed, 0 failed**
  ("All tests PASSED!"; up from 884 with the new section-14 live block and
  section 20).
- **dx-host** (primary, focused): release oracle `26.05.20260630.95ca1e2`,
  `VERSION_ID="26.05"`, Nix `2.34.7`, old-base gate `OLD_BASE_ABSENT`.
- **Section 14 live on both dx-test and dx-host → 130 passed, 0 failed**: no
  `tinted-colorscheme` deprecation; `colors_name` == `tinty current`;
  `watch=true` live reload; project.nvim empty-history warning absent; control
  notification still shows (filter not over-suppressing). The 2 skips are the
  pre-existing `DX_TEST_DESTRUCTIVE` continuum test and the best-effort
  real-project history-write check.
- The nvim payload was deployed to both guests via `dx-stop-container` →
  `dx-start-container` → `dx-wait-ssh` (no destructive changeover). The
  user's project.nvim warning is fixed on the primary.

**Verification-method note:** an ad-hoc headless probe that wrapped
`vim.notify` *above* the config filter produced a false positive
(`PROJECT_WARN=true`); the committed section-14 assertion checks the actual
notification path (with a control) and is the authoritative, green result.

Completion criteria: all met except the intentionally-deferred follow-ups.

## Round 3 verdict

The plan is now a **fully converged specification**: it has absorbed every
round-2 finding, including R-13, and its only substantive change this round is
a *refinement* of the R-13 fix (accepted — see R-13; I re-verified the refined
version against the live plugin). No new inaccuracies were introduced; I found
nothing new to correct.

**This is the load-bearing observation for round 3:** two consecutive review
rounds have now been folded into the plan document with **zero repository
change** — HEAD is still `37efce9`, and I independently re-confirmed that
R-01, R-11, and R-12 are *still literally present* in `README.md`
(`README.md:654` broad `nix flake update`; `:624-626` the `--inputs-from`
essentials claim; `:745`/`:755` the "step 6"/"step 5" stale references). The
plan and this review have reached the point of **diminishing returns on
further iteration**. The marginal value is now entirely in **execution**, not
more planning:

- the P0 documentation fixes (R-01, R-11, R-12, R-02) are a handful of
  one-line edits to `README.md` and `plan.md` — minutes, no code risk;
- R-04 and R-13 are small, well-specified TDD tasks the plan already scopes
  precisely;
- R-07 is one recorded suite run.

Recommendation: stop iterating the plan and start landing the P0 items. A
third review round did not surface anything a first execution pass would not
have made moot.

## Findings

Status key: **[fixed]** landed in tree · **[planned]** correctly captured in
the plan, not yet in tree · **[withdrawn]** this review was wrong.

### R-01 — README "One release pin" self-contradiction — CONFIRMED · [planned, P0-doc-1]

`README.md:624-626` claims essentials install with `--inputs-from …` resolving
to the lock; `README.md:645-646` correctly says they use the global registry;
`grep -c 'inputs-from' bootstrap.sh` = **0** (`install_essentials` runs plain
`nix profile install nixpkgs#…`). Still present in the tree. Highest-value fix.

### R-11 (NEW, surfaced by the revised plan) — README "One release pin" uses a too-broad `nix flake update` — CONFIRMED · [planned, P0-doc-2]

`README.md:654` is a bare `nix flake update`. Two problems, both real:
it refreshes **all** inputs including `nixpkgs-unstable` (contradicting the
stated goal of leaving the optional AI set untouched during a stable bump),
and a bare `nix flake update` from the repo root fails because the root is not
a flake (the flake lives in the context dir). The correct form — the one the
actual bump used and the one the new runbook's step 4 already documents — is
`nix flake update nixpkgs nixvim home-manager --flake <context-dir>`. The plan
caught this; I did not in round 1. Valid.

### R-12 (NEW, surfaced by the revised plan) — stale step numbers in the README "Upgrade / Bump" runbook I authored — CONFIRMED · [planned, P0-doc-3]

Verified against the actual headings:
- runbook intro (`README.md:745`) says "the destructive apply in **step 6**";
  the destructive apply is **step 7** (`### 7. Apply to the primary`, line 901);
- the "hard-won rules" warning (`README.md:755`) says activation breaks
  surface "at the canary in **step 5**"; the canary is **step 6**
  (`### 6. Canary`, line 882) — and `README.md:879` already says "step 6," so
  the runbook contradicts itself internally.
Both are real off-by-one references in my own runbook. This is exactly the
independent check R-09 asked for, and it found defects — good catch by the
plan. Fix both references.

### R-02 — plan.md Phase-3 status contradiction — CONFIRMED, plan's clarification accepted · [planned, P0-doc-4]

`plan.md:58` both attributes the nushell break to "Phase 3 live testing" and
says "Phase 3 … has not been run yet." The plan's clarification is correct and
sharper than mine: the break was found on the **`dx-test` Stage-B canary**,
while the formal `nixos-2605.env` Phase-3 profile **was never created**
(`tests/profiles/` holds only `default`, `dx-test`, `dx-tinty` — confirmed).
The fix should record the canary run and mark the never-built profile path
superseded, not merely reword "Phase 3."

### R-03 — `dx-recreate` is not "mere reactivation" — CONFIRMED · [planned, P1]

`bin/dx-recreate` runs `dx-destroy` (removes container **and** image) then
`exec dx`. My `tinted-nvim-plan.md:153` mischaracterises it; the plan's
correction (payload-only apply = `dx-stop-container` → `dx-start-container` →
`dx-wait-ssh`, which is what the real deploy did) stands.

### R-04 — `--skip-integration` side effects — CONFIRMED for the defect; my section-16 narrowing WITHDRAWN · [planned, now P0]

The core finding holds and the plan rightly **elevated it to P0**: section 17
runs the side-effectful `dx-ai` installer gated only on `requires_container`
(no `SKIP_INTEGRATION`), and section 15 does live SSH/SCP work.

**Correction to my round-1 review:** I claimed section 16 "does honour
`SKIP_INTEGRATION`." That was wrong. Verified: `test_section16_persist_storage.sh`
guards **only** its migration-helper sub-block with `SKIP_INTEGRATION`
(`test_skip … else run_migration_helper_tests`), then falls through to live
`/persist` probes gated only on `requires_container`. The plan is correct that
**sections 15, 16, and 17 all** need an outer skip between static and live
blocks. R-04's "precision correction" is withdrawn; the plan's wider scope is
right. Its remedy (an explicit `SKIP_INTEGRATION` exit before each live block,
plus a stub regression proving no guest/SSH/SCP/container/`dx-ai` command runs
on the skip path) is the correct shape.

### R-05 — F-09/F-10 store-reuse defects — CONFIRMED · [planned, deferred]

`bootstrap.sh:184` still `cp -a -n /nix/store/. /mnt/tmp-nix/store/`
(unregistered). Correctly kept as a hard blocker on in-place pin bumps.

### R-06 — `tinted-nvim-plan.md` stray fence — CONFIRMED · [planned, P1]

`grep -c '```' tinted-nvim-plan.md` = 7 (unbalanced); trailing stray fence.
Bundled with R-03 into the plan's Tinted-plan cleanup.

### R-07 — end-to-end validation executed; the gap is the record + one residual — CONFIRMED, plan accepts · [planned, P0]

Stage-A (884/884 + recreate), Stage-B (884/884, oracle = 26.05), and the
primary changeover (salvage → factory-reset → rebuild → `OLD_BASE_ABSENT` →
884/884) were all performed this session. The plan now states this and
correctly reduces the residual to: a post-Tinted `flake check` and **one**
recorded full `dx-host` suite run (the last primary suite predates the Tinted
commit; only nvim was spot-checked afterward). No destructive re-run needed.

### R-08 — `dx-get`/`dx-put` fix omitted — CONFIRMED, plan accepts · [fixed in c63079f; now recorded]

The plan added a "Changeover file-transfer reliability" section crediting
`c63079f`. Resolved.

### R-09 — the new README runbook was unreviewed — CONFIRMED, plan acts · [planned, P1]

Round 1 flagged that neither the plan nor I had independently reviewed the new
"Upgrade / Bump" runbook. The revised plan reviewed it and found R-11/R-12.
That is the finding working as intended. The runbook still warrants a full
command-by-command pass before operational reliance, per the plan's P1 item.

### R-10 — uncommitted audit artifacts — CONFIRMED, plan accepts · [planned, P1]

`complete-bump-plan.md`, `complete-bump-review.md`, and `tinted-nvim-plan.md`
are all untracked. Decide tracked-vs-scratch and commit or remove together.

### R-13 (NEW) — `project.nvim` "No data available to write!" warning: root cause + concrete fix — CONFIRMED, plan accepts and refines · [planned, P1]

This is the warning still shown on nvim launch now that the tinted deprecation
is gone. Diagnosed against the shipped plugin
(`project.nvim 4.1.1`, the `project.util.*` fork) rather than guessed. The
plan (round 3) accepts the finding and **refines the fix** — see the
"Round 3" note after the snippet.

**Root cause (verified in source).** `lua/project/util/history.lua:714`,
inside `write_history()`:

```lua
if vim.tbl_isempty(tbl_out) then
  uv.fs_close(fd)
  Log.error(('(%s.write_history): No data available to write!'):format(MODSTR))
  vim.notify(('(%s.write_history): No data available to write!'):format(MODSTR), WARN)
  return
end
```

The message is emitted with a **direct `vim.notify(..., WARN)`** that bypasses
the plugin's own logging gate — `project/util/log.lua`'s `Log.*` return early
when `Config.options.log.enabled` is false (the default), but this `vim.notify`
does not. So **no `project.nvim` config option silences it.** It fires when
`write_history()` runs with no detected project — on the `VimLeavePre` autocmd
(`core.lua:568-571`) and on the empty-history deferred write scheduled 10 s
after startup (`history.lua:549-550`) — i.e. whenever nvim is used without
opening a recognised project root (the dashboard, a scratch buffer). It is
**benign** (there is genuinely nothing to save) but unconditional.

**Recommended fix (config-only, surgical — no plugin patch).** Add a narrow
`vim.notify` wrapper that drops exactly this message and passes everything else
through. Put it in `nvim/plugins/project-nvim.nix` as `extraConfigLua`
(nixvim concatenates `extraConfigLua` across modules, so it lives with the
plugin it concerns):

```nix
  extraConfigLua = ''
    -- project.nvim 4.1.1 emits an unconditional vim.notify(WARN)
    -- "No data available to write!" from write_history() whenever it exits or
    -- runs its deferred startup write with no detected project (dashboard /
    -- scratch buffer). It bypasses the plugin's own log.enabled=false gate
    -- (history.lua:714), so no config option silences it. Drop exactly that
    -- message; pass everything else through.
    do
      local notify = vim.notify
      vim.notify = function(msg, level, opts)
        if type(msg) == "string"
            and msg:find("write_history", 1, true)
            and msg:find("No data available to write", 1, true) then
          return
        end
        return notify(msg, level, opts)
      end
    end
  '';
```

**Verified.** Headless on the live guest: calling
`require("project.util.history").write_history()` with no project data warns
(`BASELINE_WARNS=true`); with the wrapper installed the message is suppressed
(`AFTER_FILTER_WARNS=false`) and unrelated notifications still pass. The dx
config ships no `vim.notify`-replacing plugin (no `nvim-notify`/`noice` in the
imports), so a config-time wrapper is stable; if such a plugin is added later,
move the wrapper into a `VimEnter` autocmd so it wraps the final `vim.notify`.

**Round 3 — the plan accepted this and refined the fix; I re-verified the
refinement.** The plan keeps the config-local suppression but replaces my
two-substring test with an **exact message-and-level match**, arguing that a
global `vim.notify` override should have the smallest possible match surface:

```lua
local empty_history = "(project.util.history.write_history): No data available to write!"
vim.notify = function(msg, level, opts)
  if msg == empty_history and level == vim.log.levels.WARN then return end
  return notify(msg, level, opts)
end
```

**Assessment: accept the plan's version.** Its reasoning is sound, and I
verified it against the live plugin — I captured the actual emitted message
(`EXACT_MSG=[(project.util.history.write_history): No data available to write!]`,
`LEVEL_IS_WARN=true`), and the exact-match filter suppresses it
(`PLAN_FILTER_ON_EXACT=SUPPRESSED`) while passing other warnings
(`PLAN_FILTER_ON_OTHER=PASSED`). One tradeoff to record: exact match is
**tighter but more brittle** — if a future `project.nvim` version changes the
`MODSTR` or the message text even slightly, the filter silently stops matching
and the warning returns. That is a low-stakes, self-announcing regression (the
warning simply reappears), and over-suppressing an unrelated message via too
wide a filter is the higher-stakes risk on a global override — so the plan's
choice is the right default. **Add it to the plugin-version watch list** so a
`project.nvim` bump re-checks the string. My substring version remains the
fallback if brittleness ever bites.

**Notes.** (1) The plan's round-3 disposition (a dedicated "P1 — Remove
project.nvim's empty-history warning" section) supersedes its earlier "accept
without code changes" stance — resolved. (2) TDD: the plan's test spec is
better than my original note — assert the exact warning is absent, a control
`vim.notify("dx-project-notify-control", WARN)` still shows, and a real
recognised-project session can still write history. Adopt it. (3) Deploy as a
payload/Home Manager change via `dx-stop-container` → `dx-start-container` →
`dx-wait-ssh` (not `dx-recreate`, per R-03); land it with the Tinted runtime
regression as one nvim payload-polish slice.

## Residual checks and minor notes

- **Section 18 on a real host is 55/55.** The plan (and its predecessor)
  still records "54 passed; `nc` loopback failed in the review sandbox" and
  asks for a clean host re-run. For the record, this reviewer ran section 18
  on the actual host this session and it passed **55/55** (the `nc` listener
  test works outside the sandbox). The plan's "require a clean pass" is
  satisfied; it can be marked done rather than pending.
- **No new inaccuracies** were introduced by the revision. Every new claim
  (R-11, R-12, the R-04 widening, the missing `nixos-2605.env`) was verified
  true.
- **The plan remains a document, not a diff.** Its "Completion criteria" are
  sound; nothing in them is yet met in the tree.

## Recommended order of execution (unchanged in shape, now fully agreed)

The plan's P0/P1 ordering now matches round 1's recommendation. Execution
order:

1. **Doc fixes (one pass):** R-01, R-11, R-12, R-02 — all edits to
   `README.md` and `plan.md`; highest value, lowest effort, no code risk.
2. **R-04:** make `--skip-integration` skip the live block in sections 15, 16,
   17, with a stub regression (TDD). Effectively P0 given the `dx-ai` side
   effect.
3. **R-07:** post-Tinted `flake check` (≥8 GB container) + one recorded full
   `dx-host` suite; record command, date, commit, oracle, `VERSION_ID`,
   `OLD_BASE_ABSENT`, and Tinted `colors_name` in-repo.
4. **R-03/R-06:** fix or fold `tinted-nvim-plan.md`.
5. **R-10:** commit the audit set (or delete scratch) once 1–4 land.
6. **nvim payload polish (one re-activation cycle):** land the **R-13**
   `project.nvim` notify filter and the **Tinted committed runtime test**
   (P1) together — both are nvim behavioral changes verified on the same
   `dx-stop/start` re-activation — then the runbook command-by-command pass
   (R-09).
7. Keep F-09/F-10, `.env` precedence, and bootstrap provenance as separated
   follow-ups; keep the guards until an inventory clears them.

## Limitations of this review

- Not an independent *implementation* review (authorship caveat above);
  findings are tree re-verifications plus session execution evidence.
- Round 2 did not execute any live suite; R-07's residual is a recommendation,
  not something performed here.
- R-11/R-12 concern a runbook this reviewer wrote; they were confirmed by
  direct check, but a reviewer who did not author the runbook should still do
  the full command-by-command pass the plan's P1 item asks for.
