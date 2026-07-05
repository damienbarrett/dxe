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

## Lifecycle Layers

The DX environment is built from independent **layers** of state, ordered from
most persistent (slowest to rebuild) to most ephemeral. Each layer has a
dedicated `dx-create-X` and `dx-destroy-X` script. Every create script skips
its work if the layer is already present; every destroy script no-ops if the
layer is absent. A small set of wrappers (`dx`, `dx-destroy`, `dx-recreate`,
`dx-factory-reset`) compose these layer scripts in fixed orders for the common
operations.

### Lifecycle Principles

1. **One concern per script.** Each lifecycle script owns exactly one layer
   (keypair, image, container, runtime state, bootstrap payload, etc.).
2. **Idempotence toward end state.** Every create script no-ops if its layer
   exists. Every destroy script no-ops if its layer is absent.
3. **Symmetric pairs.** Each layer has a `create-X` and `destroy-X` script
   that read as antonyms. The script name tells you which layer it operates on.
4. **Wrappers only orchestrate.** `dx`, `dx-destroy`, `dx-recreate`, and
   `dx-factory-reset` are short sequences of lifecycle calls with no unique
   logic. New phases land in one place.
5. **Forcing a rebuild is explicit.** Idempotent build means "skip if present."
   To force a rebuild at any layer, destroy that layer first.
6. **Persistent volumes are protected by construction.** `/nix` and `/persist`
   survive everything except `dx-factory-reset` (or an explicit
   `dx-destroy-volumes`).
7. **The bootstrap payload is part of every start.** `dx-start-container`
   always runs `dx-sync-bootstrap` after ensuring the container is running, so edits to
   `home/*.nix` or `bootstrap.sh` land on the next `dx` without an image
   rebuild.
8. **Layer cost informs default behaviour.** Volumes (hours to rebuild) are
   never touched implicitly. Image (minutes) is rebuilt only by `dx-recreate`
   or explicit destroy. Container and runtime state (seconds) are freely
   rebuilt.

### Layered lifecycle scripts

| # | Layer | Create | Destroy |
| --- | --- | --- | --- |
| 1 | Host SSH keypair | [`bin/dx-create-keys`](bin/dx-create-keys) | [`bin/dx-destroy-keys`](bin/dx-destroy-keys) |
| 2 | Persistent volumes | [`bin/dx-create-volumes`](bin/dx-create-volumes) | [`bin/dx-destroy-volumes`](bin/dx-destroy-volumes) |
| 3 | Image | [`bin/dx-create-image`](bin/dx-create-image) | [`bin/dx-destroy-image`](bin/dx-destroy-image) |
| 4 | Container | [`bin/dx-create-container`](bin/dx-create-container) | [`bin/dx-destroy-container`](bin/dx-destroy-container) |
| 5 | Runtime state | [`bin/dx-start-container`](bin/dx-start-container) | [`bin/dx-stop-container`](bin/dx-stop-container) |
| 6 | Bootstrap payload | [`bin/dx-sync-bootstrap`](bin/dx-sync-bootstrap) | *(replaced on next sync)* |
| 7 | SSH connection | [`bin/dx-ssh`](bin/dx-ssh) | *(user exits)* |

`dx-destroy-volumes` is the only interactive lifecycle script: it lists the
volumes it is about to remove, requires the user to type `destroy` to confirm,
and refuses to run non-interactively without `--force`. Every other script is
fire-and-forget.

### Wrappers

| Wrapper | Composition |
| --- | --- |
| [`bin/dx`](bin/dx) | `create-keys → create-image → create-volumes → create-container → start-container → wait-ssh → ssh` |
| [`bin/dx-destroy`](bin/dx-destroy) | `destroy-container → destroy-image` (preserves volumes and keys) |
| [`bin/dx-recreate`](bin/dx-recreate) | `dx-destroy → exec dx` (preserves volumes and keys) |
| [`bin/dx-factory-reset`](bin/dx-factory-reset) | prompts once, then `destroy-container → destroy-image → destroy-volumes --force → destroy-keys` |

### Helpers and runtime utilities

These do not belong to the layer model — they observe state, transfer files,
or perform maintenance operations.

| Script | Role |
| --- | --- |
| [`bin/dx-lib.sh`](bin/dx-lib.sh) | Shared library (env vars, container helpers). Sourced by every script; not executable on its own. |
| [`bin/dx-profile`](bin/dx-profile) | Loads a named profile of env-var overrides from `tests/profiles/<name>.env`, then execs the rest of the command. Opt-in; defaults apply when not used. |
| [`bin/dx-mount`](bin/dx-mount) | Explicitly launches an isolated side container with a host directory bind-mounted at `/workspace`. It derives private container, volume, key, and port defaults and refuses to use `dx-host`. |
| [`bin/dx-wait-ssh`](bin/dx-wait-ssh) | Blocks until guest SSH responds. Gates the SSH connection layer. |
| [`bin/dx-status`](bin/dx-status) | Reports image, container, SSH, tool, persist, and tmux status. |
| [`bin/dx-put`](bin/dx-put) | Copies host files into the guest. |
| [`bin/dx-forward`](bin/dx-forward) | Exposes guest web ports on macOS loopback addresses with SSH local forwarding. |
| [`bin/dx-reverse`](bin/dx-reverse) | Exposes macOS loopback services inside the guest with SSH reverse forwarding. |
| [`bin/dx-enter`](bin/dx-enter) | Direct `container exec` shell, bypassing SSH. |
| [`bin/dx-gc`](bin/dx-gc) | Runs Nix garbage collection and store optimization inside the guest. |
| [`bin/dx-reclaim`](bin/dx-reclaim) | Reclaims host disk space by deleting old Nix generations in the guest and trimming persistent filesystems. |
| [`bin/dx-export`](bin/dx-export) | Archives the container to a tar file. |
| [`bin/dx-nix-disk`](bin/dx-nix-disk) | Prepares a sparse Nix disk image; lifecycle-adjacent storage prep. |
| [`container/.../bootstrap.sh`](container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh) | Runs inside the guest from the synced payload; configures `/nix`, the `dx` user, SSH, Home Manager, shell, tmux, and tools. |

### Reclaiming host disk space

Apple Container stores named volumes as sparse host images. The apparent size
of those images can stay high after the guest deletes data until the guest
filesystem reports its free blocks back to the host. `dx-reclaim` handles that
maintenance path for the DX volumes:

```bash
./bin/dx-reclaim
```

Run it when the `dx-nix` or `dx-persist` volume has grown noticeably and you
want to return unused space to macOS. The container must already be running.

`dx-reclaim` prints host sparse-image usage and guest filesystem usage before
and after the operation. It then:

