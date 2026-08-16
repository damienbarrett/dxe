#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Herdr configuration and session persistence"

BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
PERSISTENCE="$BOOTSTRAP_DIR/persistence.sh"
ACTIVATION="$BOOTSTRAP_DIR/activation.sh"
TEMPLATE="$BOOTSTRAP_DIR/herdr-config.toml"
MERGER="$BOOTSTRAP_DIR/herdr-config.sh"

assert_file_exists "$TEMPLATE" "repository owns a canonical Herdr config template"
assert_file_exists "$MERGER" "repository owns the Herdr config merger"
assert_file_contains_literal "$TEMPLATE" 'prefix = "ctrl+space"' "Herdr template keeps the tmux-style prefix"
assert_file_contains_literal "$TEMPLATE" 'key = "ctrl+h"' "Herdr template includes prefix-free left navigation"
assert_file_contains_literal "$TEMPLATE" 'key = "prefix+shift+h"' "Herdr template includes tmux-style left resize"
assert_file_contains_literal "$TEMPLATE" 'previous_agent = "prefix+shift+up"' "Herdr template includes previous-agent navigation"
assert_file_contains_literal "$TEMPLATE" 'focus_agent = "prefix+alt+1..9"' "Herdr template includes indexed agent focus"
assert_file_contains_literal "$TEMPLATE" 'agent_panel_sort = "priority"' "Herdr template treats the agent sidebar as an attention queue"
assert_file_contains_literal "$TEMPLATE" 'pane_history = true' "Herdr template persists pane history"
assert_file_contains_literal "$TEMPLATE" 'scrollback_limit_bytes = 10000000' "Herdr template keeps the configured scrollback limit"

if [ ! -f "$TEMPLATE" ] || [ ! -f "$MERGER" ]; then
    print_summary
    exit_with_code
fi

# Everything below executes the guest config merger and the guest bootstrap
# functions for real. Both are guest code and assume the guest's toolchain:
# the merger needs Bash 4+ associative arrays and `sha256sum`, and the
# persistence functions need `ln -sfnT`, none of which a stock macOS host has.
# Executing guest bootstrap code for real is the Linux coverage runner's job
# (tests/run-coverage-linux.sh drives these same functions in a container and
# holds them to the 100% ratchet); this file adds the behavior assertions on
# top, and CI runs it on ubuntu-24.04. So skip off Linux rather than assert
# against a toolchain the guest will never run -- the same guard shape as
# tests/test_section12_validate_linux.sh.
if [ "$(uname -s)" != Linux ]; then
    test_skip "Herdr merger and persistence execution need the guest Linux toolchain; covered by run-coverage-linux.sh and CI"
    print_summary
    exit_with_code
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-herdr-config-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# The merger is a sourceable bootstrap module, like scripts/lib/dx-keyring.sh,
# so drive its function rather than executing the file. Each call runs in a
# subshell: it publishes through a RETURN trap and resets its own globals, and
# a failing case must not take this script's shell with it.
# shellcheck source=/dev/null
source "$MERGER"
seed_config() ( dx_herdr_seed_config "$1" "$2" )

fresh="$fixture/fresh/config.toml"
if seed_config "$TEMPLATE" "$fresh"; then
    test_pass "fresh Herdr config is seeded"
else
    test_fail "fresh Herdr config is seeded"
fi
assert_file_contains_literal "$fresh" 'prefix = "ctrl+space"' "fresh config receives repository key bindings"
assert_file_contains_literal "$fresh" 'command = "$HOME/.local/bin/dx-herdr-navigate left ctrl+h"' "fresh config uses the Home Manager-installed navigation helper"
assert_file_contains_literal "$fresh" 'description = "resize pane left"' "fresh custom bindings appear clearly in Herdr help"
assert_file_contains_literal "$fresh" 'rows = [["state_icon", "agent", "state_text"], ["workspace", "tab"]]' "fresh config receives the task-oriented agent row layout"
if [ -f "$fresh" ] && [ "$(file_mode "$fresh")" = 600 ]; then
    test_pass "seeded Herdr config is private"
else
    test_fail "seeded Herdr config is private"
fi

if command -v herdr >/dev/null 2>&1; then
    if HERDR_CONFIG_PATH="$fresh" herdr config check >/dev/null; then
        test_pass "canonical Herdr template passes the installed config validator"
    else
        test_fail "canonical Herdr template passes the installed config validator"
    fi
