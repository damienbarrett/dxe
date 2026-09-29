#!/usr/bin/env bash

NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --accept-flake-config)
# Single source of truth for the optional AI tools bundle. Keep the Nix
# declaration (flake.nix's aiPackages), bin/dx-herdr, and docs/guest.md in sync
# with this list by hand; they are outside this module's ownership.
DX_AI_TOOLS="codex gemini claude agy herdr opencode"
# A generation published before OpenCode support has no .tools-manifest (see
# dx_ai_generation_tools); its real, complete inventory was this five-tool
# set, and validating or recovering it must use that instead of the current
# DX_AI_TOOLS, which would demand an opencode executable that generation was
# never asked to build.
DX_AI_LEGACY_TOOLS="codex gemini claude agy herdr"
# The intersection of the agents dx-ai publishes and the integrations Herdr
# ships. Herdr has no target for gemini or agy, so they are absent by design.
DX_AI_HERDR_INTEGRATIONS=(claude codex opencode)

# dx-ai is packaged both as a Home Manager `home.file` (for normal guest use,
# once the AI generation itself has been published) and loadable straight off
# the bootstrap volume (so a fresh guest's very first dx-ai run, before any AI
# generation exists, can still resolve it). Try the script's own directory
# first since it is already colocated there in both installs.
dx_ai_load_opencode_persistence() {
    local script_directory candidate
    declare -F dx_ai_opencode_persistence >/dev/null && return 0
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-opencode-persistence.sh" \
        "$HOME/.local/lib/dx/dx-opencode-persistence.sh" \
        "${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-opencode-persistence.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=/dev/null
        source "$candidate" || return 1
        declare -F dx_ai_opencode_persistence >/dev/null && return 0
    done
    echo "Error: OpenCode persistence library is unavailable." >&2
    return 1
}

# Same three-candidate shape as dx_ai_load_opencode_persistence, for the
# same reason: scripts/lib/dx-keyring.sh is packaged both as a Home Manager
# `home.file` and loadable straight off the bootstrap volume, so a fresh
# guest's very first dx-ai run (before any AI generation exists to publish
# it under ~/.local/lib/dx) can still resolve it.
dx_ai_load_keyring() {
    local script_directory candidate
    declare -F dx_keyring_start >/dev/null && return 0
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-keyring.sh" \
        "$HOME/.local/lib/dx/dx-keyring.sh" \
        "${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-keyring.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=/dev/null
        source "$candidate" || return 1
        declare -F dx_keyring_start >/dev/null && return 0
    done
    echo "Error: keyring library is unavailable." >&2
    return 1
}

dx_ai_usage() {
    cat <<'EOF'
Usage: dx-ai [--recover] [--supports <tool>]

Install or update Codex, Gemini, Claude, Antigravity, Herdr, and OpenCode from an
immutable working generation under /persist. The published bootstrap is never modified.
Use --recover to repoint current to its retained predecessor generation.
Use --supports <tool> to check if a tool is known to this dx-ai generation.

If a nixpkgs-unstable refresh would build a non-trivial package from source
(a binary-cache miss), dx-ai falls back to the previous generation's lock; if
that also misses, or none exists, it refuses to install and exits non-zero.
Set DX_AI_ALLOW_SOURCE_BUILDS=1 to build from source anyway.
EOF
}

dx_ai_published_root() {
    local root="${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}"
    if [ -L "$root/current" ] && [ -f "$root/current/flake.nix" ]; then readlink -f "$root/current"; else printf '%s\n' "$root"; fi
}

# Fable B4: a uniform "Error: <msg>" stderr line for the staging/publish
# paths that used to fail with a bare `return 1` and nothing printed. A
# plain function call cannot exit its caller, so every call site still
# writes its own `return 1` right alongside this.
dx_ai_fail() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

# Same three-candidate shape as dx_ai_load_opencode_persistence/
# dx_ai_load_keyring, for the same reason: scripts/lib/dx-ai-lock.sh is
# packaged both as a Home Manager `home.file` and loadable straight off the
# bootstrap volume, so a fresh guest's very first dx-ai run (before any AI
# generation exists to publish it under ~/.local/lib/dx) can still resolve
# its own publication lock. Fable B3/B7: dx-ai's publication-lock primitives
# (process identity, the lock itself) now live in that shared library so
# they sit in kcov's coverage scope, unlike this file.
dx_ai_load_lock() {
    local script_directory candidate
    declare -F dx_ai_lock_acquire >/dev/null && return 0
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-ai-lock.sh" \
        "$HOME/.local/lib/dx/dx-ai-lock.sh" \
        "${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-ai-lock.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=/dev/null
        source "$candidate" || return 1
        declare -F dx_ai_lock_acquire >/dev/null && return 0
    done
    echo "Error: dx-ai publication lock library is unavailable." >&2
    return 1
}

# Branch 11 / Phase 4 (qnap-dxe-plan.md DQ7, docs/refactor/
# arch-neutral-guest.md section 3.4): the Antigravity CLI publishes its
# updater manifest at a per-system URL upstream (verified read-only against
# the real host: both linux_arm64.json and linux_amd64.json exist at this
# same path shape). No env override remains -- AGY_MANIFEST_URL had no
# consumer outside one static test assertion, updated alongside this
# change.
dx_ai_agy_manifest_url() {
    case "$1" in
        aarch64-linux) printf '%s\n' "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json" ;;
        x86_64-linux)  printf '%s\n' "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json" ;;
        *) return 1 ;;
    esac
}

