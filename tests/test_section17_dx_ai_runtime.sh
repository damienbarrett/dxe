#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# Section 17: dx-ai Runtime
# Verifies the optional AI tool installer works from inside the running guest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 17: dx-ai Runtime"

AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
before_flags=$-
# shellcheck source=/dev/null
source "$AI_SCRIPT"
if [ "$before_flags" = "$-" ] \
    && declare -F dx_ai_refresh_pin >/dev/null && declare -F dx_ai_stage_generation >/dev/null \
    && declare -F dx_ai_validate_generation >/dev/null && declare -F dx_ai_publish_generation >/dev/null \
    && declare -F dx_ai_recover_generation >/dev/null; then
    test_pass "dx-ai is a sourceable main with focused generation functions"
else
    test_fail "dx-ai is a sourceable main with focused generation functions"
fi
# Fable B3/B7: the publication-lock primitives now live in
# scripts/lib/dx-ai-lock.sh, loaded on demand the same way
# dx_ai_load_opencode_persistence/dx_ai_load_keyring load theirs. Load it
# here (once, up front) so every direct dx_ai_lock_acquire/dx_ai_lock_release
# call below -- not just the ones reached through dx_ai_main -- has them.
if dx_ai_load_lock && declare -F dx_ai_lock_acquire >/dev/null && declare -F dx_ai_lock_release >/dev/null \
    && declare -F dx_ai_process_start >/dev/null && declare -F dx_ai_boot_id >/dev/null; then
    test_pass "dx_ai_load_lock resolves the shared publication-lock library"
else
    test_fail "dx_ai_load_lock resolves the shared publication-lock library"
fi
assert_file_not_contains "$AI_SCRIPT" 'cd /guest-bootstrap' "dx-ai never changes into the published payload"
assert_file_not_contains "$AI_SCRIPT" 'sed -i' "dx-ai pin refresh is independent of Nix source formatting"
assert_file_contains_literal "$AI_SCRIPT" '/persist/home/dx/.local/state/dx-ai' "dx-ai mutable generations live under persist"

ai_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-ai-generations.XXXXXX")"
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT
published="$ai_fixture/published"; state="$ai_fixture/state"
mkdir -p "$published/pins" "$state/generations/previous"
# Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 3):
# pins/agy.json is a per-system keyed map. Both entries populated here (the
# generation-lifecycle tests below don't care about agy specifically, only
# that the required file exists and parses); the null/unsupported-system
# case has its own dedicated fixtures further down.
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy-arm","hash":"sha512-test-arm"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy-amd","hash":"sha512-test-amd"}}' > "$published/pins/agy.json"
printf '%s\n' fixture > "$published/flake.nix"
printf '%s\n' fixture > "$published/flake.lock"
seed_ai_profile() {
    local generation="$1" tool
    mkdir -p "$generation/profile/bin"
    for tool in codex gemini claude agy herdr opencode; do printf '#!/bin/sh\n' > "$generation/profile/bin/$tool"; chmod 0755 "$generation/profile/bin/$tool"; done
}
cp -a "$published/." "$state/generations/previous/"
printf '%s\n' '' > "$state/generations/previous/.predecessor"
seed_ai_profile "$state/generations/previous"
ln -s generations/previous "$state/current"
real_mv="$(command -v mv)"
mv_calls_log="$ai_fixture/mv-calls.log"
: > "$mv_calls_log"
mv() {
    printf '%s\n' "$*" >> "$mv_calls_log"
    case "${1:-}" in
        -Tf) rm -f "$3"; "$real_mv" -f "$2" "$3" ;;
        -T)
            # Emulate GNU mv's --no-target-directory for hosts whose mv
            # lacks it (e.g. BSD mv on macOS, where this suite also runs):
            # fail if the destination already exists at all, since plain mv
            # would otherwise move the source INSIDE an existing destination
            # directory instead of atomically renaming onto that exact path.
            # dx_ai_lock_acquire's stale-owner reclaim relies on exactly this
            # "fail if occupied" contract.
            [ ! -e "$3" ] && [ ! -L "$3" ] || return 1
            "$real_mv" "$2" "$3"
            ;;
        *) "$real_mv" "$@" ;;
    esac
}
stage="$(dx_ai_stage_generation "$published" "$state" next)"
if [ "$(cat "$stage/.predecessor")" = previous ] && [ "$(cat "$published/flake.nix")" = fixture ]; then
    test_pass "AI staging records predecessor without mutating published bootstrap"
else
    test_fail "AI staging records predecessor without mutating published bootstrap"
fi
seed_ai_profile "$stage"
dx_ai_publish_generation "$state" next "$stage"
if [ "$(readlink "$state/current")" = generations/next ] && [ -d "$state/generations/previous" ]; then
    test_pass "AI publication atomically advances current and retains predecessor"
else
    test_fail "AI publication atomically advances current and retains predecessor"
fi

# A copy failure (from the published bootstrap into the new stage) must
# discard the partial stage rather than leave it behind for a later run to
# trip over.
cpfail_state="$ai_fixture/cpfail-state"
mkdir -p "$cpfail_state/generations"
if (
    cp() { return 1; }
    dx_ai_stage_generation "$published" "$cpfail_state" next
) >/dev/null 2>&1; then
    test_fail "AI staging discards its stage when copying the published bootstrap fails"
elif [ -e "$cpfail_state/generations/.staging-next" ]; then
    test_fail "AI staging discards its stage when copying the published bootstrap fails"
else
    test_pass "AI staging discards its stage when copying the published bootstrap fails"
fi

# The very first generation ever staged has no state/current to read a
# predecessor from at all (not merely an empty one, as "previous" above
# already seeded) -- the empty case must still succeed and record an empty
# predecessor.
freshpred_state="$ai_fixture/freshpred-state"
mkdir -p "$freshpred_state"
freshpred_stage="$(dx_ai_stage_generation "$published" "$freshpred_state" first)"
if [ -n "$freshpred_stage" ] && [ "$(cat "$freshpred_stage/.predecessor")" = "" ]; then
    test_pass "AI staging records an empty predecessor for the very first generation"
else
    test_fail "AI staging records an empty predecessor for the very first generation"
fi

# An invalid predecessor name recorded at state/current (corrupt or hostile,
# not merely absent) is refused rather than staged over.
badpred_state="$ai_fixture/badpred-state"
mkdir -p "$badpred_state/generations"
ln -s "generations/bad!name" "$badpred_state/current"
if dx_ai_stage_generation "$published" "$badpred_state" next >/dev/null 2>&1; then
    test_fail "AI staging refuses an invalid predecessor generation name"
elif [ -e "$badpred_state/generations/.staging-next" ]; then
    test_fail "AI staging refuses an invalid predecessor generation name"
else
    test_pass "AI staging refuses an invalid predecessor generation name"
fi

# dx_ai_update_flake, unstubbed: it refreshes the agy pin for the named
# system, then updates and re-evaluates the flake's own metadata -- every
# dx_ai_main-level test below stubs this function away entirely, so its own
# real control flow is proven here instead.
updateflake_stage="$ai_fixture/updateflake-stage"
mkdir -p "$updateflake_stage/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$updateflake_stage/pins/agy.json"
printf '%s\n' fixture > "$updateflake_stage/flake.nix"
printf '%s\n' fixture > "$updateflake_stage/flake.lock"
updateflake_calls="$ai_fixture/updateflake-calls.log"
: > "$updateflake_calls"
if (
    dx_ai_refresh_pin() { printf 'refresh_pin %s %s\n' "$1" "$2" >> "$updateflake_calls"; }
    nix() { printf 'nix %s\n' "$*" >> "$updateflake_calls"; }
    dx_ai_update_flake "$updateflake_stage" aarch64-linux
) >/dev/null 2>&1; then
    test_pass "dx_ai_update_flake completes its real refresh/update/metadata sequence"
else
    test_fail "dx_ai_update_flake completes its real refresh/update/metadata sequence"
fi
if grep -qxF "refresh_pin $updateflake_stage aarch64-linux" "$updateflake_calls" \
    && grep -q "^nix flake update .*nixpkgs-unstable$" "$updateflake_calls" \
    && grep -q "^nix flake metadata .*$updateflake_stage$" "$updateflake_calls"; then
    test_pass "dx_ai_update_flake calls dx_ai_refresh_pin, then updates and re-evaluates the flake, in order"
else
    test_fail "dx_ai_update_flake calls dx_ai_refresh_pin, then updates and re-evaluates the flake, in order (log: $(cat "$updateflake_calls" | tr '\n' '|'))"
fi

# dx_ai_install_profile, unstubbed: every dx_ai_main-level test below stubs
# it away entirely, so its own real `nix profile add` argv is proven here.
installprofile_calls="$ai_fixture/installprofile-calls.log"
: > "$installprofile_calls"
if (
    nix() { printf 'nix %s\n' "$*" >> "$installprofile_calls"; }
    dx_ai_install_profile "$ai_fixture/installprofile-stage"
) >/dev/null 2>&1; then
    test_pass "dx_ai_install_profile builds the isolated AI tools profile via nix profile add"
else
    test_fail "dx_ai_install_profile builds the isolated AI tools profile via nix profile add"
fi
if grep -q "^nix profile add --profile $ai_fixture/installprofile-stage/profile .*$ai_fixture/installprofile-stage#ai-tools\$" "$installprofile_calls"; then
    test_pass "dx_ai_install_profile forwards the exact --profile path and #ai-tools attribute"
else
    test_fail "dx_ai_install_profile forwards the exact --profile path and #ai-tools attribute (log: $(cat "$installprofile_calls"))"
fi

failed_stage="$(dx_ai_stage_generation "$published" "$state" failed)"
seed_ai_profile "$failed_stage"
if (
    set -e
    mv() { [ "${1:-}" != -Tf ] || return 1; "$real_mv" "$@"; }
    dx_ai_publish_generation "$state" failed "$failed_stage"
); then
    test_fail "AI pointer publication failure is reported"
else
    test_pass "AI pointer publication failure is reported"
fi
if [ "$(readlink "$state/current")" = generations/next ] && [ -d "$state/generations/previous" ]; then
    test_pass "failed AI pointer switch preserves current and predecessor"
else
    test_fail "failed AI pointer switch preserves current and predecessor"
fi

if dx_ai_recover_generation "$state" >/dev/null && [ "$(readlink "$state/current")" = generations/previous ]; then
    test_pass "AI recovery atomically selects the retained predecessor"
else
    test_fail "AI recovery atomically selects the retained predecessor"
fi

# --- Per-generation tool manifests: dx-ai records the tool set of each
# generation and validates a generation against its own manifest, so
# recovering a retained pre-OpenCode five-tool generation works, and
# dx_ai_verify reports on that generation's own executables rather than
# assuming the current, larger DX_AI_TOOLS.
expect_failure() {
    local message="$1"; shift
    if "$@" >/dev/null 2>&1; then test_fail "$message"; else test_pass "$message"; fi
}

# "previous" (just recovered above, via cp -a rather than dx_ai_stage_generation)
# has no .tools-manifest: it stands in for a generation published before
# OpenCode support existed.
if [ ! -e "$state/generations/previous/.tools-manifest" ]; then
    test_pass "a legacy generation predates the tools manifest"
else
    test_fail "a legacy generation predates the tools manifest"
fi
legacy_expected="$(printf '%s\n' codex gemini claude agy herdr)"
if legacy_tools="$(dx_ai_generation_tools "$state/generations/previous")" && [ "$legacy_tools" = "$legacy_expected" ]; then
    test_pass "AI recovery accepts a legacy predecessor using its own five-tool inventory"
else
    test_fail "AI recovery accepts a legacy predecessor using its own five-tool inventory"
fi
legacy_verify_expected="$(for legacy_tool in codex gemini claude agy herdr; do printf '  %s -> %s/generations/previous/profile/bin/%s\n' "$legacy_tool" "$state" "$legacy_tool"; done)"
if legacy_verify="$(dx_ai_verify "$state/generations/previous" 2>&1)" \
    && [ "$(printf '%s\n' "$legacy_verify" | grep '^  .* -> ')" = "$legacy_verify_expected" ]; then
    test_pass "AI verification uses the legacy generation-local inventory"
else
    test_fail "AI verification uses the legacy generation-local inventory"
fi

# A present manifest is authoritative and must be regular, nonempty, and valid.
manifest_fixture="$ai_fixture/manifest-cases"
cp -a "$state/generations/previous" "$manifest_fixture"
for manifest_case in empty invalid-tail duplicate dot dotdot symlink directory; do
    rm -rf "$manifest_fixture/.tools-manifest"
    case "$manifest_case" in
        empty) : > "$manifest_fixture/.tools-manifest" ;;
        invalid-tail) printf '%s\n' codex 'not a tool' > "$manifest_fixture/.tools-manifest" ;;
        duplicate) printf '%s\n' codex codex > "$manifest_fixture/.tools-manifest" ;;
        dot) printf '%s\n' . > "$manifest_fixture/.tools-manifest" ;;
        dotdot) printf '%s\n' .. > "$manifest_fixture/.tools-manifest" ;;
        symlink) ln -s /dev/null "$manifest_fixture/.tools-manifest" ;;
        directory) mkdir "$manifest_fixture/.tools-manifest" ;;
    esac
    expect_failure "AI validation rejects a $manifest_case tool manifest" dx_ai_validate_generation "$manifest_fixture"
done
rm -rf "$manifest_fixture/.tools-manifest"
if dx_ai_validate_generation "$manifest_fixture" >/dev/null; then
    test_pass "AI validation uses the legacy inventory only when the manifest is absent"
else
    test_fail "AI validation uses the legacy inventory only when the manifest is absent"
fi

# Publication requires the candidate's own manifest (dx_ai_stage_generation
# always writes one) to declare the COMPLETE current bundle and to actually
# deliver an executable for every declared tool.
manifest_missing_stage="$(dx_ai_stage_generation "$published" "$state" manifest-missing-opencode)"
seed_ai_profile "$manifest_missing_stage"
rm -f "$manifest_missing_stage/profile/bin/opencode"
expect_failure "AI publication rejects a candidate missing its declared opencode executable" \
    dx_ai_publish_generation "$state" manifest-missing-opencode "$manifest_missing_stage"
if [ "$(readlink "$state/current")" = generations/previous ]; then
    test_pass "incomplete AI candidate leaves current generation unchanged"
else
    test_fail "incomplete AI candidate leaves current generation unchanged"
fi
printf '#!/bin/sh\n' > "$manifest_missing_stage/profile/bin/opencode"; chmod 0755 "$manifest_missing_stage/profile/bin/opencode"
if [ "$(tr '\n' ' ' < "$manifest_missing_stage/.tools-manifest" | sed 's/ $//')" = "codex claude agy herdr opencode" ]; then
    test_pass "AI staging records the complete generation-local tool manifest"
else
    test_fail "AI staging records the complete generation-local tool manifest"
fi
if dx_ai_publish_generation "$state" manifest-missing-opencode "$manifest_missing_stage" >/dev/null 2>&1; then
    test_pass "AI publication accepts the same candidate after its opencode executable is added"
else
    test_fail "AI publication accepts the same candidate after its opencode executable is added"
fi

# A generation that cannot be made read-only (`chmod -R a-w`) must be rolled
# back entirely -- removed rather than left behind half-published and
# writable -- and state/current must stay on whatever it already pointed at.
chmodfail_stage="$(dx_ai_stage_generation "$published" "$state" chmodfail)"
seed_ai_profile "$chmodfail_stage"
chmodfail_current_before="$(readlink "$state/current")"
if (
    chmod() { case "$*" in "-R a-w "*) return 1 ;; *) command chmod "$@" ;; esac; }
    dx_ai_publish_generation "$state" chmodfail "$chmodfail_stage"
) >/dev/null 2>&1; then
    test_fail "AI publication rolls back a generation it cannot make read-only"
elif [ -e "$state/generations/chmodfail" ]; then
    test_fail "AI publication rolls back a generation it cannot make read-only"
elif [ "$(readlink "$state/current")" != "$chmodfail_current_before" ]; then
    test_fail "AI publication rolls back a generation it cannot make read-only"
else
    test_pass "AI publication rolls back a generation it cannot make read-only"
fi

# WP1.8 (Fable D6): mv() above exists only to emulate GNU mv -T/-Tf for
# dx_ai_publish_generation/dx_ai_recover_generation/dx_ai_main's pointer-
# switch and lock-reclaim paths, which macOS's own mv lacks. None of the
# tool-manifest, dx_ai_verify, or agy/DQ7 cases between here and the next
# real AI publication call ever reach a mv -T/-Tf codepath, so unset it for
# that stretch -- it cannot then shadow anything else that happens to call
# a plain `mv` in between. Redefined identically just before the next case
# that needs it (the noagy end-to-end dx_ai_main run below).
unset -f mv

