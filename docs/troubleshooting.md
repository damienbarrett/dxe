## Troubleshooting

### Resetting the Environment (Stale Dependencies)

If the guest bootstrap fails due to stale dependencies or a corrupted Nix store
in the persistent volume, you can perform a "hard reset" to clear the cache and
start fresh:

1. **Tear down the container and image (volumes preserved):**
   ```bash
   ./bin/dx-destroy
   ```
2. **Reset ONLY the Nix volume** (`/persist` is never touched):
   ```bash
   ./bin/dx-reset-nix-volume
   ```
   This is the same volume-scoped recovery `store-trust-plan.md`'s own
   refusals name — it refuses if a container still exists or the runtime
   reports the volume in use, and (under `DX_RUNTIME=docker-ssh`) goes
   through the same labelled-volume collision check every other volume
   delete does, rather than a raw `container`/`docker volume delete` that
   bypasses both.
3. **Bring everything back up:**
   ```bash
   ./bin/dx
   ```
   *Note: This will trigger a full download of all Nix packages during the next bootstrap.*

For a complete wipe (including `/persist` contents and SSH keys), use
`./bin/dx-factory-reset` — it prompts for confirmation before removing anything.

### Guest stops before SSH with a missing bootstrap toolchain

The container starts and then stops, and `container logs dx-host` ends with a
missing binary immediately after the Nix volume is remounted:

```
copying 0 paths...
Nix volume image import completed in 1s.
.../bootstrap/base-and-storage.sh: line NNN: /nix/store/<hash>-dx-bootstrap-essentials/bin/mkdir: No such file or directory
```

The bootstrap toolchain is on `PATH` at a store path that exists only in the
container's own filesystem. The import is what copies it onto the `/nix` volume
before the remount replaces `/nix` wholesale; when the import copies nothing,
the first command after the remount has no binary to execute. `copying 0 paths`
right before the failure is the tell.

Current bootstraps do not produce this: the import reads the registered set
through a read-write store view, and checks that the required paths are present
before the remount, failing with `did not materialise required bootstrap paths`
and naming them. If you see that message instead, the guest stopped early on
purpose and nothing is half-written.

A related, narrower failure (store-trust-plan.md Problem 2): every required
path can be present and still individually broken (a truncated or otherwise
corrupted executable) — a bare presence check cannot see that.
`verify_remount_prerequisites` runs immediately after the volume reaches its
final place, actually executing (a harmless `--version`) each of the small
set of tools the very next bootstrap steps depend on
(readlink/mkdir/mktemp/rm/ln/chown/mv/setpriv/bash/nix), and refuses,
naming the specific broken tool, rather than the guest dying on whichever
one of them the next line happens to call first.

Recovery, in order of cost:

1. Run `./bin/dx` again. The guest waits for the host to publish before it
   executes anything, so a corrected payload from your working tree is picked up
   on that start. A generation that cannot boot is no longer self-perpetuating.
2. If the volume itself is the problem, use the hard reset above —
   `./bin/dx-reset-nix-volume`. It costs a full Nix store download and
   nothing else.

Do not reach for `./bin/dx-factory-reset` here. It also destroys `/persist`,
which holds the home directory and persisted state; a store rebuild does not.

### Guest stops right after Home Manager activation with "dbus-daemon not found"

**Superseded by `refactor/keyring-owned-by-dx-ai` (Branch 16):** bootstrap no
longer starts, resolves, or knows anything about the keyring at all, so this
failure mode cannot happen on a bootstrap containing Branch 16 -- `dx-recreate`
and every other bootstrap path reach sshd regardless of whether an AI
generation exists or what state it is in. History, for a guest still running
a pre-Branch-16 bootstrap: a guest whose `/persist` already held a published
AI generation failed to come up after `dx-recreate`, or any other bootstrap
starting from a fresh `/home/dx`, with `Error: dbus-daemon not found on dx's
PATH...`, because the old `setup_keyring_service` (guest
`bootstrap/persistence.sh`) resolved `dbus-daemon` by asking dx's login
shell to find it on `PATH`, which depended on ordering that a fresh
`/home/dx` did not guarantee. `fix/keyring-bootstrap-recreate` (Branch 15)
first fixed the resolution and made the failure non-fatal (a `Warning:`
instead); Branch 16 then removed bootstrap's keyring involvement entirely,
which is why this whole class of bootstrap-side keyring failure cannot
recur. **Recovering a guest still on an old bootstrap:** publish a bootstrap
containing at least Branch 15 (or, better, Branch 16) with
`./bin/dx-sync-bootstrap` and `./bin/dx-start-container`; `dx-recreate` is
not required unless the guest needs a fresh `/home/dx` for some other reason.

