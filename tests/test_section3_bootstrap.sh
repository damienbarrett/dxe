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
for function_name in dx_validate_atomic_marker_path dx_publish_atomic_marker dx_pipeline_succeeded dx_bootstrap_scratch_dir dx_persist_durable_identity_record dx_read_durable_identity_record dx_write_nix_volume_record dx_read_nix_volume_record dx_parse_nix_volume_record dx_persist_image_default_profile_target dx_read_image_default_profile_target essentials_profile_path essentials_profile_store_path install_essential_packages essentials_store_valid repair_store_closure verify_remount_prerequisites ensure_essentials_valid generate_host_keys install_essentials link_system_bash dx_seed_staged_entries dx_move_missing_entries cleanup_stale_nix_store_imports nix_store_import_registered nix_verify_imported_bootstrap_paths dx_write_pending_image_identity nix_install_image_essentials_root nix_seed_volume record_durable_nix_identity migrate_durable_nix_identity_if_needed nix_image_registered_paths nix_image_store_identity nix_image_essentials_identity nix_image_default_profile_store_path capture_nix_image_default_profile nix_restore_image_default_profile nix_image_bootstrap_store_paths nix_target_store_uri nix_image_store_import_required nix_verify_single_bootstrap_path_collision nix_verify_no_bootstrap_path_collision publish_nix_image_store_identity dx_nix_format_device dx_nix_mount prepare_nix_volume prepare_nix_volume_impl prepare_nix_volume_direct_impl populate_prepared_nix_volume populate_prepared_nix_volume_in_place publish_nix_volume_image_identity configure_single_user_nix configure_release_identity resolve_timezone_file configure_timezone materialize_auth_files auth_entries_with_numeric_id dx_parse_durable_identity_record create_user setup_persist dx_ensure_tree_owner dx_prepare_owned_directory configure_ssh dx_host_key_store_trusted dx_host_key_store_populated dx_harden_host_keys dx_persist_host_keys run_as_dx run_as_dx_argv dx_nix_root_writable_as_dx run_home_manager_activation publish_nix_ownership_marker ensure_nix_ownership ai_tools_opted_in setup_gh_persistence setup_tmux_persistence setup_herdr_persistence dx_seed_herdr_config dx_activate_herdr configure_guest verify_guest_tools dx_guest_native_system dx_guest_resolve_system; do
    if declare -F "$function_name" >/dev/null; then test_pass "$function_name is directly sourceable"; else test_fail "$function_name is directly sourceable"; fi
done

# setup_nix_volume/setup_nix_volume_impl had no production caller (only
# coverage-driver probes exercised them); they were deleted from
# base-and-storage.sh. Guard against their reappearing.
if ! declare -F setup_nix_volume >/dev/null && ! declare -F setup_nix_volume_impl >/dev/null; then
    test_pass "setup_nix_volume and setup_nix_volume_impl were removed (no production caller)"
else
    test_fail "setup_nix_volume and setup_nix_volume_impl were removed (no production caller)"
fi

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

# Declared once so ShellCheck (SC2154) sees every later dx_parse_nix_volume_
# record call site below as an assignment, not an undeclared read;
# dx_parse_nix_volume_record assigns these names dynamically (Contract 3,
# refactor-v2-final.md), by design, in the caller's own frame.
nix_volume_mode="" nix_volume_root="" nix_volume_device="" nix_volume_fs="" nix_volume_opts=""
mkdir -p "$fixture/nix/store/profile/bin" "$fixture/nix/var/nix/profiles/per-user/root"
ln -s "$fixture/nix/store/profile" "$fixture/nix/var/nix/profiles/per-user/root/profile"
export DX_ESSENTIALS_ROOT=$fixture
fixture_physical="$(cd "$fixture" && pwd -P)"
if [ "$(essentials_profile_path)" = "$fixture_physical/nix/store/profile/bin" ]; then test_pass "essentials profile resolves before the Nix remount"; else test_fail "essentials profile resolves before the Nix remount"; fi

# NAS live gate (first x86_64 bootstrap under the docker-ssh runtime): `nix
# profile install "$bootstrap_root#bootstrap-essentials"` failed there with
#   "An existing package already provides ... dx-bootstrap-essentials/bin/gunzip
#    ... conflicting file from the new package ... gzip-1.14/bin/gunzip"
# Docker injects HOME=/root into the container process at runtime (never in
# the image config), so an unqualified `nix profile install` resolves the
# *default* profile via /root/.nix-profile -> /nix/var/nix/profiles/default,
# which the upstream nixos/nix image already populates with a legacy
# manifest.nix environment (gzip-1.14, gnutar, coreutils-full, ...) that
# conflicts with bootstrap-essentials. Apple's runtime leaves HOME unset for
# PID 1, so the same unqualified install accidentally falls back to
# /nix/var/nix/profiles/per-user/root/profile -- a fresh manifest.json, and
# exactly the profile essentials_profile_store_path already checks first.
# The install must name that profile explicitly so both runtimes agree,
# independent of whatever HOME happens to be for the calling process.
install_argv_fixture="$fixture/install-argv.log"
if (
    nix() { printf '%s\n' "$*" >> "$install_argv_fixture"; }
    DX_BOOTSTRAP_ROOT=/guest-bootstrap
    install_essential_packages
    stdin_matches -F -- '--profile /nix/var/nix/profiles/per-user/root/profile' < "$install_argv_fixture"
); then
    test_pass "install_essential_packages names the per-user root profile explicitly, independent of HOME"
else
    test_fail "install_essential_packages names the per-user root profile explicitly, independent of HOME"
fi

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
    run_as_dx_argv() { "$@"; }
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
    run_as_dx_argv() { :; }
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

# Fable B10: run_as_dx_argv passes every argument through untouched -- no
# shell re-parses it, so a path is one argv element regardless of its
# content. setup_gh_persistence's own relocate/link step (dx_persist_
# relocate_dir/dx_persist_publish_link, scripts/lib/dx-persist-relocate.sh)
# now goes through it (as_dx=1) instead of a string-interpolated
# `run_as_dx "ln -sfnT '$persistent_gh' '$home_gh'"`. A fake setpriv (what
# both run_as_dx and run_as_dx_argv shell out to) records its own argv;
# drive setup_gh_persistence against a fixture path containing both a space
# and an apostrophe -- the two characters careful quoting of a shell
# string would have had to get right -- and assert the recorded argv holds
# each path as one intact element.
argv_capture_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-argv-capture.XXXXXX")"
argv_capture_log="$argv_capture_fixture/setpriv-argv.log"
gh_argv_persist="$argv_capture_fixture/gh persist/home/dx"
gh_argv_home="$argv_capture_fixture/gh's home"
mkdir -p "$gh_argv_persist/.config" "$gh_argv_home/.config"
(
    chown() {
        local args=() arg
        for arg in "$@"; do
            if [ "$arg" = dx:dx ]; then args+=("$(id -u):$(id -g)"); else args+=("$arg"); fi
        done
        command chown "${args[@]}"
    }
    setpriv() { : > "$argv_capture_log"; printf '%s\n' "$@" >> "$argv_capture_log"; }
    setup_gh_persistence "$gh_argv_persist" "$gh_argv_home"
) >/dev/null 2>&1
if grep -qFx "$gh_argv_persist/.config/gh" "$argv_capture_log" 2>/dev/null \
    && grep -qFx "$gh_argv_home/.config/gh" "$argv_capture_log" 2>/dev/null; then
    test_pass "run_as_dx_argv passes a path containing a space and an apostrophe through as one argv element"
else
    test_fail "run_as_dx_argv passes a path containing a space and an apostrophe through as one argv element (captured: $(cat "$argv_capture_log" 2>/dev/null | tr '\n' '|'))"
fi
rm -rf "$argv_capture_fixture"

# Fable B11: NU_PATH (configure_guest's own "set nushell as default shell"
# step) was assigned without `local`, an unintended global that would leak
# into any later code reading a variable of that name. Drive configure_guest
# end to end with every heavier dependency stubbed, and assert NU_PATH is
# gone (declare -p fails) the moment the function returns -- true only if
# it was actually scoped to the function, regardless of whether the local
# nu binary this assigns from exists (it does not, on this host, so the
# `[ -f "$NU_PATH" ]` guard's own body never runs either way).
if (
    ensure_nix_ownership() { :; }
    dx_ensure_tree_owner() { :; }
    dx_prepare_owned_directory() { :; }
    run_as_dx() { :; }
    run_as_dx_argv() { :; }
    setup_gh_persistence() { :; }
    setup_tmux_persistence() { :; }
    ai_tools_opted_in() { return 1; }
    dx_activate_herdr() { :; }
    run_home_manager_activation() { :; }
    configure_guest >/dev/null
    ! declare -p NU_PATH >/dev/null 2>&1
); then
    test_pass "configure_guest's NU_PATH does not leak as a global"
else
    test_fail "configure_guest's NU_PATH does not leak as a global"
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
    run_as_dx_argv() { return 0; }
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
    run_as_dx_argv() { return 0; }
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
# Fable review B8/D7: the six "Bootstrap phase: ... completed in Ns" lines
# below used to be asserted by grepping the literal text out of the phase
# functions' own source. Each is now driven through the real function with
# only its own immediate dependencies stubbed, so the assertion exercises
# the actual timing/echo logic instead of parsing source text.
p_ie_output="$({
    useradd() { :; }
    install_essentials
} 2>&1)" || true
if printf '%s\n' "$p_ie_output" | stdin_matches -F 'Bootstrap phase: essentials installation completed in'; then
    test_pass "install_essentials reports elapsed time on completion"
else
    test_fail "install_essentials reports elapsed time on completion (output: $p_ie_output)"
fi

p_pnv_output="$({
    export DX_BOOTSTRAP_SCRATCH_DIR="$fixture/p-pnv-scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { [ "$*" = '-n -o TARGET,FSTYPE /nix' ] && printf '%s\n' '/nix btrfs' || return 1; }
    prepare_nix_volume
} 2>&1)" || true
if printf '%s\n' "$p_pnv_output" | stdin_matches -F 'Bootstrap phase: Nix volume prepare/mount completed in'; then
    test_pass "prepare_nix_volume reports elapsed time on completion"
else
    test_fail "prepare_nix_volume reports elapsed time on completion (output: $p_pnv_output)"
fi

p_eev_output="$({
    essentials_profile_store_path() { printf '%s\n' /fake/essentials-profile; }
    essentials_store_valid() { return 0; }
    ensure_essentials_valid
} 2>&1)" || true
if printf '%s\n' "$p_eev_output" | stdin_matches -F 'Bootstrap phase: essentials verification/repair completed in'; then
    test_pass "ensure_essentials_valid reports elapsed time on completion"
else
    test_fail "ensure_essentials_valid reports elapsed time on completion (output: $p_eev_output)"
fi

p_eno_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-phase-ownership.XXXXXX")"
p_eno_output="$({
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
    run_as_dx_argv() { return 0; }
    essentials_store_valid() { return 0; }
    mkdir -p "$p_eno_root/store" "$p_eno_root/var/nix"
    DX_NIX_OWNERSHIP_ROOT="$p_eno_root" publish_nix_ownership_marker >/dev/null
    DX_NIX_OWNERSHIP_ROOT="$p_eno_root" ensure_nix_ownership
} 2>&1)" || true
rm -rf "$p_eno_root"
if printf '%s\n' "$p_eno_output" | stdin_matches -F 'Bootstrap phase: Nix ownership check/migration completed in'; then
    test_pass "ensure_nix_ownership reports elapsed time on completion"
else
    test_fail "ensure_nix_ownership reports elapsed time on completion (output: $p_eno_output)"
fi

p_hma_output="$({
    validate_positive_integer() { return 0; }
    run_as_dx_with_timeout() { return 0; }
    dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }
    export DX_BOOTSTRAP_ROOT="$fixture" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_home_manager_activation
} 2>&1)" || true
if printf '%s\n' "$p_hma_output" | stdin_matches -F 'Bootstrap phase: Home Manager activation completed in'; then
    test_pass "run_home_manager_activation reports elapsed time on completion"
else
    test_fail "run_home_manager_activation reports elapsed time on completion (output: $p_hma_output)"
fi

p_vgt_output="$({
    run_as_dx() { return 0; }
    verify_guest_tools
} 2>&1)" || true
if printf '%s\n' "$p_vgt_output" | stdin_matches -F 'Bootstrap phase: final guest tool verification completed in'; then
    test_pass "verify_guest_tools reports elapsed time on completion"
