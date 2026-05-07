#!/bin/bash
set -euo pipefail

# Ensure SSL certificates are found
export SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}
export NIX_SSL_CERT_FILE=${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}

# 1. Bootstrapping dependencies (Section 2/3)
install_essentials() {
    # Only install if shadow tools (like useradd) aren't available
    if ! command -v useradd >/dev/null 2>&1; then
        echo "Installing essential tools..."
        # Install tools needed for the bootstrap itself into the root profile
        # util-linux and btrfs-progs added for Nix volume management (§2)
        nix profile install nixpkgs#bashInteractive nixpkgs#shadow nixpkgs#openssh nixpkgs#gnutar nixpkgs#gzip nixpkgs#sudo nixpkgs#gnused nixpkgs#gnugrep nixpkgs#which nixpkgs#procps nixpkgs#util-linux nixpkgs#btrfs-progs nixpkgs#e2fsprogs --extra-experimental-features "nix-command flakes"
    fi
    export PATH="/root/.nix-profile/bin:$PATH"
}

# §2: Setup dedicated Nix volume
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
            umount "$raw_path" || true
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
    cat > /etc/nix/nix.conf <<EOF
auto-optimise-store = true
min-free = 1073741824
max-free = 5368709120
experimental-features = nix-command flakes
EOF
}

# 2. Create non-root guest user (Section 3)
create_user() {
    if ! id -u dx >/dev/null 2>&1; then
        echo "Creating user dx..."
        groupadd -f dx
        useradd -m -g dx -s /bin/bash dx
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

# Hand /workspace (mounted from the dx-workspace named volume) to dx.
# Top-level only — recursive chown on a populated workspace is wasteful.
setup_workspace() {
    if [ -d /workspace ]; then
        chown dx:dx /workspace
        chmod 0755 /workspace
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

    mkdir -p /var/run/sshd
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

# 5. Configure Shell & Tmux (Section 3/6)
configure_guest() {
    echo "Configuring guest environment with Home Manager..."
    
    # Hand over Nix ownership to dx for true single-user operation (§7)
    # Sentinel on the persistent volume — skip if already done on this store.
    if [ ! -f /nix/.dx-owner-set ]; then
        echo "Granting Nix ownership to dx..."
        chown -R dx:dx /nix
        touch /nix/.dx-owner-set
    else
        echo "Nix ownership already set. Skipping chown."
    fi
    chown -R dx:dx /home/dx
    chown -R dx:dx /guest-bootstrap

    # Create persistent Nix cache dir on volume to speed up evaluations
    mkdir -p /nix/cache/nix
    chown -R dx:dx /nix/cache
    run_as_dx "mkdir -p ~/.cache && ln -sf /nix/cache/nix ~/.cache/nix"

    # Use Home Manager to manage dotfiles and user profile
    run_as_dx "nix run --extra-experimental-features 'nix-command flakes' /guest-bootstrap#homeConfigurations.dx.activationPackage"

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
install_essentials
setup_nix_volume   # §2: Call BEFORE install_tools
configure_nix_daemon # §3
create_user
setup_workspace
configure_ssh
configure_guest
verify_guest_tools

echo "Guest bootstrap complete. Starting sshd in foreground..."
SSHD_BIN=$(command -v sshd)
exec "$SSHD_BIN" -D -e -p 2222
