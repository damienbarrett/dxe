#!/usr/bin/env bash
set -euo pipefail

# Ensure SSL certificates are found
export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}
export NIX_SSL_CERT_FILE=${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}
DX_GUEST_ACTIVATION_TIMEOUT="${DX_GUEST_ACTIVATION_TIMEOUT:-1800}"
DX_GUEST_ACTIVATION_ATTEMPTS="${DX_GUEST_ACTIVATION_ATTEMPTS:-2}"
DX_GUEST_ACTIVATION_RETRY_DELAY="${DX_GUEST_ACTIVATION_RETRY_DELAY:-5}"

# 0. Temporary old-base guard for the base-image changeover (README.md, "Base Image Changeover").
#
# The official nixos/nix base image never provides a bash binary at the path
# checked below (regular file or symlink, including a dangling one), and
# nothing in this guest payload creates it -- its presence matches the known
# flakes-base signature. This is a TEMPORARY guard: remove this function and
# its call in `# Main` below, together with the host-site twin in
# bin/dx-start-container, once every machine (primary, side containers,
# profiles) has changed over.
guard_old_base() {
    local bash_path="${DX_GUARD_ROOT:-}/bin/bash"

    if [ -e "$bash_path" ] || [ -L "$bash_path" ]; then
        echo "Error: $bash_path is present, matching the known flakes-base signature (nixpkgs/nix-flakes)." >&2
        echo "This container was built from the old flakes base and must be rebuilt under the official base." >&2
        echo "Follow the Base Image Changeover procedure in README.md before retrying." >&2
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
essentials_profile_path() {
    local root="${DX_ESSENTIALS_ROOT:-}"
    local joined="" candidate resolved
    for candidate in \
        "$root/nix/var/nix/profiles/per-user/root/profile/bin" \
        "$root/root/.local/state/nix/profiles/profile/bin" \
        "$root/root/.nix-profile/bin"; do
        resolved="$(readlink -f "$candidate" 2>/dev/null)" || continue
        [ -d "$resolved" ] || continue
        joined="${joined:+$joined:}$resolved"
    done
    printf '%s\n' "$joined"
}

# 1. Bootstrapping dependencies (Section 2/3)
install_essentials() {
    # The essentials profile lives off the image's default PATH (see
    # essentials_profile_path above), so it must be resolved and exported
    # BEFORE the skip-gate below runs. Every container boot re-executes this
    # function; if the gate ran first, it would never see a previous boot's
    # already-installed essentials and would re-run `nix profile install` on
    # every restart, which can conflict with that same profile's own earlier
    # contents once the registry-resolved package revision has moved on.
    local essentials_path
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
        nix profile install nixpkgs#bashInteractive nixpkgs#shadow nixpkgs#openssh nixpkgs#gnutar nixpkgs#gzip nixpkgs#sudo nixpkgs#coreutils nixpkgs#gnused nixpkgs#gnugrep nixpkgs#which nixpkgs#procps nixpkgs#util-linux nixpkgs#btrfs-progs nixpkgs#e2fsprogs --extra-experimental-features "nix-command flakes" --option connect-timeout 15 --option stalled-download-timeout 60 --option download-attempts 2
        # The install just created or extended a profile; resolve it (again)
        # so the freshly installed tools are on PATH for the rest of bootstrap.
        essentials_path="$(essentials_profile_path)"
        if [ -n "$essentials_path" ]; then
            export PATH="$essentials_path:$PATH"
        fi
    fi
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

# §2: Setup dedicated Nix volume.
#
# Apple Container mounts the dx-nix named volume at /var/lib/dx-nix-raw with
# its own (small, runtime-managed) filesystem. We re-format that backing
# block device with btrfs/ext4 and mount it at /nix so the Nix store has
# room to grow and survives container rebuilds. This requires CAP_SYS_ADMIN
# inside the guest, which dx-create-container grants via --cap-add.
setup_nix_volume() {
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
        return 0
    fi

    if [ ! -d "$raw_path" ]; then
        echo "Warning: $raw_path not found. Skipping dedicated volume setup."
        return 0
    fi

    # Detect whether it's a block device or directory
    local backing_dev=$(findmnt -n -o SOURCE "$raw_path" || true)

    if [ -b "$backing_dev" ]; then
        echo "Detected block device backing $raw_path: $backing_dev"
        dev="$backing_dev"
        # mkfs idempotent: skip if blkid -L dx-nix already resolves
        if ! blkid -L dx-nix >/dev/null 2>&1; then
            echo "Formatting $dev with $fs_type..."
            if ! umount "$raw_path" 2>/dev/null; then
                echo "Error: failed to umount $raw_path. The container is missing CAP_SYS_ADMIN; re-create it with ./bin/dx-destroy && ./bin/dx (dx-create-container adds the capability)." >&2
                exit 1
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

    # Move existing /nix content to volume if volume is new (no store)
    if [ ! -d /mnt/tmp-nix/store ]; then
        echo "Initializing Nix volume with existing /nix content..."
        # Use cp -a to preserve permissions and links
        cp -a /nix/. /mnt/tmp-nix/
    else
        # The volume was seeded by a previous build, so the first-init copy
        # above is skipped. Merge in store paths that exist only in the freshly
        # built image -- chiefly the root bootstrap essentials installed in §1
        # plus the base image's /usr/bin -> /nix/store targets (nix, sshd, ...).
        # Without this, the remount below shadows them and the rest of the
        # bootstrap loses mkdir/mount/nix/etc. cp -a -n only adds missing,
        # immutable store paths; it never clobbers existing ones. Errors are
        # non-fatal but surfaced -- a silent partial copy would be invisible.
        echo "Merging freshly built image store into Nix volume..."
        cp -a -n /nix/store/. /mnt/tmp-nix/store/ \
            || echo "Warning: image store merge reported errors; continuing." >&2
    fi

    umount /mnt/tmp-nix
    mount -t "$fs_type" -o "$mount_opts" "$dev" /nix

    # Append a fstab entry (only if absent) so the mount persists
    if ! grep -q "/nix $fs_type" /etc/fstab 2>/dev/null; then
        echo "Adding /nix to /etc/fstab..."
        if blkid -L dx-nix >/dev/null 2>&1; then
            echo "LABEL=dx-nix /nix $fs_type $mount_opts 0 0" >> /etc/fstab
        else
            echo "$dev /nix $fs_type $mount_opts 0 0" >> /etc/fstab
        fi
    fi
}

# §3: Nix daemon configuration
configure_nix_daemon() {
    echo "Configuring Nix daemon..."
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

configure_release_identity() {
    local release

    release="$(sed -n \
        's#^[[:space:]]*nixpkgs\.url[[:space:]]*=[[:space:]]*"github:nixos/nixpkgs/nixos-\([^"]*\)";.*#\1#p' \
        /guest-bootstrap/flake.nix | head -1)"
    case "$release" in
        ''|*[!0-9.]*)
            echo "Error: could not derive a numeric NixOS release from /guest-bootstrap/flake.nix." >&2
            return 1
            ;;
    esac

    cat > /etc/os-release <<EOF
NAME="NixOS"
ID=nixos
VERSION="$release"
VERSION_ID="$release"
PRETTY_NAME="NixOS $release (DX guest)"
HOME_URL="https://nixos.org/"
EOF
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
        cp "$file" "$tmp" 2>/dev/null || : > "$tmp"
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
setup_persist() {
    if [ -d /persist ]; then
        chown dx:dx /persist
        chmod 0755 /persist
        install -d -o dx -g dx -m 0755 /persist/home /persist/home/dx
    fi
}

# 3. Configure SSH (Section 4)
configure_ssh() {
    echo "Configuring SSH..."
    mkdir -p /home/dx/.ssh
    
    # Authorized keys from environment variable (Section 4)
    if [ -n "${DX_PUB_KEY:-}" ]; then
        if [ ! -f /home/dx/.ssh/authorized_keys ] || ! grep -q "$DX_PUB_KEY" /home/dx/.ssh/authorized_keys; then
            echo "$DX_PUB_KEY" > /home/dx/.ssh/authorized_keys
        fi
    elif [ -f /guest-bootstrap/dx_key.pub ]; then
        if [ ! -f /home/dx/.ssh/authorized_keys ]; then
            cp /guest-bootstrap/dx_key.pub /home/dx/.ssh/authorized_keys
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
run_as_dx() {
    local cmd="$1"
    # setpriv --reuid=dx --regid=dx --init-groups bash -l -c "$cmd"
    # Note: bash -l is needed to pick up the profile
    setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" bash -l -c "$cmd"
}

run_as_dx_with_timeout() {
    local timeout_seconds="$1"
    local cmd="$2"

    setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" \
        timeout --kill-after=30s "${timeout_seconds}s" bash -l -c "$cmd"
}

validate_positive_integer() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*|0)
            echo "Error: $name must be a positive integer, got '$value'." >&2
            return 1
            ;;
    esac
}

run_home_manager_activation() {
    validate_positive_integer DX_GUEST_ACTIVATION_TIMEOUT "$DX_GUEST_ACTIVATION_TIMEOUT"
    validate_positive_integer DX_GUEST_ACTIVATION_ATTEMPTS "$DX_GUEST_ACTIVATION_ATTEMPTS"
    validate_positive_integer DX_GUEST_ACTIVATION_RETRY_DELAY "$DX_GUEST_ACTIVATION_RETRY_DELAY"

    local attempt=1
    local status=0
    local activation_cmd
    activation_cmd="nix run --option connect-timeout 15 --option stalled-download-timeout 60 --option download-attempts 2 --extra-experimental-features 'nix-command flakes' /guest-bootstrap#homeConfigurations.dx.activationPackage"

    while [ "$attempt" -le "$DX_GUEST_ACTIVATION_ATTEMPTS" ]; do
        echo "Running Home Manager activation (attempt $attempt/$DX_GUEST_ACTIVATION_ATTEMPTS, timeout ${DX_GUEST_ACTIVATION_TIMEOUT}s)..."
        if run_as_dx_with_timeout "$DX_GUEST_ACTIVATION_TIMEOUT" "$activation_cmd"; then
            return 0
        else
            status=$?
        fi

        if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
            echo "Warning: Home Manager activation timed out after ${DX_GUEST_ACTIVATION_TIMEOUT}s." >&2
        else
            echo "Warning: Home Manager activation failed with exit status $status." >&2
        fi

        if [ "$attempt" -ge "$DX_GUEST_ACTIVATION_ATTEMPTS" ]; then
            echo "Error: Home Manager activation failed after $DX_GUEST_ACTIVATION_ATTEMPTS attempt(s)." >&2
            return "$status"
        fi

        echo "Retrying Home Manager activation in ${DX_GUEST_ACTIVATION_RETRY_DELAY}s..."
        sleep "$DX_GUEST_ACTIVATION_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

dbus_session_config_for_dx() {
    local dbus_bin
    local dbus_real
    local dbus_prefix

    dbus_bin="$(run_as_dx 'command -v dbus-daemon')"
    dbus_real="$(readlink -f "$dbus_bin")"
    dbus_prefix="${dbus_real%/bin/dbus-daemon}"

    if [ -f "$dbus_prefix/share/dbus-1/session.conf" ]; then
        printf '%s\n' "$dbus_prefix/share/dbus-1/session.conf"
    elif [ -f "$dbus_prefix/etc/dbus-1/session.conf" ]; then
        printf '%s\n' "$dbus_prefix/etc/dbus-1/session.conf"
    else
        echo "Error: could not locate dbus session.conf for $dbus_bin." >&2
        return 1
    fi
}

dbus_socket_from_address() {
    local address="${1:-}"
    local socket=""

    case "$address" in
        unix:path=*)
            socket="${address#unix:path=}"
            socket="${socket%%,*}"
            printf '%s\n' "$socket"
            ;;
    esac
}

dbus_address_is_live() {
    local socket
    socket="$(dbus_socket_from_address "${1:-}")"
    [ -n "$socket" ] && [ -S "$socket" ]
}

ensure_nix_ownership() {
    local sentinel="/nix/.dx-owner-set"
    local dx_owner
    local sentinel_owner
    local needs_chown=0

    dx_owner="$(id -u dx):$(id -g dx)"
    sentinel_owner="$(stat -c '%u:%g' "$sentinel" 2>/dev/null || true)"

    if [ ! -f "$sentinel" ]; then
        needs_chown=1
    elif [ "$sentinel_owner" != "$dx_owner" ]; then
        echo "Nix ownership marker needs repair."
        needs_chown=1
    elif ! run_as_dx "test -w /nix/store && test -w /nix/var/nix"; then
        echo "Nix store is not writable by dx."
        needs_chown=1
    fi

    if [ "$needs_chown" -eq 1 ]; then
        echo "Granting Nix ownership to dx..."
        chown -R dx:dx /nix
        touch "$sentinel"
        chown dx:dx "$sentinel"
    else
        echo "Nix ownership already set. Skipping chown."
    fi
}

setup_gh_persistence() {
    local persistent_config_dir="/persist/home/dx/.config"
    local persistent_gh="/persist/home/dx/.config/gh"
    local home_config_dir="/home/dx/.config"
    local home_gh="/home/dx/.config/gh"
    local timestamp=""
    local backup_path=""

    mkdir -p "$persistent_config_dir" "$home_config_dir"

    if [ -e "$persistent_gh" ] && [ ! -d "$persistent_gh" ]; then
        timestamp="$(date +%Y%m%d%H%M%S)"
        backup_path="$persistent_config_dir/gh.non-directory-backup.$timestamp"
        mv "$persistent_gh" "$backup_path"
        echo "Moved non-directory GitHub CLI config target to $backup_path"
    fi

    if [ -L "$home_gh" ]; then
        rm -f "$home_gh"
    elif [ -e "$home_gh" ]; then
        if [ ! -e "$persistent_gh" ]; then
            mv "$home_gh" "$persistent_gh"
        elif [ -d "$persistent_gh" ] && [ -z "$(ls -A "$persistent_gh" 2>/dev/null)" ]; then
            rmdir "$persistent_gh"
            mv "$home_gh" "$persistent_gh"
        else
            timestamp="$(date +%Y%m%d%H%M%S)"
            backup_path="$persistent_config_dir/gh.ephemeral-backup.$timestamp"
            mv "$home_gh" "$backup_path"
            echo "Moved ephemeral GitHub CLI config to $backup_path"
        fi
    fi

    mkdir -p "$persistent_gh"
    chown -R dx:dx /persist/home/dx "$home_config_dir"
    chmod 700 "$persistent_gh"
    run_as_dx "ln -sfnT /persist/home/dx/.config/gh /home/dx/.config/gh"
}

# Persist tmux-resurrect save data across container rebuilds. /persist is a
# runtime mount, so Home Manager cannot create this directory declaratively;
# home/tools.nix points resurrect at it via @resurrect-dir. install -d sets
# ownership on the directories it creates regardless of the later recursive
# chowns over /persist/home/dx.
setup_tmux_persistence() {
    install -d -o dx -g dx -m 0755 /persist/home/dx/.local/share/tmux/resurrect
}

# agy stores its known CLI state under ~/.gemini/antigravity-cli, which is
# persisted with ~/.gemini. Also provide D-Bus + gnome-keyring Secret Service
# compatibility for auth flows that request it; keyring data is linked to
# /persist so any Secret Service-backed tokens survive container rebuilds.
setup_keyring_service() {
    echo "Setting up D-Bus keyring service for credential persistence..."

    # 1. Persist keyring data across container rebuilds
    local persistent_keyrings="/persist/home/dx/.local/share/keyrings"
    mkdir -p "$persistent_keyrings"
    chown -R dx:dx /persist/home/dx/.local
    run_as_dx "mkdir -p ~/.local/share && ln -sfnT '$persistent_keyrings' ~/.local/share/keyrings"

    # 2. Reuse a live D-Bus session when available, otherwise start a fresh one.
    local env_file="/home/dx/.dx-keyring-env"
    local dbus_config
    local bus_addr
    bus_addr="$(sed -n "s/^export DBUS_SESSION_BUS_ADDRESS='\(.*\)'$/\1/p" "$env_file" 2>/dev/null || true)"

    if ! dbus_address_is_live "$bus_addr"; then
        dbus_config="$(dbus_session_config_for_dx)"
        run_as_dx "dbus-daemon --config-file='$dbus_config' --fork --print-address > '$env_file.addr'"
        bus_addr="$(cat "$env_file.addr")"
        rm -f "$env_file.addr"
    fi

    # 3. Start gnome-keyring-daemon (secret-service component) with an empty
    #    unlock password so it is immediately usable in this headless guest.
    local gk_out
    gk_out="$(run_as_dx "DBUS_SESSION_BUS_ADDRESS='$bus_addr' echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null" || true)"

    # 4. Write a sourceable env file so SSH sessions inherit the bus address
    cat > "$env_file" <<ENVEOF
export DBUS_SESSION_BUS_ADDRESS='$bus_addr'
ENVEOF
    chown dx:dx "$env_file"
}

# 5. Configure Shell & Tmux (Section 3/6)
configure_guest() {
    echo "Configuring guest environment with Home Manager..."
    
    # Hand over Nix ownership to dx for true single-user operation (§7)
    ensure_nix_ownership
    chown -R dx:dx /home/dx
    chown -R dx:dx /guest-bootstrap

    # Create persistent Nix cache dir on volume to speed up evaluations
    mkdir -p /nix/cache/nix
    chown -R dx:dx /nix/cache
    run_as_dx "mkdir -p ~/.cache && ln -sf /nix/cache/nix ~/.cache/nix"

    # Expose persistent /persist volume at a stable path inside $HOME.
    run_as_dx "ln -sfnT /persist /home/dx/persist"

    # Persist GitHub CLI credentials/configuration across container rebuilds.
    setup_gh_persistence

    # Persist tmux-resurrect save data across container rebuilds.
    setup_tmux_persistence

    # Persist AI CLI tool credentials/configuration across container rebuilds
    # Only restore these links if the user has opted into the AI tools
    if run_as_dx "nix profile list" | grep -qE "Flake attribute:[[:space:]]+packages\.[^.]+\.ai-tools$"; then
        mkdir -p /persist/home/dx/.gemini/antigravity-cli /persist/home/dx/.claude /persist/home/dx/.codex
        if [ ! -s /persist/home/dx/.claude.json ]; then
            printf '%s\n' '{}' > /persist/home/dx/.claude.json
        fi
        chown -R dx:dx /persist/home/dx
        run_as_dx "ln -sfn /persist/home/dx/.gemini ~/.gemini"
        run_as_dx "ln -sfn /persist/home/dx/.claude ~/.claude"
        run_as_dx "ln -sfn /persist/home/dx/.claude.json ~/.claude.json"
        run_as_dx "ln -sfn /persist/home/dx/.codex ~/.codex"

        # Start D-Bus + gnome-keyring so agy can persist OAuth tokens
        setup_keyring_service
    fi

    # Use Home Manager to manage dotfiles and user profile. This is bounded so
    # a wedged Nix substitute cannot leave the container alive but pre-SSH.
    run_home_manager_activation

    # Set nushell as default shell
    NU_PATH="/home/dx/.nix-profile/bin/nu"
    if [ -f "$NU_PATH" ]; then
        echo "Setting nushell as the default shell..."
        touch /etc/shells
        if ! grep -q "$NU_PATH" /etc/shells; then
            echo "$NU_PATH" >> /etc/shells
        fi
        usermod -s "$NU_PATH" dx
    fi
}

verify_guest_tools() {
    echo "Verifying guest tools..."
    if ! run_as_dx 'command -v nvim >/dev/null && command -v tmux >/dev/null && command -v nix >/dev/null && command -v yazi >/dev/null'; then
        echo "Error: DX guest tools are not available in the dx login shell." >&2
        exit 1
    fi
}

start_ssh() {
    if ! pgrep -x sshd >/dev/null; then
        echo "Starting sshd..."
        "$(command -v sshd)"
    fi
}

# Main
guard_old_base
if [ "${DX_BOOTSTRAP_TEST_MODE:-}" = "guard" ]; then exit 0; fi
install_essentials
link_system_bash
setup_nix_volume   # §2: Call BEFORE install_tools
configure_nix_daemon # §3
configure_release_identity
materialize_auth_files
create_user
setup_persist
configure_ssh
configure_guest
verify_guest_tools
configure_timezone   # §4: Run after guest profile is verified

echo "Guest bootstrap complete. Starting sshd in foreground..."
SSHD_BIN=$(command -v sshd)
exec "$SSHD_BIN" -D -e -p 2222
