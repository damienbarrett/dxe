# Plan: Persistent Nix Store Volume for Fast Container Rebuilds

## Problem

Every time the DX container is destroyed and recreated, `bootstrap.sh` re-downloads the
entire Nix package graph from scratch into `/nix/store`. This takes many minutes and burns
bandwidth. The goal is to persist `/nix` across container rebuilds so those downloads are
reused.

---

## Approach

Store `/nix` in a dedicated raw disk image file (e.g. `~/.dx-cache/nix-store.img`). The
`container create` command mounts this image at `/nix` inside the container. The container
itself can be freely destroyed and rebuilt; the disk image survives independently.

On first use the disk image is created and formatted (ext4) inside a throwaway container.
On subsequent uses it is simply mounted and the existing store is reused. Nix's
content-addressed store means a rebuilt image that requests the same packages will find
them already present.

---

## Implementation Steps

### 1. Add `DX_NIX_DISK` to `dx-lib.sh`

```sh
export DX_NIX_DISK="${DX_NIX_DISK:-$HOME/.dx-cache/nix-store.img}"
export DX_NIX_DISK_SIZE="${DX_NIX_DISK_SIZE:-20G}"
```

This keeps the disk outside the repo and project root so it survives `git clean` and
directory deletions.

---

### 2. Add `bin/dx-nix-disk` — create and format the disk image (run once)

```sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dx-lib.sh"

mkdir -p "$(dirname "$DX_NIX_DISK")"

if [ -f "$DX_NIX_DISK" ]; then
    echo "Nix store disk already exists: $DX_NIX_DISK"
    exit 0
fi

echo "Creating ${DX_NIX_DISK_SIZE} disk image at $DX_NIX_DISK ..."
# Create a sparse raw image
mkfile -n "$DX_NIX_DISK_SIZE" "$DX_NIX_DISK"   # macOS; swap for fallocate on Linux

echo "Formatting disk with ext4 (via throwaway container)..."
# Spin up a minimal container to format the image from inside Linux
container run --rm \
    --volume "$DX_NIX_DISK:/dev/nix-disk" \
    nixpkgs/nix-flakes:nixos-25.11-aarch64-linux \
    bash -c "mkfs.ext4 -L nix-store /dev/nix-disk"

echo "Nix store disk ready: $DX_NIX_DISK"
```

> **Note:** verify the exact `container run --volume` syntax for mounting a raw disk image
> vs. a directory share against the installed version of the Apple container CLI. The flag
> may be `--disk` rather than `--volume` depending on the release.

---

### 3. Modify `bin/dx-create` to mount the disk

Add a guard that ensures the disk exists, then pass it to `container create`:

```sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dx-lib.sh"

if container_exists "$DX_CONTAINER_NAME"; then
    echo "Container $DX_CONTAINER_NAME already exists. Skipping create."
    exit 0
fi

# Ensure the persistent nix store disk exists
if [ ! -f "$DX_NIX_DISK" ]; then
    echo "Nix store disk not found. Run: ./bin/dx-nix-disk"
    exit 1
fi

echo "Creating DX container: $DX_CONTAINER_NAME from image $DX_IMAGE"

DX_PUB_KEY=$(cat "$DX_SSH_KEY_PUB")
container create \
    --name "$DX_CONTAINER_NAME" \
    -m 4G -c 4 \
    -p "127.0.0.1:$DX_SSH_PORT:2222" \
    -e "DX_PUB_KEY=$DX_PUB_KEY" \
    --volume "$DX_NIX_DISK:/nix" \   # <-- persistent nix store
    "$DX_IMAGE"
```

---

### 4. Modify `bootstrap.sh` to handle a pre-populated or empty `/nix`

The bootstrap already guards installs with idempotency checks (`if ! command -v useradd`,
`if [ ! -f /home/dx/.nix-profile/bin/nvim ]`), so it is safe to run against a populated
store. No structural change is needed.

One optional guard makes the "already populated" path explicit and fast:

```sh
install_essentials() {
    if ! command -v useradd >/dev/null 2>&1; then
        echo "Installing essential tools..."
        nix profile install nixpkgs#bashInteractive nixpkgs#shadow nixpkgs#openssh \
            nixpkgs#gnutar nixpkgs#gzip nixpkgs#sudo nixpkgs#gnused nixpkgs#gnugrep \
            nixpkgs#which nixpkgs#procps \
            --extra-experimental-features "nix-command flakes"
    else
        echo "Essential tools already present (nix store reused). Skipping."
    fi
    export PATH="/root/.nix-profile/bin:$PATH"
}
```

---

### 5. Rebuild workflow (after this change)

```
# First-time setup (once)
./bin/dx-nix-disk          # create + format the persistent disk

# Normal first run
./bin/dx-build             # build the OCI image
./bin/dx-create            # create container, mounting nix-store.img at /nix
./bin/dx-start             # start; bootstrap downloads everything → populates disk

# Rebuild / validation cycle (nix store preserved)
./bin/dx-stop              # stop the container
container delete dx-host   # destroy the container (not the disk)
./bin/dx-build             # rebuild the OCI image (Containerfile changes, etc.)
./bin/dx-create            # recreate; same nix-store.img remounted
./bin/dx-start             # bootstrap skips already-downloaded packages → fast
```

---

### 6. `.gitignore` entry

The disk image must not be committed:

```
# Persistent nix store disk (stored in ~/.dx-cache, but guard anyway)
*.img
*.raw
```

---

## File locations summary

| Artifact | Path | Persisted? |
|---|---|---|
| OCI image | managed by `container` runtime | rebuilt by `dx-build` |
| Container | managed by `container` runtime | destroyed on rebuild |
| Nix store disk | `~/.dx-cache/nix-store.img` | **yes — survives rebuilds** |
| SSH key | `dx_key` / `dx_key.pub` | yes (in repo) |

---

## Open questions / things to verify

1. **`container` CLI volume flag for disk images** — confirm whether the flag is
   `--volume <img>:<mountpoint>` or `--disk <img>` (with a separate mount declaration in
   the guest). Check `container create --help`.
2. **Filesystem type** — ext4 is the safe default. If the container base image uses a
   different tool for `/nix` initialization, adjust accordingly.
3. **Disk size** — 20 GB covers a typical Nix profile with neovim + home-manager. Increase
   to 40 GB if large closures (e.g. LLVM) are added later.
4. **Nix daemon vs. single-user** — the current setup is single-user (nix owned by `dx`).
   Confirm the mount is visible at the right point in the boot sequence before
   `install_essentials` runs.
