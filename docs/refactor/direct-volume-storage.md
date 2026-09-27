# Direct Docker volume storage for `/nix` (Branch 11 / Phase 3, `feat/qnap-direct-storage`)

Increment 0 design note, written before any code exists (the same discipline
`docker-adapter-mapping.md` used for Phase 2). Implements
`qnap-dxe-plan.md`'s `## Phase 3` items 1-3 and DQ4's `direct-volume`
bootstrap branch, amended by the coordinating session's 2026-09-27 decisions
recorded in the task file: Docker named volumes only (no bind mounts, no
QNAP path in any tracked file), QNAP guests start from scratch (item 7's
restore drill is dropped; item 6 is satisfied by the existing
`dx-backup`/`dx-restore`, not designed here). Items 4 (helpers through the
adapter), 5 (`dx-reclaim`), and 6 (backup argv characterisation) are later
increments (4-6) with their own docs updates in Increment 7; this note is
scoped to the in-guest protocol per the task's own Increment 0 description.

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
volume was last populated." Section 4 explains why direct-volume mode does
not have this same independent point of comparison.

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
below it changes. Because `prepare_nix_volume_apple_image`'s path never sets
`DX_NIX_VOLUME_IN_PLACE`, this guard is inert for every existing caller.

New function, `direct-volume` only:

```sh
populate_prepared_nix_volume_in_place() {
    local volume_root="$1"
    local owner_uid owner_gid import_started

    owner_uid="$(id -u dx 2>/dev/null || printf '%s' 0)"
    owner_gid="$(id -g dx 2>/dev/null || printf '%s' 0)"
    migrate_durable_nix_identity_if_needed "$volume_root"

    if [ ! -d "$volume_root/store" ]; then
        echo "Error: direct-volume mode requires /nix/store to already exist. Docker populates an empty named volume from the image's content at its mount point on first use; an empty $volume_root/store means that dependency did not hold. Never seeding /nix into /nix." >&2
        return 1
    fi

    import_started=$SECONDS
    if [ ! -f "$volume_root/.dx-image-store-identity" ]; then
        # First bootstrap-managed boot for this volume (Docker's
        # copy-on-first-mount just populated it, or an older
        # marker-less generation reused here). No independent copy of
        # the image's own store exists to import from in direct-volume
        # mode -- see section 4 -- so this mirrors apple-image's own
        # fresh-seed branch, which also never calls
        # nix_image_store_import_required.
        DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$(nix_image_store_identity 2>/dev/null || true)"
        export DX_NIX_PENDING_IMAGE_STORE_IDENTITY
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    elif nix_image_store_import_required /nix "$volume_root"; then
        echo "Error: this volume's recorded Nix-store identity no longer verifies (image Nix essentials changed, or content diverged, since this volume was last confirmed). Direct-volume mode cannot import a differently-provenanced store because the image's own store is hidden under the mount; see store-trust-plan.md. Recreate the volume, or wait for the verified import path." >&2
        return 1
    else
        echo "Image Nix essentials identity is unchanged; skipping image-store import."
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    fi
    echo "Nix volume image import completed in $((SECONDS - import_started))s."
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
| `populate_prepared_nix_volume` | seed/import into the staged device, **then remount device onto `/nix` + fstab** | seed check + import-required check **against `/nix` in place, no remount** |
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

## 5. Image change with a reused volume (design point D) — what the refusal actually covers

`nix_image_store_import_required`'s `identity` value comes from
`nix_image_store_identity`, which runs `nix path-info --all` with no
`--store` override -- it reads whichever Nix store is *currently mounted at
`/nix`*, not a separately accessible image copy. In apple-image mode this
is genuinely informative because, at populate-time, `/nix` is still the
image's own ephemeral mount, physically distinct from the durable device
(section 1). In direct-volume mode there is no such second copy: `/nix` is
the volume from container start, always, so the "image's own store" this
phase's task file refers to as "hidden under the mount" is not reachable by
any in-guest mechanism once a non-empty volume is attached. Concretely:

- **Marker absent** (`$volume_root/.dx-image-store-identity` does not
  exist): treated as the volume's first bootstrap-managed boot (matches
  apple-image's own fresh-seed branch, which never calls
  `nix_image_store_import_required` either) -- proceeds, publishes roots,
  and (via `publish_nix_image_store_identity`, later in `bootstrap_main`,
  unchanged) writes the marker for the first time.
- **Marker present and `nix_image_store_import_required` reports "not
  required"** (identity matches and `nix store verify --recursive
  --no-trust` on the recorded roots passes): the volume's own content is
  self-consistent with what was last recorded on it -- proceeds, republishes
  roots ("Matching identity -> publish roots as today").
- **Marker present and `nix_image_store_import_required` reports
  "required"** (identity differs, or matches but verification fails):
  refuses before `nix_install_image_essentials_root` runs, citing
  `store-trust-plan.md`.

**Flagged for the coordinating session's design review (not a stop, per the
task's own instruction to point at `store-trust-plan.md` rather than
implement an import):** because `/nix`'s content is physically unchanged by
recreating a container against the same volume with a *different* image
(Docker's copy-on-first-mount never touches a non-empty volume), the
"required" branch above cannot, by itself, detect that exact scenario --
the identity it recomputes each boot is derived only from the volume's own
persisted content, which a mere image bump does not touch. What it *does*
still catch is any case where the volume's content has diverged from its
own last-recorded, verified state (corruption, an interrupted prior write,
external tampering). The general "no valid, volume-reusing pin-bump
procedure" gap is exactly `store-trust-plan.md` Problem 1, already recorded
as unsolved for both runtimes; this phase does not attempt to close it, and
the refusal above is the same fail-closed posture the task asks for, not a
guaranteed pin-bump detector. Recommendation: land as designed (matches the
task's literal instruction and the "do not implement an import" boundary);
flagging so the coordinating session's review confirms this reading of "the
image changed but the volume was populated by a different image" matches
intent before Increment 3 lands.

One related, pre-existing gap this phase does not touch either way: by the
time `populate_prepared_nix_volume` runs (in either mode), `install_essentials`,
`capture_nix_image_default_profile`, and `create_user` have already executed
binaries resolved from whatever store is currently mounted -- this is
`store-trust-plan.md` Problem 2 ("no mechanism chosen"), pre-existing and
identical in shape for apple-image today; direct-volume mode does not make
it worse or better.

## 6. Env passthrough (design point A, Increment 1)

`bin/dx-create-container`'s `CREATE_ARGS` array gains one line, immediately
after the existing `DX_NIX_DISK_SIZE` entry:

```sh
    --env "DX_NIX_DISK_SIZE=$DX_NIX_DISK_SIZE"
    --env "DX_NIX_STORAGE_MODE=$DX_NIX_STORAGE_MODE"
    --memory "$DX_CONTAINER_MEMORY"