1. Deletes old Nix generations inside the guest with `nix-collect-garbage -d`.
2. Runs `fstrim -v` on `/nix` and `/persist` so already-free blocks can be
   discarded from the sparse host images.

This does not delete persisted files. It removes only unreferenced Nix store
paths and discards blocks the guest filesystem has already marked free. It is
reasonable to run occasionally after large rebuilds or dependency churn, but it
does not need to run constantly or on a tight schedule.

### Migration from earlier versions

| Old name | New name | Notes |
| --- | --- | --- |
| `dx-init-keys` | `dx-create-keys` | |
| `dx-build` | `dx-create-image` | Now idempotent: skips when the image already exists. |
| `dx-create` | `dx-create-container` | |
| `dx-destroy` | `dx-destroy-container` | The old name now refers to an umbrella that destroys image AND container — see the Wrappers table. |
| `dx-start` | `dx-start-container` | Now also syncs the bootstrap payload, so direct starts bring SSH up without a separate `dx-sync-bootstrap` step. |
| `dx-stop` | `dx-stop-container` | |

If you have data in the old default `dx-workspace` volume, migrate it before
starting the renamed lifecycle:

```bash
./bin/dx-migrate-persist
```

The helper copies `dx-workspace` into `dx-persist`, writes a migration sentinel,
and never deletes the old volume. For a custom old volume, run:

```bash
DX_LEGACY_WORKSPACE_VOLUME=<old-volume> \
DX_PERSIST_VOLUME=<new-volume> \
./bin/dx-migrate-persist
```

After starting the guest, verify the data under `/persist`. Only then remove
the old volume manually, for example:

```bash
container volume rm dx-workspace
```

## Configuration Variables

All variables have defaults, so a normal single-container setup does not need to
set any of these explicitly. Override them when running isolated lifecycle
tests, parallel experiments, or multiple containers on the same host.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DX_CONTAINER_NAME` | `dx-host` | Apple container name. Change this to create a separate container without touching the default DXE instance. |
| `DX_IMAGE` | `dx-nixos-26.05` | Image name used by `dx-create-image` and `dx-create-container`. |
| `DX_SSH_PORT` | `2222` | Host port forwarded to guest SSH port `2222`. Use a different port for a second running container. |
| `DX_SSH_KEY` | `$DX_PROJECT_ROOT/dx_key` | Host private key used for SSH into the guest. |
| `DX_SSH_KEY_PUB` | `$DX_PROJECT_ROOT/dx_key.pub` | Host public key provisioned into the guest on create. |
| `DX_SSH_CONNECT_TIMEOUT` | `15` | Host-side SSH connection timeout in seconds for `dx-ssh`. |
| `DX_CONTEXT_DIR` | `container/aarch64-darwin-apple-container-dx-nixos-26.05` | Directory used as the image build context and default bootstrap source. |
| `DX_BOOTSTRAP_SOURCE` | `$DX_CONTEXT_DIR` | Host directory pushed into the clean guest bootstrap volume. Override this to test a different bootstrap checkout without rebuilding the image. |
| `DX_BOOTSTRAP_VOLUME` | `dx-bootstrap` | Named volume mounted at `/guest-bootstrap` by default. It stores the pushed bootstrap payload outside the image layer. |
| `DX_BOOTSTRAP_PATH` | `/guest-bootstrap` | Guest path where the bootstrap payload is mounted and executed. |
| `DX_BOOTSTRAP_WAIT_TIMEOUT` | `30` | Seconds `dx-sync-bootstrap` waits for the guest entrypoint to report bootstrap readiness before failing with a log hint. |
| `DX_GUEST_ACTIVATION_TIMEOUT` | `1800` | Seconds allowed for one guest Home Manager activation attempt before the bootstrap kills it and retries. A clean Nix store can require much of this window. |
| `DX_GUEST_ACTIVATION_ATTEMPTS` | `2` | Total guest Home Manager activation attempts before bootstrap fails and the container exits with logs. |
| `DX_GUEST_ACTIVATION_RETRY_DELAY` | `5` | Seconds to wait between guest Home Manager activation attempts. |
| `DX_SSH_WAIT_TIMEOUT` | Derived from the complete guest activation retry budget | Maximum seconds `dx-wait-ssh` waits for bootstrap. The default covers all activation attempts, their kill/retry delays, and 30 minutes for rebuilding the root bootstrap toolchain on a clean image. |
| `DX_NIX_VOLUME` | `dx-nix` | Named volume that backs the persistent Nix store. Apple Container surfaces it inside the guest at `/var/lib/dx-nix-raw`; the bootstrap reformats it as btrfs (or ext4 as a fallback) and remounts it at `/nix`. Override this for isolated test containers or parallel experiments so they do not share the default writable Nix store. |
| `DX_NIX_MOUNT` | `/nix` | Guest mount point for the active Nix filesystem. Used by maintenance commands such as `dx-reclaim`. |
| `DX_PERSIST_VOLUME` | `dx-persist` | Named volume mounted at the fixed guest path `/persist`. |
| `DX_GIT_MOUNT_SOURCE` | empty | Optional host directory bind-mounted by `dx-create-container`. Leave empty for plain `dx`; use `dx-mount` to set it for an isolated side container. |
| `DX_GIT_MOUNT_TARGET` | `/workspace` | Guest path for an explicit host checkout mount. |
| `DX_GUEST_WORKDIR` | empty | Optional guest workdir used by `dx-ssh`; `dx-mount` sets it to the mounted repo subdirectory. |
| `DX_CONTAINER_MEMORY` | `12G` | Memory passed to `container create`. `dx-mount` defaults this to `6G` unless explicitly overridden. |
| `DX_CONTAINER_CPUS` | `4` | CPU count passed to `container create`. `dx-mount` defaults this to `2` unless explicitly overridden. |
| `DX_CONTAINER_VOLUME_DIR` | `$HOME/Library/Application Support/com.apple.container/volumes` | Host directory where Apple Container stores named volume sparse images. Used for `dx-reclaim` reporting. |
| `DX_STOP_GRACE_SECONDS` | `5` | Seconds passed to `container stop --time` before the container CLI escalates. |
| `DX_STOP_COMMAND_TIMEOUT` | `15` | Host-side timeout for a `container stop` or `container kill` CLI command that hangs. |
| `DX_STOP_WAIT_TIMEOUT` | `5` | Seconds to wait for the container state to become stopped after each stop attempt. |
| `DX_DELETE_COMMAND_TIMEOUT` | `15` | Host-side timeout for a `container delete` CLI command that hangs. |

`DX_NIX_VOLUME` exists because the Nix store is large, persistent, and lives on
its own writable filesystem. Apple Container creates and mounts the volume at
`/var/lib/dx-nix-raw`; the guest bootstrap then formats the backing block
device as btrfs (or ext4 if the kernel lacks btrfs) and remounts it at `/nix`,
which requires `CAP_SYS_ADMIN` inside the guest (granted by
`bin/dx-create-container`). The default `dx-nix` volume preserves downloads
and activation state across container recreation, but only one running
container should use that writable volume at a time. For a clean lifecycle
test, use a separate Nix volume so the test cannot corrupt or lock the default
environment.

`/persist` is the fixed supported guest path for persisted files. Do not set
`DX_PERSIST_PATH`; path overrides are not supported. Setting old
`DX_WORKSPACE_VOLUME` or `DX_WORKSPACE_PATH` variables now fails early with a
rename message so existing `.env` files are not silently ignored.

### Mounting a Host Checkout (`dx-mount`)

Host bind mounts are intentionally not part of plain `dx`. Use `./bin/dx-mount
[DIR]` only when you explicitly want a host directory visible inside a
separate, isolated side container. The typical session is three commands:

```bash
# 1. Optional: preview the derived profile. Creates and starts nothing.
./bin/dx-mount ~/src/myrepo --print-env

