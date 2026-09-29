#!/bin/bash
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
mv() {
    if [ "${1:-}" = -Tf ]; then rm -f "$3"; "$real_mv" -f "$2" "$3"; else "$real_mv" "$@"; fi
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
if [ "$(tr '\n' ' ' < "$manifest_missing_stage/.tools-manifest" | sed 's/ $//')" = "codex gemini claude agy herdr opencode" ]; then
    test_pass "AI staging records the complete generation-local tool manifest"
else
    test_fail "AI staging records the complete generation-local tool manifest"
fi
if dx_ai_publish_generation "$state" manifest-missing-opencode "$manifest_missing_stage" >/dev/null 2>&1; then
    test_pass "AI publication accepts the same candidate after its opencode executable is added"
else
    test_fail "AI publication accepts the same candidate after its opencode executable is added"
fi

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
    dx_ai_boot_id() { printf '%s\n' test-boot-id; }
    dx_ai_process_start() { printf '%s\n' 123; }
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
dx_ai_boot_id() { printf '%s\n' test-boot-id; }
dx_ai_process_start() { printf '%s\n' 123; }
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
dx_ai_boot_id() { printf '%s\n' test-boot-id; }
dx_ai_process_start() { printf '%s\n' 123; }
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

assert_grep_in_file "$AI_SCRIPT" '^ +dx_ai_install_herdr_integrations$' "dx-ai runs the Herdr integration step from its main flow"
assert_file_not_contains "$AI_SCRIPT" 'dx_ai_install_herdr_integrations || return' "dx-ai never lets an optional Herdr integration fail the update"

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
mkdir -p "$loader_fixture/bin"
cp "$AI_SCRIPT" "$loader_fixture/bin/dx-ai.sh"

home_candidate="$loader_fixture/home-candidate"
mkdir -p "$home_candidate/.local/lib/dx"
cp "$CONTAINER_DIR/scripts/lib/dx-opencode-persistence.sh" "$home_candidate/.local/lib/dx/dx-opencode-persistence.sh"
if HOME="$home_candidate" DX_AI_BOOTSTRAP_ROOT="$loader_fixture/no-such-bootstrap" \
    bash -c "source '$loader_fixture/bin/dx-ai.sh'; dx_ai_load_opencode_persistence && declare -F dx_ai_opencode_persistence >/dev/null"; then
    test_pass "dx_ai_load_opencode_persistence resolves the Home-Manager-installed copy (candidate 2)"
else
    test_fail "dx_ai_load_opencode_persistence resolves the Home-Manager-installed copy (candidate 2)"
fi

bootstrap_candidate="$loader_fixture/bootstrap-candidate"
mkdir -p "$bootstrap_candidate/scripts/lib"
cp "$CONTAINER_DIR/scripts/lib/dx-opencode-persistence.sh" "$bootstrap_candidate/scripts/lib/dx-opencode-persistence.sh"
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
# legacy link targets must produce an error, not a nested symlink placed
# inside it (the bug Branch 2's revert reintroduced by removing -T; see
# checkout-consolidation-plan.md's Branch 2 section). dx_ai_setup_credentials
# does not itself check each ln's exit status (neither did the code Branch 2
# reverted), so its own return code stays 0 either way; the observable
# contract this hardening buys is that the failing ln call reports an error
# on stderr instead of nothing, and -- the actually load-bearing part --
# leaves the real directory and its content alone rather than nesting a
# symlink inside it. This runs deliberately unshimmed: GNU ln -T genuinely
# refuses a real directory target on Linux, and this repository's macOS
# bash-3.2 job proves the same observable contract for a different reason --
# BSD ln has no -T option at all, so the call fails there too -- but either
# way nothing is silently swallowed and nothing is nested.
hardening_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-creds-hardening.XXXXXX")"
hardening_fixture="$(cd "$hardening_fixture" && pwd -P)"
hardening_persist="$hardening_fixture/persist/home/dx"
hardening_home="$hardening_fixture/home/dx"
mkdir -p "$hardening_persist" "$hardening_home/.claude"
printf '%s\n' pre-existing-real-file > "$hardening_home/.claude/keep-me"
hardening_stderr="$(dx_ai_setup_credentials "$hardening_persist" "$hardening_home" 2>&1 >/dev/null)"
if [ -n "$hardening_stderr" ]; then
    test_pass "a pre-existing real ~/.claude directory produces an error, not silence"
else
    test_fail "a pre-existing real ~/.claude directory produces an error, not silence"
fi
if [ -d "$hardening_home/.claude" ] && [ ! -L "$hardening_home/.claude" ] \
    && [ "$(cat "$hardening_home/.claude/keep-me")" = pre-existing-real-file ] \
    && [ ! -e "$hardening_home/.claude/.claude" ]; then
    test_pass "the pre-existing real ~/.claude directory and its content survive untouched, not nested into"
else
    test_fail "the pre-existing real ~/.claude directory and its content survive untouched, not nested into"
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

# Reinstall the fixture-cleanup trap the blocks above replaced.
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
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

for tool in codex gemini claude agy herdr opencode; do
    if run_guest "command -v $tool" >/dev/null 2>&1; then
        test_pass "$tool is available after dx-ai"
    else
        test_fail "$tool is available after dx-ai"
    fi
done

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
