# Direct Docker volume storage for `/nix` (Branch 11 / Phase 3, `feat/qnap-direct-storage`)

Increment 0 design note, written before any code exists (the same discipline
`docker-adapter-mapping.md` used for Phase 2); Increment 0b amends section 5
per the coordinating session's design review of `f06404c` (see that section).
Implements `qnap-dxe-plan.md`'s `## Phase 3` items 1-3 and DQ4's
`direct-volume` bootstrap branch, amended by the coordinating session's
2026-09-27 decisions recorded in the task file: Docker named volumes only (no
bind mounts, no QNAP path in any tracked file), QNAP guests start from
scratch (item 7's restore drill is dropped; item 6 is satisfied by the
existing `dx-backup`/`dx-restore`, not designed here). Items 4 (helpers
through the adapter), 5 (`dx-reclaim`), and 6 (backup argv characterisation)
are later increments (4-6) with their own docs updates in Increment 7.

## 1. Today's apple-image protocol (unchanged; the baseline this branch varies from)

`bootstrap.sh`'s `bootstrap_main` (unconditional, both modes):

```
configure_single_user_nix
install_essentials
link_system_bash
capture_nix_image_default_profile   # reads /nix (pre-remount)
prepare_nix_volume                  # -> prepare_nix_volume_impl
materialize_auth_files
create_user                         # may consume record_durable_nix_identity's result
populate_prepared_nix_volume
nix_restore_image_default_profile
ensure_essentials_valid
publish_nix_image_store_identity
configure_release_identity
setup_persist
configure_ssh
configure_guest true
verify_guest_tools
configure_timezone
exec sshd -D -e -p 2222
```

`container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/base-and-storage.sh`,
today (`apple-image`, the only mode that exists before this branch):

- `prepare_nix_volume_impl`: if `/nix` is already mounted with the target
  filesystem (`findmnt -n -o TARGET,FSTYPE /nix`, matched on the FSTYPE
  field only -- Section 3 P7), sets `DX_NIX_VOLUME_ALREADY_MOUNTED=true`,
  `DX_NIX_VOLUME_ROOT=/nix`, calls `record_durable_nix_identity /nix`, and
  returns -- this is the fast path DQ4 says direct-volume must NOT reuse.
  Otherwise it detects whether `/var/lib/dx-nix-raw` (Apple's small
  runtime-managed volume) is a block device or a directory, formats it
  (`mkfs.btrfs`/`mkfs.ext4`, or `truncate` a sparse image file first for the
  directory case), mounts the result at `/mnt/tmp-nix`, sets
  `DX_NIX_VOLUME_ALREADY_MOUNTED=false`, `DX_NIX_VOLUME_ROOT=/mnt/tmp-nix`,
  `DX_NIX_VOLUME_DEVICE`/`FS_TYPE`/`MOUNT_OPTS`, and calls
  `record_durable_nix_identity /mnt/tmp-nix`.