# Same three-candidate shape as dx_ai_load_opencode_persistence/
# dx_ai_load_keyring, for the same reason: scripts/lib/dx-guest-system.sh
# (dx_guest_native_system/dx_guest_resolve_system, shared with bootstrap.sh)
# is packaged both as a Home Manager `home.file` and loadable straight off
# the bootstrap volume, so a fresh guest's very first dx-ai run can still
# resolve it.
dx_ai_load_guest_system() {
    local script_directory candidate
    declare -F dx_guest_resolve_system >/dev/null && return 0
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-guest-system.sh" \
        "$HOME/.local/lib/dx/dx-guest-system.sh" \
        "${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-guest-system.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=/dev/null
        source "$candidate" || return 1
        declare -F dx_guest_resolve_system >/dev/null && return 0
    done
    echo "Error: guest-system helper is unavailable." >&2
    return 1
}

# The tool set to actually stage/publish/verify for $2 (a system), given
# $1's pins/agy.json: the full DX_AI_TOOLS when that system's agy pin is
# non-null, or DX_AI_TOOLS minus agy -- with DQ7's exact diagnostic on
# stderr -- when it is null. This never causes a foreign-architecture
# binary to be installed: that guarantee comes from flake.nix's own
# per-system agy/aiPackages filtering (docs/refactor/arch-neutral-guest.md
# section 3.3), which means a null-pin system's #ai-tools closure simply
# never contains an agy derivation to begin with. This function only keeps
# dx-ai's own bookkeeping (the tools-manifest, publish validation, verify)
# in agreement with what that filtering actually built.
dx_ai_tools_for_system() {
    local root="$1" system="$2" is_null tool
    is_null="$(jq -r --arg system "$system" '(.[$system] // null) == null' "$root/pins/agy.json" 2>/dev/null)" || is_null=true
    if [ "$is_null" = true ]; then
        echo "agy: no native artifact for $system; skipping (DQ7)" >&2
        for tool in $DX_AI_TOOLS; do [ "$tool" = agy ] || printf '%s\n' "$tool"; done
    else
        printf '%s\n' $DX_AI_TOOLS
    fi
}

dx_ai_refresh_pin() {
    local root="$1" system="$2" manifest_url manifest version url sha512_hex hash tmp is_null
    # DQ7: a null pin is a deliberate, sticky "no native artifact for this
    # system" declaration -- not a placeholder waiting to be filled in.
    # Refresh must never resurrect it, and must decide that BEFORE ever
    # reaching the network, since whatever upstream's manifest happens to
    # publish today is irrelevant to that declaration (docs/refactor/
    # arch-neutral-guest.md section 7.1; same jq shape as
    # dx_ai_tools_for_system's own null check, so both agree on what "null"
    # means).
    is_null="$(jq -r --arg system "$system" '(.[$system] // null) == null' "$root/pins/agy.json" 2>/dev/null)" || is_null=true
    if [ "$is_null" = true ]; then
        echo "agy: pin for $system is null; refresh will not resurrect it (DQ7)" >&2
        return 0
    fi
    manifest_url="$(dx_ai_agy_manifest_url "$system")" || { echo "Warning: agy has no known manifest URL for $system; skipping pin refresh." >&2; return 0; }
    echo "Refreshing Antigravity CLI manifest for $system..."
    manifest="$(curl -fsSL "$manifest_url")" || { echo "Warning: could not fetch agy manifest. Keeping current pin." >&2; return 0; }
    version="$(printf '%s' "$manifest" | jq -r '.version // empty')"
    url="$(printf '%s' "$manifest" | jq -r '.url // empty')"
    sha512_hex="$(printf '%s' "$manifest" | jq -r '.sha512 // empty')"
    [ -n "$version" ] && [ -n "$url" ] && [ -n "$sha512_hex" ] || { echo "Warning: malformed agy manifest. Keeping current pin." >&2; return 0; }
    case "$url" in https://*) ;; *) echo "Warning: agy manifest URL is not HTTPS. Keeping current pin." >&2; return 0 ;; esac
    case "$sha512_hex" in *[!0-9A-Fa-f]*|'') echo "Warning: malformed agy manifest hash. Keeping current pin." >&2; return 0 ;; esac
    [ "${#sha512_hex}" -eq 128 ] || { echo "Warning: malformed agy manifest hash. Keeping current pin." >&2; return 0; }
    hash="$(nix hash convert --hash-algo sha512 --to sri "$sha512_hex")" || { echo "Warning: could not convert agy manifest hash. Keeping current pin." >&2; return 0; }
    tmp="$(mktemp "$root/pins/.agy.json.XXXXXX")" || return 1
    if ! jq --arg system "$system" --arg version "$version" --arg url "$url" --arg hash "$hash" \
        '.[$system] = {version:$version, url:$url, hash:$hash}' "$root/pins/agy.json" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ "$(cat "$tmp")" = "$(cat "$root/pins/agy.json")" ]; then rm -f "$tmp"; echo "Antigravity CLI pin for $system is unchanged ($version)."; return 0; fi
    if ! mv -f "$tmp" "$root/pins/agy.json"; then rm -f "$tmp"; return 1; fi
    echo "Pinned agy $version for $system from upstream manifest."
}

