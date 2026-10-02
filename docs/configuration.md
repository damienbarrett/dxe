## Configuration Variables

All variables have defaults, so a normal single-container setup does not need to
set any of these explicitly. Override them when running isolated lifecycle
tests, parallel experiments, or multiple containers on the same host.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DX_RUNTIME` | `apple` | Container lifecycle runtime. `apple` (the local Apple Container runtime) or `docker-ssh` (the remote Docker-over-SSH runtime, `qnap-dxe-plan.md` Phase 2); any other value, including the retired Phase 1 placeholder `docker`, is rejected with a clear message. |
| `DX_REMOTE_HOST` | empty | Validated OpenSSH config alias for the `docker-ssh` runtime's target host (e.g. `qnap-dxe`); required when `DX_RUNTIME=docker-ssh`, must stay empty for `apple`. The alias itself owns the username, identity file, address, and host-key policy -- this field only ever stores its name, never ssh option text. See `tests/profiles/qnap-example.env`. |
| `DX_GUEST_SYSTEM` | `aarch64-linux` | Target guest system for the `docker-ssh` runtime's preflight, matching the remote host's own `uname -m` (`aarch64-linux` or `x86_64-linux`). Unused by `apple`, which is always `aarch64-linux`. |
| `DX_NIX_STORAGE_MODE` | `apple-image` | `apple-image` (the existing Apple sparse-image-in-a-managed-volume shape) or `direct-volume` (`qnap-dxe-plan.md` DQ4: mount the Nix volume directly at `/nix`, used by `docker-ssh`). |
| `DX_CONTAINER_RESTART_POLICY` | `no` | `no` or `unless-stopped`. Apple never sets a restart-policy flag regardless of this value (`dx_runtime_capability restart_policy` is false for `apple`); `docker-ssh` passes it to `docker create --restart`. |
| `DX_CONTAINER_NAME` | `dx-host` | Apple container name. Change this to create a separate container without touching the default DXE instance. |
| `DX_IMAGE` | `dx-nixos-26.05` | Image name used by `dx-create-image` and `dx-create-container`. |
| `DX_SSH_PORT` | `2222` | Host port forwarded to guest SSH port `2222`. Use a different port for a second running container. |
| `DX_SSH_KEY` | `$DX_PROJECT_ROOT/dx_key` | Host private key used for SSH into the guest. |
| `DX_SSH_KEY_PUB` | `$DX_PROJECT_ROOT/dx_key.pub` | Host public key provisioned into the guest on create. |
| `DX_SSH_CONNECT_TIMEOUT` | `15` | Host-side SSH connection timeout in seconds for `dx-ssh`. |
| `DX_SYSTEM_WAIT_TIMEOUT` | `30` | Seconds to wait for container-service readiness after starting the local Apple service. Startup failure or timeout stops `dx` before guest checks; QNAP service startup remains manual. |
| `DX_CONTEXT_DIR` | `container/dx-nixos-26.05` | Directory used as the image build context and default bootstrap source. Renamed from `container/aarch64-darwin-apple-container-dx-nixos-26.05` in WP9.4 (the flake is architecture-neutral; the QNAP guest is x86_64). A git-tracked symlink at the old path keeps a profile that still names it working for one release; `dx_config_validate_cross_fields` prints a one-line deprecation warning to stderr when it sees the old name. The old path is removed at the next base changeover (see `docs/release-maintenance.md`). |
| `DX_BOOTSTRAP_SOURCE` | `$DX_CONTEXT_DIR` | Host directory pushed into the clean guest bootstrap volume. Override this to test a different bootstrap checkout without rebuilding the image. |
| `DX_BOOTSTRAP_VOLUME` | `dx-bootstrap` | Named volume mounted at `/guest-bootstrap` by default. It stores the pushed bootstrap payload outside the image layer. |
| `DX_BOOTSTRAP_PATH` | `/guest-bootstrap` | Guest path where the bootstrap payload is mounted and executed. |
| `DX_BOOTSTRAP_WAIT_TIMEOUT` | `30` | Seconds `dx-sync-bootstrap` waits for the guest entrypoint to report bootstrap readiness before failing with a log hint. |
| `DX_BOOTSTRAP_CONFIRM_TIMEOUT` | `5` | Seconds `dx-start-container` waits, after a real bootstrap publish (not the unchanged-content skip), for the guest's execution lease to name the just-published generation before failing the start. Live-measured publish-to-lease latency on `dx-test` was 0.2-0.4s; the default gives over 10x headroom. Distinct from the guest-side `DX_BOOTSTRAP_PUBLISH_GRACE` (30s default, not a registry field): that bounds a guest with no publisher at all, this bounds the host's confirmation that a publisher's guest actually picked it up. |
| `DX_GUEST_ACTIVATION_TIMEOUT` | `1800` | Seconds allowed for one guest Home Manager activation attempt before the bootstrap kills it and retries. A clean Nix store can require much of this window. |
| `DX_GUEST_ACTIVATION_ATTEMPTS` | `2` | Total guest Home Manager activation attempts before bootstrap fails and the container exits with logs. |
| `DX_GUEST_ACTIVATION_RETRY_DELAY` | `5` | Seconds to wait between guest Home Manager activation attempts. |
| `DX_SSH_WAIT_TIMEOUT` | Derived from the complete guest activation retry budget | Maximum seconds `dx-wait-ssh` waits for bootstrap. The default covers all activation attempts, their kill/retry delays, and 30 minutes for rebuilding the root bootstrap toolchain on a clean image. |
| `DX_NIX_VOLUME` | `dx-nix` | Named volume that backs the persistent Nix store. Apple Container surfaces it inside the guest at `/var/lib/dx-nix-raw`; the bootstrap reformats it as btrfs (or ext4 as a fallback) and remounts it at `/nix`. Override this for isolated test containers or parallel experiments so they do not share the default writable Nix store. |
| `DX_NIX_MOUNT` | `/nix` | Guest mount point for the active Nix filesystem. Used by maintenance commands such as `dx-reclaim`. |
| `DX_NIX_DISK` | `$HOME/.dx-cache/nix-store.img` | Host-side sparse Nix disk path used by disk maintenance helpers. |
| `DX_NIX_DISK_SIZE` | `64G` | Default sparse Nix disk size. Forwarded into the guest by `dx-create-container` and used by the bootstrap when it creates the sparse Nix store image. |
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
| `DX_MOUNT_IDENTITY_DIR` | `$HOME/.dx-cache/mount-identities` | Private directory containing bounded v2 mount manifests and their locks. |
| `DX_TUNNEL_LOCK_TIMEOUT` | `5` | Maximum seconds to wait for a per-tunnel state-transition lock. |
| `DX_BACKUP_DIR` | `$HOME/Backups/dxe-persist` | Base host directory for `dx-backup`/`dx-restore`. The actual per-container mirror always lives at `$DX_BACKUP_DIR/$DX_CONTAINER_NAME`, even when overridden, so `dx-host` and `dx-test` never share one. See ["Backing up and restoring /persist"](lifecycle.md#backing-up-and-restoring-persist). |

`DX_NIX_VOLUME` exists because the Nix store is large, persistent, and lives on
its own writable filesystem. Apple Container creates and mounts the volume at
`/var/lib/dx-nix-raw`; the guest bootstrap then formats the backing block
device as btrfs (or ext4 if the kernel lacks btrfs) and remounts it at `/nix`,
which requires `CAP_SYS_ADMIN` inside the guest (granted by
`bin/dx-create-container`). The default `dx-nix` volume preserves downloads
and activation state across container recreation, and a host lifecycle claim
assigns it to one container for that container's full lifecycle, including
while stopped. Destroy the owning container before assigning the volume to a
different container; for a clean lifecycle test, use a separate Nix volume so
the test cannot corrupt or lock the default environment.

`/persist` is the fixed supported guest path for persisted files. Do not set
`DX_PERSIST_PATH`; path overrides are not supported. Setting old
`DX_WORKSPACE_VOLUME` or `DX_WORKSPACE_PATH` variables now fails early with a
rename message so existing `.env` files are not silently ignored.

### Generated defaults reference

Generated by [`docs/gen-config-table.sh`](gen-config-table.sh) from
`bin/lib/dx-config.sh`'s own `DXE_CONFIG_REGISTRY` -- the single source of
truth for every field's default (Fable A5's refactor, Muse C2). Run the
script and paste its output over this table whenever the registry
changes; `tests/test_section10_docs.sh` asserts the two stay identical.
The table above is the hand-maintained reference with each field's
purpose; this one exists so the *default* can never drift from the
registry that validates it.

| Variable | Default |
| --- | --- |
| `DX_RUNTIME` | `apple` |
| `DX_REMOTE_HOST` | (empty) |
| `DX_GUEST_SYSTEM` | `aarch64-linux` |
| `DX_NIX_STORAGE_MODE` | `apple-image` |
| `DX_CONTAINER_RESTART_POLICY` | `no` |
| `DX_CONTAINER_NAME` | `dx-host` |
| `DX_IMAGE` | `dx-nixos-26.05` |
| `DX_SSH_PORT` | `2222` |
| `DX_SSH_KEY` | `$DX_PROJECT_ROOT/dx_key` |
| `DX_SSH_KEY_PUB` | `$DX_PROJECT_ROOT/dx_key.pub` |
| `DX_SSH_CONNECT_TIMEOUT` | `15` |
| `DX_SYSTEM_WAIT_TIMEOUT` | `30` |
| `DX_CONTEXT_DIR` | `$DX_PROJECT_ROOT/container/dx-nixos-26.05` |
| `DX_BOOTSTRAP_SOURCE` | `$DX_CONTEXT_DIR` |
| `DX_BOOTSTRAP_VOLUME` | `dx-bootstrap` |
| `DX_BOOTSTRAP_PATH` | `/guest-bootstrap` |
| `DX_BOOTSTRAP_WAIT_TIMEOUT` | `30` |
| `DX_BOOTSTRAP_CONFIRM_TIMEOUT` | `5` |
| `DX_GUEST_ACTIVATION_TIMEOUT` | `1800` |
| `DX_GUEST_ACTIVATION_ATTEMPTS` | `2` |
| `DX_GUEST_ACTIVATION_RETRY_DELAY` | `5` |
| `DX_NIX_VOLUME` | `dx-nix` |
| `DX_NIX_MOUNT` | `/nix` |
| `DX_NIX_DISK` | `$HOME/.dx-cache/nix-store.img` |
| `DX_NIX_DISK_SIZE` | `64G` |
| `DX_PERSIST_VOLUME` | `dx-persist` |
| `DX_GIT_MOUNT_SOURCE` | (empty) |
| `DX_GIT_MOUNT_TARGET` | `/workspace` |
| `DX_GUEST_WORKDIR` | (empty) |
| `DX_CONTAINER_MEMORY` | `12G` |
| `DX_CONTAINER_CPUS` | `4` |
| `DX_CONTAINER_VOLUME_DIR` | `$HOME/Library/Application Support/com.apple.container/volumes` |
| `DX_STOP_GRACE_SECONDS` | `5` |
| `DX_STOP_COMMAND_TIMEOUT` | `15` |
| `DX_STOP_WAIT_TIMEOUT` | `5` |
| `DX_DELETE_COMMAND_TIMEOUT` | `15` |
| `DX_MOUNT_IDENTITY_DIR` | `$HOME/.dx-cache/mount-identities` |
| `DX_TUNNEL_LOCK_TIMEOUT` | `5` |
| `DX_BACKUP_DIR` | `$HOME/Backups/dxe-persist` |

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

Bundle those overrides into a named profile in
`${XDG_CONFIG_HOME:-$HOME/.config}/dxe/profiles/`. `bin/dx-profile` looks there
first, then in the checkout's `tests/profiles/` for bundled examples and test
fixtures. Set `DX_PROFILES_DIR` to select a single explicit directory instead;
an absent profile in that directory fails without falling back.
Root `.env` and profiles are data files, never shell
scripts. Run them only through `dx-profile <name>`:

```bash
./bin/dx-profile dx-test ./bin/dx
./bin/dx-profile dx-test ./bin/dx-destroy
./bin/dx-profile dx-test ./bin/dx-recreate
```

Profiles are purely opt-in. Do not source a profile. Running a script without
`dx-profile` uses the canonical defaults — `dx-host` on port `2222`, default
volumes, and default keys.

Keep personal profiles outside the repository. Store SSH keys separately in
`~/.ssh/dxe/`, with the private key readable only by you (`chmod 600`). The
profile contains absolute paths in `DX_SSH_KEY` and `DX_SSH_KEY_PUB`, never key
material. For example:

```text
DX_SSH_KEY=/absolute/path/to/.ssh/dxe/qnap-canary
DX_SSH_KEY_PUB=/absolute/path/to/.ssh/dxe/qnap-canary.pub
```

Use your actual home path: profiles do not expand `~`, `$HOME`, or
`$XDG_CONFIG_HOME`. Moving an existing key preserves the controller's SSH
identity and access to the guest;
generating a replacement key would require changing the guest's authorized
keys.

To recreate a missing profile, copy the matching bundled example into your
user profile directory and restore your host alias, resource names, port,
and absolute key paths. A missing public key can be derived from the private
key with `ssh-keygen -y -f /absolute/path/to/private-key`; a private key cannot
be recovered from its public key. If the original private key is lost, create
a replacement and provision its public key into the guest before reconnecting.

The accepted grammar is deliberately bounded: blank lines, full-line comments,
an optional literal `export ` prefix, and one allowlisted `NAME=value` record
per line. Names cannot repeat. Values are data: quoting, backslashes, command
substitution, general variable expansion, control operators, and continuations
are rejected with file-and-line diagnostics. The only expansion is a literal
`${DX_PROJECT_ROOT}` placeholder in host-path fields.

Migration examples:

```text
# old shell syntax (rejected)
export DX_SSH_KEY="$DX_PROJECT_ROOT/dx-test_key"

# bounded data syntax
export DX_SSH_KEY=${DX_PROJECT_ROOT}/dx-test_key
```

Precedence is command flags/immutable plans, inherited or profile environment,
command-specific derived values, root `.env`, then defaults. Resolution records
an origin for every field and exports one complete versioned snapshot. Children
validate that snapshot and never reopen `.env`; partial, stale, wrong-root, and
unknown-version markers fail closed.

Shipped profiles:

- `tests/profiles/default.env` — documentation of the default values and a
  template for authoring a new data profile.
- `tests/profiles/dx-test.env` — fully isolated `dx-test` environment. Test
  container, image, volumes, and SSH key all live in a `dx-test*` namespace
  alongside the primary `dx-host` resources, on port `2299` so both can run
  simultaneously.