else
    test_skip "installed Herdr config validator is unavailable"
fi

fresh_before="$(shasum -a 256 "$fresh" | cut -d' ' -f1)"
idempotent_output=""
if idempotent_output="$(seed_config "$TEMPLATE" "$fresh" 2>&1)"; then
    fresh_after="$(shasum -a 256 "$fresh" | cut -d' ' -f1)"
    if [ "$fresh_before" = "$fresh_after" ] && [ -z "$idempotent_output" ]; then
        test_pass "Herdr seeding is byte-idempotent and silent"
    else
        test_fail "Herdr seeding is byte-idempotent and silent"
    fi
else
    test_fail "Herdr seeding is byte-idempotent and silent"
fi

existing="$fixture/existing/config.toml"
mkdir -p "$(dirname "$existing")"
cat > "$existing" <<'EOF'
# User-owned settings must survive DXE default updates.
[keys]
detach = "prefix+q"

[[keys.command]]
key = 'prefix+g'
type = "popup"
command = "custom-g"

[ui]
sidebar_width = 31
agent_panel_sort = "spaces"

[theme]
name = "user-theme"
EOF

if seed_config "$TEMPLATE" "$existing"; then
    test_pass "existing Herdr config accepts missing DXE defaults"
else
    test_fail "existing Herdr config accepts missing DXE defaults"
fi
assert_file_contains_literal "$existing" 'detach = "prefix+q"' "explicit user key values win over DXE defaults"
assert_file_contains_literal "$existing" 'command = "custom-g"' "existing custom command wins on a matching key"
assert_file_not_contains "$existing" '^command = "lazygit"$' "DXE does not duplicate an explicitly occupied command key"
assert_file_contains_literal "$existing" 'sidebar_width = 31' "unrelated UI settings survive Herdr seeding"
assert_file_contains_literal "$existing" 'agent_panel_sort = "spaces"' "explicit user sidebar ordering wins over DXE defaults"
assert_file_contains_literal "$existing" 'name = "user-theme"' "theme-managed data survives Herdr seeding"
assert_file_contains_literal "$existing" 'prefix = "ctrl+space"' "missing key defaults are added to an existing config"
if [ "$(grep -Fc "key = 'prefix+g'" "$existing")" -eq 1 ] \
    && ! grep -Fq 'key = "prefix+g"' "$existing"; then
    test_pass "single-quoted TOML command keys remain unique after merge"
else
    test_fail "single-quoted TOML command keys remain unique after merge"
fi

occupied="$fixture/occupied/config.toml"
mkdir -p "$(dirname "$occupied")"
cat > "$occupied" <<'EOF'
[keys]
goto = 'prefix+g'
EOF
if seed_config "$TEMPLATE" "$occupied"; then
    if grep -Fq "goto = 'prefix+g'" "$occupied" \
        && grep -Fq 'prefix = "ctrl+space"' "$occupied" \
        && grep -Fq 'agent_panel_sort = "priority"' "$occupied" \
        && ! grep -Fq 'command = "lazygit"' "$occupied"; then
        test_pass "custom commands do not collide with occupied built-in bindings"
    else
        test_fail "custom commands do not collide with occupied built-in bindings"
    fi
else
    test_fail "custom commands do not collide with occupied built-in bindings"
fi

occupied_default="$fixture/occupied-default/config.toml"
mkdir -p "$(dirname "$occupied_default")"
cat > "$occupied_default" <<'EOF'
[keys]
detach = "prefix+f"

[[keys.command]]
key = "ctrl+space"
type = "shell"
command = "custom-prefix-action"
EOF
if seed_config "$TEMPLATE" "$occupied_default"; then
    if grep -Fq 'detach = "prefix+f"' "$occupied_default" \
        && grep -Fq 'command = "custom-prefix-action"' "$occupied_default" \
        && ! grep -Fq 'goto = "prefix+f"' "$occupied_default" \
        && ! grep -Fq 'prefix = "ctrl+space"' "$occupied_default"; then
        test_pass "built-in defaults do not collide with explicit existing bindings"
    else
        test_fail "built-in defaults do not collide with explicit existing bindings"
    fi
else
    test_fail "built-in defaults do not collide with explicit existing bindings"
fi