- `populate_prepared_nix_volume`: returns immediately if
  `DX_NIX_VOLUME_ALREADY_MOUNTED=true` (skipping identity migration and the
  import-required check entirely on that path -- accepted today because
  Apple's own filesystem identity does not change between simple
  restarts). Otherwise: resolves `dx` uid/gid, calls
  `migrate_durable_nix_identity_if_needed "$volume_root"`; if
  `$volume_root/store` is missing (truly fresh device), seeds the whole
  `/nix` tree via `nix_seed_volume` then `nix_install_image_essentials_root`;
  else if `nix_image_store_import_required /nix "$volume_root"` is true,
  imports the image's registered closure via `nix_store_import_registered`;
  else republishes roots via `nix_install_image_essentials_root` ("Image Nix
  essentials identity is unchanged; skipping image-store import."). Finally
  (always, on the non-already-mounted path): `umount "$volume_root"`,
  `mount -t "$DX_NIX_VOLUME_FS_TYPE" ... /nix`, and append `/etc/fstab` if the
  entry is not already present.

The critical asymmetry `nix_image_store_import_required`'s comparison
depends on: at the point `populate_prepared_nix_volume` runs, `/nix` (the
`source_root` argument) is still the *image's own ephemeral mount*,
physically distinct from `$volume_root` (the durable device, staged at
`/mnt/tmp-nix` and not yet swapped onto `/nix`). `nix_image_registered_paths`
(`nix path-info --all`, no `--store` override) reads whichever store is
*currently mounted at `/nix`* -- i.e. genuinely "what this container's
actual image ships" -- and compares it against a marker recorded on the
volume. This is what lets apple-image detect "the image changed since this
volume was last populated." Section 5 explains why direct-volume mode does
not have this same independent point of comparison, and what replaces it.

## 2. The direct-volume protocol

### 2.1 `prepare_nix_volume_impl` — explicit dispatch

```sh
prepare_nix_volume_impl() {
    case "${DX_NIX_STORAGE_MODE:-apple-image}" in
        apple-image) : ;;                          # fall through, body unchanged below
        direct-volume) prepare_nix_volume_direct_impl; return ;;
        *)
            echo "Error: unknown DX_NIX_STORAGE_MODE '${DX_NIX_STORAGE_MODE:-}'; expected apple-image or direct-volume." >&2
            return 1
            ;;
    esac
    echo "Setting up dedicated Nix volume..."
    ... today's entire apple-image body, byte for byte, unchanged ...
}
```

The function keeps its name and its entire apple-image body; the dispatch is
a thin header, so an absent `DX_NIX_STORAGE_MODE` (every container created
before this branch, including the primary guest) falls straight through to
exactly the code that runs today. Malformed/unknown values fail closed
before any filesystem action, per the task's fail-closed requirement.

New function, `direct-volume` only:

```sh
prepare_nix_volume_direct_impl() {
    echo "Using direct Docker volume storage for /nix (DX_NIX_STORAGE_MODE=direct-volume)..."
    local mountpoint
    mountpoint="$(findmnt -n -o TARGET /nix 2>/dev/null || true)"
    if [ "$mountpoint" != /nix ]; then
        echo "Error: direct-volume mode requires the Nix volume mounted at /nix" >&2
        return 1
    fi
    DX_NIX_VOLUME_ROOT=/nix
    DX_NIX_VOLUME_IN_PLACE=true
    export DX_NIX_VOLUME_ROOT DX_NIX_VOLUME_IN_PLACE
    record_durable_nix_identity /nix
}
```

`findmnt -n -o TARGET /nix` is the exact probe the task specifies. This
function calls no `mkfs*`, `mount`, `umount`, `truncate`, or `blkid`, and
never touches `/etc/fstab` -- there is nothing here for those tools to do
in a Docker named-volume mount. `DX_NIX_VOLUME_IN_PLACE` (new, distinct from
`DX_NIX_VOLUME_ALREADY_MOUNTED`) is the explicit signal DQ4 requires instead
of reusing the existing fast path. `record_durable_nix_identity /nix` runs
exactly as it does in apple-image's own already-mounted branch -- same
function, unchanged, new call site.

### 2.2 `populate_prepared_nix_volume` — explicit dispatch

```sh
populate_prepared_nix_volume() {
    local volume_root="${DX_NIX_VOLUME_ROOT:?Nix volume was not prepared}"

    if [ "${DX_NIX_VOLUME_IN_PLACE:-false}" = true ]; then
        populate_prepared_nix_volume_in_place "$volume_root"
        return
    fi

    if [ "${DX_NIX_VOLUME_ALREADY_MOUNTED:-false}" = true ]; then
        return 0
    fi

    ... today's entire apple-image body, byte for byte, unchanged ...
}
```

One new guard clause ahead of the existing `ALREADY_MOUNTED` check; nothing
below it changes. Because `prepare_nix_volume_impl`'s apple-image path never
sets `DX_NIX_VOLUME_IN_PLACE`, this guard is inert for every existing caller.

New function, `direct-volume` only (amended by Increment 0b -- see section 5
for why the image-identity marker check exists alongside the original
`nix_image_store_import_required` check):

```sh
populate_prepared_nix_volume_in_place() {
    local volume_root="$1"
    local owner_uid owner_gid import_started
    local image_identity identity_marker recorded_identity

    owner_uid="$(id -u dx 2>/dev/null || printf '%s' 0)"
    owner_gid="$(id -g dx 2>/dev/null || printf '%s' 0)"
    migrate_durable_nix_identity_if_needed "$volume_root"

    if [ ! -d "$volume_root/store" ]; then
        echo "Error: direct-volume mode requires /nix/store to already exist. Docker populates an empty named volume from the image's content at its mount point on first use; an empty $volume_root/store means that dependency did not hold. Never seeding /nix into /nix." >&2
        return 1
    fi

    image_identity="${DX_IMAGE_IDENTITY:-}"
    if [ -z "$image_identity" ]; then
        echo "Error: direct-volume mode requires the runtime image identity; recreate the container with a current dx-create-container." >&2
        return 1
    fi

    identity_marker="$volume_root/.dx-image-identity-v1"
    if [ ! -f "$identity_marker" ]; then
        publish_nix_volume_image_identity "$volume_root" "$image_identity" || return 1
    else
        recorded_identity="$(cat "$identity_marker" 2>/dev/null || true)"
        if [ "$recorded_identity" != "$image_identity" ]; then
            echo "Error: this Nix volume was populated by a different image (recorded ${recorded_identity:0:19}... vs current ${image_identity:0:19}...); recreate the Nix volume (QNAP guests start from scratch) or wait for the verified import path (store-trust-plan.md Problem 1)." >&2
            return 1
        fi
    fi

    import_started=$SECONDS
    if [ ! -f "$volume_root/.dx-image-store-identity" ]; then
        DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$(nix_image_store_identity 2>/dev/null || true)"
        export DX_NIX_PENDING_IMAGE_STORE_IDENTITY
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    elif nix_image_store_import_required /nix "$volume_root"; then
        echo "Error: this volume's Nix-store content no longer matches its own recorded identity (corruption, or an interrupted prior write, since this volume was last confirmed); see store-trust-plan.md." >&2
        return 1
    else
        echo "Image Nix essentials identity is unchanged; skipping image-store import."
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    fi
    echo "Nix volume image import completed in $((SECONDS - import_started))s."
}
```

New helper, mirroring `publish_nix_image_store_identity`'s own
mktemp/chown/atomic-publish shape:

```sh
publish_nix_volume_image_identity() {
    local volume_root="$1"
    local image_identity="$2"
    local marker="$volume_root/.dx-image-identity-v1"
    local temporary

    dx_validate_atomic_marker_path "$marker" "direct-volume image identity marker" || return 1
    temporary="$(mktemp "$volume_root/.dx-image-identity-v1.tmp.XXXXXX")" || return 1
    printf '%s\n' "$image_identity" > "$temporary"
    if ! chown dx:dx "$temporary" \
        || ! dx_publish_atomic_marker "$temporary" "$marker" "direct-volume image identity marker"; then
        rm -f "$temporary"
        return 1
    fi
}
```

No `umount`/`mount`/`/etc/fstab` tail: `$volume_root` is already `/nix`, the
final mount point, from container start.

### 2.3 Ordering table

| Step (`bootstrap_main`) | apple-image | direct-volume |
| --- | --- | --- |
| `capture_nix_image_default_profile` | reads the image's own ephemeral `/nix` | reads the volume's `/nix` (already mounted; see section 4) |
| `prepare_nix_volume` | format+mount raw volume at `/mnt/tmp-nix`, or short-circuit if already correctly mounted | verify `/nix` is a mountpoint; refuse otherwise |
| `create_user` | may reuse `DX_NIX_DURABLE_UID/GID` from `record_durable_nix_identity` | same, unchanged |
| `populate_prepared_nix_volume` | seed/import into the staged device, **then remount device onto `/nix` + fstab** | image-identity marker check, then seed check + import-required check **against `/nix` in place, no remount** |
| `nix_restore_image_default_profile` | restores `/nix/var/nix/profiles/default` against the now-final `/nix` | same call, same function, unchanged (already final `/nix`) |
| `ensure_essentials_valid`, `publish_nix_image_store_identity` | unchanged | unchanged |

## 3. Apple-only steps skipped in direct-volume mode

Never invoked on the `direct-volume` branch: `findmnt -n -o TARGET,FSTYPE`
(the apple-image already-mounted probe -- direct-volume uses the plain
`TARGET`-only probe instead), block-device-vs-directory detection, `truncate`
(sparse image creation), `mkfs.btrfs`/`mkfs.ext4`, `blkid -L dx-nix`, the
`mount -t ... /mnt/tmp-nix` staging mount, the final `umount`/`mount`
remount pair, and the `/etc/fstab` append. `nix_seed_volume` (the
image-root-to-volume tar copy) is also never called -- see section 4.
Increment 2's tests assert this with recording-stub shell functions for
`mkfs.btrfs`, `mkfs.ext4`, `mount`, `umount`, `truncate`, and `blkid` (the
same shape as Section 3 P7's `findmnt` stub), logging every invocation and
asserting the log stays empty after `prepare_nix_volume_direct_impl` and
`populate_prepared_nix_volume_in_place` run. `--cap-add CAP_SYS_ADMIN` is
not granted at all under `docker-ssh` today (Phase 2's
`dx_runtime_docker_container_create` never emits it); that is existing
Phase 2 behavior, not something this phase changes.

## 4. The Docker copy-on-first-mount dependency (design point C)

Docker's documented behavior: creating a container with a *new, empty*
named volume mounted at a path that already has content in the image
populates the volume from that image content before the container's
process starts; a *non-empty* (already-populated) volume is used exactly
as-is and the image's own content at that path is never copied or
otherwise made reachable. Direct-volume mode depends on this for its
initial `/nix/store`: nothing in this bootstrap ever seeds `/nix` from a
separate image copy (`nix_seed_volume` is apple-image-only, per section 3).
If `/nix/store` is missing when `populate_prepared_nix_volume_in_place`
runs, that dependency did not hold (wrong image, a volume that was never
actually populated, or a volume mounted at the wrong container path), and
the guest refuses with the message in section 2.2 rather than attempting to
seed `/nix` from itself.

**How the live check will verify it** (the coordinating session's own step,
not this subagent's): create a disposable, freshly created named volume,
run a short-lived, non-privileged container from the real DX guest image
with that volume mounted directly at `/nix` and no bootstrap entrypoint
(e.g. `docker run --rm -v <disposable-vol>:/nix <image> sh -c 'test -d
/nix/store && echo OK'`), confirm `/nix/store` is present without any
bootstrap code having run, then remove the disposable volume. This is the
same shape `tests/qnap/phase0-spike.sh` step 5 already proved for a mount
without privilege/`CAP_SYS_ADMIN`, extended to check store content with the
real guest image rather than the spike's minimal listener image.

## 5. Image change with a reused volume (design point D, amended in Increment 0b)

**Increment 0 originally proposed** relying solely on
`nix_image_store_import_required` for this refusal. The coordinating
session's design review of `f06404c` rejected that: a refusal that cannot
detect a plain image bump on a reused volume does not satisfy design point
D. The finding recorded in Increment 0 was correct --
`nix_image_store_import_required`'s `identity` value comes from
`nix_image_store_identity`, which runs `nix path-info --all` with no
`--store` override, reading whichever Nix store is *currently mounted at
`/nix`*. In apple-image mode that is genuinely informative (section 1's
"critical asymmetry": `/nix` is still the image's own ephemeral mount at
populate-time, physically distinct from the durable device). In
direct-volume mode there is no such second copy -- recreating a container
against the same volume with a *different* image leaves `/nix`'s content
completely untouched (Docker's copy-on-first-mount never touches a
non-empty volume), so this signal alone cannot distinguish "same image,
volume reused" from "different image, volume reused." The amendment does
not try to reach the image's own hidden store to fix this; instead **the
host tells the guest which image created the container**, independent of
the volume's own content.

### 5.1 New contract operation: `dx_runtime_image_identity`

`dx_runtime_image_identity <image>` returns the runtime's own stable
identity for an image reference, added to `bin/lib/dx-runtime.sh`'s
dispatch (`dx_runtime_image_identity() { dx_runtime_dispatch image_identity
"$@"; }`, grouped with the other image operations) and both adapters:

- **Docker** (`bin/lib/dx-runtime-docker.sh`): `<docker> image inspect
  --format '{{.Id}}' <ref>` -- the same structured, single-field query shape
  every other Docker query in this adapter uses (never a JSON blob parsed on
  the controller; `tests/qnap/phase0-spike.sh` already uses this exact
  `--format` for its own base-image/tag-image digest comparison). Returns
  `sha256:<hex>` verbatim, as Docker's own template renders it.
- **Apple** (`bin/lib/dx-runtime-apple.sh`): `container image inspect
  <ref>` has no `--format` flag (confirmed against the real Apple Container
  CLI's `--help`); it always prints a JSON array whose first element has a
  stable top-level `"id"` field (a bare hex digest, confirmed against real
  local images -- distinct from the `"digest"` fields nested under
  `configuration.descriptor` and each `variants[]` entry, which are named
  differently and cannot be confused with it). Extracted with a fixed-shape
  `sed` match (no `jq` dependency on the controller, matching
  `bin/lib/dx-runtime-docker.sh`'s own stated reason for avoiding a JSON
  parser on the Mac side), then rendered with a `sha256:` prefix so both
  runtimes produce the same `sha256:<hex>` shape even though the two
  values are never compared against each other.

Failure to obtain an image identity (image missing, inspect fails, output
unparseable) fails closed: `dx_runtime_image_identity` returns non-zero and
`bin/dx-create-container` aborts the create (`set -euo pipefail`) rather
than proceeding without one.

### 5.2 Env passthrough gains a second token

`bin/dx-create-container` resolves `dx_runtime_image_identity "$DX_IMAGE"`
once and passes it as a second `--env` token, alongside
`DX_NIX_STORAGE_MODE` (section 7): `--env
"DX_IMAGE_IDENTITY=$(dx_runtime_image_identity "$DX_IMAGE")"`. Apple's
create argv therefore changes by exactly two env tokens now (both
deliberate, both authorised); section 7 has the exact characterisation-test
update. **Apple-image mode in the guest does not consume
`DX_IMAGE_IDENTITY` at all** -- it is computed and forwarded for both
runtimes (so the contract operation and the env-passthrough code path are
uniform), but nothing in `base-and-storage.sh`'s apple-image branch reads
it. Apple behaviour is unchanged.

### 5.3 Guest-side check, direct-volume only

`populate_prepared_nix_volume_in_place` (section 2.2) now runs, in this
order, before any store-content execution the phase controls:

1. `$volume_root/store` missing -> refuse (section 2.2's existing Docker
   copy-on-first-mount refusal, unchanged, checked first since there is
   nothing to compare an identity against otherwise).
2. `DX_IMAGE_IDENTITY` absent/empty -> refuse ("direct-volume mode requires
   the runtime image identity; recreate the container with a current
   dx-create-container").
3. `$volume_root/.dx-image-identity-v1` absent (first bootstrap-managed
   boot for this volume, immediately after Docker's copy-on-first-mount, or
   an older marker-less generation) -> write it atomically with the env
   value (`publish_nix_volume_image_identity`, reusing
   `dx_publish_atomic_marker`/`dx_validate_atomic_marker_path`), then
   continue to step 4.
4. Marker present and equal to `DX_IMAGE_IDENTITY` -> continue: run the
   *original* `nix_image_store_import_required` check unchanged. This is
   now purely a self-consistency/corruption check ("this volume's own
   content still matches what was last recorded on it"), not an
   image-change detector -- that job now belongs to step 3/5 entirely.
5. Marker present and **not** equal to `DX_IMAGE_IDENTITY` -> refuse,
   naming both identities prefix-shortened (`${value:0:19}...`, matching a
   git-short-SHA-style abbreviation of `sha256:<hex>`) and the remedy:
   recreate the Nix volume (QNAP guests start from scratch, user decision
   3) or wait for the verified import path (`store-trust-plan.md` Problem
   1).

This correctly detects a plain image bump on a reused volume (the marker
written under the *old* image's identity will not equal the *new* image's
identity, because the host recomputes `DX_IMAGE_IDENTITY` fresh at every
`dx-create-container` from the runtime's own image inspection -- it does
not depend on anything stored on the volume) while keeping
`nix_image_store_import_required`'s existing check as the corruption/tamper
safety net the original design already had. "Matching identity -> publish
roots as today" (design point D's own words) still holds: a matched marker
falls through to exactly the same `nix_install_image_essentials_root` call
as before.

One related, pre-existing gap this phase does not touch either way: by the
time `populate_prepared_nix_volume` runs (in either mode),
`install_essentials`, `capture_nix_image_default_profile`, and
`create_user` have already executed binaries resolved from whatever store
is currently mounted -- this is `store-trust-plan.md` Problem 2 ("no
mechanism chosen"), pre-existing and identical in shape for apple-image
today. Section 6 below states this precisely for direct-volume mode, which
sharpens it without solving it.

## 6. The trust-root limitation of direct-volume mode (new, Increment 0b)

Apple-image mode has a genuine pre-remount window: `/nix` starts out as the
image's own ephemeral mount, and every early bootstrap step
(`install_essentials`, `capture_nix_image_default_profile`,
`prepare_nix_volume`'s formatting) runs against that known-good image
content *before* the durable volume is ever swapped onto `/nix`. Only after
the swap does anything execute from the volume's own (possibly-reused,
possibly-stale) content.

**Direct-volume mode has no such window at all.** `/nix` is the Docker
volume from the container's very first instruction -- there is no point,
ever, during this bootstrap at which the entrypoint shell, `bash`, `nix`,
or any other early binary resolves against anything other than whatever is
already on that volume. Every check this phase adds (the image-identity
marker comparison in section 5, the pre-existing
`nix_image_store_import_required` self-consistency check) is itself
executed by tools drawn from the exact store it is checking. This is
`store-trust-plan.md` Problem 2 ("after the remount, no binary from the
persistent store may be trusted to prove that same trust root sound") in a
sharper form than apple-image ever presented it: apple-image at least has
one step (however early) that runs before any volume content executes;
direct-volume mode does not have that step at all.

This is **not waived and not solved here**. `store-trust-plan.md` already
records Problem 2 as open, with no mechanism chosen, for both runtimes;
this phase adds no new resolution and claims none. Branch 12 owns the
design (pre-remount verification using image-resident tooling, a captured
independent toolchain, or deliberate fail-fast, per that file's "Designs to
compare" section) for whichever runtime reaches it first. Increment 7
carries this same statement into `qnap-dxe-plan.md`'s Phase 3 status text,
so it is recorded where an operator planning the QNAP rollout will see it.

## 7. Env passthrough (design point A, Increment 1; second token added in Increment 0b)

`bin/dx-create-container`'s `CREATE_ARGS` array gains two lines, immediately
after the existing `DX_NIX_DISK_SIZE` entry:

```sh
    --env "DX_NIX_DISK_SIZE=$DX_NIX_DISK_SIZE"
    --env "DX_NIX_STORAGE_MODE=$DX_NIX_STORAGE_MODE"
    --env "DX_IMAGE_IDENTITY=$(dx_runtime_image_identity "$DX_IMAGE")"
    --memory "$DX_CONTAINER_MEMORY"
```

(`dx_runtime_image_identity`'s failure aborts the script under `set -euo
pipefail` before `CREATE_ARGS` is even passed to `dx_runtime_container_create`
-- fail-closed, per section 5.1.)

`DX_NIX_STORAGE_MODE` is already a registered config field (default
`apple-image`, validated to `apple-image|direct-volume`;
`bin/lib/dx-config.sh`, landed in Phase 2), so this is a value the neutral
`--env` vocabulary already knows how to carry. `DX_IMAGE_IDENTITY` is not a
registered config field (it is computed, not configured, exactly like
`HOST_TZ`/`DX_PUB_KEY` above it in the same array). Both
`dx_runtime_apple_container_create` and `dx_runtime_docker_container_create`
render `--env` as `-e` in the same relative order (`bin/lib/dx-runtime-apple.sh`,
`bin/lib/dx-runtime-docker.sh`), so no adapter change is needed for either
token to reach either guest. This is the two deliberate, on-purpose changes
to Apple's create argv the task (and the coordinating session's amendment)
call for: `tests/test_runtime_boundary_characterisation.sh`'s
"dx-create-container renders today's exact Apple container-create argv"
case (around lines 694-727) gains two lines, `-e
DX_NIX_STORAGE_MODE=apple-image` and `-e DX_IMAGE_IDENTITY=sha256:<pinned
test digest>`, inserted immediately after `-e DX_NIX_DISK_SIZE=64G` in both
the pinned env block and the independently reconstructed expected-argv
block; the test's fake `container` tool gains an `image inspect` branch
returning a fixed, pinned JSON body shaped like section 5.1 describes, so
the expected identity value is deterministic. Containers created before
this branch (no `DX_NIX_STORAGE_MODE`/`DX_IMAGE_IDENTITY` env vars inside
the guest at all) are unaffected: `${DX_NIX_STORAGE_MODE:-apple-image}`
treats absence identically to `apple-image`, and apple-image mode never
reads `DX_IMAGE_IDENTITY` (section 5.2).

## 8. The apple-image "unchanged" claim and what proves it

No apple-image code path's behavior changes:

- `prepare_nix_volume_impl`/`populate_prepared_nix_volume` keep their names
  and their entire existing bodies; the new dispatch guards are inert
  whenever `DX_NIX_STORAGE_MODE` is unset/`apple-image` and
  `DX_NIX_VOLUME_IN_PLACE` is unset (true for every existing caller and
  test).
- Section 3 (`tests/test_section3_bootstrap.sh`), including P7's
  `findmnt` false-positive/true-positive pair and every other
  `prepare_nix_volume`/`populate_prepared_nix_volume`/`setup_nix_volume`
  case, keeps passing unmodified (the new direct-volume functions are
  additive; the sourced-function-definedness smoke list at line 24 gains
  the new function names, which is the only edit to that file's existing
  content).
- Section 5 (`tests/test_section5_nix.sh`) and `tests/test_nix_store_import.sh`
  (Section 25's isolated real-Nix runner, which already exercises
  `nix_image_store_import_required`, `nix_seed_volume`,
  `nix_store_import_registered` directly) are unaffected: none of those
  functions' bodies change; direct-volume mode only adds new call sites and
  a store-presence/marker-presence gate around them.
- `tests/test_runtime_boundary_characterisation.sh`'s Apple create-argv case
  proves the two, on-purpose env-token additions and nothing else changed
  (section 7).
- Coverage/ratchet (`tests/run-coverage-linux.sh`) re-measured on the
  finished branch, same rules as every prior phase (measure on a clean
  `git archive HEAD | tar -x` export; adjust `tests/coverage/ratchet.env`
  only to the measured value, in its own commit, if it moved).

## 9. `DX_NIX_DISK_SIZE` in direct-volume mode

Neither `prepare_nix_volume_direct_impl` nor
`populate_prepared_nix_volume_in_place` reads `DX_NIX_DISK_SIZE` (it is only
ever consumed by apple-image's sparse-image-file branch, `truncate -s
"$disk_size" "$dev"`). It remains a registered, validated config field
(still forwarded as an env var per section 7, since the guest treats an
absent/ignored variable as harmless) but is meaningless once
`DX_NIX_STORAGE_MODE=direct-volume`: Docker volume sizing is a QNAP storage
pool / Container Station matter outside this phase's scope (DQ4's deferred
"later bind for `/persist`" territory, not reopened here). Documented here
per the task's instruction; no code enforces or rejects setting it
alongside `direct-volume`.

## 10. Out of scope for this design note

Items 4 (helpers through the adapter: `dx-create-volumes`,
`dx-destroy-container`, `dx-destroy-image`, `dx-migrate-persist`, the
`dx_container_list_names` boundary-leak fix, the Section 32 audit
extension), 5 (`dx_runtime_volume_usage` + capability-aware `dx-reclaim`),
and 6 (backup argv characterisation under `docker-ssh`) are later increments
(4-6) with their own validation; Increment 7 updates `docs/lifecycle.md`,
`docs/refactor/runtime-boundary.md`/`runtime-boundary-inventory.md`,
`qnap-dxe-plan.md`'s Phase 3 status (including this note's section 6
trust-root statement, per the coordinating session's amendment), and the
consolidation plan. Not in this phase at all (per the task): `dx-mount`,
`dx-nix-disk`, remote-aware SSH/publish, the x86_64 guest image itself,
`system_start`, and any `.nix` change.