dx_ai_stage_generation() {
    local published="$1" state="$2" id="$3" stage predecessor=""
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) dx_ai_fail "invalid AI generation id: $id"; return 1 ;; esac
    [ -d "$published" ] && [ ! -L "$published" ] || { dx_ai_fail "published bootstrap is missing or is a symlink: $published"; return 1; }
    [ ! -L "$state" ] && [ ! -L "$state/generations" ] || { dx_ai_fail "AI state root or its generations directory is a symlink: $state"; return 1; }
    stage="$state/generations/.staging-$id"
    mkdir -p "$state/generations" || { dx_ai_fail "could not create $state/generations"; return 1; }
    [ -d "$state/generations" ] && [ ! -L "$state/generations" ] || { dx_ai_fail "$state/generations is not a plain directory"; return 1; }
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || { dx_ai_fail "AI generation stage already exists: $stage"; return 1; }
    mkdir "$stage" || { dx_ai_fail "could not create AI generation stage: $stage"; return 1; }
    if ! cp -a "$published/." "$stage/" || ! chmod -R u+w "$stage"; then
        chmod -R u+w "$stage" 2>/dev/null || true
        rm -rf "$stage"
        dx_ai_fail "could not copy the published bootstrap into $stage"
        return 1
    fi
    if [ -L "$state/current" ]; then predecessor="$(readlink "$state/current")"; predecessor=${predecessor##*/}; fi
    case "$predecessor" in
        '') ;;
        [.-]*|*[!A-Za-z0-9_.-]*)
            chmod -R u+w "$stage"; rm -rf "$stage"
            dx_ai_fail "invalid AI predecessor generation name: $predecessor"
            return 1
            ;;
    esac
    printf '%s\n' "$predecessor" > "$stage/.predecessor" \
        || { chmod -R u+w "$stage"; rm -rf "$stage"; dx_ai_fail "could not record predecessor in $stage/.predecessor"; return 1; }
    # Record this generation's own tool inventory. A generation published
    # before OpenCode existed has no manifest at all (dx_ai_generation_tools
    # falls back to DX_AI_LEGACY_TOOLS for those); every generation staged
    # from here on declares the complete current bundle.
    printf '%s\n' $DX_AI_TOOLS > "$stage/.tools-manifest" \
        || { chmod -R u+w "$stage"; rm -rf "$stage"; dx_ai_fail "could not record tool manifest in $stage/.tools-manifest"; return 1; }
    printf '%s\n' "$stage"
}

