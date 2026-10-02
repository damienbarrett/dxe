# docker-ssh lifecycle lock for a never-created profile (`fix/docker-lock-image`) — evidence

Found live on 2026-10-02 inside the user's QNAP maintenance window: the first
`dx` of a disposable, never-created docker-ssh profile refused at the
lifecycle lock with "could not acquire the remote lock … (it may already be
held)" although nothing held it. The lock is a never-started container, and
it was created from `$DX_IMAGE` — the profile's own local-only tag, which
does not exist on the remote daemon before that profile's first
`dx-create-image` and cannot be pulled. Since `dx` acquires the lock before
`dx-create-image` (WP6.5), every new docker-ssh profile hit it; existing
guests (whose images exist) did not. Nothing was created on the NAS; the
inventory stayed at the canary alone.

## Change (one increment, red before green)

`dx_runtime_docker_lock_acquire` now creates the lock from the Containerfile's
pinned base image reference, through the same helper `dx-create-image`
already uses to pull it; an unreadable reference or an unset
`DX_CONTEXT_DIR` is a configuration error made before any remote call.
Labels, owner token, `dx-lock status`/`unlock` and messages are unchanged.

Red (unchanged code, `tests/test_docker_adapter_lock.sh`): the lock used
`$DX_IMAGE`; acquire failed for a profile whose image is absent while the
fake accepts only the base reference; no configuration error for an
unreadable reference; and the end-to-end case — `dx_connect_or_bring_up`
with the real lock functions, a fake daemon and stub children for a
never-created profile — failed at the lock. Green: 29/29; lock-create then
`dx-create-keys` → … → `dx-start-container`, lock-release, `dx-ssh` in order.

## Gates

| Gate | Result |
| --- | --- |
| affected suites (Docker adapter lock/runtime/lifecycle/health, Sections 9, 10, 27, entrypoint decisions, qx) | green |
| bash 3.2 | all passed |
| fresh clone in Ubuntu 24.04, no state directory | suite exit 0 (its lint section self-skips when the apt ShellCheck is not the pinned version; lint covered below) |
| pinned ShellCheck 0.10.0, CI file set, clean export | clean |
| kcov coverage | 100%; scope 4,194 ≥ floor 3,935; unscoped 2,629 ≤ ceiling 2,635 (ratchet untouched) |
| `nix flake check` (default and `--all-systems`) | passed; `flake.lock` unchanged |
| Apple live tier on `dx-test` (regression; Apple's lock is a local directory) | ready after 14 s; `dx` reconnect without publication; live tier: 45 suites, 2576 passed, 0 failed, 94 skipped; cold stop clean |

The docker-ssh proof — creating a disposable `dx-qnap-spike3` from a clean
daemon, restarting it to confirm the execution-lease fix across a Docker
restart, then factory-resetting it — runs inside the user's QNAP window right
after this lands, and is recorded in
`docs/evidence/20260928/qnap-promotion.md`.
