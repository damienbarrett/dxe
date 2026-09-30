#!/usr/bin/env bash
# dx-ai's generation lifecycle: stage a fresh generation from the published
# bootstrap, build its profile, validate it, publish it, collect obsolete
# ones, recover to a retained predecessor, and verify what is installed.
# Safe to source (import-only). Moved out of dx-ai.sh (Fable B7) so this
# logic sits under scripts/lib, in kcov's coverage scope (unlike
# scripts/*.sh -- see tests/coverage/exclusions.txt).
#
# Depends on dx_ai_fail (dx-ai.sh) and, for validation/verify, on
# DX_AI_TOOLS/DX_AI_LEGACY_TOOLS (dx-ai.sh globals) -- all present in the
# same process by the time any of these functions actually runs, since
# dx-ai.sh loads this library eagerly, right after defining them.

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
        '') : ;;
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
    done < "$manifest" # KCOV_LOOP_TERMINATOR
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
            .staging-*) : ;;
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
