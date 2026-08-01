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

# 2. Create non-root guest user (Section 3)
create_user() {
    if ! id -u dx >/dev/null 2>&1; then
        echo "Creating user dx..."
        groupadd -f dx
        useradd -m -g dx -s /bin/sh dx
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

# Hand /persist (mounted from the dx-persist named volume) to dx.
# Top-level only; recursive chown on populated persistent storage is wasteful.
configure_ssh() {
    echo "Configuring SSH..."
    mkdir -p /home/dx/.ssh
    
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
        chown -R dx:dx /home/dx/.ssh
        chmod 700 /home/dx/.ssh
        chmod 600 /home/dx/.ssh/authorized_keys
    fi

    mkdir -p /etc/ssh
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -A
    fi

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
