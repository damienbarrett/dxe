# D2 — How is configuration represented and which source wins?

Implemented by [Phase 1b](../checklists/phase-1b.md).

## Resolution: root `.env` and named profiles are data

Neither is sourced. Both use one allowlisted parser and canonical field registry.
The accepted line grammar is deliberately small. This is the plan's explicit,
safety-driven exception to preserving current `.env`/profile evaluation and
precedence; it therefore ships with fail-closed migration diagnostics rather than
masquerading as a behavior-preserving move.

- blank lines and full-line `#` comments;
- an optional literal `export ` prefix for migration of checked-in profiles;
- exactly one `NAME=value` assignment per line, with no duplicate or unknown
  names;
- the right-hand side is data, not shell: there is no command, parameter, quote,
  backslash, or tilde evaluation;
- the sole expansion is an exact `${DX_PROJECT_ROOT}` placeholder in fields
  whose schema permits a host path.

A migration checker rejects shell constructs whose meaning would change —
including command substitution, general `$VAR` expansion, control operators,
line continuations, and shell quoting — with a file and line diagnostic. Update
the three checked-in profiles ([`tests/profiles/`](../../../tests/profiles)) to the
data grammar in the same phase. A gitignored file being absent in this checkout is
not evidence that other machines have nothing to migrate, so the release notes
include before/after examples and a fail-closed check rather than silently
reinterpreting legacy shell.

## Precedence

Highest first:

1. command flags and a command's already-resolved immutable plan;
2. inherited environment, including values exported by `dx-profile`, where the
   command's field policy permits an environment override;
3. command-specific derived values (notably private `dx-mount` resources);
4. root `.env`;
5. built-in defaults.

The resolver records each value's origin. `dx-mount` uses that origin to keep
its isolation contract: an inherited/profile override is explicit, while root
`.env` cannot replace a private derived container, volume, key, port, memory, or
CPU value. Existing command-specific restrictions still apply — for example,
`dx-mount` container naming remains `--container` or derived, not an inherited
`DX_CONTAINER_NAME` shortcut.

## The resolved snapshot

After resolution, the parent exports every registry field and origin as one
complete snapshot, plus `DXE_CONFIG_SNAPSHOT_VERSION=1` and
`DXE_CONFIG_RESOLVED=1`. The boolean marker is never trusted by itself: a child
validates the version, project root, presence, and type of the entire snapshot
before it skips `.env`; a partial, stale, wrong-root, or unknown-version snapshot
fails closed with a diagnostic. Neither internal marker is accepted from either
data file's allowlist.

Every umbrella entrypoint initializes once before printing a plan or launching its
first child, including `dx`, `dx-destroy`, `dx-recreate`, `dx-factory-reset`, and
`dx-mount`. Directly invoked commands still initialize configuration normally.
Tests cover both paths and prove every orchestration chain preserves one exact
snapshot.