# 2. Bring up the side container and connect. The host checkout appears at
#    /workspace inside the guest. Re-running the same command later
#    reattaches to the same side container.
./bin/dx-mount ~/src/myrepo

# 3. When finished, remove the side container and all of its private state.
./bin/dx-mount ~/src/myrepo --destroy
```

How it behaves:

- If `DIR` is inside a git repository, `dx-mount` mounts the repo top-level
  and maps the original subdirectory to the guest workdir under `/workspace`.
  Running it from different subdirectories of one repo reuses the same side
  container.
- The derived side container uses a `dx-mount-<slug>-<hash>` name, private
  Nix, persist, and bootstrap volumes, a private SSH key, and a derived
  non-default SSH port. It shares the immutable default image to avoid a
  rebuild. First boot is slow because the private Nix volume bootstraps a
  fresh store.
- It refuses `dx-host` and never destroys or recreates an existing container
  to change a mount; with `--container NAME`, an existing side container must
  match the recorded mount identity.
- If the derived SSH port is already in use before the side container exists,
  `dx-mount` refuses and tells you to pick a free port with `DX_SSH_PORT`.
- `--destroy` removes the derived side container, private volumes, private key
  pair, and mount identity marker. It does not remove the shared `dx-nixos-26.05` image.
  It also refuses to destroy default dx-host resources (`dx-nix`, `dx-persist`,
  `dx-bootstrap`, `dx_key`) even if your environment leaks those names into the
  cleanup.

Example isolated lifecycle create:

```bash
DX_IMAGE=dx-lifecycle \
DX_CONTAINER_NAME=dx-lifecycle \
DX_SSH_PORT=2299 \
DX_NIX_VOLUME=dx-lifecycle-nix \
DX_PERSIST_VOLUME=dx-lifecycle-persist \
DX_BOOTSTRAP_VOLUME=dx-lifecycle-bootstrap \
./bin/dx
```

### Profiles

Bundling those eight overrides into a one-line invocation is what
`tests/profiles/` and `bin/dx-profile` are for. A profile is a small shell
file that `export`s the variables you want to override; running anything
through `dx-profile <name>` sources the file and then execs the rest of the
command:

```bash
./bin/dx-profile dx-test ./bin/dx
./bin/dx-profile dx-test ./bin/dx-destroy
./bin/dx-profile dx-test ./bin/dx-recreate
```

Profiles are purely opt-in. Running any script without `dx-profile` (or
without manually sourcing a profile) leaves every variable unset, so the
defaults in `bin/dx-lib.sh` apply exactly as they would on a fresh shell —
`dx-host` on port `2222`, default volumes, default keys. Defaults are the
rule; profiles are the exception.

Shipped profiles:

- `tests/profiles/default.env` — documentation of the default values. Sourcing
  this file is a no-op; it exists as a template to copy when authoring a new
  profile.
- `tests/profiles/dx-test.env` — fully isolated `dx-test` environment. Test
  container, image, volumes, and SSH key all live in a `dx-test*` namespace
  alongside the primary `dx-host` resources, on port `2299` so both can run
  simultaneously.

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

The image does not contain the bootstrap repository. `dx-create-container`
mounts a dedicated `dx-bootstrap` volume at `/guest-bootstrap`, and
`dx-start-container` copies the local container configuration into that volume
at start time. After editing `container/.../flake.nix`,
`bootstrap.sh`, or related guest configuration, rerun `./bin/dx-sync-bootstrap`
against a running container rather than rebuilding the image.

## GitHub CLI Auth Persistence

The GitHub CLI (`gh`) is installed in the default DX toolset. Authenticate
inside the guest with:

```bash
gh auth login
```

`gh` uses `~/.config/gh` by default. The bootstrap links that path to
`/persist/home/dx/.config/gh`, so GitHub CLI configuration and auth state
survive `dx-recreate` and container rebuilds through the persistent volume.
This state is removed only by `dx-factory-reset`, `dx-destroy-volumes`,
or manually deleting the persist volume/path.

## Optional AI Tools

Codex, Gemini, Claude, and `agy` (Antigravity CLI) are intentionally not installed by
default. This keeps the standard DX environment free of AI CLIs, so they are not
available in secure, restricted, or work environments unless you explicitly opt in.

If AI tooling is approved for your environment, install or update the optional
AI tools bundle inside the guest:

```bash
dx-ai
```

This updates `nixpkgs-unstable` in `/guest-bootstrap`, then installs or upgrades
the `codex`, `gemini`, `claude`, and `agy` commands in the guest user's Nix profile.
The `dx-ai` helper is installed into `~/.local/bin` by Home Manager, the same
way `dx-theme` is installed.

### Bumping `agy` (Antigravity CLI)

`agy` is fetched as a pinned tarball from Google's release bucket (see the
`antigravity-cli` derivation in `container/.../flake.nix`). The binary ships with
a self-updater, but the Nix store is read-only, so `dx-ai` refreshes the local
flake pin from Google's CLI manifest before installing or upgrading `ai-tools`.

To inspect the upstream manifest manually:

```bash
# Linux arm64; substitute linux_amd64 / darwin_arm64 / darwin_amd64 as needed.
curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json
```

The manifest returns `{ "version": ..., "url": ..., "sha512": ... }`. `dx-ai`
converts `sha512` to a Nix SRI hash with `nix hash convert --hash-algo sha512
--to sri` and rewrites the local `/guest-bootstrap/flake.nix` pin before running
`nix profile add` or `nix profile upgrade`.

To update the checked-in fallback pin:

1. Replace the `version`, `src.url`, and `src.hash` in the `agy` derivation in
   `flake.nix`. `hash` uses SRI format: `sha512-<base64>`. Convert from the
   manifest's hex with:

   ```bash
   printf '%s' "<sha512-hex>" | xxd -r -p | base64 | tr -d '\n'
   ```

2. Re-sync the bootstrap payload and reinstall:

   ```bash
   ./bin/dx-sync-bootstrap
   ./bin/dx-ssh dx-ai
   ```

## NixVim Configuration

The editor configuration is managed via NixVim in `container/.../flake.nix`. This is the canonical path for all editor settings, plugins, and keymaps. Standalone `lazy.nvim` configurations are not supported.

## Theming

**Note on Terminal Compatibility:** Dynamic terminal theming relies on standard ANSI escape sequences (`OSC 4`, `OSC 10`, `OSC 11`) to change the 16-color palette, foreground, and background colors on the fly. **Apple's built-in `Terminal.app` explicitly does not support these sequences and will ignore them.** To use dynamic theming with `dx-theme`, you must use a modern terminal emulator that supports `OSC 4/10/11`, such as **Ghostty**, **iTerm2**, **Kitty**, or **Alacritty**.

Tinty theming is wired as an experimental, guest-driven runtime path. It does not edit host terminal configuration.

Aliases are declared in `home/theme.nix` (`dxThemes`) and rendered to
`~/.config/dx/themes.json` at activation time. `dx-theme list` shows the
full set. A representative subset:

```bash
dx-theme dark                  # base16-mocha
dx-theme light                 # base16-gruvbox-light-medium
dx-theme gruvbox-dark          # base16-gruvbox-dark-hard
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

