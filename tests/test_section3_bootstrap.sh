#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
test_section "Section 3: Sourceable Guest Bootstrap"

assert_file_exists "$BOOTSTRAP" "bootstrap orchestrator exists"
assert_file_exists "$CONTAINER_DIR/scripts/lib/dx-guest-system.sh" "the shared guest-system helper exists"
assert_file_contains_literal "$BOOTSTRAP" 'source "$DX_BOOTSTRAP_ROOT/scripts/lib/dx-guest-system.sh"' "bootstrap sources the shared guest-system helper"
for module in common base-and-storage system persistence activation; do
    assert_file_exists "$BOOTSTRAP_DIR/$module.sh" "bootstrap $module phase exists"
    if output="$(bash -c 'before=$-; source "$1"; [ "$before" = "$-" ]' _ "$BOOTSTRAP_DIR/$module.sh" 2>&1)" && [ -z "$output" ]; then
        test_pass "bootstrap $module phase is side-effect-free when sourced"
    else
        test_fail "bootstrap $module phase is side-effect-free when sourced"
    fi
done

source "$BOOTSTRAP_DIR/common.sh"
source "$CONTAINER_DIR/scripts/lib/dx-guest-system.sh"
source "$BOOTSTRAP_DIR/base-and-storage.sh"
source "$BOOTSTRAP_DIR/system.sh"
source "$BOOTSTRAP_DIR/persistence.sh"
source "$BOOTSTRAP_DIR/activation.sh"
for function_name in dx_validate_atomic_marker_path dx_publish_atomic_marker dx_pipeline_succeeded essentials_profile_path essentials_profile_store_path install_essential_packages essentials_store_valid repair_store_closure verify_remount_prerequisites ensure_essentials_valid generate_host_keys install_essentials link_system_bash dx_seed_staged_entries dx_move_missing_entries cleanup_stale_nix_store_imports nix_store_import_registered nix_verify_imported_bootstrap_paths nix_install_image_essentials_root nix_seed_volume record_durable_nix_identity migrate_durable_nix_identity_if_needed nix_image_registered_paths nix_image_store_identity nix_image_essentials_identity nix_image_default_profile_store_path capture_nix_image_default_profile nix_restore_image_default_profile nix_image_bootstrap_store_paths nix_target_store_uri nix_image_store_import_required nix_verify_single_bootstrap_path_collision nix_verify_no_bootstrap_path_collision publish_nix_image_store_identity prepare_nix_volume prepare_nix_volume_impl prepare_nix_volume_direct_impl populate_prepared_nix_volume populate_prepared_nix_volume_in_place publish_nix_volume_image_identity setup_nix_volume configure_single_user_nix configure_release_identity resolve_timezone_file configure_timezone materialize_auth_files auth_entries_with_numeric_id create_user setup_persist dx_ensure_tree_owner dx_prepare_owned_directory configure_ssh dx_host_key_store_trusted dx_host_key_store_populated dx_harden_host_keys dx_persist_host_keys run_as_dx run_home_manager_activation publish_nix_ownership_marker ensure_nix_ownership ai_tools_opted_in setup_gh_persistence setup_tmux_persistence setup_herdr_persistence dx_seed_herdr_config dx_activate_herdr configure_guest verify_guest_tools dx_guest_native_system dx_guest_resolve_system; do
    if declare -F "$function_name" >/dev/null; then test_pass "$function_name is directly sourceable"; else test_fail "$function_name is directly sourceable"; fi
done

# Branch 11 / Phase 4 (qnap-dxe-plan.md DQ7, docs/refactor/
# arch-neutral-guest.md section 4): the guest selects its own system from
# uname -m, cross-checked against DX_GUEST_SYSTEM (the third
# bin/dx-create-container env token) when the host provided one. Agree,
# disagree, and unsupported-architecture cases, all with `uname` stubbed so
# these are deterministic regardless of the real host/container running
# this test.
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' aarch64 || command uname "$@"; }
    unset DX_GUEST_SYSTEM
    [ "$(dx_guest_native_system)" = aarch64-linux ]
); then
    test_pass "dx_guest_native_system maps uname -m=aarch64 to aarch64-linux"
else
    test_fail "dx_guest_native_system maps uname -m=aarch64 to aarch64-linux"
fi
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' x86_64 || command uname "$@"; }
    unset DX_GUEST_SYSTEM
    [ "$(dx_guest_native_system)" = x86_64-linux ]
); then
    test_pass "dx_guest_native_system maps uname -m=x86_64 to x86_64-linux"
else
    test_fail "dx_guest_native_system maps uname -m=x86_64 to x86_64-linux"
fi
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' armv7l || command uname "$@"; }
    dx_guest_native_system
); then
    test_fail "dx_guest_native_system refuses an unsupported guest architecture (32-bit ARM, DQ7)"
else
    test_pass "dx_guest_native_system refuses an unsupported guest architecture (32-bit ARM, DQ7)"
fi

if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' aarch64 || command uname "$@"; }
    unset DX_GUEST_SYSTEM
    [ "$(dx_guest_resolve_system)" = aarch64-linux ]
); then
    test_pass "dx_guest_resolve_system: DX_GUEST_SYSTEM unset uses the native system (Apple's case today)"
else
    test_fail "dx_guest_resolve_system: DX_GUEST_SYSTEM unset uses the native system (Apple's case today)"
fi
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' x86_64 || command uname "$@"; }
    export DX_GUEST_SYSTEM=x86_64-linux
    [ "$(dx_guest_resolve_system)" = x86_64-linux ]
); then
    test_pass "dx_guest_resolve_system: matching DX_GUEST_SYSTEM agrees with the native system"
else
    test_fail "dx_guest_resolve_system: matching DX_GUEST_SYSTEM agrees with the native system"
fi
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' aarch64 || command uname "$@"; }
    export DX_GUEST_SYSTEM=x86_64-linux
    out="$(dx_guest_resolve_system 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F "host profile says DX_GUEST_SYSTEM=x86_64-linux, but this guest is aarch64-linux"
); then
    test_pass "dx_guest_resolve_system refuses when DX_GUEST_SYSTEM disagrees with the native system"
else
    test_fail "dx_guest_resolve_system refuses when DX_GUEST_SYSTEM disagrees with the native system"
fi
if (
    uname() { [ "${1:-}" = -m ] && printf '%s\n' armv7l || command uname "$@"; }
    unset DX_GUEST_SYSTEM
    dx_guest_resolve_system
); then
    test_fail "dx_guest_resolve_system refuses an unsupported guest architecture even with DX_GUEST_SYSTEM unset"
else
    test_pass "dx_guest_resolve_system refuses an unsupported guest architecture even with DX_GUEST_SYSTEM unset"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/nix/store/profile/bin" "$fixture/nix/var/nix/profiles/per-user/root"
ln -s "$fixture/nix/store/profile" "$fixture/nix/var/nix/profiles/per-user/root/profile"
export DX_ESSENTIALS_ROOT=$fixture
fixture_physical="$(cd "$fixture" && pwd -P)"
if [ "$(essentials_profile_path)" = "$fixture_physical/nix/store/profile/bin" ]; then test_pass "essentials profile resolves before the Nix remount"; else test_fail "essentials profile resolves before the Nix remount"; fi

# Ownership migrations must be one-time repairs, not recurring work. This
# sourceable fixture records the recursive boundary and proves the marker
# suppresses it on the next activation. The Linux behavior runner additionally
# exercises the same helper with a real dx uid and filesystem ownership.
marker_fixture="$fixture/marker"
mkdir -p "$marker_fixture/data"
printf '%s\n' legacy > "$marker_fixture/data/file"
marker_output="$({
    id() { [ "${1:-}" = -u ] && printf '123' || printf '456'; }
    stat() { printf '123:456\n'; }
    install() { mkdir -p "${!#}"; }
    chown() { printf '%s\n' "$*" >> "$marker_fixture/chown.log"; }
    dx_ensure_tree_owner "$marker_fixture/data" "$marker_fixture/data/.dxe-owner-v1" "fixture data"
    dx_ensure_tree_owner "$marker_fixture/data" "$marker_fixture/data/.dxe-owner-v1" "fixture data"
} 2>&1)"
if [ -f "$marker_fixture/data/.dxe-owner-v1" ] \
    && [ "$(grep -c -- '-R dx:dx' "$marker_fixture/chown.log")" -eq 1 ] \
    && printf '%s\n' "$marker_output" | stdin_matches 'already verified'; then
    test_pass "ownership migration publishes a marker and skips recursive repair thereafter"
else
    test_fail "ownership migration publishes a marker and skips recursive repair thereafter"
fi

# Existing directories must still receive the requested mode. Ownership is
# remapped to this test process because the host does not have a dx account;
# chmod and the filesystem checks remain real.
mode_fixture="$fixture/mode"
mkdir -p "$mode_fixture"
chmod 0700 "$mode_fixture"
mode_result="$({
    id() { [ "${1:-}" = -u ] && printf '%s\n' "$(command id -u)" || printf '%s\n' "$(command id -g)"; }
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [[ "$arg" == -* ]]; then continue; fi
            if [ "$arg" = dx:dx ]; then args+=("$(command id -u):$(command id -g)"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
    }
    dx_prepare_owned_directory "$mode_fixture" 0755
    file_mode "$mode_fixture"
} 2>&1)"
if [ "$mode_result" = 755 ]; then
    test_pass "owned directory preparation repairs the requested mode on an existing directory"
else
    test_fail "owned directory preparation repairs the requested mode on an existing directory (got $mode_result)"
fi

# A failed marker publication must not claim success. The next invocation
# retries the migration and can publish the marker safely.
retry_fixture="$fixture/retry"
mkdir -p "$retry_fixture"
retry_result="$({
    id() { [ "${1:-}" = -u ] && printf '123\n' || printf '456\n'; }
    stat() { printf '123:456\n'; }
    install() { mkdir -p "${!#}"; }
    chown() { printf '%s\n' "$*" >> "$retry_fixture/chown.log"; }
    first_move=1
    mv() { if [ "$first_move" -eq 1 ]; then first_move=0; return 1; fi; command mv "$@"; }
    dx_ensure_tree_owner "$retry_fixture" "$retry_fixture/.dxe-owner-v1" "retry fixture" || true
    [ ! -e "$retry_fixture/.dxe-owner-v1" ]
    dx_ensure_tree_owner "$retry_fixture" "$retry_fixture/.dxe-owner-v1" "retry fixture"
    [ -f "$retry_fixture/.dxe-owner-v1" ]
    [ "$(grep -c -- '-R dx:dx' "$retry_fixture/chown.log")" -eq 2 ]
} 2>&1)"
if [ $? -eq 0 ]; then
    test_pass "failed ownership marker publication is retried without a false success marker"
