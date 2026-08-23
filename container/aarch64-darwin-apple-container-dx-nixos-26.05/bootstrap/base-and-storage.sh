#!/usr/bin/env bash
# Source-only bootstrap base-and-storage phase. Safe to source.

install_essentials() {
    # The essentials profile lives off the image's default PATH (see
    # essentials_profile_path above), so it must be resolved and exported
    # BEFORE the skip-gate below runs. Every container boot re-executes this
    # function; if the gate ran first, it would never see a previous boot's
    # already-installed essentials and would re-run `nix profile install` on
    # every restart, which can conflict with that same profile's own earlier
    # contents once the registry-resolved package revision has moved on.
    local essentials_path
    local phase_started=$SECONDS
    local status
    essentials_path="$(essentials_profile_path)"
    if [ -n "$essentials_path" ]; then
        export PATH="$essentials_path:$PATH"
    fi
    # Only install if shadow tools (like useradd) aren't available
    if ! command -v useradd >/dev/null 2>&1; then
        echo "Installing essential tools..."
        # Install tools needed for the bootstrap itself into the root profile.
        # util-linux/btrfs-progs/e2fsprogs provide mount/umount/mkfs for the
        # dedicated /nix volume managed in setup_nix_volume (§2). The download
        # options mirror run_home_manager_activation so a stalled substituter
        # fetch aborts and retries instead of hanging the whole bootstrap.
        if install_essential_packages; then
            :
        else
            status=$?
            echo "Bootstrap phase: essentials installation failed after $((SECONDS - phase_started))s (exit $status)." >&2
            return "$status"
        fi
        # The install just created or extended a profile; resolve it (again)
        # so the freshly installed tools are on PATH for the rest of bootstrap.
        essentials_path="$(essentials_profile_path)"
        if [ -n "$essentials_path" ]; then
            export PATH="$essentials_path:$PATH"
        fi
    fi
    echo "Bootstrap phase: essentials installation completed in $((SECONDS - phase_started))s."
}

# Non-interactive sshd sessions hand dx's nushell only the bare default
# PATH, and both dx-ssh's command wrapper and dx-wait-ssh's readiness
# probe bootstrap the guest environment via `bash -l`. The old base
# satisfied that with a global /bin/bash; the official base ships none.
# Link the essentials bash at /usr/bin/bash -- on the default PATH --
# and deliberately NOT at /bin/bash, whose presence is the old-base
# guard signature (guard_old_base above).
link_system_bash() {
    local root="${DX_LINK_ROOT:-}"
    local bash_path
    bash_path="$(command -v bash)"
    mkdir -p "$root/usr/bin"
    ln -sfn "$bash_path" "$root/usr/bin/bash"
}

# Wraps the `-b` test so the block-device path below can be exercised without a
# real block device. Coverage probes shadow this the same way they shadow
# findmnt and blkid; creating one with mknod needs CAP_MKNOD, which a rootless
# container runner does not have, and that made this branch's coverage depend on
# which container runtime happened to run the suite.
is_block_device() { [ -b "$1" ]; }

dx_seed_staged_entries() (
    local staged_contents="$1" destination_root="$2" staged_path entry_name
    shopt -s dotglob nullglob
    for staged_path in "$staged_contents"/*; do
        entry_name="${staged_path##*/}"
        if [ -e "$destination_root/$entry_name" ] || [ -L "$destination_root/$entry_name" ]; then
            echo "Error: refusing to seed over existing Nix entry $destination_root/$entry_name." >&2
            return 1
        fi
        mv "$staged_path" "$destination_root/$entry_name" || return 1
    done
) # KCOV_SUBSHELL_TERMINATOR

# Move every entry from a recovered staging subtree unless a newer published
# entry already occupies that name. Keep glob state local to this helper so
# recovery callers cannot leak dotglob/nullglob into later bootstrap work.
dx_move_missing_entries() (
    local source="$1" destination="$2" staged_path entry_name destination_path
    shopt -s dotglob nullglob
    for staged_path in "$source"/*; do
        entry_name="${staged_path##*/}"
        destination_path="$destination/$entry_name"
        [ -e "$destination_path" ] || [ -L "$destination_path" ] || mv "$staged_path" "$destination_path" || return 1
    done
) # KCOV_SUBSHELL_TERMINATOR

