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

## Nix and persistent-data ownership

DX runs Nix in direct single-user mode. After the persistent Nix volume is
mounted, `/nix/store` and `/nix/var/nix` are owned by `dx`; Nix commands,
Home Manager, garbage collection, and reclaim must run as `dx`. Root performs
the early mount/import work, then must not write new store content behind the
single-user boundary.

Bootstrap creates mutable guest directories with `dx:dx` ownership. A volume
created by an older bootstrap may receive a one-time ownership migration for
`/home/dx`, `/nix/cache`, or `/persist/home/dx`. Each migration publishes a
versioned `.dxe-*-owner-v1` marker only after it succeeds, so ordinary starts
do not recursively scan the user's accumulated cache, AI state, or sessions.
The legacy Nix marker `/nix/.dx-owner-set` remains for compatibility with an
older bootstrap generation.

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
`container/dx-nixos-26.05/bootstrap/herdr-config.toml`.
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

Codex, Claude, `agy` (Antigravity CLI), `herdr`, and `opencode` are intentionally not installed by
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
installing or upgrading the `codex`, `claude`, `agy`, `herdr`, and `opencode`
commands in the guest user's Nix profile. It never modifies the published
bootstrap. The `dx-ai` helper is installed into `~/.local/bin` by Home
Manager, the same way `dx-theme` is installed.

`nixpkgs-unstable` tracks the `nixpkgs-unstable` channel branch, which only
advances once Hydra has finished building a revision, so its packages are
cached on cache.nixos.org for the guest's architecture. That is not a
guarantee, though: after the refresh, `dx-ai` runs `nix build --dry-run` and
refuses to install if any package other than the trivial, always-local ones
(the `dx-ai-tools` bundle itself, and `agy`/`claude-code`'s own tiny
fetch-and-unpack, both unfree-licensed and never cached by Hydra) would have
to be built from source. On a miss, it first retries against the previously
published generation's own lock -- which was already cached and working --
and continues on that revision with a notice if that is clean. If it isn't
(or there is no previous generation), `dx-ai` fails before touching the Nix
profile, prints the packages that would be built from source and the
remedy, and leaves the currently published generation untouched. Set
`DX_AI_ALLOW_SOURCE_BUILDS=1` to build from source anyway.

OpenCode's configuration and authentication state under `~/.config/opencode`,
and its mutable application data under `~/.local/share/opencode`, are linked to
the corresponding directories under `/persist/home/dx` so they survive guest
recreation.

On first opt-in, and again during activation after a recreate, DXE safely
migrates any pre-existing files from either OpenCode home path into those
persistent targets before restoring the links. It refuses to touch a
symlinked or non-directory persistent ancestor rather than traversing it,
and if a file name already exists in the persistent target, the home-side
file is kept alongside it as a `.dxe-conflict-…` file rather than discarded,
so nothing is silently lost.

Each optional AI generation records its own tool inventory in
`.tools-manifest`. `dx-ai --recover` validates a generation against its own
manifest, so it can recover to a retained generation created before OpenCode
support existed (which has no manifest and is treated as the legacy
five-tool inventory: Codex, Gemini, Claude, `agy`, and `herdr`). A newly
published generation must still contain the complete current optional
bundle, including OpenCode.

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

`agy` is fetched as a pinned tarball from Google's release bucket, keyed per
Nix system in `pins/agy.json` (Branch 11 / Phase 4, DQ7:
`docs/refactor/arch-neutral-guest.md` section 3) and spliced into the `agy`
derivation in `container/.../flake.nix` per system. An architecture with no
native artifact has a JSON `null` entry there; `agy` is then omitted from
that system's `ai-tools` closure entirely (never a foreign-architecture
binary), and `dx-ai` prints `agy: no native artifact for <system>; skipping
(DQ7)` and installs every other tool. The binary ships with a self-updater,
but the Nix store is read-only, so `dx-ai` refreshes the local flake pin
(for its own running system only) from Google's CLI manifest before
installing or upgrading `ai-tools`.

To inspect the upstream manifest manually:

```bash
# aarch64-linux; substitute linux_amd64 for x86_64-linux.
curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json
```

The manifest returns `{ "version": ..., "url": ..., "sha512": ... }`. `dx-ai`
converts `sha512` to a Nix SRI hash with `nix hash convert --hash-algo sha512
--to sri` and rewrites that system's key in the local mutable generation's
`pins/agy.json` before running `nix profile add` or `nix profile upgrade`;
`/guest-bootstrap` remains unchanged.