else
    test_fail "verify_guest_tools reports elapsed time on completion (output: $p_vgt_output)"
fi
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
export DX_BOOTSTRAP_SCRATCH_DIR="$fixture/p7-fp-scratch"
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
export DX_BOOTSTRAP_SCRATCH_DIR="$fixture/p7-tp-scratch"
p7_tp_output="$({
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() {
        printf '%s\n' "$*" >> "$p7_tp_log"
        if [ "$*" = '-n -o TARGET,FSTYPE /nix' ]; then printf '%s\n' '/nix btrfs'; else return 1; fi
    }
    prepare_nix_volume_impl
    record="$(dx_read_nix_volume_record)"
    dx_parse_nix_volume_record "$record"
    echo "already_mounted=$([ "$nix_volume_mode" = already-mounted ] && echo true || echo false) root=$nix_volume_root"
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
export DX_BOOTSTRAP_SCRATCH_DIR="$p8_fixture/explicit-apple-scratch"
p8_explicit_apple_output="$({
    DX_NIX_STORAGE_MODE=apple-image
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() {
        printf '%s\n' "$*" >> "$p8_explicit_apple_log"
        if [ "$*" = '-n -o TARGET,FSTYPE /nix' ]; then printf '%s\n' '/nix btrfs'; else return 1; fi
    }
    prepare_nix_volume_impl
    record="$(dx_read_nix_volume_record)"
    dx_parse_nix_volume_record "$record"
    echo "already_mounted=$([ "$nix_volume_mode" = already-mounted ] && echo true || echo false) root=$nix_volume_root"
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
    export DX_BOOTSTRAP_SCRATCH_DIR="$p8_fixture/mounted-scratch"
    prepare_nix_volume_impl
    record="$(dx_read_nix_volume_record)"
    dx_parse_nix_volume_record "$record"
    echo "root=$nix_volume_root in_place=$([ "$nix_volume_mode" = in-place ] && echo true || echo false) already_mounted=$([ "$nix_volume_mode" = already-mounted ] && echo true || echo unset)"
} 2>&1)"
if printf '%s\n' "$p8_mounted_output" | stdin_matches -x 'root=/nix in_place=true already_mounted=unset' \
    && [ "$(cat "$p8_identity_log")" = /nix ] \
    && ! grep -qE '^(mount|umount|truncate|blkid|mkfs\.btrfs|mkfs\.ext4) ' "$p8_mounted_log"; then
    test_pass "prepare_nix_volume_direct_impl: /nix already mounted -> sets DX_NIX_VOLUME_IN_PLACE (not ALREADY_MOUNTED), records durable identity, no mutating call"
else
    test_fail "prepare_nix_volume_direct_impl: /nix already mounted -> sets DX_NIX_VOLUME_IN_PLACE (not ALREADY_MOUNTED), records durable identity, no mutating call (output: $p8_mounted_output; identity-log: $(cat "$p8_identity_log" 2>/dev/null); mutating-log: $(cat "$p8_mounted_log" 2>/dev/null))"
fi

rm -rf "$p8_fixture"

# P9 (Branch 11 / Phase 3, Increment 3; corrected Branch 11 / Phase 4,
# Findings 6 and 7): populate_prepared_nix_volume's explicit dispatch on
# DX_NIX_VOLUME_IN_PLACE, and populate_prepared_nix_volume_in_place's
# amended two-check protocol (docs/refactor/direct-volume-storage.md
# section 5.3): store-missing refusal, DX_IMAGE_IDENTITY-absent refusal,
# the new image-identity marker (write-once / match-and-continue /
# mismatch-refuse), and -- as landed, replacing the original
# nix_image_store_import_required corruption-only signal this comment used
# to describe -- direct content verification of the bounded bootstrap-root
# set once the marker matches (Finding 6), keyed by DX_IMAGE_IDENTITY's own
# bare digest with its `sha256:` prefix stripped and validated before use
# (Finding 7). Lower-level Nix collaborators are stubbed throughout (their
# own behavior is unchanged and tested elsewhere -- Section 5,
# tests/test_nix_store_import.sh); these tests isolate only the new
# dispatch/marker/verification logic this increment and its two corrections
# add. owner_uid/owner_gid fall back to the production code's own "0"
# default (no real "dx" user exists on this host, exactly like every other
# isolated fixture in this file).
p9_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p9-in-place-populate.XXXXXX")"

# 1. Store missing: refuse, naming the Docker copy-on-first-mount
# dependency, before nix_image_store_import_required is ever consulted.
p9_missing_root="$p9_fixture/vol-missing"
mkdir -p "$p9_missing_root"
p9_missing_calls="$p9_fixture/missing-calls.log"
if (
    nix_image_store_import_required() { printf 'CALLED %s\n' "$*" >> "$p9_missing_calls"; return 1; }
    DX_IMAGE_IDENTITY=sha256:0000000000000000000000000000000000000000000000000000000000000000
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

# 2b (Branch 11 / Phase 4, Finding 7): store present, DX_IMAGE_IDENTITY
# present but NOT the runtime-shaped `sha256:<64 hex>` token (a foreign
# runtime, or a future format change) -> fail closed with a clear message
# naming the offending value, before nix_install_image_essentials_root (and
# therefore before any GC-roots publication under a garbage directory name)
# is ever reached.
p9_root_badshape="$p9_fixture/vol-badshape"
mkdir -p "$p9_root_badshape/store"
p9_badshape_calls="$p9_fixture/badshape-calls.log"
if (
    nix_install_image_essentials_root() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_badshape_calls"; }
    DX_IMAGE_IDENTITY="md5:not-the-expected-shape"
    populate_prepared_nix_volume_in_place "$p9_root_badshape"
) >"$p9_fixture/badshape.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: a non-sha256:<64 hex> DX_IMAGE_IDENTITY refuses before publishing GC roots"
else
    if stdin_matches -F 'is not the expected sha256:<64 hex> shape' < "$p9_fixture/badshape.out" \
        && stdin_matches -F 'md5:not-the-expected-shape' < "$p9_fixture/badshape.out" \
        && [ ! -s "$p9_badshape_calls" ]; then
        test_pass "populate_prepared_nix_volume_in_place: a non-sha256:<64 hex> DX_IMAGE_IDENTITY refuses before publishing GC roots, naming the offending value"
    else
        test_fail "populate_prepared_nix_volume_in_place: a non-sha256:<64 hex> DX_IMAGE_IDENTITY refuses before publishing GC roots, naming the offending value (out: $(cat "$p9_fixture/badshape.out"); calls: $(cat "$p9_badshape_calls" 2>/dev/null))"
    fi
fi

# 3. Marker absent (first bootstrap-managed boot for this volume): writes
# it atomically with the env value, then installs/publishes the essentials
# roots keyed by DX_IMAGE_IDENTITY's bare digest, with its `sha256:`
# algorithm prefix stripped before it is ever passed on as
# DX_NIX_PENDING_IMAGE_STORE_IDENTITY (Branch 11 / Phase 4, Finding 6: never
# DX_IMAGE_IDENTITY's live-store-hash predecessor; Finding 7: the prefixed
# token itself is not a valid GC-roots key, so the strip has to happen
# before this one call, not after), and never surviving past that one call
# -- see the function's own comment. Neither nix_image_store_import_required
# NOR nix_image_store_identity (the real `nix path-info --all` enumerator)
# may be consulted on this path.
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
    nix_image_store_identity() { printf 'MUST-NOT-BE-CALLED\n' >> "$p9_fresh_calls"; return 1; }
    nix_install_image_essentials_root() { printf 'install_root %s\n' "$*" >> "$p9_fresh_calls"; }
    DX_IMAGE_IDENTITY=sha256:1100000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_fresh" 0 0
    echo "marker=$(cat "$p9_root_fresh/.dx-image-identity-v1" 2>/dev/null)"
    echo "pending-after-return=${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-<unset>}"
} 2>&1)"
if printf '%s\n' "$p9_fresh_output" | stdin_matches -F 'marker=sha256:1100000000000000000000000000000000000000000000000000000000000000' \
    && printf '%s\n' "$p9_fresh_output" | stdin_matches -F 'pending-after-return=<unset>' \
    && grep -qF -- 'install_root' "$p9_fresh_calls" \
    && grep -qF -- '1100000000000000000000000000000000000000000000000000000000000000' "$p9_fresh_calls" \
    && ! grep -qF -- 'MUST-NOT-BE-CALLED' "$p9_fresh_calls"; then
    test_pass "populate_prepared_nix_volume_in_place: marker absent -> writes it, publishes roots keyed by DX_IMAGE_IDENTITY passed as an explicit fourth argument (Contract 1, Fable B6 item 4), never calls nix_image_store_identity, and DX_NIX_PENDING_IMAGE_STORE_IDENTITY is never set at all"
else
    test_fail "populate_prepared_nix_volume_in_place: marker absent -> writes it, publishes roots keyed by DX_IMAGE_IDENTITY passed as an explicit fourth argument (Contract 1, Fable B6 item 4), never calls nix_image_store_identity, and DX_NIX_PENDING_IMAGE_STORE_IDENTITY is never set at all (output: $p9_fresh_output; calls: $(cat "$p9_fresh_calls" 2>/dev/null))"
fi

# 3b (Branch 11 / Phase 4, Finding 7 -- the real first-boot failure on a
# real, runtime-shaped DX_IMAGE_IDENTITY token): both runtimes' image
# identity carries the `sha256:` algorithm prefix (dx_runtime_apple_image_
# identity's own `printf 'sha256:%s'`; Docker's `image inspect --format
# '{{.Id}}'`), 71 chars total, never a bare 64-hex digest. Every fixture
# above and below uses that real shape for DX_IMAGE_IDENTITY, but each one
# also mocks nix_install_image_essentials_root itself, so none of them
# actually exercises its own identity-shape validation or its GC-roots
# directory name -- exactly the gap that let Finding 7 land undetected.
# This fixture runs the REAL nix_install_image_essentials_root (only its
# own nix_image_bootstrap_store_paths collaborator and chown are stubbed,
# same reasons as test 3 above) and asserts the published GC-roots
# directory is named by the BARE digest, with no `sha256:` anywhere in the
# path.
p9_root_realroots="$p9_fixture/vol-realroots"
mkdir -p "$p9_root_realroots/store"
p9_realroots_calls="$p9_fixture/realroots-calls.log"
if (
    chown() { printf 'chown %s\n' "$*" >> "$p9_realroots_calls"; }
    nix_image_bootstrap_store_paths() { printf '%s\n' "/nix/store/dddddddddddddddddddddddddddddddd-essentials"; }
    DX_IMAGE_IDENTITY=sha256:8800000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_realroots"
) >"$p9_fixture/realroots.out" 2>&1; then
    if [ -L "$p9_root_realroots/var/nix/gcroots/dx-image-roots-v2-8800000000000000000000000000000000000000000000000000000000000000/dddddddddddddddddddddddddddddddd-essentials" ] \
        && [ ! -e "$p9_root_realroots/var/nix/gcroots/dx-image-roots-v2-sha256:8800000000000000000000000000000000000000000000000000000000000000" ]; then
        test_pass "populate_prepared_nix_volume_in_place: the real nix_install_image_essentials_root publishes GC roots named by the bare 64-hex digest, never the sha256:-prefixed token (Finding 7)"
    else
        test_fail "populate_prepared_nix_volume_in_place: the real nix_install_image_essentials_root publishes GC roots named by the bare 64-hex digest, never the sha256:-prefixed token (Finding 7) (out: $(cat "$p9_fixture/realroots.out"); tree: $(find "$p9_root_realroots/var/nix/gcroots" 2>/dev/null))"
    fi
else
    test_fail "populate_prepared_nix_volume_in_place: the real nix_install_image_essentials_root publishes GC roots named by the bare 64-hex digest, never the sha256:-prefixed token (Finding 7) (out: $(cat "$p9_fixture/realroots.out"))"
fi