# Recover (or discard an incomplete) same-filesystem import staging directory.
# Only a stage carrying .ready completed extraction.  For that state publish a
# complete staged path before considering an older quarantined path; this means
# a crash between quarantine and publication can never make cleanup delete the
# only valid copy.  A pre-.ready stage is safe to discard because no final path
# was removed before that marker was written.
cleanup_stale_nix_store_imports() {
    local destination_root="$1"
    local destination_store="$destination_root/store"
    local stage

    for stage in "$destination_root"/.dx-store-import-stage.*; do
        [ -d "$stage" ] || continue
        if [ ! -f "$stage/.ready" ]; then
            echo "Discarding incomplete image-store import staging directory $(basename "$stage")..."
            rm -rf "$stage"
            continue
        fi
        echo "Recovering interrupted image-store import staging directory $(basename "$stage")..."
        mkdir -p "$destination_store"
        dx_move_missing_entries "$stage/store" "$destination_store" || return 1
        dx_move_missing_entries "$stage/quarantine" "$destination_store" || return 1
        dx_move_missing_entries "$stage/contents" "$destination_root" || return 1
        rm -rf "$stage"
    done
}

# Incremental imports use Nix's native copy protocol rather than a filesystem
# copy.  Nix publishes paths atomically, retries interrupted transfers, and
# records validity/references in the target database as part of the operation;
# a tar or cp merge can only provide the first of those properties.  The target
# keeps the logical /nix/store path while `real` points at the temporary mount.
nix_store_import_registered() {
    local destination_root="$1"
    local owner_uid="$2"
    local owner_gid="$3"
    local target_store

    mkdir -p "$destination_root/store" "$destination_root/var/nix" "$destination_root/var/log/nix"
    chown "$owner_uid:$owner_gid" "$destination_root/store" "$destination_root/var" "$destination_root/var/nix" "$destination_root/var/log/nix"
    target_store="$(nix_target_store_uri "$destination_root")"
    echo "Importing registered image Nix closure..."
    if ! { nix_image_registered_paths | run_as_dx "set -o pipefail; nix --extra-experimental-features 'nix-command flakes read-only-local-store' copy --from 'local?read-only=true' --to '$target_store' --stdin --no-check-sigs"; dx_pipeline_succeeded "${PIPESTATUS[@]}"; }; then
        echo "Error: Nix could not import and register the image store closure." >&2
        return 1
    fi
    nix_verify_imported_bootstrap_paths "$destination_root" || return 1
    nix_install_image_essentials_root "$destination_root" "$owner_uid" "$owner_gid"
}

