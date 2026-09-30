#!/usr/bin/env bash
# dx-ai's Antigravity CLI (agy) pin: the per-system manifest URL and the
# refresh that keeps pins/agy.json current. Safe to source (import-only).
# Moved out of dx-ai.sh (Fable B7) so this logic sits under scripts/lib, in
# kcov's coverage scope (unlike scripts/*.sh -- see
# tests/coverage/exclusions.txt).

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
