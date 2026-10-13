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

### "SSH key file not found at ~/.ssh/dxe/dx_key"

The default key pair lives in `~/.ssh/dxe/` (it used to be the checkout root).
A checkout that still holds `dx_key` and `dx_key.pub` at its root is used
automatically, with one line naming the `mkdir -p ~/.ssh/dxe && mv ...`
commands that move the pair. If neither location has the key, run
`./bin/dx-create-keys` for a new pair (a new public key is only provisioned
into a guest that is created afterwards: an existing guest authorizes the key it
was created with, so move that pair rather than generating another). See
[Where the default key pair lives](configuration.md#where-the-default-key-pair-lives).

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

### AI tools vanish after `dx-reclaim` (`current/profile/bin/<tool>: No such file or directory`)

`codex`, `claude` and the other optional AI tools stop working right after
`./bin/dx-reclaim`. Its output includes `removing stale link from
".../gcroots/auto/..." to ".../dx-ai/generations/.staging-<id>/profile-1-link"`
followed by `deleting '/nix/store/...-profile'`. Cause (fixed by
`fix/dx-ai-gcroot`): `dx-ai` builds each generation in a `.staging-<id>`
stage and renames it into place, but Nix's only GC root for the profile
named the stage path. After the rename the root pointed at nothing, so the
garbage collection deleted the profile that `current` still pointed at.

**Fix:** `dx-ai` now registers a root at the generation's final path when it
publishes, and every `dx-ai` or `dx-ai --recover` run re-registers the roots
of `current` and its retained predecessor (see
[Optional AI Tools](guest.md#optional-ai-tools)). **Recovery:** publish a
bootstrap containing the fix (`./bin/dx-sync-bootstrap`, then
`./bin/dx-start-container`), then run `dx-ai` in the guest. It prints
`Warning: could not register a GC root for AI generation <id>` for each
generation whose profile was already deleted, then builds and publishes a
replacement. On a guest that has the fix but has not run `dx-ai` since,
run `dx-ai` before the next `dx-reclaim`.

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

For a named profile, apply it to **both** commands so the restart targets
the same container. For the production QNAP guest:

```bash
./bin/dx-profile qnap ./bin/dx-stop-container && ./bin/dx-profile qnap ./bin/dx-start-container
```

To connect to the running guest while postponing that restart, use
`qx` or `./bin/dx-profile qnap ./bin/dx-ssh`. `qx` defaults to the `qnap` profile and reads `QX_PROFILE`
to use another one.

### "profile '<name>' is pinned to <path>; run it from that checkout"

The profile sets `DX_PROFILE_ROOT`, so only that checkout may run it (a second
checkout must not drive the same target). Run `dx-profile <name> ...` from the
pinned checkout, or correct the pin in your private profile if the checkout
moved. The pin is compared after resolving symlinks.

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

### /persist host directory refusals

With `DX_PERSIST_STORAGE=host-path`, `dx-create-volumes`, `dx-start-container` and `dx-persist-migrate` check the guest's NAS directory (`<DX_PERSIST_HOST_ROOT>/dxe/<container name>/persist`, shown as `<dir>` below) before they write anything, and refuse with one `Error:` line that names the fix. Nothing is changed by a refusal. The fragments below are the stable part of each message.

`<dir> is missing, but <guest> already has /persist data: ...`. The directory is gone although the guest used it (a persist volume exists, or the per-profile record says so). The tooling never creates an empty replacement. Restore the directory from a NAS snapshot or backup, or import the volume with `dx-persist-migrate`; if you removed the directory on purpose, delete the record file named in the message too. If the message adds that the share may not be mounted, mount or unlock it first.

`<dir>, or a level above it under the share root (dxe, dxe/<guest>), is a symlink`. `/persist` must be a real directory. Replace the symlink with the directory itself, then retry.

`<dir>/.dxe-persist-dir names guest X, not Y; this directory belongs to another guest`. The marker belongs to a different guest. Check `DX_PERSIST_HOST_ROOT` and `DX_CONTAINER_NAME` in the profile (`dx-persist-migrate` says the same).

`<dir> is marked copying`. A migration into it from the persist volume has not finished. Resume it with `dx-persist-migrate`, or roll it back, before starting the guest. The guest never starts on a `copying` directory.

`<dir> is marked retired`. A rollback returned the guest to the persist volume. Set `DX_PERSIST_STORAGE=volume` in the profile, or move the retired directory aside first and then migrate again with `dx-persist-migrate` (into a new, empty directory).

`<dir> is not empty and has no .dxe-persist-dir marker`. Data that dxe did not mark is never adopted. Move it aside first (the directory, or its contents; keep it if it matters), then start fresh with `dx-create-volumes`, or copy the guest's persist volume into the now-absent or now-empty directory with `dx-persist-migrate` (`dx-persist-migrate` itself refuses a non-empty unmarked directory; it copies only into an empty or absent one). If the guest has used other `/persist` storage before (its persist volume or the record exists), starting fresh needs the emptied directory and `DX_PERSIST_FRESH_START=<container name>`, as in the next entry.

`<dir> is empty and unmarked, but <guest> has used other /persist storage before`. An empty directory is not proof of a new guest while the old volume or the record exists. To start fresh on purpose (new SSH host keys, no credentials; the old volume is kept), run `DX_PERSIST_FRESH_START=<container name> ./bin/dx-create-volumes` once; the value must equal `DX_CONTAINER_NAME`. Otherwise restore the data and do not use that variable. Two cases make `dx-create-volumes` mark an existing empty directory: finishing an interrupted create (when no old volume or record exists), and a fresh start (`DX_PERSIST_FRESH_START=<container name>`, only when the old volume or record exists).

`the share root <root> does not look mounted: its sentinel file DX_PERSIST_HOST_MOUNT_SENTINEL=<name> is missing`. An unmounted or locked share can leave an empty mount point. Mount or unlock the share, then retry.

`cannot tell whether the share root <root> is mounted`. Creating or marking a directory needs proof the share is mounted, and `DX_PERSIST_HOST_MOUNT_SENTINEL` is not set. Set it in the private profile to a file that exists at the share root only while it is mounted.

`cannot tell whether the persist volume <name> exists`. `docker volume inspect` failed for a reason other than "no such volume" (the Docker daemon or the SSH connection is down, or permission was denied), and a missing volume could mean a new, empty `/persist`. Fix the NAS connection or its Docker daemon, then retry. Nothing was changed.

`<dir>/.dxe-persist-dir is not a valid /persist marker`. Inspect the directory and restore a valid marker, or move the directory aside, then retry.

`the share root DX_PERSIST_HOST_ROOT=<root> is not a usable directory`. The root is wrong, unavailable, or could not be checked. Fix `DX_PERSIST_HOST_ROOT` in the private profile or make the share available, then retry.

`the share root DX_PERSIST_HOST_ROOT=<root> resolves to the filesystem root`. The root, or a symlink it goes through, leads to `/` on the NAS, which is never a share root. Set `DX_PERSIST_HOST_ROOT` in the private profile to the share itself, then retry. A profile whose `DX_PERSIST_HOST_ROOT` is `/` itself (or `//`, `/.`, `/..`) is refused before anything runs: `DX_PERSIST_HOST_ROOT must not be the filesystem root`.

The guest runs its own check, too, before it changes anything under `/persist` or starts `sshd`. This self-check stops the guest on any of the following, so a guest that Docker restarts after a NAS reboot never runs on an empty or foreign `/persist`:

`/persist is not a mount point`. The share directory is not bound there, so data would land on the container's own filesystem. Check the bind, then run `./bin/dx-recreate`.

`<marker> is missing, so /persist is not a prepared directory for guest <guest>`. The marker is absent, or the NAS share is not unlocked yet. Check the share, then run `./bin/dx`, whose host-side checks say what to do.

`<marker> is malformed`. It is not a regular file, or its fields are not the expected ones. Inspect it on the NAS (`schema=1`, the right `guest=`, `state=ready`) before starting the guest again.

`<marker> names guest X, not Y` or `has state copying, not ready`. For a foreign marker, check the profile as above. For a marker that is not ready, finish the migration, or after a rollback set the profile back to volume mode and run `./bin/dx-recreate`.

A healthy start prints `Verified host-path /persist for guest <guest>: a mount point with a ready .dxe-persist-dir.` in the bootstrap log (`Checking Bootstrap Logs`, below).

### A guest tool does not notice a change made from the host

Files changed under `/persist` from the Mac (through the NAS share) can reach the guest without a file-system event, so a long-running watcher in the guest, such as an editor, a dev server or a build tool, can miss the change. The change is on disk and a fresh read sees it. Refresh the tool's view (reload the folder, or touch the file from inside the guest), or restart the watcher. Prefer making such edits from inside the guest.

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
