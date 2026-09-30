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

`populate_prepared_nix_volume`'s `/etc/fstab` append (P13 case (e) in
`test_section3_bootstrap.sh`) gained a Fable B11 seam: a trailing optional
`fstab` parameter, positional-with-production-default (`"${3:-/etc/fstab}"`),
the same shape as `setup_persist`'s `persist_root` and
`dx_persist_host_keys`'s `etc_ssh`/`store`. The Unit/static tier now proves
the presence check and the append (LABEL= and raw-device lines, plus
idempotency on a second run) entirely against a fixture file, and asserts
the real `/etc/fstab` is never opened at all; the previous version of this
case ran against the real file directly (root: append-and-restore on the
kcov Linux image; non-root: a permission-denied fail-closed assertion on
this dev Mac), which is gone. The real `/etc/fstab` append itself -- no
production caller passes the new third argument, so `bootstrap_phases`
still writes to the real file exactly as before -- is therefore live-tier
only now: confirmed by an actual guest boot on the Live isolated tier, the
same as the `prepare_nix_volume_impl` calls described just above.

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

**WP6.5 / Astra F4 (the lifecycle lock) -- live-only assertion, not yet
confirmed.** `dx_lifecycle_lock_acquire`/`_release` (`bin/lib/dx-container.sh`)
and every mutating entrypoint's own use of it are proven entirely through
fakes: a scripted `docker` standing in for the remote lock container
(`bin/lib/dx-runtime-docker-lock.sh`'s existing create-fails-if-present
protocol), and real local `bash -c`/backgrounded processes standing in for
a second controller against Apple's own local lock. None of this has run
two REAL controllers against the same live QNAP daemon, or two real
`dx`/`dx-recreate` invocations racing on the same Apple host. The atomic
primitive each side relies on (`docker create --name`'s own name-conflict
error; a plain `mkdir` for Apple) is a real OS/daemon guarantee, not
something this WP invented, so this is recorded as the same class of gap
WP6.4/Astra F3's own entry above describes -- a live gate should still
confirm it before relying on it operationally, particularly the "an
interrupted owner is reported, not silently stolen" claim, which depends on
the real daemon continuing to refuse a name conflict exactly the way the
fakes assume.

**WP5.2 / Fable A3+B3 (extends Astra R3) -- the shared guest publication-
lock protocol.** `bin/lib/dx-bootstrap-protocol.sh`'s
`dx_guest_publication_protocol_snippet` is now the one rendering of
`process_start`/`boot_id`/`publication_lock_acquire`/
`publication_lock_release` the launcher (`dx_bootstrap_launch_command`),
the sync's guest program (`dx_sync_guest_program`), the health probe
(`dx_bootstrap_health_command`), and the guest's own `dx-ai-lock.sh` all
share -- closing the launcher/sync drift Fable A3 found (a missing
`[ -z "$live_start" ]` clause) and dx-ai-lock.sh's own narrower gaps
(Fable B3: no grace period before reclaiming an ownerless lock directory,
and a GNU-only `mv -T` for its stale-owner takeover, both now the same
rename-then-remove-via-the-portable-form every copy uses).
`tests/test_refactor_contracts.sh` pins the launcher's and the sync's
rendered text as byte-identical, and pins the shipped
`container/.../scripts/lib/dx-publication.sh` as identical to the rendered
snippet; `tests/test_bootstrap_publication.sh` runs one fixture (a live
owner, an owner from a previous boot, a reused pid, an ownerless
directory, and a reclaim whose rename target already exists) against all
three implementations, asserting identical outcomes and stderr. All of
this is Unit/static-tier: real `/proc`-shaped fixtures under a fake root
(`DX_LOCK_PROC_ROOT`), never a real Linux `/proc`, since this suite runs on
the macOS host. It has not been re-confirmed against an actual guest
kernel's `/proc` (real boot ids, real pid reuse timing) -- the Live
isolated tier's ordinary guest boots exercise the launcher and health-probe
renderings for real on every promotion, which is the closest this gets
today; a dedicated concurrent-publish drill against a live guest would
still be the stronger confirmation Astra R3's own suggested sequence asks
for.

## Useful final commands

```sh
# CI-equivalent tiers (hermetic; see the table above), runnable anywhere
# including a container-free machine. tests/run_all_tests.sh, run-tier.sh,
# run-bash32-tests.sh and run-coverage-contracts.sh are one-line wrappers
# over tests/run.sh (Fable D2), which selects suites by their own
# `# tier:`/`# bash32:` header (tests/run.sh --tier unit is equivalent to
# the first line below).
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
