# DX Experience

A lightweight, persistent, guest-driven development environment hosted on macOS using the Apple `container` framework.

## Principles

- **Lightweight Host:** The `Containerfile` is kept minimal. It does NOT install development tools or configuration.
- **Guest-Driven:** All tool downloads, installation, and configuration happen inside the guest via Nix flakes during the bootstrap phase.
- **Reproducible:** Nix flakes and pinned inputs ensure the environment is identical across different machines.
- **Secure by Default:** SSH is configured for public-key authentication only. Root login and password login are disabled.
- **Convenient:** Passwordless `sudo` is enabled for the `dx` user inside the guest to facilitate development.

## Getting Started

1. **Prerequisites:** Ensure Apple `container` is installed on your macOS host.
2. **Build the Image:**
   ```bash
   ./bin/dx-build
   ```
3. **Generate SSH Key:** (If you don't have one)
   ```bash
   ssh-keygen -t ed25519 -f ./dx_key -N ""
   ```
4. **Create the Container:**
   ```bash
   ./bin/dx-create
   ```
   *Note: This script automatically detects `./dx_key.pub` and provisions it in the guest.*
5. **Start the Environment:**
   ```bash
   ./bin/dx-start
   ```
6. **Connect:**
   ```bash
   ./bin/dx-ssh
   ```
   This will drop you into a persistent `tmux` session with NixVim and other tools ready.

## Normal Workflow

- **Check Status:** `./bin/dx-status`
- **Work with Code:** Use `/workspace` inside the guest.
- **Transfer Files:** `./bin/dx-put <host_path> [guest_path]`
- **Stop Environment:** `./bin/dx-stop`
- **Restart Environment:** `./bin/dx-start` followed by `./bin/dx-ssh`

## Guest Bootstrap

The bootstrap script (`container/.../bootstrap.sh`) is responsible for:
1. Installing essential bootstrap tools (shadow, openssh, sudo).
2. Creating the `dx` user and configuring SSH/sudo.
3. Installing the full DX toolset via Nix (NixVim, git, tmux, etc.).
4. Configuring the shell and tmux (including True Color support).

To rerun the bootstrap manually inside the guest:
```bash
sudo /guest-bootstrap/bootstrap.sh
```

## NixVim Configuration

The editor configuration is managed via NixVim in `container/.../flake.nix`. This is the canonical path for all editor settings, plugins, and keymaps. Standalone `lazy.nvim` configurations are not supported.
