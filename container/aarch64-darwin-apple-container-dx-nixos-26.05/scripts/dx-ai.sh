#!/usr/bin/env bash

AGY_MANIFEST_URL="${AGY_MANIFEST_URL:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json}"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --accept-flake-config)

dx_ai_usage() {
    cat <<'EOF'
Usage: dx-ai [--recover]

Install or update Codex, Gemini, Claude, and Antigravity from an immutable
working generation under /persist. The published bootstrap is never modified.
Use --recover to repoint current to its retained predecessor generation.
EOF
}

dx_ai_published_root() {
    local root="${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}"
    if [ -L "$root/current" ] && [ -f "$root/current/flake.nix" ]; then readlink -f "$root/current"; else printf '%s\n' "$root"; fi
}

dx_ai_process_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

dx_ai_lock_acquire() {
    local lock="$1" elapsed=0 boot pid start live
    [ ! -L "${lock%/*}" ] || return 1
    mkdir -p "${lock%/*}" || return 1
    [ -d "${lock%/*}" ] && [ ! -L "${lock%/*}" ] || return 1
    while ! mkdir "$lock" 2>/dev/null; do
        if [ -f "$lock/owner" ]; then
            IFS="$(printf '\t')" read -r boot pid start < "$lock/owner" || true
            live="$(dx_ai_process_start "${pid:-0}" || true)"
            if [ "$boot" != "$(cat /proc/sys/kernel/random/boot_id)" ] || [ -z "$live" ] || [ "$start" != "$live" ]; then rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; continue; fi
        fi
        [ "$elapsed" -lt 30 ] || { echo "Error: timed out waiting for dx-ai publication lock." >&2; return 1; }
        sleep 1; elapsed=$((elapsed + 1))
    done
    printf '%s\t%s\t%s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$$" "$(dx_ai_process_start $$)" > "$lock/owner"
}

dx_ai_lock_release() { rm -f "$1/owner"; rmdir "$1"; }

dx_ai_refresh_pin() {
    local root="$1" manifest version url sha512_hex hash tmp
    echo "Refreshing Antigravity CLI manifest..."
    manifest="$(curl -fsSL "$AGY_MANIFEST_URL")" || { echo "Warning: could not fetch agy manifest. Keeping current pin." >&2; return 0; }
    version="$(printf '%s' "$manifest" | jq -r '.version // empty')"
    url="$(printf '%s' "$manifest" | jq -r '.url // empty')"
    sha512_hex="$(printf '%s' "$manifest" | jq -r '.sha512 // empty')"
    [ -n "$version" ] && [ -n "$url" ] && [ -n "$sha512_hex" ] || { echo "Warning: malformed agy manifest. Keeping current pin." >&2; return 0; }
    case "$url" in https://*) ;; *) echo "Warning: agy manifest URL is not HTTPS. Keeping current pin." >&2; return 0 ;; esac
    case "$sha512_hex" in *[!0-9A-Fa-f]*|'') echo "Warning: malformed agy manifest hash. Keeping current pin." >&2; return 0 ;; esac
    [ "${#sha512_hex}" -eq 128 ] || { echo "Warning: malformed agy manifest hash. Keeping current pin." >&2; return 0; }
    hash="$(nix hash convert --hash-algo sha512 --to sri "$sha512_hex")" || { echo "Warning: could not convert agy manifest hash. Keeping current pin." >&2; return 0; }
    tmp="$(mktemp "$root/pins/.agy.json.XXXXXX")" || return 1
    if ! jq --arg version "$version" --arg url "$url" --arg hash "$hash" '.version=$version | .url=$url | .hash=$hash' "$root/pins/agy.json" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ "$(cat "$tmp")" = "$(cat "$root/pins/agy.json")" ]; then rm -f "$tmp"; echo "Antigravity CLI pin is unchanged ($version)."; return 0; fi
    if ! mv -f "$tmp" "$root/pins/agy.json"; then rm -f "$tmp"; return 1; fi
    echo "Pinned agy $version from upstream manifest."
}

