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