nix_install_image_essentials_root() {
    local destination_root="$1"
    local owner_uid="$2"
    local owner_gid="$3"
    local gcroots stage final identity path final_name bootstrap_paths

    gcroots="$destination_root/var/nix/gcroots"
    mkdir -p "$gcroots"
    # A stage has no published roots, so a previous interrupted stage is safe
    # to discard; the old identity-qualified directory remains in place.
    rm -rf "$gcroots"/.dx-image-roots-stage.*
    # Publish a complete new root set before pruning the old one. A kill at
    # any point therefore leaves at least one valid set for the GC scanner.
    identity="${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-$(nix_image_store_identity)}" || return 1
    if ! [[ "$identity" =~ ^[0123456789abcdef]{64}$ ]]; then
        echo "Error: refusing to publish GC roots with an invalid image identity." >&2
        return 1
    fi
    # Version the directory layout as well as the image identity.  A matching
    # identity from an older bootstrap can otherwise suppress publication of
    # newly required roots (such as the image default profile) indefinitely.
    final_name="dx-image-roots-v2-$identity"
    final="$gcroots/$final_name"
    if [ ! -d "$final" ]; then
        stage="$(mktemp -d "$gcroots/.dx-image-roots-stage.XXXXXX")" || return 1
        bootstrap_paths="$(nix_image_bootstrap_store_paths /nix)" || {
            rm -rf "$stage"
            return 1
        }
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            ln -s "$path" "$stage/${path##*/}" || { rm -rf "$stage"; return 1; }
        done <<< "$bootstrap_paths"
        if ! find "$stage" -mindepth 1 -maxdepth 1 -type l -print -quit | grep -q .; then
            rm -rf "$stage"
            echo "Error: refusing to publish an empty image GC-root set." >&2
            return 1
        fi
        chown "$owner_uid:$owner_gid" "$stage" || { rm -rf "$stage"; return 1; }
        chown -h "$owner_uid:$owner_gid" "$stage"/* || { rm -rf "$stage"; return 1; }
        # Identity-qualified names make this a one-way atomic publication.
        mv "$stage" "$final" || { rm -rf "$stage"; return 1; }
    fi
    # Only prune after the new complete directory is visible. Legacy links
    # are superseded by the directory form and can be safely removed here.
    rm -f "$gcroots"/dx-image-* 2>/dev/null || true
    for path in "$gcroots"/dx-image-roots-*; do
        [ "$path" = "$final" ] || rm -rf "$path"
    done
    chown "$owner_uid:$owner_gid" "$gcroots"
}

# Seed a brand-new durable volume through the same owner-mapped staging rule as
# incremental imports.  The whole /nix tree is moved only after extraction
# completes, so the store and its database arrive together; no recursive chown
# is needed afterwards merely because root performed the bootstrap copy.
nix_seed_volume() {
    local source_root="$1"
    local destination_root="$2"
    local owner_uid="$3"
    local owner_gid="$4"
    local stage_root=""
    local staged_contents=""
    local staged_path entry_name

    [ -d "$source_root/store" ] || {
        echo "Error: image Nix tree is missing $source_root/store." >&2
        return 1
    }
    mkdir -p "$destination_root"
    cleanup_stale_nix_store_imports "$destination_root"
    stage_root="$(mktemp -d "$destination_root/.dx-store-import-stage.XXXXXX")" || return 1
    staged_contents="$stage_root/contents"
    mkdir "$staged_contents" || { rm -rf "$stage_root"; return 1; }

    echo "Seeding Nix volume from image..."
    if ! { tar -C "$source_root" --owner="$owner_uid" --group="$owner_gid" --numeric-owner -cf - . \
        | tar -C "$staged_contents" -xf -; dx_pipeline_succeeded "${PIPESTATUS[@]}"; }; then
        echo "Error: could not stage the initial Nix volume; no tree was published." >&2
        rm -rf "$stage_root"
        return 1
    fi
    touch "$stage_root/.ready"

    dx_seed_staged_entries "$staged_contents" "$destination_root" || { rm -rf "$stage_root"; return 1; }
    rm -rf "$stage_root"
}

record_durable_nix_identity() {
    local volume_root="$1"
    local persist_home="${DX_PERSIST_HOME:-/persist/home/dx}"
    local nix_identity="" persist_identity="" identity=""
    local nix_identity_safe=false persist_identity_safe=false

    unset DX_NIX_DURABLE_UID DX_NIX_DURABLE_GID DX_NIX_IDENTITY_MIGRATION_REQUIRED
    [ -d "$volume_root/store" ] && nix_identity="$(stat -c '%u:%g' "$volume_root/store" 2>/dev/null || true)"
    [ -d "$persist_home" ] && persist_identity="$(stat -c '%u:%g' "$persist_home" 2>/dev/null || true)"
    [[ "$nix_identity" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] && nix_identity_safe=true
    [[ "$persist_identity" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] && persist_identity_safe=true
    if [ -n "$nix_identity" ] && [ "$nix_identity_safe" != true ]; then
        # Never reuse root/malformed ownership as dx.  A safe persisted
        # identity (if present) remains authoritative; after create_user the
        # whole Nix tree, including DB/big-lock, is migrated exactly once.
        echo "Warning: ignoring unsafe durable Nix identity '$nix_identity'; scheduling Nix-volume migration." >&2
        DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
        export DX_NIX_IDENTITY_MIGRATION_REQUIRED
        nix_identity=""
    fi
    if [ -n "$persist_identity" ] && [ "$persist_identity_safe" != true ]; then
        echo "Warning: ignoring unsafe persisted-home identity '$persist_identity'." >&2
        persist_identity=""
    fi
    if [ -n "$nix_identity" ] && [ -n "$persist_identity" ] && [ "$nix_identity" != "$persist_identity" ]; then
        # The Nix volume is needed before Home Manager and is the source for
        # the guest identity; persistence's own marker-guarded migration will
        # repair its tree once dx exists. Do not turn a recoverable historic
        # mismatch into an unbootable guest.
        echo "Warning: durable Nix identity $nix_identity differs from $persist_home identity $persist_identity; reusing Nix identity and scheduling persisted-home migration." >&2
        DX_PERSIST_IDENTITY_MIGRATION_REQUIRED=true
        export DX_PERSIST_IDENTITY_MIGRATION_REQUIRED
    fi
    identity="${nix_identity:-$persist_identity}"
    if [[ "$identity" =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]]; then
        DX_NIX_DURABLE_UID="${identity%%:*}"
        DX_NIX_DURABLE_GID="${identity##*:}"
        export DX_NIX_DURABLE_UID DX_NIX_DURABLE_GID
        echo "Reusing durable identity $identity for dx."
    fi
}

# This marker is independent of activation.sh's `.dx-owner-layout-v1`, not a
# later version of it. The two record different one-time migrations of the same
# volume: that one records the ownership *layout*, this one records the durable
# *identity* the safe-identity fallback settled on. They are versioned
# separately and neither supersedes the other. `.dx-owner-set` is the shared
# legacy sentinel both publish for older bootstrap generations.
migrate_durable_nix_identity_if_needed() {
    local volume_root="$1"
    local marker="$volume_root/.dx-durable-identity-v1"
    local compat_marker="$volume_root/.dx-owner-set"
    local marker_tmp compat_tmp
    local expected="$(id -u dx):$(id -g dx)"

    [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ] || return 0
    if ! [[ "$expected" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then
        echo "Error: refusing durable Nix ownership migration for unsafe dx identity '$expected'." >&2
        return 1
    fi
    dx_validate_atomic_marker_path "$marker" "durable Nix identity marker" || return 1
    dx_validate_atomic_marker_path "$compat_marker" "durable Nix identity compatibility marker" || return 1
    if [ -f "$marker" ] \
        && [ "$(stat -c '%u:%g' "$marker" 2>/dev/null || true)" = "$expected" ] \
        && grep -qx 'durable-identity=1' "$marker" \
        && grep -qx 'owner=dx:dx' "$marker"; then
        # A prior publish can have completed the versioned marker but been
        # interrupted before the legacy compatibility sentinel. Repair only
        # that tiny sentinel; do not repeat the recursive migration.
        if [ ! -f "$compat_marker" ]; then
            compat_tmp="$(mktemp "$volume_root/.dx-owner-set.tmp.XXXXXX")" || return 1
            if ! chown dx:dx "$compat_tmp" \
                || ! dx_publish_atomic_marker "$compat_tmp" "$compat_marker" "durable Nix identity compatibility marker"; then
                rm -f "$compat_tmp"
                return 1
            fi
        elif [ "$(stat -c '%u:%g' "$compat_marker" 2>/dev/null || true)" != "$expected" ]; then
            chown dx:dx "$compat_marker" || return 1
        fi
        unset DX_NIX_IDENTITY_MIGRATION_REQUIRED
        return 0
    fi
    echo "Migrating durable Nix ownership once for the selected safe dx identity..."
    chown -R dx:dx "$volume_root" || return 1
    marker_tmp="$(mktemp "$volume_root/.dx-durable-identity-v1.tmp.XXXXXX")" || return 1
    compat_tmp="$(mktemp "$volume_root/.dx-owner-set.tmp.XXXXXX")" || { rm -f "$marker_tmp"; return 1; }
    if ! printf 'durable-identity=1\nowner=dx:dx\n' > "$marker_tmp" \
        || ! chown dx:dx "$marker_tmp" "$compat_tmp" \
        || ! dx_publish_atomic_marker "$marker_tmp" "$marker" "durable Nix identity marker" \
        || ! dx_publish_atomic_marker "$compat_tmp" "$compat_marker" "durable Nix identity compatibility marker"; then
        rm -f "$marker_tmp" "$compat_tmp"
        return 1
    fi
    unset DX_NIX_IDENTITY_MIGRATION_REQUIRED
}

# Read the source store database rather than walking the source filesystem.
# Sorting gives a deterministic whole-image identity: a changed /usr/bin/nix
# or sshd target changes the registered path set even if root's profile does not.
# Read the registered set through a read-write store view.  A read-only
# local-store view cannot checkpoint the store database's SQLite write-ahead
# log, so it reports only what was committed when the image was built and omits
# every path install_essentials registered this boot -- the bootstrap
# essentials closure among them.  Importing that stale set copies nothing onto
# a volume that already holds the image-build paths, and the guest then loses
# its toolchain to the /nix remount.
nix_image_registered_paths() {
    if ! { nix --extra-experimental-features 'nix-command flakes' path-info --all | LC_ALL=C sort; dx_pipeline_succeeded "${PIPESTATUS[@]}"; }; then
        return 1
    fi
}

nix_image_store_identity() {
    local paths identity
    paths="$(mktemp "${TMPDIR:-/tmp}/dxe-nix-image-paths.XXXXXX")" || return 1
    if ! nix_image_registered_paths > "$paths" || [ ! -s "$paths" ]; then
        rm -f "$paths"
        echo "Error: could not enumerate registered image Nix paths." >&2
        return 1
    fi
    identity="$(sha256sum < "$paths")" || { rm -f "$paths"; return 1; }
    rm -f "$paths"
    identity="${identity%% *}"
    case "$identity" in *[!0123456789abcdef]*|"") return 1 ;; esac
    printf '%s\n' "$identity"
}

# The resolved root essentials profile is one required boot root, used with
# the registered-set identity above to validate and retain the actual closure.
nix_image_essentials_identity() {
    local source_root="$1"
    local profile="$source_root/var/nix/profiles/per-user/root/profile"
    local resolved

    resolved="$(readlink -f "$profile" 2>/dev/null)" || return 1
    case "$resolved" in "$source_root"/store/*) printf '%s\n' "${resolved##*/}" ;; *) return 1 ;; esac
}

