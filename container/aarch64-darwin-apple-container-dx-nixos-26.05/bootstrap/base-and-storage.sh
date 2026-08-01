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

# Wraps the `-b` test so the block-device path below can be exercised without a
# real block device. Coverage probes shadow this the same way they shadow
# findmnt and blkid; creating one with mknod needs CAP_MKNOD, which a rootless
# container runner does not have, and that made this branch's coverage depend on
# which container runtime happened to run the suite.
is_block_device() { [ -b "$1" ]; }

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
