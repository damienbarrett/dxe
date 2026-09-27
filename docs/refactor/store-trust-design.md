# Design comparison: verifying the persistent store before trusting it

Branch `fix/store-trust` (Branch 12), Step 0 — characterisation and design
comparison only, written before any production code exists (the same
discipline `docker-adapter-mapping.md` and `direct-volume-storage.md` used
for their own Increment 0 notes). Answers `store-trust-plan.md` Problems 1
and 2's "Definition of done" bullet "one design selected... with the
rejected alternatives and reasons recorded" — the selection itself is the
coordinating session's, not this document's; this document exists to make
that selection informed. No mechanism is implemented here.

Scope note: this branch touches only `container/.../bootstrap/`,
`bin/lib/`, `flake.nix`, `tests/`, and the docs the task names. Nothing here
proposes a change outside that set; every "designs" reaches its comparison
armed only with what already exists in the tree (`nix copy`, `nix store
verify`, the existing marker/atomic-publish helpers, the existing
`bootstrapEssentials` mechanism).

## 1. Problem 1 — volume-reusing image-pin bump

### 1.1 Characterisation: reproducing the observed collision

`docs/release-maintenance.md` records one real incident (2026-08-30,
bumping the isolated `dx-test` profile from `nixos/nix:2.34.7` to `2.34.8`
with `/nix` retained):

```
copying path '/nix/store/dy9skynmbyj7yc7dnn7qcgrfpwiy2yh6-base-system' to 'local://'...
error: hash mismatch importing path '/nix/store/dy9skynmbyj7yc7dnn7qcgrfpwiy2yh6-base-system';
         specified: sha256:0n8y708xzz6w5wfmjj9lfazp63f5rpkhwaz90hcvcnvlrl8n20v1
         got:       sha256:0nwfi38jwvazkb5mwvkg1i711v5j3g27z0p7p0m079kqhslmw5c1
```

Reproducing the exact two image tags would need network pulls of two real
`nixos/nix` releases and is not needed to characterise the *mechanism* — the
task explicitly allows "a fixture or the Section 25 runner." This turn used
a fixture built from **real Nix** (`nix`, `nix-store`) in a throwaway
`dxe-scratch-branch12storetrust-<pid>` container
(`docker.io/nixos/nix:2.34.8`, removed after use; dx-host/dx-test untouched
throughout — confirmed by `container list -a` before and after), exercising
the exact primitive DXE's own `nix_store_import_registered` uses:

```
nix --extra-experimental-features 'nix-command flakes read-only-local-store' \
    copy --from '<store-uri>' --to '<store-uri>' --stdin --no-check-sigs
```

against store URIs of the same shape `nix_target_store_uri` already
constructs (`local?store=/nix/store&real=<dir>/store&state=<dir>/var/nix&log=<dir>/var/log/nix`).
`nix-store --dump-db` / `--load-db` (Nix's own whole-database text
export/import pair) built two independent, real store instances sharing one
store-path *name* with different registered content, deliberately and
transparently, rather than guessing at two coincidentally-colliding real
package builds.

**Two distinct collision shapes were found, with different observable
behaviour:**

**Shape A — a store whose own database disagrees with its own on-disk
bytes** (e.g. an image whose build/publish pipeline baked a stale NAR hash
alongside genuinely different shipped bytes). Copying that path from that
store, to anywhere, reproduces the *exact* observed error text and shape:

```
copying 1 paths...
copying path '/nix/store/gfhshzjbxfdmya6xcv65331nk6jrraha-collide-demo2' to 'local://'...
error: hash mismatch importing path '/nix/store/gfhshzjbxfdmya6xcv65331nk6jrraha-collide-demo2';
         specified: sha256:1fxvpfxvpfxvpfxvpfxvpfxvpfxvpfxvpfxvpfxvpfxvpfxvpfxv
         got:       sha256:0ys52fl3np4s5z4pc0iv87f3axhd8n5mzq21w2svvcnblxaj4wcm
```