To update the checked-in fallback pin:

1. Replace the `version`, `url`, and `hash` under the target system's key
   (`"aarch64-linux"` or `"x86_64-linux"`) in `pins/agy.json`. `hash` uses
   SRI format: `sha512-<base64>`. Convert from the manifest's hex with:

   ```bash
   printf '%s' "<sha512-hex>" | xxd -r -p | base64 | tr -d '\n'
   ```

2. Re-sync the bootstrap payload and reinstall:

   ```bash
   ./bin/dx-sync-bootstrap
   ./bin/dx-ssh dx-ai
   ```

### Keyring (D-Bus session bus + gnome-keyring Secret Service)

`agy` is the only consumer of the guest's keyring: a per-user D-Bus session
bus plus `gnome-keyring-daemon`'s Secret Service, which `agy` uses to persist
an OAuth token across guest restarts. `dbus`/`gnome-keyring` are declared
only in the optional AI tools bundle (`flake.nix`'s `aiPackages`), so the
keyring only exists once you have opted in with `dx-ai`.

Bootstrap keeps no keyring knowledge at all -- it is owned entirely by
`dx-ai` and an explicit `dx-keyring` command, both thin wrappers over the
shared `scripts/lib/dx-keyring.sh` library. Every ordinary `dx-ai` run
starts or reuses the keyring at its end, so most of the time nothing extra
is needed. After a container restart (`dx-stop-container` /
`dx-start-container`), the previous boot's bus is gone but its Home
Manager-managed shell integration still points at the recorded address, so
run one of:

```bash
dx-keyring start   # explicit
dx-ai              # any AI-tools update also starts it
```

before an `agy` login. `dx-keyring status` reports `live`, `stale`, or
`absent` for the recorded bus (plus pids when live) if you want to check
first.

**Why no automatic start-on-`agy` wrapper.** Explicit is preferred over
magic here: wrapping `agy` to silently start a keyring session on first use
would hide *when* and *why* a background service started, and would need to
special-case every other tool that might eventually want the same Secret
Service. An explicit `dx-keyring start` (or the same effect from a plain
`dx-ai`) is one predictable seam.

**Why not systemd socket activation.** The usual desktop-Linux pattern
(a systemd user session lazily starting `dbus-daemon`/`gnome-keyring-daemon`
on first socket connection) needs a running systemd `--user` instance, which
this guest's minimal NixOS profile does not run; `dx` has no user systemd
session to activate against.

**Considered and deferred: `dbus-run-session` per invocation.** Wrapping
each `agy` invocation in its own `dbus-run-session` (a fresh, private bus
for that one process) was considered and rejected: `gnome-keyring-daemon`'s
Secret Service unlocks once per bus, so a fresh bus per run means a freshly
locked keyring every single run -- exactly the OAuth-persistence problem
this exists to solve, not a shortcut around it. A single long-lived,
explicitly managed bus (this design) is required for the unlock to actually
persist across invocations.

**The stale-socket defect this design fixes.** The previous (bootstrap-owned)
liveness check only asked whether the recorded socket path was still a
socket-typed file (`[ -S ... ]`). After a container restart, the previous
boot's `/tmp/dbus-*` socket *file* survives in the container's writable
layer even though the process that owned it is gone, and a dead socket's
file type does not change -- so the old check treated it as live, skipped
starting a fresh bus, and started `gnome-keyring-daemon` against a dead
address. `scripts/lib/dx-keyring.sh`'s `dx_keyring_probe` fixes this with a
real liveness test: the socket must exist *and* a live D-Bus client call
(`dbus-send ... org.freedesktop.DBus.ListNames`, bounded by a timeout) must
actually succeed against it. `dx_keyring_start` is idempotent: a live bus
with the Secret Service already registered starts nothing new.

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
- **Single-Writer Constraint:** A Nix volume is claimed by one container for its
  full lifecycle, not merely while it is running. Destroy that container before
  assigning the volume to another one; use a distinct volume name for parallel
  containers.
- **Optimization:** The filesystem is formatted with btrfs and zstd:3 compression. Nix's auto-optimise-store is enabled to deduplicate identical files at the hardlink level, further saving space.
- **Bootstrap Payload:** `/guest-bootstrap` is backed by the `dx-bootstrap`
  volume and populated from the local checkout at start time, keeping repository
  changes out of the image layer.
