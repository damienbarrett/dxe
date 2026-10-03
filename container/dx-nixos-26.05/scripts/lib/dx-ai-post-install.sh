#!/usr/bin/env bash
# dx-ai's post-install steps: AI-credential symlinks, the keyring, and Herdr
# agent integrations. Safe to source (import-only). Moved out of dx-ai.sh
# (Fable B7) so this logic sits under scripts/lib, in kcov's coverage scope
# (unlike scripts/*.sh -- see tests/coverage/exclusions.txt).

# dx_ai_load_opencode_persistence/dx_ai_load_keyring (called just below) are
# thin wrappers over dx_ai_load_library, defined back in dx-ai.sh rather
# than here: dx_ai_load_library resolves candidate 1 (the CALLING script's
# own colocated lib/ directory) from the calling frame's own file
# (BASH_SOURCE[1]), and dx-ai.sh -- not this already-inside-scripts/lib/
# file -- is the one whose sibling lib/ directory candidate 1 is meant to
# name. Bash functions are process-global regardless of which sourced file
# defines them, so calling them from here is exactly like calling any other
# already-loaded function.

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

# Fable B9: .gemini/.claude/.codex/.local/share/keyrings each go through the
# shared dx_persist_relocate_dir (scripts/lib/dx-persist-relocate.sh, eagerly
# loaded by dx-ai.sh alongside this file) -- a pre-existing REAL directory at
# any of these is relocated into $persist_home (conflicts renamed aside)
# rather than either silently nested into (the old activation.sh `ln -sfn`
# shape) or failing loudly with no recovery (the old dx-ai.sh `ln -sfnT`
# shape, whose failure this function's own `||` call chain never surfaced
# anyway -- see dx_ai_main). .claude.json is a FILE, not a directory, so it
# keeps its own simple seed-if-missing-then-link shape; nothing here ever
# owned relocating a pre-existing real file at that exact path.
dx_ai_setup_credentials() {
    local persist_home="${1:-/persist/home/dx}" home="${2:-$HOME}" settings
    dx_ai_load_opencode_persistence || return 1
    dx_ai_opencode_persistence "$persist_home" "$home" || return 1
    mkdir -p "$persist_home" "$persist_home/.local/share" "$home/.config" "$home/.local/share" || return 1
    dx_persist_relocate_dir "$home/.gemini" "$persist_home/.gemini" "$persist_home" gemini || return 1
    mkdir -p "$persist_home/.gemini/antigravity-cli" || return 1
    dx_persist_relocate_dir "$home/.claude" "$persist_home/.claude" "$persist_home" claude || return 1
    dx_persist_relocate_dir "$home/.codex" "$persist_home/.codex" "$persist_home" codex || return 1
    dx_persist_relocate_dir "$home/.local/share/keyrings" "$persist_home/.local/share/keyrings" "$persist_home/.local/share" keyrings || return 1
    [ -s "$persist_home/.claude.json" ] || printf '%s\n' '{}' > "$persist_home/.claude.json"
    ln -sfnT "$persist_home/.claude.json" "$home/.claude.json"
    settings="$persist_home/.claude/settings.json"; [ -s "$settings" ] || printf '%s\n' '{}' > "$settings"
    if ! jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
        dx_ai_merge_json_setting "$settings" '. + {statusLine: {type: "command", command: "dx-claude-statusline"}}' || return 1
    fi
}

# After a successful dx-ai in a guest in usage-service mode (the s6 service
# directory exists), restart ONLY agent-stats so it picks up the new
# generation's PATH, then check it still works with it. Outside service mode
# this is a silent no-op. The AI update itself already succeeded, so a failed
# restart or check is reported loudly but never fails dx-ai, and nothing is
# rolled back: shared tools are never silently reverted. s6-svc needs root,
# hence sudo, and the absolute path through the service directory's .s6-bin
# link (the essentials profile is not on dx's PATH).
dx_ai_usage_service_hook() {
    local state="$1" scan="${DX_USAGE_SCAN_DIR:-/run/dx-services}"
    [ -d "$scan/agent-stats" ] || return 0
    echo "Restarting the usage service (agent-stats) on the new AI generation..."
    if ! sudo -n "$scan/.s6-bin/s6-svc" -r "$scan/agent-stats"; then
        echo "Warning: could not restart agent-stats; it keeps running on the previous PATH (no rollback was performed). Try: dx-usage-service restart" >&2
        return 0
    fi
    dx_ai_usage_service_compat_check "$state/current" || echo "Warning: the usage service compatibility check failed against the new AI generation; no rollback was performed. Inspect with: dx-usage-service logs" >&2
    return 0
}

# STUB until the package is installed. The agreed check: with the new
# generation's profile/bin first on PATH, `agent-stats-rust --version` (from
# /persist/services/agent-stats/current/bin) must succeed, as dx. Returns 0 so
# the hook is complete and testable; replace the body with that check.
dx_ai_usage_service_compat_check() {
    echo "Usage service compatibility check not implemented yet (agreed check: agent-stats-rust --version succeeds on the new PATH under $1/profile/bin)."
    return 0
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
