# Plan: land the remaining `fix/dx-bootstrap-sigbus-volume-store` work on main

## Why this is a re-implementation, not a merge

`fix/dx-bootstrap-sigbus-volume-store` carries one commit, `a428c55` ("Repair
the bootstrap toolchain and persist host keys to fix ssh-keygen SIGBUS"). It
branched from `884ab51`, 66 commits behind current `main`, and it edits
`container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh` — a
release directory that no longer exists. `main` is on 26.05 and that monolith
has since been split into `bootstrap/{common,base-and-storage,system,
persistence,herdr-config,activation}.sh`.

`git merge-tree main fix/dx-bootstrap-sigbus-volume-store` confirms the outcome:

```
CONFLICT (modify/delete): container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh
    deleted in main and modified in fix/dx-bootstrap-sigbus-volume-store
CONFLICT (content): tests/test_section3_bootstrap.sh
CONFLICT (content): tests/test_section4_ssh.sh
```

Resolving that merge would resurrect a dead 25.11 release path. The content is
what matters, and `refactor-v2-final.md` (P3) already directs it to be folded
into the store-import work rather than merged.

## What is already on main

`3adeecd` ("Make guest bootstrap ownership and store import bounded and
recoverable"), merged as part of the 23-commit fast-forward, already
re-implements three of the commit's four fixes — and improves on them:

| `a428c55` fix | Status on `main` | Location |
| --- | --- | --- |
| 1. `essentials_store_valid` fast closure check | **Landed, stronger** — drops `--no-contents`, so it content-verifies rather than trusting a registered-but-truncated binary | `bootstrap/common.sh:83` |
| 2. `repair_store_closure` + `ensure_essentials_valid` after the remount | **Landed**, called in `bootstrap_main` before `create_user`/`configure_ssh` | `common.sh:89,95`; `bootstrap.sh:20` |
| 3. Self-healing `generate_host_keys` (no bare fatal `ssh-keygen -A`) | **Landed** | `common.sh:126`, called at `system.sh:246` |
| 4. Host keys persisted under `/persist/etc/ssh` | **Missing** — no match for `persist/etc/ssh` anywhere in the tree | — |

So the delta to land is fix (4) only.

## The gap

`configure_ssh` (`bootstrap/system.sh:245-247`) is:

```bash
mkdir -p /etc/ssh
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    generate_host_keys
fi
```

`/etc/ssh` is on the ephemeral rootfs. Two consequences:

- The guest's host identity is regenerated on every rebuild. Note this is
  *not* visible through `bin/dx-ssh`, which sets `StrictHostKeyChecking=no` and
  `UserKnownHostsFile=/dev/null` (`bin/lib/dx-ssh-common.sh:18-19`); it
  surfaces on a direct `ssh` to the forwarded port.
- `generate_host_keys` is self-healing *within* a boot, but nothing carries a
  good key across boots, so a persistent openssh-closure problem re-runs keygen
  every single boot instead of restoring a key that already worked.

## Design

One deviation from `a428c55`, forced by a real difference in the tree:
`setup_persist` does `chown dx:dx "$persist_root"; chmod 0755` — **`/persist`
is dx-owned and dx-writable**. `a428c55` simply did `mkdir -p /persist/etc/ssh;
chmod 700`, which leaves host *private* keys where the unprivileged guest user
can rename the directory out of the way and substitute its own. Storing keys
there is still right; trusting them unconditionally is not.

Add to `bootstrap/system.sh`:

1. `dx_host_key_store_trusted <store>` — the store is trusted only when it is
   a real directory (not a symlink) owned by uid 0. Uses the established
   portable idiom `stat -c '%u:%g' … || stat -f '%u:%g' … || true`. An
   untrusted store is refused with a diagnostic, never restored from.
2. `dx_persist_host_keys <etc_ssh> <persist_store>` — parameterized on both
   roots so it is testable against a fixture, matching `setup_persist`'s
   signature style:
   - refuse a symlinked `/etc/ssh` or a symlinked store before any mutation
     (the F5/R1 pattern used throughout `persistence.sh`);
   - create the store `root:root 0700` via `install -d -o root -g root -m 0700`;
   - if the store is trusted and holds `ssh_host_*_key`, restore with `cp -a`;
   - otherwise call the existing self-healing `generate_host_keys`;
   - re-assert modes after restore (private `0600`, `.pub` `0644`) so a
     bad-moded persisted copy cannot make sshd refuse to start;
   - backfill the store from `/etc/ssh` whenever the store holds no keys.
3. `configure_ssh` calls `dx_persist_host_keys /etc/ssh /persist/etc/ssh` in
   place of the current `mkdir`/`if`/`generate_host_keys` block.

Ordering already works: `bootstrap_main` runs `setup_persist` before
`configure_ssh`, so `/persist` exists and is prepared.

## TDD steps (red → green → refactor)

Per `constitution.md`: behavior tests, 100% coverage over the declared scope.

1. **Red** — add behavior tests to `tests/test_section3_bootstrap.sh` (it
   sources every module, runs fixture-based behavior tests, and is in the
   `unit/static` tier; `test_section4_ssh.sh` is *not* in that tier). Cases:
   - a fresh persist store generates keys and backfills the store;
   - a populated, root-owned store is restored to `/etc/ssh` without calling
     `generate_host_keys`;
   - a store owned by a non-root uid is refused and keys are regenerated;
   - a symlinked store and a symlinked `/etc/ssh` are refused before mutation;
   - restored private keys end up mode `0600`.
   Stubs follow the existing style, and per the recorded privilege-stub lesson
   `chown` is a **recording** stub (appending to a log that the assertion
   reads), never a no-op — a no-op `chown` is exactly what has hidden
   root-vs-dx bugs here before.
2. Add the new function names to the sourceability contract list at
   `tests/test_section3_bootstrap.sh:25`.
3. **Green** — implement the three items above in `bootstrap/system.sh`.
4. Update `tests/test_section4_ssh.sh`'s static assertions to reference the
   persisted store.
5. **Coverage** — add root-privileged probes to
   `tests/test_sourceable_coverage.sh` (isolated Linux kcov runner) for the
   branches the macOS fixture cannot reach with real ownership.

## Validation

- `tests/run-tier.sh unit/static` — full pass, no failures.
- `shellcheck` clean on the modified modules (section 0 lint).
- `tests/run-coverage-linux.sh` for the 100% scope gate. If the ratchet dips
  purely because added test lines dilute `total_lines`, rebaseline
  `tests/coverage/ratchet.env` with the reason, per the convention recorded in
  that file. A genuine regression — production logic leaving the scope — is not
  acceptable.
- Live `dx-recreate` is the real proof (restore-from-persist across a rebuild).
  Note the recorded lesson that `dx-recreate` starts before syncing, so the
  first start after a bootstrap change runs the *previous* generation; check the
  generation id before drawing conclusions.

## Branch disposition

Once this lands, `fix/dx-bootstrap-sigbus-volume-store` is fully superseded:
fixes 1–3 by `3adeecd`, fix 4 by this work. Delete it locally and on origin
after the commit, and note in the commit message that it supersedes `a428c55`.

## Status: complete

Landed on `main`. `dx_host_key_store_trusted`, `dx_host_key_store_populated`,
`dx_harden_host_keys`, and `dx_persist_host_keys` are in `bootstrap/system.sh`,
and `configure_ssh` now calls `dx_persist_host_keys /etc/ssh /persist/etc/ssh`.

The root-privileged probe earned its place. The first implementation ran
`install -d -o root -g root -m 0700` on the store *before* checking trust, and
GNU `install -d` applies ownership to an already-existing directory — so a
store dx had substituted would have been chowned back to root and then trusted,
laundering a dx-planted key into the guest's host identity. The macOS fixture
could not see it (its `install` is stubbed); the real-ownership probe in the
isolated runner failed immediately. The store is now created only when absent,
and never chowned into trust.

Validation: `unit/static` 735 passed / 0 failed; section 0 lint clean
(shellcheck itself is not installed locally and is skipped there, it runs in
the coverage image); `tests/run-coverage-linux.sh` reports `covered=100%
scope_share=22.78%` against a 2256 bp baseline. Live `dx-recreate` proof of
restore-across-rebuild is still outstanding and is the one thing this change
has not been exercised against on real hardware.