# 4/reproducer (Branch 11 / Phase 4, Finding 6 -- a real, deterministic NAS
# recreate-check failure): a reused volume (image-identity marker matches)
# must be verified by DIRECT CONTENT of the bounded bootstrap-root set, not
# by comparing a whole-store content hash. In direct-volume mode /nix IS
# the volume from container start (no remount ever replaces it), so that
# hash is of the LIVE store and legitimately changes on every boot that
# touches Nix at all (Home Manager activation, dx-ai, ...) -- comparing it
# against a marker published on an earlier, less-grown boot refused every
# single reused-volume reboot, deterministically. This fixture's `nix`
# stub answers `path-info --all` with a list that would never match
# anything recorded earlier -- proving the fix no longer even asks the
# question: RED before the fix (the old code refused here), GREEN after
# (only the bounded `store verify --recursive --no-trust` over the actual
# bootstrap roots decides this now, and it reports the store healthy).
p9_root_match="$p9_fixture/vol-match"
mkdir -p "$p9_root_match/store"
printf 'sha256:2200000000000000000000000000000000000000000000000000000000000000\n' > "$p9_root_match/.dx-image-identity-v1"
# A stale marker from an older, pre-Finding-6 boot may still physically
# exist on a real reused volume; the fixed code must never read it.
printf 'unrelated-stale-marker-from-before-this-fix\n' > "$p9_root_match/.dx-image-store-identity"
p9_match_calls="$p9_fixture/match-calls.log"
p9_match_output="$({
    nix_image_store_import_required() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_match_calls"; return 1; }
    nix_image_bootstrap_store_paths() { printf '%s\n' "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-essentials"; }
    run_as_dx() { eval "$1"; }
    # A case statement defined inline inside a command substitution's own
    # captured text breaks this host's bash 3.2 parser outright -- the same
    # narrow parser bug the P11 block far below in this file already works
    # around (see its own comment, above p11_clear_output, for the
    # unbalanced-paren-counting mechanics). Reduced here to its simplest
    # form and confirmed separately: even a single bracketed case arm with
    # no quoting at all is enough to trip it when it appears literally
    # inside command-substitution syntax; calling a case-using function
    # that is defined OUTSIDE the substitution is unaffected, and so is a
    # case-using function defined inline inside a plain parenthesized
    # subshell that is not itself command-substituted. Avoided here with
    # if/double-bracket glob matching instead of the P11 block's own
    # leading-paren-per-arm convention, specifically so this comment can
    # describe the bug without embedding another unbalanced example for
    # the same naive counter to trip over.
    nix() {
        printf 'CALL %s\n' "$*" >> "$p9_match_calls"
        if [[ "$*" == *'path-info --all'* ]]; then
            # A live store's registered set after real activation --
            # deliberately unrelated to anything a marker could have
            # recorded earlier. Reaching this stub at all is itself a
            # test failure (see the "never invoked" assertion below);
            # answering it plausibly just means a regression back to
            # the old behaviour fails for the RIGHT reason (a mismatch)
            # rather than a fixture wiring accident.
            printf '/nix/store/grown-after-first-boot-activation\n'
        elif [[ "$*" == *'store verify --store'*'--recursive --no-trust'* ]]; then
            return 0
        else
            return 1
        fi
    }
    nix_install_image_essentials_root() { printf 'install_root %s\n' "$*" >> "$p9_match_calls"; }
    DX_IMAGE_IDENTITY=sha256:2200000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_match"
} 2>&1)"
if printf '%s\n' "$p9_match_output" | stdin_matches -F 'Image Nix essentials verified; skipping image-store import.' \
    && ! printf '%s\n' "$p9_match_output" | stdin_matches -F 'Error' \
    && grep -qF -- 'install_root' "$p9_match_calls" \
    && grep -qF -- "store verify --store" "$p9_match_calls" \
    && ! grep -qF -- 'MUST-NOT-BE-CALLED' "$p9_match_calls" \
    && [ "$(cat "$p9_root_match/.dx-image-identity-v1")" = 'sha256:2200000000000000000000000000000000000000000000000000000000000000' ]; then
    test_pass "populate_prepared_nix_volume_in_place: a reused volume (marker matches) is verified by the bounded bootstrap-root content, not a live whole-store hash -- does not refuse, roots republished (Finding 6 reproducer)"
else
    test_fail "populate_prepared_nix_volume_in_place: a reused volume (marker matches) is verified by the bounded bootstrap-root content, not a live whole-store hash -- does not refuse, roots republished (Finding 6 reproducer) (output: $p9_match_output; calls: $(cat "$p9_match_calls" 2>/dev/null))"
fi
if ! grep -qF -- 'path-info --all' "$p9_match_calls"; then
    test_pass "populate_prepared_nix_volume_in_place: nix path-info --all (nix_image_store_identity) is never invoked on the reused-volume path"
else
    test_fail "populate_prepared_nix_volume_in_place: nix path-info --all (nix_image_store_identity) is never invoked on the reused-volume path (calls: $(cat "$p9_match_calls" 2>/dev/null))"
fi

# 5. Marker present and matching, but the bounded bootstrap-root content
# verification fails (corruption, or an interrupted prior write, since this
# volume was last confirmed) -> refuse, citing store-trust-plan.md;
# nix_install_image_essentials_root must not run.
p9_root_corrupt="$p9_fixture/vol-corrupt"
mkdir -p "$p9_root_corrupt/store"
printf 'sha256:3300000000000000000000000000000000000000000000000000000000000000\n' > "$p9_root_corrupt/.dx-image-identity-v1"
if (
    nix_image_bootstrap_store_paths() { printf '%s\n' "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-essentials"; }
    run_as_dx() { eval "$1"; }
    nix() { return 1; }
    nix_install_image_essentials_root() { echo "MUST-NOT-RUN"; }
    DX_IMAGE_IDENTITY=sha256:3300000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_corrupt"
) >"$p9_fixture/corrupt.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: marker matches but bootstrap-root content verification fails -> refuses"
else
    if stdin_matches -F 'store-trust-plan.md' < "$p9_fixture/corrupt.out" \
        && ! stdin_matches -F 'MUST-NOT-RUN' < "$p9_fixture/corrupt.out"; then
        test_pass "populate_prepared_nix_volume_in_place: marker matches but bootstrap-root content verification fails -> refuses, citing store-trust-plan.md, before publishing roots"
    else
        test_fail "populate_prepared_nix_volume_in_place: marker matches but bootstrap-root content verification fails -> refuses, citing store-trust-plan.md, before publishing roots (out: $(cat "$p9_fixture/corrupt.out"))"
    fi
fi

# 5b. Marker matches but nix_image_bootstrap_store_paths resolves no roots
# at all -> fail closed with a clear message rather than trivially
# "verifying" an empty set and calling the volume trustworthy.
p9_root_noroots="$p9_fixture/vol-noroots"
mkdir -p "$p9_root_noroots/store"
printf 'sha256:4400000000000000000000000000000000000000000000000000000000000000\n' > "$p9_root_noroots/.dx-image-identity-v1"
if (
    nix_image_bootstrap_store_paths() { :; }
    nix_install_image_essentials_root() { echo "MUST-NOT-RUN"; }
    run_as_dx() { echo "MUST-NOT-VERIFY"; }
    DX_IMAGE_IDENTITY=sha256:4400000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_noroots"
) >"$p9_fixture/noroots.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: no bootstrap roots resolved -> fails closed"
else
    if stdin_matches -F 'no bootstrap root paths resolved' < "$p9_fixture/noroots.out" \
        && ! stdin_matches -F 'MUST-NOT-RUN' < "$p9_fixture/noroots.out" \
        && ! stdin_matches -F 'MUST-NOT-VERIFY' < "$p9_fixture/noroots.out"; then
        test_pass "populate_prepared_nix_volume_in_place: no bootstrap roots resolved -> fails closed with a clear message, before verification or republishing"
    else
        test_fail "populate_prepared_nix_volume_in_place: no bootstrap roots resolved -> fails closed with a clear message, before verification or republishing (out: $(cat "$p9_fixture/noroots.out"))"
    fi
fi

# 6. Marker present and MISMATCHED (a genuine image bump on a reused
# volume): refuse, naming both identities prefix-shortened and
# store-trust-plan.md, WITHOUT ever consulting the bootstrap-root content
# verification (the marker mismatch is decisive on its own -- design point
# D's amendment).
p9_root_bump="$p9_fixture/vol-bump"
mkdir -p "$p9_root_bump/store"
printf 'sha256:5500000000000000000000000000000000000000000000000000000000000000\n' > "$p9_root_bump/.dx-image-identity-v1"
p9_bump_calls="$p9_fixture/bump-calls.log"
if (
    nix_image_store_import_required() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_bump_calls"; return 1; }
    nix_image_bootstrap_store_paths() { printf 'MUST-NOT-BE-CALLED %s\n' "$*" >> "$p9_bump_calls"; return 1; }
    DX_IMAGE_IDENTITY=sha256:6600000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume_in_place "$p9_root_bump"
) >"$p9_fixture/bump.out" 2>&1; then
    test_fail "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses"
else
    if stdin_matches -F 'sha256:550000000000' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'sha256:660000000000' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'store-trust-plan.md' < "$p9_fixture/bump.out" \
        && stdin_matches -F 'recreate the Nix volume' < "$p9_fixture/bump.out" \
        && [ ! -s "$p9_bump_calls" ]; then
        test_pass "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses, naming both identities and store-trust-plan.md, without ever consulting the bootstrap-root content verification"
    else
        test_fail "populate_prepared_nix_volume_in_place: a mismatched marker (image bump) refuses, naming both identities and store-trust-plan.md, without ever consulting the bootstrap-root content verification (out: $(cat "$p9_fixture/bump.out"); calls: $(cat "$p9_bump_calls" 2>/dev/null))"
    fi
fi

# 7. Dispatch integration: populate_prepared_nix_volume with
# DX_NIX_VOLUME_IN_PLACE=true routes to populate_prepared_nix_volume_in_place
# (never the apple-image remount/fstab tail below it).
p9_root_dispatch="$p9_fixture/vol-dispatch"
mkdir -p "$p9_root_dispatch/store"
printf 'sha256:7700000000000000000000000000000000000000000000000000000000000000\n' > "$p9_root_dispatch/.dx-image-identity-v1"
p9_dispatch_output="$({
    nix_image_bootstrap_store_paths() { printf '%s\n' "/nix/store/cccccccccccccccccccccccccccccccc-essentials"; }
    run_as_dx() { eval "$1"; }
    # A `case` statement defined inline inside this `$(...)` command
    # substitution's own text breaks this host's bash 3.2 parser (see the
    # longer comment on the same pattern above); `if`/`[[ ]]` avoids it.
    nix() {
        if [[ "$*" == *'store verify --store'*'--recursive --no-trust'* ]]; then
            return 0
        else
            return 1
        fi
    }
    nix_install_image_essentials_root() { echo "roots-published"; }
    umount() { echo "MUST-NOT-UMOUNT"; }
    mount() { echo "MUST-NOT-MOUNT"; }
    export DX_BOOTSTRAP_SCRATCH_DIR="$p9_fixture/dispatch-scratch"
    dx_write_nix_volume_record in-place "$p9_root_dispatch"
    export DX_IMAGE_IDENTITY=sha256:7700000000000000000000000000000000000000000000000000000000000000
    populate_prepared_nix_volume 0 0
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

# Ordering (Fable review B8): verify_remount_prerequisites must run strictly
# after populate_prepared_nix_volume (the remount in apple-image mode;
# container start in direct-volume mode -- bootstrap_phases' own shared call
# site either way) and strictly before nix_restore_image_default_profile,
# whose own named tools it exists to check ahead of. Proven behaviourally:
# source the orchestrator (its own `[ "${BASH_SOURCE[0]}" = "$0" ]` guard,
# asserted above, keeps sourcing from running bootstrap_main or execing
# sshd), shadow every documented phase function with a stub that logs its
# own $FUNCNAME, and call bootstrap_phases() -- not by comparing grep line
# numbers in bootstrap.sh's source text.
p10b_output="$({
    # shellcheck source=../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh
    source "$BOOTSTRAP"
    configure_single_user_nix() { printf '%s\n' "${FUNCNAME[0]}"; }
    install_essentials() { printf '%s\n' "${FUNCNAME[0]}"; }
    link_system_bash() { printf '%s\n' "${FUNCNAME[0]}"; }
    capture_nix_image_default_profile() { printf '%s\n' "${FUNCNAME[0]}"; }
    prepare_nix_volume() { printf '%s\n' "${FUNCNAME[0]}"; }
    materialize_auth_files() { printf '%s\n' "${FUNCNAME[0]}"; }
    create_user() { printf '%s\n' "${FUNCNAME[0]}"; }
    populate_prepared_nix_volume() { printf '%s\n' "${FUNCNAME[0]}"; }
    verify_remount_prerequisites() { printf '%s\n' "${FUNCNAME[0]}"; }
    nix_restore_image_default_profile() { printf '%s\n' "${FUNCNAME[0]}"; }
    ensure_essentials_valid() { printf '%s\n' "${FUNCNAME[0]}"; }
    publish_nix_image_store_identity() { printf '%s\n' "${FUNCNAME[0]}"; }
    configure_release_identity() { printf '%s\n' "${FUNCNAME[0]}"; }
    setup_persist() { printf '%s\n' "${FUNCNAME[0]}"; }
    configure_ssh() { printf '%s\n' "${FUNCNAME[0]}"; }
    configure_guest() { printf '%s\n' "${FUNCNAME[0]}"; }
    verify_guest_tools() { printf '%s\n' "${FUNCNAME[0]}"; }
    configure_timezone() { printf '%s\n' "${FUNCNAME[0]}"; }
    bootstrap_phases
} 2>&1)" || true
p10b_expected="configure_single_user_nix
install_essentials
link_system_bash
capture_nix_image_default_profile
prepare_nix_volume
materialize_auth_files
create_user
populate_prepared_nix_volume
verify_remount_prerequisites
nix_restore_image_default_profile
ensure_essentials_valid
publish_nix_image_store_identity
configure_release_identity
setup_persist
configure_ssh
configure_guest
verify_guest_tools
configure_timezone"
if [ "$p10b_output" = "$p10b_expected" ]; then
    test_pass "bootstrap_phases runs every documented phase in order (shadowed-function log, not a grep-line-number comparison)"
