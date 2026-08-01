# D3 — Where does CI actually run?

Implemented by [Phase 0](../checklists/phase-0.md) (minimal job) and
[Phase 1a](../checklists/phase-1a.md) (full matrix).

The repository has a GitHub remote, so hosted CI is available. It cannot run
the live tiers: Apple Container needs a real macOS host with virtualization,
which hosted runners do not provide. Nix is also constrained —
`flake.nix` pins `system = "aarch64-linux"` and places every package under it,
so an x86_64 Linux runner can *evaluate* the flake but cannot build the NixOS
closure without emulation.

## Resolution

The primary CI job is hosted Linux and contains syntax, lint, unit/static,
host-contract, coverage, and Nix **evaluation only** (`nix eval` /
`nix flake check --no-build`). A second, non-live compatibility job runs the
host libraries and host-contract suites with Bash 3.2; guest bootstrap modules
continue to target the guest's pinned Linux Bash. The compatibility job does
not need Apple Container virtualization. Nix builds and every live or
destructive tier stay on the developer's mac, run from a documented
pre-promotion script. CI makes the container-free and supported-host-shell gates
unskippable without pretending to reproduce the runtime.

## Where Bash 3.2 comes from

Hosted Linux runners ship Bash 5.x, and 3.2 is not installable from apt; building
it from source in CI is slow and fragile. The compatibility job therefore runs on
a hosted **`macos-*`** runner, whose `/bin/bash` is 3.2.57. That runner needs no
virtualization and starts no Apple Container, so it satisfies this decision's own
constraint that the compatibility job stay non-live.

The job asserts its interpreter before running anything:

```sh
/bin/bash --version | head -1   # must report 3.2.x
```

This mirrors what [Phase 1a](../checklists/phase-1a.md) already requires of the
local `tests/run-bash32-tests.sh` wrapper — neither may silently fall through to a
newer Bash.

## Start small

A minimal job — `bash -n` over every shell file plus ShellCheck — depends on
nothing else in this plan and there is no `.github/` today. It lands in
[Phase 0](../checklists/phase-0.md) so the characterization tests written there
have somewhere to run as they are written. The full matrix above lands in Phase 1a.