# dx_ai_verify must validate the generation's own inventory before trusting
# anything on PATH -- a stale/foreign binary earlier in PATH must not stand
# in for a missing generation executable.
verify_fixture="$ai_fixture/verify"
cp -a "$state/generations/manifest-missing-opencode" "$verify_fixture"
# Published generations are made read-only (dx_ai_publish_generation); undo
# that on this copy so the fixture below can still mutate it.
chmod -R u+w "$verify_fixture"
rm -f "$verify_fixture/profile/bin/herdr"
verify_fallback_bin="$ai_fixture/path-fallback"
mkdir -p "$verify_fallback_bin"
printf '#!/bin/sh\n' > "$verify_fallback_bin/herdr"; chmod 0755 "$verify_fallback_bin/herdr"
if PATH="$verify_fallback_bin:$PATH" dx_ai_verify "$verify_fixture" >/dev/null 2>&1; then
    test_fail "AI verification rejects a missing generation executable despite a PATH fallback"
else
    test_pass "AI verification rejects a missing generation executable despite a PATH fallback"
fi
printf '%s\n' codex 'not a tool' > "$verify_fixture/.tools-manifest"
if verify_output="$(dx_ai_verify "$verify_fixture" 2>&1)"; then
    test_fail "AI verification rejects a malformed generation inventory"
elif printf '%s\n' "$verify_output" | stdin_matches '^  codex -> '; then
    test_fail "AI verification validates its complete inventory before reporting any tool"
else
    test_pass "AI verification validates its complete inventory before reporting any tool"
fi

# dx_ai_verify with NO generation argument validates against PATH itself
# (the "AI tools were installed the old way, straight onto PATH" shape) --
# and fails as soon as any DX_AI_TOOLS entry is missing from it, the same
# way the generation-local branch fails on a missing executable above.
if verify_path_output="$(PATH="$ai_fixture/no-such-verify-path" dx_ai_verify 2>&1)"; then
    test_fail "AI verification against PATH fails when a DX_AI_TOOLS entry is missing from it"
elif printf '%s\n' "$verify_path_output" | stdin_matches '^  codex -> $'; then
    test_pass "AI verification against PATH fails when a DX_AI_TOOLS entry is missing from it"
else
    test_fail "AI verification against PATH fails when a DX_AI_TOOLS entry is missing from it"
fi

# --- dx_ai_check_cached / dx_ai_ensure_cached: refuse silent source builds ---
# (found on Branch 6, 2026-09-26: a nixpkgs-unstable refresh landed on a
# revision whose AI tools were not yet cached for the guest's architecture,
# and Nix silently built codex-core/codex-tui from source, OOM-killing the
# guest at the profile's default 12 GB). The fake `nix` below reproduces the
# *exact* wording nix 2.34.8's `build --dry-run` writes to stderr, verified
# against a real Nix (nixos/nix:2.34.8) rather than assumed -- see
# src/libmain/shared.cc's printMissing: singular "this derivation will be
# built:" / "this path will be fetched (...)" for exactly one, plural "these
# N derivations will be built:" / "these N paths will be fetched (...)"
# otherwise. dx-ai's own trivial, always-local derivations (verified against
# a real `nix build .#ai-tools` and `nix derivation show`): the dx-ai-tools
# buildEnv itself, its generic builder.pl companion, and agy/claude-code's
# own fetch+unpack (both unfree-licensed upstream, so Hydra never builds or
# caches either one, on any revision -- see the progress file for the
# nixpkgs package.nix evidence).
cache_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-ai-cache.XXXXXX")"
trap 'chmod -R u+w "$cache_fixture" 2>/dev/null || true; rm -rf "$cache_fixture"' EXIT

dryrun_all_cached="these 6 derivations will be built:
  /nix/store/aaaa10000000000000000000000001-claude.zst.drv
  /nix/store/aaaa10000000000000000000000002-claude-code-2.1.281.drv
  /nix/store/aaaa10000000000000000000000003-builder.pl.drv
  /nix/store/aaaa10000000000000000000000004-antigravity-cli-src.drv
  /nix/store/aaaa10000000000000000000000005-antigravity-cli-1.0.5.drv
  /nix/store/aaaa10000000000000000000000006-dx-ai-tools.drv
these 2 paths will be fetched (10.0 MiB download, 20.0 MiB unpacked):
  /nix/store/bbbb10000000000000000000000001-codex-0.157.0
  /nix/store/bbbb10000000000000000000000002-herdr-0.9.1"

dryrun_allowlisted_singular="this derivation will be built:
  /nix/store/aaaa10000000000000000000000006-dx-ai-tools.drv
this path will be fetched (1.0 MiB download, 2.0 MiB unpacked):
  /nix/store/bbbb10000000000000000000000001-codex-0.157.0"

dryrun_heavy_miss="these 3 derivations will be built:
  /nix/store/cccc10000000000000000000000001-codex-core-0.157.0.drv
  /nix/store/cccc10000000000000000000000002-codex-tui-0.157.0.drv
  /nix/store/aaaa10000000000000000000000006-dx-ai-tools.drv
this path will be fetched (5.0 MiB download, 9.0 MiB unpacked):
  /nix/store/bbbb10000000000000000000000002-herdr-0.9.1"

dryrun_nothing_to_do=""

# dx_ai_check_cached: a fake nix scripted per-call via a counter file, so a
# single test can drive two successive `nix build --dry-run` calls (the
# fresh lock, then the post-fallback re-check) with different scripted
# output -- exactly the shape dx_ai_ensure_cached needs.
cache_call_count="$cache_fixture/nix-call-count"
cache_script_1="$cache_fixture/nix-output-1"
cache_script_2="$cache_fixture/nix-output-2"
nix() {
    case "$*" in
        "build --dry-run --extra-experimental-features "*"nix-command flakes"*"--accept-flake-config "*"#ai-tools")
            local n=0
            [ ! -f "$cache_call_count" ] || n="$(cat "$cache_call_count")"
            n=$((n + 1))
            printf '%s\n' "$n" > "$cache_call_count"
            if [ "$n" -eq 1 ]; then cat "$cache_script_1" >&2; else cat "$cache_script_2" >&2; fi
            return 0
            ;;
        *) command nix "$@" ;;
    esac
}

# A tiny jq stand-in for dx_ai_nixpkgs_unstable_rev's one fixed query, so
# these assertions are exact regardless of whether the *host running the
# tests* happens to have a real jq -- the coverage/kcov image
# (tests/coverage/Dockerfile) does not, unlike the real guest, which always
# does via dxPackages. Follows the file's existing idiom of stubbing an
# external tool with a shell function rather than depending on the host's
# real binary (see the malformed-manifest jq fake above).
jq() {
    if [ "${1:-}" = -r ] && [ "${2:-}" = '.nodes["nixpkgs-unstable"].locked.rev // empty' ]; then
        sed -n 's/.*"rev":"\([^"]*\)".*/\1/p' "$3" 2>/dev/null
        return 0
    fi
    command jq "$@"
}

reset_cache_fixture() {
    rm -f "$cache_call_count"
    printf '%s\n' "$1" > "$cache_script_1"
    printf '%s\n' "${2:-}" > "$cache_script_2"
}

# Case: allow-listed-only builds (plural form) -- clean, no miss reported.
reset_cache_fixture "$dryrun_all_cached"
if check_out="$(dx_ai_check_cached "$cache_fixture" 2>/dev/null)" && [ -z "$check_out" ]; then
    test_pass "dx_ai_check_cached is clean when every 'will be built' derivation is allow-listed"
else
    test_fail "dx_ai_check_cached is clean when every 'will be built' derivation is allow-listed"
fi

# Case: allow-listed-only, singular ("this derivation will be built:") wording.
reset_cache_fixture "$dryrun_allowlisted_singular"
if check_out="$(dx_ai_check_cached "$cache_fixture" 2>/dev/null)" && [ -z "$check_out" ]; then
    test_pass "dx_ai_check_cached handles nix's singular 'this derivation will be built:' wording"
else
    test_fail "dx_ai_check_cached handles nix's singular 'this derivation will be built:' wording"
fi

# Case: nothing to build or fetch at all (everything already valid locally).
reset_cache_fixture "$dryrun_nothing_to_do"
if check_out="$(dx_ai_check_cached "$cache_fixture" 2>/dev/null)" && [ -z "$check_out" ]; then
    test_pass "dx_ai_check_cached is clean when nix reports nothing to build or fetch"
else
    test_fail "dx_ai_check_cached is clean when nix reports nothing to build or fetch"
fi

# Case: a heavy, non-allow-listed miss is reported by name and fails.
reset_cache_fixture "$dryrun_heavy_miss"
if check_out="$(dx_ai_check_cached "$cache_fixture" 2>/dev/null)"; then
    test_fail "dx_ai_check_cached reports a heavy cache miss"
elif printf '%s\n' "$check_out" | stdin_matches '^codex-core-0\.157\.0$' \
    && printf '%s\n' "$check_out" | stdin_matches '^codex-tui-0\.157\.0$' \
    && ! printf '%s\n' "$check_out" | stdin_matches '^dx-ai-tools$'; then
    test_pass "dx_ai_check_cached reports a heavy cache miss"
else
    test_fail "dx_ai_check_cached reports a heavy cache miss"
fi

# Case: nix itself fails to even evaluate the dry-run (distinct from
# succeeding and reporting a heavy miss) -- reported at rc=2, with the
# evaluation error surfaced, not silently treated as "nothing to build".
if (
    nix() {
        case "$*" in
            "build --dry-run "*"#ai-tools")
                echo "error: evaluation failed" >&2
                return 1
                ;;
            *) command nix "$@" ;;
        esac
    }
    check_evalfail_out="$(dx_ai_check_cached "$cache_fixture" 2>&1)"
    check_evalfail_rc=$?
    [ "$check_evalfail_rc" -eq 2 ] \
        && printf '%s\n' "$check_evalfail_out" | stdin_matches -F "could not evaluate the AI tools profile" \
        && printf '%s\n' "$check_evalfail_out" | stdin_matches -F "evaluation failed"
); then
    test_pass "dx_ai_check_cached reports rc=2 when nix itself fails to evaluate"
else
    test_fail "dx_ai_check_cached reports rc=2 when nix itself fails to evaluate"
fi

# Case: a non-path line appears inside the "will be built" section (nix has
# never been observed to print one, but the parser must not silently treat
# it as a store path either) -- it is skipped, and a real heavy miss further
# down the same section is still caught.
dryrun_with_noise="these 2 derivations will be built:
  note: an annotation line, not a /nix/store path
  /nix/store/aaaa10000000000000000000000006-dx-ai-tools.drv
  /nix/store/cccc10000000000000000000000001-codex-core-0.157.0.drv
this path will be fetched (1.0 MiB download, 2.0 MiB unpacked):
  /nix/store/bbbb10000000000000000000000001-codex-0.157.0"
reset_cache_fixture "$dryrun_with_noise"
if check_out="$(dx_ai_check_cached "$cache_fixture" 2>/dev/null)"; then
    test_fail "dx_ai_check_cached skips a non-path line inside the 'will be built' section"
elif printf '%s\n' "$check_out" | stdin_matches '^codex-core-0\.157\.0$' \
    && ! printf '%s\n' "$check_out" | stdin_matches '^dx-ai-tools$'; then
    test_pass "dx_ai_check_cached skips a non-path line inside the 'will be built' section"
else
    test_fail "dx_ai_check_cached skips a non-path line inside the 'will be built' section"
fi

# --- dx_ai_ensure_cached: fall back to the previous generation's lock, then
# fail closed; DX_AI_ALLOW_SOURCE_BUILDS=1 skips only the final refusal ---
ensure_fixture="$cache_fixture/ensure"
ensure_state="$ensure_fixture/state"
mkdir -p "$ensure_state/generations/previous"
printf '%s\n' fixture > "$ensure_state/generations/previous/flake.nix"
cat > "$ensure_state/generations/previous/flake.lock" <<'EOF'
{"nodes":{"nixpkgs-unstable":{"locked":{"rev":"0ldrev00000000000000000000000000000000"}}}}
EOF
ln -s generations/previous "$ensure_state/current"
mkdir -p "$ensure_fixture/stage"
cat > "$ensure_fixture/stage/flake.nix" <<'EOF'
      system = "aarch64-linux";
EOF
cat > "$ensure_fixture/stage/flake.lock" <<'EOF'
{"nodes":{"nixpkgs-unstable":{"locked":{"rev":"newrev0000000000000000000000000000000000"}}}}
EOF

# All cached: dx_ai_ensure_cached never touches $state/current and returns 0.
reset_cache_fixture "$dryrun_all_cached"
if ensure_out="$(dx_ai_ensure_cached "$ensure_fixture/stage" "$ensure_state" 2>&1)" \
    && [ "$(cat "$cache_call_count")" = 1 ]; then
    test_pass "dx_ai_ensure_cached proceeds without a fallback attempt when already clean"
else
    test_fail "dx_ai_ensure_cached proceeds without a fallback attempt when already clean"
fi

# Heavy miss, clean fallback: the previous generation's lock is copied into
# the stage, the second check is clean, dx-ai continues at the old revision
# and prints one clear notice; the published generation is untouched.
reset_cache_fixture "$dryrun_heavy_miss" "$dryrun_all_cached"
current_before="$(readlink "$ensure_state/current")"
if ensure_out="$(dx_ai_ensure_cached "$ensure_fixture/stage" "$ensure_state" 2>&1)"; then
    test_pass "dx_ai_ensure_cached falls back to the previous generation's lock on a clean re-check"
else
    test_fail "dx_ai_ensure_cached falls back to the previous generation's lock on a clean re-check"
fi
if printf '%s\n' "$ensure_out" | stdin_matches "newrev0000000000000000000000000000000000" \
    && printf '%s\n' "$ensure_out" | stdin_matches "0ldrev00000000000000000000000000000000" \
    && grep -F '"rev":"0ldrev00000000000000000000000000000000"' "$ensure_fixture/stage/flake.lock" >/dev/null; then
    test_pass "a clean fallback prints the old and new revisions and adopts the old lock"
else
    test_fail "a clean fallback prints the old and new revisions and adopts the old lock"
fi
if [ "$(readlink "$ensure_state/current")" = "$current_before" ]; then
    test_pass "a clean fallback leaves the published AI generation untouched"
else
    test_fail "a clean fallback leaves the published AI generation untouched"
fi

# Heavy miss, failing fallback: both checks miss, no override -- fail closed,
# print the remedy, exit non-zero, published generation still untouched.
cat > "$ensure_fixture/stage/flake.lock" <<'EOF'
{"nodes":{"nixpkgs-unstable":{"locked":{"rev":"newrev0000000000000000000000000000000000"}}}}
EOF
reset_cache_fixture "$dryrun_heavy_miss" "$dryrun_heavy_miss"
current_before="$(readlink "$ensure_state/current")"
if ensure_out="$(dx_ai_ensure_cached "$ensure_fixture/stage" "$ensure_state" 2>&1)"; then
    test_fail "dx_ai_ensure_cached fails closed when the fallback also misses"
else
    test_pass "dx_ai_ensure_cached fails closed when the fallback also misses"
fi
if printf '%s\n' "$ensure_out" | stdin_matches "codex-core-0.157.0" \
    && printf '%s\n' "$ensure_out" | stdin_matches -i "remedy" \
    && printf '%s\n' "$ensure_out" | stdin_matches "DX_AI_ALLOW_SOURCE_BUILDS"; then
    test_pass "a failing fallback names the packages and the remedy, including the override"
else
    test_fail "a failing fallback names the packages and the remedy, including the override"
fi
if [ "$(readlink "$ensure_state/current")" = "$current_before" ]; then
    test_pass "a failing fallback leaves the published AI generation untouched"
else
    test_fail "a failing fallback leaves the published AI generation untouched"
fi

# No previous generation: skip the fallback attempt entirely (no
# $state/current to copy from) and fail closed the same way.
cat > "$ensure_fixture/stage/flake.lock" <<'EOF'
{"nodes":{"nixpkgs-unstable":{"locked":{"rev":"newrev0000000000000000000000000000000000"}}}}
EOF
no_gen_state="$ensure_fixture/no-gen-state"
mkdir -p "$no_gen_state"
reset_cache_fixture "$dryrun_heavy_miss"
if ensure_out="$(dx_ai_ensure_cached "$ensure_fixture/stage" "$no_gen_state" 2>&1)"; then
    test_fail "dx_ai_ensure_cached fails closed when there is no previous generation"
