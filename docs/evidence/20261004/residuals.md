# Long-standing residuals closed (2026-10-04)

Branch `fix/residuals-20261004`, user instruction "Fix the long-standing small residuals", each change
red first:

1. The dx-ai hook's compatibility check is real: after a dx-ai update in a service-mode guest it runs the
   installed release's `agent-stats-<implementation> --help` (offline, exit 0) with the new generation
   first on PATH and checks that `claude`, `codex` and `agy` resolve there; failures are warnings,
   never a rollback. (The package has no `--version`.)
2. The Mac's default SSH key pair moved out of the checkout: `DX_SSH_KEY`/`DX_SSH_KEY_PUB` default to
   `~/.ssh/dxe/dx_key[.pub]`, profiles may use a `${HOME}` placeholder in path fields (symmetric with
   `${DX_PROJECT_ROOT}`), and `tests/profiles/dx-test.env` uses it. A checkout that still holds the
   legacy pair keeps working: the configuration falls back to it and prints one note with the `mv`
   commands.
3. The guest-tree compatibility symlink (WP9.4) and its deprecation warning are removed; a Section 10
   contract keeps the old directory name out of every tracked file except `docs/evidence` and
   `docs/reviews`.

Gates: unit tier (also a fresh Ubuntu clone and a simulated legacy-key checkout), bash 3.2, ShellCheck
0.10.0, kcov 100% of the scope (unscoped ceiling lowered 2641 -> 2638), `nix flake check`, pre-push scan.
Apple tier on `dx-test` with the keys in `~/.ssh/dxe`: live tier: 48 suites, 2977 passed, 0 failed, 84 skipped. docker-ssh tier on a disposable
spike: live tier: 48 suites, 2946 passed, 1 failed, 89 skipped (SPIKE10 LIVE TIER PASSED except the class D dx-ai case (explained)).