dx_ai_update_flake() {
    local stage="$1" system="$2"
    dx_ai_refresh_pin "$stage" "$system"
    echo "Updating nixpkgs-unstable..."
    (cd "$stage" && nix flake update "${NIX_FLAGS[@]}" nixpkgs-unstable)
    nix flake metadata "${NIX_FLAGS[@]}" "$stage" >/dev/null
}

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

dx_ai_install_profile() {
    local stage="$1"
    echo "Building an isolated optional AI tools profile..."
    nix profile add --profile "$stage/profile" "${NIX_FLAGS[@]}" "$stage#ai-tools"
}

dx_ai_tool_known() {
    local tool="$1" candidate
    for candidate in $DX_AI_TOOLS; do
        [ "$candidate" != "$tool" ] || return 0
    done
    return 1
}

# A retained generation's own tool inventory: its .tools-manifest if it has
# one, one tool name per line, or DX_AI_LEGACY_TOOLS if the manifest is
# entirely absent (a generation published before OpenCode support). A
# manifest that exists must be a regular, non-symlink, non-empty file with
# no blank/dot/duplicate/otherwise-malformed lines -- anything else is
# treated as corrupt, not silently ignored.
dx_ai_generation_tools() {
    local generation="$1" manifest="$1/.tools-manifest" tool inventory="" seen=" "
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then printf '%s\n' $DX_AI_LEGACY_TOOLS; return; fi
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    while IFS= read -r tool || [ -n "$tool" ]; do
        case "$tool" in ''|.|..|*[!A-Za-z0-9_.-]*) return 1 ;; esac
        case "$seen" in *" $tool "*) return 1 ;; esac
        seen="$seen$tool "
        inventory="$inventory${inventory:+
}$tool"
    done < "$manifest"
    [ -n "$inventory" ] || return 1
    printf '%s\n' "$inventory"
}

dx_ai_validate_generation() {
    local generation="$1" required tool tools
    [ -d "$generation" ] && [ ! -L "$generation" ] || { dx_ai_fail "AI generation is missing or not a directory: $generation"; return 1; }
    for required in flake.nix flake.lock pins/agy.json .predecessor; do
        [ -f "$generation/$required" ] && [ ! -L "$generation/$required" ] || { dx_ai_fail "AI generation is missing $generation/$required"; return 1; }
    done
    tools="$(dx_ai_generation_tools "$generation")" || { dx_ai_fail "AI generation has an invalid tool manifest: $generation/.tools-manifest"; return 1; }
    while IFS= read -r tool; do
        [ -f "$generation/profile/bin/$tool" ] && [ -x "$generation/profile/bin/$tool" ] \
            || { dx_ai_fail "AI generation is missing the $tool executable: $generation/profile/bin/$tool"; return 1; }
    done <<EOF
$tools
EOF
}