invalid="$fixture/invalid/config.toml"
mkdir -p "$(dirname "$invalid")" "$fixture/bin"
printf '%s\n' '[ui]' 'sidebar_width = 42' > "$invalid"
cat > "$fixture/bin/herdr-reject" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$fixture/bin/herdr-reject"
invalid_before="$(shasum -a 256 "$invalid" | cut -d' ' -f1)"
if DX_HERDR_CONFIG_CHECK_BIN="$fixture/bin/herdr-reject" seed_config "$TEMPLATE" "$invalid" >/dev/null 2>&1; then
    test_fail "invalid merged Herdr config is rejected"
else
    invalid_after="$(shasum -a 256 "$invalid" | cut -d' ' -f1)"
    if [ "$invalid_before" = "$invalid_after" ]; then
        test_pass "validation failure leaves the original config untouched"
    else
        test_fail "validation failure leaves the original config untouched"
    fi
fi

# shellcheck source=/dev/null
source "$PERSISTENCE"
# shellcheck source=/dev/null
source "$ACTIVATION"
persist_home="$fixture/persist/home/dx"
home="$fixture/home/dx"
mkdir -p "$persist_home" "$home"

chown_log="$fixture/chown-calls"
: > "$chown_log"
if declare -F setup_herdr_persistence >/dev/null; then
    if (
        # Recording stub, not a no-op. These tests do not run as root, so every
        # path this creates is already owned by the caller and an ownership
        # assertion would pass whether or not the code chowns anything --
        # the blindspot that let the ~/.local defect reach a live guest.
        # Recording the calls asserts the privilege contract instead.
        chown() { printf '%s\n' "$*" >> "$chown_log"; }
        run_as_dx() { bash -c "$1"; }
        setup_herdr_persistence "$persist_home" "$home"
    ); then
        test_pass "Herdr persistence activates against a disposable home"
    else
        test_fail "Herdr persistence activates against a disposable home"
    fi
else
    test_fail "setup_herdr_persistence is sourceable"
fi

if [ -L "$home/.config/herdr" ] && [ "$(readlink "$home/.config/herdr")" = "$persist_home/.config/herdr" ]; then
    test_pass "Herdr configuration is linked to persistent storage"
else
    test_fail "Herdr configuration is linked to persistent storage"
fi

# Live defect: `mkdir -p ~/.local/state` runs as root and creates the
# intermediate ~/.local as root too, but only the leaves were chowned. Herdr
# activation runs before Home Manager in configure_guest, so HM then ran as dx
# against a root-owned ~/.local and died with "cannot create directory
# '/home/dx/.local/share'". It took dx-test down on recreate and was invisible
# to the factory-reset path, where Nix had already created ~/.local as dx.
#
# Asserts ownership rather than a mode: the failing operation is dx creating a
# new subdirectory, so that is what this reproduces.
if grep -Fq "$home/.local " "$chown_log" || grep -Fqx "dx:dx $home/.config $home/.local/state $home/.local" "$chown_log"; then
    test_pass "Herdr activation hands the shared ~/.local root to dx"
else
    test_fail "Herdr activation hands the shared ~/.local root to dx (chowned: $(tr '\n' '; ' < "$chown_log"))"
fi
# ~/.local is a shared XDG root -- Home Manager's share/ and bin/, the Nix
# profile under state/nix -- so it must not be forced private the way the
# Herdr-owned leaves are.
if [ "$(file_mode "$home/.local")" != 700 ]; then
    test_pass "the shared ~/.local root keeps a mode other tools can use"
else
    test_fail "the shared ~/.local root keeps a mode other tools can use"
fi
if [ -L "$home/.local/state/herdr" ] && [ "$(readlink "$home/.local/state/herdr")" = "$persist_home/.local/state/herdr" ]; then
    test_pass "Herdr sessions are linked to persistent storage"
else
    test_fail "Herdr sessions are linked to persistent storage"
fi

migrate_persist="$fixture/migrate/persist/home/dx"
migrate_home="$fixture/migrate/home/dx"
mkdir -p "$migrate_persist" "$migrate_home/.config/herdr" "$migrate_home/.local/state/herdr"
printf '%s\n' migrated > "$migrate_home/.config/herdr/user-marker"
printf '%s\n' session > "$migrate_home/.local/state/herdr/session-marker"
if (
    chown() { :; }
    run_as_dx() { bash -c "$1"; }
    setup_herdr_persistence "$migrate_persist" "$migrate_home"
); then
    if [ -f "$migrate_persist/.config/herdr/user-marker" ] \
        && [ -f "$migrate_persist/.local/state/herdr/session-marker" ]; then
        test_pass "pre-existing ephemeral Herdr config and sessions migrate into persistence"
    else
        test_fail "pre-existing ephemeral Herdr config and sessions migrate into persistence"
    fi
