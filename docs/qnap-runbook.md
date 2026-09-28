# QNAP operator runbook

Operating a `docker-ssh` guest on a QNAP NAS (`qnap-dxe-plan.md` Phase 6,
item 1). This is a checklist and reference for install, preflight, normal
operation, update, backup, restore, and removal; it does not repeat the
layer model or the shared lifecycle scripts, covered in
[`docs/lifecycle.md`](lifecycle.md) and
["Operating a QNAP guest"](lifecycle.md#operating-a-qnap-guest) there.

Every example below uses [`tests/profiles/qnap-example.env`](../tests/profiles/qnap-example.env)'s
placeholder shape and the `qnap-dxe` SSH alias name that file documents.
**Never** put a real hostname, tailnet address, username, or storage-pool
path into a tracked file — this repository is public
(`docs/refactor/constraints.md`, `tests/test_section1_secrets.sh`). Your
own real profile is a local, git-ignored file.

## 1. Install

1. Confirm the NAS's Docker CLI is reachable and Container Station is
   installed (Phase 0's inventory: `docker`, `docker compose`, and
   `getconf`/`awk` are found by glob on the non-interactive PATH, not
   assumed to be on it).
2. Add a `Host` alias for the NAS to `~/.ssh/config` (or the system
   `ssh_config`) that owns the username, identity file, MagicDNS name or
   Tailscale address, and host-key policy. Confirm it connects
   non-interactively before anything else:
   ```sh
   ssh -o BatchMode=yes -o ConnectTimeout=10 <your-alias> true
   ```
3. Copy `tests/profiles/qnap-example.env` to a new, git-ignored profile
   (its own header explains why: `tests/profiles/` has no repository-wide
   `*.env` ignore rule, so add your new file's exact name to `.gitignore`
   the same way `dx_key`/`dx_key.pub` are ignored by name). Set
   `DX_REMOTE_HOST` to your alias name; leave everything else at the
   example's values unless you have a specific reason to change them
   (`DX_GUEST_SYSTEM` must match the NAS's own `uname -m`: `aarch64` ->
   `aarch64-linux`, `x86_64` -> `x86_64-linux` — the docker-ssh adapter
   refuses a mismatch before touching Nix, per DQ7). `DX_CONTAINER_MEMORY`/
   `DX_CONTAINER_CPUS` default to 8G/4 CPU (`qnap-dxe-plan.md` Phase 4,
   `docs/refactor/arch-neutral-guest.md`), smaller than Apple's 12G/4-CPU
   default, chosen to leave headroom for the NAS's existing Container
   Station workloads and its other native services rather than assuming
   the whole machine is DXE's; size up only after checking the NAS's own
   actual free CPU/memory (Phase 0's inventory records this NAS's specific
   headroom outside the repository — see the private target note, never
   committed here).
4. Generate this profile's own SSH keypair — never reuse `dx_key` or
   `dx-test_key` (a docker-ssh profile's guest is a completely separate
   identity from any Apple guest):
   ```sh
   ./bin/dx-profile <your-profile-name> ./bin/dx-create-keys
   ```
5. Bring the guest up:
   ```sh
   ./bin/dx-profile <your-profile-name> ./bin/dx
   ```
   The first bring-up bootstraps from scratch (`direct-volume` storage
   mode: a QNAP guest always starts with fresh volumes, there is no
   existing `/nix`/`/persist` to migrate onto it) and can take several
   minutes. `dx-wait-ssh`'s progress output names the bootstrap phase it
   is currently in and, once the port is open, the login-shell probe's
   own error if the guest is not answering yet — read that text before
   assuming a slow start is a hang; see
   ["Operating a QNAP guest"](lifecycle.md#operating-a-qnap-guest) and
   `docs/troubleshooting.md`.

## 2. Preflight (before every operational session, not only install)

- `uname -m` on the NAS still matches `DX_GUEST_SYSTEM` in your profile.
- The Docker CLI answers `docker version`/`docker info` over the
  management SSH connection (the same non-interactive reachability check
  every docker-ssh command already performs before doing anything else).
- `tailscale0` (or whatever interface carries the NAS's tailnet address)
  has an address, if you are about to restart the container, Container
  Station, or the NAS itself — guest SSH publishes to that address only
  (DQ5), so a restart before the interface is addressed is exactly the
  race item 9 is about; see `qnap-dxe-plan.md` Phase 6 item 9 and this
  runbook's Update section below.

## 3. Normal operation

```sh
./bin/dx-profile <your-profile-name> ./bin/dx-status   # image/container/health/SSH/tools
./bin/dx-profile <your-profile-name> ./bin/dx-ssh       # interactive shell
./bin/dx-profile <your-profile-name> ./bin/dx-forward PORT:PORT
./bin/dx-profile <your-profile-name> ./bin/dx-reverse PORT
```

`dx-status`'s SSH section reports the guest's actual discovered Tailscale
address (never `localhost`), and now distinguishes two states a bare
open/closed line could not (Branch 11 / Phase 6 item 5): the container
running but the port not open yet (shows the most recent bootstrap-progress
marker) and the port open but the guest not answering a login shell (shows
that probe's own error). Under `DX_RUNTIME=docker-ssh` it also shows the
remote per-profile lock's read-only state; `bin/dx-lock status`/`unlock
--force` manage that lock explicitly (never on elapsed time alone, DQ6).

Commands with no remote parity — refuse immediately, before any mutation,
naming why (`qnap-dxe-plan.md` DQ8): `dx-mount DIR` (a controller-local
directory is never a valid remote bind source), `dx-nix-disk` (Apple-only
sparse-image mechanism).

## 4. Update (QTS / QuTS / Container Station)

**Back up first, always — never perform a QTS or Container Station update
solely to test this runbook's own claims about it** (`qnap-dxe-plan.md`
Phase 6 item 6):

```sh
./bin/dx-profile <your-profile-name> ./bin/dx-backup
```

Then perform the QTS/QuTS/Container Station update through the NAS's own
App Center UI — DXE never triggers one itself
(`dx_runtime_docker_system_start` refuses unconditionally under
`docker-ssh`, pointing at the App Center UI, because starting or
restarting Container Station's Docker Engine remotely is a service-restart
action on production infrastructure). After the update, run preflight
(section 2) again before resuming normal operation, and confirm
`dx-status` still reports a healthy generation and the guest's SSH address
unchanged.

Restart-policy guidance (`DX_CONTAINER_RESTART_POLICY=unless-stopped`, and
the restart-ordering behaviour across a container restart, a Container
Station restart, and a NAS reboot) is being finalised against live
observations from the NAS's own maintenance window and will be added here
once settled — see `qnap-dxe-plan.md`'s Phase 6 status for the current
state. Until then, leave `DX_CONTAINER_RESTART_POLICY` at its default
(`no`) and start the guest back up yourself
(`./bin/dx-profile <your-profile-name> ./bin/dx`) after any restart.

## 5. Backup

```sh
./bin/dx-profile <your-profile-name> ./bin/dx-backup
./bin/dx-profile <your-profile-name> ./bin/dx-backup --dry-run --summary
```

Captures the at-risk contents of `/persist` (uncommitted/unpushed git
state, everything outside a repository) into
`$DX_BACKUP_DIR/$DX_CONTAINER_NAME` on the controller — a plain directory
Time Machine or any other host backup tool already protects, distinct per
profile by construction (`dx-host`, `dx-test`, and every QNAP profile each
get their own `$DX_CONTAINER_NAME`-named subdirectory, never shared). See
["Backing up and restoring /persist"](lifecycle.md#backing-up-and-restoring-persist)
for exactly what is captured and why. Run it before any update, any
storage migration, or any base-image pin change, and whenever you want a
fresh recovery point.

## 6. Restore

```sh
./bin/dx-profile <your-profile-name> ./bin/dx-restore --dry-run
./bin/dx-profile <your-profile-name> ./bin/dx-restore
```

Needs a running guest. To restore into a **freshly created** guest (after
`dx-factory-reset`, or a new NAS): bring the guest up as usual (section 1
step 5) so `/persist` exists, then run `dx-restore` with the same
`DX_BACKUP_DIR` the backup was taken into. There is no cross-guest restore
drill for a QNAP profile beyond this — a QNAP guest always starts from
scratch (`direct-volume` storage mode), so restoring `/persist` content is
the only migration path that ever applies.

## 7. Removal

```sh
./bin/dx-profile <your-profile-name> ./bin/dx-destroy          # container + image, volumes/keys kept
./bin/dx-profile <your-profile-name> ./bin/dx-destroy-volumes   # /nix and /persist, irreversible
./bin/dx-profile <your-profile-name> ./bin/dx-factory-reset     # everything, irreversible
```

`dx-factory-reset` and `dx-destroy-volumes` print an immutable ownership
plan and refuse the **whole** operation — zero delete calls issued — if
any targeted container or volume fails its `io.dxe.*` label check
(`qnap-dxe-plan.md` DQ6), rather than a resource-by-resource partial
destroy (Branch 11 / Phase 6 item 7). This is what makes it safe to run
these commands against a QNAP profile at all: by construction, they can
never reach an Apple-runtime resource (a different runtime entirely),
another QNAP profile's resources (a different `io.dxe.profile` label), or
an unrelated Container Station container or volume (no `io.dxe.managed`
label). Images have no labels at all (Docker's `tag` cannot attach one),
so `dx-destroy-image`'s exact configured name is the only protection
there — the same as it has always been.

Back up first (section 5) if there is anything in `/persist` worth
keeping; `dx-destroy-volumes`/`dx-factory-reset` delete it irreversibly.

## 8. Emergency access when Tailscale is down

Guest SSH publishes to the NAS's Tailscale address only (DQ5) — if
Tailscale itself is down, that path is unreachable by design, and there is
**no fallback LAN or public publish** to reach for instead (that is
exactly the escape DQ5 forbids). The only supported path is:

1. Reach the **NAS itself** on the LAN, as the operator, using QNAP's own
   admin SSH access (not DXE's guest SSH, which stays tailnet-only
   regardless of what else is down).
2. From there, use the NAS's own local Docker CLI to inspect or act on the
   guest directly: `docker ps`, `docker logs <container>`, `docker exec -it
   <container> ...`. This bypasses the Tailscale-dependent guest-SSH
   transport entirely, without opening any new network exposure.

Never open a permanent public ingress, and never temporarily republish the
guest's SSH port to the LAN or `0.0.0.0` "just for this" — restore
Tailscale connectivity and resume the normal path above instead.
