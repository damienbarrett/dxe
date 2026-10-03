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
own real profile lives outside the checkout in the user config directory
described below; its SSH keys live separately under `~/.ssh/dxe/`.

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
3. Copy `tests/profiles/qnap-example.env` to
   `${XDG_CONFIG_HOME:-$HOME/.config}/dxe/profiles/<your-profile-name>.env`.
   Keep personal profiles outside the checkout and set `DX_SSH_KEY` and
   `DX_SSH_KEY_PUB` to absolute paths under `~/.ssh/dxe/`; the profile stores
   paths, never key material. Create that key directory with mode `700`.
   Profiles do not expand `~` or `$HOME`, so write your actual home path. Set
   `DX_REMOTE_HOST` to your alias name; set `DX_PROFILE_ROOT` to the absolute
   path of the one checkout allowed to drive this profile (kept only in your
   private profile, never in a tracked file), so a second checkout cannot
   reach the NAS; leave everything else at the
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
   The guest's hostname is its container name (the adapter passes
   `--hostname` equal to `--name`, as Apple does), so the shell prompt and tmux
   status read the same on every recreate and on both runtimes.

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

`./bin/qx` delegates to `dx` with the user profile
`${XDG_CONFIG_HOME:-$HOME/.config}/dxe/profiles/qnap.env` (the default;
the canary profile is retired) to
connect to the production QNAP guest and attach to its `dx` tmux session. If the
container is already running, it connects directly without publishing
bootstrap changes. If it is stopped or absent, it runs the full `dx`
bring-up flow first. With `bin/` on your PATH,
run `qx` to connect or `qx 'uname -a'` to run a guest command. Arguments
pass through unchanged. Set `QX_PROFILE=<name>` to use another profile
(letters, digits, `.`, `_`, `-`; it must not start with `.` or `-`). The profile must exist; `qx` fails if it
is missing. `dx-profile` also supports `DX_PROFILES_DIR` for an explicit
directory and bundled profiles under `tests/profiles/`; user profiles take
precedence when no explicit directory is supplied.