else
    test_pass "dx_ai_ensure_cached fails closed when there is no previous generation"
fi
if [ "$(cat "$cache_call_count")" = 1 ]; then
    test_pass "no previous generation means no fallback dry-run is even attempted"
else
    test_fail "no previous generation means no fallback dry-run is even attempted"
fi

# The override: still tries the fallback first (best effort, zero source
# builds if it works), and only skips the *refusal* when it doesn't.
cat > "$ensure_fixture/stage/flake.lock" <<'EOF'
{"nodes":{"nixpkgs-unstable":{"locked":{"rev":"newrev0000000000000000000000000000000000"}}}}
EOF
reset_cache_fixture "$dryrun_heavy_miss" "$dryrun_heavy_miss"
current_before="$(readlink "$ensure_state/current")"
if ensure_out="$(DX_AI_ALLOW_SOURCE_BUILDS=1 dx_ai_ensure_cached "$ensure_fixture/stage" "$ensure_state" 2>&1)"; then
    test_pass "DX_AI_ALLOW_SOURCE_BUILDS=1 skips the refusal after a failed fallback"
else
    test_fail "DX_AI_ALLOW_SOURCE_BUILDS=1 skips the refusal after a failed fallback"
fi
if [ "$(cat "$cache_call_count")" = 2 ] \
    && printf '%s\n' "$ensure_out" | stdin_matches "codex-core-0.157.0"; then
    test_pass "the override still attempts the fallback first and still prints the list"
else
    test_fail "the override still attempts the fallback first and still prints the list"
fi
if [ "$(readlink "$ensure_state/current")" = "$current_before" ]; then
    test_pass "the override leaves the published AI generation untouched"
else
    test_fail "the override leaves the published AI generation untouched"
fi

unset -f nix jq
rm -rf "$cache_fixture"
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT

pin_before="$(shasum -a 256 "$published/pins/agy.json")"
if (
    curl() { printf '%s\n' '{}'; }
    jq() { printf '%s' ''; }
    dx_ai_refresh_pin "$published" aarch64-linux
); then
    test_pass "malformed upstream AI manifest is non-destructive"
else
    test_fail "malformed upstream AI manifest is non-destructive"
fi
if [ "$pin_before" = "$(shasum -a 256 "$published/pins/agy.json")" ]; then test_pass "malformed AI manifest leaves pin unchanged"; else test_fail "malformed AI manifest leaves pin unchanged"; fi

# --- Branch 11 / Phase 4 (qnap-dxe-plan.md DQ7, docs/refactor/
# arch-neutral-guest.md section 3): per-system agy manifest URL, per-system
# pin refresh, native-system detection, and the null-pin "no native
# artifact" diagnostic. ---

if [ "$(dx_ai_agy_manifest_url aarch64-linux)" = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json" ]; then
    test_pass "dx_ai_agy_manifest_url resolves the arm64 manifest for aarch64-linux"
else
    test_fail "dx_ai_agy_manifest_url resolves the arm64 manifest for aarch64-linux"
fi
if [ "$(dx_ai_agy_manifest_url x86_64-linux)" = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json" ]; then
    test_pass "dx_ai_agy_manifest_url resolves the amd64 manifest for x86_64-linux"
else
    test_fail "dx_ai_agy_manifest_url resolves the amd64 manifest for x86_64-linux"
fi
expect_failure "dx_ai_agy_manifest_url refuses an unrecognized system" dx_ai_agy_manifest_url riscv64-linux

# dx_ai_refresh_pin updates ONLY the named system's key, leaving every other
# architecture's entry byte-for-byte untouched.
refresh_fixture="$ai_fixture/refresh-pin"
mkdir -p "$refresh_fixture/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1.0.5","url":"https://example.invalid/old-arm","hash":"sha512-oldarm"},"x86_64-linux":{"version":"1.2.12","url":"https://example.invalid/old-amd","hash":"sha512-oldamd"}}' > "$refresh_fixture/pins/agy.json"
if (
    curl() { printf '%s\n' '{"version":"9.9.9","url":"https://example.invalid/new-amd","sha512":"'"$(printf 'a%.0s' $(seq 1 128))"'"}'; }
    nix() { [ "$1" = hash ] && printf 'sha512-newamdhash\n' || command nix "$@"; }
    # Narrow jq stand-in for this call's three shapes (the leading null-pin
    # guard's query, manifest-field extraction from stdin, and the
    # single-key merge into pins/agy.json) -- the pinned-ShellCheck/coverage
    # container deliberately has no real jq (see dx-ai.sh's own
    # dx_ai_nixpkgs_unstable_rev comment for the same accepted gap), unlike
    # the real guest, which always does via dxPackages. Generic string-splice
    # merge, not a hardcoded answer: it reads the file's OTHER key(s) back
    # out untouched, so this still proves dx_ai_refresh_pin's real behavior,
    # not a tautology.
    jq() {
        if [ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = system ] && [ "$5" = '(.[$system] // null) == null' ]; then
            if grep -qF "\"$4\":null" "$6" 2>/dev/null; then printf 'true\n'; else printf 'false\n'; fi
            return
        fi
        case "$1 $2" in
            "-r .version // empty") sed -n 's/.*"version":"\([^"]*\)".*/\1/p' ;;
            "-r .url // empty") sed -n 's/.*"url":"\([^"]*\)".*/\1/p' ;;
            "-r .sha512 // empty") sed -n 's/.*"sha512":"\([^"]*\)".*/\1/p' ;;
            *)
                if [ "$1" = --arg ] && [ "$2" = system ]; then
                    local args=("$@") sys version url hash file content new_value before after
                    sys="${args[2]}"; version="${args[5]}"; url="${args[8]}"; hash="${args[11]}"
                    file="${args[$(( ${#args[@]} - 1 ))]}"
                    content="$(cat "$file")"
                    new_value="{\"version\":\"$version\",\"url\":\"$url\",\"hash\":\"$hash\"}"
                    case "$content" in
                        *"\"$sys\":null"*)
                            before="${content%%\"$sys\":null*}"
                            after="${content#*\"$sys\":null}"
                            printf '%s' "$before\"$sys\":$new_value$after"
                            ;;
                        *"\"$sys\":{"*)
                            before="${content%%\"$sys\":{*}"
                            after="${content#*\"$sys\":\{*\}}"
                            printf '%s' "$before\"$sys\":$new_value$after"
                            ;;
                        *) return 1 ;;
                    esac
                else
                    return 1
                fi
                ;;
        esac
    }
    dx_ai_refresh_pin "$refresh_fixture" x86_64-linux
) && refreshed_amd="$(sed -n 's/.*"x86_64-linux":{"version":"\([^"]*\)".*/\1/p' "$refresh_fixture/pins/agy.json")" \
    && refreshed_arm="$(sed -n 's/.*"aarch64-linux":{[^}]*"url":"\([^"]*\)".*/\1/p' "$refresh_fixture/pins/agy.json")" \
    && [ "$refreshed_amd" = 9.9.9 ] && [ "$refreshed_arm" = "https://example.invalid/old-arm" ]; then
    test_pass "dx_ai_refresh_pin updates only the named system's key"
else
    test_fail "dx_ai_refresh_pin updates only the named system's key"
fi

# dx_ai_refresh_pin: a merge whose `jq` invocation itself fails (distinct
# from one that runs cleanly but produces a byte-identical or malformed
# result, both already covered above) must discard its temp file and fail,
# never leaving a stray temp pin file behind or touching the real one.
refresh_jqfail_fixture="$ai_fixture/refresh-pin-jqfail"
mkdir -p "$refresh_jqfail_fixture/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1.0.5","url":"https://example.invalid/old-arm","hash":"sha512-oldarm"}}' > "$refresh_jqfail_fixture/pins/agy.json"
if (
    curl() { printf '%s\n' '{"version":"9.9.9","url":"https://example.invalid/new-arm","sha512":"'"$(printf 'a%.0s' $(seq 1 128))"'"}'; }
    nix() { [ "$1" = hash ] && printf 'sha512-newarmhash\n' || command nix "$@"; }
    # Same narrow jq stand-in as the fixture above, except the final merge
    # assignment (identified by lacking -r, unlike every other call this
    # function makes) always fails -- isolating dx_ai_refresh_pin's own
    # `if ! jq ...; then rm -f "$tmp"; return 1; fi` guard from a merge that
    # merely produces an unwanted result.
    jq() {
        if [ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = system ] && [ "$5" = '(.[$system] // null) == null' ]; then
            printf 'false\n'
            return
        fi
        case "$1 $2" in
            "-r .version // empty") sed -n 's/.*"version":"\([^"]*\)".*/\1/p' ;;
            "-r .url // empty") sed -n 's/.*"url":"\([^"]*\)".*/\1/p' ;;
            "-r .sha512 // empty") sed -n 's/.*"sha512":"\([^"]*\)".*/\1/p' ;;
            *) return 1 ;;
        esac
    }
    dx_ai_refresh_pin "$refresh_jqfail_fixture" aarch64-linux
); then
    test_fail "dx_ai_refresh_pin discards its temp file when the merge jq invocation itself fails"
elif [ -z "$(find "$refresh_jqfail_fixture/pins" -maxdepth 1 -name '.agy.json.*')" ] \
    && grep -qF '"aarch64-linux":{"version":"1.0.5"' "$refresh_jqfail_fixture/pins/agy.json"; then
    test_pass "dx_ai_refresh_pin discards its temp file when the merge jq invocation itself fails"
else
    test_fail "dx_ai_refresh_pin discards its temp file when the merge jq invocation itself fails"
fi

# Finding 2 (dx-test live tier): the live gate showed dx_ai_refresh_pin
# re-fetching and overwriting a system's pin even though pins/agy.json
# already recorded it as null ("Pinned agy 9.9.9 for x86_64-linux from
# upstream manifest") -- for a system DQ7 says has no native artifact. A
# null entry is a deliberate, sticky "unsupported" marker: refresh must
# never resurrect it, and must never even reach the network to find out,
# since the null declaration is what encodes "no native artifact" -- not
# whatever upstream's manifest happens to publish today. curl is stubbed to
# RETURN real-looking manifest data (the same shape the named-key test above
# uses) specifically so a naive fix that merely reverted the write after
# fetching would still fail this: the assertion also proves curl is never
# even invoked.
null_refresh_fixture="$ai_fixture/refresh-pin-null"
mkdir -p "$null_refresh_fixture/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1.0.5","url":"https://example.invalid/old-arm","hash":"sha512-oldarm"},"x86_64-linux":null}' > "$null_refresh_fixture/pins/agy.json"
null_pin_before="$(cat "$null_refresh_fixture/pins/agy.json")"
null_refresh_curl_called="$ai_fixture/refresh-pin-null-curl-called.log"
rm -f "$null_refresh_curl_called"
if (
    curl() { printf 'called\n' >> "$null_refresh_curl_called"; printf '%s\n' '{"version":"9.9.9","url":"https://example.invalid/new-amd","sha512":"'"$(printf 'a%.0s' $(seq 1 128))"'"}'; }
    # Same narrow jq stand-in dx_ai_tools_for_system's own null-check test
    # uses below (no real jq in the pinned-ShellCheck/coverage container):
    # reads the fixture's real content, not a hardcoded answer.
    jq() {
        if [ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = system ]; then
            if grep -qF "\"$4\":null" "$6" 2>/dev/null; then printf 'true\n'; else printf 'false\n'; fi
        else
            return 1
        fi
    }
    null_refresh_out="$(dx_ai_refresh_pin "$null_refresh_fixture" x86_64-linux 2>&1)"
    printf '%s\n' "$null_refresh_out" | stdin_matches -F "DQ7"
) && [ ! -f "$null_refresh_curl_called" ] \
    && [ "$(cat "$null_refresh_fixture/pins/agy.json")" = "$null_pin_before" ]; then
    test_pass "dx_ai_refresh_pin never resurrects a null system's pin (Finding 2)"
else
    test_fail "dx_ai_refresh_pin never resurrects a null system's pin (Finding 2)"
fi

# Branch 11 / Phase 4, Increment 3 (docs/refactor/arch-neutral-guest.md
# section 4): dx-ai.sh now sources the shared scripts/lib/dx-guest-system.sh
# helper (dx_guest_native_system/dx_guest_resolve_system) instead of its own
# temporary dx_ai_native_system (Increment 2) -- that mapping is tested
# directly in tests/test_section3_bootstrap.sh, alongside bootstrap.sh's own
# use of the same shared helper. dx_ai_load_guest_system, the loader that
# resolves it (same three-candidate shape as dx_ai_load_opencode_persistence/
# dx_ai_load_keyring), is proven here.
if (
    unset -f dx_guest_resolve_system dx_guest_native_system 2>/dev/null
    dx_ai_load_guest_system && declare -F dx_guest_resolve_system >/dev/null
); then
    test_pass "dx_ai_load_guest_system resolves the shared guest-system helper"
else
    test_fail "dx_ai_load_guest_system resolves the shared guest-system helper"
fi

# dx_ai_tools_for_system: the full DX_AI_TOOLS list when the system's agy
# pin is non-null; DX_AI_TOOLS minus agy, plus DQ7's exact diagnostic on
# stderr, when it is null. Never silently substitutes a foreign binary --
# that guarantee is flake.nix's own per-system agy/aiPackages filtering
# (section 3.3); this only keeps dx-ai's own bookkeeping in agreement.
tools_fixture="$ai_fixture/tools-for-system"
mkdir -p "$tools_fixture/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":null}' > "$tools_fixture/pins/agy.json"
# Narrow jq stand-in for dx_ai_tools_for_system's one query -- same
# accepted gap as dx_ai_refresh_pin's stand-in above (no real jq in the
# pinned-ShellCheck/coverage container). Reads the fixture's real content
# rather than a hardcoded answer, so the three assertions below still
# prove the real null-vs-non-null branch, not a tautology. Scoped to this
# block only; unset once done.
jq() {
    if [ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = system ]; then
        if grep -qF "\"$4\":null" "$6" 2>/dev/null; then printf 'true\n'; else printf 'false\n'; fi
    else
        return 1
    fi
}
supported_expected="$(printf '%s\n' $DX_AI_TOOLS)"
if supported_out="$(dx_ai_tools_for_system "$tools_fixture" aarch64-linux 2>/dev/null)" && [ "$supported_out" = "$supported_expected" ]; then
    test_pass "dx_ai_tools_for_system returns the full tool list when agy is supported"
else
    test_fail "dx_ai_tools_for_system returns the full tool list when agy is supported"
fi
unsupported_expected="$(for t in $DX_AI_TOOLS; do [ "$t" != agy ] && printf '%s\n' "$t"; done)"
if unsupported_out="$(dx_ai_tools_for_system "$tools_fixture" x86_64-linux 2>/dev/null)" && [ "$unsupported_out" = "$unsupported_expected" ]; then
    test_pass "dx_ai_tools_for_system excludes agy when its pin is null"
else
    test_fail "dx_ai_tools_for_system excludes agy when its pin is null"
fi
if dx_ai_tools_for_system "$tools_fixture" x86_64-linux 2>&1 >/dev/null | stdin_matches -F "agy: no native artifact for x86_64-linux; skipping (DQ7)"; then
    test_pass "dx_ai_tools_for_system prints DQ7's exact unsupported-tool diagnostic"
else
    test_fail "dx_ai_tools_for_system prints DQ7's exact unsupported-tool diagnostic"
fi
unset -f jq

# Re-establish the mv -T/-Tf emulation (see the WP1.8 note above, where it
# was unset) for the dx_ai_main run below, which publishes a real
# generation and so exercises dx_ai_publish_pointer's mv -Tf switch.
mv() {
    printf '%s\n' "$*" >> "$mv_calls_log"
    case "${1:-}" in
        -Tf) rm -f "$3"; "$real_mv" -f "$2" "$3" ;;
        -T)
            [ ! -e "$3" ] && [ ! -L "$3" ] || return 1
            "$real_mv" "$2" "$3"
            ;;
        *) "$real_mv" "$@" ;;
    esac
}

