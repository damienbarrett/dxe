# Phase 0.5 — Standalone safety fixes

**Goal:** land the three safety fixes that need no restructuring, in place.
**Owns:** no seam — it is a fast path out of the findings table.
**Decisions:** [D6](../decisions/D6-command-boundaries.md),
[D4-core](../decisions/D4-mount-manifest.md#d4-core-mandatory) (partial).

Three P1 findings are each under ~20 lines of change but currently sit behind an
entire library extraction (former Phase 1 items 5 and 7) or an entire codec and
locking design (Phase 3). There is no dependency justifying that wait. Each item
here is one commit with its red test first, independently revertible, and blocks
nothing.

**No production file moves in this phase.** These are in-place fixes to
`bin/dx-lib.sh` and `bin/dx-mount`; the moves happen later and must preserve
these behaviors — Phase 1b does not get to reinstate an unsafe implementation
because the move is mechanical.

## Items

- [x] **1. Exact runtime-process identity.** Replace the substring match in
  `container_runtime_pids` ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L272-L279)) —
  currently `index($0, "--uuid " name)` — with an exact `--uuid` argument/value
  pair match. A fallback stop for `dx-host` must not select `dx-host-other`, which
  `--container` accepts because `dx_require_non_reserved_container_name` rejects
  only the exact string `dx-host`. Capture a stable process-start identity and
  revalidate it immediately before each TERM and KILL so PID reuse cannot redirect
  a signal.

  Replace the implementation-string assertion at
  [`tests/test_section9_host_scripts.sh`](../../../tests/test_section9_host_scripts.sh#L1526-L1541)
  with behavioral fixtures covering exact, prefix-colliding (`dx-host` vs
  `dx-host-other`), missing, and malformed `ps` output.

- [x] **2. Private timeout bookkeeping.** `run_with_timeout`
  ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L218-L255)) writes its marker to
  `${TMPDIR:-/tmp}/dx-timeout.$$.<pid>`, a predictable path any other process can
  create or delete to force or mask exit 124. Move bookkeeping into a private
  `mktemp -d` directory and clean it on every signal and exit path. Refuse to
  signal a PID whose recorded start identity no longer matches.

- [x] **3. Stop sourcing the mount identity file.** Replace
  `source "$identity_file"` ([`bin/dx-mount`](../../../bin/dx-mount#L217-L228)) with
  a non-evaluating reader for the versionless and version-1 formats, per
  [D4-core](../decisions/D4-mount-manifest.md#legacy-decoders). Accept only the
  exact assignment names and the supported `printf %q` output; reject
  substitutions, expansions, redirects, extra tokens, and trailing commands.

  This closes the code-execution surface now. The v2 codec, the identity-directory
  mode and staging rules, the per-container lock, and the migration/audit commands
  all stay in [Phase 3](phase-3.md) — do not pull them forward.

## Exit gate

- A fallback stop proves exact container UUID identity and refuses
  prefix-colliding and reused-PID fixtures.
- No predictable timeout marker is left in shared temporary storage, on any exit
  path.
- `dx-mount` reads legacy identity files without `source`, `eval`, or a shell
  subprocess, and a hostile manifest fixture fails closed before any resource
  command runs.
- The three implementation-string assertions those fixes replace are gone, and no
  production file has moved.