Bootstrap updates remain an explicit maintenance step: publish with
`./bin/dx-profile qnap ./bin/dx-sync-bootstrap`, then stop and start
the container under the same profile to activate the update. A restart
ends running guest processes and tmux sessions, so choose a suitable time.

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
--force` manage that lock explicitly (never on elapsed time alone, DQ6). The
lock is a never-started container built from the Containerfile's pinned base
image reference (not the profile's own image), so the first `dx` for a
brand-new profile can take it before `dx-create-image` has made that image.

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

**Restart policy and restart ordering — settled 2026-09-28.** A
maintenance window against a disposable guest (`dx-qnap-spike`, 8 GB /
4 CPU x86_64) on this NAS proved `DX_CONTAINER_RESTART_POLICY=unless-stopped`
across all three restart kinds: a container restart, a Container Station
restart (Docker unreachable for ~40s, the guest came back on its own,
`RestartPolicy` preserved), and a full NAS reboot (the NAS unreachable
over SSH for ~7 minutes; the guest was already running, on the same
Tailscale-only bind, by the time SSH answered again). In every case the
guest resumed the last published bootstrap generation with no controller
present, and `dx-wait-ssh` was ready within about 30-40s of the guest
itself becoming reachable. No state was lost; the port never bound
`0.0.0.0`, not even transiently. This is per-NAS evidence, not a
guarantee about every QNAP model or QTS/QuTS release: it relies on
`tailscale0` already being addressed before Container Station starts any
container, which held throughout this window.

**Default stays `no`.** Set `DX_CONTAINER_RESTART_POLICY=unless-stopped`
in your own profile only after your own guest has completed at least one
full, successful bootstrap and `dx-status` shows a healthy generation
(section 1's guardrail) — this proof does not carry over to a NAS you
have not tested it on yourself. If you have not run this same check on
your own NAS, leave the default (`no`) and start the guest back up
yourself (`./bin/dx-profile <your-profile-name> ./bin/dx`) after any
restart. If the guest ever fails to come back after a restart with
`unless-stopped` set, `dx-status`/`docker ps`/Container Station will show
it exited with a bind error rather than silently publishing on the wrong
address (DQ5's invariant always holds); the remedy is the same manual
start once `tailscale0` has its address again, never a wider publish.

**Troubleshooting: `dx-status` reports a stale "Running" generation after a
restart.** Inside a Docker container the kernel boot id is the NAS kernel's
and does not change when the container restarts, so the previous
incarnation's PID 1 execution lease carries the same boot id as the live one.
`dx-status` and `dx-start-container` now treat a lease as live only when its
boot id, PID and process start time all match a running process, and every
sync (published or unchanged-content skip) prunes the rest, so a false
"running an older generation" drift line should not recur. If you still see
one, run `dx-sync-bootstrap` (or any `dx-start-container`) once to prune, then
re-check `dx-status`; the Docker health check, which looks only at the
current generation's lease, was always authoritative.

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

The selector may warn "`<path>/.git` is a file, not a directory (a linked
worktree or submodule)". That is informational: the path is still backed
up, it is just not treated as a repository boundary.

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

After a `dx-backup`, a `dx-restore --dry-run` may list a few "would create"
entries for files that existed at backup time and were removed since,
typically SQLite `-wal`/`-shm` side files of a tool that was running. They
are not a backup defect: the backup is verified when the dry-run shows no
directory-mode conflicts and the file count is otherwise identical.

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

Guest SSH (and the usage service's port, when enabled — section 10) publishes to
the NAS's Tailscale address only (DQ5) — if
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

## 9. Promotion (canary acceptance)

Promoting the QNAP runtime from proof-of-concept to daily use
(`qnap-dxe-plan.md` Phase 7; design:
[`docs/refactor/qnap-promotion.md`](refactor/qnap-promotion.md)). Every
step below is the coordinating session's own action, each after the
user's explicit go — this section is a checklist and reference, not
something a subagent runs.

**Identity.** The canary: `dx-qnap-canary`, guest SSH on the NAS's
Tailscale address at port **2222**,
`DX_CONTAINER_RESTART_POLICY=unless-stopped` from creation (proven on
this NAS in Phase 6's maintenance window), **8 GB / 2 CPU** — the user's
own choice for the canary only, not a new default (see
[`tests/profiles/qnap-canary-example.env`](../tests/profiles/qnap-canary-example.env)).
Acceptance period: **one week** of real daily use. **Pre-approved
(2026-09-28):** the canary is created as soon as Phase 7's code lands on
`main`; the one-week acceptance period starts on that creation day, not
on some later date.

### 9.1 Daily-use exercise list

Exercise each of the following at least once during the week (not a
fixed daily order): `git` (clone/commit/push/pull inside the guest);
Nix (a rebuild that changes a generation, `dx-status` showing the new
generation active); `tmux` (a session that survives a `dx-ssh`
disconnect/reconnect); at least one editor; `dx-ai`/Herdr or another AI
tool; `dx-forward`/`dx-reverse` (one tunnel each way); controller
suspend/reconnect (close the laptop lid mid-session, reopen, confirm
`dx-status`/`dx-ssh` recover without guest-side action); an ordinary
controller network change (Wi-Fi to a different network, or Wi-Fi to a
hotspot); and the relay-fallback observation below, which needs its own
deliberate pass.

**Relay-fallback observation.** The one item 1 check Phase 6's exit gate
carried over: a guest stays reachable when the direct Tailscale path
fails and traffic relays. Force the controller's *direct* path to the
NAS to fail — reaching a network known to block UDP hole-punching (a
restrictive Wi-Fi network or hotspot) is the preferred way to produce
this; a controller-side firewall rule blocking outbound UDP is an
acceptable substitute **only as a fallback, if no such restrictive
network turns up during the week** — never anything on the NAS side
either way. Before: `tailscale status` (the NAS's peer line) and
`tailscale ping <NAS's tailscale address>`, both showing a direct
endpoint. Force the change; after: the same two commands now showing the
peer routed `via` a DERP relay. While relayed: `dx-status`/`dx-ssh`
against `dx-qnap-canary` still succeed, unchanged — this is the actual
proof (plain SSH over whatever Tailscale routes underneath; the
published `<tailscale address>:2222` bind never changes). Record all
four outputs, sanitized (no real address in the evidence record).

