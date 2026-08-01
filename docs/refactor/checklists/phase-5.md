# Phase 5 — Finish optional AI updater decomposition

**Goal:** reduce `dx-ai` implementation coupling after [Phase 4](phase-4.md) has
already made its data and mutation boundaries safe.
**Owns:** seam 4 (optional remainder).
**Optional.** Nothing depends on it.

## Items

- [x] **1. Refactor `dx-ai` into a sourceable main** plus focused functions for pin
  refresh, flake update, profile install/upgrade, credential persistence,
  statusline seeding, and verification.

- [x] **2. Keep the Phase 4 AI-generation protocol behind focused functions** for
  stage, validate, publish-pointer, retain-predecessor, collect, and recover; do
  not reintroduce writes to `/guest-bootstrap/current` or a mutable live `flake/`
  directory.

  If [D5-hardening](../decisions/D5-bootstrap-state.md#d5-hardening-deferrable) was
  deferred, the retain-predecessor and collect functions are stubs with the same
  signatures — do not invent a second, parallel mechanism here.

- [x] **3. Reuse only the Home Manager-installed Phase 4 keyring library**; fail
  clearly if packaging is broken rather than falling back to a copied
  implementation.

- [x] **4. Test** malformed upstream manifests, failed downloads, unchanged pins,
  atomic generation/pointer failure, bootstrap-current changes, first install,
  upgrade, recovery through the retained predecessor generation, and pre-existing
  user configuration.

## Exit gate

- Reformatting or extracting the Nix derivation cannot break pin refresh.
- A failed refresh leaves the published bootstrap, AI `current`, and its
  predecessor valid; a successful refresh publishes one new persistent
  generation and atomically advances only the AI `current` pointer.
- Existing Claude, Codex, Gemini, GitHub, and keyring data remains untouched
  except for the documented additive setup.