Verified: the destination gets **no valid database entry** afterwards
(`nix-store -q --hash` on it reports `path ... is not valid`) — but the
failed transfer **does** leave an orphaned, writable (not
read-only-finalised, unlike a genuinely completed Nix store object),
unregistered directory physically present under the destination's `store`
dir. Nothing mismatched is ever registered or resolvable as valid; the
leftover is inert clutter, not a trusted object, and is safe to remove or
overwrite on retry.

**Shape B — the destination already validly holds different, but
internally self-consistent, content under the same name** (the literal
scenario `docs/release-maintenance.md`'s own prose describes: "the volume
holds the old one, registered"). Reproduced with both sides genuinely
self-consistent (registered hash matches on-disk bytes on each side):

```
copying 0 paths...
```

Exit 0. **No error, no warning.** The destination's old content is silently
retained; the new source's differing content for that name is never even
read. This is a materially different mechanism from Shape A and does **not**
reproduce an error at all.

**This is a real, previously-undocumented finding for this task:** today's
"safety" for Problem 1 is not a single deliberate check — it is whichever of
two structurally different Nix behaviours a given collision happens to hit.
Shape A fails loudly (safely, but with a message a boot operator has to
research). Shape B fails silently, retaining stale content under a name the
new image's *other* still-to-be-copied paths may assume has the new
content — a real (if narrow) risk to the "no mismatched content may be
executed" property that today's protocol does not detect, let alone refuse.
Neither shape is quarantine (nothing is skipped-and-continued); Shape B is
closer to "silently ignored" than "quarantined."

### 1.2 The four required safety properties, evaluated against *today*

| Property | Shape A (source self-inconsistency) | Shape B (destination already valid, different content) |
| --- | --- | --- |
| No mismatched content executed | Holds — nothing is registered | **At risk** — old content is retained and could be executed under a name the new closure's other members now assume differs |
| Failure pre-remount and recoverable | Holds (this call site is pre-remount in both apple-image branches) | N/A — there is no failure to recover from; nothing is flagged |
| Existing volumes not silently mutated into an ambiguous state | Holds (DB stays unambiguous; the orphaned directory is inert) | Arguably **violated in spirit** — the volume now silently mixes old-image content under new-image-closure assumptions, with no record that this happened |
| Fresh-volume path remains valid | Holds (this code path is never reached for a genuinely empty volume) | Holds (same reasoning) |

### 1.3 Designs compared (at least two, per the task; three are compared)

All three operate at the same call site: `populate_prepared_nix_volume`'s
existing `elif nix_image_store_import_required /nix "$volume_root"` branch
(apple-image mode only — direct-volume mode's analogous branch already has
its own image-identity-marker mechanism, see §1.5), before
`nix_store_import_registered` performs the real transfer.

**Design P1-A — Formalise today's incidental refusal into a deliberate,
uniform pre-import collision check (recommended).** Before calling `nix
copy` for real, walk the same bounded root set
`nix_image_bootstrap_store_paths` already enumerates (the pattern
`nix_image_store_import_required`'s own `nix store verify` call already
uses) and, for each root path already present on the volume, compare its
recorded hash against the image's own registered hash for that name (a pair
of `nix-store -q --hash`-style queries against the two stores, no transfer
attempted yet). If any root-set path would collide, refuse deterministically
— naming the offending path(s) and pointing at the destroy-and-rebuild
procedure — before any `nix copy` is attempted. This catches **both**
collision shapes above uniformly (Shape B is no longer silently skipped: the
pre-check catches it exactly as it would Shape A), replacing today's
shape-dependent, sometimes-silent behaviour with one deliberate, tested,
documented outcome.