### `agy` cannot persist an OAuth token after a container restart (keyring is stale)

`dx-keyring status` reports `stale` (or `agy`'s Secret Service calls fail)
right after `dx-stop-container` / `dx-start-container`, even though the
guest was working before the restart. Cause (fixed by
`refactor/keyring-owned-by-dx-ai`, Branch 16, for a guest running a
bootstrap containing it -- see below for an older guest): the previous
boot's `/tmp/dbus-*` socket *file* survives in the container's writable
layer across a restart, but the process that owned it does not; a socket
file's type never changes just because its listener died, so a liveness
check that only asked `[ -S socket ]` (every bootstrap and `dx-ai` version
before this branch) treated the dead file as a live bus, skipped starting a
fresh one, and started `gnome-keyring-daemon` against a dead address.

**Fix:** `scripts/lib/dx-keyring.sh`'s `dx_keyring_probe` now requires a
real D-Bus client call to succeed against the recorded address, not just a
socket-typed file at that path; `dx_keyring_start` (used by both `dx-ai` and
the explicit `dx-keyring start` command) clears a stale address/socket
before starting fresh, and is idempotent otherwise. **Recovery, on a guest
already running a bootstrap containing this fix:** run `dx-keyring start`
(or any `dx-ai`) after a container restart, before an `agy` login -- see
`docs/guest.md`'s "Keyring" section. **On a guest whose keyring is stuck
this way and only has an older `dx-ai`:** `dx-recreate` publishes a fresh
`/home/dx` and re-runs the (now-fixed) bootstrap and `dx-ai`, which is a
heavier fix than necessary but always resolves it.

### A start fails with "published bootstrap generation X, but ... is running Y"

`./bin/dx-start-container` published a bootstrap edit, but the running guest
provably isn't executing it — most commonly because the container was
already running and was never restarted, so its launcher resolved `current`
at some earlier boot and has no reason to look again. The container itself
is left running; only the start command fails, on purpose (this is
`dx-start-container` doing its job, not a new defect).

Restart it: `./bin/dx-stop-container && ./bin/dx-start-container`. The
second start's sync sees the content unchanged (the first start already
published it) and takes the fast skip path, so the freshly-started guest
picks up the edit on its own first boot. See
[D7](refactor/decisions/D7-start-generation.md) for the full mechanism and
`docs/configuration.md`'s `DX_BOOTSTRAP_CONFIRM_TIMEOUT` entry for the bound.

### A healthy boot reported as a failure

`./bin/dx` can exit non-zero on a guest that is actually fine. Two causes, both
harmless:

- `dx-wait-ssh` samples SSH once, so under load it can give up while the guest
  is still coming up.
- Run non-interactively, the final tmux attach fails with
  `open terminal failed: not a terminal`.

Check the guest directly before re-diagnosing:

```bash
container list -a | grep dx-host
./bin/dx-ssh true
```

If the container is running and `dx-ssh` succeeds, the boot succeeded.

### `dx` hangs at "Waiting for guest SSH" on a loaded host

Symptom: `./bin/dx` prints `Waiting for guest SSH to become responsive...` and
then dots for a very long time. `container logs dx-host` shows a *healthy*
sshd — it is accepting publickey logins the whole time — alongside repeated
`ssh_dispatch_run_fatal: Connection from ...: Broken pipe [preauth]`. A login
you start yourself eventually succeeds, but takes a minute or more.

The mechanism is always the same: the TCP connect is answered, then the guest is
too starved to send its SSH banner inside `DX_SSH_CONNECT_TIMEOUT`, so every
readiness probe dies with `Connection timed out during banner exchange` and the
wait loop runs to its full budget (about 91 minutes by default). `dx-wait-ssh`
now names this case in its timeout report instead of only printing the guest log
tail, which shows a healthy sshd and so points away from the real cause.

**Two different faults produce it, and the remedies are opposite.** Establish
which one you have before acting -- both were seen in the same session on
2026-09-07, and treating the second as the first wastes an hour:

| | Starved host | Wedged guest |
| --- | --- | --- |
| Host load average | far above the core count | normal |
| Host disk I/O | thousands of tps, 100+ MB/s | idle |
| VM process CPU | high, alongside other busy processes | ~400-500% while the host is otherwise quiet |
| Remedy | fix the host (below) | restart the container (below) |

Confirm it from the host:

```bash
uptime                    # load average well above the core count
iostat -d -w 1 -c 5       # sustained thousands of tps on disk0
ps -Ao pcpu,pid,comm -r | head
```

