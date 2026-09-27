# Docker-over-SSH runtime adapter (Branch 11 / Phase 2, `feat/qnap-docker-adapter`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 2 and
`checkout-consolidation-plan.md`'s Branch 11. No home directory paths, keys,
fingerprints, or NAS identifiers appear below; the pre-approved placeholder
alias `qnap-dxe` stands in for the real host throughout the branch's tests
and example profile.

Branch `feat/qnap-docker-adapter`, from `main` `abd4d2d`, 12 commits (10
increment commits, one executable-bit fix, one coverage-gap-closing commit)
plus a ratchet re-measure, landing at `2ec3749` before this documentation
commit. Every increment was developed and characterised entirely against
fake `ssh`/`docker` boundaries (`tests/lib/fake-tools.sh`'s `fake_qnap_ssh_write`,
`tests/test_docker_runtime_adapter.sh`, Section 33); the real NAS is
production and was never touched by this branch — no `ssh`, `docker`, or
`dx-*` command in this branch's own work reached it.

## What changed

- `bin/lib/dx-runtime-docker.sh` (new, 809 lines): implements every
  `dx_runtime_<op>` for `DX_RUNTIME=docker-ssh`. `bin/lib/dx-runtime.sh`'s
  dispatch became one shared `dx_runtime_dispatch` helper computing
  `dx_runtime_apple_$op` / `dx_runtime_docker_$op` dynamically, rather than a
  hand-written one-liner per operation per adapter — still a plain function
  call with no subshell or pipe of its own, so the Phase 1 stdin/exit-status
  passthrough proof holds unchanged for both adapters.