# End-to-end: a sourced dx_ai_main run on a system whose agy pin is null
# stages a generation whose .tools-manifest and published executables
# reflect the adjusted list -- proving the exclusion is actually wired into
# the real generation lifecycle, not only callable in isolation. Finding 2
# (dx-test live tier): dx_ai_update_flake is exercised for REAL here (not
# stubbed to a no-op) -- the live gate caught the refresh-resurrection bug
# specifically because it runs dx_ai_main unstubbed; a fast-tier test that
# stubbed dx_ai_update_flake away could never have caught it.
noagy_published="$ai_fixture/noagy-published"; noagy_state="$ai_fixture/noagy-state"
mkdir -p "$noagy_published/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":null}' > "$noagy_published/pins/agy.json"
printf '%s\n' fixture > "$noagy_published/flake.nix"
printf '%s\n' fixture > "$noagy_published/flake.lock"
noagy_output_log="$ai_fixture/noagy-output.log"
(
    # The live tier always runs every section under a resolved host profile
    # (./bin/dx-profile <name> ...), which exports DX_GUEST_SYSTEM (Apple's
    # default: aarch64-linux) into this process's environment before this
    # test file ever starts -- unlike the fast/bare tier, where it is
    # simply absent. dx_guest_resolve_system (scripts/lib/dx-guest-system.sh)
    # deliberately refuses when DX_GUEST_SYSTEM disagrees with the guest's
    # own native uname (docs/refactor/arch-neutral-guest.md section 4): a
    # real x86_64 guest's own DX_GUEST_SYSTEM, forwarded by
    # bin/dx-create-container, always agrees with its own native
    # architecture, so that refusal never fires in production. Here it
    # simulates a native x86_64 guest via the uname stub below while
    # inheriting the test RUNNER's own resolved (aarch64-linux) profile --
    # a combination that can only arise from the test host's environment,
    # never from a real guest -- so this subshell isolates itself from that
    # inherited token exactly like a real guest's own environment would
    # never carry a mismatched one.
    unset DX_GUEST_SYSTEM
    uname() { [ "${1:-}" = -m ] && printf '%s\n' x86_64 || command uname "$@"; }
    # Full jq stand-in: the leading null-pin guard query (also
    # dx_ai_tools_for_system's own null check, same shape), manifest-field
    # extraction from stdin, and the single-key merge into pins/agy.json --
    # same three shapes as the direct dx_ai_refresh_pin unit test's stand-in
    # above (no real jq in the pinned-ShellCheck/coverage container). This
    # is deliberately the FULL stand-in, not just the null-check branch: a
    # narrower one that failed field-extraction closed would make refresh
    # bail out via its own "malformed manifest" path regardless of the null
    # guard, which would pass this test whether or not the guard exists.
    jq() {
        if [ "$1" = -r ] && [ "$2" = --arg ] && [ "$3" = system ] && [ "$5" = '(.[$system] // null) == null' ]; then
            if grep -qF "\"$4\":null" "$6" 2>/dev/null; then printf 'true\n'; else printf 'false\n'; fi
            return
        fi
        case "$1 $2" in
            "-r .version // empty") sed -n 's/.*"version":"\([^"]*\)".*/\1/p' ;;
            "-r .url // empty") sed -n 's/.*"url":"\([^"]*\)".*/\1/p' ;;
            "-r .sha512 // empty") sed -n 's/.*"sha512":"\([^"]*\)".*/\1/p' ;;
            *)
                if [ "$1" = --arg ] && [ "$2" = system ]; then
                    local args=("$@") sys version url hash file content new_value before after
                    sys="${args[2]}"; version="${args[5]}"; url="${args[8]}"; hash="${args[11]}"
                    file="${args[$(( ${#args[@]} - 1 ))]}"
                    content="$(cat "$file")"
                    new_value="{\"version\":\"$version\",\"url\":\"$url\",\"hash\":\"$hash\"}"
                    case "$content" in
                        *"\"$sys\":null"*)
                            before="${content%%\"$sys\":null*}"
                            after="${content#*\"$sys\":null}"
                            printf '%s' "$before\"$sys\":$new_value$after"
                            ;;
                        *"\"$sys\":{"*)
                            before="${content%%\"$sys\":{*}"
                            after="${content#*\"$sys\":\{*\}}"
                            printf '%s' "$before\"$sys\":$new_value$after"
                            ;;
                        *) return 1 ;;
                    esac
                else
                    return 1
                fi
                ;;
        esac
    }
    # curl deliberately RETURNS real-looking manifest data for x86_64-linux
    # (upstream genuinely publishes one) so this proves the null pin survives
    # because dx_ai_refresh_pin's own guard declines to resurrect it, not
    # because this fixture never gave refresh anything to resurrect with.
    # nix's flake subcommands are no-ops (this fixture's flake.nix/
    # flake.lock are not real flakes); its hash subcommand matches the
    # existing dx_ai_refresh_pin unit test's own stand-in above.
    curl() { printf '%s\n' '{"version":"9.9.9","url":"https://example.invalid/new-amd","sha512":"'"$(printf 'a%.0s' $(seq 1 128))"'"}'; }
    nix() {
        case "$1 $2" in
            "flake update"|"flake metadata") return 0 ;;
            *) [ "$1" = hash ] && printf 'sha512-newamdhash\n' || command nix "$@" ;;
        esac
    }
    dx_ai_ensure_cached() { :; }
    dx_ai_install_profile() {
        local stage="$1" tool
        mkdir -p "$stage/profile/bin"
        for tool in $(cat "$stage/.tools-manifest" 2>/dev/null || printf '%s\n' $DX_AI_TOOLS); do
            printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"
        done
    }
    dx_ai_setup_credentials() { :; }
    dx_ai_ensure_keyring() { :; }
    dx_ai_verify() { :; }
    id() { printf '%s\n' 1000; }
    # WP5.2: dx_ai_lock_acquire now delegates to the shared
    # publication_lock_acquire (bin/lib/dx-bootstrap-protocol.sh /
    # scripts/lib/dx-publication.sh), which calls boot_id/process_start
    # directly, not the dx_ai_boot_id/dx_ai_process_start wrappers -- stub
    # the names it actually calls.
    boot_id() { printf '%s\n' test-boot-id; }
    process_start() { printf '%s\n' 123; }
    DX_AI_BOOTSTRAP_ROOT="$noagy_published" DX_AI_STATE_ROOT="$noagy_state" dx_ai_main
) >"$noagy_output_log" 2>&1
noagy_manifest="$(readlink -f "$noagy_state/current" 2>/dev/null)"
if [ -n "$noagy_manifest" ] && [ -f "$noagy_manifest/.tools-manifest" ] \
    && ! grep -qx agy "$noagy_manifest/.tools-manifest" \
    && [ ! -e "$noagy_manifest/profile/bin/agy" ] \
    && [ -x "$noagy_manifest/profile/bin/codex" ] \
    && grep -qF '"x86_64-linux":null' "$noagy_manifest/pins/agy.json" \
    && ! grep -qF "Pinned agy" "$noagy_output_log"; then
    test_pass "a real dx_ai_main run on a null-agy system publishes a generation without agy"
else
    test_fail "a real dx_ai_main run on a null-agy system publishes a generation without agy"
fi

# R5: an unavailable boot ID is not an identity. In that environment dx-ai
# must fail before touching a live owner's lock rather than parse an empty
# first TSV field and reclaim it as stale.
if (
    proc_root="$ai_fixture/no-identity-proc"
    lock="$ai_fixture/missing-identity.lock"
    mkdir -p "$proc_root" "$lock"
    printf 'old-boot\t999\t123\n' > "$lock/owner"
    set +e
    out="$(dx_ai_lock_acquire "$lock" "$proc_root" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -d "$lock" ] && [ "$(cat "$lock/owner")" = $'old-boot\t999\t123' ] && printf '%s\n' "$out" | stdin_matches "cannot identify lock owner process"
); then
    test_pass "dx-ai refuses lock acquisition when all process identities are unavailable (R5)"
else
    test_fail "dx-ai refuses lock acquisition when all process identities are unavailable (R5)"
fi

# R5: parse field 22 in Bash, including a comm field containing a closing
# parenthesis and spaces. This runs before the lock code needs the identity,
# so no external awk can be required in the early guest bootstrap path.
proc_root="$ai_fixture/proc-identity"
mkdir -p "$proc_root/sys/kernel/random" "$proc_root/4242"
printf '%s\n' '4242 (worker ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 424242' > "$proc_root/4242/stat"
printf '%s\n' 'btime 1785827572' > "$proc_root/stat"
printf '%s\n' 'a1b2c3d4-e5f6-7890-abcd-ef0123456789' > "$proc_root/sys/kernel/random/boot_id"
if [ "$(dx_ai_process_start 4242 "$proc_root")" = 424242 ]; then
    test_pass "dx-ai parses proc stat starttime in Bash with a complex comm field (R5)"
else
    test_fail "dx-ai parses proc stat starttime in Bash with a complex comm field (R5)"
fi
if [ "$(dx_ai_boot_id "$proc_root")" = a1b2c3d4-e5f6-7890-abcd-ef0123456789 ]; then
    test_pass "dx-ai preserves raw UUID boot identities for existing owner records (R5)"
else
    test_fail "dx-ai preserves raw UUID boot identities for existing owner records (R5)"
fi
rm -f "$proc_root/sys/kernel/random/boot_id"
if [ "$(dx_ai_boot_id "$proc_root")" = btime:1785827572 ]; then
    test_pass "dx-ai falls back to an explicit proc btime boot identity (R5)"
else
    test_fail "dx-ai falls back to an explicit proc btime boot identity (R5)"
fi
mkdir -p "$proc_root/$$"
printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777" > "$proc_root/$$/stat"
btime_lock="$ai_fixture/btime.lock"
if dx_ai_lock_acquire "$btime_lock" "$proc_root" && [ "$(cut -f1 "$btime_lock/owner")" = btime:1785827572 ]; then
    dx_ai_lock_release "$btime_lock"
    test_pass "dx-ai acquires a lock with the btime fallback identity (R5)"
else
    dx_ai_lock_release "$btime_lock" 2>/dev/null || true
    test_fail "dx-ai acquires a lock with the btime fallback identity (R5)"
fi

# Coverage: a $proc_root/stat that EXISTS and is readable, but never
# contains a well-formed, matching `btime` line, exhausts dx_ai_boot_id's
# fallback loop entirely and falls through to its own `return 1` AFTER the
# loop (dx-ai-lock.sh:43) -- distinct from $proc_root/stat being missing or
# unreadable altogether (dx-ai-lock.sh:37/18, the "all process identities are
# unavailable" R5 case above, which never even enters this loop). No
# sys/kernel/random/boot_id file is present either, so the earlier UUID
# short-circuit (line 34-36) is also not what is under test here.
no_btime_proc="$ai_fixture/no-btime-proc"
no_btime_lock="$ai_fixture/no-btime.lock"
mkdir -p "$no_btime_proc/$$"
printf '%s\n' 'cpu  100 200 300 400' > "$no_btime_proc/stat"
printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 888" > "$no_btime_proc/$$/stat"
no_btime_out="$(dx_ai_boot_id "$no_btime_proc")"; no_btime_rc=$?
if [ "$no_btime_rc" -eq 1 ] && [ -z "$no_btime_out" ]; then
    test_pass "dx_ai_boot_id falls through its stat-scan loop with no output when no line matches btime (dx-ai-lock.sh:43)"
else
    test_fail "dx_ai_boot_id falls through its stat-scan loop with no output when no line matches btime (dx-ai-lock.sh:43) (rc=$no_btime_rc out='$no_btime_out')"
fi
no_btime_lock_out="$(dx_ai_lock_acquire "$no_btime_lock" "$no_btime_proc" 2>&1)"; no_btime_lock_rc=$?
if [ "$no_btime_lock_rc" -eq 1 ] && [ ! -e "$no_btime_lock" ] \
    && printf '%s\n' "$no_btime_lock_out" | stdin_matches "cannot identify lock owner process"; then
    test_pass "dx-ai refuses lock acquisition when the boot-id stat fallback finds no btime line (dx-ai-lock.sh:43)"
else
    test_fail "dx-ai refuses lock acquisition when the boot-id stat fallback finds no btime line (dx-ai-lock.sh:43) (rc=$no_btime_lock_rc out='$no_btime_lock_out')"
fi

# WP5.2 Refactor: dx-ai-lock.sh's OWN dx_ai_boot_id used to refuse a
# /proc/sys/kernel/random/boot_id whose content was not a hex/dash string
# (`case "$boot" in ''|*[!0-9A-Fa-f-]*) ;; esac`, from before WP5.2 unified
# the three implementations' boot_id into the shared
# scripts/lib/dx-publication.sh). Unifying it silently dropped that
# validation -- the shared boot_id() accepted ANY non-empty content from
# that file verbatim. A boot_id file containing garbage (not a UUID, not a
# btime marker) must not be trusted as an identity: dx_ai_boot_id falls
# through to the /proc/stat btime fallback exactly as it would if the
# boot_id file were absent, and since this fixture's own /proc/stat also
# carries no matching btime line, dx-ai must fail closed with its existing
# "cannot identify lock owner process" refusal, never a lock acquired under
# a garbage identity.
garbage_boot_proc="$ai_fixture/garbage-boot-proc"
garbage_boot_lock="$ai_fixture/garbage-boot.lock"
mkdir -p "$garbage_boot_proc/sys/kernel/random" "$garbage_boot_proc/$$"
printf 'not-a-boot-id\n' > "$garbage_boot_proc/sys/kernel/random/boot_id"
printf 'cpu  100 200 300 400\n' > "$garbage_boot_proc/stat"
printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 999" > "$garbage_boot_proc/$$/stat"
garbage_boot_out="$(dx_ai_boot_id "$garbage_boot_proc")"; garbage_boot_rc=$?
if [ "$garbage_boot_rc" -eq 1 ] && [ -z "$garbage_boot_out" ]; then
    test_pass "dx_ai_boot_id refuses a non-hex/dash boot_id file and falls through to the btime fallback"
else
    test_fail "dx_ai_boot_id refuses a non-hex/dash boot_id file and falls through to the btime fallback (rc=$garbage_boot_rc out='$garbage_boot_out')"
fi
garbage_boot_lock_out="$(dx_ai_lock_acquire "$garbage_boot_lock" "$garbage_boot_proc" 2>&1)"; garbage_boot_lock_rc=$?
if [ "$garbage_boot_lock_rc" -eq 1 ] && [ ! -e "$garbage_boot_lock" ] \
    && printf '%s\n' "$garbage_boot_lock_out" | stdin_matches "cannot identify lock owner process"; then
    test_pass "dx-ai refuses lock acquisition when boot_id contains non-hex/dash garbage"
else
    test_fail "dx-ai refuses lock acquisition when boot_id contains non-hex/dash garbage (rc=$garbage_boot_lock_rc out='$garbage_boot_lock_out')"
fi

# Coverage: a $proc_root/stat that DOES contain a line whose key is
# "btime", but whose VALUE is not a plain non-negative integer, must be
# refused via the INLINE `''|*[!0-9]*) return 1 ;;` case arm
# (dx-publication.sh:43) -- distinct from the "no btime line matches at
# all" case above, which instead exhausts the loop and falls through to
# the `return 1` AFTER it (dx-publication.sh:47/its KCOV_LOOP_TERMINATOR
# line), and from the non-hex/dash boot_id file case, which never reaches
# this stat-scan loop's btime branch at all. No sys/kernel/random/boot_id
# file is present, so the raw-UUID short circuit is not what is under test
# here either.
garbage_btime_proc="$ai_fixture/garbage-btime-proc"
garbage_btime_lock="$ai_fixture/garbage-btime.lock"
mkdir -p "$garbage_btime_proc/$$"
printf '%s\n' 'cpu  100 200 300 400' 'btime not-a-number' > "$garbage_btime_proc/stat"
printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 999" > "$garbage_btime_proc/$$/stat"
garbage_btime_out="$(dx_ai_boot_id "$garbage_btime_proc")"; garbage_btime_rc=$?
if [ "$garbage_btime_rc" -eq 1 ] && [ -z "$garbage_btime_out" ]; then
    test_pass "dx_ai_boot_id refuses a /proc/stat btime field that is not a plain integer (dx-publication.sh:43)"
else
    test_fail "dx_ai_boot_id refuses a /proc/stat btime field that is not a plain integer (dx-publication.sh:43) (rc=$garbage_btime_rc out='$garbage_btime_out')"
fi
garbage_btime_lock_out="$(dx_ai_lock_acquire "$garbage_btime_lock" "$garbage_btime_proc" 2>&1)"; garbage_btime_lock_rc=$?
if [ "$garbage_btime_lock_rc" -eq 1 ] && [ ! -e "$garbage_btime_lock" ] \
    && printf '%s\n' "$garbage_btime_lock_out" | stdin_matches "cannot identify lock owner process"; then
    test_pass "dx-ai refuses lock acquisition when the boot-id stat fallback's btime field is garbage (dx-publication.sh:43)"
else
    test_fail "dx-ai refuses lock acquisition when the boot-id stat fallback's btime field is garbage (dx-publication.sh:43) (rc=$garbage_btime_lock_rc out='$garbage_btime_lock_out')"
