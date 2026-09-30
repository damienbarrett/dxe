# Validation matrix

Part of the completed refactor; its summary document, `refactor-plan.md`, is closed and removed (see Git history).

Run the smallest applicable tier on every Red-Green-Refactor cycle and all
tiers before completion.

| Tier | Runs on | Purpose | Required checks |
| --- | --- | --- | --- |
| Syntax/lint | CI + local | Fast shell feedback | `bash -n` for all shell entrypoints and libraries; mandatory ShellCheck |
| Unit/static | CI + local | Pure parsing, planning, schema, and Nix structure | No Apple Container binary in `PATH`; config snapshots, manifest audit/migration, tunnel, lease, AI-generation, and bootstrap module tests; Nix **evaluation** only |
| Host contract | CI + local | Failure and state-machine behavior | Fake `container`, `ssh`, `scp`, `ps`, `kill`, `tar`, and filesystem fixtures; exact process identity, command-boundary transport, orchestration snapshots, and concurrent state transitions |
| Bash 3.2 compatibility | CI (`macos-*` runner) + local mac | Enforce the supported host interpreter | `/bin/bash` host syntax, config, manifest, tunnel, and host-contract suites; no guest modules or live runtime; asserts `/bin/bash --version` is 3.2.x first |
| Shell coverage | CI + local Linux runner | Enforce [D1](decisions/D1-coverage.md) | Pinned `kcov` environment; 100% over declared sourceable scope; ratcheted `scope_exec_lines` floor and `unscoped_prod_exec_lines` ceiling; reviewed exclusions |
| Nix build | mac only | Guest closure actually builds | `nix build` of the aarch64-linux outputs; not reproducible on a hosted x86_64 runner |
| Live isolated | mac only | End-to-end runtime behavior | `./bin/dx-profile dx-test tests/run_all_tests.sh` against non-default resources |
| Destructive isolated | mac only | Factory reset and cleanup | Explicit opt-in; assert resource names are not any default before execution |
| Runtime compatibility | mac only | Supported Apple Container surface | Documented Apple Container versions; legacy manifest/tunnel/bootstrap state; restart-safe leases and migration audits |

**The hermetic-vs-live split, stated once (Muse E4):** the `Runs on` column
above is the sole statement of it; nothing else in this document restates
which tiers are which, only points back here. It is also the operative part
of [D3](decisions/D3-ci.md). Syntax/lint, Unit/static, Host contract, Bash
3.2 compatibility and Shell coverage are the contract CI enforces on every
push -- hermetic, no real guest or Apple Container involved. Nix build, Live
isolated, Destructive isolated and Runtime compatibility are `mac only`: each
is the developer's pre-promotion responsibility on a real macOS host,
because Apple Container needs virtualization a hosted runner does not have.

Nix *evaluation* is not similarly constrained to one architecture: `flake.nix`
evaluates both `aarch64-linux` (Apple's guest) and `x86_64-linux` (the QNAP's)
via its `supportedSystems`, and CI's Unit/static tier proves both with
`nix flake check --no-build --all-systems` against the flake's `checks`
output (`home-activation`, `ai-tools`, `alias-is-identity`, per system) --
not just the bare "checking flake output" that `nix flake check` does for
`homeConfigurations` on its own, which walks the attribute without evaluating
it.

`prepare_nix_volume_impl`'s `mkfs.btrfs`/`mkfs.ext4`, `truncate` and `mount`
calls (constitution rule 3: a privilege-boundary stub must be validated
against the real boundary at least once) are function-shadowed in the
Unit/static tier's `test_section3_bootstrap.sh` fixtures, since they need
`CAP_SYS_ADMIN` this tier's runner does not have; the real commands are only
exercised on the Live isolated tier, via an actual guest boot.

