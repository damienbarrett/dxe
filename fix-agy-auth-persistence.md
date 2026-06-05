# Fix agy Auth Persistence

## Problem

`codex`, `gemini`, and `claude` keep their authentication after `dx-recreate`, but `agy` requires authentication again.

`dx-recreate` intentionally preserves `/nix` and `/persist`; it destroys and recreates the container and image only. So auth survives only when the tool stores credentials under a path that bootstrap re-links into the fresh `/home/dx`, or under another persistent mounted path.

## Investigation

Source paths checked:

- `bin/dx-recreate` delegates to `dx-destroy` and then `dx`, preserving volumes.
- `container/aarch64-darwin-apple-container-dx-nixos-25.11/bootstrap.sh`
- `container/aarch64-darwin-apple-container-dx-nixos-25.11/scripts/dx-ai.sh`
- `container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix`
- `container/aarch64-darwin-apple-container-dx-nixos-25.11/home/shell.nix`
- `tests/test_section16_persist_storage.sh`
- `tests/test_section17_dx_ai_runtime.sh`

Live guest checks via `./bin/dx-ssh` showed:

- `codex`, `gemini`, `claude`, and `agy` are installed in `/home/dx/.nix-profile/bin`.
- `~/.gemini`, `~/.claude`, `~/.claude.json`, and `~/.codex` are symlinks into `/persist/home/dx`.
- `~/.local/share/keyrings` is also a symlink into `/persist/home/dx/.local/share/keyrings`.
- D-Bus and `gnome-keyring-daemon` are running, and `~/.dx-keyring-env` points shells at the current D-Bus session.
- `agy --version` reports `1.0.0`.
- `agy changelog` reports that `1.0.1` fixed "OAuth token persistence and authentication hangs".
- The current upstream Linux arm64 manifest reports `1.0.5`:
  - URL: `https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.5-5009297080451072/linux-arm/cli_linux_arm64.tar.gz`
  - SHA-512 hex: `8f92ed6e26166ddab595b3975e47e91fdd1c0bf73b393be25287631ccae0702a6372ebea25e8fbd4997abf6d9bb9d23368868a5bfa0c7a27cbd2110981c50198`
  - Nix SRI hash: `sha512-j5LtbiYWbdq1lbOXXkfpH90cC/c7OTviUodjHMrgcCpjcuvqJej71Jl6v22budIzaIaKW/oMeifL0hEJgcUBmA==`

Observed `agy` state in the live guest:

- The persisted `~/.gemini` tree contains `antigravity-cli/`.
- The OAuth token file is at `/persist/home/dx/.gemini/antigravity-cli/antigravity-oauth-token`.
- Related `agy` settings, history, logs, conversations, and cache are also under `/persist/home/dx/.gemini/antigravity-cli/`.
- No actual keyring data files were present under `/persist/home/dx/.local/share/keyrings` in this guest, so the current `agy` token path appears to be the Gemini-backed file tree, not the gnome-keyring data directory.

## Likely Root Cause

The persistence wiring for the relevant on-disk `agy` auth path is already mostly correct because `~/.gemini` is linked to `/persist/home/dx/.gemini`.

The stronger failure signal is the pinned `agy` version. The flake pins `agy` to `1.0.0`, and `agy`'s own changelog says `1.0.1` fixed OAuth token persistence and authentication hangs. That directly matches the reported symptom.

Unlike `codex`, `gemini`, and `claude`, `agy` is not coming from the `nixpkgs-unstable` input. Those three tools get newer versions when `dx-ai` runs `nix flake update nixpkgs-unstable`; `agy` is a local fixed-output derivation, so it needs its own manifest refresh path.

The D-Bus/keyring setup may be harmless or still useful for older/fallback credential paths, but it does not appear to be where the live `agy` OAuth token is stored. Treating keyring persistence as the primary fix is probably the wrong target.

## Fix Plan

