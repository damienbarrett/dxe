# dx-ai: no silent source builds (Branch 14, `fix/dx-ai-no-source-builds`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 14.
No home directory paths, keys, fingerprints, or NAS identifiers appear below.

Branch `fix/dx-ai-no-source-builds`, from `main` `483aca4`, rebased onto
`main` `cf9f35f` before landing (commit ids below are the rebased ones).
Commits, in order: `c2f643f` (track the cached `nixpkgs-unstable` channel
branch, not master; single-input re-lock), `65c5d0e` (refuse silent source
builds in `dx-ai`: `--dry-run` cache check, fall back to the previous
generation's lock, then fail closed unless `DX_AI_ALLOW_SOURCE_BUILDS=1`),
`b427a0a` (docs, plan), `ca6446e` and `3b3f984` (cache-guard test fixtures
made independent of a real `jq`, found by the runner-matched contracts run),
`c8a5ceb` and `96e25d2` (scope-share ratchet re-measures, 1843 → 1806 →
1785 bp; tests-only dilution, no production logic left the scope).

## What changed and why

Found on Branch 6 (2026-09-26): a fresh guest's first `dx-ai` refreshed
`nixpkgs-unstable` to a **master** revision whose `codex-cli` was not yet on
the binary cache for `aarch64-linux`, so Nix compiled a large Rust workspace
inside the guest and was OOM-killed at the profile's default 12 GB. The user
ruled out larger guests (especially on the QNAP). Two changes:

1. The guest flake's `nixpkgs-unstable` input now tracks the
   `nixpkgs-unstable` channel branch (advances only after Hydra has built it,
   so it is cached for `aarch64-linux` and `x86_64-linux`). `flake.lock`
   changed in that one node only: `rev` `23ba3b80…` (master) →
   `d54020a6…` (channel, 2026-09-26); every other node byte-identical.
2. `dx-ai` runs `nix build --dry-run` on the staged `ai-tools` profile after
   the refresh and parses the derivations Nix says it "will build" (header
   wording verified against Nix 2.34's `printMissing`). Always-local trivial
   derivations are allow-listed: the `dx-ai-tools` buildEnv and its
   `builder.pl`, `agy`'s fetch+unpack (`antigravity-cli*`, whose fetchurl now
   has an explicit stable name), and nixpkgs' `claude-code` fetch+unpack
   (`claude-code*`, `claude.zst`) — `claude-code` is licensed unfree, so Hydra
   never caches it and its two seconds-long derivations would otherwise
   appear on every run and make a first install refuse. Anything else that
   would build is a cache miss: `dx-ai` copies the previously published
   generation's `flake.lock` into the stage and re-checks (staying on the
   known-cached revision with a `Notice:`); if that also misses, or no
   previous generation exists, it refuses before `nix profile add`, prints
   the package list and the remedy, and leaves the published generation
   untouched. `DX_AI_ALLOW_SOURCE_BUILDS=1` skips only the final refusal.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | green (all sub-suites) |
| G1 container-free contracts (runner-matched) | `ubuntu:24.04`, apt ShellCheck 0.9.0 + `jq`: "All tests PASSED!" |
| G1 pinned ShellCheck 0.10.0 | CI's exact file set: exit 0, no warnings |
| G2 coverage | `tests/run-coverage-linux.sh`: `covered=100%`; ratchet re-measured on clean exports (1806 at the branch tip, 1785 after the rebase) |
| G3 Nix | `nix flake check --no-build --no-write-lock-file`: "all checks passed!"; `flake.lock` diff confined to the `nixpkgs-unstable` node |
| G4 live | `dx-test`, below |
| G5 CI | GitHub Actions on the pushed rebased branch, green before `main` was fast-forwarded |

Red/green: Section 6 assertions on the input URL failed while it said
master; Section 17's fake-`nix` fixtures (all cached; heavy miss with a clean
fallback; heavy miss with a failing fallback; no previous generation; the
override; allow-listed-only builds; the published pointer unchanged after a
refusal; the F8 sourced-`dx_ai_main` ordering) failed 13 red with the
production functions undefined, then 85 passed green; the tests were shown
to bite by stashing only the production files (13 red again).

## Live validation on `dx-test` (profile default: 12 GB, 4 CPU)

A `dx-recreate` of the previous `dx-test` (which carried an AI generation)
first hit a **pre-existing `main` defect unrelated to this branch**: bootstrap
aborted after Home Manager activation with "dbus-daemon not found on dx's
PATH" (`setup_keyring_service`), leaving the guest stopped. Reproduced twice;
the files involved are byte-identical to `main`. It is tracked as Branch 15
and the live gate took the fresh-guest path instead, which is the scenario
this branch exists for:

- `dx-factory-reset --force`, `dx-create-keys`, `dx-create-image`,
  `dx-create-volumes`, `dx-create-container`, `dx-start-container`,
  `dx-wait-ssh`; `container list` showed 12288 MB.
- `DX_TEST_DESTRUCTIVE=1 … --section=17`: **99 passed, 0 failed, 0 skipped**.
  The real first `dx-ai` published a complete six-tool generation whose lock
  holds `nixpkgs-unstable` `d54020a6…`; only the six allow-listed trivial
  derivations were built locally, everything else came from the cache; no
  fallback or refusal; about 80 s wall time for the whole destructive run;
  memory sampled every ~20 s peaked at **~8.6 GiB of 12 GiB** (no OOM).
- Full live tier (`tests/run-tier.sh live`): **1298 passed, 0 failed,
  8 skipped**, including a second, idempotent `dx-ai` against the published
  generation (99/0/0 again).
- `dx-test` cold-stopped afterwards with its volumes and AI generation left
  in place for Branch 15's reproduction. `dx-host` and the NAS were never
  touched.

Dual-target stand-in (no QNAP guest yet): Section 27 99/0/0 and both Phase 0
dry-runs print their command lists; the x86_64 QNAP guest will use the same
channel branch and the same guard.

## Landing (2026-09-27)

Rebased onto `main` `cf9f35f` (Branch 7 had landed meanwhile); only
`tests/coverage/ratchet.env` overlapped. This branch's own files
(`container/`, `docs/guest.md`, Sections 6 and 17) are byte-identical before
and after the rebase, so the results above stand for the rebased commits.
Re-checked by the coordinating session on the rebased tip: bash-3.2 suite,
Sections 1, 10 and 27, both Phase 0 dry-runs, private identifier scan.
