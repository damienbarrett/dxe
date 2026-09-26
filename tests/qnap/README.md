# QNAP Phase 0 scripts

Versioned, non-interactive, idempotent scripts for `qnap-dxe-plan.md`'s
**Phase 0 -- Target discovery and disposable proof**. They replace running
that section's commands by hand: everything here is safe to re-run, refuses
to run without a reachable, non-interactive SSH connection, and never
touches a resource that isn't named `dxe-spike-*` and labelled
`dxe.role=spike`.

There is no NAS reachable yet. Until there is, validate these scripts with
`--dry-run` and with a stub `ssh`/`docker` on `PATH` (see
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
   username, identity file, MagicDNS name, and host-key policy:

   ```sshconfig
   Host qnap-dxe
       HostName <tailscale MagicDNS name, e.g. qnap.tailnet-name.ts.net>
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

5. Confirm Docker's SSH transport works from the Mac:

   ```sh
   docker -H ssh://qnap-dxe version
   ```

   If the local `docker` CLI is missing, the docker-over-SSH control plane
   (`qnap-dxe-plan.md` DQ1) is unavailable; install Docker Desktop/CLI on the
   controller first.

## 2. Run the inventory

```sh
tests/qnap/phase0-inventory.sh                      # writes docs/evidence/qnap/phase0-inventory-<UTC date>.md
tests/qnap/phase0-inventory.sh --dry-run             # preview only; connects nowhere
tests/qnap/phase0-inventory.sh --report /tmp/out.md  # custom report path
```

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DXE_QNAP_HOST` | `qnap-dxe` | The `ssh_config` alias from step 1 |
| `DXE_QNAP_SSH_CONNECT_TIMEOUT` | `10` | Seconds before a dead connection fails closed |

The report starts with the script's own git commit, the run date (UTC), and
the host **alias** (never the address/IP/MagicDNS name -- that stays out of
the repository). It records everything in the plan's "Inventory" list:
architecture, kernel, Docker CLI path and version, selected `docker info`
fields (never the full output -- no registry/auth sections), `docker
compose version`, Container Station pool free space, whether `docker system
dial-stdio` runs without a transport error, CPU/memory/load, Tailscale
presence and version, QTS/QuTS and Container Station versions where
`getcfg`/`qpkg.conf` make them discoverable, and any backup/snapshot
indication discoverable from the CLI. It also runs the Mac-side control
plane check (`docker -H ssh://<alias> version`), or records that no local
Docker CLI is available.

Nothing recognisable as a key, token, or secret is ever intentionally
printed: `/etc/tailscale` is never read, full `docker info` is never
printed, and anything token/secret-shaped that slips into captured text
(for example inside `docker version`'s free-text build metadata) is
redacted before the report is written or printed.

## 3. Run the disposable spike

```sh
tests/qnap/phase0-spike.sh                                     # steps 1-9
tests/qnap/phase0-spike.sh --dry-run                            # preview only; connects nowhere
tests/qnap/phase0-spike.sh --with-service-restart                # also attempt container + Container Station restart
tests/qnap/phase0-spike.sh --with-nas-reboot                     # also attempt a NAS reboot (needs a maintenance window)
tests/qnap/phase0-spike.sh --cleanup                             # remove only leftover dxe-spike-* resources from an earlier run
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

### Known best-effort spots (not verifiable without the real NAS)

Phase 0 has no NAS access yet (per the branch note in
`qnap-dxe-plan.md`), so two pieces of the spike are necessarily best-effort
until the first real run confirms or corrects them -- both are called out
in comments at their definition in `tests/qnap/phase0-spike.sh`:

- **Step 5's in-container listener** (`dxe_spike_listener_command`): the
  minimal base image has no sshd, so the plan allows "a trivial listener
  like `nc -l` or busybox httpd". The script tries busybox httpd, then
  `nc`, then `socat`, in that order, and step 7's real run records which one
  actually answered. Confirm this against the real image and simplify to
  whichever tool is actually present.
- **Step 8b's Container Station restart command**
  (`dxe_spike_container_station_restart_cmd`): a best guess following the
  common QNAP qpkg init-script convention
  (`/etc/init.d/container-station.sh restart`). Confirm the qpkg's real
  `Shell`/service-control mechanism from `/etc/config/qpkg.conf` (recorded
  by the inventory) at the first real run and update this function if it
  differs.

## 4. Read the reports

- The inventory report is Markdown, written to
  `docs/evidence/qnap/phase0-inventory-<UTC date>.md` by default (or
  `--report FILE`), and also printed to stdout.
- The spike has no report file; its `PASS`/`FAIL`/`SKIP` step log to stdout
  *is* the evidence. Redirect it if you want a copy:
  `tests/qnap/phase0-spike.sh 2>&1 | tee /tmp/phase0-spike.log`.

## 5. Fail-closed behavior

Neither script prompts or reads a tty. Without `--dry-run`, both refuse to
run at all -- before creating, building, or deleting anything -- unless
`DXE_QNAP_HOST` answers a non-interactive SSH probe
(`ssh -o BatchMode=yes -o ConnectTimeout=... -o LogLevel=ERROR <alias> true`)
within `DXE_QNAP_SSH_CONNECT_TIMEOUT` seconds. A failed preflight prints a
clear error naming the host alias (never the address) and exits non-zero.

## 6. Exit gate (from `qnap-dxe-plan.md` Phase 0)

Before moving into Phase 1, the plan requires:

- Native architecture is supported, or the plan stops with a recorded
  reason (the inventory records `uname -m`; the target is a QNAP
  TVS-h674T, expected `x86_64`).
- Docker over SSH, stdin streaming, loopback publishing, named volumes, and
  reboot persistence work on the actual QNAP (the spike's steps 1, 2/3, 4,
  5/6, 7, and the guarded step 8 reboot).
- Resource limits are chosen from observed hardware (the inventory's CPU,
  memory, and load-average fields) rather than inheriting the Apple
  runtime's 12 GB/four-CPU defaults blindly.
- No spike resource or port remains (`tests/qnap/phase0-spike.sh --cleanup`,
  with its diff proof).