fi

# --- Fable B3/WP3.5: dx-ai's publication lock reclaims an ownerless
# directory instead of waiting out the full timeout for an owner that will
# never appear, writes its owner record via tmp+mv (never a partially
# written file visible at the final path), and reclaims a stale owner by
# renaming the lock directory aside -- atomically, so a rename that loses
# (another attempt's leftover already occupies its own target) does not
# take over. `sleep` is stubbed to a no-op throughout so a timeout path
# still finishes fast. ---

# (a) An ownerless lock directory -- `mkdir "$lock"` succeeded but nothing
# ever wrote an owner file, e.g. a process killed between the two -- is
# reclaimed immediately and acquired, not waited out.
if (
    proc_root="$ai_fixture/lock-ownerless-proc"
    lock="$ai_fixture/ownerless.lock"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$" "$lock"
    printf '%s\n' 'aaaaaaaa-0000-0000-0000-000000000000' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    sleep() { :; }
    dx_ai_lock_acquire "$lock" "$proc_root" \
        && [ -f "$lock/owner" ] \
        && [ "$(cut -f2 "$lock/owner")" = "$$" ] \
        && [ "$(cut -f1 "$lock/owner")" = aaaaaaaa-0000-0000-0000-000000000000 ]
); then
    test_pass "dx-ai reclaims an ownerless lock directory and writes an owner file (WP3.5 a)"
else
    test_fail "dx-ai reclaims an ownerless lock directory and writes an owner file (WP3.5 a)"
fi
# The owner file above was written via a same-directory tmp file plus `mv`,
# never a direct redirect into "owner" itself -- observed through the mv()
# shim's own call log rather than by racing the write.
if grep -qE '(^| )[^ ]*/ownerless\.lock/owner\.tmp\.[0-9]+ [^ ]*/ownerless\.lock/owner$' "$mv_calls_log"; then
    test_pass "dx-ai writes the lock owner file via tmp + mv, never a direct write (WP3.5)"
else
    test_fail "dx-ai writes the lock owner file via tmp + mv, never a direct write (WP3.5)"
fi

# (b) A stale owner (its pid has no live process at all in this proc_root)
# is reclaimed by renaming the lock directory aside; when that rename loses
# -- its own reclaim target is already occupied, simulated here by
# pre-creating it -- this attempt must NOT take over. It keeps retrying
# (every retry loses the same way) until the timeout, leaving the original
# stale owner record and the lock directory exactly as they were.
if (
    proc_root="$ai_fixture/lock-reclaim-loses-proc"
    lock="$ai_fixture/reclaim-loses.lock"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$" "$lock"
    printf '%s\n' 'bbbbbbbb-1111-1111-1111-111111111111' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    printf 'bbbbbbbb-1111-1111-1111-111111111111\t99999\t1\n' > "$lock/owner"
    # The reclaim target dx_ai_lock_acquire will compute is the acquirer's
    # own pid -- in this sourced, non-subshelled call, $$ here is the same
    # $$ the function itself will see -- so this file blocks every attempt.
    : > "$lock.reclaim.$$"
    sleep() { :; }
    out="$(dx_ai_lock_acquire "$lock" "$proc_root" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && [ -d "$lock" ] \
        && [ "$(cat "$lock/owner")" = "$(printf 'bbbbbbbb-1111-1111-1111-111111111111\t99999\t1')" ] \
        && printf '%s\n' "$out" | stdin_matches "timed out"
); then
    test_pass "dx-ai does not take over a lock when its reclaim rename loses (WP3.5 b)"
else
    test_fail "dx-ai does not take over a lock when its reclaim rename loses (WP3.5 b)"
fi

# A stale owner whose reclaim does NOT lose (no colliding target) is
# acquired cleanly -- the success half of the same contract (b) exercises
# the failure half of.
if (
    proc_root="$ai_fixture/lock-stale-owner-proc"
    lock="$ai_fixture/stale-owner.lock"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$" "$lock"
    printf '%s\n' 'cccccccc-2222-2222-2222-222222222222' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    printf 'cccccccc-2222-2222-2222-222222222222\t99999\t1\n' > "$lock/owner"
    sleep() { :; }
    dx_ai_lock_acquire "$lock" "$proc_root" && [ "$(cut -f2 "$lock/owner")" = "$$" ]
); then
    test_pass "dx-ai reclaims a lock left by a dead process and acquires it (WP3.5)"
else
    test_fail "dx-ai reclaims a lock left by a dead process and acquires it (WP3.5)"
fi

# A genuinely live, same-boot owner is never reclaimed -- acquisition can
# only wait it out and time out, leaving its record untouched.
if (
    proc_root="$ai_fixture/lock-live-owner-proc"
    lock="$ai_fixture/live-owner.lock"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$" "$proc_root/424242" "$lock"
    printf '%s\n' 'dddddddd-3333-3333-3333-333333333333' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    printf '%s\n' '424242 (owner) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 999' > "$proc_root/424242/stat"
    printf 'dddddddd-3333-3333-3333-333333333333\t424242\t999\n' > "$lock/owner"
    sleep() { :; }
    out="$(dx_ai_lock_acquire "$lock" "$proc_root" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && [ "$(cat "$lock/owner")" = "$(printf 'dddddddd-3333-3333-3333-333333333333\t424242\t999')" ] \
        && printf '%s\n' "$out" | stdin_matches "timed out"
); then
    test_pass "dx-ai waits out a live owner's lock rather than stealing it (WP3.5)"
else
    test_fail "dx-ai waits out a live owner's lock rather than stealing it (WP3.5)"
fi

# A symlinked lock parent is refused outright (never even attempts mkdir).
if (
    proc_root="$ai_fixture/lock-symlink-parent-proc"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$" "$ai_fixture/symlink-parent-target"
    printf '%s\n' 'eeeeeeee-4444-4444-4444-444444444444' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    ln -s "$ai_fixture/symlink-parent-target" "$ai_fixture/symlink-parent"
    ! dx_ai_lock_acquire "$ai_fixture/symlink-parent/.lock" "$proc_root" 2>/dev/null
); then
    test_pass "dx-ai refuses a lock whose parent directory is a symlink (WP3.5)"
else
    test_fail "dx-ai refuses a lock whose parent directory is a symlink (WP3.5)"
fi

# A lock parent path already occupied by a plain file makes `mkdir -p` fail.
if (
    proc_root="$ai_fixture/lock-file-parent-proc"
    mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$"
    printf '%s\n' 'ffffffff-5555-5555-5555-555555555555' > "$proc_root/sys/kernel/random/boot_id"
    printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
    : > "$ai_fixture/file-parent"
    ! dx_ai_lock_acquire "$ai_fixture/file-parent/.lock" "$proc_root" 2>/dev/null
); then
    test_pass "dx-ai refuses a lock whose parent path is an existing plain file (WP3.5)"
else
    test_fail "dx-ai refuses a lock whose parent path is an existing plain file (WP3.5)"
fi

# Coverage (dx-publication.sh:82-84): `mkdir "$lock"` itself succeeds, but
# the owner.tmp write immediately after it does not -- e.g. a filesystem
# that denies the write once the directory exists. `mkdir "$lock"` only
# ever needs write+execute on $lock's PARENT (left alone here); a umask of
# 0200, set only around this one call, strips the OWNER's write bit from
# the directory `mkdir "$lock"` itself creates, so the very next write
# inside it -- the owner.tmp file -- fails EACCES for its own creator, with
# no shim and no race. Root ignores directory permission bits outright, so
# tests/run-coverage-linux.sh's isolated kcov image (which runs the WHOLE
# suite as root) needs the same setpriv drop to uid/gid 65534 that WP6.1
# (Astra F1, tests/test_persist_backup_select.sh) already established for
# exactly this reason; the script-file indirection below (rather than
# calling the sourced function directly, as every other case here does) is
# what lets setpriv change the effective uid at all, since a plain function
# call cannot.
ownertmp_parent="$ai_fixture/ownertmp-fail-parent"
ownertmp_proc="$ai_fixture/ownertmp-fail-proc"
mkdir -p "$ownertmp_parent" "$ownertmp_proc"
chmod 0777 "$ownertmp_parent" "$ownertmp_proc"
# $ai_fixture itself is mktemp -d's usual 0700 (root-owned in the kcov
# image) -- uid 65534 cannot even traverse INTO it to reach the two
# world-writable directories just below, regardless of their own mode.
# Execute-only (no read) is enough to reach a known child path without
# making the rest of $ai_fixture's contents listable.
chmod 0711 "$ai_fixture"
# The probe file itself lives under the world-traversable/writable
# $ownertmp_parent, not $ai_fixture -- uid 65534 needs to reach and read
# it too, not just write inside the lock.
ownertmp_probe="$ownertmp_parent/ownertmp-fail-probe.sh"
cat > "$ownertmp_probe" <<'PROBE'
#!/bin/bash
set -uo pipefail
proc_root="$1"; lock="$2"; container_dir="$3"
# shellcheck disable=SC1091
source "$container_dir/scripts/lib/dx-ai-lock.sh"
mkdir -p "$proc_root/sys/kernel/random" "$proc_root/$$"
printf '%s\n' '12121212-3434-3434-3434-343434343434' > "$proc_root/sys/kernel/random/boot_id"
printf '%s\n' "$$ (probe) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
umask 0200
dx_ai_lock_acquire "$lock" "$proc_root"
PROBE
chmod 0644 "$ownertmp_probe"
ownertmp_lock="$ownertmp_parent/ownertmp-fail.lock"
ownertmp_stderr="$ai_fixture/ownertmp-fail-stderr.log"
ownertmp_assert() {
    if [ "$ownertmp_rc" -eq 1 ] && [ ! -e "$ownertmp_lock" ] \
        && grep -q '^Error: could not record the publication lock owner' "$ownertmp_stderr"; then
        test_pass "WP5.2: an owner-tmp write failure is reported as an Error and the lock directory is removed (dx-publication.sh:82-84)"
    else
        test_fail "WP5.2: an owner-tmp write failure is reported as an Error and the lock directory is removed (dx-publication.sh:82-84) (rc=$ownertmp_rc stderr='$(cat "$ownertmp_stderr" 2>/dev/null)')"
    fi
}
if [ "$(id -u)" -eq 0 ]; then
    if command -v setpriv > /dev/null 2>&1; then
        setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp bash "$ownertmp_probe" "$ownertmp_proc" "$ownertmp_lock" "$CONTAINER_DIR" > /dev/null 2> "$ownertmp_stderr"
        ownertmp_rc=$?
        ownertmp_assert
    else
        test_skip "WP5.2: an owner-tmp write failure is reported as an Error and the lock directory is removed (running as root without setpriv: mode bits do not deny root; dx-publication.sh:82-84)"
    fi
else
    bash "$ownertmp_probe" "$ownertmp_proc" "$ownertmp_lock" "$CONTAINER_DIR" > /dev/null 2> "$ownertmp_stderr"
    ownertmp_rc=$?
    ownertmp_assert
fi

# --- F8: a successful sourced dx_ai_main must release its lock and clear its EXIT trap ---
# Reuses the mv() wrapper above (still active) to translate publish's `mv -Tf`
# for hosts whose real mv lacks GNU's -T.
f8_published="$ai_fixture/f8-published"; f8_state="$ai_fixture/f8-state"
mkdir -p "$f8_published/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$f8_published/pins/agy.json"
printf '%s\n' fixture > "$f8_published/flake.nix"
printf '%s\n' fixture > "$f8_published/flake.lock"

# Stub every function that would otherwise touch the real Nix store or /persist,
# so this exercises dx_ai_main's own control flow (locking, staging, publication)
# rather than the network/build/credential side effects those functions own.
dx_ai_update_flake() { :; }
dx_ai_ensure_cached() { :; }
dx_ai_install_profile() {
    local stage="$1" tool
    mkdir -p "$stage/profile/bin"
    for tool in codex gemini claude agy herdr opencode; do printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"; done
}
dx_ai_setup_credentials() { :; }
dx_ai_ensure_keyring() { :; }
dx_ai_verify() { :; }
# The coverage container runs every test as root; stub id so this probe
# exercises dx_ai_main's lock lifecycle (what F8 is about) rather than
# tripping its unrelated "run as dx, not root" guard.
id() { printf '%s\n' 1000; }
# The host running this unit test may not expose Linux /proc. Provide the
# identity that a real guest supplies so F8 keeps testing lock release rather
# than the R5 fail-closed guard above.
boot_id() { printf '%s\n' test-boot-id; }
process_start() { printf '%s\n' 123; }
# The host running this unit test may report a Darwin-style uname -m (e.g.
# "arm64") that the shared guest-system helper's Linux-only mapping does not
# recognize -- production dx-ai.sh only ever runs inside the Linux guest.
# Stub it to the identity a real guest supplies, same reasoning as the two
# stubs above.
dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }

f8_path_before="$PATH"
DX_AI_BOOTSTRAP_ROOT="$f8_published" DX_AI_STATE_ROOT="$f8_state" dx_ai_main
f8_main_rc=$?
f8_trap_after="$(trap -p EXIT)"
PATH="$f8_path_before"
# dx_ai_main's own EXIT trap replaced the fixture-cleanup trap installed above;
# reinstall it now that the probe of its post-call state is complete.
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT
# Restore the real functions the block above stubbed out.
# shellcheck source=/dev/null
source "$AI_SCRIPT"
unset -f mv id

if [ "$f8_main_rc" -eq 0 ] && [ ! -d "$f8_state/.lock" ] && [ -z "$f8_trap_after" ]; then
    test_pass "a successful sourced dx_ai_main releases its lock and clears its EXIT trap"
else
    test_fail "a successful sourced dx_ai_main releases its lock and clears its EXIT trap"
fi

# dx_ai_main must call the cache guard AFTER updating the flake and BEFORE
# installing the profile -- a miss must never reach nix profile add.
update_line="$(grep -n 'dx_ai_update_flake "\$stage"' "$AI_SCRIPT" | head -1 | cut -d: -f1)"
ensure_line="$(grep -n 'dx_ai_ensure_cached "\$stage" "\$state"' "$AI_SCRIPT" | head -1 | cut -d: -f1)"
install_line="$(grep -n 'dx_ai_install_profile "\$stage"' "$AI_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$update_line" ] && [ -n "$ensure_line" ] && [ -n "$install_line" ] \
    && [ "$update_line" -lt "$ensure_line" ] && [ "$ensure_line" -lt "$install_line" ]; then
    test_pass "dx_ai_main runs the cache guard after the flake update and before the profile install"
else
    test_fail "dx_ai_main runs the cache guard after the flake update and before the profile install"
fi

# --- F16: a real (unstubbed) dx_ai_ensure_cached refusal, exercised through
# dx_ai_main end to end, must leave the published AI generation untouched
# and never reach dx_ai_install_profile/nix profile add. ---
f16_published="$ai_fixture/f16-published"; f16_state="$ai_fixture/f16-state"
mkdir -p "$f16_published/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$f16_published/pins/agy.json"
printf '%s\n' fixture > "$f16_published/flake.nix"
printf '%s\n' fixture > "$f16_published/flake.lock"

dx_ai_update_flake() { :; }
dx_ai_install_profile() { test_fail "a refused dx_ai_main must never reach dx_ai_install_profile"; }
dx_ai_setup_credentials() { :; }
dx_ai_ensure_keyring() { :; }
dx_ai_verify() { :; }
id() { printf '%s\n' 1000; }
boot_id() { printf '%s\n' test-boot-id; }
process_start() { printf '%s\n' 123; }
dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }
nix() {
    case "$*" in
        "build --dry-run --extra-experimental-features "*"#ai-tools")
            printf 'these 1 derivations will be built:\n  /nix/store/dddd10000000000000000000000001-codex-core-0.157.0.drv\n' >&2
            return 0
            ;;
        *) command nix "$@" ;;
    esac
}

f16_path_before="$PATH"
DX_AI_BOOTSTRAP_ROOT="$f16_published" DX_AI_STATE_ROOT="$f16_state" dx_ai_main
f16_main_rc=$?
PATH="$f16_path_before"
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT
unset -f nix id
# shellcheck source=/dev/null
source "$AI_SCRIPT"

if [ "$f16_main_rc" -ne 0 ]; then
    test_pass "a real cache-miss refusal makes dx_ai_main exit non-zero end to end"
else
    test_fail "a real cache-miss refusal makes dx_ai_main exit non-zero end to end"
fi
if [ ! -e "$f16_state/current" ] && [ ! -d "$f16_state/.lock" ]; then
    test_pass "a real cache-miss refusal publishes no AI generation and releases its lock"
