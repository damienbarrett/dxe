#!/usr/bin/env bash
# Source-only bootstrap persistence phase. Safe to source.

# Mutable guest data is durable, so recursively repairing its ownership on
# every start makes bootstrap time grow with the user's history.  New trees
# are created with their intended owner and old trees are migrated once.  The
# marker lives beside the data it protects and is published only after the
# migration succeeds, so an interrupted migration is retried safely.
if ! declare -F dx_validate_atomic_marker_path >/dev/null; then
    # A few direct behavior tests source this phase by itself. Production
    # bootstrap sources common.sh first; load that same shared contract for
    # standalone callers without duplicating its safety-critical helpers.
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# Fable B9: setup_gh_persistence/setup_herdr_persistence's migrate/backup-
# conflicts/link logic is scripts/lib/dx-persist-relocate.sh's shared
# dx_persist_relocate_dir. Unlike dx-ai.sh/dx-keyring.sh, this bootstrap
# phase is never packaged as a Home Manager home.file -- it only ever runs
# from the bootstrap volume, alongside scripts/lib as a fixed sibling -- so
# a single sibling-relative source, not the full three-candidate loader, is
# enough here.
if ! declare -F dx_persist_relocate_dir >/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/dx-persist-relocate.sh"
fi

dx_ensure_tree_owner() {
    local target="$1"
    local marker="$2"
    local description="$3"
    local marker_tmp
    local started=$SECONDS
    local expected_owner
    local marker_owner

    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -d "$target" ]; }; then
        echo "Error: refusing ownership migration for $description: $target is not a directory." >&2
        return 1
    fi
    dx_validate_atomic_marker_path "$marker" "$description ownership marker" || return 1

    if [ -d "$target" ]; then
        if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
            chown dx:dx "$target" || return 1
        fi
    elif id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
        install -d -o dx -g dx -m 0755 "$target" || return 1
    else
        # Sourceable behavior tests run on hosts without the guest account.
        # Production always reaches this branch after create_user.
        mkdir -p "$target" || return 1
    fi
    if [ ! -d "$target" ]; then
        if id -u dx >/dev/null 2>&1; then
            echo "Error: could not create $description directory $target." >&2
            return 1
        fi
        # A sourceable test may intentionally stub mkdir while exercising a
        # later branch. There is no guest account or writable target to
        # migrate in that harness.
        return 0
    fi
    if [ -f "$marker" ]; then
        expected_owner="$(id -u dx):$(id -g dx)"
        marker_owner="$(stat -c '%u:%g' "$marker" 2>/dev/null || stat -f '%u:%g' "$marker" 2>/dev/null || true)"
        if [ "$marker_owner" = "$expected_owner" ] \
            && grep -q '^ownership-layout=1$' "$marker" \
            && grep -q '^owner=dx:dx$' "$marker"; then
            echo "Bootstrap phase: $description ownership already verified (0s)."
            return 0
        fi
        echo "Warning: $description ownership marker is stale; repeating its bounded migration."
    fi

    echo "Migrating legacy $description ownership (one time)..."
    # This is intentionally the only recursive ownership operation for the
    # target.  It is marker-guarded and therefore does not run on normal boots.
    chown -R dx:dx "$target" || return 1
    marker_tmp="$marker.tmp.$$"
    if ! printf 'ownership-layout=1\nowner=dx:dx\n' > "$marker_tmp" \
        || ! chown dx:dx "$marker_tmp" \
        || ! chmod 0600 "$marker_tmp" \
        || ! dx_publish_atomic_marker "$marker_tmp" "$marker" "$description ownership marker"; then
        rm -f "$marker_tmp"
        return 1
    fi
    echo "Bootstrap phase: $description ownership migration completed in $((SECONDS - started))s."
}

dx_prepare_owned_directory() {
    local directory="$1"
    local mode="${2:-0755}"
    if [ -L "$directory" ]; then
        echo "Error: refusing to create owned directory through symlink: $directory" >&2
        return 1
    fi
    if [ -d "$directory" ]; then
        if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
            chown dx:dx "$directory" || return 1
        fi
        chmod "$mode" "$directory" || return 1
    elif id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
        install -d -o dx -g dx -m "$mode" "$directory"
    else
        mkdir -p "$directory"
    fi
    if [ ! -d "$directory" ] && id -u dx >/dev/null 2>&1; then
        echo "Error: could not create owned directory $directory." >&2
        return 1
    fi
}