else
    test_fail "bootstrap_phases runs every documented phase in order (shadowed-function log, not a grep-line-number comparison) (log: $p10b_output)"
fi

p10b_populate_idx="$(printf '%s\n' "$p10b_output" | grep -n -x 'populate_prepared_nix_volume' | cut -d: -f1)"
p10b_verify_idx="$(printf '%s\n' "$p10b_output" | grep -n -x 'verify_remount_prerequisites' | cut -d: -f1)"
p10b_restore_idx="$(printf '%s\n' "$p10b_output" | grep -n -x 'nix_restore_image_default_profile' | cut -d: -f1)"
if [ -n "$p10b_populate_idx" ] && [ -n "$p10b_verify_idx" ] && [ -n "$p10b_restore_idx" ] \
    && [ "$p10b_populate_idx" -lt "$p10b_verify_idx" ] && [ "$p10b_verify_idx" -lt "$p10b_restore_idx" ]; then
    test_pass "bootstrap_phases (behavioural log) runs verify_remount_prerequisites strictly between populate_prepared_nix_volume and nix_restore_image_default_profile"
else
    test_fail "bootstrap_phases (behavioural log) runs verify_remount_prerequisites strictly between populate_prepared_nix_volume and nix_restore_image_default_profile (log: $p10b_output)"
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

# P12 (docs/reviews/2026-09-29-fable.md finding B2, WP3.2): the wrapper
# `if prepare_nix_volume_impl "$@"; then` (below prepare_nix_volume_impl)
# invokes it as an `if` condition, so Bash suspends errexit for the whole
# function body -- a failing mkfs/truncate/mount was silently ignored,
# DX_NIX_VOLUME_ROOT was still set to /mnt/tmp-nix, and the phase printed
# "... completed". The next phase (populate_prepared_nix_volume) then finds
# no store at that path and tars the image store into the ephemeral rootfs
# before failing -- bricking the guest until recreate.
#
# DX_NIX_RAW_PATH is a test-only override, added alongside these cases,
# mirroring DX_NIX_DISK_SIZE two lines below it in the source: production
# never sets it, so the hardcoded /var/lib/dx-nix-raw default is unchanged,
# but it lets these fixtures point the directory-style branch at a plain
# writable temp directory. /var/lib itself is root-owned on every host this
# suite runs on unprivileged, so without this seam the mkfs/truncate/mount
# lines below are simply unreachable outside a real guest boot. mkfs/
# truncate/mount themselves stay stubbed either way -- they need
# CAP_SYS_ADMIN this runner does not have -- and are validated on the live
# tier only (docs/refactor/validation-matrix.md).
#
# Each case below runs the whole fixture as the left side of `(...) || true`
# rather than a bare statement: prepare_nix_volume_impl's own bug (errexit
# suspended inside an `if` condition) means a failing stub never aborts the
# subshell early either way, but populate_prepared_nix_volume's
# `${DX_NIX_VOLUME_ROOT:?...}` guard performs an unconditional shell exit
# when unset (not an ordinary non-zero return), which -- unlike a normal
# command failure -- is not suppressed by an `if`/`&&`/`||` context around
# the call itself. Only nesting the whole capture in its own subshell
# contains that abrupt exit to the subshell instead of this test file.
p12_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p12-unchecked-privileged.XXXXXX")"

# (a) A failing mount (the task's own reproduction): an older kernel
# rejecting a mount option, or any other mount(8) failure. Every other stub
# is a "happy path" no-op (truncate creates the sparse image file, mkfs
# succeeds); only mount fails. tar is a MUST-NOT sentinel: if
# prepare_nix_volume still reported success, a following
# populate_prepared_nix_volume call would try to seed the image store with
# tar -- proving the brick, not just the exit code.
p12_raw_mount="$p12_fixture/dx-nix-raw-mount"
mkdir -p "$p12_raw_mount"
p12_mount_out="$p12_fixture/mount-fail.out"
(
    export DX_NIX_RAW_PATH="$p12_raw_mount"
    export DX_BOOTSTRAP_SCRATCH_DIR="$p12_raw_mount/scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { return 1; }
    blkid() { return 1; }
    umount() { :; }
    tar() { echo MUST-NOT-TAR; return 1; }
    truncate() { : > "${3:?}"; }
    mkfs.btrfs() { :; }
    mkfs.ext4() { :; }
    mount() { echo 'mount: wrong fs type' >&2; return 32; }
    prepare_nix_volume
    echo "prepare_exit=$?"
    echo "root=$(dx_read_nix_volume_record >/dev/null 2>&1 && echo set || echo unset)"
    populate_prepared_nix_volume 0 0
) >"$p12_mount_out" 2>&1 || true
if ! grep -qxF 'prepare_exit=0' "$p12_mount_out" \
    && grep -qxF 'root=unset' "$p12_mount_out" \
    && grep -qF 'Error: mount failed for' "$p12_mount_out" \
    && ! grep -qF completed "$p12_mount_out" \
    && ! grep -qF MUST-NOT-TAR "$p12_mount_out"; then
    test_pass "prepare_nix_volume: a failing mount is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store"
else
    test_fail "prepare_nix_volume: a failing mount is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store (output: $(cat "$p12_mount_out"))"
fi

# (b) A failing mkfs.btrfs (the fs_type the grep stub above selects). mount
# and truncate stay happy-path no-ops so only the mkfs failure is under
# test.
p12_raw_mkfs="$p12_fixture/dx-nix-raw-mkfs"
mkdir -p "$p12_raw_mkfs"
p12_mkfs_out="$p12_fixture/mkfs-fail.out"
(
    export DX_NIX_RAW_PATH="$p12_raw_mkfs"
    export DX_BOOTSTRAP_SCRATCH_DIR="$p12_raw_mkfs/scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { return 1; }
    blkid() { return 1; }
    umount() { :; }
    tar() { echo MUST-NOT-TAR; return 1; }
    truncate() { : > "${3:?}"; }
    mkfs.btrfs() { echo 'mkfs.btrfs: failed' >&2; return 1; }
    mkfs.ext4() { echo 'mkfs.ext4: failed' >&2; return 1; }
    mount() { :; }
    prepare_nix_volume
    echo "prepare_exit=$?"
    echo "root=$(dx_read_nix_volume_record >/dev/null 2>&1 && echo set || echo unset)"
    populate_prepared_nix_volume 0 0
) >"$p12_mkfs_out" 2>&1 || true
if ! grep -qxF 'prepare_exit=0' "$p12_mkfs_out" \
    && grep -qxF 'root=unset' "$p12_mkfs_out" \
    && grep -qF 'Error: mkfs.btrfs failed for' "$p12_mkfs_out" \
    && ! grep -qF completed "$p12_mkfs_out" \
    && ! grep -qF MUST-NOT-TAR "$p12_mkfs_out"; then
    test_pass "prepare_nix_volume: a failing mkfs.btrfs is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store"
else
    test_fail "prepare_nix_volume: a failing mkfs.btrfs is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store (output: $(cat "$p12_mkfs_out"))"
fi

# (c) A failing truncate: the sparse image file is never created, but
# nothing downstream noticed before this fix -- mkfs ran against a
# non-existent device path and "succeeded" (stubbed), then mount
# "succeeded" (stubbed) too.
p12_raw_truncate="$p12_fixture/dx-nix-raw-truncate"
mkdir -p "$p12_raw_truncate"
p12_truncate_out="$p12_fixture/truncate-fail.out"
(
    export DX_NIX_RAW_PATH="$p12_raw_truncate"
    export DX_BOOTSTRAP_SCRATCH_DIR="$p12_raw_truncate/scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { return 1; }
    blkid() { return 1; }
    umount() { :; }
    tar() { echo MUST-NOT-TAR; return 1; }
    truncate() { echo 'truncate: failed' >&2; return 1; }
    mkfs.btrfs() { :; }
    mkfs.ext4() { :; }
    mount() { :; }
    prepare_nix_volume
    echo "prepare_exit=$?"
    echo "root=$(dx_read_nix_volume_record >/dev/null 2>&1 && echo set || echo unset)"
    populate_prepared_nix_volume 0 0
) >"$p12_truncate_out" 2>&1 || true
if ! grep -qxF 'prepare_exit=0' "$p12_truncate_out" \
    && grep -qxF 'root=unset' "$p12_truncate_out" \
    && grep -qF 'Error: truncate failed for' "$p12_truncate_out" \
    && ! grep -qF completed "$p12_truncate_out" \
    && ! grep -qF MUST-NOT-TAR "$p12_truncate_out"; then
    test_pass "prepare_nix_volume: a failing truncate is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store"
else
    test_fail "prepare_nix_volume: a failing truncate is checked -- fails closed, leaves DX_NIX_VOLUME_ROOT unset, never reports completed, and a following populate never seeds the store (output: $(cat "$p12_truncate_out"))"
fi

# Refactor pin: dx_nix_mount is now the sole caller of `mount` from
# prepare_nix_volume_impl. Assert it forwards the exact device, filesystem,
# options and mountpoint argv mount(8) itself expects -- not just that *a*
# mount call happened -- in the MUST-NOT sentinel style at test_section3:1416
# ("$*" recorded to a log, then compared for equality).
p12_mount_argv_log="$p12_fixture/mount-argv.log"
(
    mount() { printf '%s\n' "$*" >> "$p12_mount_argv_log"; }
    dx_nix_mount /dev/fake-dev btrfs 'compress=zstd:3,noatime' /mnt/tmp-nix
)
if [ "$(cat "$p12_mount_argv_log" 2>/dev/null)" = "-t btrfs -o compress=zstd:3,noatime /dev/fake-dev /mnt/tmp-nix" ]; then
    test_pass "dx_nix_mount forwards the exact mount argv (device, filesystem, options, mountpoint)"
else
    test_fail "dx_nix_mount forwards the exact mount argv (device, filesystem, options, mountpoint) (log: $(cat "$p12_mount_argv_log" 2>/dev/null))"
fi

# Refactor pin: dx_nix_format_device dispatches on its fs_type argument, not
# on any ambient state, and calls exactly one of mkfs.btrfs/mkfs.ext4 -- the
# other is a MUST-NOT sentinel. Two cases (btrfs and ext4) pin both the
# argv of the tool that runs and that the other tool never runs at all.
p12_format_btrfs_log="$p12_fixture/format-btrfs.log"
(
    mkfs.btrfs() { printf '%s\n' "$*" >> "$p12_format_btrfs_log"; }
    mkfs.ext4() { echo MUST-NOT-MKFS-EXT4 >> "$p12_format_btrfs_log"; }
    dx_nix_format_device /dev/fake-dev btrfs
)
if [ "$(cat "$p12_format_btrfs_log" 2>/dev/null)" = "-f -L dx-nix -m single -d single /dev/fake-dev" ]; then
    test_pass "dx_nix_format_device btrfs: forwards the exact mkfs.btrfs argv, never calls mkfs.ext4"
else
    test_fail "dx_nix_format_device btrfs: forwards the exact mkfs.btrfs argv, never calls mkfs.ext4 (log: $(cat "$p12_format_btrfs_log" 2>/dev/null))"
fi