```

`DX_NIX_STORAGE_MODE` is already a registered config field (default
`apple-image`, validated to `apple-image|direct-volume`;
`bin/lib/dx-config.sh`, landed in Phase 2), so this is a value the neutral
`--env` vocabulary already knows how to carry -- both
`dx_runtime_apple_container_create` and `dx_runtime_docker_container_create`
render `--env` as `-e` in the same relative order (`bin/lib/dx-runtime-apple.sh`,
`bin/lib/dx-runtime-docker.sh`), so no adapter change is needed for the
token to reach either guest. This is the one deliberate, on-purpose change
to Apple's create argv the task calls for:
`tests/test_runtime_boundary_characterisation.sh`'s "dx-create-container
renders today's exact Apple container-create argv" case (around lines
694-727) gains one line, `-e DX_NIX_STORAGE_MODE=apple-image`, inserted
immediately after `-e DX_NIX_DISK_SIZE=64G` in both the pinned env block and
the independently reconstructed expected-argv block, plus
`DX_NIX_STORAGE_MODE=apple-image` added to the pinned `env` invocation.
Containers created before this branch (no `DX_NIX_STORAGE_MODE` env var
inside the guest at all) are unaffected: `${DX_NIX_STORAGE_MODE:-apple-image}`
treats absence identically to `apple-image`.

## 7. The apple-image "unchanged" claim and what proves it

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
  proves the single, on-purpose env-token addition and nothing else changed
  (section 6).
- Coverage/ratchet (`tests/run-coverage-linux.sh`) re-measured on the
  finished branch, same rules as every prior phase (measure on a clean
  `git archive HEAD | tar -x` export; adjust `tests/coverage/ratchet.env`
  only to the measured value, in its own commit, if it moved).

## 8. `DX_NIX_DISK_SIZE` in direct-volume mode

Neither `prepare_nix_volume_direct_impl` nor
`populate_prepared_nix_volume_in_place` reads `DX_NIX_DISK_SIZE` (it is only
ever consumed by apple-image's sparse-image-file branch, `truncate -s
"$disk_size" "$dev"`). It remains a registered, validated config field
(still forwarded as an env var per section 6, since the guest treats an
absent/ignored variable as harmless) but is meaningless once
`DX_NIX_STORAGE_MODE=direct-volume`: Docker volume sizing is a QNAP storage
pool / Container Station matter outside this phase's scope (DQ4's deferred
"later bind for `/persist`" territory, not reopened here). Documented here
per the task's instruction; no code enforces or rejects setting it
alongside `direct-volume`.

## 9. Out of scope for this design note

Items 4 (helpers through the adapter: `dx-create-volumes`,
`dx-destroy-container`, `dx-destroy-image`, `dx-migrate-persist`, the
`dx_container_list_names` boundary-leak fix, the Section 32 audit
extension), 5 (`dx_runtime_volume_usage` + capability-aware `dx-reclaim`),
and 6 (backup argv characterisation under `docker-ssh`) are later increments
(4-6) with their own validation; Increment 7 updates `docs/lifecycle.md`,
`docs/refactor/runtime-boundary.md`/`runtime-boundary-inventory.md`,
`qnap-dxe-plan.md`'s Phase 3 status, and the consolidation plan. Not in this
phase at all (per the task): `dx-mount`, `dx-nix-disk`, remote-aware
SSH/publish, the x86_64 guest image itself, `system_start`, and any `.nix`
change.