else
    test_fail "a real cache-miss refusal publishes no AI generation and releases its lock"
fi

# --- Fable B4/WP3.6: dx-ai must not fail silently, and must reclaim orphaned
# generation stages. Reuses the dx_ai_boot_id/dx_ai_process_start/
# dx_guest_resolve_system stubs still active from F16 above. ---
id() { printf '%s\n' 1000; }

# RED (1): a staged generation missing one of its own declared tools'
# executables (dx_ai_stage_generation always records the complete current
# DX_AI_TOOLS in .tools-manifest) must fail loudly, naming the missing
# path -- not just exit 1 with nothing on stderr, which is what
# dx_ai_validate_publish_generation's silent `return 1` used to do after a
# successful, possibly multi-minute `nix profile add`.
missingtool_published="$ai_fixture/missingtool-published"; missingtool_state="$ai_fixture/missingtool-state"
mkdir -p "$missingtool_published/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$missingtool_published/pins/agy.json"
printf '%s\n' fixture > "$missingtool_published/flake.nix"
printf '%s\n' fixture > "$missingtool_published/flake.lock"
dx_ai_update_flake() { :; }
dx_ai_ensure_cached() { :; }
dx_ai_install_profile() {
    local stage="$1" tool
    mkdir -p "$stage/profile/bin"
    # Deliberately omits opencode, one of DX_AI_TOOLS.
    for tool in codex gemini claude agy herdr; do
        printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"
    done
}
dx_ai_setup_credentials() { :; }
dx_ai_ensure_keyring() { :; }
dx_ai_verify() { :; }
missingtool_err="$(DX_AI_BOOTSTRAP_ROOT="$missingtool_published" DX_AI_STATE_ROOT="$missingtool_state" dx_ai_main 2>&1 1>/dev/null)"
missingtool_rc=$?
if [ "$missingtool_rc" -ne 0 ] \
    && printf '%s\n' "$missingtool_err" | stdin_matches '^Error:' \
    && printf '%s\n' "$missingtool_err" | stdin_matches 'profile/bin/opencode'; then
    test_pass "a staged generation missing a declared tool's executable fails loudly with its path (WP3.6 RED 1)"
else
    test_fail "a staged generation missing a declared tool's executable fails loudly with its path (WP3.6 RED 1)"
fi

# RED (2): dx_ai_collect_generations must also remove orphaned .staging-*
# stages -- bash's bare `*` glob never matches a dot-name, so before this
# fix a killed run's stage was never collected, and its profile/-*-link
# pinned a full closure under /nix/var/nix/gcroots/auto forever.
gc_state="$ai_fixture/gc-state"
mkdir -p "$gc_state/generations/current-gen" "$gc_state/generations/predecessor-gen" "$gc_state/generations/.staging-old"
ln -s /nix/store/x "$gc_state/generations/.staging-old/profile"
dx_ai_collect_generations "$gc_state" current-gen predecessor-gen
if [ ! -e "$gc_state/generations/.staging-old" ] \
    && [ -d "$gc_state/generations/current-gen" ] \
    && [ -d "$gc_state/generations/predecessor-gen" ]; then
    test_pass "dx_ai_collect_generations removes an orphaned .staging-* stage (WP3.6 RED 2)"
else
    test_fail "dx_ai_collect_generations removes an orphaned .staging-* stage (WP3.6 RED 2)"
fi

# RED (3): whichever step fails -- staging itself, the flake update, or the
# profile install -- dx_ai_main must still release the lock and discard any
# in-flight stage. Before dx_ai_run_locked existed this was never asserted;
# only a successful run's release was.
wp36_seed_published() {
    local root="$1"
    mkdir -p "$root/pins"
    printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$root/pins/agy.json"
    printf '%s\n' fixture > "$root/flake.nix"
    printf '%s\n' fixture > "$root/flake.lock"
}

stagefail_published="$ai_fixture/stagefail-published"; stagefail_state="$ai_fixture/stagefail-state"
wp36_seed_published "$stagefail_published"
mkdir -p "$stagefail_state"
ln -s /nonexistent "$stagefail_state/generations"
DX_AI_BOOTSTRAP_ROOT="$stagefail_published" DX_AI_STATE_ROOT="$stagefail_state" dx_ai_main >/dev/null 2>&1
stagefail_rc=$?
if [ "$stagefail_rc" -ne 0 ] && [ ! -d "$stagefail_state/.lock" ]; then
    test_pass "a staging failure still releases dx-ai's lock (WP3.6 RED 3)"
else
    test_fail "a staging failure still releases dx-ai's lock (WP3.6 RED 3)"
fi

updatefail_published="$ai_fixture/updatefail-published"; updatefail_state="$ai_fixture/updatefail-state"
wp36_seed_published "$updatefail_published"
dx_ai_update_flake() { return 1; }
DX_AI_BOOTSTRAP_ROOT="$updatefail_published" DX_AI_STATE_ROOT="$updatefail_state" dx_ai_main >/dev/null 2>&1
updatefail_rc=$?
if [ "$updatefail_rc" -ne 0 ] \
    && [ ! -d "$updatefail_state/.lock" ] \
    && [ -z "$(find "$updatefail_state/generations" -maxdepth 1 -name '.staging-*' 2>/dev/null)" ]; then
    test_pass "a flake-update failure still releases the lock and discards the stage (WP3.6 RED 3)"
else
    test_fail "a flake-update failure still releases the lock and discards the stage (WP3.6 RED 3)"
fi

installfail_published="$ai_fixture/installfail-published"; installfail_state="$ai_fixture/installfail-state"
wp36_seed_published "$installfail_published"
dx_ai_update_flake() { :; }
dx_ai_ensure_cached() { :; }
dx_ai_install_profile() { return 1; }
DX_AI_BOOTSTRAP_ROOT="$installfail_published" DX_AI_STATE_ROOT="$installfail_state" dx_ai_main >/dev/null 2>&1
installfail_rc=$?
if [ "$installfail_rc" -ne 0 ] \
    && [ ! -d "$installfail_state/.lock" ] \
    && [ -z "$(find "$installfail_state/generations" -maxdepth 1 -name '.staging-*' 2>/dev/null)" ]; then
    test_pass "a profile-install failure still releases the lock and discards the stage (WP3.6 RED 3)"
else
    test_fail "a profile-install failure still releases the lock and discards the stage (WP3.6 RED 3)"
fi

unset -f id dx_ai_update_flake dx_ai_ensure_cached dx_ai_install_profile dx_ai_setup_credentials dx_ai_ensure_keyring dx_ai_verify
# shellcheck source=/dev/null
source "$AI_SCRIPT"
dx_ai_load_lock
boot_id() { printf '%s\n' test-boot-id; }
process_start() { printf '%s\n' 123; }
dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }

# --- F15: --supports is a silent, exact-arity capability probe ---
if out="$(dx_ai_main --supports herdr)" && [ -z "$out" ]; then
    test_pass "--supports <tool> for a known tool exits 0 with no stdout"
else
    test_fail "--supports <tool> for a known tool exits 0 with no stdout"
fi

if out="$(dx_ai_main --supports opencode)" && [ -z "$out" ]; then
    test_pass "--supports opencode exits 0 with no stdout"
else
    test_fail "--supports opencode exits 0 with no stdout"
fi

out="$(dx_ai_main --supports nonexistent-tool)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    test_pass "--supports <tool> for an unknown tool exits 1 with no stdout"
else
    test_fail "--supports <tool> for an unknown tool exits 1 with no stdout"
fi

dx_ai_main --supports >/dev/null 2>&1
if [ "$?" -eq 64 ]; then
    test_pass "--supports with no tool name is a usage error (exit 64)"
else
    test_fail "--supports with no tool name is a usage error (exit 64)"
fi

dx_ai_main --supports herdr junk extra >/dev/null 2>&1
if [ "$?" -eq 64 ]; then
    test_pass "--supports rejects trailing arguments (exit 64)"
else
    test_fail "--supports rejects trailing arguments (exit 64)"
fi

# Herdr agent integrations install hook files into the agent config directories
# dx-ai already owns, so dx-ai re-asserts them for every published generation.
# HERDR_BIN_PATH is the same injection seam dx-herdr-navigate.sh uses.
herdr_fixture="$ai_fixture/herdr"
mkdir -p "$herdr_fixture"
herdr_stub="$herdr_fixture/herdr"
cat > "$herdr_stub" <<'HERDR_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DXE_HERDR_STUB_LOG"
case "$1 ${2:-}" in
    "integration status")
        [ "${DXE_HERDR_STUB_STATUS_RC:-0}" -eq 0 ] || exit "$DXE_HERDR_STUB_STATUS_RC"
        if [ "${3:-}" = --outdated-only ]; then
            printf '%s' "${DXE_HERDR_STUB_OUTDATED:-}"
        else
            printf '%s' "${DXE_HERDR_STUB_STATUS:-}"
        fi
        ;;
    "integration install") exit "${DXE_HERDR_STUB_INSTALL_RC:-0}" ;;
esac
HERDR_STUB
chmod 0755 "$herdr_stub"

herdr_stub_log="$herdr_fixture/log"
run_herdr_integrations() {
    : > "$herdr_stub_log"
    (
        export DXE_HERDR_STUB_LOG="$herdr_stub_log"
        export DXE_HERDR_STUB_STATUS="${1:-}"
        export DXE_HERDR_STUB_OUTDATED="${2:-}"
        export DXE_HERDR_STUB_INSTALL_RC="${3:-0}"
        export DXE_HERDR_STUB_STATUS_RC="${4:-0}"
        HERDR_BIN_PATH="$herdr_stub" dx_ai_install_herdr_integrations
    )
}
herdr_installed_targets() {
    sed -n 's/^integration install //p' "$herdr_stub_log" | sort | tr '\n' ' '
}

# Transcribed from real `herdr integration status` output (0.8.0), not invented.
# An up-to-date integration reports `current (vN)`; the earlier fixture used
# `installed`, a word Herdr never emits, so the "does not reinstall" assertion
# below passed against a format the real tool does not produce -- and dx-ai
# reinstalled every healthy integration on every run in the field.
all_missing="claude: not installed (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: not installed (/home/dx/.codex/herdr-agent-state.sh)
cursor: not installed (/home/dx/.cursor/herdr-agent-state.sh)
opencode: not installed (/home/dx/.config/opencode/plugins/herdr-agent-state.js)"
all_current="claude: current (v7) (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)
opencode: current (v7) (/home/dx/.config/opencode/plugins/herdr-agent-state.js)"
all_outdated="claude: outdated (v6) (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)
opencode: current (v7) (/home/dx/.config/opencode/plugins/herdr-agent-state.js)"

if run_herdr_integrations "$all_missing" "" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "claude codex opencode " ]; then
    test_pass "dx-ai installs the missing Herdr integrations for the agents it manages"
else
    test_fail "dx-ai installs the missing Herdr integrations for the agents it manages"
fi

if run_herdr_integrations "$all_missing" "" >/dev/null 2>&1 \
    && ! grep -q 'integration install cursor' "$herdr_stub_log"; then
    test_pass "dx-ai leaves Herdr integrations for unmanaged agents alone"
else
    test_fail "dx-ai leaves Herdr integrations for unmanaged agents alone"
fi

if run_herdr_integrations "$all_current" "" >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "a repeated dx-ai run reinstalls no current Herdr integration"
else
    test_fail "a repeated dx-ai run reinstalls no current Herdr integration"
fi

if run_herdr_integrations "$all_current" "codex: outdated (/home/dx/.codex/herdr-agent-state.sh)" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "codex " ]; then
    test_pass "dx-ai refreshes a Herdr integration that upstream reports outdated"
else
    test_fail "dx-ai refreshes a Herdr integration that upstream reports outdated"
fi

# The same signal in the full listing rather than --outdated-only.
if run_herdr_integrations "$all_outdated" "" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "claude " ]; then
    test_pass "dx-ai refreshes an integration the status listing marks outdated"
else
    test_fail "dx-ai refreshes an integration the status listing marks outdated"
fi

# opencode-specific: when opencode is outdated, dx-ai triggers its reinstall
all_opencode_outdated="claude: current (v7) (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)
opencode: outdated (v6) (/home/dx/.config/opencode/plugins/herdr-agent-state.js)"
if run_herdr_integrations "$all_opencode_outdated" "" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "opencode " ]; then
    test_pass "dx-ai refreshes the opencode Herdr integration when it is outdated"
else
    test_fail "dx-ai refreshes the opencode Herdr integration when it is outdated"
fi

# An unrecognised state must not put dx-ai into a reinstall loop.
if run_herdr_integrations "claude: bewildered (v9) (/home/dx/.claude/hooks/x.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)
opencode: current (v7) (/home/dx/.config/opencode/plugins/herdr-agent-state.js)" "" >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "an unrecognised Herdr integration state is left alone, not reinstalled"
else
    test_fail "an unrecognised Herdr integration state is left alone, not reinstalled"
fi

if (
    export DXE_HERDR_STUB_LOG="$herdr_stub_log"
    PATH=/nonexistent HERDR_BIN_PATH='' dx_ai_install_herdr_integrations
) >/dev/null 2>&1; then
    test_pass "dx-ai treats an absent Herdr as a skip, not a failure"
else
    test_fail "dx-ai treats an absent Herdr as a skip, not a failure"
fi

if run_herdr_integrations "$all_missing" "" 1 >/dev/null 2>&1; then
    test_pass "a failed Herdr integration install does not fail the AI update"
else
    test_fail "a failed Herdr integration install does not fail the AI update"
fi

if run_herdr_integrations "" "" 0 1 >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "an unreadable Herdr integration status installs nothing and does not fail"
else
    test_fail "an unreadable Herdr integration status installs nothing and does not fail"
fi

# Fable D7 item 5: dx-ai's main flow calling dx_ai_install_herdr_integrations
# as a bare statement (never `|| return`) used to be asserted by grepping
# dx-ai.sh's own source text for that exact call shape. Proven behaviourally
# instead: stub dx_ai_install_herdr_integrations itself to fail loudly, run
# dx_ai_main end to end (the same F8-style stub set -- id/update_flake/
# ensure_cached/install_profile/credentials/keyring/verify all trivially
# succeeding, so this isolates dx_ai_main's own control flow around the
# Herdr step), and require BOTH that the stub really ran (a marker file, so
# a call site that stopped invoking the function at all could never pass
# vacuously) and that dx_ai_main still exits 0 -- the real property "an
# optional Herdr integration never fails the update" names, regardless of
# whether the call site happens to spell its guard as a bare statement or
# something else entirely.
herdrfail_published="$ai_fixture/herdrfail-published"; herdrfail_state="$ai_fixture/herdrfail-state"
wp36_seed_published "$herdrfail_published"
herdrfail_marker="$ai_fixture/herdrfail-called"
rm -f "$herdrfail_marker"
dx_ai_update_flake() { :; }
dx_ai_ensure_cached() { :; }
dx_ai_install_profile() {
    local stage="$1" tool
    mkdir -p "$stage/profile/bin"
    for tool in codex gemini claude agy herdr opencode; do printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"; done
}
dx_ai_setup_credentials() { :; }
dx_ai_ensure_keyring() { :; }
dx_ai_verify() { :; }
dx_ai_install_herdr_integrations() { touch "$herdrfail_marker"; return 1; }
id() { printf '%s\n' 1000; }
# dx_ai_main_update's own real publish step below this uses `mv -Tf`
# (GNU's --no-target-directory), which this suite's macOS/BSD `mv` rejects
# outright -- the same translation the F8 fixture above already needed and
# left this file's own comment on; unset again below alongside this case's
# other stubs, exactly like F8 does.
mv() { case "${1:-}" in -Tf) shift; rm -f "$2"; command mv -f "$1" "$2" ;; -T) shift; { [ ! -e "$2" ] && [ ! -L "$2" ]; } && command mv "$1" "$2" ;; *) command mv "$@" ;; esac; }

DX_AI_BOOTSTRAP_ROOT="$herdrfail_published" DX_AI_STATE_ROOT="$herdrfail_state" dx_ai_main >/dev/null 2>&1
herdrfail_rc=$?
unset -f id mv dx_ai_update_flake dx_ai_ensure_cached dx_ai_install_profile dx_ai_setup_credentials dx_ai_ensure_keyring dx_ai_verify dx_ai_install_herdr_integrations
# shellcheck source=/dev/null
source "$AI_SCRIPT"
boot_id() { printf '%s\n' test-boot-id; }
process_start() { printf '%s\n' 123; }
dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }

if [ "$herdrfail_rc" -eq 0 ] && [ -f "$herdrfail_marker" ]; then
    test_pass "a failed Herdr integration step (dx_ai_install_herdr_integrations) never fails an otherwise successful dx_ai_main"
