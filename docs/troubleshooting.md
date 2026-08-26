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

Recovery, in order of cost:

1. Run `./bin/dx` again. The guest waits for the host to publish before it
   executes anything, so a corrected payload from your working tree is picked up
   on that start. A generation that cannot boot is no longer self-perpetuating.
2. If the volume itself is the problem, use the hard reset above — delete only
   `dx-nix`. It costs a full Nix store download and nothing else.

Do not reach for `./bin/dx-factory-reset` here. It also destroys `/persist`,
which holds the home directory and persisted state; a store rebuild does not.

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