**Design P1-B — Essential-set-aware quarantine (rejected).** Split colliding
paths into "bootstrap-essential" (`nix_image_bootstrap_store_paths`
membership — must refuse, as in P1-A) and "other" (rename the old
conflicting content aside, unregister it, and import the new content under
that name, so a bump colliding only on non-essential paths can still
succeed). Rejected: `store-trust-plan.md`'s own "Not collision quarantine"
section already warns this "may violate the very content identity the guest
is meant to trust," and this fixture work sharpens why — a quarantined path
does not just disappear tidily, it requires *correctly unregistering* the
old entry from Nix's database (a real content-addressed store's validity
table, not just a filesystem rename) with its own new failure modes, for a
volume state that is *more* ambiguous than today's, not less. It also does
not even help the one collision actually observed on 2026-08-30
(`base-system`, plausibly bootstrap-essential, so still refused under this
design) — higher risk and complexity for no demonstrated benefit on the
incident that opened this problem.

**Design P1-C — Full closure staged into an isolated area before any live
merge (rejected).** Copy the entire incoming closure into fresh, disposable
staging first (so no collision is possible while staging), verify
completely there, then merge as a single atomic step that still refuses on
essential-set collisions. Strongest isolation of the three in principle, but
collapses into either P1-A's safety profile (if the final merge step also
refuses on any collision) or P1-B's risk profile (if it also quarantines
non-essential paths) — for materially higher cost either way: full-closure
disk staging (not the bounded root set) and a new atomic bulk-merge
primitive with its own test surface. Dominated by one of the other two
options; not worth its added engineering cost.

| | P1-A (recommended) | P1-B (rejected) | P1-C (rejected) |
| --- | --- | --- | --- |
| No mismatched content executed | Yes | At risk (deliberately relaxed for non-essential paths) | Yes, if it also refuses; otherwise = P1-B |
| Pre-remount, recoverable | Yes | Yes | Yes |
| No silent ambiguous mutation | Yes (closes Shape B too) | No — mixed old/new state by design | Yes, if it also refuses; otherwise = P1-B |
| Fresh-volume path unaffected | Yes | Yes | Yes |
| Cost | Low — reuses the existing bounded root-set check | Medium-high — new DB-unregistration primitive | Highest — full closure staging + new atomic merge |
| Solves the actual 2026-08-30 incident | Refuses it deliberately (does not make it succeed) | No (base-system is plausibly essential) | Same as whichever of A/B it collapses to |

### 1.4 Open judgement call, flagged for the coordinating session

