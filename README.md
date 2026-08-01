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
2. **Bring up the environment:**
   ```bash
   ./bin/dx
   ```
   `dx` is a state-driven entrypoint: on first run it generates the SSH
   keypair, builds the image, creates persistent volumes, creates and starts
   the container, syncs the bootstrap payload as part of container start,
   waits for SSH, and connects.
   On every later run it skips whatever already exists and reconnects. Each
   underlying lifecycle script is idempotent toward its end state, so `dx`
   is safe to run from any starting state.

   The first run takes a few minutes for the image build; later runs reconnect
   in seconds.

## Normal Workflow

- **Connect (or first-time setup):** `./bin/dx`
- **Check Status:** `./bin/dx-status`
- **Work with Code:** Use `/persist` inside the guest.
- **Occasionally mount a host checkout in an isolated side container:** `./bin/dx-mount [DIR]`
- **Transfer Files:** `./bin/dx-put <host_path> [guest_path]`
- **Forward guest web ports to macOS:** `./bin/dx-forward 5173:5175`
- **Expose macOS host ports inside the guest:** `./bin/dx-reverse 5432:15432`
- **Stop the Container:** `./bin/dx-stop-container`
- **Push edited bootstrap payload to a running guest:** `./bin/dx-sync-bootstrap`

## Forwarding guest web ports

Use `dx-forward` when a web server is listening inside the guest and you want
to open it from a macOS browser on `127.0.0.1`. It creates SSH local forwards
against the already-running `dx-host`, so you do not need to recreate the
container.

```bash
./bin/dx-forward 5173:5175
open http://127.0.0.1:5175/
```

Port syntax is `guest_port` or `guest_port:host_port`. For example,
`./bin/dx-forward 8000` maps guest `127.0.0.1:8000` to host
`127.0.0.1:8000`, while `./bin/dx-forward 5173:5175` maps guest
`127.0.0.1:5173` to host `127.0.0.1:5175`.

Use direct `http://192.168.64.x:<port>` access only as a diagnostic shortcut.
Use `dx-reverse` for guest-to-host access, not for macOS-browser-to-guest
access.

Manage active forwards with:

```bash
./bin/dx-forward --list
./bin/dx-forward --stop 5175
./bin/dx-forward --stop-all
```

## Accessing host ports from the guest

Use `dx-reverse` when a service is listening on macOS and guest tools need to
reach it through guest loopback. It creates SSH reverse forwards (`ssh -R`)
against the already-running `dx-host`.

```bash
./bin/dx-reverse 5432:15432
```

Port syntax is `host_port` or `host_port:guest_port`. For example,
`./bin/dx-reverse 5432:15432` maps host `127.0.0.1:5432` to guest
`127.0.0.1:15432`. Inside the guest, connect to `127.0.0.1:15432`.

Manage active reverse forwards with:

```bash
./bin/dx-reverse --list
./bin/dx-reverse --stop 15432
./bin/dx-reverse --stop-all
```

For both helpers, `--list` reports active forwards, stale sockets, and orphan
metadata. `--stop` removes stale or orphan state. `--stop-all` continues
cleaning other entries after an individual failure, but exits non-zero if any
active SSH master could not be stopped; state for that master is retained so it
can be inspected and stopped later.

## Hotkeys

The default tmux prefix is `Ctrl-Space`. Press `Ctrl-Space ?` inside tmux to
show the configured prefix-key help.

| Key | Action |
| --- | --- |
| `Ctrl-Space c` | Open a new window in the current pane's directory. |
| `Ctrl-Space %` | Split the current pane vertically in the current directory. |
| `Ctrl-Space "` | Split the current pane horizontally in the current directory. |
| `Ctrl-Space S` | Toggle synchronize-panes for the current window. When enabled, input is sent to every pane in that window and the tmux status bar shows a `SYNC` pill. |
| `Ctrl-Space P` | Open a scratch shell popup in the current directory. Exit the shell to close it. |
| `Ctrl-Space g` | Open `lazygit` in a popup in the current directory. |
| `Ctrl-Space w` | Open the tmux session/window/pane picker. |
| `Ctrl-Space b` | Open the picker filtered to windows with tmux activity or bell flags. This is useful when background windows have produced output; it may be empty when nothing has changed. |
| `Ctrl-Space [` | Enter tmux copy mode. Use `v` to begin selection, `V` to select a line, `Ctrl-v` for rectangle selection, and `y` to copy and exit. |
| `Ctrl-Space ]` | Paste the most recent tmux buffer. |
| `Ctrl-Space +` | Switch the current tmux window to the tiled layout. |
| `Ctrl-Space a` | Switch to the main-vertical layout, show pane numbers, and swap the selected pane into the main slot. Press `Escape` to leave the layout unchanged. |


## Documentation

- [Lifecycle, helpers, migration, and recovery](docs/lifecycle.md)
- [Configuration, profiles, and `dx-mount`](docs/configuration.md)
- [Guest bootstrap, persistence, optional AI tools, NixVim, and theming](docs/guest.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Release, pin, upgrade, and base-image changeover procedures](docs/release-maintenance.md)
- [Test and validation tiers](docs/refactor/validation-matrix.md)
- [Current refactor decisions and migration gates](refactor-plan.md)

Profile files and root `.env` are bounded `NAME=value` data, not shell scripts. Run profiles with `./bin/dx-profile NAME COMMAND`; do not source them. The full grammar, precedence, defaults, and migration examples are in [configuration](docs/configuration.md).

## Project records

See [plan.md](plan.md) for the release-upgrade record and
[refactor-plan.md](refactor-plan.md) for the architecture decisions and
operational migration gates retained by this refactor.