else
    test_fail "failed ownership marker publication is retried without a false success marker ($retry_result)"
fi

# A marker path may be attacker-controlled durable state.  GNU mv treats a
# directory destination as a request to move the temporary file inside it;
# marker publication must reject that shape instead of reporting success and
# leaving the migration perpetually unmarked.
directory_marker_fixture="$fixture/directory-marker"
mkdir -p "$directory_marker_fixture/data/.dxe-owner-v1"
directory_marker_result="$({
    id() { [ "${1:-}" = -u ] && printf '123\n' || printf '456\n'; }
    chown() { :; }
    dx_ensure_tree_owner "$directory_marker_fixture/data" "$directory_marker_fixture/data/.dxe-owner-v1" "directory marker fixture"
} >/dev/null 2>&1; printf '%s' "$?")"
if [ "$directory_marker_result" -ne 0 ] \
    && [ -d "$directory_marker_fixture/data/.dxe-owner-v1" ] \
    && [ -z "$(find "$directory_marker_fixture/data/.dxe-owner-v1" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    test_pass "directory-valued ownership markers fail safely without nested temporary files"
else
    test_fail "directory-valued ownership markers fail safely without nested temporary files"
fi

# Exercise the real GitHub and Herdr persistence functions against disposable
# trees. The chown boundary maps dx:dx to this process, while file creation,
# chmod, symlink/refusal logic, and readability checks remain real.
persist_behavior="$({
    id() { [ "${1:-}" = -u ] && command id -u || command id -g; }
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [[ "$arg" == -* ]]; then args+=("$arg"); continue; fi
            if [ "$arg" = dx:dx ]; then args+=("$(command id -u):$(command id -g)"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
        printf '%s\n' "$*" >> "$fixture/persistence-chown.log"
    }
    run_as_dx() { bash -c "$1"; }
    gh_persist="$fixture/gh-persist/home/dx"
    gh_home="$fixture/gh-home"
    mkdir -p "$gh_persist/.config" "$gh_home/.config" "$gh_persist/.cache"
    printf '%s\n' cached > "$gh_persist/.cache/old-input"
    setup_gh_persistence "$gh_persist" "$gh_home"
    setup_gh_persistence "$gh_persist" "$gh_home"
    [ -L "$gh_home/.config/gh" ]
    [ -r "$gh_persist/.cache/old-input" ]
    [ "$(grep -c -- '-R dx:dx' "$fixture/persistence-chown.log")" -eq 1 ]

    gh_move_persist="$fixture/gh-move-persist/home/dx"
    gh_move_home="$fixture/gh-move-home"
    mkdir -p "$gh_move_persist/.config" "$gh_move_home/.config/gh"
    printf '%s\n' token > "$gh_move_home/.config/gh/hosts.yml"
    setup_gh_persistence "$gh_move_persist" "$gh_move_home"
    [ -r "$gh_move_persist/.config/gh/hosts.yml" ]
    [ -L "$gh_move_home/.config/gh" ]
    [ "$(grep -c -- '-R dx:dx' "$fixture/persistence-chown.log")" -eq 2 ]

    herdr_persist="$fixture/herdr-persist/home/dx"
    herdr_home="$fixture/herdr-home"
    mkdir -p "$herdr_persist/.config" "$herdr_persist/.local/state" "$herdr_home"
    printf '%s\n' history > "$herdr_persist/.local/state/history"
    run_as_dx() { :; }
    setup_herdr_persistence "$herdr_persist" "$herdr_home"
    setup_herdr_persistence "$herdr_persist" "$herdr_home"
    [ -r "$herdr_persist/.local/state/history" ]
    [ "$(grep -c -- '-R dx:dx' "$fixture/persistence-chown.log")" -eq 3 ]
} 2>&1)"
if [ $? -eq 0 ]; then
    test_pass "GitHub and Herdr migrations leave persisted data usable without recurring recursive chowns"
else
    test_fail "GitHub and Herdr migrations leave persisted data usable without recurring recursive chowns ($persist_behavior)"
fi

# A factory-reset persist volume has no pre-existing XDG tree.  The bootstrap
# must establish the shared ~/.local parent and its state/share children as dx
# before later services create their own XDG children; otherwise the first
# dx-ai invocation cannot create ~/.local/state/dx-ai or
# ~/.local/share/opencode.  Keep this fixture scoped to a temporary persist
# root so the sourceable test never touches the host's /persist volume.
fresh_persist="$fixture/fresh-persist/home/dx"
fresh_persist_behavior="$({
    id() { [ "${1:-}" = -u ] && command id -u || command id -g; }
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [ "$arg" = dx:dx ]; then args+=("$(command id -u):$(command id -g)"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
    }
    install() { command mkdir -p "${!#}"; }
    mkdir -p "$fixture/fresh-persist"
    setup_persist "$fixture/fresh-persist"
    if [ ! -d "$fresh_persist/.local" ] || [ ! -d "$fresh_persist/.local/state" ] \
        || [ ! -d "$fresh_persist/.local/share" ]; then
        echo "xdg-parent-missing"
    else
        echo "xdg-parent-ready"
    fi
    mkdir -p "$fresh_persist/.local/state/dx-ai"
    touch "$fresh_persist/.local/state/dx-ai/child-created-by-dx"
    mkdir -p "$fresh_persist/.local/share/opencode"
    touch "$fresh_persist/.local/share/opencode/child-created-by-dx"
} 2>&1)"
if [ -d "$fresh_persist/.local" ] \
    && [ -d "$fresh_persist/.local/state/dx-ai" ] \
    && [ -f "$fresh_persist/.local/state/dx-ai/child-created-by-dx" ] \
    && [ -d "$fresh_persist/.local/share/opencode" ] \
    && [ -f "$fresh_persist/.local/share/opencode/child-created-by-dx" ] \
    && printf '%s\n' "$fresh_persist_behavior" | stdin_matches 'xdg-parent-ready'; then
    test_pass "fresh persist prepares ~/.local/share so dx can create an OpenCode data child"
else
    test_fail "fresh persist prepares ~/.local/share so dx can create an OpenCode data child ($fresh_persist_behavior)"
fi

# The persist root itself is a trust boundary: setup must refuse a symlink
# before chown/install can follow it into an unrelated tree.
symlink_persist="$fixture/symlink-persist"
symlink_persist_target="$fixture/symlink-persist-target"
mkdir -p "$symlink_persist_target"
ln -s "$symlink_persist_target" "$symlink_persist"
if setup_persist "$symlink_persist" >/dev/null 2>&1; then
    test_fail "fresh persist refuses a symlinked persist root"
else
    test_pass "fresh persist refuses a symlinked persist root"
fi

# Nix ownership markers are tested against a disposable tree. The fixture uses
# this process's real numeric owner as the stand-in for dx, while the marker,
# atomic rename, writability gate, and recursive-call count remain real.
if (
    ownership_root="$fixture/nix-ownership"
    owner_uid="$(command id -u)"
    owner_gid="$(command id -g)"
    id() { [ "${1:-}" = -u ] && printf '%s\n' "$owner_uid" || printf '%s\n' "$owner_gid"; }
    if [ "$(command uname -s)" = Darwin ]; then
        stat() {
            if [ "${1:-}" = -c ]; then
                shift 2
                command stat -f '%u:%g' "$1"
            else
                command stat "$@"
            fi
        }
    fi
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [ "$arg" = dx:dx ]; then args+=("$owner_uid:$owner_gid"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
        printf '%s\n' "$*" >> "$ownership_root/chown.log"
    }
    run_as_dx() { return 0; }
    essentials_store_valid() { return 0; }

    mkdir -p "$ownership_root/fresh/store" "$ownership_root/fresh/var/nix"
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/fresh" publish_nix_ownership_marker
    [ -f "$ownership_root/fresh/.dx-owner-layout-v1" ]
    [ -f "$ownership_root/fresh/.dx-owner-set" ]
    [ "$(stat -c '%u:%g' "$ownership_root/fresh/.dx-owner-layout-v1")" = "$owner_uid:$owner_gid" ]
    rm -f "$ownership_root/fresh/.dx-owner-set"
    : > "$ownership_root/chown.log"
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/fresh" ensure_nix_ownership
    ! grep -q -- '-R dx:dx' "$ownership_root/chown.log"

    mkdir -p "$ownership_root/content-invalid/store" "$ownership_root/content-invalid/var/nix"
    essentials_store_valid() { return 1; }
    ! DX_NIX_OWNERSHIP_ROOT="$ownership_root/content-invalid" publish_nix_ownership_marker
    [ ! -e "$ownership_root/content-invalid/.dx-owner-set" ]
    essentials_store_valid() { return 0; }

    mkdir -p "$ownership_root/symlink/store" "$ownership_root/symlink/var/nix"
    ln -s "$ownership_root/content-invalid" "$ownership_root/symlink/.dx-owner-set"
    ! DX_NIX_OWNERSHIP_ROOT="$ownership_root/symlink" ensure_nix_ownership

    mkdir -p "$ownership_root/directory/.dx-owner-set" "$ownership_root/directory/.dx-owner-layout-v1"
    ! DX_NIX_OWNERSHIP_ROOT="$ownership_root/directory" publish_nix_ownership_marker
    [ -z "$(find "$ownership_root/directory/.dx-owner-set" "$ownership_root/directory/.dx-owner-layout-v1" -mindepth 1 -maxdepth 1 -print -quit)" ]

    mkdir -p "$ownership_root/legacy/store" "$ownership_root/legacy/var/nix"
    : > "$ownership_root/legacy/.dx-owner-set"
    command chown "$owner_uid:$owner_gid" "$ownership_root/legacy/.dx-owner-set"
    : > "$ownership_root/chown.log"
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/legacy" ensure_nix_ownership
    [ -f "$ownership_root/legacy/.dx-owner-layout-v1" ]
    ! grep -q -- '-R dx:dx' "$ownership_root/chown.log"

    mkdir -p "$ownership_root/invalid/store" "$ownership_root/invalid/var/nix"
    : > "$ownership_root/chown.log"
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/invalid" ensure_nix_ownership
    [ -f "$ownership_root/invalid/.dx-owner-layout-v1" ]
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/invalid" ensure_nix_ownership
    [ "$(grep -c -- '-R dx:dx' "$ownership_root/chown.log")" -eq 1 ]

    mkdir -p "$ownership_root/retry/store" "$ownership_root/retry/var/nix"
    : > "$ownership_root/chown.log"
    move_count=0
    mv() {
        move_count=$((move_count + 1))
        [ "$move_count" -eq 2 ] && return 1
        command mv "$@"
    }
    retry_status=0
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/retry" ensure_nix_ownership || retry_status=$?
    [ "$retry_status" -ne 0 ]
    [ ! -e "$ownership_root/retry/.dx-owner-layout-v1" ]
    DX_NIX_OWNERSHIP_ROOT="$ownership_root/retry" ensure_nix_ownership
    [ -f "$ownership_root/retry/.dx-owner-layout-v1" ]
    [ "$(grep -c -- '-R dx:dx' "$ownership_root/chown.log")" -eq 1 ]
    ! find "$ownership_root/retry" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .
); then
    test_pass "Nix ownership markers publish atomically, upgrade legacy layouts cheaply, and retry after publication failure"
