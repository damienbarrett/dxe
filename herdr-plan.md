# Plan — add `herdr` to the DX guest

Drafted 2026-08-02. Revised the same day after an independent review whose
load-bearing claims were re-verified and are now consolidated into this plan.
Several findings corrected the original design, including one factual error
about the released artifact's licence.

## Status

The product decisions are settled. One implementation blocker remains:
the checked-in `flake.lock` predates Herdr's nixpkgs package. Clear it in the
package Red → Green → Refactor slice before that slice can be considered green.

## Corrections to the previous draft

The upstream and repository claims were verified directly. All of the following
were confirmed:

| Claim | Verification | Verdict |
| --- | --- | --- |
| `v0.7.5` is **AGPL-3.0-or-later**, not Apache-2.0 | `Cargo.toml` at tag `v0.7.5` → `license = "AGPL-3.0-or-later"`; tag `LICENSE` is dual AGPL-or-commercial; nixpkgs builds `tag = "v0.7.5"` | **Corrected from the previous draft** |
| Upstream relicensed *after* the release | commit `cd5ea1b`, 2026-07-22, "relicense herdr under apache-2.0" — one day after `v0.7.5` (2026-07-21) | Confirmed |
| The checked-in lock has no herdr | `nix eval github:nixos/nixpkgs/27ac479f…#herdr.version` → *does not provide attribute*. Lock is 2026-05-29 | Confirmed — **blocker** |
| Sessions/history live under `~/.config/herdr`, not `~/.local/state/herdr` | `src/config/io.rs` at `v0.7.5`: `config_dir()` honours `XDG_CONFIG_HOME` else `~/.config/herdr`; `config.toml` is `config_dir().join(…)`; a separate function reads `XDG_STATE_HOME` | Confirmed — **my layout was backwards** |
| `dx-ai` refreshes the whole bundle | `dx-ai.sh`: `nix flake update … nixpkgs-unstable` then `nix profile add …#ai-tools` | Confirmed |
| `dx-ssh` owns far more than SSH options | `bin/dx-ssh`: `HOST_TZ`, `TERM`, OSC colour-reset trap, `GUEST_PATH`, SSL cert vars, `DX_GUEST_WORKDIR`, theme restore, tmux guard | Confirmed |
| nixpkgs disables upstream tests | `doCheck = false` in `package.nix` | Confirmed — our live smoke test matters |

**My licence error, stated plainly.** I reported Apache-2.0 from GitHub's
repository-level detection, which describes current `master`. I then dismissed
the crates.io AGPL signal as "a stale or unrelated crate". That signal was
correct evidence about the released artifact, and I was wrong to wave it away.

One important nuance: `config_dir()` honours `XDG_CONFIG_HOME`,
which **is** set in this guest (`/home/dx/.config`). So herdr's paths are
deterministic here and the tmux-style `/tmp` fallback I worried about cannot
occur. That removes the rationale for pinning `HERDR_SOCKET_PATH` entirely.

## Resolved conflicts

Both conflicts in the earlier drafts are settled.

### C1 — No retention pruner (YAGNI)

An earlier draft of this plan claimed scrollback "grows without bound". That was
wrong. `session-history.json` is **replaced on each snapshot**, not appended, and
the live buffer is already capped by `advanced.scrollback_limit_bytes` (upstream
default 10,000,000 bytes per pane). Total size scales with pane and session
count, not with elapsed time — so an age pruner would delete a three-month-old
session still in daily use while ignoring a hundred idle panes created today.

**Decision: build no pruner.** The per-pane byte cap is the real bound. Ship a
documented, user-invoked cleanup path for `session-history.json` and record the
measured directory size as evidence. Revisit only if that measurement shows a
problem. Do not add an age/session pruner merely to solve a nonexistent
append-only log.

### C2 — Accept the AGPL release

The artifact nixpkgs builds is `v0.7.5`, AGPL-3.0-or-later with a commercial
alternative. Apache-2.0 exists only on unreleased `master`; packaging that would
mean a custom derivation off a moving target and is not justified here.

**Decision: use the AGPL nixpkgs package.** This matches the owner's acceptance.
Practically it is unproblematic for this use: the AGPL's basic permissions cover
running an unmodified program and making private copies, and invoking a separate
executable does not relicense DXE's own shell and Nix code.

Three things to carry rather than forget:

- If DXE **conveys** the binary, object-code distribution obligations apply.
  The optional profile lives on the `/nix` and `/persist` volumes while
  `dx-export` captures only the container root filesystem, so the normal export
  path does not appear to convey it — but a future export of those volumes, or
  a pre-populated image, would. Preserve notices and source availability and
  document that path rather than discovering it later.
- If DXE ever modifies Herdr and lets users interact with that modified version
  remotely, AGPL section 13 adds a corresponding-source offer requirement. The
  current design uses an unmodified, separate nixpkgs executable and does not
  trigger that scenario.