On a fresh activation, DXE initializes the current Tinty scheme to the dark default (`base16-mocha`) if no previous theme has been selected. After that, `dx-theme` preserves the user's last selected theme, and activation only refreshes generated side files.

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
- **Recreate-Survival:** The Nix store (`/nix`) is stored on a dedicated Apple container volume. This means your downloaded packages and Nix configuration persist even if you delete and recreate the container with `dx-recreate` (or any manual sequence of `dx-destroy-container` and `dx-create-container`).
- **Single-Writer Constraint:** Only one running container may mount the dx-nix volume at a time. If you need a second concurrent container, it will need its own volume name or you must wait for the first container to stop.
- **Optimization:** The filesystem is formatted with btrfs and zstd:3 compression. Nix's auto-optimise-store is enabled to deduplicate identical files at the hardlink level, further saving space.
- **Bootstrap Payload:** `/guest-bootstrap` is backed by the `dx-bootstrap`
  volume and populated from the local checkout at start time, keeping repository
  changes out of the image layer.

## Troubleshooting

### Resetting the Environment (Stale Dependencies)

If the guest bootstrap fails due to stale dependencies or a corrupted Nix store
in the persistent volume, you can perform a "hard reset" to clear the cache and
start fresh:

1. **Tear down the container and image (volumes preserved):**
   ```bash
   ./bin/dx-destroy
   ```
2. **Delete and recreate the persistent Nix volume:**
   ```bash
   container volume delete dx-nix
   container volume create dx-nix
   ```
3. **Bring everything back up:**
   ```bash
   ./bin/dx
   ```
   *Note: This will trigger a full download of all Nix packages during the next bootstrap.*

For a complete wipe (including `/persist` contents and SSH keys), use
`./bin/dx-factory-reset` — it prompts for confirmation before removing anything.

### Checking Bootstrap Logs
After a factory reset, `./bin/dx` must repopulate the complete Nix store before
SSH starts. The command waits for the full bounded retry period and prints a
recent bootstrap log line every 30 seconds. To monitor the complete bootstrap
output from another terminal:
```bash
container logs dx-host -f
```

## Release and Pin Maintenance

