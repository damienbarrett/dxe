#!/usr/bin/env bash
# dx-ai's binary-cache-miss policy: decide whether a fresh nixpkgs-unstable
# lock would build anything non-trivial from source, and if so, try falling
# back to the previous generation's own lock before refusing. Safe to source
# (import-only). Moved out of dx-ai.sh (Fable B7) so this logic sits under
# scripts/lib, in kcov's coverage scope (unlike scripts/*.sh -- see
# tests/coverage/exclusions.txt).

# A "will be built" derivation Nix is expected to ALWAYS build locally,
# regardless of how well cached nixpkgs-unstable is, so it is not a sign of
# the actual risk dx_ai_check_cached exists to catch:
#   - dx-ai-tools: our own packages.ai-tools buildEnv (flake.nix); never
#     published to any binary cache since it is not part of nixpkgs.
#   - builder.pl: nixpkgs' own buildEnv implementation's generic, trivial
#     Perl builder script -- part of the same buildEnv, no compiler ever
#     runs, and the identical shape appears for ANY buildEnv anywhere.
#   - antigravity-cli*: agy's own two derivations (its fetchurl source step,
#     named "antigravity-cli-src" above, and its "antigravity-cli-<version>"
#     unpack/install step) -- agy is a private, non-redistributable CLI, so
#     it is never on any binary cache, on any revision.
#   - claude-code*/claude.zst: nixpkgs' own claude-code package's two
#     derivations (its "claude.zst" fetchurl source step and its
#     "claude-code-<version>" unpack/wrap step). claude-code's package.nix
#     sets `license = lib.licenses.unfree`, and Hydra never builds or caches
#     unfree-licensed packages, so -- exactly like agy -- this is a small,
#     seconds-long, always-local fetch+unpack (`dontBuild = true` in both
#     nixpkgs' package.nix and this shape), not real compilation, and not
#     something a channel refresh or a fallback lock can ever avoid. Treated
#     the same as agy here rather than left to trigger the fallback/refusal
#     path on every single run. Verified against nixpkgs revision
#     d54020a6ac3211e9f4201631bdf67678818c0cdf (2026-09-26) with a real Nix;
#     re-verify this list if aiPackages ever gains another always-local
#     package.
dx_ai_trivial_build() {
    case "$1" in
        dx-ai-tools|builder.pl|antigravity-cli*|claude-code*|claude.zst) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse `nix build --dry-run`'s stderr for the derivations it says it "will
# build" and fail (printing their names, one per line, on stdout) if any of
# them is not on the trivial allow-list above -- a real cache miss on a
# heavy package (codex's Rust workspace, the incident this guards against)
# would otherwise be silently compiled from source inside the guest. Header
# wording verified against a real Nix 2.34.8 (src/libmain/shared.cc's
# printMissing): singular "this derivation will be built:" for exactly one,
# plural "these N derivations will be built:" otherwise; the "will be
# fetched" line (also singular/plural) always follows and ends the list, if
# present. Prints nothing and returns 0 when there is nothing to build, or
# everything to build is allow-listed.
dx_ai_check_cached() {
    local stage="$1" output line in_build=false path base name misses=""
    if ! output="$(nix build --dry-run "${NIX_FLAGS[@]}" "$stage#ai-tools" 2>&1 1>/dev/null)"; then
        echo "Error: could not evaluate the AI tools profile to check the Nix cache." >&2
        printf '%s\n' "$output" >&2
        return 2
    fi
    while IFS= read -r line; do
        case "$line" in
            "this derivation will be built:"|"these "*" derivations will be built:")
                in_build=true
                continue
                ;;
            "this path will be fetched"*|"these "*" paths will be fetched"*)
                in_build=false
                continue
                ;;
        esac
        [ "$in_build" = true ] || continue
        case "$line" in
            "  /nix/store/"*.drv) ;;
            *) continue ;;
        esac
        path="${line#  }"
        base="${path##*/}"
        name="${base#*-}"
        name="${name%.drv}"
        dx_ai_trivial_build "$name" && continue
        misses="$misses$name
"
    done <<EOF
$output
EOF
    [ -z "$misses" ] || { printf '%s' "$misses"; return 1; }
}

# The nixpkgs-unstable input's locked revision, from a generation's own
# flake.lock -- used only to name revisions in the fallback/refusal notices.
dx_ai_nixpkgs_unstable_rev() {
    jq -r '.nodes["nixpkgs-unstable"].locked.rev // empty' "$1/flake.lock" 2>/dev/null
}

# Refuse to install AI tools that would silently build from source: on a
# cache miss with the freshly updated lock, try the previously published AI
# generation's own flake.lock instead (it was cached and installable before,
# so this is a best-effort, zero-source-build recovery attempted regardless
# of the override below); if that is clean, stay on it and say so. If it is
# not clean either (or there is no previous generation to fall back to),
# refuse before dx_ai_install_profile with the list of packages that would
# be built from source and the remedy, unless DX_AI_ALLOW_SOURCE_BUILDS=1,
# which skips only that final refusal (the list is still printed). Never
# touches $state/current -- only ever reads it and writes into $stage, which
# the caller discards on any failure.
dx_ai_ensure_cached() {
    # Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 4):
    # $3 is this guest's own already-resolved system (dx_ai_main resolves it
    # once via the shared scripts/lib/dx-guest-system.sh helper), used only
    # to name the system in the fallback/refusal notice below -- replaces
    # the earlier flake.nix-text-grepping dx_ai_flake_system, which stopped
    # working once flake.nix became multi-system (no single "system = "
    # line to find). Optional: direct unit tests below call this with two
    # args and get the same "this system" fallback wording as before.
    local stage="$1" state="$2" system="${3:-}" misses rc new_rev old_rev
    misses="$(dx_ai_check_cached "$stage")"; rc=$?
    [ "$rc" -ne 0 ] || return 0
    [ "$rc" -ne 2 ] || return 1

    new_rev="$(dx_ai_nixpkgs_unstable_rev "$stage" 2>/dev/null || true)"

    if [ -f "$state/current/flake.lock" ] && [ ! -L "$state/current/flake.lock" ]; then
        old_rev="$(dx_ai_nixpkgs_unstable_rev "$state/current" 2>/dev/null || true)"
        if cp -f "$state/current/flake.lock" "$stage/flake.lock"; then
            if misses="$(dx_ai_check_cached "$stage")"; then
                echo "Notice: nixpkgs-unstable $new_rev is not fully cached for ${system:-this system}; staying on $old_rev." >&2
                return 0
            fi
        fi
    fi

    if [ "${DX_AI_ALLOW_SOURCE_BUILDS:-0}" = 1 ]; then
        echo "Warning: DX_AI_ALLOW_SOURCE_BUILDS=1 -- building the following AI tools packages from source instead of the Nix binary cache:" >&2
        printf '  %s\n' $misses >&2
        return 0
    fi

    echo "Error: refusing to install AI tools that would build the following packages from source instead of fetching them from the Nix binary cache:" >&2
    printf '  %s\n' $misses >&2
    echo "Remedy: wait for nixpkgs-unstable's binary cache to catch up and re-run dx-ai (it will retry the refresh), or set DX_AI_ALLOW_SOURCE_BUILDS=1 to build from source anyway." >&2
    return 1
}