# A candidate generation about to be published must additionally carry its
# OWN manifest (not merely validate against the legacy fallback because one
# happens to be missing) and that manifest must declare the complete current
# bundle -- a generation staged today that is missing an executable
# DX_AI_TOOLS just added is a build defect, not a legacy generation.
dx_ai_validate_publish_generation() {
    local generation="$1" expected actual
    dx_ai_validate_generation "$generation" || return 1
    [ -f "$generation/.tools-manifest" ] && [ ! -L "$generation/.tools-manifest" ] \
        || { dx_ai_fail "AI generation about to publish has no tool manifest of its own: $generation/.tools-manifest"; return 1; }
    expected="$(printf '%s\n' $DX_AI_TOOLS)"
    actual="$(dx_ai_generation_tools "$generation")" || { dx_ai_fail "could not read tool manifest: $generation/.tools-manifest"; return 1; }
    [ "$actual" = "$expected" ] \
        || { dx_ai_fail "AI generation's tool manifest does not declare the complete current bundle: $generation/.tools-manifest"; return 1; }
}

dx_ai_publish_pointer() {
    local state="$1" id="$2" tmp
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) dx_ai_fail "invalid AI generation id: $id"; return 1 ;; esac
    tmp="$state/.current.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || { dx_ai_fail "AI publish temp pointer already exists: $tmp"; return 1; }
    if ! ln -s "generations/$id" "$tmp"; then dx_ai_fail "could not create AI publish temp pointer: $tmp"; return 1; fi
    if ! mv -Tf "$tmp" "$state/current"; then rm -f "$tmp"; dx_ai_fail "could not publish AI current pointer: $state/current"; return 1; fi
}

# Also collects orphaned `.staging-<id>` generation stages: a run killed
# between dx_ai_stage_generation and dx_ai_publish_generation leaves one
# behind, and bash's bare `*` glob never matches a dot-name, so before this
# it accumulated forever, each one pinning a full closure under
# /nix/var/nix/gcroots/auto. Safe to remove unconditionally: staging only
# ever happens under dx_ai_run_locked's lock, and this function only ever
# runs from dx_ai_publish_generation, itself under that same lock, so any
# `.staging-*` still present here belongs to some earlier, non-current run.
dx_ai_collect_generations() {
    local state="$1" current="$2" predecessor="$3" candidate candidate_id
    for candidate in "$state/generations"/* "$state/generations"/.staging-*; do
        [ -d "$candidate" ] || continue
        candidate_id=${candidate##*/}
        if [ -L "$candidate" ]; then rm -f "$candidate"; continue; fi
        case "$candidate_id" in
            .staging-*) ;;
            *)
                [ "$candidate_id" = "$current" ] && continue
                [ -n "$predecessor" ] && [ "$candidate_id" = "$predecessor" ] && continue
                ;;
        esac
        chmod -R u+w "$candidate" 2>/dev/null || true
        rm -rf "$candidate" || echo "Warning: could not collect obsolete AI generation $candidate_id." >&2
    done
}

dx_ai_publish_generation() {
    local state="$1" id="$2" stage="$3" generation predecessor=""
    generation="$state/generations/$id"
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) dx_ai_fail "invalid AI generation id: $id"; return 1 ;; esac
    [ ! -e "$generation" ] && [ ! -L "$generation" ] || { dx_ai_fail "AI generation already exists: $generation"; return 1; }
    dx_ai_validate_publish_generation "$stage" || { dx_ai_fail "staged AI generation is not ready to publish: $stage"; return 1; }
    mv "$stage" "$generation" || { dx_ai_fail "could not move staged AI generation into place: $stage -> $generation"; return 1; }
    if ! chmod -R a-w "$generation"; then
        chmod -R u+w "$generation" 2>/dev/null || true
        rm -rf "$generation"
        dx_ai_fail "could not make published AI generation read-only: $generation"
        return 1
    fi
    if ! dx_ai_publish_pointer "$state" "$id"; then
        chmod -R u+w "$generation"; rm -rf "$generation"
        dx_ai_fail "could not publish AI current pointer for $id"
        return 1
    fi
    predecessor="$(cat "$generation/.predecessor")" || { dx_ai_fail "could not read predecessor from $generation/.predecessor"; return 1; }
    dx_ai_collect_generations "$state" "$id" "$predecessor"
}