else
    test_fail "Nix ownership markers publish atomically, upgrade legacy layouts cheaply, and retry after publication failure"
fi

# Characterisation: ensure_nix_ownership_impl's marker-content check (the
# same grep -q shape fixed in ai_tools_opted_in above, for consistency with
# the read-all idiom, applied here too) reads a real two-line marker file and
# takes the "already set" skip path without a recursive chown. The writer
# here (marker_contents) is at most two short lines -- well under any pipe
# buffer -- so a standalone probe confirmed this call site was never
# reproducibly racy; this characterises correct existing behaviour rather
# than proving a defect.
marker_content_fixture="$fixture/marker-content-check"
mkdir -p "$marker_content_fixture/store" "$marker_content_fixture/var/nix"
marker_content_output="$({
    owner_uid="$(command id -u)"
    owner_gid="$(command id -g)"
    id() { [ "${1:-}" = -u ] && printf '%s\n' "$owner_uid" || printf '%s\n' "$owner_gid"; }
    if [ "$(command uname -s)" = Darwin ]; then
        stat() {
            if [ "${1:-}" = -c ]; then
                shift 2
                command stat -f '%u:%g' "$1"
            else
                command stat "$@"
            fi
        }
    fi
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [ "$arg" = dx:dx ]; then args+=("$owner_uid:$owner_gid"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
    }
    run_as_dx() { return 0; }
    essentials_store_valid() { return 0; }
    DX_NIX_OWNERSHIP_ROOT="$marker_content_fixture" publish_nix_ownership_marker
    DX_NIX_OWNERSHIP_ROOT="$marker_content_fixture" ensure_nix_ownership
} 2>&1)"
if printf '%s\n' "$marker_content_output" | stdin_matches -F 'Nix ownership already set. Skipping recursive ownership repair.'; then
    test_pass "ownership marker content check (characterisation) reads a real two-line marker and skips recursive repair"
else
    test_fail "ownership marker content check (characterisation) reads a real two-line marker and skips recursive repair ($marker_content_output)"
fi

if (
    dx_ensure_tree_owner() { return 1; }
    setup_gh_persistence "$fixture/fail-persist" "$fixture/fail-home"
); then
    test_fail "GitHub persistence propagates ownership-helper failure"
else
    test_pass "GitHub persistence propagates ownership-helper failure"
fi
if (
    dx_ensure_tree_owner() { return 1; }
    setup_herdr_persistence "$fixture/fail-herdr-persist" "$fixture/fail-herdr-home"
); then
    test_fail "Herdr persistence propagates ownership-helper failure"
else
    test_pass "Herdr persistence propagates ownership-helper failure"
fi

mkdir -p "$fixture/auth/etc" "$fixture/auth/store"
printf '%s\n' 'root:x:0:' > "$fixture/auth/store/group"
ln -s "$fixture/auth/store/group" "$fixture/auth/etc/group"
export DX_AUTH_ROOT="$fixture/auth"
if materialize_auth_files && [ ! -L "$fixture/auth/etc/group" ] && grep -q '^root:' "$fixture/auth/etc/group"; then test_pass "auth materialization preserves data and replaces symlinks"; else test_fail "auth materialization preserves data and replaces symlinks"; fi

assert_file_not_contains "$BOOTSTRAP_DIR/system.sh" 'guard_old_base' "guest bootstrap no longer defines the old-base guard (removed once every guest moved off the old base -- docs/refactor/migration-gates.md#old-base-guards)"
assert_file_not_contains "$BOOTSTRAP" 'guard_old_base' "bootstrap orchestrator no longer calls the old-base guard"

assert_file_contains_literal "$BOOTSTRAP" 'if [ "${BASH_SOURCE[0]}" = "$0" ]' "bootstrap main runs only when executed"
assert_file_not_contains "$BOOTSTRAP" 'DX_BOOTSTRAP_TEST_MODE' "bootstrap has no production test-mode branch"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /guest-bootstrap' "bootstrap never hands published payload ownership to dx"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /home/dx' "normal activation does not recursively re-own the home tree"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /persist/home/dx' "normal activation does not recursively re-own persisted AI state"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /nix' "normal activation does not recursively re-own a validated Nix volume"
assert_file_not_contains "$BOOTSTRAP_DIR/system.sh" 'chown -R dx:dx /home/dx/.ssh' "SSH setup does not recursively re-own existing user SSH contents"
assert_file_not_contains "$BOOTSTRAP_DIR/persistence.sh" 'chown -R dx:dx /persist/home/dx' "persistence setup does not recursively re-own persisted home on every boot"
assert_file_contains_literal "$BOOTSTRAP_DIR/persistence.sh" 'dx_ensure_tree_owner' "persisted-tree ownership uses a marker-guarded migration helper"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'dx_ensure_tree_owner' "activation uses bounded ownership checks for mutable roots"
assert_file_contains_literal "$BOOTSTRAP_DIR/base-and-storage.sh" 'Bootstrap phase: essentials installation completed in' "essentials installation reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/base-and-storage.sh" 'Bootstrap phase: Nix volume prepare/mount completed in' "Nix volume prepare/mount reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/common.sh" 'Bootstrap phase: essentials verification/repair completed in' "essentials verification/repair reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'Bootstrap phase: Nix ownership check/migration completed in' "Nix ownership check/migration reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'Bootstrap phase: Home Manager activation completed in' "Home Manager activation reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'Bootstrap phase: final guest tool verification completed in' "final guest tool verification reports elapsed time"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2' "Herdr persistence and config seeding are non-fatal bootstrap activation steps"
assert_file_contains_literal "$BOOTSTRAP" 'configure_guest true' "validated Nix imports pass content validation only from bootstrap into guest setup"
assert_file_not_contains "$BOOTSTRAP" 'DX_NIX_VOLUME_PHASE' "bootstrap uses explicit Nix volume lifecycle seams"
assert_file_not_contains "$BOOTSTRAP" 'DX_NIX_OWNERSHIP_CONTENT_VALIDATED' "bootstrap does not export ownership steering state"
assert_file_contains_literal "$BOOTSTRAP_DIR/common.sh" '"$bootstrap_root#bootstrap-essentials" --no-update-lock-file' "essentials install uses the checked-in locked bootstrap output"
assert_file_not_contains "$BOOTSTRAP_DIR/common.sh" 'nixpkgs#' "essentials install does not resolve the global flake registry"
assert_file_contains_literal "$CONTAINER_DIR/flake.nix" 'bootstrap-essentials = pkgs.buildEnv' "flake defines the locked bootstrap essentials output"
assert_file_contains_literal "$BOOTSTRAP" 'exec "$(command -v sshd)" -D -e -p 2222' "foreground sshd remains the final bootstrap action"

if (
    validate_positive_integer() { return 0; }
    run_as_dx_with_timeout() { return 17; }
    # This host may not be a Linux guest (e.g. macOS reports uname -m as
    # "arm64", which dx_guest_native_system does not recognize); stub the
    # resolver so this probe exercises activation timing, not architecture
    # detection.
    dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }
    # Exported: run_home_manager_activation (activation.sh) reads all four as
    # globals, several statements below, not as a same-line command prefix.
    export DX_BOOTSTRAP_ROOT="$fixture" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    hm_status=0
    run_home_manager_activation >/dev/null 2>&1 || hm_status=$?
    [ "$hm_status" -eq 17 ]
); then
    test_pass "Home Manager timing preserves activation failure status"
else
    test_fail "Home Manager timing preserves activation failure status"
fi

# Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 4):
# run_home_manager_activation selects homeConfigurations."dx-<system>" for
# its OWN resolved system, not the bare (aliased) "dx" attribute -- proven
# by capturing the exact flake reference passed to nix run, for both
# systems, and refusing when system resolution itself refuses.
if (
    validate_positive_integer() { return 0; }
    captured=""
    run_as_dx_with_timeout() { captured="$*"; return 0; }
    dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }
    export DX_BOOTSTRAP_ROOT="$fixture" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_home_manager_activation >/dev/null 2>&1
    printf '%s\n' "$captured" | stdin_matches -F "$fixture#homeConfigurations.dx-aarch64-linux.activationPackage"
); then
    test_pass "Home Manager activation selects homeConfigurations.dx-aarch64-linux for an aarch64-linux guest"
else
    test_fail "Home Manager activation selects homeConfigurations.dx-aarch64-linux for an aarch64-linux guest"
fi
if (
    validate_positive_integer() { return 0; }
    captured=""
    run_as_dx_with_timeout() { captured="$*"; return 0; }
    dx_guest_resolve_system() { printf '%s\n' x86_64-linux; }
    export DX_BOOTSTRAP_ROOT="$fixture" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_home_manager_activation >/dev/null 2>&1
    printf '%s\n' "$captured" | stdin_matches -F "$fixture#homeConfigurations.dx-x86_64-linux.activationPackage"
); then
    test_pass "Home Manager activation selects homeConfigurations.dx-x86_64-linux for an x86_64-linux guest"
else
    test_fail "Home Manager activation selects homeConfigurations.dx-x86_64-linux for an x86_64-linux guest"
fi
if (
    validate_positive_integer() { return 0; }
    run_as_dx_with_timeout() { test_fail "activation must not run Nix when system resolution refuses"; }
    dx_guest_resolve_system() { echo "Error: host profile says DX_GUEST_SYSTEM=x86_64-linux, but this guest is aarch64-linux." >&2; return 1; }
    export DX_BOOTSTRAP_ROOT="$fixture" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    hm_status=0
    run_home_manager_activation >/dev/null 2>&1 || hm_status=$?
    [ "$hm_status" -ne 0 ]
); then
    test_pass "Home Manager activation refuses before running Nix when system resolution refuses"