- `dx_runtime_container_create` gained a genuinely runtime-neutral parameter
  vocabulary (`--name`, `--image`, `--volume {nix,persist,bootstrap,git}:...`,
  `--env`, `--memory`, `--cpus`, `--publish`, `--restart-policy`,
  `--entrypoint-cmd`/`--entrypoint-arg`) instead of Apple-flavoured flags,
  after the coordinating session rejected an earlier draft that translated
  Apple's flags inside the Docker adapter as making Apple's CLI syntax the
  de facto contract (DQ2 forbids this). `bin/dx-create-container` speaks only
  the neutral vocabulary; each adapter renders its own real argv.
  `dx_runtime_apple_container_create` reproduces today's exact `container
  create` argv byte-for-byte from the same vocabulary, proven in
  `tests/test_runtime_boundary_characterisation.sh`. `dx_runtime_run_ephemeral`
  was deliberately left as the Apple pass-through it already was; a neutral
  version is deferred to whichever of Phase 3/6 first needs it.
- DQ6 labels (`io.dxe.managed`, `io.dxe.schema`, `io.dxe.profile`,
  `io.dxe.role`) attached at create time for volumes/containers/locks and
  verified before every delete; a same-named unlabelled or mismatched
  resource refuses as a collision, never an adoption candidate.
- `image_build` never issues a remote `docker build` (Phase 0 found the real
  NAS refuses one): it parses the Containerfile's single `FROM <ref>` line
  and does `docker pull` + `docker tag`, failing closed on anything beyond
  that one line.
- `system_start` always refuses for docker-ssh (operator uses the NAS's own
  App Center UI).
- A remote per-profile lock (a labelled, never-started container named
  `dxe-lock-<profile-id>` — container-name uniqueness is Docker's only atomic
  "create, fail if already present" primitive) backs a new `bin/dx-lock`
  entrypoint (`status`, `unlock --force`); `bin/dx-status` shows the same
  state read-only. Never removed on elapsed time alone.
- `bin/lib/dx-tunnel.sh` and `bin/lib/dx-backup.sh`'s local cache keys gain an
  extra identity segment (`dx_runtime_host_identity`'s
  `docker-ssh:<alias>:<daemon-id>`) for docker-ssh only, so two profiles
  sharing a container name can never collide; Apple's key shapes are
  byte-for-byte unchanged.
- Five distinct diagnostic classes (`dx_runtime_docker_classify_failure`):
  authentication failure, connection loss, daemon restart or unreachable,
  missing Docker access, generic-but-never-silent fallback — quoted
  alongside the raw remote text in every failure message.
- New config fields (`bin/lib/dx-config.sh`): `DX_REMOTE_HOST`,
  `DX_GUEST_SYSTEM`, `DX_NIX_STORAGE_MODE`, `DX_CONTAINER_RESTART_POLICY`,
  plus `dx_config_validate_cross_fields()` enforcing `DX_REMOTE_HOST`
  required iff `DX_RUNTIME=docker-ssh`. The Phase 1 placeholder value
  `docker` is retired in favour of the real `docker-ssh` value, with a
  distinct rejection message pointing at the new name.
- No entrypoint and no `bin/lib/dx-container.sh` wrapper name needed to
  change to add the second adapter, except `container_system_ensure_started`'s
  echo, which hardcoded "Apple container system is not running" and needed a
  runtime-conditional message (Apple's own wording kept byte-for-byte).

Full command-by-command mapping and design rationale:
`docs/refactor/docker-adapter-mapping.md`. Narrative summary:
`docs/refactor/runtime-boundary.md`'s "Phase 2" section.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 (`tests/run-bash32-tests.sh`, macOS `/bin/bash`) | 120 passed, 0 failed, 0 skipped |
| G1 pinned ShellCheck 0.10.0 (`nixos-25.05`, CI's exact file set: `find bin tests container -type f \( -name '*.sh' -o -path 'bin/dx*' \)`) | clean (exit 0, no findings) |
| G1 container-free contracts (`tests/run_all_tests.sh --skip-integration`) | all sections 0 failed; "All tests PASSED!" (Section 33 itself: 107 passed, 0 failed, 0 skipped) |
| G2 coverage (`tests/run-coverage-linux.sh`) | `covered=100% scope_share=21.61%`; ratchet raised `1997`→`2161` bp on a clean `git archive HEAD \| tar -x` export (no unearned slack) |
| G3 Nix | not applicable (no `.nix`/lock file changed) |
| G4 live | **not run from this branch** — the NAS is production and off-limits to the implementing session; the one live step (read-only `dx-status` against a disposable QNAP profile) is the coordinating session's own, separate step after this branch lands |
| G5 CI | not pushed (local commits only, per the task's constraints) |

Red/green: every increment (0-8) was proven red before green with its own
characterisation tests; the coverage/ratchet checkpoint additionally found
and fixed a real test-infrastructure bug (see below) and closed 21 lines of
kcov-visible gap with 10 new targeted tests before the ratchet was
re-measured.

## A caught infrastructure bug, not a design defect

`tests/test_docker_runtime_adapter.sh` lost its executable bit during an
Increment 6 file reconstruction (`cat head lock_block tail > file`, which
creates a new file rather than preserving the source's mode bits), and had
been tracked as mode `100644` since Increment 2. `tests/run_all_tests.sh`
invokes every test file as `bash "$file"` (no `+x` needed), so the fast
suite ran this file's tests correctly throughout Increments 2-8 regardless.
`tests/run-coverage-linux.sh`'s own `run-coverage-contracts.sh` execs test
files directly, which does need `+x` — so the coverage container silently
never ran this file's tests until the bit was restored (commit `c439828`),
meaning every kcov measurement before that commit under-counted this file's
contribution. Caught only because the full coverage checkpoint (deliberately
deferred per the standing brief's own guidance, to keep per-increment
validation fast) was finally run for the first time this session. No
production code was affected; the fix and its blast-radius explanation are
in `c439828`'s own commit message.

## Flagged for the coordinating session

- **`bin/dx-mount` does not refuse under `DX_RUNTIME=docker-ssh`.** DQ8's
  capability table (`dx_runtime_docker_capability`) correctly answers
  `bind_mounts: no`, but nothing in `bin/dx-mount` queries that capability
  before attempting a bind mount. `bin/dx-mount` is outside this branch's
  allowed-file list (`bin/lib/`, `bin/dx-status`, `tests/`,
  `tests/profiles/qnap-example.env`, `docs/`, the two plan files), so this
  pre-existing gap is made reachable rather than introduced or closed by
  Phase 2. See `docs/refactor/docker-adapter-mapping.md`'s "Flagged for
  review" item 4 for the proposed fix shape.
- The three items flagged in the Increment 0 mapping doc (`image_build`
  strategy, `system_start` refusal, lock audit/unlock placement) were all
  resolved by the coordinating session before the relevant increment and are
  recorded as resolved, with the actual decisions, in
  `docs/refactor/docker-adapter-mapping.md`'s "Flagged for review" section.

## What was not done from this branch

- No live command reached the NAS: no `ssh`, no `docker`, no `dx-*` entrypoint
  was ever run against `qnap-dxe`. The read-only `dx-status` gate against a
  disposable QNAP profile remains the coordinating session's own step.
- `run_ephemeral`'s neutral-parameter treatment (deferred to Phase 3/6, per
  the coordinating session's explicit instruction).
- The `bin/dx-mount` gap above.