dx_ai_recover_generation() {
    local state="$1" current_target current predecessor
    [ -L "$state/current" ] || { echo "Error: no AI generation is currently published." >&2; return 1; }
    current_target="$(readlink "$state/current")"
    case "$current_target" in generations/*) current=${current_target#generations/} ;; *) echo "Error: invalid AI current pointer." >&2; return 1 ;; esac
    case "$current" in ''|*/*|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: invalid AI current generation." >&2; return 1 ;; esac
    dx_ai_validate_generation "$state/generations/$current" || { echo "Error: current AI generation is incomplete." >&2; return 1; }
    predecessor="$(cat "$state/generations/$current/.predecessor")" || { dx_ai_fail "could not read predecessor from $state/generations/$current/.predecessor"; return 1; }
    case "$predecessor" in ''|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: no valid retained AI predecessor is available." >&2; return 1 ;; esac
    dx_ai_validate_generation "$state/generations/$predecessor" || { echo "Error: retained AI predecessor is incomplete." >&2; return 1; }
    dx_ai_publish_pointer "$state" "$predecessor" || return 1
    echo "Recovered AI generation $predecessor (from $current)."
}

# Merge a jq filter into a JSON object file and replace it atomically.
#
# Refuses to touch a file that does not parse as a JSON object (an absent or
# empty file is the caller's job to seed first, e.g. with
# `[ -s "$file" ] || printf '%s\n' '{}' > "$file"`; this only guards the
# merge itself) and refuses to install an empty or failed jq result over it.
# Both guards matter: `jq -e '.someKey' "$file"`, the usual "does this
# setting already exist" probe callers use to decide whether to call this at
# all, fails identically for "key absent" and "not JSON" -- so an unparseable
# file reaches here exactly like one that legitimately needs the merge, and
# the type check is what tells them apart before anything is written.
dx_ai_merge_json_setting() {
    local file="$1" filter="$2" tmp
    jq -e 'type=="object"' "$file" >/dev/null 2>&1 \
        || { echo "Error: $file is not a JSON object; refusing to rewrite it" >&2; return 1; }
    tmp="$file.tmp.$$"
    jq "$filter" "$file" > "$tmp"
    if [ -s "$tmp" ]; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        echo "Error: failed to update $file; left unchanged" >&2
        return 1
    fi
}

dx_ai_setup_credentials() {
    local persist_home="${1:-/persist/home/dx}" home="${2:-$HOME}" settings
    dx_ai_load_opencode_persistence || return 1
    dx_ai_opencode_persistence "$persist_home" "$home" || return 1
    mkdir -p "$persist_home/.gemini/antigravity-cli" "$persist_home/.claude" "$persist_home/.codex" \
        "$persist_home/.local/share/keyrings" "$home/.config" "$home/.local/share"
    [ -s "$persist_home/.claude.json" ] || printf '%s\n' '{}' > "$persist_home/.claude.json"
    ln -sfnT "$persist_home/.gemini" "$home/.gemini"; ln -sfnT "$persist_home/.claude" "$home/.claude"
    ln -sfnT "$persist_home/.claude.json" "$home/.claude.json"; ln -sfnT "$persist_home/.codex" "$home/.codex"
    ln -sfnT "$persist_home/.local/share/keyrings" "$home/.local/share/keyrings"
    settings="$persist_home/.claude/settings.json"; [ -s "$settings" ] || printf '%s\n' '{}' > "$settings"
    if ! jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
        dx_ai_merge_json_setting "$settings" '. + {statusLine: {type: "command", command: "dx-claude-statusline"}}' || return 1
    fi
}