**Evidence.** Record a dated, sanitized entry per exercised item under
`docs/evidence/<date>/qnap-promotion.md` — the exact `dx-*` command run
(generic host alias `qnap-dxe` only, never a real address) and the
observed result; the relay-fallback entry additionally carries the four
`tailscale status`/`ping` before/after lines, sanitized the same way
`docs/refactor/qnap-lifecycle.md`'s own evidence record is. Also record,
once, for the week's own final validation: the NixOS release pin
(`flake.nix`'s three branch refs), the base image tag + digest
(`docs/release-maintenance.md`'s alignment rule), and
`DX_IMAGE_IDENTITY` before/after the rebuild below.

### 9.2 Image rebuild + recreate, preserving volumes

Follow [`docs/release-maintenance.md`](release-maintenance.md)'s existing
procedure — no new procedure for QNAP. Against the live canary:

```sh
./bin/dx-profile dx-qnap-canary ./bin/dx-recreate
```

(If this coincides with an actual release-pin bump, follow
`docs/release-maintenance.md`'s "MIND THE PIN" branch instead —
`dx-destroy -> dx-reset-nix-volume -> dx` — since a changed Nix image
pin is a store-trust event, not a plain recreate; either branch
preserves `/persist` and the SSH identity.)

Record before/after, via `dx-status`/`dx-backup --dry-run`, no new
tooling:

- `DX_IMAGE_IDENTITY` changed (new build), and the guest's bootstrap log
  shows it noticed the change.
- `/persist` content unchanged: `dx-backup --dry-run` immediately before
  and immediately after reports the same at-risk selection (ideally "0
  files ... transferred" on the after-run if a backup was taken just
  before recreating).
- SSH host identity: the per-profile known-hosts pin is **expected** to
  need no `ssh-keygen -R` (a QNAP guest's host key lives on the
  `/persist`-adjacent state `direct-volume` mode preserves across a
  recreate) — this is an expectation, not a given; **verify it in the
  evidence record** by confirming `dx-ssh` connects with no host-key
  mismatch warning immediately after the recreate.
- Labels, port, and restart policy unchanged (`docker inspect` /
  `dx-status`).

### 9.3 Destructive lifecycle on disposables only

Reaffirms, does not redesign, Phase 6's already-proven procedure
(`dx-destroy-volumes`/`dx-factory-reset`'s immutable ownership plan,
whole-operation refusal on any label mismatch) — now run with the canary
concurrently live, a stronger proof than Phase 6's spike-only
environment. Create a fresh `dx-qnap-spike*`-labelled disposable guest,
run `dx-destroy-volumes --force`/`dx-factory-reset --force` against it,
and separately confirm refusal against a deliberately mislabelled or
misnamed target resembling the canary (zero delete calls). **Never** run
any destructive command against `dx-qnap-canary` itself, its volumes, or
its keys.

### 9.4 Restore drill (a second isolated profile)

Demonstrates a full backup + restore on a QNAP guest — the other item
Phase 6's exit gate carried over (item 3). The second profile is
**disposable**: name `dx-qnap-drill`, port **2224**, its own volumes and
keys, created and destroyed during the canary week (never reused, never
confused with the canary or the eventual production profile).
**Pre-approved (2026-09-28)** to be created and destroyed during the
canary week — but the operator is still warned before each of those two
steps (creation and destruction), not created or torn down silently: say
so at the time, name the exact commands about to run, and confirm before
running them.

```sh
# 1. Fresh backup of the canary.
./bin/dx-profile dx-qnap-canary ./bin/dx-backup

# 2. Bring up the disposable drill profile (its own local, git-ignored
#    profile, own keys, own volumes -- port 2224 so it can run alongside
#    the still-live canary).
./bin/dx-profile dx-qnap-drill ./bin/dx-create-keys
./bin/dx-profile dx-qnap-drill ./bin/dx

# 3. Restore the CANARY's backup into the DRILL guest -- dry-run first.
./bin/dx-profile dx-qnap-drill ./bin/dx-restore --source-container=dx-qnap-canary --dry-run
./bin/dx-profile dx-qnap-drill ./bin/dx-restore --source-container=dx-qnap-canary
```

`--source-container=dx-qnap-canary` overrides only which mirror
`dx-restore` reads *from*; it always pushes into the profile actually
running the command (here, `dx-qnap-drill`) — a plain `dx-restore` run
under `dx-qnap-drill` with no flag would refuse instead (no backup
mirror), exactly as it does for any fresh profile; the flag is the only
way to cross profiles, and it never happens by accident. `dx-restore`
prints `Restoring dx-qnap-canary's backup into dx-qnap-drill
(cross-profile restore).` whenever the flag is given, including under
`--dry-run` — check for that line before trusting the run touched the
intended pair of profiles.

**Expect a refusal on the first real run, and `--force` for it.** A freshly
created guest already holds the bootstrap-seeded Herdr configuration, which
differs from the mirrored one, so the dry-run reports it as a conflict and
the plain `dx-restore` refuses (as it does for any differing target; an
existing directory whose mode differs from the captured one is refused the
same way). On this disposable drill guest only, re-run the same command with
`--force` once the dry-run shows nothing but that expected configuration (and,
possibly, directory-mode) conflict. Never add `--force` against a guest that
holds data you want to keep.

**Verify content and permissions:**

```sh
# Content: re-run the dry-run after the real push -- every target should
# now report "already identical" (sha256-based, the same classification
# dx-restore always uses).
./bin/dx-profile dx-qnap-drill ./bin/dx-restore --source-container=dx-qnap-canary --dry-run

# Permissions: dx-restore always restores dx:dx ownership and preserves
# file modes from the mirror, and recreates each directory with the mode
# captured in the generation's dirs.tsv (an existing directory with a
# different mode is refused unless you re-run as `dx-restore --force`,
# which also overwrites differing files) -- spot-check
# both explicitly, including a directory such as the guest's private state
# directory. A mirror made before directory modes were captured says so
# once and restores directories with default modes.
./bin/dx-profile dx-qnap-drill ./bin/dx-enter -- \
    find /persist -not \( -user dx -a -group dx \) -print   # expect empty
./bin/dx-profile dx-qnap-drill ./bin/dx-enter -- \
    stat -c '%a %n' /persist/<a known path>   # compare against the same
                                                # path's mode on the canary
```

Once the drill is done, tear it down (it was always disposable) — warn
the operator before running this, the same as before the drill's own
creation above:

```sh
./bin/dx-profile dx-qnap-drill ./bin/dx-factory-reset --force
```

### 9.5 Production profile and `dx-host`

Once the week passes with no unresolved checklist failure and the
restore drill above counts as the verified backup, the user creates the
production profile. Identifiers (the user's own decision, not this
document's — see
[`tests/profiles/qnap-example.env`](../tests/profiles/qnap-example.env)):
`DX_CONTAINER_NAME=dx-qnap` (already `qnap-example.env`'s own value),
**port 2222** (since 2026-10-03). During the cutover the production
guest used the temporary port 2223 (2026-09-28 → 2026-10-03), distinct
from the canary's 2222 so both could run concurrently; the canary was
retired on 2026-10-03 and 2223 was given back. 8 GB / 4 CPU and
`unless-stopped` from creation (both already `qnap-example.env`'s own
documented values).

`dx-host` (the Apple DXE) receives no destroy, no factory-reset, no
volume change, until **both** the canary has completed its full
acceptance period with no unresolved failure, and `/persist`'s
irreplaceable content has a **verified** backup (restored-and-checked —
section 9.4's drill is the qualifying event). Destroying or retiring
`dx-host` is never scheduled by this document; it stays the user's own
separate, later, explicit call.

## 10. Usage service

The guest can run the `agent-stats` collector and its HTTP API (port 8787
inside the guest) as a supervised service next to sshd, reachable from your
Apple devices over the tailnet. It is off by default and opt-in per profile.
Design: [`docs/refactor/usage-service-host.md`](refactor/usage-service-host.md).

### 10.1 The publication rule (DQ5)

Without the service, guest SSH is the only published port. With
`DX_USAGE_SERVICE=on` the rule reads: **SSH, plus the usage service when
enabled, both on the NAS's Tailscale address only, never the LAN or
`0.0.0.0`.** The second mapping is an explicit, opt-in extension of the
SSH-only rule. It uses the same publish path as SSH (the address is
discovered at run time and never written to any file). The API has no
authentication of its own; the tailnet is the access control. With the field
`off` the create command is byte-identical to a profile that never set it.

### 10.2 Enabling it (maintenance window)

1. In your private profile (never a tracked file) set `DX_USAGE_SERVICE=on`
   and, only if 8787 is taken or unwanted, `DX_USAGE_SERVICE_HOST_PORT`. The
   port must differ from `DX_SSH_PORT`; `dx-create-container` refuses `on`
   otherwise. See the commented lines in
   [`tests/profiles/qnap-example.env`](../tests/profiles/qnap-example.env).
2. In a window you have named, recreate the guest under that profile:
   `./bin/dx-profile <profile> ./bin/dx-recreate`. It takes about two minutes
   and **kills running tmux sessions**; `/persist`, `/nix` and the bootstrap
   volume are kept. Both the second mapping and the guest-visible
   `DX_USAGE_SERVICE` variable are fixed at container creation, so changing
   either later needs another recreate. The first boot with the service on
   upgrades the essentials profile (it adds the s6 tools to an existing
   guest), which needs network access and takes longer than a normal boot; the
   guest log shows an "Upgrading the essentials profile" line. If the boot cannot
   complete, `dx` stops waiting once the restart count rises (see its error and
   the last log lines) instead of polling for the full timeout.
3. Verify: `./bin/dx-profile <profile> ./bin/dx-usage-service status`, then
   from a tailnet device
   `curl -s http://<NAS tailnet name>:8787/health/live` (200),
   `/health/ready` (503 until the first report, then 200 even when a provider
   shows an error row) and `/health/progress` (200; 503 only for a stalled
   collection). Until a release is installed (10.3) the service reports that
   no usable release exists and retries every 30 seconds.

To turn it off: remove the lines (or set `off`) and recreate. State under
`/persist/services/agent-stats` is kept.

### 10.3 Installing and selecting a release

Releases are built and linked **as `dx` inside the guest**, for example from
`dx-enter`. Build the combined output `agent-stats-release` (both
implementations, `bin/agent-stats-rust`, `bin/agent-stats-python`,
`bin/check-limits`, `share/agent-stats/*`), from either source:

```bash
# pinned flake reference (needs repository access from the guest)
nix build --no-link --print-out-paths \
  github:<OWNER>/agent-stats/<commit>#agent-stats-release
```

**Copying a source tree instead.** The `dx` user's non-interactive `PATH` has
no `tar`, and `dx-ssh` does not forward stdin, so a tar pipe or `dx-put` of a
tree does not work. Copy a **git bundle** to the guest's published address and
build from a clone of it. On the machine that has the source:

```bash
git bundle create /tmp/agent-stats.bundle --all
scp -P <SSH port> -i <profile key> /tmp/agent-stats.bundle dx@<guest address>:/tmp/
```

then, as `dx` inside the guest:

```bash
git clone /tmp/agent-stats.bundle /tmp/agent-stats-src
nix build --no-link --print-out-paths \
  "git+file:///tmp/agent-stats-src?rev=<commit>#agent-stats-release"
```

`<SSH port>` and `<profile key>` come from your private profile
(`DX_SSH_PORT`, `DX_SSH_KEY`), and the guest address is the published
Tailscale address. For the same commit the store path is identical to the one
the pinned GitHub reference builds.

Register the result as a Nix GC root and select it. Move the old `current`
target to `previous` first, so a rollback target always exists:

```bash
cd /persist/services/agent-stats
old="$(readlink -f current 2>/dev/null || true)"
[ -z "$old" ] || nix-store --add-root /persist/services/agent-stats/previous --indirect -r "$old"
nix-store --add-root /persist/services/agent-stats/current --indirect -r <store path>
```

then, from the host, `./bin/dx-profile <profile> ./bin/dx-usage-service restart`.
The launcher never creates or moves either link.

**Rollback:** point `current` back at `previous`'s target
(`nix-store --add-root /persist/services/agent-stats/current --indirect -r "$(readlink -f /persist/services/agent-stats/previous)"`)
and restart the service.

### 10.4 Implementation selection

`/persist/services/agent-stats/config/implementation` holds `rust` (the
default; also when the file is absent or empty) or `python`. Any other value
is a clear launcher error. Restart the service after changing it.

### 10.5 Where things live

| What | Where |
| --- | --- |
| State | `/persist/services/agent-stats/{config,workspace,data,logs,control}`, owned by `dx` (`control` carries the dx-ai restart request); the service's tmux state is under `workspace/tmux` |
| Releases | `current` and `previous` in that directory (GC roots) |
| Logs | `/persist/services/agent-stats/logs/{sshd,agent-stats,agent-stats-watchdog}/current`, bounded (10 files of 1 MB each per service); read with `dx-usage-service logs [N]` |
| Service tree | `/run/dx-services`, rebuilt on every boot, PID 1 is `s6-svscan` |

In service mode **sshd's `-e` log goes to its persisted s6-log directory
(`logs/sshd`), not to `docker logs`**; `docker logs` shows only bootstrap
output. The host health check is unchanged (it reads the lease and readiness
marker only).

`dx-usage-service start|stop|restart|status|logs [N]` drives only the
agent-stats service (docker-ssh only; Apple refuses). A guest not in service
mode answers with how to enable it.

### 10.6 Apple clients

Point the Apple clients at `http://<NAS tailnet name>:8787/` (or your
`DX_USAGE_SERVICE_HOST_PORT`).

### 10.7 `dx-ai` updates

After a successful `dx-ai` in a guest in service mode, the hook asks for a
restart of only agent-stats (so it sees the new generation's `PATH`). The guest
has no usable `sudo`, so there is none involved: the hook, running as `dx`,
writes `/persist/services/agent-stats/control/restart` atomically, and the
root watchdog consumes that file and runs `s6-svc -r` on agent-stats, picking it
up within one watchdog interval (about 30 seconds) and without any back-off. The
hook waits up to 60 seconds for the request to be picked up and `/health/live`
to answer again (without `curl` it skips the wait and says so), then runs a
compatibility check. The check is a **stub until the package is installed**: it
prints the agreed check (`agent-stats-rust --version` succeeding on the new
`PATH`) and passes. A failed request, a service that does not come back, or a
failed check is reported with "no rollback was performed" and never fails
`dx-ai`; shared tools are never silently reverted. To restart by hand at any
time, use `dx-usage-service restart` from the host.