setup_persist() {
    local persist_root="${1:-/persist}"
    if [ -L "$persist_root" ]; then
        echo "Error: refusing to prepare persisted storage through symlink: $persist_root" >&2
        return 1
    fi
    if [ -d "$persist_root" ]; then
        chown dx:dx "$persist_root"
        chmod 0755 "$persist_root"
        install -d -o dx -g dx -m 0755 "$persist_root/home" "$persist_root/home/dx"
        dx_ensure_tree_owner "$persist_root/home/dx" "$persist_root/home/dx/.dxe-owner-v1" "persisted guest home" || return 1
        # The persisted home is shared by Home Manager and optional tools.
        # Establish only the bounded XDG root here, while the volume is still
        # fresh, so later root-run setup cannot leave it inaccessible to dx.
        # dx_prepare_owned_directory rejects a symlink and changes no child
        # ownership, preserving the marker-based no-recursive-chown design.
        dx_prepare_owned_directory "$persist_root/home/dx/.local" 0755 || return 1
        dx_prepare_owned_directory "$persist_root/home/dx/.local/state" 0755 || return 1
        dx_prepare_owned_directory "$persist_root/home/dx/.local/share" 0755 || return 1
    fi
}

# 3. Configure SSH (Section 4)
#
# Fable B9: the migrate/backup-conflicts/link shape below is now
# scripts/lib/dx-persist-relocate.sh's shared dx_persist_relocate_dir --
# see setup_herdr_persistence and dx-ai's own dx_ai_setup_credentials/
# activation.sh's AI-credential setup for its other call sites.
setup_gh_persistence() {
    local persist_home="${1:-/persist/home/dx}"
    local home="${2:-/home/dx}"
    local persistent_config_dir="$persist_home/.config"
    local persistent_gh="$persistent_config_dir/gh"
    local home_config_dir="$home/.config"
    local home_gh="$home_config_dir/gh"

    dx_ensure_tree_owner "$persist_home" "$persist_home/.dxe-owner-v1" "persisted guest home" || return 1
    dx_prepare_owned_directory "$persistent_config_dir" 0755 || return 1
    dx_prepare_owned_directory "$home_config_dir" 0755 || return 1

    dx_persist_relocate_dir "$home_gh" "$persistent_gh" "$persistent_config_dir" gh 1 || return 1
    chown dx:dx "$home_config_dir" "$persistent_gh" || return 1
}

# Persist tmux-resurrect save data across container rebuilds. /persist is a
# runtime mount, so Home Manager cannot create this directory declaratively;
# home/tools.nix points resurrect at it via @resurrect-dir. install -d sets
# ownership on the directories it creates regardless of the later recursive
# chowns over /persist/home/dx.
setup_tmux_persistence() {
    install -d -o dx -g dx -m 0755 /persist/home/dx/.local/share/tmux/resurrect
}

