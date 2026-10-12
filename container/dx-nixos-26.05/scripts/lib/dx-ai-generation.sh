#!/usr/bin/env bash
# dx-ai's generation lifecycle: stage a fresh generation from the published
# bootstrap, build its profile, validate it, publish it with a Nix GC root
# at its final path, collect obsolete ones, recover to a retained
# predecessor, and verify what is installed.
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

# Owner-write bit from the mode itself, not access(2): `[ -w ]` is always
# true for root, and the question is what dx (the owner) may do.
dx_ai_owner_writable() {
    local mode
    mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)" || return 1
    [ $((8#$mode & 8#200)) -ne 0 ]
}

# A Nix GC root for a generation at its FINAL path (fix/dx-ai-gcroot).
# `nix profile add --profile <stage>/profile` registers an indirect root by
# the generation link's unresolved path (gcroots/auto/<hash> ->
# .staging-<id>/profile-1-link); publishing renames the stage, that root
# dangles, and the next `nix-collect-garbage` deletes the profile `current`
# points at. This registers the same kind of root where the link now lives,
# through Nix's documented interface (as docs/qnap-runbook.md does for the
# usage service): `nix-store --add-root <gen>/profile-1-link --indirect -r
# <store path>`. Nix replaces that link through a temporary symlink beside
# it, so a read-only generation is made owner-writable for the call only and
# read-only again whatever the outcome. Never rebuilds, never touches
# gcroots/ itself, and prints no Error:/Warning: line of its own (callers
# decide what a failure means). A profile that is a plain directory has no
# store path to root; any other shape than Nix's own (profile -> a link
# beside it -> a store path) is refused.
dx_ai_root_generation() {
    local generation="$1" link store_path unlocked=0 result=0
    [ -L "$generation/profile" ] || return 0
    link="$(readlink "$generation/profile")"
    case "$link" in ''|.|..|*/*) return 1 ;; esac
    store_path="$(readlink "$generation/$link")" || return 1
    if ! dx_ai_owner_writable "$generation"; then
        chmod u+w "$generation" || return 1
        unlocked=1
    fi
    nix-store --add-root "$generation/$link" --indirect -r "$store_path" >/dev/null || result=1
    if [ "$unlocked" -eq 1 ]; then chmod u-w "$generation" || result=1; fi
    return "$result"
}

# Removes every .staging-* stage under a generations directory. Only ever
# called under the publication lock, by a run that has not staged anything
# yet (dx_ai_reconcile_roots) or has already moved its own stage into place
# (dx_ai_collect_generations), so every stage found here is an abandoned
# one. The root Nix registered for it dangles once it is gone and pins
# nothing; Nix's own GC prunes that link (gcroots/ belongs to Nix).
dx_ai_discard_stages() {
    local generations="$1" candidate
    for candidate in "$generations"/.staging-*; do
        [ -d "$candidate" ] || continue
        if [ -L "$candidate" ]; then rm -f "$candidate"; continue; fi
        chmod -R u+w "$candidate" 2>/dev/null || true
        rm -rf "$candidate" || echo "Warning: could not remove abandoned AI generation stage ${candidate##*/}." >&2
    done
}

# Roots one retained generation, by id, for dx_ai_reconcile_roots: non-zero,
# quietly, when there is no such plain generation directory; a Warning when
# it exists but cannot be rooted (its store path is already gone).
dx_ai_reconcile_root() {
    local generations="$1" id="$2"
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    [ -d "$generations/$id" ] && [ ! -L "$generations/$id" ] || return 1
    dx_ai_root_generation "$generations/$id" \
        || echo "Warning: could not register a GC root for AI generation $id" >&2
}

# The start of every locked dx-ai run (update and --recover), under the
# publication lock and before anything is staged or recovered: remove
# abandoned stages, then root current and the predecessor its .predecessor
# records at their final paths. That heals a guest whose generations were
# published before publish rooted them (their only root still names a
# vanished stage) without rebuilding anything. Never fails the run: an
# unrootable generation is a Warning, an update then builds a replacement,
# and --recover's own validation decides whether the predecessor is usable.
# A symlinked state root or generations directory is never followed
# (dx_ai_stage_generation refuses it with its own error).
dx_ai_reconcile_roots() {
    local state="$1" generations="$1/generations" current predecessor
    [ ! -L "$state" ] && [ ! -L "$generations" ] && [ -d "$generations" ] || return 0
    dx_ai_discard_stages "$generations"
    [ -L "$state/current" ] || return 0
    current="$(readlink "$state/current")"
    case "$current" in generations/*) current=${current#generations/} ;; *) return 0 ;; esac
    dx_ai_reconcile_root "$generations" "$current" || return 0
    predecessor="$(cat "$generations/$current/.predecessor" 2>/dev/null)" || return 0
    dx_ai_reconcile_root "$generations" "$predecessor"
    return 0
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
    # The root `nix profile add` registered names the stage path, which the
    # rename just emptied: root the final path before current can point at
    # it. A GC that lands in between makes this fail (the store path is
    # gone), and current then stays on its rooted predecessor.
    if ! dx_ai_root_generation "$generation"; then
        chmod -R u+w "$generation" 2>/dev/null || true
        rm -rf "$generation"
        dx_ai_fail "could not register a GC root for AI generation $id"
        return 1
    fi
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

# The --recover counterpart of dx-ai.sh's dx_ai_main_update: the critical
# section dx_ai_run_locked runs under the publication lock. Here, not in
# dx-ai.sh, so it sits in kcov's coverage scope.
dx_ai_main_recover() {
    dx_ai_reconcile_roots "$1"
    dx_ai_recover_generation "$1"
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