> Status: this section is the maintenance contract for the single official
> `nixos/nix` base image. A dual-base flip was once considered and dropped
> in favor of a one-time, one-way changeover onto the single official base
> — no `DX_BASE` selector, no flavor names, no coexistence. See
> [Base Image Changeover](#base-image-changeover-one-time) below for the
> cutover runbook.

### One release pin

The NixOS release is pinned in exactly one file — the flake inputs in
`container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.nix`:

```nix
nixpkgs.url      = "github:nixos/nixpkgs/nixos-26.05";
nixvim.url       = "github:nix-community/nixvim/nixos-26.05";
home-manager.url = "github:nix-community/home-manager/release-26.05";
```

`flake.lock` records the concrete revisions those branches resolved to
(`nixvim` and `home-manager` follow this flake's `nixpkgs` for their own
package set):

- the full guest toolset follows the lock — Home Manager activation builds
  from this flake;
- the root bootstrap essentials do **not** yet follow the lock —
  `install_essentials` resolves `nixpkgs#…` through the **global flake
  registry** (pinning them to the guest lock with
  `--inputs-from /guest-bootstrap --no-update-lock-file` is a follow-up, not
  yet implemented — see the caveat below and "Bootstrap nixpkgs pin and
  provenance" tracking).

The base image is release-agnostic: it contributes the Nix tool itself and
a seed store that is merged once and then inert — after bootstrap, every
tool in use resolves through the lock. The release string also appears in
*names* (the context directory, the `dx-nixos-26.05*` image names); those
are identity labels refreshed during a release bump, not additional pins.
The local image name (`dx-nixos-26.05`) is a **mutable local cache key,
never provenance** — see "Build-cache trap" below; it says nothing about
which `Containerfile` produced the image bits.

After the base changeover (below), the docker-nixpkgs release-tag
availability gate that previously blocked the 26.05 upgrade is **gone**.
Release maintenance is **not** thereby reduced to two flake edits: it still
includes lock regeneration, `home.stateVersion` review, the aligned Nix
image-pin review (below — a release bump can change the correct image
tag), identity-name updates (context directory, local image name),
release-string test updates, and revalidation — see
[plan.md](plan.md)'s playbook. And until the bootstrap lock pin lands (a
follow-up, not yet implemented), root bootstrap essentials still resolve
through the **global flake registry**, not the guest lock — this document
must not claim otherwise.

A release bump is therefore:

```bash
# 1. One place: edit the three branch refs in flake.nix (one file, one commit).
# 2. Re-lock the stable inputs only — run in the guest, or anywhere with Nix;
#    the macOS host needs none. --flake targets the context dir (the repo root
#    is not a flake); nixpkgs-unstable is left untouched so the optional AI set
#    does not move during a stable release bump:
nix flake update nixpkgs nixvim home-manager \
    --flake container/aarch64-darwin-apple-container-dx-nixos-26.05
# 3. Check the base-image alignment rule (below), then recreate and validate:
./bin/dx-recreate
tests/run_all_tests.sh
```

For the complete step-by-step procedure (image pre-flight, canary, and the
destructive apply), follow [Upgrade / Bump](#upgrade--bump-new-nixos-release).

The full release playbook, including the context-directory rename and the
parallel validation instance, is in [plan.md](plan.md).

### Base-image alignment rule

`Containerfile` pins the official image by Nix version and manifest-list
digest:

```Dockerfile
FROM nixos/nix:2.34.7@sha256:<manifest-list digest>
```

Policy:

- match the major.minor of the pinned release's default Nix
  (`nixpkgs#nix.version` at the locked revision, i.e. `nixVersions.stable`),
  taking the newest patch tag within that minor. Bumping the release
  therefore tells you the correct image tag mechanically, and the
  Nix-version bump folds into the same deliberate event instead of being an
  independent chore;
- explicit tag **plus** the tag's multi-platform manifest-list digest (what
  `container image pull nixos/nix:<tag>` resolves) — never `latest`; a
  digest-only reference (no tag) is rejected;
- **re-query the digest immediately before any change** — never copy a
  previously recorded digest blind. Tags are mutable; a stale digest can
  silently pin different content than the tag currently resolves to.

A post-activation in-guest `nix --version` cannot verify the alignment —
the guest toolset itself ships the locked `nix`, which shadows the image's
on `PATH`. Verify against the pristine image directly instead:

```bash
container run --rm nixos/nix:<tag>@sha256:<digest> nix --version
```

This must match the tag's major.minor, and that in turn must match the
release's default Nix — checked in the guest (the macOS host has no Nix):

```bash
container exec dx-host nix eval --raw --no-update-lock-file --inputs-from /guest-bootstrap nixpkgs#nix.version
```

The alignment is test-enforced rather than templated into the
Containerfile: the Containerfile is deliberately a single `FROM` line (no
`ARG` indirection), and the macOS host has no Nix with which to evaluate
the version at build time.

### Build-cache trap

`dx-create-image` skips the build whenever the local image name
(`dx-nixos-26.05`) already exists — editing the Containerfile changes
nothing until the old image is removed. `./bin/dx-destroy` removes
container **and** image; `./bin/dx-factory-reset` additionally removes all
three volumes and the SSH keypair (confirmation-gated, `--force` to skip).
Both operate only on the resources the active profile resolves.

### Bumping the Nix image pin — unresolved pending store-reuse fixes

**There is currently no valid, volume-reusing pin-bump procedure.**
Two defects block one, both rooted in `setup_nix_volume`'s store handling:

- a reused `/nix` volume's profile paths can keep resolving `nix` to the
  **old** image's binary even after a new image is built, so a naive
  transition check can silently validate the wrong binary;
- the store-seeding merge copies `/nix/store` paths onto the volume without
  registering them in the volume's store database — copied paths exist on
  disk but are invisible to `nix path-info` and unprotected from garbage
  collection.

Until both are fixed (their own design change, tracked as a follow-up),
**the only safe way to bump the Nix image pin is a full destroy-and-rebuild
with salvage** — the same one-time changeover procedure below (quiesce and
salvage `/persist`, referrer-first inventoried cleanup, factory reset,
rebuild, validate), not an in-place volume-reusing bump. What *is* safe to
rely on today: the alignment rule above, this section's build-cache trap
warning, and the digest re-query discipline.

## Upgrade / Bump (new NixOS release)

The step-by-step runbook for moving the pinned release, e.g. **26.05 →
26.11**. This is the sequence validated on the 25.11 → 26.05 bump
(2026-07-04); the reference policy it leans on lives in
[Release and Pin Maintenance](#release-and-pin-maintenance) above, and the
destructive apply in step 7 is [Base Image Changeover](#base-image-changeover-one-time)
below. Throughout, **OLD** is the current release (e.g. `26.05`) and
**NEW** is the target (e.g. `26.11`).

**Two hard-won rules before you start:**

- **Static checks do not catch the breakages that cost the most time.**
  `nix flake check` catches *eval*-time breaks (a removed package). It does
  **not** catch `home-manager` buildEnv path conflicts or runtime shell/tool
  API changes — those surface only at **live Home Manager activation**, i.e.
  at the canary in step 6. On the 26.05 bump, three separate breaks
  (`neofetch` removed, `ghostty.terminfo` colliding with ncurses, nushell's
  `$nu.home-path` renamed to `$nu.home-dir`) each slipped past the static
  suite and were caught only by rebuilding a real guest.
- **`nix flake check` needs a roomy container** (≥ 8 GB). The default
  container size OOMs mid-evaluation and is `SIGKILL`ed, which can look like
  a pass if you only check the exit path — always give it memory and read
  the final `all checks passed!` line.

### 1. Preconditions

- NEW's flake input branches exist and resolve — check without changing
  anything (throwaway container; the macOS host has no Nix):

  ```bash
  IMG='nixos/nix:2.34.7@sha256:<current pinned digest>'   # current base is fine
  for ref in \
      github:nixos/nixpkgs/nixos-26.11 \
      github:nix-community/home-manager/release-26.11 \
      github:nix-community/nixvim/nixos-26.11; do
    container run --rm "$IMG" nix --extra-experimental-features 'nix-command flakes' \
        flake metadata "$ref" >/dev/null 2>&1 \
        && echo "OK  $ref" || echo "MISSING  $ref"
  done
  ```

  If `home-manager/release-NEW` or `nixvim/nixos-NEW` is not published yet,
  **wait** — do not promote a mixed stable/unstable combination.
- Clean configuration surface (same precondition as the changeover):
  `env | grep '^DX_'` prints nothing, and `.env` is absent or reviewed
  line by line.
- A working tree with no unrelated changes (section 13 rejects a dirty
  tree, and the canary must validate a committed bump).

### 2. Pick the aligned Nix image pin

The base image is pinned by **Nix version**, not NixOS release, per the
[Base-image alignment rule](#base-image-alignment-rule). A release bump can
therefore change the correct image tag. Determine NEW's default Nix and
choose the newest patch tag of that minor:

```bash
# NEW's default Nix version (throwaway container, locked to NEW's nixpkgs):
container run --rm "$IMG" nix --extra-experimental-features 'nix-command flakes' \
    eval --raw 'github:nixos/nixpkgs/nixos-26.11#nix.version'
# → e.g. 2.36.1  ⇒  pin the newest nixos/nix:2.36.x tag
```

Then **re-query the manifest-list digest from Docker Hub immediately**
(never copy a digest blind — tags are mutable) and confirm the tag has a
`linux/arm64` manifest. This exact `tag@sha256:digest` is what lands in the
`Containerfile`.

### 3. Pre-flight the new image (throwaway containers, no repo change)

Prove the pinned reference before editing anything:

```bash
NEW_IMG='nixos/nix:2.36.1@sha256:<re-queried digest>'
container run --rm "$NEW_IMG" /usr/bin/env bash -c 'echo env-bash-ok'
container run --rm "$NEW_IMG" nix --version                 # matches the tag
container run --rm --entrypoint sh "$NEW_IMG" -c \
    'if [ -e /bin/bash ] || [ -L /bin/bash ]; then echo OLD_BASE; else echo OK-no-bin-bash; fi'
mkdir -p /tmp/pf && printf 'FROM %s\n' "$NEW_IMG" > /tmp/pf/Containerfile \
    && container build -t dx-preflight -f /tmp/pf/Containerfile /tmp/pf \
    && container image rm dx-preflight        # digest-pinned FROM must build
```

`OK-no-bin-bash` is required — the official base ships no `/bin/bash`, which
is what the temporary old-base guards key on.

### 4. Make the bump (one revertible commit)

Do these together so the lock diff has a single cause. TDD where a test
encodes the change: flip the failing test first (`test_helpers.sh`'s
`DX_EXPECTED_NIXOS_RELEASE`, `test_section2_containerfile.sh`'s exact `FROM`
line), watch it fail against OLD, then make it pass.

- `git mv container/aarch64-darwin-apple-container-dx-nixos-OLD container/aarch64-darwin-apple-container-dx-nixos-NEW`
- `flake.nix` inputs → the three NEW branches (`nixpkgs-unstable` stays on
  `master`).
- Regenerate `flake.lock` — targeted, in a throwaway container bind-mounting
  the renamed context dir:

  ```bash
  container run --rm -v "$PWD/container/aarch64-darwin-apple-container-dx-nixos-NEW:/ctx" "$IMG" \
      nix --extra-experimental-features 'nix-command flakes' \
      flake update nixpkgs nixvim home-manager --flake /ctx
  ```
- `home.nix`: `home.stateVersion = "NEW"` (review the Home Manager
  state-version notes first).
- `Containerfile`: the single `FROM` line to the step-2 `tag@sha256:digest`,
  and update the exact-line string in `tests/test_section2_containerfile.sh`.
- `bin/dx-lib.sh` defaults: `DX_IMAGE=dx-nixos-NEW` and `DX_CONTEXT_DIR`.
- `tests/test_helpers.sh`: `DX_EXPECTED_NIXOS_RELEASE=NEW`.
- Release-string sweep — update every **live** reference, leave design
  history alone:

  ```bash
  grep -rn 'OLD' bin tests container README.md   # e.g. grep -rn '26\.05' ...
  ```

  Update `dx-nixos-OLD` image names, the `dx-nixos-OLD` assertions in
  `tests/test_section18_mount_git.sh`, profile `.env` comments, and this
  file's examples. Leave `plan.md`'s OLD/NEW playbook framing as history.
- Static gate — all green, plus a roomy `flake check`:

  ```bash
  # Note the underscore in the glob: test_section${s}_*.sh matches only
  # section s. Bare test_section$s*.sh would let s=1 also match 10-19 and
  # s=2 also match 20.
  for s in 0 1 2 3 5 9 10 18 20; do bash tests/test_section${s}_*.sh || break; done
  container run --rm --memory 8g --cpus 4 \
      -v "$PWD/container/aarch64-darwin-apple-container-dx-nixos-NEW:/ctx" "$NEW_IMG" \
      nix --extra-experimental-features 'nix-command flakes' \
      flake check --no-write-lock-file /ctx        # must end: all checks passed!
  ```

  Commit as one "Bump the pinned release to NixOS NEW" commit.

### 5. Fix compatibility breaks (separate commits, TDD)

`nix flake check` will name any **removed / renamed package** (eval error) —
fix each in `flake.nix` (e.g. `neofetch` → `fastfetch`) as its own commit
with the check as the gate. The **activation-only** breaks (buildEnv path
conflicts, shell/tool API changes) are not visible yet; they surface at the
canary in step 6. Keep every compat fix a separate commit from the raw bump
so a lock diff and a package swap never share a commit.

### 6. Canary — rebuild the isolated `dx-test` profile (non-destructive)

Gate the primary on a full, from-scratch NEW build of the throwaway
profile. This is where activation-only breaks appear; fix each (own commit),
restart, and re-run until green:

```bash
./bin/dx-profile dx-test ./bin/dx-destroy
./bin/dx-profile dx-test ./bin/dx-destroy-volumes --force
./bin/dx-profile dx-test ./bin/dx-destroy-keys
./bin/dx-profile dx-test ./bin/dx                      # fresh NEW bootstrap
./bin/dx-profile dx-test bash tests/run_all_tests.sh   # must be all-green
# Confirm the release oracle actually reports NEW (not a stale default):
./bin/dx-profile dx-test ./bin/dx-ssh \
    "bash -lc 'grep VERSION_ID /etc/os-release; nix --version'"
```

**Do not touch the primary until this is all-green and reports NEW.**

### 7. Apply to the primary

Because there is still **no valid volume-reusing pin-bump procedure** (see
[Bumping the Nix image pin](#bumping-the-nix-image-pin--unresolved-pending-store-reuse-fixes)
— blocked on the `setup_nix_volume` store-reuse defects), a pin-changing
bump reaches the primary the same way the base changeover did: **full
destroy-and-rebuild with salvage.** Follow
[Base Image Changeover](#base-image-changeover-one-time) below verbatim —
salvage `/persist` first (the `dx-get`/`dx-put` round-trip is now reliable),
inventory referrer-first, `dx-factory-reset`, rebuild on the NEW commit,
pass the old-base exclusion gate and the full suite, then re-establish
`gh auth` / `dx-ai` / repos. (Only once the store-reuse fixes land, and only
for a bump that does **not** change the Nix image pin, would an in-place
`./bin/dx-recreate` become a valid volume-reusing alternative.)

### 8. After the bump

- Remove any now-stale OLD image left behind (`container image ls`;
  `container image rm dx-nixos-OLD` once no container references it) — see
  the [Build-cache trap](#build-cache-trap).
- Update the concrete release numbers and the current digest in **this**
  section and in [Release and Pin Maintenance](#release-and-pin-maintenance)
  so the next bump starts from accurate examples.
- Once every machine and profile is on the new base, the temporary old-base
  guards (`guard_old_base` in `bootstrap.sh`, its twin in
  `dx-start-container`, and their tests) can be removed in a cleanup commit.

## Base Image Changeover (one-time)

> This is a **one-time, destructive** cutover — not a recurring maintenance
> task, and not a live flip. It replaces the (now removed) third-party,
> per-release community-published base with the official, digest-pinned
> `nixos/nix` base defined above. There is no in-place migration: existing machines are
> destroyed and rebuilt from scratch, with an auditable one-time `/persist`
> salvage step. This section is the guarded runbook for that changeover —
> each step copyable, with expected output, safe behavior when the resource
> it targets is already absent, an abort condition, and a verification
> before you continue to the next step.

### Clean-configuration precondition — required before every destructive step below

Two configuration surfaces can silently redirect a destructive command at
the wrong (including default) resources. Verify both before step 1 of the
changeover procedure, and re-verify before any later destructive step if
you are not running the whole procedure in one sitting:

- **`.env`** is sourced **as shell code** (`set -a`) by every child script,
  *after* the parent script has already exported its own values — so *any*
  line in it executes, and a `DX_*` line there silently re-overrides the
  profile's or `dx-mount`'s own exports. `.env` must be **absent, or
  reviewed line by line** — not merely free of `DX_*` entries.
- **Inherited `DX_*` environment**: exported variables in your shell
  survive into every resolution — `dx-mount` in particular captures
  pre-set values as user-supplied before it even sources the shared
  library. Confirm:

  ```bash
  env | grep '^DX_'
  ```

  Expected output: **nothing**. If anything prints, unset it, or print and
  review every effective resource name immediately before each destructive
  command below.

Destroying under a clobbered or polluted resolution is strictly worse than
validating under one — do not proceed past this point until both checks
are clean.

### Canary gate — required before the primary is touched

Before anything on the real machine is destroyed, prove a full
official-base bootstrap works, in isolation, on the exact commit that will
land:

1. Create a dedicated cutover profile (the `tests/profiles/dx-test.env`
   pattern): a unique container name, image name, SSH port, all three
   volume names, and its own key pair.
2. Re-check the clean-configuration precondition above — an unisolated
   `.env` or environment defeats canary isolation too.
3. **Assert absence** — confirm the cutover profile's container, image,
   volumes, and keys do not already exist:

   ```bash
   container list -a
   container image ls
   container volume ls
   ```

   Expected: nothing named after the cutover profile. **Abort condition**:
   any of them already exist — pick different names or clean up first.
4. Bring it up on the branch carrying the new `FROM` line:

   ```bash
   ./bin/dx-profile <cutover> ./bin/dx
   ```

   Expected: bootstrap completes and SSH is reachable under the profile.
5. Run the full suite, profile-aware, from a **clean, committed tree** —
   `test_section13_final_review.sh` fails on tracked modifications by
   design, so this validates the changeover **commit**, never a dirty
   working tree. Then run the same-base recreate cycle, to prove volume
   reuse still works on the new base:

   ```bash
   ./bin/dx-profile <cutover> tests/run_all_tests.sh
   ./bin/dx-profile <cutover> ./bin/dx-destroy
   ./bin/dx-profile <cutover> ./bin/dx
   ```
6. Tear the canary down completely, in this order:

   ```bash
   ./bin/dx-profile <cutover> ./bin/dx-destroy
   ./bin/dx-profile <cutover> ./bin/dx-destroy-volumes --force
   ./bin/dx-profile <cutover> ./bin/dx-destroy-keys
   ```

   Verify: `container list -a` / `container image ls` / `container volume
   ls` show nothing named after the cutover profile, and its key files are
   gone.

**Abort condition**: any canary step fails, or teardown leaves a resource
behind. Do not start the changeover procedure until the canary passes
cleanly end to end. The primary factory reset (step 4 below) is gated on
this run passing.

### Changeover procedure (per machine)

**Ordering rule**: destroy referrers before resources. `container image
rm` / `container volume rm` fail while any container still references the
target, and that can strand a half-reset machine mid-procedure. Every step
below is safe to re-run; **step 2 (inventory) is the re-entry point** if
you stop partway, and nothing destroys the primary before step 4.

1. **Quiesce and salvage `/persist`.** Stop active guest workloads; push
   every repository and verify the remotes are up to date. Then:

   ```bash
   ./bin/dx-get /persist ./persist-backup-$(date +%Y%m%d)
   ```

   **Inspect the copied tree by eye before continuing — this is not
   optional.** `dx-export` is **not** a substitute: it wraps `container
   export`, which captures the root filesystem only, not named-volume
   contents. Record what is deliberately not preserved (for example
   gh/AI credentials — these are re-established in step 9, not salvaged).

   **Abort condition**: the backup looks incomplete or wrong — stop and
   investigate before touching anything else.

2. **Inventory and deletion ledger.** Enumerate every resource that will be
   removed, and write it down (a text file, a scratch note — anything you
   check step 5 against):

   ```bash
   container list -a
   ls ~/.dx-cache/mount-identities/ 2>/dev/null   # absent is fine — no side containers
   ```

   For **every** profile file — `tests/profiles/*.env` and any
   user-maintained profiles — read its image, volume, and key values into
   the ledger **even when no container currently exists for it**:
   container inspection alone cannot discover an orphaned profile's image,
   volumes, or keys. Cross-check for unaccounted `dx-*` strays:

   ```bash
   container image ls
   container volume ls
   ```

   Then run `container inspect <name>` on **each** container in the list
   and read the output yourself — `container list -a` shows images but
   **not** volume mounts, so volume referrers are visible only this way.
   While reading, add to the ledger every container, image, and volume
   (persist/bootstrap, custom-profile, and side-container volumes alike),
   key file, and identity marker that is slated for removal.

   Any container referencing a ledgered image or volume **must** be
   destroyed in step 3 — it cannot be deferred, since the resource removal
   later fails while it is still referenced. Leave alone only containers
   referencing nothing ledgered (for example Apple's own `buildkit`
   builder).

   **Abort condition**: you cannot account for a `dx-*` resource — stop
   here, not mid-reset.

3. **Destroy non-default referrers, staged globally referrer-first.** Do
   this in three stages, not per-unit — the per-unit tools interleave
   container and resource removal, so staging avoids a resource shared
   *across* units (the default image every side container references, or
   an override-shared volume) failing mid-unit:

   - **3a — containers only**, every ledgered container:

     ```bash
     ./bin/dx-profile dx-test ./bin/dx-destroy-container
     ./bin/dx-profile dx-tinty ./bin/dx-destroy-container
     # ... and any custom profiles
     DX_CONTAINER_NAME=<name> ./bin/dx-destroy-container   # per side container
     ```

   - **3b — verify**: `container list -a` shows no ledgered container.
     **Abort condition**: any survives — stop and resolve before 3c.

   - **3c — resources**, through the same guarded tools (each is verified
     idempotent on already-missing resources, so re-running any of these is
     always safe):

     - side containers still attached to their checkout:

       ```bash
       ./bin/dx-mount <source-dir> --destroy
       ```

     - an **orphaned** side container (checkout moved or deleted) — do
       **not** try to recreate the directory to make the normal form work;
       `dx-mount` resolves identity via `git rev-parse --show-toplevel`,
       so a recreated empty directory can resolve into an *enclosing* Git
       root and derive the wrong identity. Instead, in two separate
       invocations:

       ```bash
       ./bin/dx-mount --container <name> --print-destroy-plan
       # reconcile the printed plan against your ledger, THEN:
       ./bin/dx-mount --container <name> --destroy
       ```

     - shipped profiles:

       ```bash
       ./bin/dx-profile dx-test ./bin/dx-destroy
       ./bin/dx-profile dx-test ./bin/dx-destroy-volumes --force
       ./bin/dx-profile dx-test ./bin/dx-destroy-keys
       # repeat the same triple for dx-tinty and any custom profiles
       ```

4. **Factory-reset the primary** — gated on the canary gate above having
   passed:

   ```bash
   ./bin/dx-factory-reset
   ```

   Removes the primary container, image, all three volumes, and keys
   (confirmation-gated).

5. **Verify the ledger, not a hardcoded list.** Every entry recorded in
   step 2 must now be absent: containers via `container list -a`, images
   via `container image ls`, **all** volumes via `container volume ls`
   (persist/bootstrap, custom-profile, and side-container volumes alike),
   key files, and identity markers on the host filesystem.

   **Abort condition**: any ledger entry survives — return to step 2.

6. **Rebuild:**

   ```bash
   ./bin/dx
   ```

   Fresh image from the edited Containerfile, fresh volume seed, fresh
   bootstrap.

7. **Old-base exclusion gate.** `/bin/bash` absence **excludes** the known
   flakes base — it does not by itself prove the image is `nixos/nix` at
   the pinned digest. Positive provenance instead comes from the
   digest-pinned `FROM`, the ledger-verified image removal in step 5, and
   the fresh rebuild in step 6 — exact-content provenance only under the
   digest pin; base-family only under a tag-only waiver. Run exactly this
   — it fails closed on any `container exec` error, and treats absence as
   a positive token, never as the fallback branch of a failed probe:

   ```bash
   state="$(container exec dx-host sh -c \
       'if [ -e /bin/bash ] || [ -L /bin/bash ]; then echo OLD_BASE; else echo OLD_BASE_ABSENT; fi')" \
       || { echo "FAIL: could not verify (container exec error)"; exit 1; }
   case "$state" in
       OLD_BASE_ABSENT) echo "OK: old flakes base excluded (no /bin/bash)" ;;
       OLD_BASE)        echo "FAIL: /bin/bash present — still the old flakes base"; exit 1 ;;
       *)               echo "FAIL: unexpected verification output: $state"; exit 1 ;;
   esac
   ```

   Expected output: `OK: old flakes base excluded (no /bin/bash)`. Any
   other output is a hard stop. The same invariant is also enforced by a
   pair of temporary guards on every container boot and every
   `dx-start-container` bring-up, for as long as they remain in the tree
   (see the temporary old-base guards described above) — this manual gate exists because a
   bring-up against an **already-running** container only re-syncs the
   bootstrap payload; it does not by itself prove which image is running.

   **Accepted residual window**: `dx-ssh` and `dx-enter` bypass
   `dx-start-container`, so a direct session against an
   **already-running old container**, between pulling this change and that
   container's next start or restart, is caught by no guard. The window
   closes at the next lifecycle touch; it does not exempt you from running
   this gate.

8. **Validate:**

   - [ ] `./bin/dx` completed bootstrap; sshd reachable; `dx-enter` works.
   - [ ] Full test suite passes.
   - [ ] Old-base exclusion gate (step 7) passes; neither temporary guard
         fired during the rebuild.
   - [ ] AI-tools opt-in path (`dx-ai`, keyring, persistence links) works.
   - [ ] Timezone, persist links, and `gh` persistence are intact after a
         `dx-destroy && dx` cycle — same-base volume reuse is revalidated,
         not assumed, on the new base.
   - [ ] Both shipped profiles (`dx-test`, `dx-tinty`) rebuild from scratch
         and pass their suites (their old images/volumes were removed in
         step 3).

9. **Re-establish intentional state — last, only after validation
   passes:** `gh auth login`, `dx-ai` opt-in, re-clone into `/persist`.
   Anything deliberately not salvaged in step 1 is re-created here, not
   before.

**Rollback**: `git revert` the changeover commit, then repeat this same
procedure in reverse. Fresh volumes both directions, so no store-schema
compatibility proof is needed — but the flakes tag is **mutable**:
rollback restores the old base family and release label, not necessarily
byte-identical content (mitigate by recording the pulled flakes digest
during pre-flight if that matters), and it presumes the flakes `25.11` tag
is still published.

## Planned Work

- **[NixOS 26.05 upgrade & code-review fixes](plan.md)** — the release-bump playbook (previously gated on a third-party base-image tag; that gate is gone, see [Base Image Changeover](#base-image-changeover-one-time) — now waiting only on the target release's flake input branches) plus eight consolidated code-review fixes against the current 25.11 codebase. See [Consolidated Code-Review Fixes](plan.md#consolidated-code-review-fixes) for the per-item status.
- ~~**Dual base-image support**~~ — **done, differently**: the plan to select between two base images was replaced with a one-time, one-way changeover onto the single official, digest-pinned `nixos/nix` image — no `DX_BASE`, no flavors, no coexistence; the third-party per-release base dependency is removed. Maintenance contract: [Release and Pin Maintenance](#release-and-pin-maintenance); cutover runbook: [Base Image Changeover](#base-image-changeover-one-time).
- **[Tmux configuration improvements](tmux-plan.md)** — migrate option-shaped tmux settings to typed Home Manager options and add resurrect/continuum persistence. Not started; sliced for TDD with manual validation gates.
- **Git-access follow-ups** — the `dx-mount` side-container workflow has shipped; remaining items are the `dx-branch` self-dev helper, seeded Nix base for faster side-container cold starts, credential propagation, and worktree/submodule validation.