else
    test_fail "Home Manager activation refuses before running Nix when system resolution refuses"
fi

if (
    run_as_dx() { return 23; }
    tools_status=0
    verify_guest_tools >/dev/null 2>&1 || tools_status=$?
    [ "$tools_status" -eq 1 ]
); then
    test_pass "final tool verification timing preserves failure status"
else
    test_fail "final tool verification timing preserves failure status"
fi

# Regression: ai_tools_opted_in (activation.sh) must not report a real
# `nix profile list` match as absent under pipefail. It pipes
# `run_as_dx "nix profile list"` into grep; `grep -q` would exit at its first
# match and close the pipe, and a still-writing `nix profile list` could then
# get SIGPIPE/EPIPE, which under `set -o pipefail` (true for bootstrap.sh,
# which sources this file) turns a real match -- the AI tools genuinely
# installed -- into a failed pipeline read as "not installed". Same shape
# Branch 4a fixed in bin/lib/dx-container.sh. Reproduce deterministically
# with a stubbed run_as_dx whose "nix profile list" output puts the matching
# Flake-attribute line FIRST, then tens of thousands of filler lines.
#
# The codex-marker fast path (`[ -x .../current/profile/bin/codex ]`) must be
# false for these probes to exercise the piped fallback at all; that absolute
# guest path never exists on the host or CI runner this test itself runs on,
# so no fixture setup is needed to guarantee it, but each probe still checks
# and skips rather than assuming.
AI_TOOLS_FILLER_LINES=20000
ai_tools_opted_in_biglist_present() (
    set -o pipefail
    run_as_dx() {
        case "$1" in
            'nix profile list')
                printf 'Flake attribute: packages.aarch64-linux.ai-tools\n'
                i=1
                while [ "$i" -le $AI_TOOLS_FILLER_LINES ]; do
                    printf 'Flake attribute: packages.aarch64-linux.filler-%d\n' "$i"
                    i=$((i + 1))
                done
                ;;
            *) return 0 ;;
        esac
    }
    ai_tools_opted_in
)
ai_tools_opted_in_biglist_absent() (
    set -o pipefail
    run_as_dx() {
        case "$1" in
            'nix profile list')
                i=1
                while [ "$i" -le $AI_TOOLS_FILLER_LINES ]; do
                    printf 'Flake attribute: packages.aarch64-linux.filler-%d\n' "$i"
                    i=$((i + 1))
                done
                ;;
            *) return 0 ;;
        esac
    }
    ai_tools_opted_in
)
if [ -e /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex ]; then
    test_skip "ai_tools_opted_in biglist probes (host has a real guest AI-tools marker path)"
else
    if ai_tools_opted_in_biglist_present; then
        test_pass "ai_tools_opted_in finds a real nix-profile-list match past a large filler list under pipefail"
    else
        test_fail "ai_tools_opted_in finds a real nix-profile-list match past a large filler list under pipefail"
    fi
    if ai_tools_opted_in_biglist_absent; then
        test_fail "ai_tools_opted_in correctly reports the AI tools as not installed when absent from a large filler list"
    else
        test_pass "ai_tools_opted_in correctly reports the AI tools as not installed when absent from a large filler list"
    fi
fi

# /etc/os-release must be world-readable: unprivileged guest tooling reads it,
# and dx cannot. Its mode is not allowed to depend on the ambient umask, which
# the bootstrap launcher once leaked as 077. The repair case is the important
# one -- `cat >` preserves an existing file's mode, so writing a fresh file
# correctly is not enough to recover a guest that already has a private copy.
release_file="$fixture/os-release"
write_release_identity "$release_file" 26.05
if [ "$(dx_path_mode "$release_file")" = 644 ]; then
    test_pass "release identity is written world-readable"
else
    test_fail "release identity is written world-readable (mode $(dx_path_mode "$release_file"))"
fi
if grep -q '^VERSION_ID="26.05"$' "$release_file" && grep -q '^ID=nixos$' "$release_file"; then
    test_pass "release identity records the derived release"
else
    test_fail "release identity records the derived release"
fi
chmod 0600 "$release_file"
write_release_identity "$release_file" 26.05
if [ "$(dx_path_mode "$release_file")" = 644 ]; then
    test_pass "release identity repairs an existing unreadable file"
else
    test_fail "release identity repairs an existing unreadable file (mode $(dx_path_mode "$release_file"))"
fi

# Writing under a hostile umask must still produce a readable file.
(umask 077; write_release_identity "$fixture/os-release-umask" 26.05)
if [ "$(dx_path_mode "$fixture/os-release-umask")" = 644 ]; then
    test_pass "release identity is readable even under a restrictive umask"
else
    test_fail "release identity is readable even under a restrictive umask (mode $(dx_path_mode "$fixture/os-release-umask"))"
fi

# Bootstrap's own keyring functions (dx_resolve_keyring_bin,
# setup_keyring_service) were removed in Branch 16: the guest keyring is
# now owned entirely by dx-ai and the explicit dx-keyring command
# (scripts/lib/dx-keyring.sh, scripts/dx-ai.sh, scripts/dx-keyring.sh), with a
# real liveness probe -- see tests/test_sourceable_coverage.sh and
# tests/test_section17_dx_ai_runtime.sh for that behavioral coverage, and
# tests/test_refactor_contracts.sh for the "bootstrap contains no keyring
# code" static assertion.

# SSH host identity must survive a rebuild. /etc/ssh is on the ephemeral
# rootfs, so without a persisted store the guest's host key churns on every
# recreate (known_hosts warnings on the host) and a persistent openssh-closure
# problem re-runs keygen on every boot instead of restoring a key that already
# worked. setup_persist hands /persist to dx, so the store holding host
# *private* keys is root-owned 0700 and is trusted only while it still is --
# dx can rename a directory it does not own out of the way and substitute one
# it does. These fixtures record chown rather than stubbing it to a no-op: a
# no-op chown is what has previously hidden root-vs-dx defects in this tree.
hostkey_fixture="$fixture/hostkeys"

# A fresh persist volume: no persisted keys, so bootstrap generates them and
# backfills the store, and the store is created root-owned 0700.
fresh_etc="$hostkey_fixture/fresh/etc/ssh"
fresh_store="$hostkey_fixture/fresh/persist/etc/ssh"
mkdir -p "$hostkey_fixture/fresh/persist/etc"
fresh_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/fresh-chown.log"; }
    install() { command mkdir -p "${!#}"; printf '%s\n' "$*" >> "$hostkey_fixture/fresh-install.log"; }
    stat() { printf '0:0\n'; }
    generate_host_keys() {
        printf '%s\n' generated >> "$hostkey_fixture/fresh-generate.log"
        mkdir -p "$fresh_etc"
        printf 'private\n' > "$fresh_etc/ssh_host_ed25519_key"
        printf 'public\n' > "$fresh_etc/ssh_host_ed25519_key.pub"
    }
    dx_persist_host_keys "$fresh_etc" "$fresh_store"
} 2>&1)"
if [ -f "$hostkey_fixture/fresh-generate.log" ] \
    && [ -f "$fresh_store/ssh_host_ed25519_key" ] \
    && [ "$(file_mode "$fresh_store")" = 700 ] \
    && grep -q -- '-o root -g root -m 0700' "$hostkey_fixture/fresh-install.log"; then
    test_pass "a fresh persist store generates host keys and backfills them for the next boot"
else
    test_fail "a fresh persist store generates host keys and backfills them for the next boot ($fresh_out)"
fi

# A populated, root-owned store is authoritative: restore it instead of
# generating a new identity, which is what keeps the host key stable.
restore_etc="$hostkey_fixture/restore/etc/ssh"
restore_store="$hostkey_fixture/restore/persist/etc/ssh"
mkdir -p "$restore_store" "$restore_etc"
printf 'persisted-private\n' > "$restore_store/ssh_host_ed25519_key"
printf 'persisted-public\n' > "$restore_store/ssh_host_ed25519_key.pub"
chmod 0666 "$restore_store/ssh_host_ed25519_key"
restore_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/restore-chown.log"; }
    install() { command mkdir -p "${!#}"; }
    stat() { printf '0:0\n'; }
    generate_host_keys() { printf '%s\n' generated >> "$hostkey_fixture/restore-generate.log"; }
    dx_persist_host_keys "$restore_etc" "$restore_store"
} 2>&1)"
if [ ! -f "$hostkey_fixture/restore-generate.log" ] \
    && [ "$(cat "$restore_etc/ssh_host_ed25519_key")" = persisted-private ] \
    && [ "$(file_mode "$restore_etc/ssh_host_ed25519_key")" = 600 ] \
    && [ "$(file_mode "$restore_etc/ssh_host_ed25519_key.pub")" = 644 ]; then
    test_pass "a persisted host identity is restored and re-hardened instead of regenerated"
else
    test_fail "a persisted host identity is restored and re-hardened instead of regenerated ($restore_out)"
fi

# /persist belongs to dx, so a store dx could have substituted must not be
# trusted as the guest's host identity.
untrusted_etc="$hostkey_fixture/untrusted/etc/ssh"
untrusted_store="$hostkey_fixture/untrusted/persist/etc/ssh"
mkdir -p "$untrusted_store" "$untrusted_etc"
printf 'attacker-private\n' > "$untrusted_store/ssh_host_ed25519_key"
untrusted_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/untrusted-chown.log"; }
    install() { command mkdir -p "${!#}"; }
    stat() { printf '1000:1000\n'; }
    generate_host_keys() {
        printf '%s\n' generated >> "$hostkey_fixture/untrusted-generate.log"
        printf 'fresh-private\n' > "$untrusted_etc/ssh_host_ed25519_key"
    }
    dx_persist_host_keys "$untrusted_etc" "$untrusted_store"
} 2>&1)"
if [ -f "$hostkey_fixture/untrusted-generate.log" ] \
    && [ "$(cat "$untrusted_etc/ssh_host_ed25519_key")" = fresh-private ] \
    && printf '%s\n' "$untrusted_out" | stdin_matches -i 'not root-owned'; then
    test_pass "a persisted host-key store dx could have substituted is refused, not restored"
else
    test_fail "a persisted host-key store dx could have substituted is refused, not restored ($untrusted_out)"
fi

