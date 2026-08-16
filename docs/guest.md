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

## Herdr Configuration and Session Persistence

Bootstrap links Herdr's writable paths into the persistent volume:

- `~/.config/herdr` points to `/persist/home/dx/.config/herdr` for
  `config.toml`, logs, and other configuration-owned files.
- `~/.local/state/herdr` points to `/persist/home/dx/.local/state/herdr` for
  session and runtime state.

The repository-owned defaults live in
`container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/herdr-config.toml`.
On bootstrap, the adjacent `bootstrap/herdr-config.sh` module atomically adds missing
defaults to the persisted `config.toml`; explicit existing values win,
occupied key bindings are not duplicated, and unrelated UI or theme tables
are preserved. When a Herdr binary is available, the merged candidate must
pass `herdr config check` before it replaces the live file.

Session contents are mutable state and are deliberately not committed to Git;
they survive container rebuilds through `/persist`. A factory reset or removal
of the persist volume removes both Herdr configuration and session state, after
which bootstrap recreates `config.toml` from the checked-in defaults.

## Optional AI Tools

Codex, Gemini, Claude, `agy` (Antigravity CLI), and `herdr` are intentionally not installed by
default. This keeps the standard DX environment free of AI CLIs, so they are not
available in secure, restricted, or work environments unless you explicitly opt in.

If AI tooling is approved for your environment, install or update the optional
AI tools bundle inside the guest:

```bash
dx-ai
```

`dx-ai` copies the immutable `/guest-bootstrap` source into a new mutable
generation under `/persist/home/dx/.local/state/dx-ai`, updates
`nixpkgs-unstable` there, then atomically publishes that generation before
installing or upgrading the `codex`, `gemini`, `claude`, `agy`, and `herdr`
commands in the guest user's Nix profile. It never modifies the published
bootstrap. The `dx-ai` helper is installed into `~/.local/bin` by Home
Manager, the same way `dx-theme` is installed.

Connect to Herdr from the host using:

```bash
dx-herdr
```

If Herdr is not yet installed in the guest, `dx-herdr` checks whether the installed
`dx-ai` generation supports Herdr and, if so, installs the optional AI tools bundle
**without prompting for confirmation** before attaching to the default Herdr session.
If the installed `dx-ai` helper predates Herdr support, `dx-herdr` fails with an
instruction to run `dx-recreate` rather than guessing at a fix.
`dx-herdr` also verifies the persistent Herdr configuration and state links
before it attaches; if bootstrap could not prepare them, it reports the repair
step (`dx-recreate`) instead of starting an ephemeral session.

### Herdr session persistence

Herdr's configuration, default session, and pane history persist under
`~/.config/herdr` (mode `0700`), and its mutable application state (downloaded
agent-detection rules, plugin state, announcement state) persists under
`~/.local/state/herdr` (mode `0700`). Both directories survive `dx-recreate` and
container rebuilds through the persistent volume, and both are included in
`/persist` backups.

**Sensitive-output warning.** Herdr's pane history
(`~/.config/herdr/session-history.json`) serialises visible terminal output —
pasted tokens, `env` output, `gh auth token`, `cat` of config files, agent
conversations. Pane history is off by default upstream for exactly this reason.
Persisting it makes that transient terminal data durable: it survives detach,
restart, and container recreation, and it enters `/persist` backups.

To remove saved pane history:

1. Stop the Herdr server with an intentional **cold** stop. This ends its pane processes:
   anything running in an attached pane is terminated, not preserved or migrated.
2. Delete `~/.config/herdr/session-history.json`.
3. Start Herdr again (`dx-herdr`) and confirm the new session shows no restored
   screen contents from the deleted history before trusting the pane with
   sensitive output again.

### Upgrading Herdr

There is no live upgrade or handoff for Herdr. `dx-recreate` preserves `/nix`
and `/persist`, so a previously installed `herdr` executable survives recreation,
and an ordinary `dx-herdr` launch never refreshes an already-present bundle.
The supported refresh is a cold sequence:

```bash
dx-recreate
dx-ai
dx-herdr
```

Running `dx-ai` against a container with a live Herdr server is outside the
supported workflow; live pane processes are never preserved across an upgrade.

### Licensing

The packaged `herdr` (`v0.7.5`) is distributed by nixpkgs under
**AGPL-3.0-or-later** (confirmed from nixpkgs' `meta.license.spdxId`), with a
commercial alternative offered upstream. DXE runs it as an unmodified, separate
executable; invoking it this way does not relicense DXE's own shell and Nix
code.

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
--to sri` and rewrites the local mutable generation's pin before running `nix
profile add` or `nix profile upgrade`; `/guest-bootstrap` remains unchanged.

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
