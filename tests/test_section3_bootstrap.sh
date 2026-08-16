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
for function_name in essentials_profile_path install_essentials link_system_bash setup_nix_volume configure_nix_daemon configure_release_identity resolve_timezone_file configure_timezone materialize_auth_files create_user setup_persist configure_ssh run_as_dx run_home_manager_activation ensure_nix_ownership setup_gh_persistence setup_tmux_persistence setup_herdr_persistence setup_keyring_service dx_seed_herdr_config dx_activate_herdr configure_guest verify_guest_tools; do
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
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2' "Herdr persistence and config seeding are non-fatal bootstrap activation steps"
assert_file_contains_literal "$BOOTSTRAP" 'exec "$(command -v sshd)" -D -e -p 2222' "foreground sshd remains the final bootstrap action"

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

print_summary
exit_with_code
