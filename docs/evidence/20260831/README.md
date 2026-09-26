# August 2026 bump-disposition evidence

This directory is the execution record and gate logs for landing the
2026-08-31 stable-lock refresh and Nix image-pin alignment waiver. It applies
to the commit `RECORD.md` names as the tip all gates ran against —
**`27cce6f`** — not to the current tip of `main`. Read it as a dated snapshot,
not as a statement about today's code.

- [`RECORD.md`](RECORD.md) — the bump-disposition execution record. It is
  explicitly a **backfilled record**: the fields it holds were filled in
  after the window closed, not before, as the plan required. It says so
  itself under "Deviations from the plan, recorded honestly," including that
  the land-or-park decision followed the gate runs rather than preceding
  them, and that evidence was first collected in a session scratchpad before
  being copied to a declared destination. Those caveats are preserved as
  written; nothing here should be read as retroactively curing them.
- [`logs/`](logs) — the ten gate logs `RECORD.md` cites (coverage, Bash 3.2,
  host contracts, Nix build/flake-check, factory-reset and recreate runs, the
  destructive-tier run, and both fresh/reused-volume canary gates).

The Nix image-pin alignment waiver this record's gates validated is tracked
in `docs/release-maintenance.md`'s ["Waiver — newest-patch clause,
2026-08-31"](../../release-maintenance.md#waiver--newest-patch-clause-2026-08-31)
section, which links onward to the open store-trust design problem in
[`store-trust-plan.md`](../../../store-trust-plan.md) (Branch 12 of
`checkout-consolidation-plan.md`) that must close or re-scope the waiver.

## Redaction

`logs/destructive.log` originally contained a throwaway SSH test key's public
fingerprint and the local machine's `user@host` string, printed by `ssh-keygen`
while generating and then destroying a disposable `dx-test_key` keypair during
the destructive-tier run. No private key material was present, but the line
was redacted anyway (replaced with a bracketed note in place) since it named a
real local username and hostname. Nothing else in this directory matched a
scan for private keys, `BEGIN OPENSSH`/`BEGIN ... PRIVATE KEY` markers, token
prefixes (`ghp_`, `sk-`, etc.), passwords, `Authorization:` headers, or
tailnet keys.

Local home-directory paths were replaced with `~/` throughout the logs on 2026-09-26 because the repository is public.