Design P1-A does **not** make a colliding volume-reusing bump *succeed* — it
makes the refusal deliberate, uniform across both collision shapes, and
well-diagnosed, replacing "no valid procedure" text with an actual
documented, tested one (a real procedure whose outcome is "detect
deterministically, refuse, and point at the existing destroy-and-rebuild
path" — still a real procedure, just not a volume-preserving one when a
collision is genuinely present). Whether that satisfies Problem 1's
Definition of Done ("a behavioral test that the chosen design resolves it
without executing mismatched content") depends on which of two readings is
intended:

- **Reading 1 (recommended):** "resolves it" = handles the collision
  deterministically, safely, and diagnosably, closing the undocumented Shape
  B gap. P1-A satisfies this fully, at low cost, consistent with Q6's
  fail-fast posture.
- **Reading 2:** "resolves it" = a volume-reusing bump must be able to
  *succeed* even when a collision is present. Only P1-B/P1-C attempt this,
  both explicitly warned against by the plan itself and both failing to
  help the one incident actually on record.

This document recommends Reading 1 and Design P1-A. The choice between
readings is exactly the kind of decision the standing brief says is not a
subagent's to make; it is recorded here for the coordinating session.

### 1.5 Direct-volume mode

Direct-volume mode (`docs/refactor/direct-volume-storage.md` §5) already has
its own, different, already-landed (on `feat/qnap-direct-storage`, not yet
merged) answer to "the image changed under a reused volume":
`DX_IMAGE_IDENTITY`, a host-provided runtime image identity compared against
a volume-local marker, refusing on any mismatch before
`nix_image_store_import_required` is even consulted. That mechanism detects
"a different image entirely," which is a **superset** trigger of "the same
image-version pair happens to collide on one store-path name" — a
direct-volume bump across genuinely different images is already refused
long before reaching a path-level collision at all. Design P1-A's bounded
root-set collision check is additive and apple-image-specific (there is no
separate pre-remount `/nix` to compare against in direct-volume mode — see
§2.5 below for the same point in Problem 2's terms); it needs no
direct-volume counterpart because direct-volume mode's existing marker
already fails closed earlier and by a different, already-designed route.
Nothing here proposes changing that mechanism.

## 2. Problem 2 — recovery blind spot for the post-remount trust root

### 2.1 Characterisation: the reproducer

Per the test contract, "the reproducer removes a prerequisite between
remount and verification" (source-shape assertions are not enough). A
sourceable fixture (Section-3-style: real, unmodified
`bootstrap/common.sh` + `bootstrap/base-and-storage.sh` from this worktree,
shell-function fakes, `/bin/bash`, stdin from `/dev/null`) built the exact
state `bootstrap_main` is in immediately after the remount:
`DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET` already resolved and pointing at a
**fully present and valid** target (`bin/sh`, `bin/nix`,
`etc/ssl/certs/ca-bundle.crt` all present and executable/readable) — i.e.
nothing is actually missing on the volume; only the *tool* used to trust it
is broken, modelling "the corrupted path IS one of its own prerequisites"
exactly as the plan states it.

**`readlink` broken** (one of the plan's own named tools:
readlink/mkdir/mktemp/rm/ln/chown/mv), simulating that tool's own store
closure member being corrupt or missing right after the remount:

```
Error: retained image default profile target is unavailable after the /nix remount.
exit=1
```

This is a **misdiagnosis**: the fixture proves the target is fully present
and valid. The true cause — a broken `readlink` — is never named anywhere.

**`chown` broken** (same class, different named tool):

```
exit=1
```

with **no `Error:` line printed at all** — a completely silent failure. The
guarded chain `if ! ln ... || ! chown ... || ! mv ...; then rm -f
"$temporary"; return 1; fi` has no `echo` on this branch at all, unlike
every one of this function's other error paths.

**Ordering evidence** (`bootstrap.sh`, unmodified, lines 18-19):

```
    nix_restore_image_default_profile
    ensure_essentials_valid
```

In both broken-tool cases, `nix_restore_image_default_profile` already
returned 1 before `ensure_essentials_valid` — the only verifier that exists
anywhere in this boot — is ever reached. Under `bootstrap.sh`'s
`set -euo pipefail`, `bootstrap_main` aborts right here, silently or
misleadingly, with no independent check of `readlink` (or any of the other
named tools) anywhere in this window today. This is RED, for the intended
reason (a corrupted own-prerequisite, not a source-shape mismatch), against
the worktree's current, unmodified tip.

**Contrast case**, to isolate exactly what is and is not already handled:
breaking `run_as_dx` (standing in for a broken `nix`) so that
`ensure_essentials_valid`'s **own** designed target — the bootstrap
essentials closure — fails, produces a properly designed, actionable
message:

```
Bootstrap essentials closure is incomplete after the /nix volume remount; repairing it...
Error: could not repair the bootstrap essentials closure.
Bootstrap phase: essentials verification/repair failed after 0s.
```

`ensure_essentials_valid` already does exactly what a verifier should when
*its own* target is corrupt. The gap is specifically the **earlier** steps'
own tool prerequisites (`nix_restore_image_default_profile`'s `readlink`,
`mkdir`, `mktemp`, `rm`, `ln`, `chown`, `mv`), which nothing checks
independently before they are used, and which — if broken — prevent
`ensure_essentials_valid` from ever running at all.

### 2.2 Designs compared against every row of the outcome table

**Design 2-1 — Pre-remount verification of the target store using
image-resident tooling.** While `/nix` is still the image's own known-good
ephemeral mount (apple-image mode only — see §2.5), and before the volume is
swapped onto `/nix`, use the image's own (trusted, not-yet-superseded) tools
to verify the staged volume's copies of the small prerequisite set (the same
named tools: readlink, mkdir, mktemp, rm, ln, chown, mv, plus `nix` itself)
before ever swapping. Repair from the image's own copies if broken
(available for free — the image is still mounted), or refuse before the
swap if repair fails.

**Design 2-2 — An absolute captured image toolchain used as the verifier.**
Bake a self-contained, statically-linked copy of the verifier toolchain into
the container image at a location that never resolves through `/nix/store`
at all (so it survives the remount regardless of what happens to `/nix`),
usable both before and after the remount, in both apple-image and
direct-volume mode alike. The plan's own caution is directly relevant here:
"a separately declared Nix output is declarative, but it is not
automatically an independent trust root if its interpreter or libraries
still resolve through the remounted `/nix/store`. Prove independence
behaviorally." A Nix-built, `bootstrapEssentials`-declared binary does
**not** qualify — it still resolves through `/nix/store` like everything
else the closure ships. Genuine independence needs delivery **outside** the
flake's normal packaging (a `Containerfile`-level addition, e.g. a static
binary placed under a non-`/nix` path at image-build time), which is a
materially different, larger kind of change than anything else this branch
otherwise touches.