# Symlinks are a trust boundary here exactly as they are in persistence.sh:
# refuse before any mutation rather than following the link.
symlink_store="$hostkey_fixture/symlink/persist/etc/ssh"
symlink_target="$hostkey_fixture/symlink/target"
symlink_etc="$hostkey_fixture/symlink/etc/ssh"
mkdir -p "$symlink_target" "$symlink_etc" "$hostkey_fixture/symlink/persist/etc"
ln -s "$symlink_target" "$symlink_store"
symlink_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/symlink-chown.log"; }
    install() { command mkdir -p "${!#}"; }
    generate_host_keys() { :; }
    ! dx_persist_host_keys "$symlink_etc" "$symlink_store"
} 2>&1)"
if [ ! -e "$symlink_target/ssh_host_ed25519_key" ] \
    && [ ! -f "$hostkey_fixture/symlink-chown.log" ] \
    && printf '%s\n' "$symlink_out" | stdin_matches -i 'symlink'; then
    test_pass "host-key persistence refuses a symlinked store before any mutation"
else
    test_fail "host-key persistence refuses a symlinked store before any mutation ($symlink_out)"
fi

symlink_etc_link="$hostkey_fixture/symlink-etc/etc/ssh"
symlink_etc_target="$hostkey_fixture/symlink-etc/target"
symlink_etc_store="$hostkey_fixture/symlink-etc/persist/etc/ssh"
mkdir -p "$symlink_etc_target" "$hostkey_fixture/symlink-etc/etc" "$symlink_etc_store"
ln -s "$symlink_etc_target" "$symlink_etc_link"
symlink_etc_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/symlink-etc-chown.log"; }
    install() { command mkdir -p "${!#}"; }
    stat() { printf '0:0\n'; }
    generate_host_keys() { :; }
    ! dx_persist_host_keys "$symlink_etc_link" "$symlink_etc_store"
} 2>&1)"
if [ ! -e "$symlink_etc_target/ssh_host_ed25519_key" ] \
    && printf '%s\n' "$symlink_etc_out" | stdin_matches -i 'symlink'; then
    test_pass "host-key persistence refuses a symlinked /etc/ssh before any mutation"
else
    test_fail "host-key persistence refuses a symlinked /etc/ssh before any mutation ($symlink_etc_out)"
fi

# Without a persist volume mounted the guest must still boot: generate into
# the ephemeral rootfs rather than failing configure_ssh.
nopersist_etc="$hostkey_fixture/nopersist/etc/ssh"
nopersist_out="$({
    chown() { printf '%s\n' "$*" >> "$hostkey_fixture/nopersist-chown.log"; }
    install() { command mkdir -p "${!#}"; }
    generate_host_keys() { printf '%s\n' generated >> "$hostkey_fixture/nopersist-generate.log"; }
    dx_persist_host_keys "$nopersist_etc" "$hostkey_fixture/nopersist/absent-persist/etc/ssh"
} 2>&1)"
if [ -f "$hostkey_fixture/nopersist-generate.log" ]; then
    test_pass "an unmounted persist volume still yields a bootable host identity"
else
    test_fail "an unmounted persist volume still yields a bootable host identity ($nopersist_out)"
fi

# The image-store import must read the registered set through a read-write
# store view. A read-only local-store view cannot checkpoint the store
# database's SQLite write-ahead log, so it reports only what was committed when
# the image was built and omits every path install_essentials registered this
# boot -- including the bootstrap essentials closure. Measured on Apple
# container: the read-only spelling returned 123 paths without the essentials,
# the read-write one 1349 paths with them. Importing the stale set copies
# nothing onto a mature volume, and the guest then loses its toolchain to the
# /nix remount and dies on the first post-remount command.
if (
    nix() {
        case "$*" in
            *'read-only=true'*) printf '%s\n' /nix/store/committed-at-image-build ;;
            *) printf '%s\n' /nix/store/committed-at-image-build /nix/store/aaa-dx-bootstrap-essentials ;;
        esac
    }
    nix_image_registered_paths | stdin_matches -F dx-bootstrap-essentials
); then
    test_pass "the registered image set is read through a view that sees this boot's registrations"
else
    test_fail "the registered image set is read through a view that sees this boot's registrations"
fi

# The same requirement at the pipeline level: whatever the importer streams into
# the copy has to carry the essentials, or the copy is a no-op on a volume that
# already holds every image-build path.
import_dst="$fixture/import-dst"
import_capture="$fixture/import-stdin.log"
if (
    nix() {
        case "$*" in
            *'read-only=true'*) printf '%s\n' /nix/store/committed-at-image-build ;;
            *) printf '%s\n' /nix/store/committed-at-image-build /nix/store/aaa-dx-bootstrap-essentials ;;
        esac
    }
    run_as_dx() { cat > "$import_capture"; }
    chown() { printf '%s\n' "$*" >> "$fixture/import-chown.log"; }
    nix_install_image_essentials_root() { :; }
    nix_verify_imported_bootstrap_paths() { :; }
    nix_store_import_registered "$import_dst" 0 0 >/dev/null
    stdin_matches -F dx-bootstrap-essentials < "$import_capture"
); then
    test_pass "the importer streams this boot's essentials closure into the copy"
else
    test_fail "the importer streams this boot's essentials closure into the copy"
fi

# The remount replaces /nix wholesale, so a required path that never
# materialised must be reported while the image store is still readable --
# rather than surfacing as an inscrutable "mkdir: No such file or directory"
# from a dead PATH after the remount.
verify_dst="$fixture/verify-dst"
mkdir -p "$verify_dst/store/aaa-present"
verify_missing_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaa-present /nix/store/bbb-absent; }
    ! nix_verify_imported_bootstrap_paths "$verify_dst"
} 2>&1)"
if [ -z "${verify_missing_output##*bbb-absent*}" ]; then
    test_pass "an import that did not materialise a required bootstrap path fails before the remount"
else
    test_fail "an import that did not materialise a required bootstrap path fails before the remount ($verify_missing_output)"
fi
if (
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaa-present; }
    nix_verify_imported_bootstrap_paths "$verify_dst"
); then
    test_pass "a fully materialised bootstrap set passes the pre-remount check"
else
    test_fail "a fully materialised bootstrap set passes the pre-remount check"
fi

# PATH after the remount points at the *resolved* essentials bin directory,
# which readlink -f follows into the derivation output rather than leaving at
# the profile root. Verifying only the profile root therefore misses exactly
# the path the next command execs -- an import can report success, satisfy the
# root check, and still leave the guest without a toolchain.
verify_bin_dst="$fixture/verify-bin-dst"
mkdir -p "$verify_bin_dst/store/present-profile"
verify_bin_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/present-profile; }
    essentials_profile_path() { printf '%s\n' /nix/store/absent-essentials/bin; }
    ! nix_verify_imported_bootstrap_paths "$verify_bin_dst"
} 2>&1)"
if [ -z "${verify_bin_output##*absent-essentials*}" ]; then
    test_pass "the pre-remount check covers the resolved essentials bin target, not just the profile root"
else
    test_fail "the pre-remount check covers the resolved essentials bin target, not just the profile root ($verify_bin_output)"
fi

# P7: findmnt's "TARGET,FSTYPE" line must be matched on the FSTYPE field
# exactly, never grepped as a whole. The old unanchored
# `findmnt ... | grep -q "$fs_type"` matched the *TARGET* half of the line
# too, so a /nix mounted somewhere whose path happens to contain the fs_type
# substring was reported as already correctly mounted -- skipping volume
# setup on a false positive. This stub is a recording stub, not a no-op: it
# logs the exact invocation so the assertion can tell the fix still consults
# findmnt for the real FSTYPE, rather than merely no longer being fooled by
# accident.
p7_fp_log="$fixture/p7-findmnt-false-positive.log"
p7_fp_output="$({
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() {
        printf '%s\n' "$*" >> "$p7_fp_log"
        if [ "$*" = '-n -o TARGET,FSTYPE /nix' ]; then printf '%s\n' '/nix-btrfs-legacy ext4'; else return 1; fi
    }
    prepare_nix_volume_impl
} 2>&1)"
if [ -s "$p7_fp_log" ] \
    && grep -qF -- '-n -o TARGET,FSTYPE /nix' "$p7_fp_log" \
    && printf '%s\n' "$p7_fp_output" | stdin_matches -F 'dx-nix-raw not found' \
    && ! printf '%s\n' "$p7_fp_output" | stdin_matches -F 'is already a btrfs mount'; then
    test_pass "prepare_nix_volume_impl exact-matches the FSTYPE field instead of substring-matching the whole findmnt line"
else
    test_fail "prepare_nix_volume_impl exact-matches the FSTYPE field instead of substring-matching the whole findmnt line ($p7_fp_output)"
fi

# True positive: when FSTYPE genuinely matches, the already-mounted
# short-circuit must still fire.
p7_tp_log="$fixture/p7-findmnt-true-positive.log"
p7_tp_output="$({
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() {
        printf '%s\n' "$*" >> "$p7_tp_log"
        if [ "$*" = '-n -o TARGET,FSTYPE /nix' ]; then printf '%s\n' '/nix btrfs'; else return 1; fi
    }
    prepare_nix_volume_impl
    echo "already_mounted=$DX_NIX_VOLUME_ALREADY_MOUNTED root=$DX_NIX_VOLUME_ROOT"
} 2>&1)"
if printf '%s\n' "$p7_tp_output" | stdin_matches -F 'is already a btrfs mount' \
    && printf '%s\n' "$p7_tp_output" | stdin_matches -F 'already_mounted=true root=/nix'; then
    test_pass "prepare_nix_volume_impl still short-circuits when the mounted FSTYPE genuinely matches"
else
    test_fail "prepare_nix_volume_impl still short-circuits when the mounted FSTYPE genuinely matches ($p7_tp_output)"
fi

# P8 (Branch 11 / Phase 3, Increment 2): the explicit DX_NIX_STORAGE_MODE
# dispatch in prepare_nix_volume_impl (docs/refactor/direct-volume-storage.md
# section 2.1). Every stub below is a RECORDING stub (logs its exact
# invocation), not a no-op, so a case that should never call mkfs/mount/
# umount/truncate/blkid actually proves it, the same discipline P7's findmnt
# stub uses.
p8_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p8-direct-volume.XXXXXX")"

# An explicit DX_NIX_STORAGE_MODE=apple-image behaves exactly like the
# absent-variable default (the P7 true-positive scenario, replayed with the
# mode named explicitly instead of relying on the fallback).
p8_explicit_apple_log="$p8_fixture/explicit-apple-findmnt.log"
p8_explicit_apple_output="$({
    DX_NIX_STORAGE_MODE=apple-image
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() {
        printf '%s\n' "$*" >> "$p8_explicit_apple_log"
        if [ "$*" = '-n -o TARGET,FSTYPE /nix' ]; then printf '%s\n' '/nix btrfs'; else return 1; fi
    }
    prepare_nix_volume_impl
    echo "already_mounted=$DX_NIX_VOLUME_ALREADY_MOUNTED root=$DX_NIX_VOLUME_ROOT"
} 2>&1)"
if printf '%s\n' "$p8_explicit_apple_output" | stdin_matches -F 'already_mounted=true root=/nix'; then
    test_pass "prepare_nix_volume_impl: an explicit DX_NIX_STORAGE_MODE=apple-image behaves exactly like the default"
