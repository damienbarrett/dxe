# Declarative Nix audit — plan A

Survey of `dxe` for work that is done imperatively in shell but could (and
should) be expressed declaratively in idiomatic Nix.

Scope reviewed: the guest flake and home-manager modules, the guest bootstrap
modules, the guest `scripts/`, the host `bin/` layer, CI, and the shell
coverage gate.

Item numbers are stable identifiers, not an execution order. The order is at
the end.

## Status

Open. Tracked in Git; its recommendations have not been adopted as an
implementation plan.

**Revisit trigger:** before the next NixOS release bump touches `flake.nix`,
or when Tier 0's CI gates are next considered; at that point the audit is
either adopted (Tier 0 + Tier 1) or archived, not left in a third state.

## The shape of the problem

`container/aarch64-darwin-apple-container-dx-nixos-26.05/` is 1,130 lines of
Nix — 689 of them outside the `nvim/` tree — against 2,387 lines of bash
bootstrap, or 3,765 counting the guest `scripts/`. The Nix that exists is
genuinely idiomatic: `home/theme.nix:49` builds the Tinty config with
`pkgs.formats.toml` and generates it at `:81-82`, which is exactly right. The
bash is where declarative work has been done imperatively.

But the first thing to understand about this repo is not the ratio. It is that
**the Nix is less checked than the bash**. The shell in the covered scope is
held at 100% line coverage by a CI gate. The home-manager tree is evaluated by
nothing — not CI, not any test — until a guest boots. Every item below moves
code across that line, so the gates come first.

---

## Tier 0 — the gates

These are not cleanup. Each one is a precondition for the tiers below being an
improvement rather than a trade.

### 16. `homeConfigurations` is never evaluated by anything

`flake.nix:176` defines `homeConfigurations.dx`. That is not a well-known flake
output, so `nix flake check` warns and skips it. CI's only Nix step is:

```yaml
# .github/workflows/ci.yml:34
run: nix flake check --no-build --no-write-lock-file ./container/...
```

So `home.nix`, `home/shell.nix`, `home/tools.nix` and `home/theme.nix` — 689
lines, and the destination for items #5, #6, #7 and #9 — are evaluated in
exactly one place: a live guest at boot, where `bootstrap/activation.sh:26`
builds `#homeConfigurations.dx.activationPackage` on the critical path to a
usable shell. A type error there does not fail CI. It fails a boot.

This falsifies the justification recorded in `tests/coverage/exclusions.txt`:

> `*.nix | Declarative Nix is checked by evaluation/build, not shell line coverage.`

It is checked by neither, for the tree that matters most. And `--no-build`
means nothing is *built* even for the outputs `flake check` does walk, so a
`pkgs.formats.toml` generator is constructed and never realised.

**Fix:** add `checks.${system}.home = self.homeConfigurations.dx.activationPackage;`
to `flake.nix`, and drop `--no-build` (or add an explicit `nix build` of the
checks). `tests/test_section0_lint.sh:24-33` asserts the literal string
`nix flake check --no-build` is present in the workflow, so it changes with it.

**Confirm on CI, not locally** — `nix` is not installed on this host, so
`tests/test_section5_nix.sh:42` and `test_section8_nixvim_config.sh:88` both
skip here. Expect `warning: unknown flake output 'homeConfigurations'` in the
current "Nix evaluation" log as confirmation.

### 12. The coverage ratchet punishes every refactor below — and the obvious fix does not work

`tests/run-coverage-linux.sh:65-68`:

```
scope_lines  = *.sh under bin/lib + bootstrap/ + scripts/lib
total_lines  = *.sh under bin, tests, container (plus bin/dx*)
share = scope_lines * 10000 / total_lines   # must be >= 2176
```

`.nix` files count in neither term. So moving 280 lines of `herdr-config.sh`
into Nix takes the share from 3904/17936 = 2176 bp to 3624/17656 = **2052 bp**,
and CI fails. Worse, `ratchet.env` defines the failure it is watching for as
"production logic moving out of bin/lib, the bootstrap modules, or
scripts/lib" — which is indistinguishable from a shell-to-Nix conversion.

