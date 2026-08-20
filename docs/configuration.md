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
| `DX_NIX_DISK` | `$HOME/.dx-cache/nix-store.img` | Host-side sparse Nix disk path used by disk maintenance helpers. |
| `DX_NIX_DISK_SIZE` | `20G` | Default sparse Nix disk size. |
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

Bundling those overrides into one invocation is what `tests/profiles/` and
`bin/dx-profile` are for. Root `.env` and profiles are data files, never shell
scripts. Run them only through `dx-profile <name>`:

```bash
./bin/dx-profile dx-test ./bin/dx
./bin/dx-profile dx-test ./bin/dx-destroy
./bin/dx-profile dx-test ./bin/dx-recreate
```

Profiles are purely opt-in. Do not source a profile. Running a script without
`dx-profile` uses the canonical defaults — `dx-host` on port `2222`, default
volumes, and default keys.

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