else
    test_fail "pre-existing ephemeral Herdr config and sessions migrate into persistence"
fi

repair_persist="$fixture/repair/persist/home/dx"
repair_home="$fixture/repair/home/dx"
mkdir -p "$repair_persist/.config" "$repair_persist/.local/state" "$repair_home"
printf '%s\n' legacy-config-target > "$repair_persist/.config/herdr"
printf '%s\n' legacy-state-target > "$repair_persist/.local/state/herdr"
if (
    chown() { :; }
    run_as_dx() { bash -c "$1"; }
    setup_herdr_persistence "$repair_persist" "$repair_home"
); then
    shopt -s nullglob
    # This branch's setup_herdr_persistence names both backups after the
    # directory being repaired, disambiguated by their parent; the guest
    # branch's dropped implementation used a herdr-<label> prefix instead.
    config_backups=("$repair_persist/.config"/herdr.non-directory-backup.*)
    state_backups=("$repair_persist/.local/state"/herdr.non-directory-backup.*)
    shopt -u nullglob
    if [ -d "$repair_persist/.config/herdr" ] && [ -d "$repair_persist/.local/state/herdr" ] \
        && [ "${#config_backups[@]}" -eq 1 ] && [ "${#state_backups[@]}" -eq 1 ] \
        && grep -qx legacy-config-target "${config_backups[0]}" \
        && grep -qx legacy-state-target "${state_backups[0]}"; then
        test_pass "non-directory persistent Herdr targets are backed up and repaired"
    else
        test_fail "non-directory persistent Herdr targets are backed up and repaired"
    fi
else
    test_fail "non-directory persistent Herdr targets are backed up and repaired"
fi

unsafe_persist="$fixture/unsafe/persist/home/dx"
unsafe_home="$fixture/unsafe/home/dx"
mkdir -p "$unsafe_persist" "$unsafe_home" "$fixture/unsafe/outside"
ln -s "$fixture/unsafe/outside" "$unsafe_persist/.config"
if (
    chown() { :; }
    run_as_dx() { bash -c "$1"; }
    setup_herdr_persistence "$unsafe_persist" "$unsafe_home"
) >/dev/null 2>&1; then
    test_fail "Herdr persistence rejects symlinked persistent parents"
else
    if [ -z "$(find "$fixture/unsafe/outside" -mindepth 1 -print -quit)" ]; then
        test_pass "Herdr persistence rejects symlinked persistent parents without traversal"
    else
        test_fail "Herdr persistence rejects symlinked persistent parents without traversal"
    fi
fi

ancestor_root="$fixture/unsafe-ancestor"
mkdir -p "$ancestor_root/persist" "$ancestor_root/outside" "$ancestor_root/home/dx"
ln -s "$ancestor_root/outside" "$ancestor_root/persist/home"
if (
    chown() { :; }
    run_as_dx() { bash -c "$1"; }
    setup_herdr_persistence "$ancestor_root/persist/home/dx" "$ancestor_root/home/dx"
) >/dev/null 2>&1; then
    test_fail "Herdr persistence rejects symlinked ancestors above persist_home"
else
    if [ -z "$(find "$ancestor_root/outside" -mindepth 1 -print -quit)" ]; then
        test_pass "Herdr persistence rejects symlinked ancestors above persist_home without traversal"
    else
        test_fail "Herdr persistence rejects symlinked ancestors above persist_home without traversal"
    fi
fi

if declare -F dx_activate_herdr >/dev/null; then
    rm -rf "$persist_home/.config/herdr" "$home/.config/herdr"
    if (
        chown() { :; }
        run_as_dx() { bash -c "$1"; }
        dx_activate_herdr "$persist_home" "$home" "$TEMPLATE"
    ); then
        test_pass "Herdr activation composes persistence and config seeding"
    else
        test_fail "Herdr activation composes persistence and config seeding"
    fi
else
    test_fail "dx_activate_herdr is sourceable"
fi