**WP6.4 / Astra F3 (the DQ6 owned-resource check) -- live-only assertion,
not yet confirmed.** `dx_runtime_docker_resource_owned`'s absent-vs-
could-not-inspect distinction (`bin/lib/dx-runtime-docker-identity.sh`'s
`dx_runtime_docker_inspect_labels`) depends on Docker's own stderr wording:
`*"No such $noun"*` (`"No such container: NAME"` / `"No such volume:
NAME"`) means genuinely absent; anything else means "could not tell."
Every assertion of this in `tests/test_docker_runtime_adapter.sh` (the
absent/could-not-be-read/connection-style cases, and the schema-999/
incompatible-`io.dxe.system` collision cases) drives a FAKE `docker`
that is scripted to print exactly that text -- none of it has been run
against a real Docker Engine's actual CLI output. This is consistent with
D8's own spike scope (the QNAP NAS is production infrastructure, off-limits
to any later test, per `qnap-dxe-plan.md` Phase 0), so it is not a gap this
WP can close itself; it is recorded here as the stub-only assertion the
Runtime compatibility tier (or a future live gate against a real, non-
production Docker host) should confirm before this specific string match
is trusted operationally. The failure mode if Docker's real wording ever
differs is fail-closed, not fail-open: an unrecognized stderr text falls
to "could not be read" (refuses), never silently to "absent" (which would
adopt/create over it) -- so a wording drift would show up as an operator-
visible refusal, not a silent DQ6 bypass.

## Useful final commands

```sh
# CI-equivalent tiers (hermetic; see the table above), runnable anywhere
# including a container-free machine
tests/run_all_tests.sh --skip-integration
tests/run-bash32-tests.sh
tests/run-coverage-linux.sh
shellcheck --severity=warning bin/dx* bin/lib/*.sh tests/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/*.sh
nix flake check --no-build --no-write-lock-file --all-systems \
  container/aarch64-darwin-apple-container-dx-nixos-26.05

# After committing a release candidate, before promotion
tests/release-check.sh

# mac-only tiers (see the table above), before promotion
nix build --no-write-lock-file \
  ./container/aarch64-darwin-apple-container-dx-nixos-26.05#<output>
./bin/dx-profile dx-test tests/run_all_tests.sh
```

Two mechanical notes for the runner: adjust glob handling so an absent optional
directory does not become a literal ShellCheck argument, and prefer
`nix flake check --no-build` in CI so evaluation errors are caught without
attempting a cross-architecture build that will fail for the wrong reason.

## Running lint and Nix evaluation without a host toolchain

`shellcheck` and `nix` are often absent from the macOS host, which is what
`Brewfile` exists to fix. When installing them is not desirable, the running DX
guest already provides both — and because it is `aarch64-linux`, it can evaluate
the flake the host cannot:

```sh
./bin/dx-put <staged-source-dir> /persist/inbox/
./bin/dx-ssh 'cd /persist/inbox/<dir> && nix shell nixpkgs/nixos-25.05#shellcheck \
  --command bash -c "find bin tests container -type f \
  \( -name \"*.sh\" -o -path \"bin/dx*\" \) -print0 \
  | xargs -0 shellcheck --severity=warning"'
./bin/dx-ssh 'cd /persist/inbox/<dir> && nix flake check --no-build \
  --no-write-lock-file --all-systems ./container/aarch64-darwin-apple-container-dx-nixos-26.05'
```

Stage the source rather than copying the working tree: the repository root holds
SSH private keys that have no reason to enter a guest.

**Pin ShellCheck.** Version 0.11.0 aborts with `Non-exhaustive patterns in
checkCmd` on `x="$(source f)"` — the construct the import-purity contract
depends on in both
[`tests/test_refactor_contracts.sh`](../../tests/test_refactor_contracts.sh)
and
[`tests/test_section9_host_scripts.sh`](../../tests/test_section9_host_scripts.sh).
0.10.0 is clean across the whole repository. CI pins the version for that
reason; re-test the pin before bumping it, and again when nixos-26.05 (the
guest's own pin) becomes the CI pin.
