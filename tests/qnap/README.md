# QNAP Phase 0 scripts

Versioned, non-interactive, idempotent scripts for `qnap-dxe-plan.md`'s
**Phase 0 -- Target discovery and disposable proof**. They replace running
that section's commands by hand: everything here is safe to re-run, refuses
to run without a reachable, non-interactive SSH connection, and never
touches a resource that isn't named `dxe-spike-*` and labelled
`dxe.role=spike`.

**The NAS is a production system, and this repository is public.** Every
report these scripts produce is private by default -- written OUTSIDE this
repository, under `$HOME/dxe-recovery/qnap/` -- and must never be committed.
The only thing that ever belongs in this repository after a real run is a
one-line outcome (native architecture supported yes/no; Docker-over-SSH
viability) added to `qnap-dxe-plan.md` by hand. Never paste a hostname,
Tailscale MagicDNS name, tailnet address, storage-pool/dataset name, account
name, or any key material into a tracked file --
`tests/test_section1_secrets.sh` scans for exactly these shapes, but that is
a safety net, not a substitute for care.

There is no NAS reachable yet from this branch's own work. Validate these
scripts with `--dry-run` and with a stub `ssh`/`docker` on `PATH` (see
`tests/test_section27_qnap_scripts.sh`); do not point `DXE_QNAP_HOST` at a
real host until you have completed the access setup below.

## 1. Prepare access

1. Generate a dedicated management keypair for the QNAP (do not reuse an
   existing DXE guest key):

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/dxe-qnap -N ""
   ```

2. On the QNAP (Control Panel -> Network & File Services -> Telnet/SSH, or
   the admin UI's authorized-keys mechanism), append the **public** key
   (`~/.ssh/dxe-qnap.pub`) to the management account's
   `~/.ssh/authorized_keys`. Use a non-`admin` account if the QNAP supports
   running Docker non-interactively as one (Phase 0's inventory records
   whether it does); never paste the private key anywhere.

3. Add a `Host` stanza to `~/.ssh/config` on the controller (this Mac). Per
   `qnap-dxe-plan.md` DQ1, this alias -- not these scripts -- owns the
   username, identity file, MagicDNS name, and host-key policy. Get the
   NAS's MagicDNS name from the Tailscale admin console rather than writing
   it here:

   ```sshconfig
   Host qnap-dxe
       HostName <the NAS's MagicDNS name, from the Tailscale admin console>
       User <management account>
       IdentityFile ~/.ssh/dxe-qnap
       IdentitiesOnly yes
   ```

   Do not add `StrictHostKeyChecking no` here: per the plan's invariants,
   the QNAP's management host key is verified normally like any other host
   you SSH to. The first connection will prompt to accept its host key
   fingerprint once (accept it after confirming out-of-band, e.g. via the
   QNAP admin UI), and afterwards it is pinned in your `known_hosts` as
   usual.

4. Confirm plain `ssh qnap-dxe true` works interactively once, then confirm
   the non-interactive form these scripts use also works:

   ```sh
   ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR qnap-dxe true
   ```

   If this fails, these scripts fail closed with the same check before
   touching anything (see "Fail-closed behavior" below).

5. Neither script depends on a local Docker CLI. The Container Station
   qpkg's Docker CLI is usually not on the NAS's non-interactive PATH
   either -- confirmed on the real target NAS -- so both scripts discover
   its absolute path themselves over SSH (falling back to a glob under the
   Container Station qpkg's own bin directory) and invoke it as a plain SSH
   remote command; see `qnap-dxe-plan.md` DQ1 and
   `lib/phase0-common.sh`'s `dxe_qnap_docker_run` for why. An explicit
   `DXE_QNAP_DOCKER=<absolute path>` overrides discovery if you already know
   it. `phase0-inventory.sh` separately records whether the naive
   `docker -H ssh://<alias> ...` mechanism (the local Docker CLI's own ssh
   transport) works, purely as a documented finding -- it is not required
   for either script to function.

## 2. Run the inventory

```sh
tests/qnap/phase0-inventory.sh                        # writes both reports under $HOME/dxe-recovery/qnap/ (private)
tests/qnap/phase0-inventory.sh --dry-run               # preview only; connects nowhere
tests/qnap/phase0-inventory.sh --report FILE           # custom full-report path
tests/qnap/phase0-inventory.sh --summary FILE          # custom summary path
```

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DXE_QNAP_HOST` | `qnap-dxe` | The `ssh_config` alias from step 1 |
| `DXE_QNAP_SSH_CONNECT_TIMEOUT` | `10` | Seconds before a dead connection fails closed |
| `DXE_QNAP_DOCKER` | discovered | Absolute path to the Docker CLI on the NAS; overrides discovery |

Both `--report` and `--summary` default to `$HOME/dxe-recovery/qnap/` --
**outside this repository** -- and both files start with the script's own
git commit, the run date (UTC), and the host **alias** (never the
address/IP/MagicDNS name).

- **`--report` (FULL)**: everything in the plan's "Inventory" list --
  architecture, kernel, the Docker CLI's discovered path and version,
  selected `docker info` fields (never the full output -- no registry/auth
  sections), `docker compose version`, Container Station storage free/total,
  whether `docker system dial-stdio` runs without a transport error,
  CPU/memory/load, Tailscale's discovered path and version, QTS/QuTS and
  Container Station versions where `getcfg`/`qpkg.conf` make them
  discoverable, any backup/snapshot indication discoverable from the CLI,
  whether the account is QNAP's default superuser and whether it is in the
  administrators group (never the account name itself), and the Mac-side
  "naive" control-plane finding (`docker -H ssh://<alias> version`).
