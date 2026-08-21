#!/usr/bin/env bash
# Source-only bootstrap system phase. Safe to source.

# Temporary old-base guard retained until the operational gate in
# docs/refactor/migration-gates.md is signed off for every side container and
# named profile. The official base never provides /bin/bash at this path.
guard_old_base() {
    local bash_path="${DX_GUARD_ROOT:-}/bin/bash"

    if [ -e "$bash_path" ] || [ -L "$bash_path" ]; then
        echo "Error: $bash_path is present, matching the known flakes-base signature (nixpkgs/nix-flakes)." >&2
        echo "This container was built from the old flakes base and must be rebuilt under the official base." >&2
        echo "Follow the Base Image Changeover procedure in docs/release-maintenance.md before retrying." >&2
        return 1
    fi
}

# Root's freshly installed essentials land in whichever profile this Nix
# picks: the official base creates /nix/var/nix/profiles/per-user/root/profile
# (not on the image PATH), while other layouts use the XDG state dir or the
# legacy ~/.nix-profile link. Resolve every candidate that exists to its
# concrete /nix/store path -- setup_nix_volume (§2) remounts the persistent
# volume over /nix, replacing /nix/var, so profile symlinks dangle afterwards
# while resolved store paths survive the pre-remount store merge.
# /etc/os-release is world-readable by specification, and unprivileged guest
# tooling reads it. The mode is set explicitly rather than inherited from the
# ambient umask: `cat >` leaves an existing file's mode untouched, so a guest
# that was once written under a restrictive umask would otherwise keep an
# unreadable file forever.
write_release_identity() {
    local target="$1" release="$2"

    cat > "$target" <<EOF
NAME="NixOS"
ID=nixos
VERSION="$release"
VERSION_ID="$release"
PRETTY_NAME="NixOS $release (DX guest)"
HOME_URL="https://nixos.org/"
EOF
    chmod 0644 "$target"
}

configure_release_identity() {
    local release

    release="$(sed -n 's#^[[:space:]]*nixpkgs\.url[[:space:]]*=[[:space:]]*"github:nixos/nixpkgs/nixos-\([^"]*\)";.*#\1#p' "$DX_BOOTSTRAP_ROOT/flake.nix" | head -1)"
    case "$release" in
        ''|*[!0-9.]*)
            echo "Error: could not derive a numeric NixOS release from $DX_BOOTSTRAP_ROOT/flake.nix." >&2
            return 1
            ;;
    esac

    write_release_identity /etc/os-release "$release"
}

# §4: Configure timezone
resolve_timezone_file() {
    local timezone="$1"
    local candidate=""
    local tz_dir=""
    local find_bin=""

    for candidate in /home/dx/.nix-profile/bin/find /root/.nix-profile/bin/find /usr/bin/find /bin/find; do
        if [ -x "$candidate" ]; then
            find_bin="$candidate"
            break
        fi
    done

    if [ -n "$find_bin" ]; then
        candidate="$("$find_bin" /nix/store -path "*/share/zoneinfo/$timezone" -type f -print -quit 2>/dev/null || true)"
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    candidate="/home/dx/.nix-profile/share/zoneinfo/$timezone"
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    tz_dir="$(run_as_dx 'printf %s "${TZDIR:-}"' || true)"
    if [ -n "$tz_dir" ]; then
        candidate="$tz_dir/$timezone"
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    return 1
}

configure_timezone() {
    if [ -n "${HOST_TZ:-}" ]; then
        echo "Configuring timezone to $HOST_TZ..."
        local tz_file
        tz_file="$(resolve_timezone_file "$HOST_TZ" || true)"
        if [ -f "$tz_file" ]; then
            ln -sf "$tz_file" /etc/localtime
            printf '%s\n' "$HOST_TZ" > /etc/timezone
        else
            echo "Warning: Timezone file for $HOST_TZ not found. Is tzdata in dxPackages?"
        fi
    fi
}

# The official base ships /etc/passwd, /etc/group, and /etc/shadow as
# symlinks into the read-only base-system store path. shadow-utils open
# these files with O_NOFOLLOW (ELOOP on any symlink) and rewrite them in
# place, so user management needs them to be regular, writable files.
# Copy each symlinked file's content into place; regular or absent files
# are left untouched.
materialize_auth_files() {
    local root="${DX_AUTH_ROOT:-}"
    local name file tmp
    for name in passwd group shadow gshadow; do
        file="$root/etc/$name"
        [ -L "$file" ] || continue
        tmp="$(mktemp)"
        # The symlink is expected to point at a real, readable store target.
        # If the copy fails (dangling symlink, or a target that is missing or
        # unreadable -- e.g. an unregistered store path), do NOT paper over it
        # with an empty file: an empty passwd/group/shadow wipes the root
        # account and breaks sudo/login, which is never a safe outcome. Fail
        # loudly and leave the original symlink in place.
        if ! cp "$file" "$tmp"; then
            echo "ERROR: materialize_auth_files: failed to copy $file (symlink target missing or unreadable); refusing to replace it with an empty file" >&2
            rm -f "$tmp"
            return 1
        fi
        rm "$file"
        mv "$tmp" "$file"
        case "$name" in
            shadow|gshadow) chmod 0600 "$file" ;;
            *) chmod 0644 "$file" ;;
        esac
    done
}