- A future Apache-licensed stable release will arrive through the normal nixpkgs
  update, at which point this ceases to be a consideration at all.

This is a compliance summary, not legal advice.

## Release blockers

**B1 — `flake.lock` must be updated and committed.** The checked-in
`nixpkgs-unstable` revision predates herdr's arrival in nixpkgs, so adding
`herdr` to `aiPackages` makes checked-in evaluation fail. CI evaluates the
committed lock, and a runtime `dx-ai` lock update does not repair it. Update to
a reviewed revision containing herdr, commit it, and record whether that
revision substitutes on a cold `aarch64-linux` store.

~~B2 — Licence decision~~ **cleared**: the AGPL release is accepted (C2). B1 is
the only remaining blocker.

## Decisions

| # | Decision | Note |
| --- | --- | --- |
| H1 | herdr joins `aiPackages` | Unchanged |
| H2 | Coexist with tmux; add `bin/dx-herdr` | Unchanged |
| H2a | `dx-herdr` bypasses tmux; the two never nest | Unchanged |
| H2b | Missing Herdr → run `dx-ai` once when the activated helper is Herdr-aware | The notice must say the *whole optional AI bundle* is being installed or updated. A stale helper fails with a recreate diagnostic; it is not retried blindly — see D1 |
| H3 | Lazy start | **Revised**: do **not** set `HERDR_SOCKET_PATH` or `HERDR_CLIENT_SOCKET_PATH`; use herdr's native layout |
| H4 | Persist config, sessions, pane history | **Revised layout** (below). Bound is the per-pane byte cap; **no pruner is built** (C1) |
| H5 | Existing `master` pin | Unchanged, but blocked on B1 |
| H6 | Install without confirming | Unchanged; scope message revised per H2b |
| H7 | **Default session only** in v1 | Reject named-session selection at the wrapper; keep herdr's native layout so adding them later is additive |
| H8 | **No live upgrade or handoff** | New. Supported refresh is cold: `dx-recreate` → explicit `dx-ai` → `dx-herdr`. Live pane processes are not preserved |
| H9 | Persist all of `~/.local/state/herdr` | New. Private mutable application state: downloaded agent-detection rules, plugin state, announcement state |
| H10 | Seed the two history settings once | Add `experimental.pane_history = true` and `advanced.scrollback_limit_bytes = 10000000` when missing; preserve later explicit user changes and unrelated TOML |
| H11 | No Herdr argument pass-through in v1 | `dx-herdr` attaches the default session. This removes an unsafe/underspecified argv boundary and prevents named, remote, or non-persistent modes |

### D1 — why a presence check is not enough

`dx-recreate` preserves `/nix` and `/persist`, including the existing `dx-ai`
profile. After recreation the **old** Herdr executable is still present, so
"is `herdr` installed?" answers yes and cannot be an upgrade check. The
canonical upgrade workflow is therefore `dx-recreate` → explicit `dx-ai` →
`dx-herdr`; ordinary `dx-herdr` launches never refresh an already-present
bundle.

Do not add live-server upgrade detection, refusal, migration, predecessor-client
selection, transition journals, or handoff for this feature. Running `dx-ai`
against a live Herdr server is outside the supported workflow; documentation
states the cold-recreate precondition instead of promising process survival.

The first-install case is different. When Herdr is absent, `dx-herdr` performs
a non-mutating, machine-readable capability probe against the activated
`dx-ai` helper: `dx-ai --supports herdr` emits no normal output and exits zero
only when the helper knows how to validate and verify a generation containing
Herdr. If it does, `dx-herdr` announces the
complete bundle scope, streams one `dx-ai` attempt, re-probes Herdr, and either
continues or returns the install failure. If the helper lacks that capability,
the wrapper fails distinctly with a `dx-recreate` instruction. Do not grep
helper source, invoke a possibly incompatible helper, retry blindly, or build a
self-contained shadow activation path into the host wrapper.

### Why named sessions are deferred

Plain `herdr` starts or attaches the default session. A named session such as
`herdr session attach client-a` has its own background server, sockets,
workspaces, tabs, panes, snapshots, history, logs, and stop/delete lifecycle;
all sessions still share global configuration and the plugin registry. Named
sessions are useful for independently stopping or automating isolated groups of
work, but they are not required for multiple repositories because one default
session already holds multiple workspaces, tabs, and panes. Retaining Herdr's
native directory layout makes later named-session support additive rather than
a persistence migration.

## Corrected state layout

```
~/.config/herdr/            <- persisted, mode 0700
  config.toml               global config
  session.json              default session structure
  session-history.json      pane history (opt-in)
  herdr.sock                default session API socket
  herdr-client.sock         default session client socket
  *.log                     capped client/server logs
  sessions/<name>/          named sessions (not exposed in v1)

~/.local/state/herdr/       <- persisted, mode 0700 (H9)
  agent-detection/          rules fetched from herdr.dev
  plugins/<id>/             plugin runtime state
  announcements             seen-state
```

