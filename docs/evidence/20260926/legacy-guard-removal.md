# Old-base guard removal (Branch 8, `refactor/legacy-migration-cleanup`) — inventory

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 8: the
inventory that satisfies the
[old-base guard gate](../../refactor/migration-gates.md#old-base-guards) in
`docs/refactor/migration-gates.md`, so [Phase 6 item
1](../../refactor/checklists/phase-6.md#items) (remove the old-base guards)
can proceed. No home-directory paths, keys, fingerprints, or NAS identifiers
appear below.

Gathered read-only on 2026-09-26. `dx-host` was not probed directly for this
branch (out of scope for a subagent per the standing brief); its guard
result below was captured earlier the same day by the coordinating session
and is recorded here, not re-derived. `container image list` and `container
volume list` were run read-only; nothing was created, started, stopped, or
removed while gathering this inventory.

## Containers

| Name | Image | State | Notes |
| --- | --- | --- | --- |
| `dx-host` | `dx-nixos-26.05:latest` | running | The primary guest. Already changed over on 2026-07-05 (see `docs/release-maintenance.md`, "Base Image Changeover", History). |
| `dx-test` | `dx-test-nixos:latest` | (transient; being recreated by a concurrent task from the current Containerfile) | Isolated lifecycle-test profile. |

No `dx-tinty` container exists. No container exists behind the leftover
`dx-mount-dx-mount-legacy-plain-…_key`(`.pub`) files — only the key files
themselves remain on disk; their removal is a user decision, not this
branch's.

## `dx-host` guard probe

The guard's own signature check, run against the running primary guest:

```
[ -e /bin/bash ] || [ -L /bin/bash ]
```

Result: **`OLD_BASE_ABSENT`** — `/bin/bash` is not present, so the primary
does not match the retired flakes-base signature.

## Image provenance

Both `dx-nixos-26.05:latest` and `dx-test-nixos:latest` are built from the
same single-line `Containerfile`:

```
FROM nixos/nix:2.34.7@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
```

— the official, digest-pinned base, not the retired community
`nixpkgs/nix-flakes` image. Both are therefore on the new base **by
construction**, independent of any live guard probe.

The old base image, `nixpkgs/nix-flakes:nixos-25.11-aarch64-linux`, is still
present in the local image cache (`container image list`), but `container
list --all` shows no container referencing it. Deleting the cached image is
a user decision, not this branch's.

## Named profiles

`tests/profiles/*.env`, each checked read-only against `container list
--all`:

| Profile | Container name | Container exists? | Old-base status |
| --- | --- | --- | --- |
| `default.env` | `dx-host` (documentation-only profile; unsets everything, falls back to `bin/dx-lib.sh` defaults) | yes (it *is* the primary) | Off old base — see `dx-host` guard probe above. |
| `dx-test.env` | `dx-test` | yes (transient; see Containers above) | Off old base by construction — built from the current single-line Containerfile. |
| `dx-tinty.env` | `dx-tinty` | no | Vacuously off old base — no guest runs under this name to be on any base. |

## Conclusion

Every guest this repository can name — the default/primary, `dx-test`, and
`dx-tinty` — is confirmed off the old base: the primary by live guard probe,
`dx-test` and any future guest by Containerfile construction, and `dx-tinty`
because no such guest currently exists. This satisfies the
[old-base guard gate](../../refactor/migration-gates.md#old-base-guards):
the default guest, side containers, and named profiles have all moved off
the old base. The remaining old-base image file and the leftover mount-key
files are inert (no container references either) and their disposal is a
separate, user-owned decision.