# The bootstrap essentials deliberately do not include getent.  These files
# have just been materialized above, so use them as the authoritative local
# identity database rather than introducing another early-boot dependency.
# Print every name using the requested numeric UID/GID; multiple entries are
# treated as unsafe by create_user rather than silently selecting one.
auth_entries_with_numeric_id() {
    local database="$1" numeric_id="$2"
    local auth_root="${DX_AUTH_ROOT:-}" auth_file name password entry_id remainder

    auth_file="$auth_root/etc/$database"
    if [ ! -r "$auth_file" ]; then
        echo "Error: cannot inspect materialized $auth_file for durable Nix identity conflicts." >&2
        return 1
    fi
    while IFS=: read -r name password entry_id remainder; do [ "$entry_id" = "$numeric_id" ] && printf '%s\n' "$name"; done < "$auth_file"
    return 0
}

# 2. Create non-root guest user (Section 3)
create_user() {
    if id -u dx >/dev/null 2>&1; then
        if [ -n "${DX_NIX_DURABLE_UID:-}" ] && [ -n "${DX_NIX_DURABLE_GID:-}" ] \
            && { [ "$(id -u dx)" != "$DX_NIX_DURABLE_UID" ] || [ "$(id -g dx)" != "$DX_NIX_DURABLE_GID" ]; }; then
            echo "Warning: existing dx identity $(id -u dx):$(id -g dx) conflicts with durable identity $DX_NIX_DURABLE_UID:$DX_NIX_DURABLE_GID; keeping the safe existing identity and scheduling one migration." >&2
            DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
            export DX_NIX_IDENTITY_MIGRATION_REQUIRED
        fi
    else
        echo "Creating user dx..."
        if [ -n "${DX_NIX_DURABLE_UID:-}" ] && [ -n "${DX_NIX_DURABLE_GID:-}" ]; then
            echo "Creating dx with durable Nix UID:GID $DX_NIX_DURABLE_UID:$DX_NIX_DURABLE_GID..."
            local existing_user existing_group
            if existing_user="$(auth_entries_with_numeric_id passwd "$DX_NIX_DURABLE_UID")" \
                && existing_group="$(auth_entries_with_numeric_id group "$DX_NIX_DURABLE_GID")" \
                && { [ -z "$existing_user" ] || [ "$existing_user" = dx ]; } \
                && { [ -z "$existing_group" ] || [ "$existing_group" = dx ]; }; then
                # The durable group may have survived without its user (for
                # example after an interrupted auth-file restore).  Reuse it
                # instead of asking groupadd to recreate an existing GID.
                if [ -z "$existing_group" ]; then
                    groupadd -g "$DX_NIX_DURABLE_GID" dx
                fi
                useradd -m -u "$DX_NIX_DURABLE_UID" -g dx -s /bin/sh dx
            else
                echo "Warning: durable Nix UID/GID is unavailable or occupied; allocating a safe dx identity and scheduling one migration." >&2
                DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
                export DX_NIX_IDENTITY_MIGRATION_REQUIRED
                groupadd -f dx
                useradd -m -g dx -s /bin/sh dx
            fi
        else
            groupadd -f dx
            useradd -m -g dx -s /bin/sh dx
        fi
        # Unlock the account for SSH access
        usermod -p '*' dx
    fi

    # Configure sudo (Section 3)
    mkdir -p /etc/sudoers.d
    if [ ! -f /etc/sudoers.d/dx ]; then
        echo "dx ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dx
        chmod 440 /etc/sudoers.d/dx
    fi

    if [ ! -f /etc/sudoers ]; then
        echo "root ALL=(ALL) ALL" > /etc/sudoers
        echo "@includedir /etc/sudoers.d" >> /etc/sudoers
        chmod 440 /etc/sudoers
    fi
}

