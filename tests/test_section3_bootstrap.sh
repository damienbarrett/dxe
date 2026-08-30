#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
test_section "Section 3: Sourceable Guest Bootstrap"

assert_file_exists "$BOOTSTRAP" "bootstrap orchestrator exists"
for module in common base-and-storage system persistence activation; do
    assert_file_exists "$BOOTSTRAP_DIR/$module.sh" "bootstrap $module phase exists"
    if output="$(bash -c 'before=$-; source "$1"; [ "$before" = "$-" ]' _ "$BOOTSTRAP_DIR/$module.sh" 2>&1)" && [ -z "$output" ]; then
        test_pass "bootstrap $module phase is side-effect-free when sourced"
    else
        test_fail "bootstrap $module phase is side-effect-free when sourced"
    fi
done

source "$CONTAINER_DIR/scripts/lib/dx-keyring.sh"
source "$BOOTSTRAP_DIR/common.sh"
source "$BOOTSTRAP_DIR/base-and-storage.sh"
source "$BOOTSTRAP_DIR/system.sh"
source "$BOOTSTRAP_DIR/persistence.sh"
source "$BOOTSTRAP_DIR/activation.sh"
for function_name in dx_validate_atomic_marker_path dx_publish_atomic_marker dx_pipeline_succeeded essentials_profile_path essentials_profile_store_path install_essential_packages essentials_store_valid repair_store_closure ensure_essentials_valid generate_host_keys install_essentials link_system_bash dx_seed_staged_entries dx_move_missing_entries cleanup_stale_nix_store_imports nix_store_import_registered nix_verify_imported_bootstrap_paths nix_install_image_essentials_root nix_seed_volume record_durable_nix_identity migrate_durable_nix_identity_if_needed nix_image_registered_paths nix_image_store_identity nix_image_essentials_identity nix_image_default_profile_store_path capture_nix_image_default_profile nix_restore_image_default_profile nix_image_bootstrap_store_paths nix_target_store_uri nix_image_store_import_required publish_nix_image_store_identity prepare_nix_volume prepare_nix_volume_impl populate_prepared_nix_volume setup_nix_volume configure_single_user_nix configure_release_identity resolve_timezone_file configure_timezone materialize_auth_files auth_entries_with_numeric_id create_user setup_persist dx_ensure_tree_owner dx_prepare_owned_directory configure_ssh dx_host_key_store_trusted dx_host_key_store_populated dx_harden_host_keys dx_persist_host_keys run_as_dx run_home_manager_activation publish_nix_ownership_marker ensure_nix_ownership setup_gh_persistence setup_tmux_persistence setup_herdr_persistence setup_keyring_service dx_seed_herdr_config dx_activate_herdr configure_guest verify_guest_tools; do
    if declare -F "$function_name" >/dev/null; then test_pass "$function_name is directly sourceable"; else test_fail "$function_name is directly sourceable"; fi
done

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
# must establish the shared ~/.local parent as dx before later services create
# ~/.local/state children; otherwise the first dx-ai invocation cannot create
# its own state directory.  Keep this fixture scoped to a temporary persist
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
    if [ ! -d "$fresh_persist/.local" ] || [ ! -d "$fresh_persist/.local/state" ]; then
        echo "xdg-parent-missing"
    else
        echo "xdg-parent-ready"
    fi
    mkdir -p "$fresh_persist/.local/state/dx-ai"
    touch "$fresh_persist/.local/state/dx-ai/child-created-by-dx"
} 2>&1)"
if [ -d "$fresh_persist/.local" ] \
    && [ -d "$fresh_persist/.local/state/dx-ai" ] \
    && [ -f "$fresh_persist/.local/state/dx-ai/child-created-by-dx" ] \
    && printf '%s\n' "$fresh_persist_behavior" | stdin_matches 'xdg-parent-ready'; then
    test_pass "fresh persist prepares ~/.local so dx can create an XDG state child"
else
    test_fail "fresh persist prepares ~/.local so dx can create an XDG state child ($fresh_persist_behavior)"
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

mkdir -p "$fixture/guard/bin"
export DX_GUARD_ROOT="$fixture/guard"
if guard_old_base; then test_pass "old-base guard accepts the official base shape"; else test_fail "old-base guard accepts the official base shape"; fi
ln -s /missing "$fixture/guard/bin/bash"
if guard_old_base >/dev/null 2>&1; then test_fail "old-base guard rejects a dangling /bin/bash signature"; else test_pass "old-base guard rejects a dangling /bin/bash signature"; fi

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

# Bootstrap ordering defect: setup_keyring_service must report an explicit
# diagnostic if dbus-daemon is still not found on dx's PATH, rather than
# dying silently. Historically `dbus_bin="$(run_as_dx 'command -v
# dbus-daemon')"` was a bare assignment: under `set -euo pipefail` a failed
# command substitution there killed the whole (sourced-into-bootstrap.sh)
# script with zero output -- the defect's signature was total silence, so
# this assertion is about outcome (a message mentioning dbus-daemon reaches
# the caller), not about matching text that used to not exist at all.
#
# This must run as a genuinely separate bash process, not a nested command
# substitution within this already-running script: bash's `errexit` does not
# reliably propagate out of a failing bare-assignment command substitution
# that occurs inside a function which is itself being captured by another
# `$(...)` in the same interpreter (verified empirically -- execution quietly
# continues past the failure instead of aborting). The real bootstrap runs
# `configure_guest`/`setup_keyring_service` as the top-level script of its own
# bash process, so a fresh `bash` subprocess is what actually reproduces the
# silent-death signature this test is asserting has been fixed.
dbus_probe_script="$(mktemp "${TMPDIR:-/tmp}/dxe-keyring-diagnostic.XXXXXX")"
cat > "$dbus_probe_script" <<'INNER'
set -euo pipefail
source "$DXE_TEST_CONTAINER_DIR/scripts/lib/dx-keyring.sh"
source "$DXE_TEST_BOOTSTRAP_DIR/common.sh"
source "$DXE_TEST_BOOTSTRAP_DIR/base-and-storage.sh"
source "$DXE_TEST_BOOTSTRAP_DIR/system.sh"
source "$DXE_TEST_BOOTSTRAP_DIR/persistence.sh"
source "$DXE_TEST_BOOTSTRAP_DIR/activation.sh"
mkdir() { :; }
chown() { :; }
run_as_dx() { case "$1" in (*'command -v dbus-daemon'*) return 1 ;; (*) return 0 ;; esac; }
setup_keyring_service
INNER
rc=0
output="$(DXE_TEST_CONTAINER_DIR="$CONTAINER_DIR" DXE_TEST_BOOTSTRAP_DIR="$BOOTSTRAP_DIR" bash "$dbus_probe_script" 2>&1)" || rc=$?
rm -f "$dbus_probe_script"
if [ "$rc" -ne 0 ] && printf '%s\n' "$output" | stdin_matches -i 'dbus-daemon'; then
    test_pass "setup_keyring_service reports an explicit diagnostic when dbus-daemon is missing, instead of dying silently"
else
    test_fail "setup_keyring_service reports an explicit diagnostic when dbus-daemon is missing, instead of dying silently (rc=$rc, output=[$output])"
fi

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

print_summary
exit_with_code