else
    test_fail "prepare_nix_volume_impl: an explicit DX_NIX_STORAGE_MODE=apple-image behaves exactly like the default ($p8_explicit_apple_output)"
fi

# An unrecognized DX_NIX_STORAGE_MODE value fails closed before any
# filesystem action -- the record-stub log for every mutating tool stays
# empty.
p8_unknown_log="$p8_fixture/unknown-mode.log"
if (
    DX_NIX_STORAGE_MODE=bogus-mode
    findmnt() { printf 'findmnt %s\n' "$*" >> "$p8_unknown_log"; }
    mount() { printf 'mount %s\n' "$*" >> "$p8_unknown_log"; }
    umount() { printf 'umount %s\n' "$*" >> "$p8_unknown_log"; }
    truncate() { printf 'truncate %s\n' "$*" >> "$p8_unknown_log"; }
    blkid() { printf 'blkid %s\n' "$*" >> "$p8_unknown_log"; }
    mkfs.btrfs() { printf 'mkfs.btrfs %s\n' "$*" >> "$p8_unknown_log"; }
    mkfs.ext4() { printf 'mkfs.ext4 %s\n' "$*" >> "$p8_unknown_log"; }
    prepare_nix_volume_impl
) >"$p8_fixture/unknown-mode.out" 2>&1; then
    test_fail "prepare_nix_volume_impl: an unrecognized DX_NIX_STORAGE_MODE value fails closed"
else
    if stdin_matches -F "unknown DX_NIX_STORAGE_MODE 'bogus-mode'" < "$p8_fixture/unknown-mode.out" && [ ! -s "$p8_unknown_log" ]; then
        test_pass "prepare_nix_volume_impl: an unrecognized DX_NIX_STORAGE_MODE value fails closed, naming the value, with no mutating call"
    else
        test_fail "prepare_nix_volume_impl: an unrecognized DX_NIX_STORAGE_MODE value fails closed, naming the value, with no mutating call (out: $(cat "$p8_fixture/unknown-mode.out"); mutating-log: $(cat "$p8_unknown_log" 2>/dev/null))"
    fi
fi

# direct-volume mode: /nix is not (yet) a mountpoint -> refuse with the
# task's exact message, before any mutating call.
p8_notmount_log="$p8_fixture/notmount.log"
if (
    DX_NIX_STORAGE_MODE=direct-volume
    findmnt() { printf 'findmnt %s\n' "$*" >> "$p8_notmount_log"; return 1; }
    mount() { printf 'mount %s\n' "$*" >> "$p8_notmount_log"; }
    umount() { printf 'umount %s\n' "$*" >> "$p8_notmount_log"; }
    truncate() { printf 'truncate %s\n' "$*" >> "$p8_notmount_log"; }
    blkid() { printf 'blkid %s\n' "$*" >> "$p8_notmount_log"; }
    mkfs.btrfs() { printf 'mkfs.btrfs %s\n' "$*" >> "$p8_notmount_log"; }
    mkfs.ext4() { printf 'mkfs.ext4 %s\n' "$*" >> "$p8_notmount_log"; }
    prepare_nix_volume_impl
) >"$p8_fixture/notmount.out" 2>&1; then
    test_fail "prepare_nix_volume_direct_impl: refuses when /nix is not a mountpoint"
else
    if stdin_matches -F 'direct-volume mode requires the Nix volume mounted at /nix' < "$p8_fixture/notmount.out" \
        && grep -qF -- '-n -o TARGET /nix' "$p8_notmount_log" \
        && ! grep -qE '^(mount|umount|truncate|blkid|mkfs\.btrfs|mkfs\.ext4) ' "$p8_notmount_log"; then
        test_pass "prepare_nix_volume_direct_impl: refuses when /nix is not a mountpoint, naming the task's exact message, with no mutating call"
    else
        test_fail "prepare_nix_volume_direct_impl: refuses when /nix is not a mountpoint, naming the task's exact message, with no mutating call (out: $(cat "$p8_fixture/notmount.out"); log: $(cat "$p8_notmount_log" 2>/dev/null))"
    fi
fi

# direct-volume mode: /nix IS the mountpoint -> succeeds, sets the explicit
# in-place state DQ4 requires (DX_NIX_VOLUME_ROOT=/nix,
# DX_NIX_VOLUME_IN_PLACE=true -- NOT DX_NIX_VOLUME_ALREADY_MOUNTED, which
# would bypass the identity/import protocol), and calls
# record_durable_nix_identity /nix exactly as apple-image's own
# already-mounted branch does. No mutating call happens either.
p8_mounted_log="$p8_fixture/mounted.log"
p8_identity_log="$p8_fixture/identity-calls.log"
p8_mounted_output="$({
    export DX_NIX_STORAGE_MODE=direct-volume
    findmnt() { printf 'findmnt %s\n' "$*" >> "$p8_mounted_log"; [ "$*" = '-n -o TARGET /nix' ] && printf '%s\n' /nix; }
    mount() { printf 'mount %s\n' "$*" >> "$p8_mounted_log"; }
    umount() { printf 'umount %s\n' "$*" >> "$p8_mounted_log"; }
    truncate() { printf 'truncate %s\n' "$*" >> "$p8_mounted_log"; }
    blkid() { printf 'blkid %s\n' "$*" >> "$p8_mounted_log"; }
    mkfs.btrfs() { printf 'mkfs.btrfs %s\n' "$*" >> "$p8_mounted_log"; }
    mkfs.ext4() { printf 'mkfs.ext4 %s\n' "$*" >> "$p8_mounted_log"; }
    record_durable_nix_identity() { printf '%s\n' "$*" >> "$p8_identity_log"; }
    prepare_nix_volume_impl
    echo "root=$DX_NIX_VOLUME_ROOT in_place=$DX_NIX_VOLUME_IN_PLACE already_mounted=${DX_NIX_VOLUME_ALREADY_MOUNTED:-unset}"
} 2>&1)"
if printf '%s\n' "$p8_mounted_output" | stdin_matches -x 'root=/nix in_place=true already_mounted=unset' \
    && [ "$(cat "$p8_identity_log")" = /nix ] \
    && ! grep -qE '^(mount|umount|truncate|blkid|mkfs\.btrfs|mkfs\.ext4) ' "$p8_mounted_log"; then
    test_pass "prepare_nix_volume_direct_impl: /nix already mounted -> sets DX_NIX_VOLUME_IN_PLACE (not ALREADY_MOUNTED), records durable identity, no mutating call"
else
    test_fail "prepare_nix_volume_direct_impl: /nix already mounted -> sets DX_NIX_VOLUME_IN_PLACE (not ALREADY_MOUNTED), records durable identity, no mutating call (output: $p8_mounted_output; identity-log: $(cat "$p8_identity_log" 2>/dev/null); mutating-log: $(cat "$p8_mounted_log" 2>/dev/null))"
fi

rm -rf "$p8_fixture"

# P9 (Branch 11 / Phase 3, Increment 3): populate_prepared_nix_volume's
# explicit dispatch on DX_NIX_VOLUME_IN_PLACE, and
# populate_prepared_nix_volume_in_place's amended two-check protocol
# (docs/refactor/direct-volume-storage.md section 5.3): store-missing
# refusal, DX_IMAGE_IDENTITY-absent refusal, the new image-identity marker
# (write-once / match-and-continue / mismatch-refuse), and the ORIGINAL
# nix_image_store_import_required check kept, unchanged, as a
# corruption-only signal once the marker matches. Lower-level Nix
# collaborators are stubbed throughout (their own behavior is unchanged and
# tested elsewhere -- Section 5, tests/test_nix_store_import.sh); these
# tests isolate only the new dispatch/marker logic this increment adds.
# owner_uid/owner_gid fall back to the production code's own "0" default
# (no real "dx" user exists on this host, exactly like every other
# isolated fixture in this file).
p9_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p9-in-place-populate.XXXXXX")"

# 1. Store missing: refuse, naming the Docker copy-on-first-mount
# dependency, before nix_image_store_import_required is ever consulted.
p9_missing_root="$p9_fixture/vol-missing"
mkdir -p "$p9_missing_root"
p9_missing_calls="$p9_fixture/missing-calls.log"
if (
    nix_image_store_import_required() { printf 'CALLED %s\n' "$*" >> "$p9_missing_calls"; return 1; }
    DX_IMAGE_IDENTITY=sha256:shouldnotmatter00000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_missing_root"
) >"$p9_fixture/missing.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: refuses when /nix/store is missing"
else
    if stdin_matches -F 'requires /nix/store to already exist' < "$p9_fixture/missing.out" \
        && [ ! -s "$p9_missing_calls" ]; then
        test_pass "populate_prepared_nix_volume_in_place: refuses when /nix/store is missing, naming the Docker copy-on-first-mount dependency, before any identity check"
    else
        test_fail "populate_prepared_nix_volume_in_place: refuses when /nix/store is missing, naming the Docker copy-on-first-mount dependency, before any identity check (out: $(cat "$p9_fixture/missing.out"))"
    fi
fi

# 2. Store present, DX_IMAGE_IDENTITY absent/empty: refuse.
p9_root_noid="$p9_fixture/vol-noid"
mkdir -p "$p9_root_noid/store"
if (
    unset DX_IMAGE_IDENTITY
    populate_prepared_nix_volume_in_place "$p9_root_noid"
) >"$p9_fixture/noid.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: refuses when DX_IMAGE_IDENTITY is absent"
else
    if stdin_matches -F 'requires the runtime image identity' < "$p9_fixture/noid.out"; then
        test_pass "populate_prepared_nix_volume_in_place: refuses when DX_IMAGE_IDENTITY is absent"
    else
        test_fail "populate_prepared_nix_volume_in_place: refuses when DX_IMAGE_IDENTITY is absent (out: $(cat "$p9_fixture/noid.out"))"
    fi
fi

