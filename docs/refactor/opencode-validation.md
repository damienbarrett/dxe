# OpenCode validation record

This is an execution record for the OpenCode optional-bundle change,
imported from the preserved local branch `preserve/dxe-agent-opencode`
(`ff8f6bd`) as historical evidence of the original (pre-revert) validation
run. It predates this repository's current coverage tooling and Branch 6's
re-landing; read it as a record of what was once observed, not as current
state.

**Historical note (units):** "branch points" below originally meant
scope-share **basis points** (parts per 10,000 of total counted shell
lines) as computed by `tests/run-coverage-linux.sh` and recorded in
`tests/coverage/ratchet.env` -- not a count of code branches. The
original text is corrected in place below to avoid that ambiguity; the
absolute counts (2,177 / 2,176) are historical and do not correspond to
this repository's current ratchet, which has moved substantially since
(see `tests/coverage/ratchet.env`'s own dated history).

**Historical note (logs):** every `/tmp/dxe-opencode-*.log` path
referenced below was a transient capture on the machine that ran this
validation at the time; none of them were ever committed, and none exist
any more. They are kept in the text only as a record of what was captured
and where, not as retrievable evidence.

## Recorded red evidence

- 2026-09-22: a fresh isolated `dx-opencode` guest failed twice while building
  Home Manager. Nix reported that `testImage`, the public NixOS GitHub avatar
  fetched from `https://avatars.githubusercontent.com/u/487568?s=200&v=4`, no
  longer matched the fixed-output hash in `flake.nix`.
- Expected: `sha256-4lDgsPtttAiM8b8d9vWZj4PbbhLPxANen+KwmYuLC3k=`.
- Actual: `sha256-PPs6NBjzRLZdMoNuiYaUwsk59KGGfHFDalePzC4LsZA=`.
- The downloaded response was independently checked as a 200-by-200 PNG, and
  `openssl` produced the recorded actual hash. This is a changed public asset,
  not an OpenCode package or lockfile update. (Branch 3 of the consolidation
  plan later removed this fetch entirely rather than re-pinning it.)
- Initial focused Section 17 red result: 52 passed, 10 intended failures, and
  1 skipped. The intended failures covered legacy-generation recovery and
  migration of existing OpenCode home paths.
- The first coverage run exposed a real activation regression: a fixture path
  reached the new activation code without `DX_BOOTSTRAP_ROOT` bound. The fix is
  now covered by the hardened tests.

## Green evidence

- The fixed-output hash was updated to the independently verified current
  value; no lockfile input was changed.
- Hardened Section 17 green: 84 passed, 0 failed, and 1 skipped.
- Section 3 green: 131 passed and 0 failed. Section 6 green: 100 passed,
  0 failed, and 1 skipped. Section 10 green: 144 passed and 0 failed.
- The final unit/static tier passed outside the sandbox; its captured record
  was `/tmp/dxe-opencode-unit.log` (gone; see the note above).
- With the corrected image hash, the fresh isolated `dx-opencode` guest booted.
  `/tmp/dxe-opencode-nix-check.log` (gone) recorded that OpenCode was absent
  before opt-in and that `nix flake check --no-build --no-write-lock-file
  /guest-bootstrap/current` passed every check, including `ai-tools`.
- Final isolated OpenCode acceptance green: 13 passed and 0 failed. It observed
  OpenCode `1.18.31`, including command resolution through `current/profile`,
  current Herdr integration plus its persisted plugin, both persistent home
  links and markers, and survival across `dx-recreate`. The equivalent
  integrated destructive command is:

  ```sh
  DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-opencode bash tests/run_all_tests.sh --section=17
  ```

  The 13/0 run preceded consolidation of the standalone acceptance script into
  Section 17.
- The full isolated live suite passed; the captured record was
  `/tmp/dxe-opencode-full-live.log` (gone).
- Final coverage passed at 100%; the covered scope was 2,177 scope-share
  basis points, above the 2,176-point baseline then in effect. The final
  record was `/tmp/dxe-opencode-coverage-final8.log` (gone).