p12_format_ext4_log="$p12_fixture/format-ext4.log"
(
    mkfs.btrfs() { echo MUST-NOT-MKFS-BTRFS >> "$p12_format_ext4_log"; }
    mkfs.ext4() { printf '%s\n' "$*" >> "$p12_format_ext4_log"; }
    dx_nix_format_device /dev/fake-dev ext4
)
if [ "$(cat "$p12_format_ext4_log" 2>/dev/null)" = "-F -L dx-nix /dev/fake-dev" ]; then
    test_pass "dx_nix_format_device ext4: forwards the exact mkfs.ext4 argv, never calls mkfs.btrfs"
else
    test_fail "dx_nix_format_device ext4: forwards the exact mkfs.ext4 argv, never calls mkfs.btrfs (log: $(cat "$p12_format_ext4_log" 2>/dev/null))"
fi

rm -rf "$p12_fixture"

# P13 (docs/evidence/20260930/agent-design-notes.md, "Bootstrap storage
# coverage cases"): six kcov gaps in base-and-storage.sh, closed the same
# way P12 above closes its own: every case below runs its whole fixture as
# the left side of `(...) || true` (or, for (e), an `if` condition around
# id -u), so a stub returning non-zero -- or a REAL command failing for
# real, as (e)'s permission-denied fstab append does on this unprivileged
# Mac -- never aborts the case's own subshell early; execution always
# reaches the case's trailing `echo "exit=$?"` (or, for (e), falls through
# to the function's own final return). Verified empirically on this Mac's
# Bash 3.2: when a compound command or subshell is the left side of
# `|| true`, or the condition of `if`, errexit is suspended for its ENTIRE
# nested execution, not merely the one command being tested.
p13_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p13-storage.XXXXXX")"

# (a) A fully successful sparse-image prepare, through the real
# prepare_nix_volume phase wrapper: btrfs supported, /nix not already
# mounted, no backing block device, no pre-existing sparse image file.
# mkdir is a plain no-op (/mnt is read-only on this dev Mac; the real
# mkdir -p /mnt/tmp-nix needs root); truncate/mkfs.btrfs/mount are
# recording stubs, pinning their exact argv, not mere no-ops -- mkfs.ext4
# is a MUST-NOT sentinel. Closes base-and-storage.sh:974-980.
p13_raw_a="$p13_fixture/dx-nix-raw-a"
mkdir -p "$p13_raw_a" "$p13_raw_a/scratch"
p13_a_out="$p13_fixture/case-a.out"
p13_a_truncate_log="$p13_fixture/case-a-truncate.log"
p13_a_mkfs_btrfs_log="$p13_fixture/case-a-mkfs-btrfs.log"
p13_a_mkfs_ext4_log="$p13_fixture/case-a-mkfs-ext4.log"
p13_a_mount_log="$p13_fixture/case-a-mount.log"
p13_a_identity_log="$p13_fixture/case-a-identity.log"
(
    export DX_NIX_RAW_PATH="$p13_raw_a"
    export DX_NIX_DISK_SIZE=8G
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_raw_a/scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { return 1; }
    blkid() { return 1; }
    mkdir() { :; }
    truncate() { printf '%s\n' "$*" >> "$p13_a_truncate_log"; : > "${3:?}"; }
    mkfs.btrfs() { printf '%s\n' "$*" >> "$p13_a_mkfs_btrfs_log"; }
    mkfs.ext4() { printf '%s\n' "$*" >> "$p13_a_mkfs_ext4_log"; }
    mount() { printf '%s\n' "$*" >> "$p13_a_mount_log"; }
    record_durable_nix_identity() { printf '%s\n' "$*" >> "$p13_a_identity_log"; }
    prepare_nix_volume
    echo "prepare_exit=$?"
    record="$(dx_read_nix_volume_record)"
    dx_parse_nix_volume_record "$record"
    printf 'MODE=%s\n' "${nix_volume_mode:-unset}"
    printf 'ROOT=%s\n' "${nix_volume_root:-unset}"
    printf 'DEVICE=%s\n' "${nix_volume_device:-unset}"
    printf 'FS_TYPE=%s\n' "${nix_volume_fs:-unset}"
    printf 'MOUNT_OPTS=%s\n' "${nix_volume_opts:-unset}"
) >"$p13_a_out" 2>&1 || true
p13_a_dev="$p13_raw_a/nix-store.btrfs"
if grep -qF 'Bootstrap phase: Nix volume prepare/mount completed in' "$p13_a_out" \
    && grep -qxF 'prepare_exit=0' "$p13_a_out" \
    && grep -qxF 'MODE=prepared' "$p13_a_out" \
    && grep -qxF 'ROOT=/mnt/tmp-nix' "$p13_a_out" \
    && grep -qxF "DEVICE=$p13_a_dev" "$p13_a_out" \
    && grep -qxF 'FS_TYPE=btrfs' "$p13_a_out" \
    && grep -qxF 'MOUNT_OPTS=compress=zstd:3,noatime,space_cache=v2,discard=async' "$p13_a_out"; then
    test_pass "prepare_nix_volume: a successful sparse-image prepare reports completion and publishes a mode=prepared Nix-volume record"
else
    test_fail "prepare_nix_volume: a successful sparse-image prepare reports completion and publishes a mode=prepared Nix-volume record (output: $(cat "$p13_a_out"))"
fi
if [ "$(cat "$p13_a_truncate_log" 2>/dev/null)" = "-s 8G $p13_a_dev" ]; then
    test_pass "prepare_nix_volume: the sparse image is truncated with the exact size and path argv"
else
    test_fail "prepare_nix_volume: the sparse image is truncated with the exact size and path argv (log: $(cat "$p13_a_truncate_log" 2>/dev/null))"
fi
if [ "$(cat "$p13_a_mkfs_btrfs_log" 2>/dev/null)" = "-f -L dx-nix -m single -d single $p13_a_dev" ] \
    && [ ! -s "$p13_a_mkfs_ext4_log" ]; then
    test_pass "prepare_nix_volume: the sparse image is formatted with the exact mkfs.btrfs argv, never mkfs.ext4"
else
    test_fail "prepare_nix_volume: the sparse image is formatted with the exact mkfs.btrfs argv, never mkfs.ext4 (btrfs log: $(cat "$p13_a_mkfs_btrfs_log" 2>/dev/null); ext4 log: $(cat "$p13_a_mkfs_ext4_log" 2>/dev/null))"
fi
if [ "$(cat "$p13_a_mount_log" 2>/dev/null)" = "-t btrfs -o compress=zstd:3,noatime,space_cache=v2,discard=async $p13_a_dev /mnt/tmp-nix" ]; then
    test_pass "prepare_nix_volume: the sparse image is mounted with the exact device, filesystem, options, and mountpoint argv"
else
    test_fail "prepare_nix_volume: the sparse image is mounted with the exact device, filesystem, options, and mountpoint argv (log: $(cat "$p13_a_mount_log" 2>/dev/null))"
fi
if [ "$(cat "$p13_a_identity_log" 2>/dev/null)" = "/mnt/tmp-nix" ]; then
    test_pass "prepare_nix_volume: the durable identity is recorded against the final mount point"
else
    test_fail "prepare_nix_volume: the durable identity is recorded against the final mount point (log: $(cat "$p13_a_identity_log" 2>/dev/null))"
fi

# (b) btrfs unsupported (the grep probe fails): falls back to ext4 with the
# matching mount options, formats with mkfs.ext4 -- MUST-NOT mkfs.btrfs.
# Calls prepare_nix_volume_impl directly (no phase-timing text is under
# test here). Closes base-and-storage.sh:914-916.
p13_raw_b="$p13_fixture/dx-nix-raw-b"
mkdir -p "$p13_raw_b" "$p13_raw_b/scratch"
p13_b_out="$p13_fixture/case-b.out"
p13_b_mkfs_btrfs_log="$p13_fixture/case-b-mkfs-btrfs.log"
p13_b_mkfs_ext4_log="$p13_fixture/case-b-mkfs-ext4.log"
(
    export DX_NIX_RAW_PATH="$p13_raw_b"
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_raw_b/scratch"
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 1; fi; command grep "$@"; }
    findmnt() { return 1; }
    blkid() { return 1; }
    mkdir() { :; }
    truncate() { : > "${3:?}"; }
    mount() { :; }
    mkfs.btrfs() { printf '%s\n' "$*" >> "$p13_b_mkfs_btrfs_log"; }
    mkfs.ext4() { printf '%s\n' "$*" >> "$p13_b_mkfs_ext4_log"; }
    prepare_nix_volume_impl
    echo "impl_exit=$?"
    record="$(dx_read_nix_volume_record)"
    dx_parse_nix_volume_record "$record"
    printf 'FS_TYPE=%s\n' "${nix_volume_fs:-unset}"
    printf 'MOUNT_OPTS=%s\n' "${nix_volume_opts:-unset}"
) >"$p13_b_out" 2>&1 || true
p13_b_dev="$p13_raw_b/nix-store.ext4"
if grep -qF 'Warning: Kernel does not support btrfs. Falling back to ext4.' "$p13_b_out" \
    && grep -qxF 'impl_exit=0' "$p13_b_out" \
    && grep -qxF 'FS_TYPE=ext4' "$p13_b_out" \
    && grep -qxF 'MOUNT_OPTS=noatime,errors=remount-ro' "$p13_b_out"; then
    test_pass "prepare_nix_volume_impl: an unsupported kernel (no btrfs) falls back to ext4 with the matching mount options"
else
    test_fail "prepare_nix_volume_impl: an unsupported kernel (no btrfs) falls back to ext4 with the matching mount options (output: $(cat "$p13_b_out"))"
fi
if [ "$(cat "$p13_b_mkfs_ext4_log" 2>/dev/null)" = "-F -L dx-nix $p13_b_dev" ] \
    && [ ! -s "$p13_b_mkfs_btrfs_log" ]; then
    test_pass "prepare_nix_volume_impl: the ext4 fallback formats with the exact mkfs.ext4 argv, never mkfs.btrfs"
else
    test_fail "prepare_nix_volume_impl: the ext4 fallback formats with the exact mkfs.ext4 argv, never mkfs.btrfs (ext4 log: $(cat "$p13_b_mkfs_ext4_log" 2>/dev/null); btrfs log: $(cat "$p13_b_mkfs_btrfs_log" 2>/dev/null))"
fi

# (c) The block-device branch (is_block_device true): findmnt is dispatched
# on its own argv so the "already mounted" probe still misses while the
# "backing device" probe reports the fake device. (c1) blkid misses -> the
# device is formatted. (c2) umount fails -> refuses with the CAP_SYS_ADMIN
# recovery text, before ever touching mkfs. Closes base-and-storage.sh:948-957.
p13_raw_c="$p13_fixture/dx-nix-raw-c"
mkdir -p "$p13_raw_c" "$p13_raw_c/scratch-c1"

p13_c1_out="$p13_fixture/case-c1.out"
p13_c1_mkfs_btrfs_log="$p13_fixture/case-c1-mkfs-btrfs.log"
p13_c1_mkfs_ext4_log="$p13_fixture/case-c1-mkfs-ext4.log"
(
    export DX_NIX_RAW_PATH="$p13_raw_c"
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_raw_c/scratch-c1"
    is_block_device() { [ "$1" = /dev/fake-block ]; }
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { case "$*" in "-n -o SOURCE $p13_raw_c") printf '%s\n' /dev/fake-block ;; *) return 1 ;; esac; }
    blkid() { return 1; }
    umount() { :; }
    mkdir() { :; }
    mount() { :; }
    mkfs.btrfs() { printf '%s\n' "$*" >> "$p13_c1_mkfs_btrfs_log"; }
    mkfs.ext4() { printf '%s\n' "$*" >> "$p13_c1_mkfs_ext4_log"; }
    prepare_nix_volume_impl
    echo "impl_exit=$?"
) >"$p13_c1_out" 2>&1 || true
if grep -qF "Detected block device backing $p13_raw_c: /dev/fake-block" "$p13_c1_out" \
    && grep -qF 'Formatting /dev/fake-block with btrfs...' "$p13_c1_out" \
    && grep -qxF 'impl_exit=0' "$p13_c1_out" \
    && [ "$(cat "$p13_c1_mkfs_btrfs_log" 2>/dev/null)" = "-f -L dx-nix -m single -d single /dev/fake-block" ] \
    && [ ! -s "$p13_c1_mkfs_ext4_log" ]; then
    test_pass "prepare_nix_volume_impl: a block-device backing store with no existing dx-nix label is detected and formatted with the exact mkfs.btrfs argv"