**Adding `.nix` to `total_lines` does not fix this.** The share is
`scope / total` with `scope ⊂ total`; removing `n` lines from both gives
`(scope-n)/(total-n)`, which is strictly smaller for any `scope < total`. No
change to the denominator repairs that. Measured, for the same 280-line
conversion producing ~80 lines of Nix:

```
baseline with .nix counted:  3904 / 19066 = 2047 bp
after the conversion:        3624 / 18866 = 1920 bp   <- still fails
```

**Fix: replace the ratio with a ceiling on uncovered production shell.** What
`ratchet.env` says it is guarding is "production logic moving out of the
covered scope". That is directly measurable as the line count of production
shell *outside* that scope — `bin/dx*`, `container/**/bootstrap.sh`,
`container/**/scripts/*.sh`, precisely the three patterns already enumerated in
`tests/coverage/exclusions.txt`. Today that is **3,179 lines**. A ceiling on it
catches the real regression, does not move when tests are added, and does not
penalise shell → Nix.

That second property matters independently of this audit. `ratchet.env` records
**nine** rebaselines, at least five of them written purely to absorb the
test-dilution edge the file itself keeps re-documenting — tests are 10,853 of
the 17,936 denominator lines. The metric has been re-litigated in prose more
often than it has caught anything.

Changes `tests/run-coverage-linux.sh:65-68` and `tests/coverage/ratchet.env`.
The 100% line-coverage assertion at `:51-63` is a separate, working gate and
stays exactly as it is.

**Recorded conflict — `refactor-v2-final.md` Phase 4 / A1.** Phase 4's first
gate re-measures the coverage ratchet against the tree at the point it runs.
A1 (a review finding on that same plan) was closed against the ratio's
`7ffa66b` measurement. If this item's reform lands first, both that
re-measurement and A1's closure are against a metric shape (a ratio) that no
longer exists. Undecided which lands first; no owner named for either
document yet.

### 17. Roughly ninety test assertions read these files as text

This is the real cost of Tiers 1 and 2, and it is invisible until you start.

```
$HOME_THEME_NIX   23 assert_file_contains
$TOOLS_NIX        21
$SHELL_NIX        15
$FLAKE_NIX        12
```

Plus the bootstrap sources:

- `tests/test_section4_ssh.sh:8-13` greps **`bootstrap/system.sh`** for the five
  `sshd_config` settings and for `dx ALL=(ALL) NOPASSWD:ALL`. Items #2 and #4
  break these directly — the strings stop being in that file.
- `tests/test_section6_tools.sh:222,224` assert the literal `command -v starship`
  and `type -q starship` in `shell.nix`. Item #6 removes both.
- `tests/test_refactor_contracts.sh:183` extracts `bootstrapEssentials` from
  `flake.nix` with `sed` — the same technique #1 objects to in production.

The constitution already calls this out: *"Where practical, tests should
validate behaviour, not simply parsing configuration files."* These assertions
exist because there was no other gate available — see #16. Fixing #16 is what
makes the replacement possible: an evaluation gate can assert against the built
`activationPackage` rather than the source text.

**Do this per-item, not as a sweep.** Each conversion below replaces the text
assertions for the file it touches, in the same change.

---

## Tier 1 — clear wins, small and low-risk

### 1. The NixOS release is parsed out of `flake.nix` with `sed`

`bootstrap/system.sh:47`:

```sh
release="$(sed -n 's#^[[:space:]]*nixpkgs\.url[...]#\1#p' "$DX_BOOTSTRAP_ROOT/flake.nix" | head -1)"
```

Text-scraping Nix source is the least idiomatic thing in the repo, and the test
suite already knows better — `tests/test_section5_nix.sh:77` uses
`nix eval --raw --inputs-from ... nixpkgs#lib.version` as the *mandatory*
release oracle. Production should use the same value.

`/etc/os-release` itself (`write_release_identity`, `system.sh:30`) should be a
flake output built with `lib.generators.toKeyValue`; bootstrap then just
`install -m0644`s it.

The bootstrap ordering makes this safe and cheap. `bootstrap.sh:10-23` runs
`install_essentials` at `:12` and `configure_release_identity` at `:25`, so by
the time the release is needed the flake has already been evaluated and
nixpkgs is in the store. Either an `--inputs-from` eval or a built output is a
warm operation there, not a cold fetch on the path to sshd.