dx_ai_stage_generation() {
    local published="$1" state="$2" id="$3" stage predecessor=""
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    [ -d "$published" ] && [ ! -L "$published" ] || return 1
    [ ! -L "$state" ] && [ ! -L "$state/generations" ] || return 1
    stage="$state/generations/.staging-$id"
    mkdir -p "$state/generations" || return 1
    [ -d "$state/generations" ] && [ ! -L "$state/generations" ] || return 1
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 1
    mkdir "$stage" || return 1
    if ! cp -a "$published/." "$stage/" || ! chmod -R u+w "$stage"; then
        chmod -R u+w "$stage" 2>/dev/null || true
        rm -rf "$stage"
        return 1
    fi
    if [ -L "$state/current" ]; then predecessor="$(readlink "$state/current")"; predecessor=${predecessor##*/}; fi
    case "$predecessor" in '' ) ;; [.-]*|*[!A-Za-z0-9_.-]*) chmod -R u+w "$stage"; rm -rf "$stage"; return 1 ;; esac
    printf '%s\n' "$predecessor" > "$stage/.predecessor" || { chmod -R u+w "$stage"; rm -rf "$stage"; return 1; }
    printf '%s\n' "$stage"
}

dx_ai_update_flake() {
    local stage="$1"
    dx_ai_refresh_pin "$stage"
    echo "Updating nixpkgs-unstable..."
    (cd "$stage" && nix flake update "${NIX_FLAGS[@]}" nixpkgs-unstable)
    nix flake metadata "${NIX_FLAGS[@]}" "$stage" >/dev/null
}

dx_ai_install_profile() {
    local stage="$1"
    echo "Building an isolated optional AI tools profile..."
    nix profile add --profile "$stage/profile" "${NIX_FLAGS[@]}" "$stage#ai-tools"
}

dx_ai_validate_generation() {
    local generation="$1" required tool
    [ -d "$generation" ] && [ ! -L "$generation" ] || return 1
    for required in flake.nix flake.lock pins/agy.json .predecessor; do [ -f "$generation/$required" ] && [ ! -L "$generation/$required" ] || return 1; done
    for tool in codex gemini claude agy; do [ -x "$generation/profile/bin/$tool" ] || return 1; done
}

dx_ai_publish_pointer() {
    local state="$1" id="$2" tmp
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    tmp="$state/.current.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    if ! ln -s "generations/$id" "$tmp"; then return 1; fi
    if ! mv -Tf "$tmp" "$state/current"; then rm -f "$tmp"; return 1; fi
}

dx_ai_collect_generations() {
    local state="$1" current="$2" predecessor="$3" candidate candidate_id
    for candidate in "$state/generations"/*; do
        [ -d "$candidate" ] || continue; candidate_id=${candidate##*/}
        if [ -L "$candidate" ]; then rm -f "$candidate"; continue; fi
        [ "$candidate_id" = "$current" ] && continue
        [ -n "$predecessor" ] && [ "$candidate_id" = "$predecessor" ] && continue
        chmod -R u+w "$candidate" 2>/dev/null || true
        rm -rf "$candidate" || echo "Warning: could not collect obsolete AI generation $candidate_id." >&2
    done
}

dx_ai_publish_generation() {
    local state="$1" id="$2" stage="$3" generation predecessor=""
    generation="$state/generations/$id"
    case "$id" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    [ ! -e "$generation" ] && [ ! -L "$generation" ] || return 1
    dx_ai_validate_generation "$stage" || return 1
    mv "$stage" "$generation" || return 1
    if ! chmod -R a-w "$generation"; then chmod -R u+w "$generation" 2>/dev/null || true; rm -rf "$generation"; return 1; fi
    if ! dx_ai_publish_pointer "$state" "$id"; then
        chmod -R u+w "$generation"; rm -rf "$generation"; return 1
    fi
    predecessor="$(cat "$generation/.predecessor")" || return 1
    dx_ai_collect_generations "$state" "$id" "$predecessor"
}

dx_ai_recover_generation() {
    local state="$1" current_target current predecessor
    [ -L "$state/current" ] || { echo "Error: no AI generation is currently published." >&2; return 1; }
    current_target="$(readlink "$state/current")"
    case "$current_target" in generations/*) current=${current_target#generations/} ;; *) echo "Error: invalid AI current pointer." >&2; return 1 ;; esac
    case "$current" in ''|*/*|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: invalid AI current generation." >&2; return 1 ;; esac
    dx_ai_validate_generation "$state/generations/$current" || { echo "Error: current AI generation is incomplete." >&2; return 1; }
    predecessor="$(cat "$state/generations/$current/.predecessor")" || return 1
    case "$predecessor" in ''|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: no valid retained AI predecessor is available." >&2; return 1 ;; esac
    dx_ai_validate_generation "$state/generations/$predecessor" || { echo "Error: retained AI predecessor is incomplete." >&2; return 1; }
    dx_ai_publish_pointer "$state" "$predecessor" || return 1
    echo "Recovered AI generation $predecessor (from $current)."
}