# SSH host identity must outlive the ephemeral rootfs.  /etc/ssh is rebuilt with
# the container, so without a persisted copy the guest gets a new host key on
# every recreate, and a persistent OpenSSH-closure fault re-runs key generation
# on every boot instead of restoring a key that already worked.  Note that
# dx-ssh pins nothing (StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null),
# so the churn is invisible through the normal path; it surfaces on a direct
# ssh to the forwarded port.
#
# setup_persist hands /persist to dx, so dx can rename a directory it does not
# own out of the way and leave its own in that place.  Host *private* keys
# therefore live in a root-owned 0700 store that is trusted only while it still
# is one.  An untrusted store is neither restored from (it would hand dx control
# of the guest's host identity) nor written to (it would leak the private key
# into a dx-readable directory).
dx_host_key_store_trusted() {
    local store="$1"
    local owner
    [ -d "$store" ] || return 1
    owner="$(stat -c '%u:%g' "$store" 2>/dev/null || stat -f '%u:%g' "$store" 2>/dev/null || true)"
    if [ "${owner%%:*}" != 0 ]; then
        echo "Warning: persisted host-key store $store is not root-owned; refusing to use it for the guest identity." >&2
        return 1
    fi
}

dx_host_key_store_populated() {
    local store="$1"
    local key
    for key in "$store"/ssh_host_*_key; do
        [ -f "$key" ] && return 0
    done
    return 1
}

# Private keys 0600, public keys 0644.  A persisted copy with looser modes
# would make sshd refuse to start, which is a boot failure rather than a
# warning, so the modes are re-asserted after every restore and backfill.
dx_harden_host_keys() {
    local directory="$1"
    local key
    for key in "$directory"/ssh_host_*; do
        [ -f "$key" ] || continue
        case "$key" in
            *.pub) chmod 0644 "$key" || return 1 ;;
            *) chmod 0600 "$key" || return 1 ;;
        esac
    done
}