### 2. `sshd_config` is a heredoc behind a substring guard

`bootstrap/system.sh:360-374`:

```sh
if [ ! -f /etc/ssh/sshd_config ] || ! grep -q "Port 2222" /etc/ssh/sshd_config; then
```

This is a correctness issue, not just style: change `PermitRootLogin` or
`PasswordAuthentication` in the repo and any guest whose existing config still
contains `Port 2222` never picks it up. A store-path config compared by hash
(or symlinked) cannot drift silently.

`/etc/ssh` is a real directory on the rootfs, not a link into `/persist` —
`dx_persist_host_keys` explicitly refuses a symlinked `/etc/ssh`
(`system.sh:278`) and persists only the host *keys*. So the drift window is
concrete: edit the repo, then `dx-start` rather than `dx-recreate`, and the
stale config survives.

Note the port itself is fine — `2222` is the fixed guest-side port and
`DX_SSH_PORT` is the host-side mapping (`bin/dx-create-container:53`). Only the
drift guard is the problem.

### 4. `/etc/sudoers` and `/etc/sudoers.d/dx` are written once and never repaired

`bootstrap/system.sh:207-217`. Both writes sit behind `[ ! -f ]` guards
(`:208`, `:213`), which is the same defect as #2: an externally edited,
truncated, or wrong-moded file is never corrected, on any boot, forever.

The content is a fixed string literal, so it cannot be malformed *from the
repo* — `visudo -c` validation would guard nothing that can currently happen.
Drift is the whole issue, and it has the same fix as #2. **Land these two
together as one "system files stop drifting" change**, and replace
`tests/test_section4_ssh.sh:8-13` with probes against the generated files.

### 5. Hand-written config text where home-manager has typed options

`home/tools.nix:115-118` writes `xdg.configFile."lazygit/config.yml".text` as a
raw string. `programs.lazygit.settings` takes an attrset, is checked at
evaluation time, and merges properly with other modules. Straightforward.

**btop is not.** `home/tools.nix:120-132` sets `force = true` on
`xdg.configFile."btop/btop.conf"`, and that is load-bearing: btop rewrites its
own config file, so without `force` the next activation collides with it. Home
Manager's `programs.btop` module has no `force` escape hatch — it owns the
`xdg.configFile` entry itself. Converting the btop half trades a working
override for activation failures or a trail of backup files.

Do lazygit. Leave btop as it is unless the module has since grown a `force`
option.

### 6. Starship, direnv and the yazi wrapper are hand-rolled — but not three times

`home/shell.nix` repeats the direnv hook and the `starship init` call across
bash (`:28-33`) and fish (`:73-78`), and the `y()` cd-on-exit wrapper across
bash (`:20-26`), fish (`:64-71`) and nushell (`:103-111`).

`programs.starship.enable`, `programs.direnv.enable` (plus `nix-direnv.enable`,
replacing the two bare packages at `flake.nix:59-60`), and
`programs.yazi.enable` with `shellWrapperName = "y"` generate that integration
from one declaration each. The `command -v starship` guards also do PATH
lookups where `${pkgs.starship}/bin/starship` would be hermetic.

Two constraints, both easy to miss:

**Nushell must be opted out.** It has no starship and no direnv today, and
`shell.nix:96-97` records that as deliberate — *"Nushell Tinted-shell startup
support is intentionally not enabled. It has not been proven for the selected
Tinty template version."* The `programs.*` modules enable nushell integration
by default, so a plain `enable = true` ships new, unproven behaviour under the
banner of a refactor. Set `enableNushellIntegration = false` on all three.
There is a second hazard there: `shell.nix:98-101` assigns `$env.config`
wholesale, which would clobber a hook record a direnv snippet had already
upserted, depending on merge order.

**Starship's config file is written at runtime.**
`scripts/dx-theme-write-tool-themes.sh:266` writes `~/.config/starship.toml` on
every theme switch. Home Manager's starship module claims that same path — as
far as I can tell only when `programs.starship.settings` is non-empty, which is
why `enable = true` alone is safe. **Verify that against the pinned
release-26.05 module before relying on it**, and either way leave a comment on
the option saying that setting `settings` there will silently break `dx-theme`.