**Design 2-3 — Deliberate fail-fast when independent repair is impossible
(recommended).** Immediately after the remount, before
`nix_restore_image_default_profile` does anything, run one minimal, bounded,
explicit presence/executability check over exactly the named tool list
(`command -v` plus a trivial invocation — no content-hash verification
needed for this check's purpose) and fail immediately, naming the specific
broken tool and pointing at the destroy-and-rebuild recovery, if any of them
are unusable. No independent repair is attempted for this class; this
directly implements Q6's already-accepted posture ("fail fast... with a
tested recovery procedure, for example rebuilding the `/nix` volume from
scratch").

| Outcome-table row | Design 2-1 | Design 2-2 | Design 2-3 (recommended) |
| --- | --- | --- | --- |
| Healthy reused volume: boot succeeds, no churn/marker rewrite | Yes (cheap targeted check) | Yes | Yes (cheapest — presence-only, no hashing) |
| Missing/corrupt pre-verifier core utility: independently repair-and-continue, or fail before trusting it, actionably | Repairs from the still-mounted image (free, apple-image only) | Repairs/verifies from the captured toolchain (works in both modes) | Fails deterministically, actionably (satisfies the "or fail" branch; never repairs) |
| Missing/corrupt Nix: repair-and-continue, or fail deterministically before marker publication | Same as above, pre-swap | Same as above, needs a captured `nix` too | Fails before marker publication (marker is published much later, unaffected) |
| Corrupt later closure member: existing bounded verify/repair remains effective | Unaffected — `ensure_essentials_valid` unchanged | Unaffected | Unaffected |
| Offline repair: bounded success from retained image material, or bounded fail-fast, never unbounded network wait | Naturally bounded — the image is *right there*, already mounted, at exactly this point | Bounded, if the captured payload also carries repair *material*, not just verifier binaries (a bigger payload) | Trivially bounded — always immediate fail-fast, no waiting, by construction |
| Failed/interrupted recovery: no success marker, unambiguous state, documented retry/reset works | Yes — pre-swap, so a retry is just re-running bootstrap | Yes | Yes — nothing is mutated by a presence check; retry/reset = rebuild the volume (already documented, already precedented by Problem 1) |
| Implementation cost / fit with stated constraints | Low-medium: reuses the existing pre-remount window, no new delivery mechanism | High: a whole new, independently-patched, non-Nix-packaged toolchain, outside "declare it in `bootstrapEssentials`" | Lowest: no new trust root, no new window dependency, uniform across both runtime modes |
| Works in direct-volume mode at all | **No** — no pre-remount window exists there (§2.5) | Yes (its whole point is not depending on remount timing) | Yes — identical in both modes, since it has no dependency on remount timing either |

### 2.3 Recommendation and rejected alternatives

**Recommended: Design 2-3.** It is the smallest change, matches Q6's already
-decided posture exactly, needs no new independent-trust-root delivery
mechanism, and — uniquely among the three — means literally the same thing
in both apple-image and direct-volume mode, because it never depends on a
pre-remount window existing at all. It turns today's two observed failure
modes (misdiagnosis, or total silence) into one deliberate, actionable,
tested failure, without attempting to promise more self-healing than Q6
asked for.

**Design 2-1 rejected as the primary mechanism, but a reasonable future
complement, apple-image only.** It is a stronger property (repair-and-
continue, not just fail-fast) and costs relatively little given the
pre-remount window and the already-mounted image are free resources at that
point — but it structurally cannot apply to direct-volume mode at all (see
§2.5), so it cannot be *the* answer to Problem 2 for both runtimes, only an
optional enhancement layered on top of 2-3 later, apple-image only, if the
coordinating session wants self-healing for this class beyond what Q6
requires.

**Design 2-2 rejected.** Genuine independence requires stepping outside the
flake's normal packaging and the plan's own stated preference ("resolve
through the checked-in flake," "declare it in `bootstrapEssentials`") into a
`Containerfile`-level, non-Nix-tracked artifact with its own separate
security-patch lifecycle — a substantially larger and more invasive change
than Q6's accepted fail-fast bar requires, for a repair-and-continue
capability this task's own resolved Q6 does not ask for.

### 2.4 What Design 2-3 does *not* do (explicitly out of scope for this
recommendation)

It does not attempt to independently verify or repair `nix` itself, shell
utilities, or `run_as_dx`'s own boundary beyond a presence/executability
probe; deep content-level self-healing for these specific early prerequisites
is exactly the capability Design 2-1/2-2 would add and this recommendation
defers. `ensure_essentials_valid`'s existing content-level verify-and-repair
behaviour for the bootstrap-essentials closure itself is untouched either
way.

### 2.5 Direct-volume mode

`docs/refactor/direct-volume-storage.md` §6 already states this precisely:
apple-image mode has a genuine pre-remount window (`/nix` starts as the
image's own ephemeral mount; several early steps run against known-good
image content before the volume is ever swapped in). **Direct-volume mode
has no such window at all** — `/nix` is the Docker volume from the
container's very first instruction, so there is no point at which any early
binary resolves against anything other than whatever is already on that
(possibly reused, possibly stale) volume. Every check this task might add is
itself executed by tools drawn from the exact store being checked.

For Problem 2, this means: **Design 2-3 (fail-fast) is the only one of the
three that means the same thing in direct-volume mode as in apple-image
mode**, because it has no dependency on a pre-remount window's existence —
it is just as valid (and just as necessary) as a presence check run at the
earliest point direct-volume mode's own bootstrap touches these tools, which
per `docs/refactor/direct-volume-storage.md` is essentially from
`populate_prepared_nix_volume_in_place` onward. Design 2-1 has no
direct-volume counterpart at all (there is no separate trusted store to
verify from) and is **explicitly not proposed for direct-volume mode**;
Design 2-2 would need its captured toolchain regardless of mode, which is
part of why it costs more. This document's answer to the task's requirement
("your designs must state what they mean for that mode, even if the answer
is 'fail closed, as it already does'") is: **fail closed, via Design 2-3,
identically in both modes** — not a new answer for direct-volume, the same
answer, because Design 2-3 was never mode-specific to begin with.

## 3. Shared-verifier question

**Does one mechanism serve both problems? No, not under the recommended
designs.** Problem 1's recommended design (P1-A) needs genuine
**content-hash** comparison (nix-native `nix store verify` / hash-of-registered
-paths idioms) — it is answering "is this incoming content safe to merge."
Problem 2's recommended design (2-3) needs only a **presence/executability**
probe — it is answering "can I trust the tools I am about to use at all,"
which content-hash verification does not need to answer for this recommendation's
scope (a broken exec, not a subtly-wrong-but-present binary, is the failure
class Design 2-3 targets; that is exactly what a presence/executability
probe catches, and exactly what Q6's fail-fast bar asks for). They also fire
at different call sites (Problem 1: inside the pre-remount import branch of
`populate_prepared_nix_volume`; Problem 2: immediately after the remount,
before `nix_restore_image_default_profile`) and answer structurally
different questions. Building one shared function for both would force one
of the two into a shape it does not need (either a heavyweight hash check
for Problem 2's cheap presence probe, or a lightweight presence probe
standing in for Problem 1's genuinely content-sensitive collision check).

**Conditional note:** if the coordinating session instead prefers Design 2-1
for Problem 2 (apple-image only, as a complement layered on top of 2-3),
*that* design does use the same underlying idiom as P1-A (`nix store verify
--no-trust` over a bounded root set, pre-remount) — at that point there is a
shared **idiom**, not a shared **function or call site** (the two still run
at different points for different reasons, over different root-set
definitions). This document's actual recommendation (P1-A + Design 2-3) has
no such overlap at all.

## 4. One branch or two?

**Recommendation: keep one branch (`fix/store-trust`, already created).**
The task allows either, conditioned on whether the problems "share code": as
established in §3, the recommended designs do not share a verifier or call
site, so there is no shared piece that would need to land first to justify
splitting. Against that, the two changes:

- touch the same two files (`bootstrap/common.sh`, `bootstrap/base-and-storage.sh`)
  in the same narrow region of `bootstrap_main`'s pre-sshd path;
- share the same test layers end to end (Section 3 fixtures, Section 25's
  isolated Linux/root runner, `test_refactor_contracts.sh`'s
  dispatch-completeness and `bootstrapEssentials` contracts);
- share the same gates (G1/G2/G3, the dual-target live tier) and the same
  docs to update (`docs/release-maintenance.md`'s waiver-close, the
  consolidation plan's Branch 12 row);
- are already named and tracked as one branch in `checkout-consolidation-plan.md`.

Splitting into two branches would mean two live-gate cycles and two review
passes over adjacent, small, non-conflicting diffs in the same two files,
for no isolation benefit given neither implementation depends on the
other's landing. **If** the coordinating session wants each problem to be
independently revertible/rollback-able in production history (a legitimate
reason on its own, distinct from "do they share code"), splitting remains
straightforward later: land Problem 2 (smaller, lower-risk, matches an
already-fully-resolved Q6 exactly) as the first increment on this branch,
Problem 1 second, each its own clean commit sequence with its own red/green
evidence — which is what this document recommends doing *within* one branch
either way.

## 5. Summary for the coordinating session

| Question | Recommendation |
| --- | --- |
| Problem 1 design | P1-A: formalise today's incidental pre-import refusal into one deliberate, bounded-root-set collision check, closing the newly-found Shape B silent-skip gap. Does not make a colliding bump succeed; makes its refusal deliberate and complete. |
| Problem 2 design | Design 2-3: a minimal, bounded, presence/executability fail-fast check for the named prerequisite tools, run immediately after the remount, before `nix_restore_image_default_profile`. Matches Q6 exactly; uniform across both runtime modes. |
| Shared verifier? | No, under the recommended pair — different mechanism classes (content-hash vs. presence), different call sites. Would exist only if Design 2-1 were chosen instead of 2-3. |
| One branch or two? | One (`fix/store-trust`, as already created); no shared-landing dependency either way, and splitting has no isolation benefit given neither recommended design depends on the other. |
| Judgement call flagged | §1.4: whether Problem 1's Definition of Done requires a volume-reusing bump to *succeed* under collision (pushes toward the explicitly-warned-against P1-B/P1-C), or merely to be handled deterministically and safely (P1-A, recommended). |

This document proposes nothing outside `container/.../bootstrap/`,
`bin/lib/`, `flake.nix`, `tests/`, and the named docs. No new host-side
contract operation, no marker/state format change, and no Phase 3
direct-volume protocol change are needed for either recommended design — §1.5
and §2.5 state precisely what each recommendation means for direct-volume
mode without altering it.