else
    test_fail "prepare_nix_volume_impl: a block-device backing store with no existing dx-nix label is detected and formatted with the exact mkfs.btrfs argv (output: $(cat "$p13_c1_out"); mkfs.btrfs log: $(cat "$p13_c1_mkfs_btrfs_log" 2>/dev/null))"
fi

p13_c2_out="$p13_fixture/case-c2.out"
p13_c2_mkfs_log="$p13_fixture/case-c2-mkfs.log"
(
    export DX_NIX_RAW_PATH="$p13_raw_c"
    is_block_device() { [ "$1" = /dev/fake-block ]; }
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { case "$*" in "-n -o SOURCE $p13_raw_c") printf '%s\n' /dev/fake-block ;; *) return 1 ;; esac; }
    blkid() { return 1; }
    umount() { return 1; }
    mkfs.btrfs() { echo MUST-NOT-MKFS-BTRFS >> "$p13_c2_mkfs_log"; }
    mkfs.ext4() { echo MUST-NOT-MKFS-EXT4 >> "$p13_c2_mkfs_log"; }
    prepare_nix_volume_impl
    echo "impl_exit=$?"
) >"$p13_c2_out" 2>&1 || true
if grep -qF "Error: failed to umount $p13_raw_c. The container is missing CAP_SYS_ADMIN; re-create it with ./bin/dx-destroy && ./bin/dx (dx-create-container adds the capability)." "$p13_c2_out" \
    && grep -qxF 'impl_exit=1' "$p13_c2_out" \
    && [ ! -s "$p13_c2_mkfs_log" ]; then
    test_pass "prepare_nix_volume_impl: a failing umount on a block-device backing store refuses before any mkfs, naming the CAP_SYS_ADMIN recovery path"
else
    test_fail "prepare_nix_volume_impl: a failing umount on a block-device backing store refuses before any mkfs, naming the CAP_SYS_ADMIN recovery path (output: $(cat "$p13_c2_out"); mkfs log: $(cat "$p13_c2_mkfs_log" 2>/dev/null))"
fi

# (d) populate_prepared_nix_volume's own fresh-vs-reuse dispatch (and the
# fatal collision path), driven directly rather than through prepare_*
# first. DX_NIX_VOLUME_FS_TYPE=dxe-cov-probe (never present in a real
# /etc/fstab) plus a grep shadow reporting the fstab line already present
# keeps (d1)/(d2) -- which both fall through to the unconditional
# umount/mount/fstab tail -- from ever touching a real mount or /etc/fstab;
# (d3) returns before reaching that tail at all, so it needs neither.
# Closes base-and-storage.sh:656-662.
p13_d1_root="$p13_fixture/dx-nix-volume-d1"
mkdir -p "$p13_d1_root"
p13_d1_log="$p13_fixture/case-d1.log"
(
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_d1_root/scratch"
    p13_fs_type=dxe-cov-probe
    dx_write_nix_volume_record prepared "$p13_d1_root" /dev/dxe-cov-fake "$p13_fs_type" dxe-cov-opts
    grep() { if [ "$*" = "-q /nix $p13_fs_type /etc/fstab" ]; then return 0; fi; command grep "$@"; }
    umount() { :; }
    mount() { :; }
    nix_image_store_identity() { printf '%s\n' IDENTITY >> "$p13_d1_log"; printf '%s\n' fakeidentity; }
    nix_seed_volume() { printf 'SEED %s\n' "$*" >> "$p13_d1_log"; }
    nix_install_image_essentials_root() { printf 'ROOTS %s\n' "$*" >> "$p13_d1_log"; }
    nix_image_store_import_required() { printf 'MUST-NOT-IMPORT_REQUIRED %s\n' "$*" >> "$p13_d1_log"; return 0; }
    nix_verify_no_bootstrap_path_collision() { printf 'MUST-NOT-COLLISION %s\n' "$*" >> "$p13_d1_log"; return 0; }
    nix_store_import_registered() { printf 'MUST-NOT-REGISTERED %s\n' "$*" >> "$p13_d1_log"; }
    populate_prepared_nix_volume 0 0
    echo "exit=$?"
) >"$p13_fixture/case-d1.out" 2>&1 || true
p13_d1_expected="IDENTITY
SEED /nix $p13_d1_root 0 0
ROOTS $p13_d1_root 0 0 fakeidentity"
if [ "$(cat "$p13_d1_log" 2>/dev/null)" = "$p13_d1_expected" ] \
    && grep -qxF 'exit=0' "$p13_fixture/case-d1.out"; then
    test_pass "populate_prepared_nix_volume: a fresh root (no store/) seeds the volume and publishes essentials roots, in order, never the import trio"
else
    test_fail "populate_prepared_nix_volume: a fresh root (no store/) seeds the volume and publishes essentials roots, in order, never the import trio (log: $(cat "$p13_d1_log" 2>/dev/null); output: $(cat "$p13_fixture/case-d1.out"))"
fi

p13_d2_root="$p13_fixture/dx-nix-volume-d2"
mkdir -p "$p13_d2_root/store"
p13_d2_log="$p13_fixture/case-d2.log"
(
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_d2_root/scratch"
    p13_fs_type=dxe-cov-probe
    dx_write_nix_volume_record prepared "$p13_d2_root" /dev/dxe-cov-fake "$p13_fs_type" dxe-cov-opts
    grep() { if [ "$*" = "-q /nix $p13_fs_type /etc/fstab" ]; then return 0; fi; command grep "$@"; }
    umount() { :; }
    mount() { :; }
    nix_image_store_identity() { printf 'MUST-NOT-IDENTITY\n' >> "$p13_d2_log"; printf '%s\n' fakeidentity; }
    nix_seed_volume() { printf 'MUST-NOT-SEED %s\n' "$*" >> "$p13_d2_log"; }
    nix_install_image_essentials_root() { printf 'MUST-NOT-ROOTS %s\n' "$*" >> "$p13_d2_log"; }
    nix_image_store_import_required() { printf 'IMPORT_REQUIRED %s\n' "$*" >> "$p13_d2_log"; printf '%s\n' fakeidentity; return 0; }
    nix_verify_no_bootstrap_path_collision() { printf 'COLLISION %s\n' "$*" >> "$p13_d2_log"; return 0; }
    nix_store_import_registered() { printf 'REGISTERED %s\n' "$*" >> "$p13_d2_log"; }
    populate_prepared_nix_volume 0 0
    echo "exit=$?"
) >"$p13_fixture/case-d2.out" 2>&1 || true
p13_d2_expected="IMPORT_REQUIRED /nix $p13_d2_root
COLLISION /nix $p13_d2_root
REGISTERED $p13_d2_root 0 0 fakeidentity"
if [ "$(cat "$p13_d2_log" 2>/dev/null)" = "$p13_d2_expected" ] \
    && grep -qxF 'exit=0' "$p13_fixture/case-d2.out"; then
    test_pass "populate_prepared_nix_volume: a reused root (store/ present, no collision) imports the registered closure, in order, never the seed trio"
else
    test_fail "populate_prepared_nix_volume: a reused root (store/ present, no collision) imports the registered closure, in order, never the seed trio (log: $(cat "$p13_d2_log" 2>/dev/null); output: $(cat "$p13_fixture/case-d2.out"))"
fi

p13_d3_root="$p13_fixture/dx-nix-volume-d3"
mkdir -p "$p13_d3_root/store"
p13_d3_log="$p13_fixture/case-d3.log"
(
    export DX_BOOTSTRAP_SCRATCH_DIR="$p13_d3_root/scratch"
    dx_write_nix_volume_record prepared "$p13_d3_root" /dev/dxe-cov-fake dxe-cov-probe dxe-cov-opts
    nix_image_store_import_required() { printf 'IMPORT_REQUIRED %s\n' "$*" >> "$p13_d3_log"; return 0; }
    nix_verify_no_bootstrap_path_collision() { printf 'COLLISION %s\n' "$*" >> "$p13_d3_log"; return 1; }
    nix_store_import_registered() { printf 'MUST-NOT-REGISTERED %s\n' "$*" >> "$p13_d3_log"; }
    umount() { printf 'MUST-NOT-UMOUNT\n' >> "$p13_d3_log"; }
    mount() { printf 'MUST-NOT-MOUNT\n' >> "$p13_d3_log"; }
    populate_prepared_nix_volume 0 0
    echo "exit=$?"
) >"$p13_fixture/case-d3.out" 2>&1 || true
p13_d3_expected="IMPORT_REQUIRED /nix $p13_d3_root
COLLISION /nix $p13_d3_root"
if [ "$(cat "$p13_d3_log" 2>/dev/null)" = "$p13_d3_expected" ] \
    && grep -qxF 'exit=1' "$p13_fixture/case-d3.out"; then
    test_pass "populate_prepared_nix_volume: a bootstrap-path collision refuses immediately, never registering the import, never touching umount/mount"
else
    test_fail "populate_prepared_nix_volume: a bootstrap-path collision refuses immediately, never registering the import, never touching umount/mount (log: $(cat "$p13_d3_log" 2>/dev/null); output: $(cat "$p13_fixture/case-d3.out"))"
fi

# (e) the /etc/fstab tail, exercised WITHOUT the grep shadow above so the
# REAL grep against the REAL /etc/fstab runs: DX_NIX_VOLUME_FS_TYPE=
# dxe-cov-probe never appears in a real fstab, so the presence check always
# misses and the append actually executes. Non-root (this dev Mac): the
# append itself fails closed (permission denied) and /etc/fstab is
# provably unchanged. Root (the kcov Linux image, which runs this whole
# suite as root): the append succeeds for real; each sub-case restores a
# snapshot afterward so the container's /etc/fstab is left exactly as this
# test found it. Better long-term: give the fstab path a seam (Fable B11)
# so no test touches the real file -- a separate follow-up, not done here.
# Closes base-and-storage.sh:675-679.
p13_e_root="$p13_fixture/dx-nix-volume-e"
mkdir -p "$p13_e_root/store"
p13_fstab_snapshot="$p13_fixture/fstab.snapshot"
cp /etc/fstab "$p13_fstab_snapshot" 2>/dev/null || : > "$p13_fstab_snapshot"

if [ "$(id -u)" -eq 0 ]; then
    p13_e1_out="$p13_fixture/case-e1.out"
    (
        export DX_BOOTSTRAP_SCRATCH_DIR="$p13_e_root/scratch-e1"
        dx_write_nix_volume_record prepared "$p13_e_root" /dev/dxe-cov-fake dxe-cov-probe dxe-cov-opts
        nix_image_store_import_required() { return 1; }
        nix_install_image_essentials_root() { :; }
        umount() { :; }
        mount() { :; }
        blkid() { [ "$*" = '-L dx-nix' ] && return 0 || command blkid "$@"; }
        populate_prepared_nix_volume 0 0
        echo "exit=$?"
    ) >"$p13_e1_out" 2>&1 || true
    if grep -qxF 'exit=0' "$p13_e1_out" \
        && grep -qF 'Adding /nix to /etc/fstab...' "$p13_e1_out" \
        && grep -qxF 'LABEL=dx-nix /nix dxe-cov-probe dxe-cov-opts 0 0' /etc/fstab; then
        test_pass "populate_prepared_nix_volume (root): a matching blkid label appends the LABEL= fstab line"
    else
        test_fail "populate_prepared_nix_volume (root): a matching blkid label appends the LABEL= fstab line (output: $(cat "$p13_e1_out"); fstab tail: $(tail -n 3 /etc/fstab 2>/dev/null))"
    fi
    cp "$p13_fstab_snapshot" /etc/fstab

    p13_e2_out="$p13_fixture/case-e2.out"
    (
        export DX_BOOTSTRAP_SCRATCH_DIR="$p13_e_root/scratch-e2"
        dx_write_nix_volume_record prepared "$p13_e_root" /dev/dxe-cov-fake dxe-cov-probe dxe-cov-opts
        nix_image_store_import_required() { return 1; }
        nix_install_image_essentials_root() { :; }
        umount() { :; }
        mount() { :; }
        blkid() { return 1; }
        populate_prepared_nix_volume 0 0
        echo "exit=$?"
    ) >"$p13_e2_out" 2>&1 || true
    if grep -qxF 'exit=0' "$p13_e2_out" \
        && grep -qF 'Adding /nix to /etc/fstab...' "$p13_e2_out" \
        && grep -qxF '/dev/dxe-cov-fake /nix dxe-cov-probe dxe-cov-opts 0 0' /etc/fstab; then
        test_pass "populate_prepared_nix_volume (root): a missing blkid label appends the raw device fstab line"
    else
        test_fail "populate_prepared_nix_volume (root): a missing blkid label appends the raw device fstab line (output: $(cat "$p13_e2_out"); fstab tail: $(tail -n 3 /etc/fstab 2>/dev/null))"
    fi
    cp "$p13_fstab_snapshot" /etc/fstab