Replaces `tests/test_section6_tools.sh:222,224`, which assert the guard strings
this item deletes.

### 7. `home.sessionVariables.PATH` prepends by hand

`home/shell.nix:142-143`. `home.sessionPath` is the option for that.

One thing to check first: the current value deliberately *prepends* the
`dx-ai` profile bin ahead of `$PATH`, and that ordering is what makes an
installed AI generation win. Confirm the generated `hm-session-vars.sh` still
prepends rather than appends before switching.

---

## Tier 2 — larger, still clearly right

### 8. `bootstrap/herdr-config.sh` is a 281-line TOML parser written in bash regex

Five regex constants, six associative arrays, parallel basic-string and
literal-string patterns for the same key. Meanwhile `home/theme.nix` two
directories over generates TOML the idiomatic way.

The defaults in `bootstrap/herdr-config.toml` are static and could be
`(pkgs.formats.toml {}).generate`. The merge is the part that genuinely cannot
be pure — the config is user-mutable and persisted.

This is the right target, but it is the hardest item here and four things
constrain it:

**The merge runs before Home Manager, with almost nothing on PATH.**
`dx_activate_herdr` is called at `activation.sh:257`; `run_home_manager_activation`
is at `:262`. Only `bootstrapEssentials` (`flake.nix:79-94`) is available — no
awk, no jq, no python, no TOML tool of any kind. "Run it against a real TOML
parser from the flake" therefore means adding one to the pre-sshd bootstrap
closure, which `flake.nix:70-78` explicitly warns against ("editing the guest
toolset above can never silently change what the guest needs to reach sshd")
and which `tests/test_refactor_contracts.sh:183` guards line-by-line. Moving
the seed *after* Home Manager is the alternative, and `activation.sh:245-248`
records a live defect from the last time its position moved.

**The merger is deliberately format-preserving.**
`dx_herdr_merge_existing` (`:171-221`) copies each of the user's lines verbatim
and only *appends* what is missing. User comments, key order and formatting all
survive. Round-tripping through any non-format-preserving TOML library destroys
that, which rules out most of the obvious tools. This also makes the
multi-line-array limitation far less dangerous than it looks: an array the
parser cannot see is still copied through untouched.

**There is a second merger over the same file.** `write_herdr_theme`
(`scripts/dx-theme-write-tool-themes.sh:422-518`, ~96 lines) does its own
hand-rolled merge of `~/.config/herdr/config.toml`, for the same stated reason
— *"Pure Bash ... awk is not in the early essentials profile"* (`:436-437`).
Any change here has to keep the two in agreement, and the item is really ~380
lines, not 281.

**It contradicts a recorded decision.** `herdr-config.sh:4-8` says the file
lives in `bootstrap/` *specifically* to stay inside the coverage scope:
"moving production logic out of that scope is exactly the regression the
scope-share ratchet exists to catch." Under the current ratchet that is
correct, and this item is self-defeating. Under #12's replacement it is not.
**#12 must land first, in the recommended form.**

Two things the current implementation gets right and a rewrite must keep:
`dx_herdr_validate_candidate` (`:222-228`) validates the merged candidate
against the real consumer via `herdr config check` before anything is moved
into place, and `dx_herdr_seed_config` is content-hash idempotent (`:274-276`),
so an unchanged config is not rewritten.

Fix the attribution while here: the awk incident is recorded at
`activation.sh:253-255`, not in `herdr-config.sh`.

### 9. Persistence symlinks are created imperatively with bespoke migration code

`bootstrap/activation.sh:200-233` and
`bootstrap/persistence.sh:164,190,373,405` each do `ln -sfn /persist/... ~/.x`
plus hand-written collision handling.

`config.lib.file.mkOutOfStoreSymlink` is the home-manager idiom for a link into
a mutable path. The comment at `persistence.sh:167` — *"/persist is a runtime
mount, so Home Manager cannot create this directory declaratively"* — is true
of the **directory** but not the **link**: `mkOutOfStoreSymlink` does not
require the target to exist at build time.

**Applies to six of the ten links, not all ten.** `~/.gemini`, `~/.claude`,
`~/.claude.json` and `~/.codex` (`activation.sh:230-233`) are created only when
the AI profile is present, and the condition is discovered at runtime by
inspecting the live nix profile (`:217-218`). `mkOutOfStoreSymlink` is
unconditional at build time. A guest that never opted in would get four
dangling links, and `mkdir -p` through a dangling symlink fails — so tools that
create their own config directory would break rather than degrade. There is no
Nix-visible flag to gate on. Leave those four alone.

**And `home-manager.backupFileExtension` does not cover the hard case.**
`persistence.sh:290-340` is not 50 lines of backup logic; it is root → dx
ownership repair and mode scoping for the *home-side parents*, plus content
migration into `/persist`. The comment at `:309-315` records why, from a live
failure: `mkdir -p` runs as root, so a freshly created `~/.config` is
root-owned, and the subsequent `run_as_dx "ln -sfnT ..."` fails with permission
denied. Home Manager activation runs as dx and cannot fix that either.
`backupFileExtension` renames a colliding file; it neither migrates content nor
repairs ownership. The ownership half stays in bootstrap regardless.

### 10. The theme system git-clones from GitHub at runtime

`scripts/dx-theme.sh:65,162` run `tinty install || tinty sync`, fetching
tinted-shell, tinted-tmux and tinted-lazygit from GitHub, unpinned, at first
boot. So `home/theme.nix` declares the config declaratively and then hands off
to a network fetch — a fresh guest cannot theme itself offline, and nothing
pins what it gets.

These should be flake inputs with the item `path`s pointed at store paths.

**There is a fourth fetch.** `tinty install` also retrieves the base16 *scheme
registry*, not just the three `items` repos — `have_scheme` (`:29-31`) tests for
it and `ensure_tinty_data` (`:54-66`) gates the whole call on it. Pinning only
the items leaves the guest still reaching for the network on first boot.

**Verify first:** confirm against tinty 0.29.0 (the pinned version) that
local-directory `path` items behave as expected, *and* that tinty does not
attempt to update them in place — the store is read-only, and a `git pull`
against a store path fails.

---

## Tier 3 — structural

### 13. CI's shellcheck is the one genuinely unpinned input

`.github/workflows/ci.yml:23-28` uses `nix shell "nixpkgs/${NIXPKGS_PIN}#shellcheck"`
with `NIXPKGS_PIN: nixos-25.05` — a mutable registry reference to a channel
branch, in no lock file, and a *different* nixpkgs from the guest's 26.05. The
comment pinning it to 0.10.0 behaviour is enforced by nothing.

A flake input plus a `devShells.<system>.ci` output would make the pin real.
`tests/test_section0_lint.sh:19-20` asserts the current form, so it changes too.

### 14. There is no root flake and no `devShells.aarch64-darwin`

Host tooling comes from `Brewfile` (bash, shellcheck, nix). The flake's only
devShell is `aarch64-linux` (`flake.nix:155-157`), so `nix develop` does not
work on the machine the developer is actually sitting at — and `nix` is not
currently on this host at all, which is why the local flake checks in
`test_section5_nix.sh` and `test_section8_nixvim_config.sh` skip.

`container` itself cannot be packaged, but bash and shellcheck can, and that
would delete the Brewfile and give #13 somewhere to live.

### 15. `26.05` is written out in nine places with no single source

- `flake.nix:5,9,13` — the three input URLs
- the context directory name
- `bin/lib/dx-config.sh:25` (`DX_IMAGE`), `:30` (`DX_CONTEXT_DIR`), `:31`
  (`DX_BOOTSTRAP_SOURCE`)
- `home.nix:7` — `stateVersion`
- `tests/test_helpers.sh:47` (`CONTAINER_DIR`), `:56` (`DX_EXPECTED_NIXOS_RELEASE`)
- `.github/workflows/ci.yml:34` — the flake-check path
- `tests/profiles/default.env:13,23` — documented defaults

**This does not follow from #1.** The directory name, `DX_IMAGE`,
`DX_CONTEXT_DIR` and the CI path are string literals that must resolve *before*
any Nix evaluates; a value derived from the flake cannot anchor them. The
host-side anchor is `bin/lib/dx-config.sh` deriving `DX_IMAGE` from the
basename of `DX_CONTEXT_DIR`, which is a bash change, not a Nix one.

**Exclude `home.stateVersion` explicitly.** It records the release at which the
profile was first created and is deliberately pinned; deriving it from the
nixpkgs input would defeat the Home Manager migration machinery the option
exists for. `plan.md:121` records the bump as a per-release review decision, and
it should stay one.

---

## Deliberately not doing

### The image build

`Containerfile` is a single `FROM` line and all guest construction happens at
boot. The textbook answer is `pkgs.dockerTools.buildLayeredImage` or a NixOS
system closure, which would make the user, sudoers, sshd, `nix.conf` and
timezone declarative in one stroke.

That is not actionable here: it would need an `aarch64-linux` builder on a
darwin host, and a large share of the bootstrap exists specifically to manage
the `/nix` volume remount and store import — work an image build cannot
perform. Worth naming as the direction of travel, not as a task.

### 3. `/etc/nix/nix.conf` as a flake output

Chicken-and-egg. `configure_single_user_nix` (`base-and-storage.sh:724-737`) is
the **first** call in `bootstrap_main` (`bootstrap.sh:11`), before
`install_essentials` at `:12` builds anything from the flake. The file has to
exist to configure the nix that would build it.

`experimental-features` is not the obstacle — `DX_NIX_FEAT_OPTS`
(`common.sh:7`) passes `--extra-experimental-features` on the command line
anyway. The blocker is `build-users-group =`, whose comment
(`base-and-storage.sh:726-728`) records that without it a root-invoked `nix`
re-owns `/nix/store` to `root:nixbld` and locks `dx` out. A `nix build` issued
before this file is written is exactly that root-invoked nix.

The current form is an unconditional 7-line heredoc rewritten on every boot, so
it has none of the drift problem that motivates #2 and #4. Leave it.

### 11. Replacing `dx-ai.sh`'s generation system

`scripts/dx-ai.sh` calls `nix profile add --profile "$stage/profile"` (`:144`)
and wraps it in `generations/<id>` directories, a `.predecessor` file, a
`current` symlink, `chmod -R a-w`, and a garbage collector — `:112-209`, about
120 of the file's 337. `nix profile` does provide generations, atomic
switching, `rollback` and `history`, so the shape is suggestive.

It does not survive contact. The wrapper does three things profiles do not:

- **Validates before publishing.** `dx_ai_validate_generation` (`:155-162`)
  refuses to publish unless all four tool binaries are executable *and*
  `flake.nix`, `flake.lock`, `pins/agy.json` and `.predecessor` are present and
  are regular files. `nix profile` has no post-install gate; a generation that
  built but produced a broken closure is published either way.
- **Pairs each profile with the sources that produced it**, immutably
  (`chmod -R a-w`, `:190`). Profiles retain store paths, not the `flake.nix` /
  `flake.lock` / `pins/agy.json` that `dx-ai update` needs to roll forward from.
- **Bounds retention to one predecessor** (`dx_ai_collect_generations`,
  `:171-185`). `nix profile` keeps every generation until an explicit
  `wipe-history`, which on a guest with a persisted volume is unbounded growth.

The profile also lives *inside* each generation (`$stage/profile`), so each has
its own single-generation profile. Restructuring onto one shared nix-managed
profile is a redesign of the update model, not a simplification of it. The
duplication that genuinely exists — the GC and the rollback pointer — is the
cheap part and is already correct.

---

## Suggested order

1. **#16** — the evaluation gate. Nothing should move into Nix that CI never
   evaluates.
2. **#12** — the ratchet, as a ceiling on uncovered production shell. Unblocks
   everything below, and #8 in particular is self-defeating without it.
3. **#17** — not a step of its own. Each item below replaces the text
   assertions for the files it touches, in the same change.
4. **#1**, then **#2 + #4** as one "system files stop drifting" change.
5. **#5** (lazygit only), **#6**, **#7** — one home-manager change.
6. **#9** — the six unconditional links; the ownership repair stays in bootstrap.
7. **#8** — the TOML merger. The largest and the most constrained; last of the
   substantive work.
8. **#13**, **#14**, **#15** — small, and can land whenever convenient. #15 no
   longer follows from #1, and #14 gives #13 somewhere to live.
9. **#10** — independent, still gated on the tinty verification.