dx_ai_ensure_keyring() {
    local address_file=/persist/home/dx/.local/state/dx/keyring-address
    dx_ai_load_keyring || return 1
    dx_keyring_start "$address_file"
}

# Decide whether `herdr integration install <target>` still has work to do.
#
# Detect the states that mean "not done" rather than the one that means "done".
# Herdr reports an up-to-date integration as `current (v7)`, not `installed`;
# matching the latter treated every healthy integration as missing and
# reinstalled both of them on every dx-ai run, rewriting their hook files each
# time. Verified against herdr 0.8.0, whose status vocabulary is `not installed`
# / `outdated (vN)` / `current (vN)`.
#
# Inverting the test also fails safe across versions: a state neither of these
# patterns recognises is left alone rather than reinstalled on a loop.
dx_ai_herdr_integration_needs_install() {
    local target="$1" status="$2" outdated="$3" line state
    while IFS= read -r line; do
        case "$line" in "$target: "*) ;; *) continue ;; esac
        state="${line#*: }"; state="${state%% (*}"; state="${state% }"
        case "$state" in
            "not installed"|outdated) return 0 ;;
        esac
        break
    done <<EOF
$status
EOF
    # `--outdated-only` is a second, independent signal: an integration Herdr
    # considers current in the full listing can still be named here.
    while IFS= read -r line; do
        case "$line" in "$target"|"$target: "*) return 0 ;; esac
    done <<EOF
$outdated
EOF
    return 1
}

dx_ai_install_herdr_integrations() {
    local herdr_bin target status outdated
    herdr_bin="${HERDR_BIN_PATH:-}"
    [ -n "$herdr_bin" ] || herdr_bin="$(command -v herdr 2>/dev/null || true)"
    [ -n "$herdr_bin" ] || { echo "Herdr is unavailable; skipping agent integrations."; return 0; }
    status="$("$herdr_bin" integration status 2>/dev/null)" || { echo "Warning: could not read Herdr integration status." >&2; return 0; }
    outdated="$("$herdr_bin" integration status --outdated-only 2>/dev/null || true)"
    for target in "${DX_AI_HERDR_INTEGRATIONS[@]}"; do
        dx_ai_herdr_integration_needs_install "$target" "$status" "$outdated" || continue
        if "$herdr_bin" integration install "$target"; then
            echo "Installed the Herdr $target integration."
        else
            echo "Warning: could not install the Herdr $target integration." >&2
        fi
    done
}

dx_ai_verify() {
    local tool generation="${1:-}" tools executable
    echo "AI tools installed:"
    if [ -n "$generation" ]; then
        tools="$(dx_ai_generation_tools "$generation")" || return 1
        while IFS= read -r tool; do
            executable="$generation/profile/bin/$tool"
            [ -f "$executable" ] && [ -x "$executable" ] \
                || { echo "Error: generation executable is missing: $executable" >&2; return 1; }
        done <<EOF
$tools
EOF
        while IFS= read -r tool; do printf '  %s -> %s\n' "$tool" "$generation/profile/bin/$tool"; done <<EOF
$tools
EOF
    else
        for tool in $DX_AI_TOOLS; do printf '  %s -> ' "$tool"; command -v "$tool" || return 1; done
    fi
}

# Fable B4/B7: acquire $1's lock, run $2 (with any further args) under it,
# and release it exactly once -- on a normal return AND on HUP/INT/TERM/exit
# -- replacing what used to be a release-and-clear-trap epilogue copied at
# every early-return site in dx_ai_main. $stage is script-global (not local
# to any one function): whichever function is running when a signal fires
# still has it in scope, so an in-flight AI generation stage is always
# discarded on the same trap that releases the lock, and a killed run never
# leaves an orphan pinned under /nix/var/nix/gcroots/auto.
dx_ai_run_locked() {
    local lock="$1" result
    shift
    dx_ai_load_lock || return 1
    dx_ai_lock_acquire "$lock" || return 1
    trap 'rm -rf "${stage:-}"; dx_ai_lock_release "${lock:-}" 2>/dev/null || true' EXIT HUP INT TERM
    "$@"
    result=$?
    dx_ai_lock_release "$lock"
    trap - EXIT HUP INT TERM
    return "$result"
}

