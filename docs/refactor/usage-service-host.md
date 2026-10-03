# Usage service on the production QNAP guest — DXE-side design

Decided with the user on 2026-10-03 (answers 1B, 2B, 3A, 4A to the four
questions). Inputs: the usage-stats plan (kept outside this repository) section 10's requirements
table, the three reference commits on `feat/usage-service-host-config`
(registry fields, a loopback publication flag, docs; one uncommitted
`dx-create-container` edit), and the guest bootstrap, which today ends with
`exec sshd -D -e -p 2222`. Target: `dx-qnap` (production, SSH on the NAS's
Tailscale address at port 2222).

## What is being asked

Run the `agent-stats` collector and its HTTP API (`:8787` inside the guest)
in the production DXE guest as user `dx`, supervised so its own failures
restart it without restarting SSH or the guest, reachable from the user's
Apple devices over the tailnet, reusing the guest's installed AI tools and
keyring.

## Decisions

1. **Exposure (1B):** the service is published the same way SSH is — on the
   NAS's discovered Tailscale address, never loopback-plus-Serve, never the
   LAN or `0.0.0.0`. Default host port `8787` (the field stays configurable).
   Access control is the tailnet itself; the API has no authentication of its
   own, which the user accepts for a tailnet-only bind.
2. **Proof (2B):** no fake-package round. The DXE half is built and gated
   container-free now; its live proof waits for the real `x86_64-linux`
   package from the usage-stats session and runs once, on a disposable
   docker-ssh spike. The Apple tier still runs as regression for the service-
   off path (which must stay byte-identical).
3. **Production (3A):** service mode is enabled on `dx-qnap` only after that
   proof, in a user-named window: edit the private `qnap` profile,
   `dx-recreate` (about two minutes; kills tmux sessions), verify.
4. **Priority (4A):** start now.

## Design

1. **Registry fields** (from the reference commits, reviewed): `DX_USAGE_SERVICE`
   enum `off|on`, default `off`; `DX_USAGE_SERVICE_HOST_PORT` port, default
   `8787`. Strict registry, fixture, field count, `docs/configuration.md`.
2. **Second tailnet publication, opt-in.** When `on`, `dx-create-container`
   adds `--publish HOSTPORT:8787` through the SAME neutral publish vocabulary
   SSH uses (the adapter renders the discovered Tailscale address in front of
   it; Apple renders its loopback as it does for SSH) plus `--env
   DX_USAGE_SERVICE=on`. Off is byte-identical to today. The reference
   commits' `--publish-loopback` is dropped in favour of reusing the existing
   mapping path; the docker-ssh adapter's rule "SSH is the only publication"
   becomes "SSH, plus the usage service when enabled", documented in the
   runbook as an explicit opt-in (DQ5).
3. **Guest service mode.** `bootstrap.sh serve` reads `${DX_USAGE_SERVICE:-off}`
   after publishing the readiness marker. Off: `exec sshd -D -e -p 2222` as
   now. On: `exec s6-svscan` (from the guest flake's locked nixpkgs) as PID 1
   over a service directory with `sshd` (same argv), `agent-stats` (the
   launcher) and `agent-stats-watchdog`, each with `s6-log` bounded logs under
   `/persist/services/agent-stats/logs`. Lease, readiness marker, signal
   forwarding and bounded shutdown preserved; `dx-stop-container` still stops
   the guest; the Docker health check is unchanged.
4. **Launcher** (`scripts/dx-usage-service.sh`, run as `dx`): start or reuse
   the keyring through `scripts/lib/dx-keyring.sh`, read the validated
   address file into the environment, prepend the active `dx-ai` generation's
   `profile/bin` to PATH, create `/persist/services/agent-stats/{config,workspace,data,logs}`
   and the `current`/`previous` release links (Nix GC roots) if absent, seed
   defaults only when absent, then exec the selected package's
   `--serve --bind 0.0.0.0:8787 --interval 900` in the foreground (the bind
   inside the container; the host-side publication is what limits reach).
   The watchdog polls `http://127.0.0.1:8787/health/progress` and restarts
   only `agent-stats` on a 503-progress or on exit, never on `/health/ready`
   503 or provider failures; bounded retry delays.
5. **Host lifecycle commands**: `dx-usage-service start|stop|restart|status|logs`
   via `dx_runtime_exec` to `s6-svc`/`s6-svstat`, docker-ssh only (Apple
   refuses with the capability message); a `dx-ai` update restarts only
   `agent-stats` and runs the compatibility check (no silent rollback).
6. **Runbook**: enabling (profile edit + recreate in a window), release
   selection and rollback via the links, the publication-rule note, and the
   Apple client base URL `http://<NAS tailnet name>:8787/`.

## What stays out

No second provider tool set; no credentials in images, flakes or tracked
files; no database; no change to the Apple runtime's startup path; no
automatic Tailscale or NAS service change by DXE.

## Build plan

Branch `feat/usage-service-host` from `main`, Sonnet subagent, one increment
per commit, red first: (1) fields + second publication (adopt the reference
commits' field work, replace their loopback flag); (2) guest service mode
with a fake `s6-svscan` in Section 3's fakes; (3) launcher + watchdog with
fakes; (4) host lifecycle commands; (5) docs and runbook. Gates: unit tier,
bash 3.2, kcov, pinned ShellCheck, `nix flake check` (the flake gains `s6`
and the scripts). Live: Apple tier on `dx-test` for the service-off
regression; the service-on proof on a disposable docker-ssh spike once the
real package exists (2B). Production enablement per 3A.