# 3. Marker absent (first bootstrap-managed boot for this volume): writes
# it atomically with the env value, then falls through to the existing
# fresh-store-identity-marker branch (nix_image_store_import_required is
# NOT consulted -- matches apple-image's own fresh-seed branch, which never
# calls it either).
p9_root_fresh="$p9_fixture/vol-fresh"
mkdir -p "$p9_root_fresh/store"
p9_fresh_calls="$p9_fixture/fresh-calls.log"
p9_fresh_output="$({
    # No "dx" user/group exists on this host (same as every other isolated
    # fixture in this file); stub chown so the real atomic-marker publish
    # path (dx_validate_atomic_marker_path/dx_publish_atomic_marker,
    # exercised for real here, unstubbed) can still complete.
    chown() { printf 'chown %s\n' "$*" >> "$p9_fresh_calls"; }
    nix_image_store_import_required() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_fresh_calls"; return 1; }
    nix_image_store_identity() { printf 'fresh-pending-identity\n'; }
    nix_install_image_essentials_root() { printf 'install_root %s\n' "$*" >> "$p9_fresh_calls"; }
    DX_IMAGE_IDENTITY=sha256:freshimage000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_fresh"
    echo "marker=$(cat "$p9_root_fresh/.dx-image-identity-v1" 2>/dev/null)"
    echo "pending=$DX_NIX_PENDING_IMAGE_STORE_IDENTITY"
} 2>&1)"
if printf '%s\n' "$p9_fresh_output" | stdin_matches -F 'marker=sha256:freshimage000000000000000000000000000000000000000000000000000' \
    && printf '%s\n' "$p9_fresh_output" | stdin_matches -F 'pending=fresh-pending-identity' \
    && grep -qF -- 'install_root' "$p9_fresh_calls" \
    && ! grep -qF -- 'MUST-NOT-BE-CALLED' "$p9_fresh_calls"; then
    test_pass "populate_prepared_nix_volume_in_place: marker absent -> writes it, publishes roots, never consults the corruption check"
else
    test_fail "populate_prepared_nix_volume_in_place: marker absent -> writes it, publishes roots, never consults the corruption check (output: $p9_fresh_output; calls: $(cat "$p9_fresh_calls" 2>/dev/null))"
fi

# 4. Marker present and matching DX_IMAGE_IDENTITY, corruption check says
# "not required" (matching, verified) -> proceeds, republishes roots. This
# is the common "recreate preserves /nix" path.
p9_root_match="$p9_fixture/vol-match"
mkdir -p "$p9_root_match/store"
printf 'sha256:matchimage00000000000000000000000000000000000000000000000000\n' > "$p9_root_match/.dx-image-identity-v1"
printf 'unrelated-existing-marker\n' > "$p9_root_match/.dx-image-store-identity"
p9_match_calls="$p9_fixture/match-calls.log"
p9_match_output="$({
    nix_image_store_import_required() { printf 'import_required %s\n' "$*" >> "$p9_match_calls"; return 1; }
    nix_install_image_essentials_root() { printf 'install_root %s\n' "$*" >> "$p9_match_calls"; }
    DX_IMAGE_IDENTITY=sha256:matchimage00000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_match"
} 2>&1)"
if grep -qF -- 'import_required /nix' "$p9_match_calls" \
    && grep -qF -- 'install_root' "$p9_match_calls" \
    && [ "$(cat "$p9_root_match/.dx-image-identity-v1")" = 'sha256:matchimage00000000000000000000000000000000000000000000000000' ]; then
    test_pass "populate_prepared_nix_volume_in_place: marker matches -> the original corruption check still runs, roots republished"
else
    test_fail "populate_prepared_nix_volume_in_place: marker matches -> the original corruption check still runs, roots republished (output: $p9_match_output; calls: $(cat "$p9_match_calls" 2>/dev/null))"
fi

# 5. Marker present and matching, but the corruption check says "required"
# (content diverged/verification failed since last confirmed) -> refuse,
# citing store-trust-plan.md; nix_install_image_essentials_root must not run.
p9_root_corrupt="$p9_fixture/vol-corrupt"
mkdir -p "$p9_root_corrupt/store"
printf 'sha256:corruptimage0000000000000000000000000000000000000000000000000\n' > "$p9_root_corrupt/.dx-image-identity-v1"
printf 'unrelated-existing-marker\n' > "$p9_root_corrupt/.dx-image-store-identity"
if (
    nix_image_store_import_required() { return 0; }
    nix_install_image_essentials_root() { echo "MUST-NOT-RUN"; }
    DX_IMAGE_IDENTITY=sha256:corruptimage0000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_corrupt"
) >"$p9_fixture/corrupt.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: marker matches but the corruption check fails -> refuses"
else
    if stdin_matches -F 'store-trust-plan.md' < "$p9_fixture/corrupt.out" \
        && ! stdin_matches -F 'MUST-NOT-RUN' < "$p9_fixture/corrupt.out"; then
        test_pass "populate_prepared_nix_volume_in_place: marker matches but the corruption check fails -> refuses, citing store-trust-plan.md, before publishing roots"
    else
        test_fail "populate_prepared_nix_volume_in_place: marker matches but the corruption check fails -> refuses, citing store-trust-plan.md, before publishing roots (out: $(cat "$p9_fixture/corrupt.out"))"
    fi
fi

# 6. Marker present and MISMATCHED (a genuine image bump on a reused
# volume): refuse, naming both identities prefix-shortened and
# store-trust-plan.md, WITHOUT ever consulting the corruption check (the
# marker mismatch is decisive on its own -- design point D's amendment).
p9_root_bump="$p9_fixture/vol-bump"
mkdir -p "$p9_root_bump/store"
printf 'sha256:oldimage0000000000000000000000000000000000000000000000000000\n' > "$p9_root_bump/.dx-image-identity-v1"
p9_bump_calls="$p9_fixture/bump-calls.log"
if (
    nix_image_store_import_required() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_bump_calls"; return 1; }
    DX_IMAGE_IDENTITY=sha256:newimage0000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_bump"
) >"$p9_fixture/bump.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses"
else
    if stdin_matches -F 'sha256:oldimage0000' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'sha256:newimage0000' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'store-trust-plan.md' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'recreate the Nix volume' < "$p9_fixture/bump.out" \
        && [ ! -s "$p9_bump_calls" ]; then
        test_pass "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses, naming both identities and store-trust-plan.md, without ever consulting the corruption check"
    else
        test_fail "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses, naming both identities and store-trust-plan.md, without ever consulting the corruption check (out: $(cat "$p9_fixture/bump.out"); calls: $(cat "$p9_bump_calls" 2>/dev/null))"
    fi
fi

# 7. Dispatch integration: populate_prepared_nix_volume with
# DX_NIX_VOLUME_IN_PLACE=true routes to populate_prepared_nix_volume_in_place
# (never the apple-image remount/fstab tail below it).
p9_root_dispatch="$p9_fixture/vol-dispatch"
mkdir -p "$p9_root_dispatch/store"
printf 'sha256:dispatchimage000000000000000000000000000000000000000000000000\n' > "$p9_root_dispatch/.dx-image-identity-v1"
printf 'unrelated-existing-marker\n' > "$p9_root_dispatch/.dx-image-store-identity"
p9_dispatch_output="$({
    nix_image_store_import_required() { return 1; }
    nix_install_image_essentials_root() { echo "roots-published"; }
    umount() { echo "MUST-NOT-UMOUNT"; }
    mount() { echo "MUST-NOT-MOUNT"; }
    DX_NIX_VOLUME_ROOT="$p9_root_dispatch"
    DX_NIX_VOLUME_IN_PLACE=true
    export DX_IMAGE_IDENTITY=sha256:dispatchimage000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume
} 2>&1)"
if printf '%s\n' "$p9_dispatch_output" | stdin_matches -F 'roots-published' \
    && ! printf '%s\n' "$p9_dispatch_output" | stdin_matches -F 'MUST-NOT-UMOUNT' \
    && ! printf '%s\n' "$p9_dispatch_output" | stdin_matches -F 'MUST-NOT-MOUNT' \
    && ! printf '%s\n' "$p9_dispatch_output" | stdin_matches -F 'Adding /nix to /etc/fstab'; then
    test_pass "populate_prepared_nix_volume: DX_NIX_VOLUME_IN_PLACE=true dispatches to the in-place function, never the apple-image remount/fstab tail"
else
    test_fail "populate_prepared_nix_volume: DX_NIX_VOLUME_IN_PLACE=true dispatches to the in-place function, never the apple-image remount/fstab tail (output: $p9_dispatch_output)"
fi

rm -rf "$p9_fixture"

# P10 (Branch 12, store-trust-plan.md Problem 2, Design 2-3):
# verify_remount_prerequisites. Every named tool is faked as a shell
# function (readlink/mkdir/mktemp/rm/ln/chown/mv/setpriv/bash/nix do not
# uniformly exist, or support --version identically, on both this file's
# hosts -- macOS bash 3.2 and Linux), so the check's own decision logic is
# what these fixtures exercise, not any one host's real toolchain.

# Ordering: verify_remount_prerequisites must run strictly after
# populate_prepared_nix_volume (the remount in apple-image mode; container
# start in direct-volume mode -- bootstrap_main's own shared call site
# either way) and strictly before nix_restore_image_default_profile, whose
# own named tools it exists to check ahead of.
bootstrap_sh="$CONTAINER_DIR/bootstrap.sh"
p10_populate_line="$(grep -n '^\s*populate_prepared_nix_volume$' "$bootstrap_sh" | cut -d: -f1)"
p10_verify_line="$(grep -n '^\s*verify_remount_prerequisites$' "$bootstrap_sh" | cut -d: -f1)"
p10_restore_line="$(grep -n '^\s*nix_restore_image_default_profile$' "$bootstrap_sh" | cut -d: -f1)"
if [ -n "$p10_populate_line" ] && [ -n "$p10_verify_line" ] && [ -n "$p10_restore_line" ] \
    && [ "$p10_populate_line" -lt "$p10_verify_line" ] && [ "$p10_verify_line" -lt "$p10_restore_line" ]; then
    test_pass "bootstrap_main calls verify_remount_prerequisites between populate_prepared_nix_volume and nix_restore_image_default_profile"
else
    test_fail "bootstrap_main calls verify_remount_prerequisites between populate_prepared_nix_volume and nix_restore_image_default_profile (populate=$p10_populate_line verify=$p10_verify_line restore=$p10_restore_line)"
fi

