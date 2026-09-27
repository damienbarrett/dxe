# Architecture-neutral guest (Branch 11 / Phase 4, `feat/qnap-arch-neutral`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 4 and
`checkout-consolidation-plan.md`'s Branch 11. No home-directory paths, keys,
fingerprints, daemon IDs, or NAS identifiers appear below; the pre-approved
placeholder alias `qnap-dxe` and the disposable names `dx-qnap-spike*` stand
in for the real host.

Branch `feat/qnap-arch-neutral`, from `main` `6688a7c`, rebased onto `756d269`
before landing (Branch 12 had landed meanwhile; two conflicts, both resolved
as unions — the Section 3 sourceable-function list and the ratchet history —
and every other file's delta identical before and after). Implemented by a
Sonnet subagent against Nix evaluation, fixtures and fakes only (10 commits,
plus the landing rebaseline and the two live-gate fixes below); designed, reviewed, live-gated and landed by
the coordinating session. Design: `docs/refactor/arch-neutral-guest.md`.

## User decisions (2026-09-27)

1. Phase 4 proceeds as a subagent task.
2. Only disposable names (`dx-qnap-spike*`) may exist on the NAS until Phase 7;
   the exit gate's guest is created and destroyed by the coordinating session.
3. The QNAP guest is **8 GB / 4 CPU** (`DX_CONTAINER_MEMORY=8G`,
   `DX_CONTAINER_CPUS=4` in the example profile; Apple keeps 12 GB).
4. The x86_64 closure is built **natively inside the disposable QNAP guest
   during its own bootstrap**, cache first; no cross-compilation, emulation
   or separate builder.

## What changed

- **Per-system flake outputs (item 1).** `flake.nix` evaluates for
  `supportedSystems = [ "aarch64-linux" "x86_64-linux" ]` through a local
  `forEachSystem` (`nixpkgs.lib.genAttrs`; no new input): `packages.<system>`
  and `devShells.<system>` for both, `homeConfigurations."dx-<system>"` per
  system with `homeConfigurations.dx` kept as the aarch64 alias. The bootstrap
  activates `homeConfigurations.dx-<system>` for the guest's own system.
- **Keyed architecture pins (items 2-3, DQ7).** `pins/agy.json` is a
  per-system map read by both `flake.nix` and `dx-ai.sh`; the Antigravity
  manifest URL is chosen per system. A read-only check of the upstream
  manifest location found a **real native x86_64 artifact** (`linux_amd64`,
  version 1.2.12; the arm64 pin is 1.0.5, each refreshed independently), so
  the x86_64 entry is real data. The `null` → "agy: no native artifact for
  <system>; skipping (DQ7)" path exists and is unit-tested; the coordinating
  session declined a production knob to fake it at the live gate.
- **The guest selects by its native system (item 1/3).** New sourceable
  `scripts/lib/dx-guest-system.sh` maps `uname -m` to a Nix system and refuses
  on disagreement with `DX_GUEST_SYSTEM` when the host provided it ("host
  profile says X, but this guest is Y") or on an unsupported architecture.
  `bin/dx-create-container` passes `DX_GUEST_SYSTEM` as a third env token for
  both runtimes — the one deliberate change to Apple's create argv;
  characterisation updated on purpose.
- **Availability and inventory (item 4).** A test evaluates every package in
  `dxPackages`, `bootstrapEssentials` and `aiPackages` for both systems
  (evaluation only), and `scripts/dx-verify-inventory.sh` prints
  present/missing for the required CLI inventory on either architecture (an
  explicit binary-name list, since attribute names differ from command names).
- **System in labels (item 5).** The docker-ssh adapter's shared label helper
  now applies `io.dxe.system=<DX_GUEST_SYSTEM>` to containers, volumes and
  the lock container (the lock's inline labels were refactored onto the
  shared helper), and `dx-status`'s docker-ssh listing shows it.
- **Not in this phase:** the context-directory rename (DQ7's standalone
  mechanical commit; still pending, recorded in the plan), remote-aware SSH
  (Phase 5).
- **Real bugs found by tests on the way** (each in its commit message): a
  negated-status bug in `bootstrap/activation.sh`; a `sed`-based
  `aiPackages` extractor in the refactor contracts blinded by a Nix list
  splice; two `jq`-availability gaps visible only in the deliberately
  `jq`-less coverage container; a `PATH="$dir" bash` lookup bug in a test;
  a missing-source gap in the sourceable coverage probes; two label-adjacency
  test regressions from the new label.

## Gates

| Gate | Result |
| --- | --- |
| Fast tier (`tests/run-tier.sh unit/static`, coordinating session, rebased tip) | 25 sections, 1,303 passed, 0 failed |
| bash-3.2 (subagent, every increment) | 99 passed, 0 failed |
| Pinned ShellCheck 0.10.0 and apt 0.9.0 (+ fast suite in `ubuntu:24.04`) | clean |
| G3 `nix flake check --no-build --no-write-lock-file --all-systems` (coordinating session, clean export of the rebased tip, throwaway `nixos/nix:2.34.8`) | all checks passed; `flake.lock` byte-identical to `main` |
| Coverage (`tests/run-coverage-linux.sh`, subagent, every increment and on the finished tree) | `covered=100%`; ratchet 2164 → 2134 on the branch, 2124 after the rebase (union with Branch 12's test growth), 2118 after the two live-gate fixes (their tests dilute; `dx-ai.sh` is outside the declared scope): 6,944 / 32,781 on a clean export |
| Private identifier scan | clean |

## Live gates, first attempt (2026-09-28): two real defects found

**Apple (`dx-test`), container-only recreate onto existing volumes:** the three
create-time env tokens were present (`DX_GUEST_SYSTEM=aarch64-linux`), the
guest resolved its own system and activated `homeConfigurations.dx-aarch64-linux`
in 9 s, the inventory verifier reported all 21 required tools present, and a
cold `dx-ai` pinned Antigravity for aarch64 from the per-system manifest with
every tool present and the keyring live. The full live tier then failed two
tests: Section 17's real-run "null-agy system publishes a generation without
agy" (the refresh had re-pinned agy for the null system), and Section 20's
truthfulness check as a consequence.

**NAS (disposable `dx-qnap-spike`, 8 GB / 4 CPU, direct `/nix`):** volumes,
image tag and container were created correctly (labels including
`io.dxe.system=x86_64-linux`, memory 8 GiB, 4 CPUs, restart `no`, three env
tokens, the three named volumes at `/guest-bootstrap`, `/nix`, `/persist`),
the bootstrap synced over exec and started natively — and the essentials
install failed 16 s in with a Nix profile file conflict over `bin/gunzip`.
Root cause, verified read-only on both runtimes: **Docker injects `HOME=/root`
into the container process at runtime; Apple's runtime leaves `HOME` unset.**
With `HOME` set, Nix resolves root's profile through `/root/.nix-profile`,
which in the upstream image points at the legacy `default` profile
(`manifest.nix`, already holding `gzip`, `gnutar`, `coreutils-full`, …), and
`nix profile install` of the essentials environment collides. With `HOME`
unset, Nix falls back to `/nix/var/nix/profiles/per-user/root/profile`, a fresh
`manifest.json` — which is where `dx-test`'s essentials actually live. The
Apple guest had been working by accident. Every disposable resource was
removed and verified gone before the fix.

**Fixes (same branch, red then green):**
- `install_essential_packages` names the target explicitly:
  `nix profile install --profile /nix/var/nix/profiles/per-user/root/profile …`
  — the profile `essentials_profile_store_path` already checks first, so
  Apple's outcome is byte-identical and the QNAP now matches it. Every other
  root-level `nix profile` call was audited (dx-ai already used `--profile`;
  the rest run as `dx` or manipulate the image-provenance links directly).
- `dx_ai_refresh_pin` returns before any network call when the current pin for
  the system is `null`, printing "agy: pin for <system> is null; refresh will
  not resurrect it (DQ7)". The Section 17 real-run test was un-stubbed so it
  exercises the real refresh path; it and a new direct unit test both fail on
  the unfixed code.

## Live gates, second attempt (2026-09-28, tip with both fixes)

**NAS — the Phase 4 exit gate proper, all disposable, all removed afterwards.**
Three labelled volumes (now also `io.dxe.system=x86_64-linux`), the digest-
pinned base re-tagged, and a container with memory 8 GiB, 4 CPUs, restart
`no`, the three env tokens, and the three named volumes at `/guest-bootstrap`,
`/nix` and `/persist`. The bootstrap synced over exec and ran natively for
x86_64: essentials installed into the explicit per-user root profile (the
first-attempt failure did not recur), the direct-volume in-place populate
wrote its image-identity marker, Home Manager activation completed in 129 s
(cache hits plus a handful of local builds), and "Guest bootstrap complete"
arrived about 150 s after start. The inventory verifier, run as the `dx`
user with a login shell through `docker exec`, reported all 21 required
tools present (a first run as root reported most missing — root's PATH does
not include `dx`'s Home Manager profile; a harness mistake, not a guest
defect, recorded so the gate is invoked correctly next time). `dx-reclaim`
under the QNAP profile reported the volumes through the new usage operation
(Nix volume 4.178 GB), ran the guest's garbage collection, and skipped the
trim as designed. Cleanup removed the container, the three volumes and the
image tag; no labelled resource remained and the lock was not held. Nothing
production-named was touched.

**Two more defects surfaced and were sent back for fixes before landing:**
- `dx-status` under docker-ssh died silently after its Image header once a
  real image existed: the adapter's image listing put `repository:tag` in the
  first column while `dx-status` greps for the bare name followed by
  whitespace (Apple lists name and tag as separate columns), so under
  `set -euo pipefail` the failed grep ended the script. Fix: separate
  repository and tag columns in the adapter, plus a docker-ssh `dx-status`
  characterisation case.
- The Apple live tier runs every section under the `dx-test` profile
  environment, which exports the whole resolved configuration
  (`DX_GUEST_SYSTEM=aarch64-linux`, `DX_CONTEXT_DIR`, …). Under that
  environment the Section 17 real-run "null-agy system" test still installed
  agy (it passes when run bare), and Section 20's truthfulness check failed
  as a consequence. Fix: isolate the fixture from inherited `DX_*`
  configuration, and ensure `dx-ai` cannot be steered by host-only variables.
  Everything else on the Apple side passed again (recreate, three env tokens,
  per-system activation, inventory 21/21, cold `dx-ai`, keyring live; 1,759
  of 1,761 live-tier checks).

## Live gates, third attempt (2026-09-28, rebased onto `main` `583e6bb` with all four fixes)

**NAS:** the disposable x86_64 guest bootstrapped natively in about 120 s;
the inventory verifier, run as `dx`, reported all 21 tools; `dx-status`'s
Image section now renders (fix 4) — and its Container section then failed
against real Docker: the adapter's `docker ps --format` used
`{{index .Labels "io.dxe.system"}}`, which is only valid for `inspect`, where
`.Labels` is a map; in `ps` and the `ls` commands it is a comma-separated
string and the correct form is `{{.Label "io.dxe.system"}}` (fix 5, below).
`dx-reclaim` reported the volumes (Nix 4.178 GB) and ran garbage collection
without a trim; cleanup left nothing labelled and the lock not held.

**Apple, passed in full:** recreate onto the existing volumes, three env
tokens, per-system activation, inventory 21/21, cold `dx-ai` with the aarch64
pin, keyring live, and the full live tier under the profile environment —
**35 sections, 1,777 passed, 0 failed, 12 skipped** — then a cold stop. The
fast tier on the same tip: 25 sections, 1,316 passed, 0 failed.

**Fix 5 (adapter only):** the container-list format uses `{{.Label "…"}}`, and
every other `--format` string in the Docker adapter was audited and validated
once against a real Docker CLI, because the fake `docker` in the tests cannot
catch Go-template errors — the lesson of fixes 4 and 5, recorded in the
mapping doc.

## Live gate, fourth attempt (2026-09-28, final tip): the NAS exit gate passes in full

Disposable x86_64 guest again (labels, 8 GiB / 4 CPUs, three env tokens,
direct `/nix`): native bootstrap complete about 120 s after start; inventory
all 21 present as `dx`; **`dx-status` now renders every section under the
QNAP profile** — the image row, the container row with its
`x86_64-linux` system column, bootstrap generation running equal to
published, the guest tools through exec, the hardening branch's
`keyring: not running` line (correct: no `dx-ai` has run in this guest),
and the remote lock not held (its SSH line still probes the controller's
loopback, the Phase 5 item already on record); `dx-reclaim` reported the
volumes and ran garbage collection without a trim; cleanup left nothing
labelled. The recreate-preserves check that Phase 3 moved to this gate was
run separately on the same disposable names and is recorded next.

## The recreate-preserves check (Phase 3's exit-gate item, run under this gate)

On the same disposable names: fresh guest bootstrapped in ~120 s, a marker
written under `/persist/home/dx`, the container destroyed alone (all three
volumes confirmed kept), then created and started again onto the same
volumes. **The second bootstrap refused** with "this volume's Nix-store
content no longer matches its own recorded identity" — a false corruption
verdict on a healthy, unchanged volume (finding 6). Cause: the direct-volume
in-place populate reused `nix_image_store_import_required`, whose identity is
a hash of `nix path-info --all` over the store mounted at `/nix`; in
apple-image mode that runs before the remount against the pristine image
store, but in direct-volume mode `/nix` is the live volume, which legitimately
changes on every boot that touches Nix, so every reboot of a used QNAP guest
would have been refused. Apple is unaffected. Fix 6 (below) makes the
host-provided image identity the only image-change signal in direct-volume
mode and checks corruption by verifying the bootstrap roots' content
directly; the re-run of this check is recorded after it.


**Fixes 6 and 7 (same branch, red then green):** in direct-volume mode the
in-place populate no longer calls the whole-store identity hash at all; the
host-provided image identity is the only image-change signal, first boot is
"the image-identity marker is absent", and on a reused volume the bootstrap
roots are verified by content (`nix store verify --no-trust` over the bounded
root set) with an empty root set failing closed. GC roots are keyed by the
image identity's bare digest (fix 7: the first version passed the
`sha256:`-prefixed token into a 64-hex validator and refused the first boot of
a fresh guest; the fixtures had mocked the publisher, so they now run the real
one). Roots therefore publish once per image rather than once per boot.

**Recreate check, passed (third run):** fresh guest bootstrapped in ~120 s and
published its GC roots; a marker was written under `/persist/home/dx`; the
container was destroyed alone (all three volumes confirmed kept) and created
and started again onto them. The second bootstrap took about 15 s: "Nix
volume image import completed in 0s", Home Manager activation 1 s, the
persisted SSH host identity restored; the marker read back identical, the
image-identity marker kept its original timestamp, no store-identity marker
exists in direct-volume mode by design, all 21 tools present, the bootstrap
generation running equal to published, and `dx-status` showed the container
with its `x86_64-linux` column. Cleanup left nothing labelled.

## Landing (2026-09-28)

Rebased twice during the gates (onto `756d269` after Branch 12, then onto
`583e6bb` after the hardening branch), each time with only the ratchet
history and one appended-test-block conflict, every other file's delta
identical before and after. Final ratchet 6,981 / 33,442 → re-measured on the
finished tree at 2088 bp (the fixes added more in-scope lines than tests);
`covered=100%` confirmed in isolation. Private identifier scan clean. Seven
real defects were found by the live gates and fixed before landing; the
lesson recorded in the plan is that the fake boundaries cannot see Docker's
Go-template semantics or the runtime's environment differences, so every
QNAP-facing change gets one real pass on the NAS before it lands.