else
    p13_e_out="$p13_fixture/case-e-nonroot.out"
    (
        export DX_BOOTSTRAP_SCRATCH_DIR="$p13_e_root/scratch-e"
        dx_write_nix_volume_record prepared "$p13_e_root" /dev/dxe-cov-fake dxe-cov-probe dxe-cov-opts
        nix_image_store_import_required() { return 1; }
        nix_install_image_essentials_root() { :; }
        umount() { :; }
        mount() { :; }
        blkid() { return 1; }
        populate_prepared_nix_volume 0 0
        echo "exit=$?"
    ) >"$p13_e_out" 2>&1 || true
    p13_e_fstab_unchanged=false
    if [ -e /etc/fstab ]; then
        if cmp -s "$p13_fstab_snapshot" /etc/fstab; then p13_e_fstab_unchanged=true; fi
    elif [ ! -s "$p13_fstab_snapshot" ]; then
        p13_e_fstab_unchanged=true
    fi
    if grep -qF 'Adding /nix to /etc/fstab...' "$p13_e_out" \
        && grep -qiF 'permission denied' "$p13_e_out" \
        && [ "$p13_e_fstab_unchanged" = true ]; then
        test_pass "populate_prepared_nix_volume (non-root): the fstab append fails closed (permission denied) and /etc/fstab is left unchanged"
    else
        test_fail "populate_prepared_nix_volume (non-root): the fstab append fails closed (permission denied) and /etc/fstab is left unchanged (output: $(cat "$p13_e_out"))"
    fi
fi

# (f) nix_image_store_identity's own enumeration-failure branch: the
# underlying registered-paths enumerator fails outright. Captured with the
# same `! nix_function_call` idiom already used above (a `!`-negated call
# inside a `{ ... }` group is exempt from errexit, unlike a bare failing
# call). Closes base-and-storage.sh:347-349.
p13_f_output="$({
    nix_image_registered_paths() { return 1; }
    ! nix_image_store_identity
} 2>&1)"
if printf '%s\n' "$p13_f_output" | grep -qF 'Error: could not enumerate registered image Nix paths.'; then
    test_pass "nix_image_store_identity reports failure when it cannot enumerate registered image Nix paths"
else
    test_fail "nix_image_store_identity reports failure when it cannot enumerate registered image Nix paths (output: $p13_f_output)"
fi

rm -rf "$p13_fixture"

# P14 (refactor-v2-final.md Contract 1, Fable B6 item 4): "a verified clean
# skip performs no marker write" -- the Phase 1 gate -- made mode-aware.
# DX_NIX_PENDING_IMAGE_STORE_IDENTITY is gone; the publication decision now
# lives in dx_write_pending_image_identity's own pending record
# (.dx-image-store-identity.pending). This proves both modes through the
# real functions, not stubs of them: apple-image's verified-match skip must
# leave the existing marker byte-for-byte untouched and never create a
# pending record, and direct-volume mode -- whose own populate function
# never calls dx_write_pending_image_identity at all -- must never create
# .dx-image-store-identity even after publish_nix_image_store_identity (the
# later, mode-agnostic phase) runs unconditionally against it.
p14_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p14-clean-skip.XXXXXX")"

# (a) apple-image mode: an already-registered, content-verified volume.
p14_apple_root="$p14_fixture/apple-volume"
mkdir -p "$p14_apple_root/store"
p14_apple_identity="1010101010101010101010101010101010101010101010101010101010101010"
printf '%s\n' "$p14_apple_identity" > "$p14_apple_root/.dx-image-store-identity"
p14_apple_marker_before="$(cat "$p14_apple_root/.dx-image-store-identity")"
p14_apple_out="$p14_fixture/apple.out"
(
    export DX_BOOTSTRAP_SCRATCH_DIR="$p14_apple_root/scratch"
    p14_fs_type=dxe-cov-probe
    dx_write_nix_volume_record prepared "$p14_apple_root" /dev/dxe-cov-fake "$p14_fs_type" dxe-cov-opts
    grep() { if [ "$*" = "-q /nix $p14_fs_type /etc/fstab" ]; then return 0; fi; command grep "$@"; }
    umount() { :; }
    mount() { :; }
    nix_image_store_identity() { printf '%s\n' "$p14_apple_identity"; }
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/p14-essentials; }
    run_as_dx() { return 0; }
    nix_install_image_essentials_root() { :; }
    populate_prepared_nix_volume 0 0
    echo "populate_exit=$?"
    publish_nix_image_store_identity "$p14_apple_root"
    echo "publish_exit=$?"
) >"$p14_apple_out" 2>&1 || true
if grep -qxF 'populate_exit=0' "$p14_apple_out" \
    && grep -qxF 'publish_exit=0' "$p14_apple_out" \
    && [ ! -e "$p14_apple_root/.dx-image-store-identity.pending" ] \
    && [ "$(cat "$p14_apple_root/.dx-image-store-identity" 2>/dev/null)" = "$p14_apple_marker_before" ]; then
    test_pass "P14 (Contract 1 gate): apple-image verified clean skip writes no pending record and leaves the identity marker byte-for-byte untouched"
else
    test_fail "P14 (Contract 1 gate): apple-image verified clean skip writes no pending record and leaves the identity marker byte-for-byte untouched (out: $(cat "$p14_apple_out"); pending: $([ -e "$p14_apple_root/.dx-image-store-identity.pending" ] && echo present || echo absent))"
fi

# (b) direct-volume mode: an already-registered, content-verified volume,
# reached through populate_prepared_nix_volume_in_place directly (P9's own
# style). publish_nix_image_store_identity is still called afterward,
# exactly as bootstrap_phases calls it unconditionally regardless of mode.
p14_direct_root="$p14_fixture/direct-volume"
mkdir -p "$p14_direct_root/store"
printf 'sha256:2020202020202020202020202020202020202020202020202020202020202020\n' > "$p14_direct_root/.dx-image-identity-v1"
p14_direct_out="$p14_fixture/direct.out"
(
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/p14-direct-essentials; }
    run_as_dx() { return 0; }
    nix_install_image_essentials_root() { :; }
    DX_IMAGE_IDENTITY=sha256:2020202020202020202020202020202020202020202020202020202020202020
    populate_prepared_nix_volume_in_place "$p14_direct_root" 0 0
    echo "populate_exit=$?"
    publish_nix_image_store_identity "$p14_direct_root"
    echo "publish_exit=$?"
) >"$p14_direct_out" 2>&1 || true
if grep -qxF 'populate_exit=0' "$p14_direct_out" \
    && grep -qxF 'publish_exit=0' "$p14_direct_out" \
    && [ ! -e "$p14_direct_root/.dx-image-store-identity.pending" ] \
    && [ ! -e "$p14_direct_root/.dx-image-store-identity" ]; then
    test_pass "P14 (Contract 1 gate, Fable B6 item 4, mode-aware): direct-volume mode never writes .dx-image-store-identity, even after publish_nix_image_store_identity runs unconditionally"
else
    test_fail "P14 (Contract 1 gate, Fable B6 item 4, mode-aware): direct-volume mode never writes .dx-image-store-identity, even after publish_nix_image_store_identity runs unconditionally (out: $(cat "$p14_direct_out"))"
fi

rm -rf "$p14_fixture"

# P15 (refactor-v2-final.md Contract 5, Fable B6 item 5): record_durable_
# nix_identity returns a bounded `identity=`/`migrate=` record on stdout
# instead of exporting DX_NIX_DURABLE_UID/DX_NIX_DURABLE_GID/
# DX_PERSIST_IDENTITY_MIGRATION_REQUIRED, create_user takes that record
# positionally and returns its own final identity in the same shape, and
# the two are bridged across the prepare/create_user phase boundary via
# dx_persist_durable_identity_record/dx_read_durable_identity_record rather
# than the removed environment variables.
p15_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p15-durable-identity.XXXXXX")"
export DX_BOOTSTRAP_SCRATCH_DIR="$p15_fixture/scratch"

# (a) A safe, already-owned Nix store: record_durable_nix_identity returns
# that uid:gid and migrate=false, and persists the same record for later
# reads -- never exporting DX_NIX_DURABLE_UID/DX_NIX_DURABLE_GID.
p15_safe_root="$p15_fixture/safe-volume"
mkdir -p "$p15_safe_root/store"
p15_safe_output="$({
    stat() { printf '4242:4242\n'; }
    DX_PERSIST_HOME="$p15_fixture/no-such-persist-home" record_durable_nix_identity "$p15_safe_root"
    echo "durable-uid-after=${DX_NIX_DURABLE_UID:-<unset>}"
} 2>/dev/null)"
p15_safe_expected="identity=4242:4242
migrate=false
durable-uid-after=<unset>"
if [ "$p15_safe_output" = "$p15_safe_expected" ] \
    && [ "$(cat "$DX_BOOTSTRAP_SCRATCH_DIR/durable-identity-record" 2>/dev/null)" = "$(printf 'identity=4242:4242\nmigrate=false')" ]; then
    test_pass "P15: record_durable_nix_identity returns identity=/migrate= on stdout, persists it for create_user, and never exports DX_NIX_DURABLE_UID"
else
    test_fail "P15: record_durable_nix_identity returns identity=/migrate= on stdout, persists it for create_user, and never exports DX_NIX_DURABLE_UID (output: $p15_safe_output; persisted: $(cat "$DX_BOOTSTRAP_SCRATCH_DIR/durable-identity-record" 2>/dev/null))"
fi
rm -rf "$DX_BOOTSTRAP_SCRATCH_DIR"

# (b) No safe identity anywhere: identity= is empty, migrate=false, and the
# persisted record faithfully carries that same empty-identity record (not
# stale state from an earlier call, and not silently skipped).
p15_none_root="$p15_fixture/none-volume"
mkdir -p "$p15_none_root"
p15_none_output="$({
    DX_PERSIST_HOME="$p15_fixture/no-such-persist-home" record_durable_nix_identity "$p15_none_root"
} 2>/dev/null)"
p15_none_expected="$(printf 'identity=\nmigrate=false')"
if [ "$p15_none_output" = "$p15_none_expected" ] \
    && [ "$(dx_read_durable_identity_record)" = "$p15_none_expected" ]; then
    test_pass "P15: record_durable_nix_identity with no safe identity returns an empty identity= and persists that same empty record"
else
    test_fail "P15: record_durable_nix_identity with no safe identity returns an empty identity= and persists that same empty record (output: $p15_none_output; read-back: $(dx_read_durable_identity_record))"
fi

# (c) The persist/read bridge round-trips exactly the record written,
# independent of record_durable_nix_identity itself (the mechanism
# bootstrap_phases relies on to carry the value from prepare_nix_volume's
# own branches to the later, separate create_user phase).
dx_persist_durable_identity_record "$(printf 'identity=777:888\nmigrate=true')"
if [ "$(dx_read_durable_identity_record)" = "$(printf 'identity=777:888\nmigrate=true')" ]; then
    test_pass "P15: dx_persist_durable_identity_record/dx_read_durable_identity_record round-trip the record across the phase boundary"
else
    test_fail "P15: dx_persist_durable_identity_record/dx_read_durable_identity_record round-trip the record across the phase boundary (read-back: $(dx_read_durable_identity_record))"
fi
rm -rf "$DX_BOOTSTRAP_SCRATCH_DIR"