- **`--summary`**: a small, whitelisted-fields-only file with no hostnames,
  addresses, paths, storage-pool names, or account names -- architecture,
  kernel version, QTS/QuTS + Container Station versions, Docker/Compose
  versions, `dial-stdio` support (yes/no), CPU count, memory, storage
  free/total in KB only (no path or pool name), whether a non-default
  administrator account can run Docker non-interactively (yes/no),
  Tailscale present (yes/no), and the docker-over-ssh finding (yes/no).

Nothing recognisable as a key, token, or secret is ever intentionally
printed: `/etc/tailscale` is never read, full `docker info` is never
printed, the account name is never captured, and anything token/secret-
shaped that slips into captured text (for example inside `docker
version`'s free-text build metadata) is redacted before either file is
written.

## 3. Run the disposable spike

```sh
tests/qnap/phase0-spike.sh                          # steps 1-9; writes both reports under $HOME/dxe-recovery/qnap/ (private)
tests/qnap/phase0-spike.sh --dry-run                 # preview only; connects nowhere
tests/qnap/phase0-spike.sh --with-service-restart     # also attempt container + Container Station restart
tests/qnap/phase0-spike.sh --with-nas-reboot          # also attempt a NAS reboot (needs a maintenance window)
tests/qnap/phase0-spike.sh --cleanup                  # remove only leftover dxe-spike-* resources from an earlier run
```

The spike implements the plan's nine steps as individually numbered,
reported steps (`PASS`/`FAIL`/`SKIP` with a reason). Every resource it
creates is named `dxe-spike-<role>` **and** carries `--label
dxe.role=spike`; every query or removal filters by that label, so nothing
unlabelled and nothing pre-existing is ever touched. It captures a full
`docker ps -a` / `docker volume ls` / `docker image ls` snapshot before and
after each run (and around `--cleanup` alone) and prints a diff proof that
only `dxe-spike-*` entries changed.

Restarts are guarded and, without their flag, reported as skipped:

- Container restart and the Container Station restart attempt need
  `--with-service-restart`.
- The NAS reboot needs `--with-nas-reboot`, and per the plan should only be
  run during an agreed maintenance window.

Without either flag, step 8 prints `SKIP (... needs maintenance window ...)`
for each guarded action and never issues the corresponding command.

`--cleanup` alone is idempotent: if there is nothing labelled `dxe.role=spike`
left, it reports "No labelled ... to remove" for each resource kind and exits
0.

Like the inventory, `--report`/`--summary` default under
`$HOME/dxe-recovery/qnap/`. `--report` gets the full step-by-step log
(may include the discovered Docker CLI absolute path -- fine, it is
private); `--summary` gets only the `Step N: PASS/FAIL/SKIP` lines (no
detail, no paths, no digests) plus a reminder of the `dxe-spike-` name
prefix convention.

### Known best-effort spots (not verifiable without the real NAS)

Two pieces of the spike are necessarily best-effort until the first real
run confirms or corrects them -- both are called out in comments at their
definition in `tests/qnap/phase0-spike.sh`:

- **Step 5's in-container listener** (`dxe_spike_listener_command`): the
  minimal base image has no sshd, so the plan allows "a trivial listener
  like `nc -l` or busybox httpd". The script tries busybox httpd, then
  `nc`, then `socat`, in that order, and step 7's real run records which one
  actually answered. Confirm this against the real image and simplify to
  whichever tool is actually present.
- **Step 8b's Container Station restart command**
  (`dxe_spike_container_station_restart_cmd`): a best guess following the
  common QNAP qpkg init-script convention. Confirm the qpkg's real
  service-control mechanism (recorded by the inventory's Container Station
  version field) at the first real run and update this function if it
  differs.

## 4. Read the reports

Both scripts print their summary to stdout and tell you (on stderr) exactly
where the full report and summary were written -- always under
`$HOME/dxe-recovery/qnap/` unless you passed `--report`/`--summary`
explicitly. Neither file is ever written inside this repository by default.

## 5. Fail-closed behavior

Neither script prompts or reads a tty. Without `--dry-run`, both refuse to
run at all -- before creating, building, or deleting anything -- unless
`DXE_QNAP_HOST` answers a non-interactive SSH probe
(`ssh -o BatchMode=yes -o ConnectTimeout=... -o LogLevel=ERROR <alias> true`)
within `DXE_QNAP_SSH_CONNECT_TIMEOUT` seconds. A failed preflight prints a
clear error naming the host alias (never the address) and exits non-zero.
`phase0-spike.sh` additionally requires discovering (or being given via
`DXE_QNAP_DOCKER`) the Docker CLI's absolute path before running any step or
`--cleanup`.

## 6. Exit gate (from `qnap-dxe-plan.md` Phase 0)

Before moving into Phase 1, the plan requires:

- Native architecture is supported, or the plan stops with a recorded
  reason (the inventory records `uname -m`).
- Docker over SSH, stdin streaming, loopback publishing, named volumes, and
  reboot persistence work on the actual QNAP (the spike's steps 1, 2/3, 4,
  5/6, 7, and the guarded step 8 reboot).
- Resource limits are chosen from observed hardware (the inventory's CPU,
  memory, and load-average fields) rather than inheriting the Apple
  runtime's 12 GB/four-CPU defaults blindly.
- No spike resource or port remains (`tests/qnap/phase0-spike.sh --cleanup`,
  with its diff proof).

Record only the one-line outcome (native architecture supported yes/no;
Docker-over-SSH viability) in `qnap-dxe-plan.md` -- never the full or
summary report content.