dx_persist_host_keys() {
    local etc_ssh="${1:-/etc/ssh}"
    local store="${2:-/persist/etc/ssh}"
    local persist_root="${3:-}"
    local store_parent store_usable=false
    store_parent="$(dirname "$store")"
    [ -n "$persist_root" ] || persist_root="$(dirname "$store_parent")"

    if [ -L "$etc_ssh" ]; then
        echo "Error: refusing to configure host keys through symlink: $etc_ssh" >&2
        return 1
    fi
    if [ -L "$store" ] || [ -L "$store_parent" ]; then
        echo "Error: refusing to persist host keys through symlink: $store" >&2
        return 1
    fi

    mkdir -p "$etc_ssh" || return 1

    # No persist volume mounted: the guest must still boot, just without a
    # durable identity.
    if [ -d "$persist_root" ]; then
        # Create the store only when it is absent.  Never chown an existing
        # store into trust: if dx substituted a directory it owns, normalising
        # ownership here would launder it into the guest's host identity.
        if [ ! -e "$store" ]; then
            install -d -o root -g root -m 0700 "$store_parent" "$store" || return 1
        fi
        if dx_host_key_store_trusted "$store"; then
            store_usable=true
            chmod 0700 "$store" || return 1
        fi
    fi

    if [ "$store_usable" = true ] && dx_host_key_store_populated "$store"; then
        echo "Restoring the persisted SSH host identity."
        cp -a "$store"/ssh_host_* "$etc_ssh/" || return 1
        dx_harden_host_keys "$etc_ssh" || return 1
        return 0
    fi

    if [ ! -f "$etc_ssh/ssh_host_ed25519_key" ] && [ ! -f "$etc_ssh/ssh_host_rsa_key" ]; then
        generate_host_keys || return 1
    fi
    dx_harden_host_keys "$etc_ssh" || return 1

    # Backfill so the identity generated here survives the next rebuild.  This
    # also covers an older rootfs whose keys the persist volume has never seen.
    if [ "$store_usable" = true ] && ! dx_host_key_store_populated "$store" \
        && dx_host_key_store_populated "$etc_ssh"; then
        cp -a "$etc_ssh"/ssh_host_* "$store/" || return 1
        dx_harden_host_keys "$store" || return 1
        echo "Persisted the SSH host identity for future rebuilds."
    fi
}

# Hand /persist (mounted from the dx-persist named volume) to dx.
# Top-level only; recursive chown on populated persistent storage is wasteful.
configure_ssh() {
    echo "Configuring SSH..."
    mkdir -p /home/dx/.ssh
    chown dx:dx /home/dx/.ssh
    chmod 700 /home/dx/.ssh
    
    # Authorized keys from environment variable (Section 4)
    if [ -n "${DX_PUB_KEY:-}" ]; then
        if [ ! -f /home/dx/.ssh/authorized_keys ] || ! grep -q "$DX_PUB_KEY" /home/dx/.ssh/authorized_keys; then
            echo "$DX_PUB_KEY" > /home/dx/.ssh/authorized_keys
        fi
    elif [ -f "$DX_BOOTSTRAP_ROOT/dx_key.pub" ]; then
        if [ ! -f /home/dx/.ssh/authorized_keys ]; then
            cp "$DX_BOOTSTRAP_ROOT/dx_key.pub" /home/dx/.ssh/authorized_keys
        fi
    fi
    
    if [ -f /home/dx/.ssh/authorized_keys ]; then
        # Only bootstrap-written metadata is repaired here. Existing user SSH
        # contents must remain untouched, and an ordinary start must not walk
        # the complete known_hosts/configuration tree.
        chown dx:dx /home/dx/.ssh/authorized_keys
        chmod 600 /home/dx/.ssh/authorized_keys
    fi

    dx_persist_host_keys /etc/ssh /persist/etc/ssh || return 1

    mkdir -p /run /var/run/sshd
    mkdir -p /var/log
    touch /var/log/lastlog
    mkdir -p /var/empty
    chmod 755 /var/empty

    if [ ! -f /etc/ssh/sshd_config ] || ! grep -q "Port 2222" /etc/ssh/sshd_config; then
        cat > /etc/ssh/sshd_config <<EOF
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
EOF
    fi

    if ! id -u sshd >/dev/null 2>&1; then
        useradd -r -M -s /bin/false sshd
    fi
}

# 4. Bootstrap guest tools (Section 6)


# Helper to run commands as dx user using setpriv