# Persist herdr configuration, sessions, history, and state across container
# rebuilds. Takes the persistent and home base directories as optional
# parameters (defaulting to the real guest paths) purely so behavior tests can
# drive this function against a disposable fixture tree instead of the real
# host filesystem; production callers always invoke it with zero arguments.
#
# F5/R1: both persistent targets, their home-/persist-side parents, and their
# user-controlled ancestors are rejected with `[ -L ... ]` *before* any
# mutation if any of them is a
# symlink. `-d` dereferences, so without this a symlink-to-directory would
# have passed the old "is it a real directory" guard, and root would then
# `mkdir -p`/`chown -R`/`chmod 0700` (and later seed config.toml) straight
# through it to wherever it points. `home_config`/`home_state` are
# deliberately excluded from that reject list: being a symlink there is the
# normal steady state this function itself creates on a successful run, and
# is handled explicitly below rather than rejected.
setup_herdr_persistence() {
    local persist_home="${1:-/persist/home/dx}"
    local home="${2:-/home/dx}"
    local persist_home_parent="${persist_home%/*}"
    local persist_mount="${persist_home_parent%/*}"
    local persistent_config="$persist_home/.config/herdr"
    local persistent_state="$persist_home/.local/state/herdr"
    local home_config="$home/.config/herdr"
    local home_state="$home/.local/state/herdr"
    local persistent_config_parent="$persist_home/.config"
    local persistent_state_parent="$persist_home/.local/state"
    local home_config_parent="$home/.config"
    local home_state_parent="$home/.local/state"
    local ready_marker="$persistent_config/.dxe-persistence-ready"
    local unsafe_path=""

    for unsafe_path in \
        "$persist_mount" "$persist_home_parent" \
        "$persist_home" "$persist_home/.local" \
        "$home" "$home/.local" \
        "$persistent_config_parent" "$persistent_state_parent" \
        "$home_config_parent" "$home_state_parent" \
        "$persistent_config" "$persistent_state"
    do
        if [ -L "$unsafe_path" ]; then
            echo "Error: refusing to activate Herdr persistence: $unsafe_path is a symlink, not the directory it must be. Remove it manually and re-run bootstrap." >&2
            return 1
        fi
    done
    dx_validate_atomic_marker_path "$ready_marker" "Herdr persistence readiness marker" || return 1

    # setup_persist normally publishes this marker before activation.  Keep
    # the call here as a safe seam for direct recovery/re-entry, but it is a
    # no-op on ordinary boots and never rewalks the persisted home tree.
    dx_ensure_tree_owner "$persist_home" "$persist_home/.dxe-owner-v1" "persisted guest home" || return 1

    # Invalidate a prior successful activation only after every persistent
    # component has been proven non-symlinked. In particular, do not touch a
    # marker through a hostile persistent_config symlink. When the config
    # target is absent or a regular file there is no directory to traverse;
    # any marker is necessarily absent and the config migration below handles
    # that target first.
    if [ -d "$persistent_config" ]; then
        rm -f "$ready_marker" || return 1
    fi

    # Home-side parents may already exist (setup_gh_persistence, which runs
    # before Herdr activation in configure_guest, already creates and chowns
    # ~/.config) or may not (nothing creates ~/.local/state before this on a
    # fresh guest). Record which is which *before* mkdir -p so the mode
    # change below can be scoped correctly.
    local home_config_parent_created=1
    local home_state_parent_created=1
    [ ! -d "$home_config_parent" ] || home_config_parent_created=0
    [ ! -d "$home_state_parent" ] || home_state_parent_created=0

    # `mkdir -p .../.local/state` also creates the intermediate ~/.local, and
    # it creates it as root just like the leaf. Track it separately: chowning
    # only the leaves leaves ~/.local root-owned, and Home Manager then runs as
    # dx and cannot mkdir ~/.local/share.
    local home_local_parent="${home_state_parent%/*}"

    mkdir -p "$persistent_config_parent" "$persistent_state_parent" "$home_config_parent" "$home_state_parent" || return 1

    # Live defect: mkdir -p above runs as root, so a freshly created
    # home-side parent is root-owned; the later `run_as_dx "ln -sfnT ..."`
    # calls below then fail with "Permission denied" (observed live on a
    # fresh dx-recreate). The original Herdr implementation plan (removed;
    # see Git history) requires both persistent targets *and* their
    # home-side parents to be dx:dx -- only the persistent side was
    # implemented.
    # Ownership is repaired unconditionally (idempotent either way). Mode
    # 0700 is applied only to a parent this call actually created: ~/.config
    # in particular is shared with other tools (gh, Home Manager, ...), and
    # forcing it private here would clobber a pre-existing, intentionally
    # shared mode out from under them.
    chown dx:dx "$home_config_parent" "$home_state_parent" "$home_local_parent" || return 1
    # Deliberately no chmod on ~/.local: unlike the leaves, it is a shared
    # XDG root (Home Manager's ~/.local/share and ~/.local/bin, the Nix
    # profile under ~/.local/state/nix), so forcing it private would break
    # tools that legitimately expect the default mode.
    if [ "$home_config_parent_created" -eq 1 ]; then
        chmod 0700 "$home_config_parent" || return 1
    fi
    if [ "$home_state_parent_created" -eq 1 ]; then
        chmod 0700 "$home_state_parent" || return 1
    fi

    # 1. Config directory persistence. Fable B9: the migrate/backup-conflicts
    # shape (formerly duplicated here and in "2." below, byte-identical apart
    # from names) is now scripts/lib/dx-persist-relocate.sh's shared
    # dx_persist_prepare_relocate_target/dx_persist_migrate_live_path; the
    # marker recheck below needs a seam between migration and publishing the
    # symlink, so this call site uses those two (and dx_persist_publish_link)
    # directly rather than the combined dx_persist_relocate_dir convenience
    # wrapper "2." uses.
    dx_persist_prepare_relocate_target "$persistent_config" "$persistent_config_parent" herdr-config || return 1
    dx_persist_migrate_live_path "$home_config" "$persistent_config" "$persistent_config_parent" herdr-config || return 1

    # The config target might have been created above or populated by moving
    # an existing home directory. Re-check its marker after that migration:
    # an old/user-supplied marker must not survive into a later state-side
    # failure and falsely advertise a complete activation.
    if ! [ -d "$persistent_config" ] || [ -L "$persistent_config" ]; then
        echo "Error: Herdr persistent config target did not become a real directory." >&2
        return 1
    fi
    dx_validate_atomic_marker_path "$ready_marker" "Herdr persistence readiness marker" || return 1
    rm -f "$ready_marker" || return 1
    dx_persist_publish_link "$persistent_config" "$home_config" 1 || return 1

    # 2. State directory persistence
    dx_persist_relocate_dir "$home_state" "$persistent_state" "$persistent_state_parent" herdr-state 1 || return 1
}
