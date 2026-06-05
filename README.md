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
- **Transfer Files:** `./bin/dx-put <host_path> [guest_path]`
- **Stop the Container:** `./bin/dx-stop-container`
- **Push edited bootstrap payload to a running guest:** `./bin/dx-sync-bootstrap`

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
| [`bin/dx-wait-ssh`](bin/dx-wait-ssh) | Blocks until guest SSH responds. Gates the SSH connection layer. |
| [`bin/dx-status`](bin/dx-status) | Reports image, container, SSH, tool, persist, and tmux status. |
| [`bin/dx-put`](bin/dx-put) | Copies host files into the guest. |
| [`bin/dx-enter`](bin/dx-enter) | Direct `container exec` shell, bypassing SSH. |
| [`bin/dx-gc`](bin/dx-gc) | Runs Nix garbage collection and store optimization inside the guest. |
| [`bin/dx-reclaim`](bin/dx-reclaim) | Reclaims host disk space by deleting old Nix generations in the guest and trimming persistent filesystems. |
| [`bin/dx-export`](bin/dx-export) | Archives the container to a tar file. |
| [`bin/dx-nix-disk`](bin/dx-nix-disk) | Prepares a sparse Nix disk image; lifecycle-adjacent storage prep. |
| [`container/.../bootstrap.sh`](container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh) | Runs inside the guest from the synced payload; configures `/nix`, the `dx` user, SSH, Home Manager, shell, tmux, and tools. |

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
| `DX_IMAGE` | `dx-nixos-25.11` | Image name used by `dx-create-image` and `dx-create-container`. |
| `DX_SSH_PORT` | `2222` | Host port forwarded to guest SSH port `2222`. Use a different port for a second running container. |
| `DX_SSH_KEY` | `$DX_PROJECT_ROOT/dx_key` | Host private key used for SSH into the guest. |
| `DX_SSH_KEY_PUB` | `$DX_PROJECT_ROOT/dx_key.pub` | Host public key provisioned into the guest on create. |
| `DX_SSH_CONNECT_TIMEOUT` | `15` | Host-side SSH connection timeout in seconds for `dx-ssh`. |
| `DX_CONTEXT_DIR` | `container/aarch64-darwin-apple-container-dx-nixos-25.11` | Directory used as the image build context and default bootstrap source. |
| `DX_BOOTSTRAP_SOURCE` | `$DX_CONTEXT_DIR` | Host directory pushed into the clean guest bootstrap volume. Override this to test a different bootstrap checkout without rebuilding the image. |
| `DX_BOOTSTRAP_VOLUME` | `dx-bootstrap` | Named volume mounted at `/guest-bootstrap` by default. It stores the pushed bootstrap payload outside the image layer. |
| `DX_BOOTSTRAP_PATH` | `/guest-bootstrap` | Guest path where the bootstrap payload is mounted and executed. |
| `DX_BOOTSTRAP_WAIT_TIMEOUT` | `30` | Seconds `dx-sync-bootstrap` waits for the guest entrypoint to report bootstrap readiness before failing with a log hint. |
| `DX_NIX_VOLUME` | `dx-nix` | Named volume that backs the persistent Nix store. Apple Container surfaces it inside the guest at `/var/lib/dx-nix-raw`; the bootstrap reformats it as btrfs (or ext4 as a fallback) and remounts it at `/nix`. Override this for isolated test containers or parallel experiments so they do not share the default writable Nix store. |
| `DX_NIX_MOUNT` | `/nix` | Guest mount point for the active Nix filesystem. Used by maintenance commands such as `dx-reclaim`. |
| `DX_PERSIST_VOLUME` | `dx-persist` | Named volume mounted at the fixed guest path `/persist`. |
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
If you cannot connect via SSH, monitor the bootstrap progress on the host:
```bash
container logs dx-host -f
```

## Planned Work

- **[NixOS 26.05 upgrade & code-review fixes](plan.md)** — the release-bump playbook (waiting on the official 26.05 base image) plus eight consolidated code-review fixes against the current 25.11 codebase. See [Consolidated Code-Review Fixes](plan.md#consolidated-code-review-fixes) for the per-item status.