dx_ai_setup_credentials() {
    local persist_home=/persist/home/dx settings tmp
    mkdir -p "$persist_home/.gemini/antigravity-cli" "$persist_home/.claude" "$persist_home/.codex" "$persist_home/.local/share/keyrings"
    [ -s "$persist_home/.claude.json" ] || printf '%s\n' '{}' > "$persist_home/.claude.json"
    ln -sfn "$persist_home/.gemini" ~/.gemini; ln -sfn "$persist_home/.claude" ~/.claude
    ln -sfn "$persist_home/.claude.json" ~/.claude.json; ln -sfn "$persist_home/.codex" ~/.codex
    mkdir -p ~/.local/share; ln -sfnT "$persist_home/.local/share/keyrings" ~/.local/share/keyrings
    settings="$persist_home/.claude/settings.json"; [ -s "$settings" ] || printf '%s\n' '{}' > "$settings"
    if ! jq -e '.statusLine' "$settings" >/dev/null 2>&1; then tmp="$settings.tmp.$$"; jq '. + {statusLine: {type: "command", command: "dx-claude-statusline"}}' "$settings" > "$tmp"; mv "$tmp" "$settings"; fi
}

dx_ai_ensure_keyring() {
    local library="$HOME/.local/lib/dx/dx-keyring.sh" address_file=/persist/home/dx/.local/state/dx/keyring-address address="" config started=false
    [ -f "$library" ] || { echo "Error: packaged keyring library is missing: $library" >&2; return 1; }
    # shellcheck source=lib/dx-keyring.sh
    source "$library"
    address="$(dx_keyring_read_address "$address_file" 2>/dev/null || true)"
    if ! dx_keyring_address_is_live "$address"; then
        command -v dbus-daemon >/dev/null && command -v gnome-keyring-daemon >/dev/null || { echo "Warning: keyring services are unavailable."; return 0; }
        config="$(dx_keyring_session_config "$(command -v dbus-daemon)")"
        address="$(dbus-daemon --config-file="$config" --fork --print-address)"
        dx_keyring_write_address "$address_file" "$address" || return 1
        started=true
    fi
    export DBUS_SESSION_BUS_ADDRESS=$address
    printf '' | gnome-keyring-daemon --unlock --start --components=secrets >/dev/null 2>&1 || true
    if [ "$started" = true ]; then echo "D-Bus keyring service started."; else echo "D-Bus keyring service already available."; fi
}

dx_ai_verify() { local tool; echo "AI tools installed:"; for tool in codex gemini claude agy; do printf '  %s -> ' "$tool"; command -v "$tool"; done; }

dx_ai_main() {
    local action=update published state id stage="" lock result=0
    case "${1:-}" in -h|--help) dx_ai_usage; return ;; --recover) action=recover; shift ;; esac
    [ "$#" -eq 0 ] || { dx_ai_usage >&2; return 64; }
    [ "$(id -u)" -ne 0 ] || { echo "Error: run dx-ai as the dx user, not root." >&2; return 1; }
    state="${DX_AI_STATE_ROOT:-/persist/home/dx/.local/state/dx-ai}"; lock="$state/.lock"; id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"
    dx_ai_lock_acquire "$lock" || return
    trap 'rm -rf "${stage:-}"; dx_ai_lock_release "${lock:-}" 2>/dev/null || true' EXIT HUP INT TERM
    if [ "$action" = recover ]; then
        dx_ai_recover_generation "$state" || result=$?
        dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM
        [ "$result" -eq 0 ] || return "$result"
        export PATH="$state/current/profile/bin:$PATH"
        dx_ai_verify
        return
    fi
    published="$(dx_ai_published_root)"; [ -f "$published/flake.nix" ] || { echo "Error: published bootstrap flake is missing." >&2; dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM; return 1; }
    if ! stage="$(dx_ai_stage_generation "$published" "$state" "$id")"; then dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM; return 1; fi
    dx_ai_update_flake "$stage" || result=$?
    [ "$result" -ne 0 ] || dx_ai_install_profile "$stage" || result=$?
    [ "$result" -ne 0 ] || dx_ai_publish_generation "$state" "$id" "$stage" || result=$?
    if [ "$result" -ne 0 ]; then rm -rf "$stage"; dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM; return "$result"; fi
    stage=""
    export PATH="$state/current/profile/bin:$PATH"
    dx_ai_lock_release "$lock"; lock=""; trap - EXIT HUP INT TERM
    dx_ai_setup_credentials || return
    dx_ai_ensure_keyring || return
    dx_ai_verify
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; dx_ai_main "$@"; fi