The usual culprit is a backup or indexer walking the Apple `container` volume
images. Each volume is a single sparse `volume.img` declared at 512 GB that the
running guest mutates constantly, so a file-level backup re-reads tens of
gigabytes on every pass and never converges:

```bash
du -sh ~/Library/Application\ Support/com.apple.container/volumes/*
tmutil isexcluded ~/Library/Application\ Support/com.apple.container
tmutil status            # a BackupPhase stuck for hours is its own problem
```

Exclude the container runtime state and the store cache. All of it is
re-derivable, and none of it restores usefully from a file-level copy of a live
disk image. `tmutil addexclusion` needs no `sudo` for paths you own:

```bash
C=~/Library/Application\ Support/com.apple.container
tmutil addexclusion "$C"/snapshots "$C"/containers "$C"/content "$C"/kernels
tmutil addexclusion "$C"/volumes/dx-nix "$C"/volumes/dx-bootstrap
tmutil addexclusion "$C"/volumes/dx-test-nix "$C"/volumes/dx-test-persist \
                    "$C"/volumes/dx-test-bootstrap
tmutil addexclusion ~/.dx-cache
tmutil isexcluded "$C"/volumes/dx-nix     # verify
sudo tmutil stopbackup                    # only if a backup is wedged right now
```

`volumes/dx-persist` is the one that holds guest state, so it is the one worth
thinking about rather than excluding reflexively. Note what including it costs:
it is a *single* `volume.img` (16 GB of real blocks inside a 512 GB sparse
declaration) whose mtime moves whenever the guest runs. Time Machine copies
whole files, so an included `dx-persist` means re-copying the entire image on
every hourly pass -- which is most of the I/O storm this section is about. A
snapshot of a mounted ext4 image is also not a dependable restore source.

Prefer backing up the contents: `./bin/dx-get` for files, or push repositories
under `/persist` to a remote. To ride out a slow host without changing anything
else, raise the probe budget for one run: `DX_SSH_CONNECT_TIMEOUT=60 ./bin/dx`.

#### The other case: a wedged guest on a quiet host

If the host is idle and the VM process alone is pinned near 400-500% with no
disk I/O, the guest is burning its vCPUs on pure computation and cannot schedule
anything new. The tell is that **`container exec` fails too** -- it does not go
through sshd, so when both it and `ssh` time out, the fault is not SSH.

There is no way in to diagnose it once it reaches that state; a restart is the
remedy, and volumes survive it untouched:

```bash
./bin/dx-stop-container   # expect the graceful stop to time out; it escalates
./bin/dx
```

Expect `container stop` *and* `container kill` to time out, leaving
`dx-stop-container` to terminate the runtime process — that escalation is itself
confirmation the guest was unresponsive rather than slow. `dx-nix` and
`dx-persist` are unaffected, so nothing on disk is lost; in-guest session state
(tmux, unsaved buffers) does not survive. Capture the culprit **before**
restarting if you can: an already-authenticated `dx-ssh` session skips the
banner exchange that is blocking new connections, so running
`ps -eo pcpu,pid,etime,args --sort=-pcpu | head -20` in a terminal that is
already attached will still work when nothing else does.

### Checking Bootstrap Logs
After a factory reset, `./bin/dx` must repopulate the complete Nix store before
SSH starts. The command waits for the full bounded retry period and prints a
recent bootstrap log line every 30 seconds. To monitor the complete bootstrap
output from another terminal:
```bash
container logs dx-host -f
```

### One-time ownership migration

On the first start after this ownership layout change, a retained volume may
log `Migrating legacy ... ownership (one time)`. This repairs the existing
tree so that `dx` can use Nix and persistent configuration safely. It is
bounded to one migration per data root; later starts only check the small
versioned marker and create newly declared directories with `dx:dx` ownership.

The migration marker is written only after the recursive repair completes. If
bootstrap is interrupted, rerun `dx` and the incomplete migration is retried;
it does not claim success early or expose a partially published marker. Do not
delete the marker unless you intentionally want to request another migration.

### Recovering a Nix volume without resetting it

If repeated bootstrap retries still report an inconsistent Nix volume, stop the
container first and preserve a volume snapshot or copy where the host supports
one. Inspect the bootstrap logs, `/nix/.dx-image-store-identity`,
`/nix/var/nix/gcroots/dx-image-roots-*`, and any
`.dx-store-import-stage.*` directories. Start the container again to let the
bounded importer/repair path recover its staged state. Do not delete identity
markers or GC roots by hand: they identify the last complete, recoverable
store state. Use the hard reset above only after preserving what you need and
after the bounded retry has failed.
