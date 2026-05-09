# DX Experience

A lightweight, persistent, guest-driven development environment hosted on macOS using the Apple `container` framework.

## Principles

- **Lightweight Host:** The `Containerfile` only selects the base image. It does NOT copy files, install tools, or define runtime configuration.
- **Guest-Driven:** All tool downloads, installation, and configuration happen inside the guest via Nix flakes during the bootstrap phase. The bootstrap payload is synced after container creation, so flake or script changes do not require an image rebuild.
- **Clean-image host-push bootstrap:** A host may push the minimal bootstrap payload into a brand-new clean guest when the guest has insufficient guest tools, credentials, or configuration to pull the repository itself. This exception is limited to first contact with a clean image; after that, the DXE should behave as a guest-owned environment.
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
   This syncs the local bootstrap payload into the guest before the guest
   bootstrap runs.
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

## Configuration Variables

All variables have defaults, so a normal single-container setup does not need to
set any of these explicitly. Override them when running isolated lifecycle
tests, parallel experiments, or multiple containers on the same host.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DX_CONTAINER_NAME` | `dx-host` | Apple container name. Change this to create a separate container without touching the default DXE instance. |
| `DX_IMAGE` | `dx-nixos-25.11` | Image name used by `dx-build` and `dx-create`. |
| `DX_SSH_PORT` | `2222` | Host port forwarded to guest SSH port `2222`. Use a different port for a second running container. |
| `DX_SSH_KEY` | `$DX_PROJECT_ROOT/dx_key` | Host private key used for SSH into the guest. |
| `DX_SSH_KEY_PUB` | `$DX_PROJECT_ROOT/dx_key.pub` | Host public key provisioned into the guest on create. |
| `DX_CONTEXT_DIR` | `container/aarch64-darwin-apple-container-dx-nixos-25.11` | Directory used as the image build context and default bootstrap source. |
| `DX_BOOTSTRAP_SOURCE` | `$DX_CONTEXT_DIR` | Host directory pushed into the clean guest bootstrap volume. Override this to test a different bootstrap checkout without rebuilding the image. |
| `DX_BOOTSTRAP_VOLUME` | `dx-bootstrap` | Named volume mounted at `/guest-bootstrap` by default. It stores the pushed bootstrap payload outside the image layer. |
| `DX_BOOTSTRAP_PATH` | `/guest-bootstrap` | Guest path where the bootstrap payload is mounted and executed. |
| `DX_NIX_VOLUME` | `dx-nix` | Named volume used as the backing store for `/nix`. Override this for isolated test containers or parallel experiments so they do not share the default writable Nix store. |
| `DX_WORKSPACE_VOLUME` | `dx-workspace` | Named volume mounted as the guest workspace. |
| `DX_WORKSPACE_PATH` | `/workspace` | Guest path for the workspace volume. |

`DX_NIX_VOLUME` exists because the Nix store is large, persistent, and mounted
as a writable guest filesystem. The default `dx-nix` volume preserves downloads
and activation state across container recreation, but only one running container
should use that writable volume at a time. For a clean lifecycle test, use a
separate Nix volume so the test cannot corrupt or lock the default environment.

Example isolated lifecycle create:

```bash
DX_IMAGE=dx-lifecycle \
DX_CONTAINER_NAME=dx-lifecycle \
DX_SSH_PORT=2299 \
DX_NIX_VOLUME=dx-lifecycle-nix \
DX_WORKSPACE_VOLUME=dx-lifecycle-workspace \
DX_BOOTSTRAP_VOLUME=dx-lifecycle-bootstrap \
./bin/dx-create
```

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

The image does not contain the bootstrap repository. `dx-create` mounts a
dedicated `dx-bootstrap` volume at `/guest-bootstrap`, and `dx-start` runs
`dx-sync-bootstrap` to copy the local container configuration into that volume.
After editing `container/.../flake.nix`, `bootstrap.sh`, or related guest
configuration, rerun `./bin/dx-sync-bootstrap` against a running container rather
than rebuilding the image.

## Optional AI Tools

Codex, Gemini, and Claude are intentionally not installed by default. This keeps
the standard DX environment free of AI CLIs, so they are not available in secure,
restricted, or work environments unless you explicitly opt in.

If AI tooling is approved for your environment, install or update the optional
AI tools bundle inside the guest:

```bash
dx-ai
```

This updates `nixpkgs-unstable` in `/guest-bootstrap`, then installs or upgrades
the `codex`, `gemini`, and `claude` commands in the guest user's Nix profile.
The `dx-ai` helper is installed into `~/.local/bin` by Home Manager, the same
way `dx-theme` is installed.

## NixVim Configuration

The editor configuration is managed via NixVim in `container/.../flake.nix`. This is the canonical path for all editor settings, plugins, and keymaps. Standalone `lazy.nvim` configurations are not supported.

## Theming

**Note on Terminal Compatibility:** Dynamic terminal theming relies on standard ANSI escape sequences (`OSC 4`, `OSC 10`, `OSC 11`) to change the 16-color palette, foreground, and background colors on the fly. **Apple's built-in `Terminal.app` explicitly does not support these sequences and will ignore them.** To use dynamic theming with `dx-theme`, you must use a modern terminal emulator that supports `OSC 4/10/11`, such as **Ghostty**, **iTerm2**, **Kitty**, or **Alacritty**.

Tinty theming is wired as an experimental, guest-driven runtime path. It does not edit host terminal configuration.

Aliases are declared in `home/theme.nix` (`dxThemes`) and rendered to
`~/.config/dx/themes.json` at activation time. `dx-theme list` shows the
full set. A representative subset:

```bash
dx-theme dark                  # base16-gruvbox-dark-hard
dx-theme light                 # base16-gruvbox-light-medium
dx-theme rose-pine             # plus rose-pine-moon, rose-pine-dawn
dx-theme everforest-dark       # plus everforest-light
dx-theme catppuccin            # = catppuccin-mocha; latte/frappe/macchiato/mocha also available
dx-theme solarized-dark        # plus solarized-light
dx-theme shades-of-purple      # Base16 Shades of Purple
dx-theme list                  # show every alias and its base16 scheme
dx-theme current               # what tinty has applied right now
dx-theme test                  # palette swatch + base00/base05 readout
dx-theme apply <scheme-id>     # bypass aliases for any tinty scheme
```

Adding a new theme family is a one-line edit to `dxThemes` in
`home/theme.nix` — `dx-theme.sh` reads aliases dynamically via `jq`, so
no script changes are needed.

The first theme apply may run `tinty install` to clone Tinty runtime repositories under Tinty's data directory. The pinned Tinty package is installed through Nix, but the template repositories are runtime-managed by Tinty for this experiment.

Current integrations:
- Shell ANSI/OSC colors through `tinted-shell`, cached from `TINTY_THEME_FILE_PATH`.
- tmux status colors through `tinted-tmux`.
- Neovim through `tinted-nvim`, which reads `tinty current` on fresh startup.
- lazygit through `tinted-lazygit` and `LG_CONFIG_FILE`.
- btop through a generated `dx-tinty` theme.
- Yazi through a generated `theme.toml`.
- Starship through a generated palette-aware `starship.toml`.

`dx-theme` refreshes generated tool themes from `tinty info` after every apply, so reapplying the current scheme also repairs stale btop, Yazi, and Starship theme files.

Rose Pine is available as a DXE-wide Tinty theme family, not just a Neovim colorscheme. The Neovim Rose Pine plugin remains packaged only as a manual fallback.

On a fresh activation, DXE initializes the current Tinty scheme to the dark default (`base16-gruvbox-dark-hard`) if no previous theme has been selected. After that, `dx-theme` preserves the user's last selected theme, and activation only refreshes generated side files.

On login, `dx-ssh` and shell startup run `dx-theme-restore` to re-emit the selected Tinty terminal palette and foreground/background without changing the selected theme. This is needed because host terminal OSC colors are session state, not durable guest files.

OSC foreground/background switching is implemented with Tinty hook palette variables:
- Outside tmux: emits OSC 10/11 directly.
- Inside tmux: emits tmux passthrough-wrapped OSC 10/11.

Manual validation still matters because host terminals vary. To test without tmux, run a non-interactive SSH command such as:
```bash
./bin/dx-ssh 'printf "\033]10;#f8f8f2\033\\\\"; printf "\033]11;#1e1e2e\033\\\\"'
```

Then connect normally with `./bin/dx-ssh`, run `dx-theme dark` and `dx-theme light`, and confirm the host terminal foreground/background visibly changes inside the default tmux session. If OSC 10/11 does not work in the host terminal or through tmux, Tinty remains useful for tool-level theming but does not satisfy the must-have DXE terminal-background requirement.

## Storage

- **Nix Volume Name:** `dx-nix` by default, configurable with `DX_NIX_VOLUME`.
- **Recreate-Survival:** The Nix store (/nix) is stored on a dedicated Apple container volume. This means your downloaded packages and Nix configuration persist even if you delete and recreate the container using dx-create.
- **Single-Writer Constraint:** Only one running container may mount the dx-nix volume at a time. If you need a second concurrent container, it will need its own volume name or you must wait for the first container to stop.
- **Optimization:** The filesystem is formatted with btrfs and zstd:3 compression. Nix's auto-optimise-store is enabled to deduplicate identical files at the hardlink level, further saving space.
- **Bootstrap Payload:** `/guest-bootstrap` is backed by the `dx-bootstrap`
  volume and populated from the local checkout at start time, keeping repository
  changes out of the image layer.

## Troubleshooting

### Resetting the Environment (Stale Dependencies)

If the guest bootstrap fails due to stale dependencies or a corrupted Nix store in the persistent volume, you can perform a "hard reset" to clear the cache and start fresh:

1. **Destroy the container:**
   ```bash
   ./bin/dx-destroy
   ```
2. **Delete and recreate the persistent Nix volume:**
   ```bash
   container volume delete dx-nix
   container volume create dx-nix
   ```
3. **Rebuild and restart:**
   ```bash
   ./bin/dx-build
   ./bin/dx-create
   ./bin/dx-start
   ```
   *Note: This will trigger a full download of all Nix packages during the next bootstrap.*

### Checking Bootstrap Logs
If you cannot connect via SSH, monitor the bootstrap progress on the host:
```bash
container logs dx-host -f
```