else
    test_fail "a failed Herdr integration step (dx_ai_install_herdr_integrations) never fails an otherwise successful dx_ai_main (rc=$herdrfail_rc marker=$([ -f "$herdrfail_marker" ] && echo present || echo absent))"
fi

# --- dx_ai_setup_credentials: OpenCode persistence is wired through the
# shared helper, and the pre-existing four (.gemini/.claude/.claude.json/
# .codex) get the ln -sfnT hardening back. dx-ai runs as dx and must never
# touch the real $HOME or /persist, so every case below is a fully isolated
# fixture passed as the function's two explicit arguments.
#
# Production runs in the Linux guest, where ln supports -T. This repository's
# macOS bash-3.2 job has no such -T (BSD ln rejects the option outright), so
# translate that one option for the functional (non-hardening) cases below --
# they are about the symlinks getting created and staying stable, not about
# -T's specific real-directory refusal, which the dedicated, unshimmed
# hardening case further down tests directly.
creds_ln_shim() { ln() { if [ "${1:-}" = -sfnT ]; then command ln -sfn "$2" "$3"; else command ln "$@"; fi; }; }
creds_ln_unshim() { unset -f ln; }

creds_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-test.XXXXXX")"
creds_fixture="$(cd "$creds_fixture" && pwd -P)"
trap 'rm -rf "$creds_fixture"' EXIT
creds_persist="$creds_fixture/persist/home/dx"
creds_home="$creds_fixture/home/dx"
mkdir -p "$creds_persist" "$creds_home"
creds_ln_shim
if dx_ai_setup_credentials "$creds_persist" "$creds_home"; then
    test_pass "dx_ai_setup_credentials succeeds against a fresh fixture"
else
    test_fail "dx_ai_setup_credentials succeeds against a fresh fixture"
fi
creds_ln_unshim
if [ -L "$creds_home/.config/opencode" ] \
    && [ "$(readlink "$creds_home/.config/opencode")" = "$creds_persist/.config/opencode" ]; then
    test_pass "dx_ai_setup_credentials symlinks ~/.config/opencode to persist"
else
    test_fail "dx_ai_setup_credentials symlinks ~/.config/opencode to persist"
fi
if [ -L "$creds_home/.local/share/opencode" ] \
    && [ "$(readlink "$creds_home/.local/share/opencode")" = "$creds_persist/.local/share/opencode" ]; then
    test_pass "dx_ai_setup_credentials symlinks ~/.local/share/opencode to persist"
else
    test_fail "dx_ai_setup_credentials symlinks ~/.local/share/opencode to persist"
fi
for legacy_link in .gemini .claude .codex; do
    if [ -L "$creds_home/$legacy_link" ] && [ "$(readlink "$creds_home/$legacy_link")" = "$creds_persist/$legacy_link" ]; then
        test_pass "dx_ai_setup_credentials symlinks ~/$legacy_link to persist"
    else
        test_fail "dx_ai_setup_credentials symlinks ~/$legacy_link to persist"
    fi
done
if [ -L "$creds_home/.claude.json" ] && [ "$(readlink "$creds_home/.claude.json")" = "$creds_persist/.claude.json" ]; then
    test_pass "dx_ai_setup_credentials symlinks ~/.claude.json to persist"
else
    test_fail "dx_ai_setup_credentials symlinks ~/.claude.json to persist"
fi
rm -rf "$creds_fixture"

# dx_ai_load_opencode_persistence's second and third candidates (the
# Home-Manager-installed copy at ~/.local/lib/dx/, and the bootstrap-volume
# fallback) are never reached by the tests above: $AI_SCRIPT's own colocated
# lib/ sibling (candidate 1) always resolves first when dx-ai.sh is sourced
# straight from the guest source tree, as every test in this file does. Each
# case below runs dx-ai.sh from a standalone copy with no lib/ sibling, in
# its own fresh bash process (a function's "already loaded" fast path would
# otherwise carry over from this process's own earlier sourcing), so
# candidate 1 always misses and the intended candidate is the first that can.
loader_fixture="$ai_fixture/loader"
mkdir -p "$loader_fixture/bin/lib"
cp "$AI_SCRIPT" "$loader_fixture/bin/dx-ai.sh"
# dx-ai.sh eagerly loads the generation/pin/cache-policy/post-install
# libraries as soon as it is sourced (Fable B7), regardless of what this
# block is actually testing (dx_ai_load_opencode_persistence's own candidate
# resolution) -- colocate them here so every case below still resolves those
# via candidate 1, leaving only dx-opencode-persistence.sh itself absent
# from this standalone copy's lib/ sibling.
for loader_fixture_eager_lib in dx-ai-loader.sh dx-ai-generation.sh dx-ai-pin.sh dx-ai-cache-policy.sh dx-ai-post-install.sh; do
    cp "$CONTAINER_DIR/scripts/lib/$loader_fixture_eager_lib" "$loader_fixture/bin/lib/$loader_fixture_eager_lib"
done

home_candidate="$loader_fixture/home-candidate"
mkdir -p "$home_candidate/.local/lib/dx"
cp "$CONTAINER_DIR/scripts/lib/dx-opencode-persistence.sh" "$home_candidate/.local/lib/dx/dx-opencode-persistence.sh"
# dx-opencode-persistence.sh itself now eagerly loads dx-persist-relocate.sh
# (Fable B9) via its own sibling-relative candidate 1, which resolves
# wherever dx-opencode-persistence.sh itself was just found -- colocate it
# alongside, the same way the outer loader_fixture_eager_lib loop above
# colocates dx-ai.sh's own eager libraries.
cp "$CONTAINER_DIR/scripts/lib/dx-persist-relocate.sh" "$home_candidate/.local/lib/dx/dx-persist-relocate.sh"
if HOME="$home_candidate" DX_AI_BOOTSTRAP_ROOT="$loader_fixture/no-such-bootstrap" \
    bash -c "source '$loader_fixture/bin/dx-ai.sh'; dx_ai_load_opencode_persistence && declare -F dx_ai_opencode_persistence >/dev/null"; then
    test_pass "dx_ai_load_opencode_persistence resolves the Home-Manager-installed copy (candidate 2)"
else
    test_fail "dx_ai_load_opencode_persistence resolves the Home-Manager-installed copy (candidate 2)"
fi

bootstrap_candidate="$loader_fixture/bootstrap-candidate"
mkdir -p "$bootstrap_candidate/scripts/lib"
cp "$CONTAINER_DIR/scripts/lib/dx-opencode-persistence.sh" "$bootstrap_candidate/scripts/lib/dx-opencode-persistence.sh"
cp "$CONTAINER_DIR/scripts/lib/dx-persist-relocate.sh" "$bootstrap_candidate/scripts/lib/dx-persist-relocate.sh"
if HOME="$loader_fixture/no-such-home" DX_AI_BOOTSTRAP_ROOT="$bootstrap_candidate" \
    bash -c "source '$loader_fixture/bin/dx-ai.sh'; dx_ai_load_opencode_persistence && declare -F dx_ai_opencode_persistence >/dev/null"; then
    test_pass "dx_ai_load_opencode_persistence resolves the bootstrap-volume fallback (candidate 3)"
else
    test_fail "dx_ai_load_opencode_persistence resolves the bootstrap-volume fallback (candidate 3)"
fi

if HOME="$loader_fixture/no-such-home" DX_AI_BOOTSTRAP_ROOT="$loader_fixture/no-such-bootstrap" \
    bash -c "source '$loader_fixture/bin/dx-ai.sh'; dx_ai_load_opencode_persistence" >/dev/null 2>&1; then
    test_fail "dx_ai_load_opencode_persistence fails closed when no candidate resolves"
else
    test_pass "dx_ai_load_opencode_persistence fails closed when no candidate resolves"
fi
rm -rf "$loader_fixture"

# Fable B7: dx_ai_load_library (scripts/lib/dx-ai-loader.sh) is the shared
# body every one of dx-ai.sh's/dx-keyring.sh's loaders now delegates to
# (dx_ai_load_opencode_persistence above is one such delegator). Exercise
# its own candidate order directly, against a disposable probe function/
# library pair, rather than only through one caller: a real entry-point
# FILE is needed (not an inline `bash -c` string) so BASH_SOURCE[1] --
# candidate 1's "the calling script's own directory" -- names a real path.
shared_loader_fixture="$ai_fixture/shared-loader"
shared_loader_entry="$shared_loader_fixture/entry"
mkdir -p "$shared_loader_entry"
cat > "$shared_loader_entry/probe.sh" <<PROBE
#!/bin/bash
# shellcheck source=/dev/null
source "$CONTAINER_DIR/scripts/lib/dx-ai-loader.sh"
dx_ai_load_library dx_shared_loader_fixture_probe dx-shared-loader-fixture.sh
PROBE
chmod +x "$shared_loader_entry/probe.sh"
shared_loader_lib_content='dx_shared_loader_fixture_probe() { :; }'

shared_loader_home_candidate="$shared_loader_fixture/home-candidate"
mkdir -p "$shared_loader_home_candidate/.local/lib/dx"
printf '%s\n' "$shared_loader_lib_content" > "$shared_loader_home_candidate/.local/lib/dx/dx-shared-loader-fixture.sh"
if HOME="$shared_loader_home_candidate" DX_AI_BOOTSTRAP_ROOT="$shared_loader_fixture/no-such-bootstrap" \
    "$shared_loader_entry/probe.sh"; then
    test_pass "dx_ai_load_library resolves the Home-Manager-installed copy (candidate 2)"
else
    test_fail "dx_ai_load_library resolves the Home-Manager-installed copy (candidate 2)"
fi

shared_loader_bootstrap_candidate="$shared_loader_fixture/bootstrap-candidate"
mkdir -p "$shared_loader_bootstrap_candidate/scripts/lib"
printf '%s\n' "$shared_loader_lib_content" > "$shared_loader_bootstrap_candidate/scripts/lib/dx-shared-loader-fixture.sh"
if HOME="$shared_loader_fixture/no-such-home" DX_AI_BOOTSTRAP_ROOT="$shared_loader_bootstrap_candidate" \
    "$shared_loader_entry/probe.sh"; then
    test_pass "dx_ai_load_library resolves the bootstrap-volume fallback (candidate 3)"
else
    test_fail "dx_ai_load_library resolves the bootstrap-volume fallback (candidate 3)"
fi

if HOME="$shared_loader_fixture/no-such-home" DX_AI_BOOTSTRAP_ROOT="$shared_loader_fixture/no-such-bootstrap" \
    "$shared_loader_entry/probe.sh" >/dev/null 2>&1; then
    test_fail "dx_ai_load_library fails closed when no candidate resolves"
else
    test_pass "dx_ai_load_library fails closed when no candidate resolves"
fi
rm -rf "$shared_loader_fixture"

# Repeated setup (a second guest activation, or a second dx-ai run) must be
# side-effect-free once every link is already correct.
idempotent_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-idempotent.XXXXXX")"
idempotent_fixture="$(cd "$idempotent_fixture" && pwd -P)"
idempotent_persist="$idempotent_fixture/persist/home/dx"
idempotent_home="$idempotent_fixture/home/dx"
mkdir -p "$idempotent_persist" "$idempotent_home"
creds_ln_shim
dx_ai_setup_credentials "$idempotent_persist" "$idempotent_home" >/dev/null
before_claude_link="$(readlink "$idempotent_home/.claude")"
before_opencode_link="$(readlink "$idempotent_home/.config/opencode")"
printf '%s\n' marker > "$idempotent_persist/.claude/marker"
if dx_ai_setup_credentials "$idempotent_persist" "$idempotent_home" \
    && [ "$(readlink "$idempotent_home/.claude")" = "$before_claude_link" ] \
    && [ "$(readlink "$idempotent_home/.config/opencode")" = "$before_opencode_link" ] \
    && [ "$(cat "$idempotent_persist/.claude/marker")" = marker ]; then
    test_pass "a repeated dx_ai_setup_credentials run is side-effect-free"
else
    test_fail "a repeated dx_ai_setup_credentials run is side-effect-free"
fi
creds_ln_unshim
rm -rf "$idempotent_fixture"

# A symlinked persist ancestor must be refused end to end through the wired
# helper, exactly as tested directly against the helper in
# test_sourceable_coverage.sh -- this proves dx_ai_setup_credentials actually
# calls it and propagates its failure rather than proceeding regardless.
unsafe_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-unsafe.XXXXXX")"
unsafe_fixture="$(cd "$unsafe_fixture" && pwd -P)"
unsafe_outside="$unsafe_fixture/outside"; unsafe_home="$unsafe_fixture/home/dx"
mkdir -p "$unsafe_outside" "$unsafe_home"
ln -s "$unsafe_outside" "$unsafe_fixture/persist"
if dx_ai_setup_credentials "$unsafe_fixture/persist/home/dx" "$unsafe_home" >/dev/null 2>&1; then
    test_fail "unsafe persistent ancestry is rejected without traversal"
else
    test_pass "unsafe persistent ancestry is rejected without traversal"
fi
if [ ! -e "$unsafe_outside/home" ]; then
    test_pass "unsafe persistent ancestry remains untouched"
else
    test_fail "unsafe persistent ancestry remains untouched"
fi
rm -rf "$unsafe_fixture"

# --- ln -sfnT hardening: a pre-existing REAL directory at one of the four
# legacy link targets must be relocated into persist rather than either
# silently nested into (the bug Branch 2's revert reintroduced by removing
# -T; see checkout-consolidation-plan.md's Branch 2 section -- this was
# activation.sh's own `ln -sfn` shape) or refused with the failure never
# surfacing (dx-ai.sh's own prior `ln -sfnT` shape, called in a `||` context
# that never checked it -- see dx_ai_main). Fable B9: dx_persist_relocate_dir
# now gives both entry points the same, actually-recovering behavior --
# the pre-existing real directory's content moves into $persist_home/.claude
# (conflicts renamed aside, none here), and ~/.claude ends up the intended
# symlink, exactly as a repeat run from a clean state would.
hardening_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-hardening.XXXXXX")"
hardening_fixture="$(cd "$hardening_fixture" && pwd -P)"
hardening_persist="$hardening_fixture/persist/home/dx"
hardening_home="$hardening_fixture/home/dx"
mkdir -p "$hardening_persist" "$hardening_home/.claude"
printf '%s\n' pre-existing-real-file > "$hardening_home/.claude/keep-me"
if dx_ai_setup_credentials "$hardening_persist" "$hardening_home" >/dev/null 2>&1; then
    test_pass "dx_ai_setup_credentials relocates a pre-existing real ~/.claude directory instead of failing"
else
    test_fail "dx_ai_setup_credentials relocates a pre-existing real ~/.claude directory instead of failing"
fi
if [ -L "$hardening_home/.claude" ] && [ "$(readlink "$hardening_home/.claude")" = "$hardening_persist/.claude" ]; then
    test_pass "the relocated ~/.claude becomes the intended symlink"
else
    test_fail "the relocated ~/.claude becomes the intended symlink"
fi
if [ "$(cat "$hardening_persist/.claude/keep-me")" = pre-existing-real-file ]; then
    test_pass "the pre-existing real ~/.claude directory's content is preserved, relocated into persist"
else
    test_fail "the pre-existing real ~/.claude directory's content is preserved, relocated into persist"
fi
rm -rf "$hardening_fixture"

# --- statusLine merge safety (Fable review 2026-09-29, finding B1):
# `jq -e '.statusLine' "$settings"` fails identically for "key absent" and
# "not JSON", and the merge that followed used to write straight to a temp
# file and `mv` it over $settings with no check that the temp file held
# anything -- an unparseable settings.json got clobbered with zero bytes.
# dx_ai_setup_credentials runs in `||` context in dx_ai_main, so errexit is
# suspended inside it; only an explicit check-and-return stops the clobber.
statusline_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-statusline.XXXXXX")"
statusline_fixture="$(cd "$statusline_fixture" && pwd -P)"

# (1) A non-JSON settings.json must fail loudly and survive untouched.
corrupt_persist="$statusline_fixture/corrupt/persist/home/dx"
corrupt_home="$statusline_fixture/corrupt/home/dx"
mkdir -p "$corrupt_persist/.claude" "$corrupt_home"
printf '%s' '{not json' > "$corrupt_persist/.claude/settings.json"
cp "$corrupt_persist/.claude/settings.json" "$statusline_fixture/corrupt/before-settings.json"
creds_ln_shim
corrupt_stderr="$(dx_ai_setup_credentials "$corrupt_persist" "$corrupt_home" 2>&1 >/dev/null)"
corrupt_status=$?
creds_ln_unshim
if [ "$corrupt_status" -ne 0 ]; then
    test_pass "dx_ai_setup_credentials fails on a non-JSON settings.json"