The previous draft had this inverted and asserted "the socket must not live on
`/persist`". That assertion is dropped: herdr's sockets live beside its session
data, named sessions ignore `HERDR_SOCKET_PATH`, and building a separate
ephemeral socket tree would add complexity to solve nothing. Rely on herdr's
0600 socket mode and its tested stale-socket cleanup. Host and guest sockets
cannot collide despite identical pathnames — different kernels, different
filesystems, and `dx-herdr` never runs the host binary. Unset host `HERDR_*` at
the boundary regardless.

On first setup, seed these missing values without replacing unrelated settings:

```toml
[experimental]
pane_history = true

[advanced]
scrollback_limit_bytes = 10000000
```

This is a TOML-aware, idempotent update: preserve explicit existing values and
all unrelated tables/comments rather than rewriting `config.toml` from a
template. Once seeded, both values belong to the user and later changes survive
activation. If an existing file cannot be updated safely, leave it intact and
fail with a diagnostic rather than partially rewriting it.

Create both persistent targets and their home-side parents as `dx:dx`, mode
0700. Reject unsafe symlink/non-directory targets. When a real home directory
already exists, migrate it if the persistent target is absent; otherwise move
the home directory to a private, timestamped backup rather than merging or
overwriting ambiguous data. Repeat activation must be a no-op apart from
repairing declared ownership/modes.

**Sensitive-output warning, to be documented.** Pane history serialises visible
terminal output — pasted tokens, `env` output, `gh auth token`, `cat` of config
files, agent conversations. It is off upstream by default for that reason.
Persisting it makes transient terminal data durable, surviving detach, restart,
and recreation, and it enters `/persist` backups. The documented cleanup path
must first require an intentional cold server stop, warn that this ends its pane
processes, remove `session-history.json`, and verify on the next start that the
saved screen contents are absent.

## `dx-herdr` design

```
dx-herdr [--help]

  1. resolve config                      (dx-lib.sh facade, D2 snapshot)
  2. require container running
  3. if herdr is absent, apply the capability/install contract in D1
  4. exec plain herdr in the guest over the shared interactive SSH contract
```

Plain `herdr` already lazily starts its detached server when necessary and then
attaches the client. DXE does not supervise, daemonize, or explicitly start it.

The configuration reference in step 1 is the repository's versioned D2 config
snapshot contract: resolve once on the host and pass the complete validated
snapshot through; no child command re-reads `.env`.

- **Reuse, don't clone, `dx-ssh`.** Extract the shared interactive contract so
  both commands keep `HOST_TZ`, `GUEST_PATH`, SSL vars, `TERM`,
  `DX_GUEST_WORKDIR`, theme restore, and the OSC colour-reset trap. Cloning
  guarantees drift.
- Put the extracted implementation in a namespaced, source-only `bin/lib/`
  module. Sourcing it must emit nothing and must not change shell options,
  `IFS`, traps, umask, working directory, configuration, or external state.
- **Do not treat `dx-ssh`'s base64 command-string transport as argv transport.**
  It joins inputs with `$*`, so original argument boundaries are already lost.
  V1 avoids that boundary entirely: the remote program is the fixed plain
  `herdr` command and the wrapper rejects all arguments except its own
  `-h`/`--help`. If pass-through is added later, design a per-argument transport
  under D6 and explicitly exclude `--session`, the `session` subcommand,
  `--no-session`, and `--remote` until their semantics are approved.
- Allocate a TTY only for the interactive attach, propagate exit status, and
  stream install output without a capturing substitution. Unset inherited
  `HERDR_*` variables at the host/guest boundary.

## Implementation sequence — Red → Green → Refactor

Every slice follows the repository constitution and validation matrix:

1. **Red:** write the smallest practical behavior test first, run the smallest
   applicable tier, and observe it fail for the intended missing behavior.
2. **Green:** implement only enough to satisfy that test, then rerun the tier.
3. **Refactor:** remove duplication and improve names/boundaries while green,
   then rerun the same tier. Do not commit a deliberately red state.

Use automated interaction through functions, commands, fake process boundaries,
pseudo-terminals, or the live guest wherever practical. Source/configuration
string searches are supporting evidence only for genuinely declarative facts
such as Nix package membership; they do not substitute for observable behavior.

Apply that cycle to these slices:

1. **Package and generation contract.** Red tests cover the package/committed
   lock inventory, Herdr-aware `dx-ai` capability probe, generation validation,
   verification, recovery, and truthful full-bundle output. Green updates and
   commits `flake.lock`, adds Herdr, and updates every inventory that currently
   enumerates only `codex gemini claude agy`: `dx_ai_validate_generation`,
   `dx_ai_verify`, Sections 6, 12, and 17 fixtures, optional-tool docs, and
   recovery tests. Refactor repeated tool inventories without obscuring the Nix
   declaration.
