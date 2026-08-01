# Phase 2 — Consolidate SSH tunnel management

**Goal:** have one implementation of control-socket lifecycle behavior.
**Owns:** seam 2.
**Independent of** [Phase 3](phase-3.md) — either order, or one without the other.

Begin with the [Phase 0](phase-0.md) red tests for metadata-publication failure, a
stop failure that leaves the master alive, and concurrent start/start, start/stop,
and stop-all transitions; keep those tests isolated from unrelated section
assertions and make them green before consolidating fixtures.

## Items

- [ ] **1. Extract into `bin/lib/dx-tunnel.sh`:**
  - port validation primitives;
  - state-directory and socket naming;
  - allowlisted metadata read/write;
  - control-master check and exit;
  - discovery/deduplication;
  - active/stale/orphan classification;
  - one-stop and stop-all semantics;
  - prerequisite checks and shared SSH invocation assembly.

- [ ] **2. Model direction with a closed `case`** (`forward` or `reverse`), not
  `eval` or dynamically named functions. Keep in the wrappers:
  - usage/examples;
  - mapping orientation;
  - which endpoint must be unprivileged;
  - local-port collision diagnostics;
  - `-L` versus `-R`;
  - direction-specific user messages.

- [ ] **3. Use a bounded per-tunnel-key lock** around the complete state transition:
  inspect/check → start master → publish metadata, or inspect/check → stop
  master → remove metadata/socket. Lock ownership uses PID plus stable process
  start identity, not age or PID alone. A start and stop for the same key cannot
  interleave, and stop-all takes each discovered key lock before acting.

- [ ] **4. Publish metadata atomically** (temporary file → fsync where practical →
  rename) while holding the key lock, and install a cleanup trap for "master
  started, metadata failed."

- [ ] **5. Use a private, mode-0700 state directory** and bounded/hash-based socket
  names so long `TMPDIR` or container names cannot exceed Unix socket limits.

- [ ] **6. Read legacy state during migration.** Discover old
  `TMPDIR/dx-forward-*.sock` and `dx-reverse-*.sock` state as read-compatible
  legacy state. Write only the new format after the migration lands. Register the
  [legacy-state removal gate](../migration-gates.md#legacy-tunnel-state) at the same
  time as the reader itself, and implement the profile-aware
  `dx-status --tunnel-state` sweep that gate uses.

  Per [risk controls](../risk-controls.md#reader-before-writer), the reader lands
  in a **strictly earlier commit** than the new-format writer.

- [ ] **7. Remove the `DX_FORWARD_TEST_MODE`/`DX_REVERSE_TEST_MODE` production
  branches** ([`bin/dx-forward`](../../../bin/dx-forward#L397),
  [`bin/dx-reverse`](../../../bin/dx-reverse#L382)) in favor of direct tests of
  sourceable parsing functions. Their eight call sites in
  [`test_section9_host_scripts.sh`](../../../tests/test_section9_host_scripts.sh#L335-L707)
  convert with them.

- [ ] **8. Split the duplicated tunnel fixtures** into one contract matrix run for
  both directions, plus small direction-specific tests. These are not two separate
  files: the fixtures are two parallel blocks inside the 1,719-line
  [`test_section9_host_scripts.sh`](../../../tests/test_section9_host_scripts.sh),
  alongside the 209-line
  [`test_section19_reverse_forward.sh`](../../../tests/test_section19_reverse_forward.sh).
  Carving the tunnel material out of section 9 is a prerequisite, not a side effect.

## Exit gate

- `dx-forward` and `dx-reverse` retain their public CLI and live round trips.
- One common implementation owns list/stop/stale/orphan/partial-failure logic.
- Per-key locks make concurrent start/start, start/stop, and stop-all outcomes
  linearizable; metadata always describes the master that remains active.
- Legacy state can be listed and stopped.
- A failed start cannot leave an untracked SSH master.
- The [legacy-state removal gate](../migration-gates.md#legacy-tunnel-state) is
  written down, with its check command, even though it will not yet be satisfied.
- Re-measure the duplication figure (baseline 242 identical lines) and confirm the
  shared engine absorbed them.