# All healthy: every named tool resolves and execs cleanly, and run_as_dx
# succeeds -- the function returns 0 with no diagnostic at all (a healthy
# reused volume boots without churn -- the outcome table's first row).
p10_healthy_output="$({
    readlink() { :; }; mkdir() { :; }; mktemp() { :; }; rm() { :; }; ln() { :; }
    chown() { :; }; mv() { :; }; setpriv() { :; }; bash() { :; }; nix() { :; }
    run_as_dx() { :; }
    verify_remount_prerequisites
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p10_healthy_output" | stdin_matches -x 'exit=0'; then
    test_pass "verify_remount_prerequisites: a healthy remount passes with no diagnostic"
else
    test_fail "verify_remount_prerequisites: a healthy remount passes with no diagnostic (output: $p10_healthy_output)"
fi

# Each named tool missing from PATH entirely (command -v itself fails):
# refuses, naming that exact tool and the dx-reset-nix-volume recovery
# path, before any later tool in the list is even reached.
for p10_tool in readlink mkdir mktemp rm ln chown mv setpriv bash nix; do
    p10_missing_output="$({
        command() {
            if [ "$1" = -v ] && [ "$2" = "$p10_tool" ]; then return 1; fi
            builtin command "$@"
        }
        readlink() { :; }; mkdir() { :; }; mktemp() { :; }; rm() { :; }; ln() { :; }
        chown() { :; }; mv() { :; }; setpriv() { :; }; bash() { :; }; nix() { :; }
        run_as_dx() { :; }
        verify_remount_prerequisites
        echo "exit=$?"
    } 2>&1)"
    if printf '%s\n' "$p10_missing_output" | stdin_matches -F "'$p10_tool' is missing from PATH" \
        && printf '%s\n' "$p10_missing_output" | stdin_matches -F 'dx-reset-nix-volume' \
        && printf '%s\n' "$p10_missing_output" | stdin_matches -x 'exit=1'; then
        test_pass "verify_remount_prerequisites: $p10_tool missing from PATH refuses, naming it and the recovery path"
    else
        test_fail "verify_remount_prerequisites: $p10_tool missing from PATH refuses, naming it and the recovery path (output: $p10_missing_output)"
    fi
done

# Each named tool present (resolves) but fails to execute (the SIGBUS-class
# truncated-executable failure, simulated here by a function that always
# returns non-zero): refuses, naming that exact tool.
for p10_tool in readlink mkdir mktemp rm ln chown mv setpriv bash nix; do
    p10_broken_output="$({
        readlink() { :; }; mkdir() { :; }; mktemp() { :; }; rm() { :; }; ln() { :; }
        chown() { :; }; mv() { :; }; setpriv() { :; }; bash() { :; }; nix() { :; }
        run_as_dx() { :; }
        eval "$p10_tool() { return 1; }"
        verify_remount_prerequisites
        echo "exit=$?"
    } 2>&1)"
    if printf '%s\n' "$p10_broken_output" | stdin_matches -F "'$p10_tool' (" \
        && printf '%s\n' "$p10_broken_output" | stdin_matches -F 'is present but fails to execute' \
        && printf '%s\n' "$p10_broken_output" | stdin_matches -F 'dx-reset-nix-volume' \
        && printf '%s\n' "$p10_broken_output" | stdin_matches -x 'exit=1'; then
        test_pass "verify_remount_prerequisites: $p10_tool present but failing to execute refuses, naming it and the recovery path"
    else
        test_fail "verify_remount_prerequisites: $p10_tool present but failing to execute refuses, naming it and the recovery path (output: $p10_broken_output)"
    fi
done

# run_as_dx itself broken (the setpriv/env/bash -l boundary
# ensure_essentials_valid depends on): refuses, naming run_as_dx and the
# recovery path, even though every individual named tool above resolved and
# executed fine on its own.
p10_runasdx_output="$({
    readlink() { :; }; mkdir() { :; }; mktemp() { :; }; rm() { :; }; ln() { :; }
    chown() { :; }; mv() { :; }; setpriv() { :; }; bash() { :; }; nix() { :; }
    run_as_dx() { return 1; }
    verify_remount_prerequisites
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p10_runasdx_output" | stdin_matches -F 'run_as_dx cannot execute a trivial command' \
    && printf '%s\n' "$p10_runasdx_output" | stdin_matches -F 'dx-reset-nix-volume' \
    && printf '%s\n' "$p10_runasdx_output" | stdin_matches -x 'exit=1'; then
    test_pass "verify_remount_prerequisites: a broken run_as_dx boundary refuses, naming the recovery path"
else
    test_fail "verify_remount_prerequisites: a broken run_as_dx boundary refuses, naming the recovery path (output: $p10_runasdx_output)"
fi

# P11 (Branch 12, store-trust-plan.md Problem 1, Design P1-A):
# nix_verify_no_bootstrap_path_collision. Fakes `nix`, `nix-store`,
# `run_as_dx`, and `nix_image_bootstrap_store_paths` so the decision logic
# is exercised directly; the real-Nix behaviour these fakes stand in for
# (a genuine hash-mismatch import refusal, and a genuine already-valid
# silent skip) is proven once against the real boundary in Section 25
# (tests/test_nix_store_import.sh), per constitution.md.

# All clear: every bootstrap root verifies against itself, and either the
# volume doesn't have it yet (nothing to compare) or has it with a matching
# hash -- no collision, no diagnostic, returns 0.
#
# The leading "(" on every case pattern arm in this file's P11 block is not
# decoration: the $(...) paren-matcher used below can misparse a bare
# "*pattern)" case arm nested inside a command substitution, treating that
# arm's own closing paren as the substitution's closing paren -- the
# standard, POSIX-legal fix is the optional leading "(" before each
# pattern. (No apostrophes in any comment inside one of these blocks
# either -- the same simplified scanner does not understand "#" comments
# well enough to treat an apostrophe there as inert.)
p11_clear_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaaa-one /nix/store/bbbb-two; }
    nix() { return 0; }
    nix-store() { case "$*" in (*aaaa-one*) printf 'sha256:same0000000000000000000000000000000000000000000000000000\n' ;; (*) return 1 ;; esac; }
    run_as_dx() {
        case "$1" in
            (*aaaa-one*) printf 'sha256:same0000000000000000000000000000000000000000000000000000\n' ;;
            (*) return 1 ;;
        esac
    }
    nix_verify_no_bootstrap_path_collision /nix /fixture-volume
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p11_clear_output" | stdin_matches -x 'exit=0'; then
    test_pass "nix_verify_no_bootstrap_path_collision: no collision on any root -> passes with no diagnostic"
else
    test_fail "nix_verify_no_bootstrap_path_collision: no collision on any root -> passes with no diagnostic (output: $p11_clear_output)"
fi

# Shape A: the image's own advertised content for a later root
# (bbbb-two) fails ITS OWN content verification. The earlier root
# (aaaa-one) passes cleanly first, proving the loop actually walks the
# whole bounded root set rather than only ever checking the first entry.
p11_shapea_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaaa-one /nix/store/bbbb-two; }
    nix() { case "$*" in (*" /nix/store/aaaa-one") return 0 ;; (*" /nix/store/bbbb-two") return 1 ;; (*) return 1 ;; esac; }
    nix-store() { printf 'sha256:same0000000000000000000000000000000000000000000000000000\n'; }
    run_as_dx() { printf 'sha256:same0000000000000000000000000000000000000000000000000000\n'; }
    nix_verify_no_bootstrap_path_collision /nix /fixture-volume
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p11_shapea_output" | stdin_matches -F '/nix/store/bbbb-two fails its own content verification' \
    && printf '%s\n' "$p11_shapea_output" | stdin_matches -F 'dx-reset-nix-volume' \
    && ! printf '%s\n' "$p11_shapea_output" | stdin_matches -F 'aaaa-one fails' \
    && printf '%s\n' "$p11_shapea_output" | stdin_matches -x 'exit=1'; then
    test_pass "nix_verify_no_bootstrap_path_collision: Shape A (image self-inconsistency) refuses, naming the exact path and the recovery path"
else
    test_fail "nix_verify_no_bootstrap_path_collision: Shape A (image self-inconsistency) refuses, naming the exact path and the recovery path (output: $p11_shapea_output)"
fi

# Shape B: the volume already validly holds DIFFERENT, self-consistent
# content under this same path name -- the collision docs/release-
# maintenance.md's own prose describes, and the one nix copy's own
# "already valid, skip" behaviour does NOT catch on its own
# (docs/refactor/store-trust-design.md section 1.1's second reproduced
# shape). Both hash prefixes must appear in the refusal.
p11_shapeb_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaaa-one; }
    nix() { return 0; }
    nix-store() { printf 'sha256:imagehash000000000000000000000000000000000000000000000000\n'; }
    run_as_dx() { printf 'sha256:volumehash00000000000000000000000000000000000000000000000\n'; }
    nix_verify_no_bootstrap_path_collision /nix /fixture-volume
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p11_shapeb_output" | stdin_matches -F '/nix/store/aaaa-one already exists on the reused Nix volume with different content' \
    && printf '%s\n' "$p11_shapeb_output" | stdin_matches -F 'sha256:imagehash00' \
    && printf '%s\n' "$p11_shapeb_output" | stdin_matches -F 'sha256:volumehash0' \
    && printf '%s\n' "$p11_shapeb_output" | stdin_matches -F 'dx-reset-nix-volume' \
    && printf '%s\n' "$p11_shapeb_output" | stdin_matches -x 'exit=1'; then
    test_pass "nix_verify_no_bootstrap_path_collision: Shape B (destination already valid, different content) refuses, naming the path and both hashes"
else
    test_fail "nix_verify_no_bootstrap_path_collision: Shape B (destination already valid, different content) refuses, naming the path and both hashes (output: $p11_shapeb_output)"
fi

# The volume has never seen this root at all (the hash query against the
# target store fails outright, e.g. ENOENT/not registered) -- nothing to
# compare, no collision, no diagnostic. This is the ordinary "new path,
# nothing to collide with" case nix copy already handles correctly.
p11_absent_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/aaaa-one; }
    nix() { return 0; }
    nix-store() { printf 'sha256:imagehash000000000000000000000000000000000000000000000000\n'; }
    run_as_dx() { return 1; }
    nix_verify_no_bootstrap_path_collision /nix /fixture-volume
    echo "exit=$?"
} 2>&1)"
if printf '%s\n' "$p11_absent_output" | stdin_matches -x 'exit=0'; then
    test_pass "nix_verify_no_bootstrap_path_collision: the volume has never registered this root at all -> nothing to compare, no diagnostic"
else
    test_fail "nix_verify_no_bootstrap_path_collision: the volume has never registered this root at all -> nothing to compare, no diagnostic (output: $p11_absent_output)"
fi

print_summary
exit_with_code
