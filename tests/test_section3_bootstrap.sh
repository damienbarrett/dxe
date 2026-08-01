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

source "$BOOTSTRAP_DIR/common.sh"
source "$BOOTSTRAP_DIR/base-and-storage.sh"
source "$BOOTSTRAP_DIR/system.sh"
source "$BOOTSTRAP_DIR/persistence.sh"
source "$BOOTSTRAP_DIR/activation.sh"
for function_name in essentials_profile_path install_essentials link_system_bash setup_nix_volume configure_nix_daemon configure_release_identity resolve_timezone_file configure_timezone materialize_auth_files create_user setup_persist configure_ssh run_as_dx run_home_manager_activation ensure_nix_ownership setup_gh_persistence setup_tmux_persistence setup_keyring_service configure_guest verify_guest_tools; do
    if declare -F "$function_name" >/dev/null; then test_pass "$function_name is directly sourceable"; else test_fail "$function_name is directly sourceable"; fi
done

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/nix/store/profile/bin" "$fixture/nix/var/nix/profiles/per-user/root"
ln -s "$fixture/nix/store/profile" "$fixture/nix/var/nix/profiles/per-user/root/profile"
export DX_ESSENTIALS_ROOT=$fixture
fixture_physical="$(cd "$fixture" && pwd -P)"
if [ "$(essentials_profile_path)" = "$fixture_physical/nix/store/profile/bin" ]; then test_pass "essentials profile resolves before the Nix remount"; else test_fail "essentials profile resolves before the Nix remount"; fi

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
assert_file_contains_literal "$BOOTSTRAP" 'exec "$(command -v sshd)" -D -e -p 2222' "foreground sshd remains the final bootstrap action"

print_summary
exit_with_code