# The official base's default profile supplies the root shell, Nix, and trust
# store before the dx profile exists.  Its `default` link normally goes via a
# generation link (`default-1-link`), which `nix-collect-garbage -d` may remove.
# Keep the resolved store target rather than that disposable generation link.
nix_image_default_profile_store_path() {
    local source_root="$1"
    local nix_root="${DX_NIX_ROOT:-/nix}"
    local profile="$source_root/var/nix/profiles/default"
    local resolved relative

    resolved="$(readlink -f "$profile" 2>/dev/null)" || return 1
    case "$resolved" in
        "$source_root"/store/*) relative="${resolved#"$source_root"/store/}" ;;
        *)
            echo "Error: image default profile does not resolve inside its Nix store." >&2
            return 1
            ;;
    esac
    [ -x "$resolved/bin/sh" ] && [ -x "$resolved/bin/nix" ] \
        && [ -r "$resolved/etc/ssl/certs/ca-bundle.crt" ] || {
        echo "Error: image default profile is missing required shell, Nix, or CA bundle content." >&2
        return 1
    }
    printf '%s\n' "$nix_root/store/$relative"
}

capture_nix_image_default_profile() {
    local source_root="${1:-/nix}"
    local target

    target="$(nix_image_default_profile_store_path "$source_root")" || return 1
    DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET="$target"
    export DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET
}

# Recreate /nix/var/nix/profiles/default as a direct link to the retained
# store path once the durable volume has replaced the image's /nix tree.  Do
# not follow profile-directory links, mutate the store target, or leave a
# half-published link if ownership or rename fails.
nix_restore_image_default_profile() {
    local nix_root="${DX_NIX_ROOT:-/nix}"
    local profiles="$nix_root/var/nix/profiles"
    local target="${DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET:-}"
    local profile="$profiles/default"
    local temporary=""
    local part

    [ -n "$target" ] || {
        echo "Error: no retained image default profile target is available after the /nix remount." >&2
        return 1
    }
    target="$(readlink -f "$target" 2>/dev/null)" || {
        echo "Error: retained image default profile target is unavailable after the /nix remount." >&2
        return 1
    }
    case "$target" in "$nix_root"/store/*) ;; *)
        echo "Error: refusing default profile target outside the mounted Nix store." >&2
        return 1
        ;;
    esac
    [ -x "$target/bin/sh" ] && [ -x "$target/bin/nix" ] \
        && [ -r "$target/etc/ssl/certs/ca-bundle.crt" ] || {
        echo "Error: retained image default profile is incomplete after the /nix remount." >&2
        return 1
    }
    for part in "$nix_root/var" "$nix_root/var/nix" "$profiles"; do
        [ ! -L "$part" ] || {
            echo "Error: refusing to restore the default profile through a symlinked profile directory." >&2
            return 1
        }
    done
    mkdir -p "$profiles" || return 1
    [ ! -e "$profile" ] || [ -L "$profile" ] || {
        echo "Error: refusing to replace a non-symlinked default Nix profile." >&2
        return 1
    }
    temporary="$(mktemp "$profiles/.default.dx.XXXXXX")" || return 1
    rm -f "$temporary"
    if ! ln -s "$target" "$temporary" \
        || ! chown -h dx:dx "$temporary" \
        || ! mv -Tf "$temporary" "$profile"; then
        rm -f "$temporary"
        return 1
    fi
    if [ "$(readlink "$profile" 2>/dev/null || true)" != "$target" ]; then
        echo "Error: default Nix profile restoration did not publish the retained direct target." >&2
        return 1
    fi
}

# These are the pre-SSHD executable roots whose image targets must remain
# registered and GC-live alongside the root essentials profile.  The list is
# intentionally short and explicit; their recursive closures cover libraries.
nix_image_bootstrap_store_paths() {
    local source_root="$1"
    local usr_root="${DX_IMAGE_USR_ROOT:-/usr}"
    local nix_root="${DX_NIX_ROOT:-/nix}"
    local essentials default_profile resolved name

    {
        essentials="$(nix_image_essentials_identity "$source_root" || true)"
        [ -n "$essentials" ] && printf '%s\n' "/nix/store/$essentials"
        default_profile="${DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET:-$(nix_image_default_profile_store_path "$source_root" || true)}"
        case "$default_profile" in
            "$nix_root"/store/*) printf '%s\n' "/nix/store/${default_profile#"$nix_root"/store/}" ;;
        esac
        for name in bash nix nix-store sshd ssh-keygen; do
            resolved="$(readlink -f "$usr_root/bin/$name" 2>/dev/null || true)"
            case "$resolved" in /nix/store/*) printf '%s\n' "$resolved" ;; esac
        done
    } | LC_ALL=C sort -u
}

# The remount replaces /nix wholesale, so every path the bootstrap is about to
# exec must physically exist on the volume first.  Checking presence here turns
# a silent brick -- "mkdir: No such file or directory" from a dead PATH after
# the remount -- into an actionable failure while the image store is still
# readable.
nix_verify_imported_bootstrap_paths() {
    local destination_root="$1"
    local source_root="${2:-/nix}"
    local path missing="" remaining entry

    while IFS= read -r path; do [ -n "$path" ] || continue; [ -e "$destination_root/store/${path#/nix/store/}" ] || missing="$missing $path"; done < <(nix_image_bootstrap_store_paths "$source_root")

    # PATH is set from the *resolved* essentials bin directories, which
    # readlink -f follows into the derivation output rather than leaving at the
    # profile root.  Those outputs are what the next command execs, so check
    # them by name as well; a closure member can be skipped by the copy while
    # the profile root it belongs to is published.
    remaining="$(essentials_profile_path 2>/dev/null || true)"
    while [ -n "$remaining" ]; do
        entry="${remaining%%:*}"
        case "$remaining" in *:*) remaining="${remaining#*:}" ;; *) remaining="" ;; esac
        case "$entry" in /nix/store/*) ;; *) continue ;; esac
        path="${entry#/nix/store/}"
        path="/nix/store/${path%%/*}"
        case " $missing " in *" $path "*) continue ;; esac
        [ -e "$destination_root/store/${path#/nix/store/}" ] || missing="$missing $path"
    done

    [ -z "$missing" ] || {
        echo "Error: the image store import did not materialise required bootstrap paths on the Nix volume:$missing" >&2
        return 1
    }
}

nix_target_store_uri() {
    local destination_root="$1"
    printf '%s\n' "local?store=/nix/store&real=$destination_root/store&state=$destination_root/var/nix&log=$destination_root/var/log/nix"
}

nix_image_store_import_required() {
    local source_root="$1"
    local destination_root="$2"
    local identity marker target_store roots="" root

    identity="$(nix_image_store_identity)" || return 0
    while IFS= read -r root; do roots="$roots $(printf '%q' "$root")"; done < <(nix_image_bootstrap_store_paths "$source_root")
    [ -n "$roots" ] || return 0
    marker="$destination_root/.dx-image-store-identity"
    if ! dx_validate_atomic_marker_path "$marker" "image store identity marker"; then
        DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$identity"
        export DX_NIX_PENDING_IMAGE_STORE_IDENTITY
        return 0
    fi
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$identity" ]; then
        target_store="$(nix_target_store_uri "$destination_root")"
        if run_as_dx "nix --extra-experimental-features 'nix-command flakes' store verify --store '$target_store' --recursive --no-trust$roots" >/dev/null 2>&1; then
            return 1
        fi
    fi
    DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$identity"
    export DX_NIX_PENDING_IMAGE_STORE_IDENTITY
    return 0
}

# This marker is deliberately published only after ensure_essentials_valid has
# verified the remounted target closure. Keep the old ownership sentinel
# separate so a stale bootstrap generation remains compatible.
publish_nix_image_store_identity() {
    local destination_root="${1:-/nix}"
    local marker="$destination_root/.dx-image-store-identity"
    local temporary=""

    [ -n "${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-}" ] || return 0
    temporary="$(mktemp "$destination_root/.dx-image-store-identity.XXXXXX")" || return 1
    printf '%s\n' "$DX_NIX_PENDING_IMAGE_STORE_IDENTITY" > "$temporary"
    if ! chown dx:dx "$temporary" \
        || ! dx_publish_atomic_marker "$temporary" "$marker" "image store identity marker"; then
        rm -f "$temporary"
        return 1
    fi
    unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY
}

populate_prepared_nix_volume() {
    local owner_uid owner_gid import_started
    local volume_root="${DX_NIX_VOLUME_ROOT:?Nix volume was not prepared}"

    if [ "${DX_NIX_VOLUME_ALREADY_MOUNTED:-false}" = true ]; then
        return 0
    fi
    # The production order creates dx between prepare and populate.  Retain a
    # root fallback for sourceable mount probes, which deliberately exercise
    # this compatibility wrapper without materialising system accounts.
    owner_uid="$(id -u dx 2>/dev/null || printf '%s' 0)"
    owner_gid="$(id -g dx 2>/dev/null || printf '%s' 0)"
    migrate_durable_nix_identity_if_needed "$volume_root"
    import_started=$SECONDS
    if [ ! -d "$volume_root/store" ]; then
        DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$(nix_image_store_identity 2>/dev/null || true)"
        export DX_NIX_PENDING_IMAGE_STORE_IDENTITY
        nix_seed_volume /nix "$volume_root" "$owner_uid" "$owner_gid"
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    elif nix_image_store_import_required /nix "$volume_root"; then
        nix_store_import_registered "$volume_root" "$owner_uid" "$owner_gid"
    else
        echo "Image Nix essentials identity is unchanged; skipping image-store import."
        # Re-publish roots even for a matching image marker. This is bounded
        # crash recovery for an interruption during a prior root refresh.
        nix_install_image_essentials_root "$volume_root" "$owner_uid" "$owner_gid"
    fi
    echo "Nix volume image import completed in $((SECONDS - import_started))s."

    umount "$volume_root"
    mount -t "$DX_NIX_VOLUME_FS_TYPE" -o "$DX_NIX_VOLUME_MOUNT_OPTS" "$DX_NIX_VOLUME_DEVICE" /nix

    if ! grep -q "/nix $DX_NIX_VOLUME_FS_TYPE" /etc/fstab 2>/dev/null; then
        echo "Adding /nix to /etc/fstab..."
        if blkid -L dx-nix >/dev/null 2>&1; then
            echo "LABEL=dx-nix /nix $DX_NIX_VOLUME_FS_TYPE $DX_NIX_VOLUME_MOUNT_OPTS 0 0" >> /etc/fstab
        else
            echo "$DX_NIX_VOLUME_DEVICE /nix $DX_NIX_VOLUME_FS_TYPE $DX_NIX_VOLUME_MOUNT_OPTS 0 0" >> /etc/fstab
        fi
    fi
}

# §2: Setup dedicated Nix volume.
#
# Apple Container mounts the dx-nix named volume at /var/lib/dx-nix-raw with
# its own (small, runtime-managed) filesystem. We re-format that backing
# block device with btrfs/ext4 and mount it at /nix so the Nix store has
# room to grow and survives container rebuilds. This requires CAP_SYS_ADMIN
# inside the guest, which dx-create-container grants via --cap-add.
prepare_nix_volume_impl() {
    echo "Setting up dedicated Nix volume..."
    local raw_path="/var/lib/dx-nix-raw"
    local dev=""
    local fs_type="btrfs"
    local mount_opts="compress=zstd:3,noatime,space_cache=v2,discard=async"

    # Check kernel support for btrfs
    if ! grep -q "btrfs" /proc/filesystems; then
        echo "Warning: Kernel does not support btrfs. Falling back to ext4."
        fs_type="ext4"
        mount_opts="noatime,errors=remount-ro"
    fi

    # Check if /nix is already mounted with the desired filesystem
    if findmnt -n -o TARGET,FSTYPE /nix | grep -q "$fs_type"; then
        echo "/nix is already a $fs_type mount. Skipping setup."
        DX_NIX_VOLUME_ALREADY_MOUNTED=true
        DX_NIX_VOLUME_ROOT=/nix
        record_durable_nix_identity /nix
        return 0
    fi

    if [ ! -d "$raw_path" ]; then
        echo "Warning: $raw_path not found. Skipping dedicated volume setup."
        DX_NIX_VOLUME_ALREADY_MOUNTED=true
        DX_NIX_VOLUME_ROOT=/nix
        return 0
    fi

    # Detect whether it's a block device or directory
    local backing_dev
    backing_dev=$(findmnt -n -o SOURCE "$raw_path" || true)

    if is_block_device "$backing_dev"; then
        echo "Detected block device backing $raw_path: $backing_dev"
        dev="$backing_dev"
        # mkfs idempotent: skip if blkid -L dx-nix already resolves
        if ! blkid -L dx-nix >/dev/null 2>&1; then
            echo "Formatting $dev with $fs_type..."
            if ! umount "$raw_path" 2>/dev/null; then
                echo "Error: failed to umount $raw_path. The container is missing CAP_SYS_ADMIN; re-create it with ./bin/dx-destroy && ./bin/dx (dx-create-container adds the capability)." >&2
                return 1
            fi
            if [ "$fs_type" == "btrfs" ]; then
                mkfs.btrfs -f -L dx-nix -m single -d single "$dev"
            else
                mkfs.ext4 -F -L dx-nix "$dev"
            fi
        fi
    else
        echo "Detected directory-style mount at $raw_path. Using sparse image file."
        dev="$raw_path/nix-store.$fs_type"
        if [ ! -f "$dev" ]; then
            echo "Creating 64G sparse image file at $dev..."
            truncate -s 64G "$dev"
            if [ "$fs_type" == "btrfs" ]; then
                mkfs.btrfs -f -L dx-nix -m single -d single "$dev"
            else
                mkfs.ext4 -F -L dx-nix "$dev"
            fi
        fi
    fi

    # Mount the volume
    echo "Mounting $dev to /nix..."
    mkdir -p /mnt/tmp-nix
    mount -t "$fs_type" -o "$mount_opts" "$dev" /mnt/tmp-nix
    DX_NIX_VOLUME_ALREADY_MOUNTED=false
    DX_NIX_VOLUME_ROOT=/mnt/tmp-nix
    DX_NIX_VOLUME_DEVICE="$dev"
    DX_NIX_VOLUME_FS_TYPE="$fs_type"
    DX_NIX_VOLUME_MOUNT_OPTS="$mount_opts"
    export DX_NIX_VOLUME_ALREADY_MOUNTED DX_NIX_VOLUME_ROOT DX_NIX_VOLUME_DEVICE DX_NIX_VOLUME_FS_TYPE DX_NIX_VOLUME_MOUNT_OPTS
    record_durable_nix_identity /mnt/tmp-nix
}

prepare_nix_volume() {
    local phase_started=$SECONDS
    local status
    if prepare_nix_volume_impl "$@"; then
        echo "Bootstrap phase: Nix volume prepare/mount completed in $((SECONDS - phase_started))s."
        return 0
    else
        status=$?
    fi
    echo "Bootstrap phase: Nix volume prepare/mount failed after $((SECONDS - phase_started))s (exit $status)." >&2
    return "$status"
}

# Compatibility seam for direct callers: normal bootstrap uses the explicit
# prepare/create-user/populate sequence above, while this retains the former
# one-call contract for sourceable probes and maintenance callers.
setup_nix_volume_impl() {
    prepare_nix_volume_impl "$@" && populate_prepared_nix_volume
}

setup_nix_volume() {
    local phase_started=$SECONDS status
    if setup_nix_volume_impl "$@"; then
        echo "Bootstrap phase: Nix volume prepare/mount completed in $((SECONDS - phase_started))s."
        return 0
    else
        status=$?
    fi
    echo "Bootstrap phase: Nix volume prepare/mount failed after $((SECONDS - phase_started))s (exit $status)." >&2
    return "$status"
}

# §3: Direct single-user Nix configuration (no daemon is started).
configure_single_user_nix() {
    echo "Configuring direct single-user Nix..."
    mkdir -p /etc/nix
    # build-users-group is cleared because the store is single-user (owned by
    # dx, §7); a root-invoked nix would otherwise re-own /nix/store to
    # root:nixbld and lock dx out.
    cat > /etc/nix/nix.conf <<EOF
auto-optimise-store = true
min-free = 1073741824
max-free = 5368709120
experimental-features = nix-command flakes
build-users-group =
EOF
}