# The critical section of a normal (non-recover) dx-ai run, run under
# dx_ai_run_locked's lock: stage a fresh generation from the published
# bootstrap, refresh its lock file, refuse a binary-cache miss, build the AI
# tools profile, and publish it. $stage is intentionally not `local` here --
# see dx_ai_run_locked above -- and is always cleared before returning,
# whether this succeeds or fails.
dx_ai_main_update() {
    local published="$1" state="$2" id="$3" system="$4" result=0
    stage="$(dx_ai_stage_generation "$published" "$state" "$id")" || return 1
    dx_ai_update_flake "$stage" "$system" || result=$?
    [ "$result" -ne 0 ] || dx_ai_ensure_cached "$stage" "$state" "$system" || result=$?
    [ "$result" -ne 0 ] || dx_ai_install_profile "$stage" || result=$?
    [ "$result" -ne 0 ] || dx_ai_publish_generation "$state" "$id" "$stage" || result=$?
    if [ "$result" -ne 0 ]; then
        rm -rf "$stage"
        stage=""
        return "$result"
    fi
    stage=""
    return 0
}

dx_ai_main() {
    local action=update published state id lock system result
    stage=""
    case "${1:-}" in
        -h|--help) dx_ai_usage; return ;;
        --recover) action=recover; shift ;;
        --supports)
            local tool="${2:-}"
            [ "$#" -eq 2 ] || { dx_ai_usage >&2; return 64; }
            dx_ai_tool_known "$tool"
            return
            ;;
    esac
    [ "$#" -eq 0 ] || { dx_ai_usage >&2; return 64; }
    [ "$(id -u)" -ne 0 ] || { dx_ai_fail "run dx-ai as the dx user, not root."; return 1; }
    state="${DX_AI_STATE_ROOT:-/persist/home/dx/.local/state/dx-ai}"; lock="$state/.lock"; id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"

    if [ "$action" = recover ]; then
        dx_ai_run_locked "$lock" dx_ai_recover_generation "$state"
        result=$?
        [ "$result" -eq 0 ] || return "$result"
        export PATH="$state/current/profile/bin:$PATH"
        dx_ai_verify "$state/current"
        return
    fi

    published="$(dx_ai_published_root)"
    [ -f "$published/flake.nix" ] || { dx_ai_fail "published bootstrap flake is missing: $published/flake.nix"; return 1; }
    # Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 4):
    # resolve this guest's own system once, via the shared helper (also used
    # by bootstrap.sh), and adjust DX_AI_TOOLS (a global the staging/
    # validation/verify functions below already read) BEFORE staging, so a
    # system with no native agy artifact stages, publishes, and verifies a
    # generation that never claims agy. Neither of these touches $state, so
    # they run before the lock is even acquired.
    dx_ai_load_guest_system || return 1
    system="$(dx_guest_resolve_system)" || return 1
    DX_AI_TOOLS="$(dx_ai_tools_for_system "$published" "$system" | tr '\n' ' ')"; DX_AI_TOOLS="${DX_AI_TOOLS% }"

    dx_ai_run_locked "$lock" dx_ai_main_update "$published" "$state" "$id" "$system"
    result=$?
    [ "$result" -eq 0 ] || return "$result"

    export PATH="$state/current/profile/bin:$PATH"
    dx_ai_setup_credentials /persist/home/dx "$HOME" || return
    dx_ai_ensure_keyring || return
    # Herdr is optional, so a missing or unhappy integration is reported but
    # never fails an otherwise successful AI update.
    dx_ai_install_herdr_integrations
    dx_ai_verify "$state/current"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; dx_ai_main "$@"; fi