# (d) create_user takes the record positionally (never DX_NIX_DURABLE_UID/
# DX_NIX_DURABLE_GID) and returns its own final identity in the same shape.
# No "dx" user exists yet, and the durable uid/gid are free, so it creates
# dx with exactly that identity.
p15_auth_root="$p15_fixture/auth"
mkdir -p "$p15_auth_root/etc"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$p15_auth_root/etc/passwd"
printf '%s\n' 'root:x:0:' > "$p15_auth_root/etc/group"
p15_useradd_log="$p15_fixture/useradd.log"
# A `case` statement defined inline inside this `$(...)` command
# substitution's own captured text breaks this host's bash 3.2 parser (see
# the longer comment on the same pattern in the P9/P11 blocks above);
# if/[[ ]] avoids it.
p15_create_user_output="$({
    id() {
        if [ "${1:-}" = -u ] && [ "${2:-}" = dx ]; then
            [ -f "$p15_fixture/dx-created" ] && printf '5151\n' || return 1
        elif [ "${1:-}" = -g ] && [ "${2:-}" = dx ]; then
            [ -f "$p15_fixture/dx-created" ] && printf '5151\n' || return 1
        else
            command id "$@"
        fi
    }
    groupadd() { :; }
    useradd() { printf '%s\n' "$*" >> "$p15_useradd_log"; : > "$p15_fixture/dx-created"; }
    usermod() { :; }
    DX_AUTH_ROOT="$p15_auth_root" create_user "$(printf 'identity=5151:5151\nmigrate=false')"
} 2>&1)"
if grep -qF -- '-u 5151 -g dx' "$p15_useradd_log" \
    && printf '%s\n' "$p15_create_user_output" | stdin_matches -F 'identity=5151:5151' \
    && printf '%s\n' "$p15_create_user_output" | stdin_matches -F 'migrate=false'; then
    test_pass "P15: create_user takes the durable-identity record positionally and returns its own final identity in the same shape"
else
    test_fail "P15: create_user takes the durable-identity record positionally and returns its own final identity in the same shape (useradd: $(cat "$p15_useradd_log" 2>/dev/null); output: $p15_create_user_output)"
fi

unset DX_BOOTSTRAP_SCRATCH_DIR
rm -rf "$p15_fixture"

# P16 (refactor-v2-final.md Contract 3, Fable B6 item 3): the mode-tagged
# Nix-volume record's bounded reader/parser, proven directly rather than
# only through prepare_nix_volume_impl's own three write sites. The plan's
# original two-mode record (already-mounted/prepared) rejects every
# direct-volume (QNAP) boot; mode=in-place is the third mode this record
# must accept -- root=/nix, no device/fs/opts -- which is the Red case this
# gate calls for.
p16_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p16-volume-record.XXXXXX")"
export DX_BOOTSTRAP_SCRATCH_DIR="$p16_fixture/scratch"

# (a) mode=in-place: accepted with just a root, rejected the moment any of
# device/fs/opts is also present (a record a writer never should have
# produced, but the reader must still refuse it rather than trust it).
if dx_write_nix_volume_record in-place /nix \
    && [ "$(dx_read_nix_volume_record)" = "$(printf 'mode=in-place\nroot=/nix\ndevice=\nfs=\nopts=')" ] \
    && (dx_parse_nix_volume_record "$(dx_read_nix_volume_record)" && [ "$nix_volume_mode" = in-place ] && [ "$nix_volume_root" = /nix ]) \
    && ! dx_parse_nix_volume_record "$(printf 'mode=in-place\nroot=/nix\ndevice=/dev/fake\nfs=\nopts=')" 2>/dev/null \
    && ! dx_parse_nix_volume_record "$(printf 'mode=in-place\nroot=\ndevice=\nfs=\nopts=')" 2>/dev/null; then
    test_pass "P16 (Contract 3 gate, Fable B6 item 3): the Nix-volume record accepts mode=in-place (root=/nix, no device/fs/opts) and rejects a record with a rejected field or no root"
else
    test_fail "P16 (Contract 3 gate, Fable B6 item 3): the Nix-volume record accepts mode=in-place (root=/nix, no device/fs/opts) and rejects a record with a rejected field or no root"
fi

# (b) mode=already-mounted: same shape rule as in-place (root only).
if dx_write_nix_volume_record already-mounted /nix \
    && dx_parse_nix_volume_record "$(dx_read_nix_volume_record)" \
    && [ "$nix_volume_mode" = already-mounted ] && [ "$nix_volume_root" = /nix ]; then
    test_pass "P16: the Nix-volume record accepts mode=already-mounted with just a root"
else
    test_fail "P16: the Nix-volume record accepts mode=already-mounted with just a root"
fi

# (c) mode=prepared: requires all four of root/device/fs/opts; a writer
# that omits one is refused outright (never persisted half-written), and a
# reader handed an incomplete record it did not itself write is refused too.
if ! dx_write_nix_volume_record prepared /mnt/tmp-nix /dev/fake btrfs 2>/dev/null \
    && ! dx_parse_nix_volume_record "$(printf 'mode=prepared\nroot=/mnt/tmp-nix\ndevice=/dev/fake\nfs=btrfs\nopts=')" 2>/dev/null \
    && dx_write_nix_volume_record prepared /mnt/tmp-nix /dev/fake btrfs noatime \
    && dx_parse_nix_volume_record "$(dx_read_nix_volume_record)" \
    && [ "$nix_volume_mode" = prepared ] && [ "$nix_volume_device" = /dev/fake ] && [ "$nix_volume_fs" = btrfs ] && [ "$nix_volume_opts" = noatime ]; then
    test_pass "P16: the Nix-volume record requires all four fields for mode=prepared, both writing and reading"
else
    test_fail "P16: the Nix-volume record requires all four fields for mode=prepared, both writing and reading"
fi

# (d) An unrecognized mode is refused outright -- never reused as a stale
# or malformed record (the contract's own "never reuse a stale record"
# guarantee).
if ! dx_write_nix_volume_record bogus-mode /nix 2>/dev/null \
    && ! dx_parse_nix_volume_record "$(printf 'mode=bogus-mode\nroot=/nix\ndevice=\nfs=\nopts=')" 2>/dev/null; then
    test_pass "P16: the Nix-volume record rejects an unrecognized mode outright, both writing and reading"
else
    test_fail "P16: the Nix-volume record rejects an unrecognized mode outright, both writing and reading"
fi

unset DX_BOOTSTRAP_SCRATCH_DIR
rm -rf "$p16_fixture"

# P17 (refactor-v2-final.md Contract 2): capture_nix_image_default_profile
# persists the resolved target for its three consumers via
# dx_persist_image_default_profile_target/dx_read_image_default_profile_
# target instead of the exported DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET, and
# the value survives across separate bootstrap phases (capture ->
# nix_image_bootstrap_store_paths -> nix_restore_image_default_profile,
# simulating the /nix remount by capturing against one root and restoring
# against another that shares only the scratch directory).
p17_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p17-default-profile.XXXXXX")"
# nix_image_default_profile_store_path requires the resolved profile link to
# stay under source_root/store/*; on macOS /tmp is itself a symlink to
# /private/tmp, so readlink -f's fully-resolved path would otherwise never
# match this $TMPDIR-rooted fixture path textually. Resolve to the physical
# path up front, the same way this file's own top-level fixture already
# does (see fixture_physical near the top of this file).
p17_fixture="$(cd "$p17_fixture" && pwd -P)"
export DX_BOOTSTRAP_SCRATCH_DIR="$p17_fixture/scratch"
p17_image="$p17_fixture/image"
mkdir -p "$p17_image/store/default-profile/bin" "$p17_image/store/default-profile/etc/ssl/certs" "$p17_image/var/nix/profiles"
: > "$p17_image/store/default-profile/bin/sh"; : > "$p17_image/store/default-profile/bin/nix"
: > "$p17_image/store/default-profile/etc/ssl/certs/ca-bundle.crt"
chmod 0755 "$p17_image/store/default-profile/bin/sh" "$p17_image/store/default-profile/bin/nix"
ln -s "$p17_image/store/default-profile" "$p17_image/var/nix/profiles/default-1-link"
ln -s default-1-link "$p17_image/var/nix/profiles/default"

if DX_NIX_ROOT="$p17_image" capture_nix_image_default_profile "$p17_image" \
    && [ -z "${DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET:-}" ] \
    && [ "$(dx_read_image_default_profile_target)" = "$p17_image/store/default-profile" ] \
    && DX_NIX_ROOT="$p17_image" nix_image_bootstrap_store_paths "$p17_image" | stdin_matches -x /nix/store/default-profile; then
    test_pass "P17 (Contract 2 gate): capture_nix_image_default_profile persists the target for nix_image_bootstrap_store_paths without exporting DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET"
else
    test_fail "P17 (Contract 2 gate): capture_nix_image_default_profile persists the target for nix_image_bootstrap_store_paths without exporting DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET"
fi

# Simulate the /nix remount: a second root standing in for the durable
# volume once it has replaced /nix, sharing only the scratch directory the
# capture above wrote to.
p17_volume="$p17_fixture/volume"
mkdir -p "$p17_volume/store/default-profile/bin" "$p17_volume/store/default-profile/etc/ssl/certs" "$p17_volume/var/nix/profiles"
: > "$p17_volume/store/default-profile/bin/sh"; : > "$p17_volume/store/default-profile/bin/nix"
: > "$p17_volume/store/default-profile/etc/ssl/certs/ca-bundle.crt"
chmod 0755 "$p17_volume/store/default-profile/bin/sh" "$p17_volume/store/default-profile/bin/nix"
if (
    unset DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET
    dx_persist_image_default_profile_target "$p17_volume/store/default-profile"
    chown() { :; }
    # nix_restore_image_default_profile's own `mv -Tf` is GNU-mv-only (the
    # production guest is always Linux); mv -f alone is atomic-equivalent
    # for this call's exact two-argument shape, so this stub stays a real
    # rename rather than a no-op, portable to this host's BSD mv.
    mv() { if [ "$1" = -Tf ]; then shift; command mv -f "$@"; else command mv "$@"; fi; }
    DX_NIX_ROOT="$p17_volume" nix_restore_image_default_profile
) \
    && [ "$(readlink "$p17_volume/var/nix/profiles/default")" = "$p17_volume/store/default-profile" ]; then
    test_pass "P17: nix_restore_image_default_profile reads the persisted target back across the simulated remount, never DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET"
else
    test_fail "P17: nix_restore_image_default_profile reads the persisted target back across the simulated remount, never DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET"
fi

unset DX_BOOTSTRAP_SCRATCH_DIR
rm -rf "$p17_fixture"

# --- P18: common.sh's record readers/writer on a malformed or unreachable
# scratch path ---------------------------------------------------------
#
# Every reader/writer above is already exercised for its happy path and its
# content-validation refusals; these close the remaining defensive corners
# flagged by the coverage report: a symlinked record file, in place of a
# regular or absent one, on each of the three scratch-directory record
# readers, and dx_write_nix_volume_record's own scratch-directory creation
# failure.
p18_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-section3-p18.XXXXXX")"
export DX_BOOTSTRAP_SCRATCH_DIR="$p18_fixture/scratch"
mkdir -p "$DX_BOOTSTRAP_SCRATCH_DIR"

ln -sfn /nonexistent-target "$DX_BOOTSTRAP_SCRATCH_DIR/durable-identity-record"
if [ "$(dx_read_durable_identity_record)" = "" ]; then
    test_pass "P18: dx_read_durable_identity_record ignores a symlinked record file"
else
    test_fail "P18: dx_read_durable_identity_record ignores a symlinked record file"
fi
rm -f "$DX_BOOTSTRAP_SCRATCH_DIR/durable-identity-record"

ln -sfn /nonexistent-target "$DX_BOOTSTRAP_SCRATCH_DIR/image-default-profile-target"
if [ "$(dx_read_image_default_profile_target)" = "" ]; then
    test_pass "P18: dx_read_image_default_profile_target ignores a symlinked record file"
else
    test_fail "P18: dx_read_image_default_profile_target ignores a symlinked record file"
fi
rm -f "$DX_BOOTSTRAP_SCRATCH_DIR/image-default-profile-target"

ln -sfn /nonexistent-target "$DX_BOOTSTRAP_SCRATCH_DIR/nix-volume-record"
if ! dx_read_nix_volume_record >/dev/null 2>&1; then
    test_pass "P18: dx_read_nix_volume_record refuses a symlinked record file"
else
    test_fail "P18: dx_read_nix_volume_record refuses a symlinked record file"
fi
rm -f "$DX_BOOTSTRAP_SCRATCH_DIR/nix-volume-record"

# dx_write_nix_volume_record's own `mkdir -p "$dir" || return 1`: point the
# scratch directory at a path whose parent is a regular file, so mkdir -p
# can never create it.
: > "$p18_fixture/not-a-directory"
DX_BOOTSTRAP_SCRATCH_DIR="$p18_fixture/not-a-directory/scratch"
if ! dx_write_nix_volume_record already-mounted /nix >/dev/null 2>&1; then
    test_pass "P18: dx_write_nix_volume_record fails when its scratch directory cannot be created"
else
    test_fail "P18: dx_write_nix_volume_record fails when its scratch directory cannot be created"
fi

unset DX_BOOTSTRAP_SCRATCH_DIR
rm -rf "$p18_fixture"

print_summary
exit_with_code