assert_file_contains_literal "$persist_home/.config/herdr/config.toml" 'prefix = "ctrl+space"' "bootstrap activation recreates the current keymap"
assert_file_contains_literal "$persist_home/.config/herdr/config.toml" 'agent_panel_sort = "priority"' "bootstrap activation recreates the agent-sidebar workflow"

# --- F7: table-scope-aware seeding regression guards ---
#
# Ported from Section 23 with the seeder itself. Each case reproduces a defect
# the original grep-based seeder actually shipped (herdr-refactor.md F7): a key
# name under an unrelated table suppressed seeding entirely; a header carrying
# a trailing comment produced a *second*, duplicate table and so a TOML parse
# error; and a key under a same-named sub-table also suppressed seeding. The
# merger replaced that seeder, so these guards move with the behavior they
# guard rather than being retired with the implementation.
seed_case() {
    local body="$1" path="$fixture/f7-$2/config.toml"
    mkdir -p "$(dirname "$path")"
    printf '%s' "$body" > "$path"
    seed_config "$TEMPLATE" "$path" >/dev/null 2>&1
    printf '%s' "$path"
}

unrelated="$(seed_case '[other]
pane_history = false
scrollback_limit_bytes = 1
' unrelated)"
if grep -q '^pane_history = false' "$unrelated" \
    && grep -q '^\[experimental\]$' "$unrelated" \
    && grep -q '^pane_history = true' "$unrelated" \
    && grep -q '^\[advanced\]$' "$unrelated" \
    && grep -q '^scrollback_limit_bytes = 10000000' "$unrelated"; then
    test_pass "seeding reaches [experimental]/[advanced] even when an unrelated table holds the same key names (F7)"
else
    test_fail "seeding reaches [experimental]/[advanced] even when an unrelated table holds the same key names (F7)"
fi

commented="$(seed_case '[experimental] # mine
foo = 1
' commented)"
if [ "$(grep -c '\[experimental\]' "$commented")" -eq 1 ] \
    && grep -q 'pane_history = true' "$commented" \
    && grep -q 'foo = 1' "$commented"; then
    test_pass "a commented table header never produces a duplicate table (F7)"
else
    test_fail "a commented table header never produces a duplicate table (F7)"
fi

nested="$(seed_case '[experimental.nested]
pane_history = false
' nested)"
if grep -q '^\[experimental\]$' "$nested" \
    && grep -q '^pane_history = true' "$nested" \
    && grep -q '^\[experimental.nested\]$' "$nested"; then
    test_pass "[experimental.nested] is a distinct table from [experimental] (F7)"
else
    test_fail "[experimental.nested] is a distinct table from [experimental] (F7)"
fi

if ! ls "$fixture"/f7-*/.dxe-herdr-config.* >/dev/null 2>&1; then
    test_pass "a successful publish leaves no temp file behind (F7)"
else
    test_fail "a successful publish leaves no temp file behind (F7)"
fi
assert_file_not_contains "$MERGER" '>> "\$config_file"' "the merger never appends in-place to the live config (F7)"

# --- L5 regression guard: the early bootstrap environment lacks awk ---
#
# Live defect: awk is not in the early essentials profile, so the seeder failed,
# the failure propagated, and the guest never booted. The essentials install is
# also skipped entirely on a guest that already has one, so the dependency could
# not be added retroactively -- which is why the merger is pure Bash and why
# this fixture removes awk while keeping the tools bootstrap really does have.
if awk_out="$(
    shim="$(mktemp -d)"
    for t in dirname mktemp chmod mv cp mkdir cat rm grep sed sha256sum; do
        p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$shim/$t"
    done
    cfg="$(mktemp -d)/config.toml"; printf '[experimental]\nfoo = 1\n' > "$cfg"
    PATH="$shim" seed_config "$TEMPLATE" "$cfg" >/dev/null 2>&1
    cat "$cfg"
)"; then
    case "$awk_out" in
        *"pane_history = true"*) awk_ok=1 ;;
        *) awk_ok=0 ;;
    esac
    case "$awk_out" in
        *"scrollback_limit_bytes = 10000000"*) ;;
        *) awk_ok=0 ;;
    esac
else
    awk_ok=0
fi
if [ "$awk_ok" -eq 1 ]; then
    test_pass "the merger seeds correctly with no awk on PATH (L5 regression guard)"
else
    test_fail "the merger seeds correctly with no awk on PATH (L5 regression guard)"
fi

print_summary
exit_with_code