1. Bump the checked-in `agy` derivation in `container/aarch64-darwin-apple-container-dx-nixos-25.11/flake.nix` from `1.0.0` to `1.0.5`.
   - Set `version = "1.0.5"`.
   - Set `src.url` to the current Linux arm64 manifest URL above.
   - Set `src.hash` to the SRI hash above.

2. Make `dx-ai` refresh the `agy` pin from Google's Antigravity CLI manifest before installing/upgrading `ai-tools`.
   - This gives `agy` the same practical freshness behavior that `codex`, `gemini`, and `claude` get through `nixpkgs-unstable`.
   - If manifest fetch or hash conversion fails, keep the checked-in pin as a reproducible fallback.

3. Keep the existing `~/.gemini -> /persist/home/dx/.gemini` persistence link.
   - This is the path that contains `antigravity-cli/antigravity-oauth-token`.
   - Do not move or read token contents in tests.

4. Update docs/comments so they do not overstate that `agy` auth is Secret Service-only.
   - `flake.nix`, `bootstrap.sh`, and `dx-ai.sh` currently describe `agy` as using D-Bus Secret Service via `zalando/go-keyring`.
   - Revise comments to say the known persisted `agy` state is under `~/.gemini/antigravity-cli`, with D-Bus/keyring kept as supporting compatibility unless removed after validation.

5. Harden the keyring service setup while touching this area.
   - `dx-ai.sh` currently skips startup whenever `DBUS_SESSION_BUS_ADDRESS` is non-empty, even if it points at a dead socket.
   - Add a helper that validates the socket from `DBUS_SESSION_BUS_ADDRESS`; if missing, start a fresh D-Bus session and rewrite `~/.dx-keyring-env`.
   - Share or mirror that logic between `dx-ai.sh` and `bootstrap.sh` to avoid the two paths drifting.

6. Add tests.
   - Static test in `tests/test_section6_tools.sh`: assert the `agy` derivation is no longer pinned to `1.0.0`; ideally assert `version = "1.0.5"` and the expected manifest URL/hash.
   - Static test in `tests/test_section6_tools.sh`: assert `dx-ai` fetches the Antigravity CLI manifest and rewrites the local `agy` derivation pin.
   - Static test in `tests/test_section6_tools.sh` or `tests/test_section3_bootstrap.sh`: assert AI persistence creates or links `~/.gemini`, since `agy` auth now depends on the Gemini-backed tree too.
   - Runtime test in `tests/test_section17_dx_ai_runtime.sh`: after `dx-ai`, assert `agy --version` is at least `1.0.1`.
   - Runtime test in `tests/test_section17_dx_ai_runtime.sh`: assert `~/.gemini/antigravity-cli` resolves under `/persist/home/dx/.gemini/antigravity-cli` once the directory exists.
   - Optional destructive test in `tests/test_section16_persist_storage.sh`: write a non-secret marker under `~/.gemini/antigravity-cli/`, run the destroy/create/start sequence, and verify the marker survives. This validates the storage path without needing OAuth.

7. Validate manually.
   - `./bin/dx-sync-bootstrap`
   - `./bin/dx-ssh dx-ai`
   - `./bin/dx-ssh 'agy --version'` should report `1.0.5`.
   - Authenticate `agy` once.
   - Confirm token metadata only, not contents: `./bin/dx-ssh 'stat ~/.gemini/antigravity-cli/antigravity-oauth-token'`
   - Run `./bin/dx-recreate`.
   - Confirm `agy` starts without prompting for auth again.

## Notes

There are also persisted `/persist/home/dx/.antigravity` and `/persist/home/dx/.antigravitycli` directories in the live guest, but the current source does not recreate home symlinks for `~/.antigravity` or `~/.antigravitycli`. The live `agy` changelog says newer versions moved project discovery into `~/.gemini/antigravity-cli/cache/projects.json`, so those older-looking directories should not be treated as the primary auth fix unless a post-upgrade test proves `agy` still reads them.