2. **Persistent state and configuration.** Red fixture tests invoke the actual
   sourceable persistence functions and observe creation, permissions,
   migration, private backup, collision rejection, idempotence, and TOML
   seeding/preservation for both Herdr directories. Green implements the
   smallest safe setup. Refactor it into focused, source-safe functions and
   rerun unit/static plus coverage tiers.
3. **Shared interactive SSH and host wrapper.** Red host-contract tests drive
   `dx-herdr` with fake `container`, `ssh`, and `dx-ai` executables and assert
   help/argument rejection, config snapshot reuse, fixed remote command, TTY
   selection, environment isolation, workdir, terminal cleanup, streaming,
   exit status, capability diagnostics, one install attempt, and successful
   attach. Green implements the shared path and wrapper. Refactor shared logic
   out of `dx-ssh` without changing its public behavior, then rerun host,
   import-purity, coverage, and Bash 3.2 tiers.
4. **Live isolated behavior.** Red acceptance tests are added before the final
   live wiring. Green proves the behaviors below on `dx-test`. Refactor only
   after those tests pass, rerun the complete live tier, and promote to
   `dx-host` only after all final gates and measurements pass.

## Validation

| Tier | Requirement |
| --- | --- |
| Syntax + pinned ShellCheck | Clean |
| Container-free contracts | Behavior passes with fake boundaries and no real Apple `container` binary |
| Coverage | 100% over declared scope; share not regressed |
| Bash 3.2 | `dx-herdr` and its host tests run under `/bin/bash` 3.2; add the suite to `run-bash32-tests.sh` if it is not in Section 9 |
| Nix evaluation | `nix flake check --no-build --no-write-lock-file` on the **committed** lock |
| Real build | aarch64-linux closure built in the Linux guest/builder — **not** a generic `nix build` on aarch64-darwin; the flake exports only `packages.aarch64-linux` |
| Live isolated | On `dx-test`, before `dx-host` |
| CI | Both jobs green |
| Release candidate | Commit the candidate, require a clean worktree, then run `tests/release-check.sh` |

Live tests must interact with Herdr and prove:

- the exact version and declared licence;
- a pane containing a known, non-secret marker survives detach / SSH disconnect
  / reattach with the same pane PID and visible marker;
- a server restart and a container recreation restore the documented layout and
  pane-history marker, while recreation is allowed to end the old pane process;
- marker data in both persisted Herdr directories survives recreation with the
  declared ownership and modes;
- stale sockets are removed safely and live sockets are not stolen;
- the wrapper starts only the default session and rejects every argument rather
  than permitting named, remote, or non-persistent modes;
- corrupt and too-new snapshots degrade to a fresh session rather than failing;
- the canonical cold flow permits an explicit `dx-ai` redeploy after recreation;
- first use with a Herdr-aware helper performs one streamed bundle install and
  attaches, while a pre-Herdr helper gives the distinct recreate diagnostic;
- a failed install is attempted once, preserves the previously selected AI
  generation, and propagates its failure; and
- the documented history cleanup removes the saved marker and does not claim to
  terminate or preserve live pane processes.

## Risks

| Risk | Mitigation |
| --- | --- |
| Committed lock lacks herdr | B1 — blocking |
| Cold-store Rust build during unprompted install | Stream output; measure on `dx-test`; H5 revisitable with that timing |
| Full-bundle update surprises the user | Notice names the whole bundle; failed refresh retains the previous generation |
| Pane history durably stores secrets | Documented, 0700 directory, byte cap, cleanup path |
| Stale activation: new host code, new bootstrap, old installed `dx-ai` | Distinct diagnostic; do not retry blindly |
| Persisted plugin/detection state drifts from the pinned generation | Documented as mutable state; do not claim the guest is fully reproducible |
| Existing Herdr data/config is damaged during setup | TOML-aware seed, private backup on collision, fail closed, idempotent behavior tests |

## Backout

More than removing one line. It must: remove herdr from generation validation
and verification; require a cold stop of any herdr server before its backing
generation is collectible; remove the host command, shared tests and docs; and
state explicitly whether persisted config, history and application state are
retained. Retaining is reasonable, but history and plugin state may contain
secrets, so point at a user-controlled cleanup path rather than silently keeping
them forever.

## Open measurements

Not decisions — facts to record after implementation:

1. Does the chosen lock revision substitute on a cold `aarch64-linux` store? If
   not, the measured build time and closure size.
2. Cold `dx-herdr` install duration — the number that decides whether H5 stands.
3. Measured total size of the persisted herdr directories, which is the evidence
   base for C1.