else
    test_fail "dx_ai_setup_credentials fails on a non-JSON settings.json"
fi
if printf '%s\n' "$corrupt_stderr" | stdin_matches -F "Error:" \
    && printf '%s\n' "$corrupt_stderr" | stdin_matches -F "$corrupt_persist/.claude/settings.json"; then
    test_pass "the non-JSON settings.json error names the file"
else
    test_fail "the non-JSON settings.json error names the file"
fi
if cmp -s "$statusline_fixture/corrupt/before-settings.json" "$corrupt_persist/.claude/settings.json"; then
    test_pass "a non-JSON settings.json is left byte-for-byte unchanged"
else
    test_fail "a non-JSON settings.json is left byte-for-byte unchanged"
fi
if ! ls "$corrupt_persist/.claude"/settings.json.tmp.* >/dev/null 2>&1; then
    test_pass "a rejected settings.json merge leaves no temp file behind"
else
    test_fail "a rejected settings.json merge leaves no temp file behind"
fi

# (2a) A valid, empty settings.json gains statusLine and stays valid JSON.
plain_persist="$statusline_fixture/plain/persist/home/dx"
plain_home="$statusline_fixture/plain/home/dx"
mkdir -p "$plain_persist/.claude" "$plain_home"
printf '%s\n' '{}' > "$plain_persist/.claude/settings.json"
creds_ln_shim
dx_ai_setup_credentials "$plain_persist" "$plain_home" >/dev/null 2>&1
plain_status=$?
creds_ln_unshim
if [ "$plain_status" -eq 0 ] \
    && jq -e '.statusLine.command == "dx-claude-statusline"' "$plain_persist/.claude/settings.json" >/dev/null 2>&1; then
    test_pass "a valid empty settings.json gains statusLine"
else
    test_fail "a valid empty settings.json gains statusLine"
fi
if jq empty "$plain_persist/.claude/settings.json" >/dev/null 2>&1; then
    test_pass "settings.json remains valid JSON after gaining statusLine"
else
    test_fail "settings.json remains valid JSON after gaining statusLine"
fi

# (2b) A settings.json that already has statusLine is left byte-identical
# (the merge is skipped entirely, not re-applied idempotently).
preset_persist="$statusline_fixture/preset/persist/home/dx"
preset_home="$statusline_fixture/preset/home/dx"
mkdir -p "$preset_persist/.claude" "$preset_home"
printf '%s\n' '{"statusLine":{"type":"command","command":"dx-claude-statusline"}}' > "$preset_persist/.claude/settings.json"
cp "$preset_persist/.claude/settings.json" "$statusline_fixture/preset/before-settings.json"
creds_ln_shim
dx_ai_setup_credentials "$preset_persist" "$preset_home" >/dev/null 2>&1
preset_status=$?
creds_ln_unshim
if [ "$preset_status" -eq 0 ] \
    && cmp -s "$statusline_fixture/preset/before-settings.json" "$preset_persist/.claude/settings.json"; then
    test_pass "a settings.json that already has statusLine is left byte-identical"
else
    test_fail "a settings.json that already has statusLine is left byte-identical"
fi
rm -rf "$statusline_fixture"

# --- dx_ai_merge_json_setting: a filter that runs cleanly but produces no
# output at all (e.g. `empty`, or any filter whose result happens to be
# empty) must never be allowed to overwrite a working settings file with
# silence -- `-s "$tmp"` is what tells this apart from a merge that legitimately
# writes zero bytes, since `jq`'s own exit code is 0 either way.
mergeempty_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-merge-json-empty.XXXXXX")"
printf '%s\n' '{"kept":"value"}' > "$mergeempty_fixture/settings.json"
cp "$mergeempty_fixture/settings.json" "$mergeempty_fixture/before.json"
mergeempty_stderr="$(dx_ai_merge_json_setting "$mergeempty_fixture/settings.json" 'empty' 2>&1 >/dev/null)"
mergeempty_status=$?
if [ "$mergeempty_status" -ne 0 ] \
    && printf '%s\n' "$mergeempty_stderr" | stdin_matches -F "Error: failed to update $mergeempty_fixture/settings.json; left unchanged" \
    && cmp -s "$mergeempty_fixture/before.json" "$mergeempty_fixture/settings.json" \
    && [ -z "$(find "$mergeempty_fixture" -maxdepth 1 -name 'settings.json.tmp.*')" ]; then
    test_pass "dx_ai_merge_json_setting refuses a filter that produces no output and leaves the file untouched"
else
    test_fail "dx_ai_merge_json_setting refuses a filter that produces no output and leaves the file untouched"
fi
rm -rf "$mergeempty_fixture"

# --- dx_ai_ensure_keyring: its own address_file is fixed and depends on
# nothing about the caller's environment. Verified directly, since every
# dx_ai_main-level test stubs this function away entirely.
keyring_ensure_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-ensure-keyring.XXXXXX")"
keyring_ensure_marker="$keyring_ensure_fixture/marker"
(
    dx_ai_load_keyring() { :; }
    dx_keyring_start() { printf '%s\n' "$1" > "$keyring_ensure_marker"; }
    dx_ai_ensure_keyring
)
if [ "$(cat "$keyring_ensure_marker" 2>/dev/null)" = /persist/home/dx/.local/state/dx/keyring-address ]; then
    test_pass "dx_ai_ensure_keyring starts the keyring at its fixed persisted address"
else
    test_fail "dx_ai_ensure_keyring starts the keyring at its fixed persisted address"
fi
(
    dx_ai_load_keyring() { return 1; }
    dx_keyring_start() { echo "unexpected dx_keyring_start call" >&2; return 1; }
    dx_ai_ensure_keyring
)
keyring_ensure_load_fail_rc=$?
if [ "$keyring_ensure_load_fail_rc" -ne 0 ]; then
    test_pass "dx_ai_ensure_keyring returns early when dx_ai_load_keyring fails"
else
    test_fail "dx_ai_ensure_keyring returns early when dx_ai_load_keyring fails"
fi
rm -rf "$keyring_ensure_fixture"

# Fable B11: dx_keyring_start (scripts/lib/dx-keyring.sh) used to swallow a
# genuine gnome-keyring-daemon launch failure with `|| true` and then print
# "started" unconditionally right after. Fake dbus-daemon/dbus-send (real
# enough to satisfy dx_keyring_probe's `[ -S ... ]` check against a real
# AF_UNIX socket, matching tests/test_sourceable_coverage.sh's own
# established fixture shape for this library) plus a gnome-keyring-daemon
# that always fails, and assert dx-keyring no longer claims success.
keyring_fail_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-keyring-fail.XXXXXX")"
mkdir -p "$keyring_fail_fixture/fakebin/bin" "$keyring_fail_fixture/fakebin/share/dbus-1"
: > "$keyring_fail_fixture/fakebin/share/dbus-1/session.conf"
keyring_fail_socket="$keyring_fail_fixture/fake.sock"
python3 - "$keyring_fail_socket" <<'PY'
import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.remove(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY
keyring_fail_addr_file="$keyring_fail_fixture/.fake-addr"
printf 'unix:path=%s,guid=deadbeefdeadbeefdeadbeefdeadbeef\n' "$keyring_fail_socket" > "$keyring_fail_addr_file"
cat > "$keyring_fail_fixture/fakebin/bin/dbus-daemon" <<FAKE
#!/bin/sh
cat "$keyring_fail_addr_file"
FAKE
cat > "$keyring_fail_fixture/fakebin/bin/dbus-send" <<'FAKE'
#!/bin/sh
printf '   array [\n      string "org.freedesktop.DBus"\n   ]\n'
FAKE
cat > "$keyring_fail_fixture/fakebin/bin/gnome-keyring-daemon" <<'FAKE'
#!/bin/sh
exit 1
FAKE
chmod +x "$keyring_fail_fixture/fakebin/bin/dbus-daemon" "$keyring_fail_fixture/fakebin/bin/dbus-send" "$keyring_fail_fixture/fakebin/bin/gnome-keyring-daemon"
keyring_fail_out="$(PATH="$keyring_fail_fixture/fakebin/bin:$PATH" bash -c "source '$CONTAINER_DIR/scripts/lib/dx-keyring.sh'; dx_keyring_start '$keyring_fail_fixture/address'" 2>&1)"
if printf '%s\n' "$keyring_fail_out" | stdin_matches -F 'gnome-keyring Secret Service started.'; then
    test_fail "dx_keyring_start does not claim the keyring started when gnome-keyring-daemon fails"
else
    test_pass "dx_keyring_start does not claim the keyring started when gnome-keyring-daemon fails"
fi
if printf '%s\n' "$keyring_fail_out" | stdin_matches -F 'Warning: gnome-keyring-daemon failed to start'; then
    test_pass "dx_keyring_start warns when gnome-keyring-daemon fails to start"
else
    test_fail "dx_keyring_start warns when gnome-keyring-daemon fails to start (output: $keyring_fail_out)"
fi
rm -rf "$keyring_fail_fixture"

# Reinstall the fixture-cleanup trap the blocks above replaced.
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT

if ! live_tail_enabled; then
    test_skip "dx-ai guest runtime checks (--skip-integration)"
    print_summary
    exit_with_code
fi

if ! requires_container; then
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

run_guest() {
    "$BASE_DIR/bin/dx-ssh" "$1"
}

set +e
DX_AI_OUT="$(run_guest 'DBUS_SESSION_BUS_ADDRESS= dx-ai' 2>&1)"
DX_AI_RC=$?
set -e

if [ "$DX_AI_RC" -eq 0 ]; then
    test_pass "dx-ai completes successfully inside the guest"
else
    test_fail "dx-ai completes successfully inside the guest"
    printf '%s\n' "$DX_AI_OUT" >&2
    print_summary
    exit_with_code
fi

if printf '%s\n' "$DX_AI_OUT" | stdin_matches -E "D-Bus session bus (started|already running)"; then
    test_pass "dx-ai ensures D-Bus keyring service"
else
    test_fail "dx-ai ensures D-Bus keyring service"
fi

for tool in codex claude agy herdr opencode; do
    if run_guest "command -v $tool" >/dev/null 2>&1; then
        test_pass "$tool is available after dx-ai"
    else
        test_fail "$tool is available after dx-ai"
    fi
done

# gemini-cli was removed from DX_AI_TOOLS/aiPackages (findings.md's
# 2026-09-30 user decision); a freshly published generation must not install
# it, even though it is still tolerated as legacy in a retained
# pre-OpenCode generation (see the DX_AI_LEGACY_TOOLS cases above).
if run_guest "command -v gemini" >/dev/null 2>&1; then
    test_fail "gemini is not available after dx-ai"
else
    test_pass "gemini is not available after dx-ai"
fi

if run_guest 'case "$(agy --version)" in 0.*|1.0.0) exit 1 ;; *) exit 0 ;; esac' >/dev/null 2>&1; then
    test_pass "agy version includes OAuth persistence fixes"
else
    test_fail "agy version includes OAuth persistence fixes"
fi

if run_guest 'test -L ~/.gemini && test "$(readlink ~/.gemini)" = /persist/home/dx/.gemini && test -d ~/.gemini/antigravity-cli' >/dev/null 2>&1; then
    test_pass "agy state directory is under persisted Gemini storage"
else
    test_fail "agy state directory is under persisted Gemini storage"
fi

if run_guest 'marker=".dxe-agy-persistence-test-$$"; echo persisted > "$HOME/.gemini/antigravity-cli/$marker" && test -f "/persist/home/dx/.gemini/antigravity-cli/$marker"; rc=$?; rm -f "$HOME/.gemini/antigravity-cli/$marker"; exit $rc' >/dev/null 2>&1; then
    test_pass "agy persisted state path is writable through ~/.gemini"
else
    test_fail "agy persisted state path is writable through ~/.gemini"
fi

if run_guest 'test -L ~/.config/opencode && test "$(readlink ~/.config/opencode)" = /persist/home/dx/.config/opencode' >/dev/null 2>&1; then
    test_pass "opencode config directory is symlinked to persist"
else
    test_fail "opencode config directory is symlinked to persist"
fi

if run_guest 'test -L ~/.local/share/opencode && test "$(readlink ~/.local/share/opencode)" = /persist/home/dx/.local/share/opencode' >/dev/null 2>&1; then
    test_pass "opencode data directory is symlinked to persist"
else
    test_fail "opencode data directory is symlinked to persist"
fi

if run_guest 'address_file=/persist/home/dx/.local/state/dx/keyring-address; test -s "$address_file" && IFS= read -r address < "$address_file" && case "$address" in unix:path=/*) exit 0 ;; *) exit 1 ;; esac' >/dev/null 2>&1; then
    test_pass "dx-ai writes one validated raw D-Bus keyring address"
else
    test_fail "dx-ai writes one validated raw D-Bus keyring address"
fi

# --- Branch 16: the guest keyring is owned by dx-ai and the explicit
# dx-keyring command, not bootstrap. The dx-ai run above already brought up
# a live bus with a live Secret Service via the exact same shared library
# (scripts/lib/dx-keyring.sh) dx-keyring itself uses; exercise the command
# directly against that same live state, then prove the real defect this
# branch fixes (a stale socket file surviving the daemon's death) end to end
# without needing a full container restart. ---
if run_guest 'dx-keyring --help' 2>&1 | stdin_matches -F 'Usage: dx-keyring'; then
    test_pass "dx-keyring --help prints usage"
else
    test_fail "dx-keyring --help prints usage"
fi

DX_KEYRING_STATUS_OUT="$(run_guest 'dx-keyring status' 2>&1)"
if printf '%s\n' "$DX_KEYRING_STATUS_OUT" | stdin_matches -F live; then
    test_pass "dx-keyring status reports live after dx-ai already started it"
else
    test_fail "dx-keyring status reports live after dx-ai already started it"
    printf '%s\n' "$DX_KEYRING_STATUS_OUT" >&2
fi

# Idempotent restart: a second `dx-keyring start` against an already-live bus
# with a running Secret Service must spawn no new dbus-daemon/
# gnome-keyring-daemon processes (procps' pgrep is in dxPackages).
BEFORE_KEYRING_PIDS="$(run_guest "pgrep -f 'dbus-daemon|gnome-keyring-daemon' | sort" 2>/dev/null || true)"
run_guest 'dx-keyring start' >/dev/null 2>&1
AFTER_KEYRING_PIDS="$(run_guest "pgrep -f 'dbus-daemon|gnome-keyring-daemon' | sort" 2>/dev/null || true)"
if [ -n "$BEFORE_KEYRING_PIDS" ] && [ "$BEFORE_KEYRING_PIDS" = "$AFTER_KEYRING_PIDS" ]; then
    test_pass "dx-keyring start is idempotent against an already-live bus (no new processes)"
else
    test_fail "dx-keyring start is idempotent against an already-live bus (no new processes) (before=[$BEFORE_KEYRING_PIDS] after=[$AFTER_KEYRING_PIDS])"
fi

# The actual reported defect: dx-stop-container/dx-start-container leaves the
# previous boot's socket FILE behind while the process that owned it is gone.
# Reproduced here without a full container cycle by killing the real
# dbus-daemon process directly -- its socket file survives on disk exactly
# the same way (see scripts/lib/dx-keyring.sh's dx_keyring_probe comment for
# the live diagnosis this mirrors).
run_guest 'pkill -9 -f "dbus-daemon --config-file" || true' >/dev/null 2>&1 || true
sleep 1
DX_KEYRING_STALE_OUT="$(run_guest 'dx-keyring status' 2>&1)"
if printf '%s\n' "$DX_KEYRING_STALE_OUT" | stdin_matches -F stale; then
    test_pass "dx-keyring status reports stale once the daemon dies but its socket file survives"
else
    test_fail "dx-keyring status reports stale once the daemon dies but its socket file survives"
    printf '%s\n' "$DX_KEYRING_STALE_OUT" >&2
fi

DX_KEYRING_RECOVER_OUT="$(run_guest 'dx-keyring start' 2>&1)"
DX_KEYRING_RECOVER_STATUS="$(run_guest 'dx-keyring status' 2>&1)"
if printf '%s\n' "$DX_KEYRING_RECOVER_STATUS" | stdin_matches -F live; then
    test_pass "dx-keyring start recovers a stale bus and keyring"
else
    test_fail "dx-keyring start recovers a stale bus and keyring"
    printf '%s\n' "$DX_KEYRING_RECOVER_OUT" "$DX_KEYRING_RECOVER_STATUS" >&2
fi

print_summary
exit_with_code
