#!/bin/bash
set -euo pipefail

# 1. Bootstrapping dependencies (Section 2/3)
install_essentials() {
    # Only install if shadow tools (like useradd) aren't available
    if ! command -v useradd >/dev/null 2>&1; then
        echo "Installing essential tools..."
        # Install tools needed for the bootstrap itself into the root profile
        nix profile install nixpkgs#bashInteractive nixpkgs#shadow nixpkgs#openssh nixpkgs#gnutar nixpkgs#gzip nixpkgs#sudo nixpkgs#gnused nixpkgs#gnugrep nixpkgs#which nixpkgs#procps --extra-experimental-features "nix-command flakes"
    fi
    export PATH="/root/.nix-profile/bin:$PATH"
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
    mkdir -p /var/empty
    chmod 755 /var/empty

    if [ ! -f /etc/ssh/sshd_config ]; then
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

    if ! pgrep -x sshd >/dev/null; then
        echo "Starting sshd..."
        $(command -v sshd)
    fi
}

# 4. Bootstrap guest tools (Section 6)
install_tools() {
    # Check if tools are already installed (idempotency check)
    if [ ! -f /home/dx/.nix-profile/bin/nvim ]; then
        echo "Installing DX tools..."
        mkdir -p /home/dx/.config/nix
        echo "experimental-features = nix-command flakes" > /home/dx/.config/nix/nix.conf

        mkdir -p /home/dx/.local/share/nvim
        mkdir -p /home/dx/.cache/nvim

        # Install tools into dx user profile (as root initially)
        nix profile install --profile /home/dx/.nix-profile /guest-bootstrap#default --extra-experimental-features "nix-command flakes" --accept-flake-config
    else
        echo "DX tools already installed. Skipping initial install."
    fi
}

# 5. Configure Shell & Tmux (Section 3/6)
configure_guest() {
    echo "Configuring guest environment with Home Manager..."
    
    # Hand over Nix ownership to dx for true single-user operation
    echo "Granting Nix ownership to dx..."
    chown -R dx:dx /nix
    chown -R dx:dx /home/dx

    # Use Home Manager to manage dotfiles and user profile
    # We use 'nix run' to avoid needing home-manager pre-installed in the root profile
    sudo -u dx bash -l -c "nix run --extra-experimental-features 'nix-command flakes' /guest-bootstrap#homeConfigurations.dx.activationPackage"

    # Add a test image for Yazi/Ghostty validation
    if [ ! -f /home/dx/test-image.png ]; then
       echo "Adding test image..."
       curl -sSL https://raw.githubusercontent.com/NixOS/nixos-artwork/master/logo/nix-snowflake.png -o /home/dx/test-image.png
       chown dx:dx /home/dx/test-image.png
    fi
}

# Main
install_essentials
create_user
configure_ssh
install_tools
configure_guest

echo "Guest bootstrap complete. SSH listening on 2222."

# 6. Serve (Section 3)
if [ "${1:-}" == "serve" ]; then
    tail -f /dev/null
fi
