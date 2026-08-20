#!/bin/bash
# Behaviour tests for the ownership-correct, atomic image-store importer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Nix store import behaviour"

# The importer relies on GNU tar's create-side owner mapping.  The normal
# macOS suite does not provide that implementation, while the isolated Linux
# coverage image runs as root and deliberately exercises real numeric owners.
if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ] || ! tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
    test_skip "requires root in the isolated Linux GNU-tar runner"
    print_summary
    exit_with_code
fi

source "$CONTAINER_DIR/bootstrap/common.sh"
source "$CONTAINER_DIR/bootstrap/base-and-storage.sh"
source "$CONTAINER_DIR/bootstrap/system.sh"

fixture="$(mktemp -d /tmp/dxe-nix-import.XXXXXX)"
test_group="dxe-import-$RANDOM"
test_user="dxe-import-$RANDOM"
test_gid=42420
test_uid=42420
cleanup() {
    userdel "$test_user" >/dev/null 2>&1 || true
    groupdel "$test_group" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT

# The shared bootstrap helpers have small, safety-critical recovery branches.
# Exercise those branches with disposable profiles and command boundaries; no
# host account, service, or mounted volume is touched.
common_fixture="$fixture/common"
mkdir -p "$common_fixture/nix/store/profile/bin" "$common_fixture/root/.local/state/nix/profiles/profile/bin"
ln -s "$common_fixture/nix/store/profile" "$common_fixture/nix/var-profile"
if DX_ESSENTIALS_ROOT="$common_fixture" essentials_profile_path >/dev/null; then
    test_pass "essentials profile lookup tolerates absent profile links"
else
    test_fail "essentials profile lookup tolerates absent profile links"
fi
if (
    install_capture="$fixture/locked-essentials-command"
    nix() { printf '%q ' "$@" > "$install_capture"; }
    DX_BOOTSTRAP_ROOT="$CONTAINER_DIR" install_essential_packages
    grep -F -- "$CONTAINER_DIR#bootstrap-essentials" "$install_capture" >/dev/null \
        && grep -F -- '--no-update-lock-file' "$install_capture" >/dev/null \
        && ! grep -F -- 'nixpkgs#' "$install_capture" >/dev/null
); then
    test_pass "essentials installation resolves the checked-in locked bootstrap output"
else
    test_fail "essentials installation resolves the checked-in locked bootstrap output"
fi

# The image default profile is the root of the official base's shell, Nix, and
# CA bundle.  A generation link is not durable: collect-garbage can delete it
# even while /nix/var/nix/profiles/default remains.  The retained direct store
# target must therefore join the bootstrap root set and be restored after a
# remount without touching the target itself.
default_image="$fixture/default-image"
mkdir -p "$default_image/store/default-profile/bin" "$default_image/store/default-profile/etc/ssl/certs" "$default_image/var/nix/profiles"
touch "$default_image/store/default-profile/bin/sh" "$default_image/store/default-profile/bin/nix" "$default_image/store/default-profile/etc/ssl/certs/ca-bundle.crt"
chmod 0755 "$default_image/store/default-profile/bin/sh" "$default_image/store/default-profile/bin/nix"
ln -s "$default_image/store/default-profile" "$default_image/var/nix/profiles/default-1-link"
ln -s default-1-link "$default_image/var/nix/profiles/default"
if DX_NIX_ROOT="$default_image" capture_nix_image_default_profile "$default_image" \
    && [ "${DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET:-}" = "$default_image/store/default-profile" ] \
    && DX_NIX_ROOT="$default_image" nix_image_bootstrap_store_paths "$default_image" | grep -qx /nix/store/default-profile; then
    test_pass "image default profile target is retained in bootstrap GC roots"
else
    test_fail "image default profile target is retained in bootstrap GC roots"
fi
rm "$default_image/var/nix/profiles/default-1-link"
if ( chown() { :; }; DX_NIX_ROOT="$default_image" nix_restore_image_default_profile ) \
    && [ "$(readlink "$default_image/var/nix/profiles/default")" = "$default_image/store/default-profile" ] \
    && [ -x "$default_image/var/nix/profiles/default/bin/sh" ] \
    && [ -x "$default_image/var/nix/profiles/default/bin/nix" ] \
    && [ -r "$default_image/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt" ]; then
    test_pass "remount repair replaces a deleted default generation with a direct retained target"
else
    test_fail "remount repair replaces a deleted default generation with a direct retained target"
fi
default_gcroots="$fixture/default-gcroots"
DX_NIX_PENDING_IMAGE_STORE_IDENTITY="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
if DX_NIX_ROOT="$default_image" nix_install_image_essentials_root "$default_gcroots" "$test_uid" "$test_gid" \
    && [ "$(readlink "$default_gcroots/var/nix/gcroots/dx-image-roots-v2-${DX_NIX_PENDING_IMAGE_STORE_IDENTITY}/default-profile")" = /nix/store/default-profile ]; then
    test_pass "retained image default target is published as a GC root"
else
    test_fail "retained image default target is published as a GC root"
fi
unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY
root_layout_upgrade="$fixture/root-layout-upgrade"
root_layout_identity="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
mkdir -p "$root_layout_upgrade/var/nix/gcroots/dx-image-roots-$root_layout_identity"
ln -s /nix/store/old-layout-root "$root_layout_upgrade/var/nix/gcroots/dx-image-roots-$root_layout_identity/old-layout-root"
nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/default-profile; }
DX_NIX_PENDING_IMAGE_STORE_IDENTITY="$root_layout_identity"
if nix_install_image_essentials_root "$root_layout_upgrade" "$test_uid" "$test_gid" \
    && [ -L "$root_layout_upgrade/var/nix/gcroots/dx-image-roots-v2-$root_layout_identity/default-profile" ] \
    && [ "$(readlink "$root_layout_upgrade/var/nix/gcroots/dx-image-roots-v2-$root_layout_identity/default-profile")" = /nix/store/default-profile ] \
    && [ ! -e "$root_layout_upgrade/var/nix/gcroots/dx-image-roots-$root_layout_identity" ]; then
    test_pass "same-identity root publication upgrades an old layout before pruning it"
else
    test_fail "same-identity root publication upgrades an old layout before pruning it"
fi
unset -f nix_image_bootstrap_store_paths
unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY
source "$CONTAINER_DIR/bootstrap/base-and-storage.sh"
rm "$default_image/var/nix/profiles/default"
mkdir "$default_image/var/nix/profiles/live-profile"
ln -s live-profile "$default_image/var/nix/profiles/default"
if ( chown() { :; }; DX_NIX_ROOT="$default_image" nix_restore_image_default_profile ) \
    && [ "$(readlink "$default_image/var/nix/profiles/default")" = "$default_image/store/default-profile" ] \
    && ! find "$default_image/var/nix/profiles/live-profile" -name '.default.dx.*' -print -quit | grep -q .; then
    test_pass "default profile repair does not follow a symlink to a live directory"
else
    test_fail "default profile repair does not follow a symlink to a live directory"
fi
rm "$default_image/var/nix/profiles/default"
touch "$default_image/var/nix/profiles/default"
if ! ( chown() { :; }; DX_NIX_ROOT="$default_image" nix_restore_image_default_profile ); then
    test_pass "default profile repair refuses a non-symlinked publication target"
else
    test_fail "default profile repair refuses a non-symlinked publication target"
fi
rm "$default_image/var/nix/profiles/default"
if ! ( chown() { return 1; }; DX_NIX_ROOT="$default_image" nix_restore_image_default_profile ) \
    && ! find "$default_image/var/nix/profiles" -name '.default.dx.*' -print -quit | grep -q .; then
    test_pass "default profile repair cleans up a failed atomic publication"
else
    test_fail "default profile repair cleans up a failed atomic publication"
fi
if (
    DX_ESSENTIALS_ROOT="$common_fixture"
    mkdir -p "$common_fixture/nix/var/nix/profiles/per-user/root"
    ln -s "$common_fixture/nix/store/profile" "$common_fixture/nix/var/nix/profiles/per-user/root/profile"
    # Unsigned image-store paths are content-valid.  Model the Nix boundary
    # rather than matching a command string: without --no-trust, Nix reports
    # the trust-only failure that used to abort bootstrap before sshd.
    run_as_dx() {
        case "$1" in
            *'store verify'*) [[ "$1" == *'--no-trust'* ]] && [[ "$1" != *'--no-contents'* ]] ;;
            *) return 0 ;;
        esac
    }
    essentials_store_valid && repair_store_closure /nix/store/profile
    validation_calls=0
    essentials_store_valid() { validation_calls=$((validation_calls + 1)); [ "$validation_calls" -gt 1 ]; }
    repair_store_closure() { return 0; }
    essentials_profile_path() { printf '%s\n' /nix/store/profile/bin; }
    ensure_essentials_valid
); then
    test_pass "essentials validation repairs a registered-but-incomplete closure"
else
    test_fail "essentials validation repairs a registered-but-incomplete closure"
fi
if (
    keygen_calls=0
    ssh-keygen() { keygen_calls=$((keygen_calls + 1)); [ "$keygen_calls" -eq 2 ]; }
    command() { if [ "$1" = -v ]; then printf '%s\n' /nix/store/openssh/bin/ssh-keygen; else builtin command "$@"; fi; }
    readlink() { printf '%s\n' /nix/store/openssh/bin/ssh-keygen; }
    repair_store_closure() { [ "$1" = /nix/store/openssh ]; }
    sleep() { :; }
    generate_host_keys
); then
    test_pass "host-key generation retries after bounded closure repair"
else
    test_fail "host-key generation retries after bounded closure repair"
fi
if (
    auth_root="$fixture/auth-occupied-uid"
    no_getent_bin="$fixture/no-getent-bin"
    mkdir -p "$auth_root/etc" "$no_getent_bin"
    # create_user only needs these external commands after its identity check;
    # deliberately omit getent to reproduce the guest's bounded bootstrap PATH.
    ln -s /bin/mkdir "$no_getent_bin/mkdir"
    ln -s /bin/chmod "$no_getent_bin/chmod"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'other:x:42420:42420::/:/bin/sh' > "$auth_root/etc/passwd"
    printf '%s\n' 'root:x:0:' > "$auth_root/etc/group"
    id() { [ "$1" = -u ] && [ "$2" = dx ] && return 1; command id "$@"; }
    groupadd() { printf '%s\n' "$*" > "$fixture/groupadd"; }
    useradd() { printf '%s\n' "$*" > "$fixture/useradd"; }
    usermod() { :; }
    PATH="$no_getent_bin" DX_AUTH_ROOT="$auth_root" DX_NIX_DURABLE_UID=42420 DX_NIX_DURABLE_GID=42420 create_user
    [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ]
    grep -q -- '-f dx' "$fixture/groupadd"
    grep -q -- '-g dx' "$fixture/useradd"
); then
    test_pass "occupied materialized durable uid falls back without getent"
else
    test_fail "occupied materialized durable uid falls back without getent"
fi

if (
    auth_root="$fixture/auth-occupied-gid"
    mkdir -p "$auth_root/etc"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$auth_root/etc/passwd"
    printf '%s\n' 'root:x:0:' 'other:x:42420:' > "$auth_root/etc/group"
    id() { [ "$1" = -u ] && [ "$2" = dx ] && return 1; command id "$@"; }
    groupadd() { printf '%s\n' "$*" > "$fixture/gid-groupadd"; }
    useradd() { printf '%s\n' "$*" > "$fixture/gid-useradd"; }
    usermod() { :; }
    DX_AUTH_ROOT="$auth_root" DX_NIX_DURABLE_UID=42420 DX_NIX_DURABLE_GID=42420 create_user
    [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ]
    grep -q -- '-f dx' "$fixture/gid-groupadd"
    grep -q -- '-g dx' "$fixture/gid-useradd"
); then
    test_pass "occupied materialized durable gid falls back without getent"
else
    test_fail "occupied materialized durable gid falls back without getent"
fi

# A durable GID may already exist as the dx group while the user entry is
# absent (for example after an interrupted auth-file restore).  Reusing that
# exact group is safe; attempting groupadd again is not.
if (
    auth_root="$fixture/auth-existing-dx-group"
    mkdir -p "$auth_root/etc"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$auth_root/etc/passwd"
    printf '%s\n' 'root:x:0:' 'dx:x:42420:' > "$auth_root/etc/group"
    id() { [ "$1" = -u ] && [ "$2" = dx ] && return 1; command id "$@"; }
    groupadd() { printf '%s\n' "$*" > "$fixture/existing-dx-groupadd"; return 97; }
    useradd() { printf '%s\n' "$*" > "$fixture/existing-dx-useradd"; }
    usermod() { :; }
    DX_AUTH_ROOT="$auth_root" DX_NIX_DURABLE_UID=42420 DX_NIX_DURABLE_GID=42420 create_user
    [ ! -e "$fixture/existing-dx-groupadd" ]
    grep -q -- '-u 42420 -g dx' "$fixture/existing-dx-useradd"
); then
    test_pass "existing durable dx group is reused when the user is absent"
else
    test_fail "existing durable dx group is reused when the user is absent"
fi

if (
    DX_ESSENTIALS_ROOT="$fixture/no-profile"
    ! ensure_essentials_valid
); then
    test_pass "missing essentials profile fails before any repair attempt"
else
    test_fail "missing essentials profile fails before any repair attempt"
fi
if (
    ssh-keygen() { return 9; }
    command() { if [ "$1" = -v ]; then printf '%s\n' /nix/store/openssh/bin/ssh-keygen; else builtin command "$@"; fi; }
    readlink() { printf '%s\n' /nix/store/openssh/bin/ssh-keygen; }
    repair_store_closure() { :; }
    sleep() { :; }
    ! generate_host_keys
); then
    test_pass "host-key generation reports bounded retry exhaustion"
else
    test_fail "host-key generation reports bounded retry exhaustion"
fi

# Direct importer failure boundaries: a discarded incomplete stage, native-copy
# producer failure, malformed root identity, and collision all retain the
# published volume rather than silently accepting partial state.
stale_incomplete="$fixture/incomplete-volume/.dx-store-import-stage.partial"
mkdir -p "$stale_incomplete/store/partial"
cleanup_stale_nix_store_imports "$fixture/incomplete-volume"
if [ ! -e "$stale_incomplete" ]; then test_pass "incomplete import staging is discarded"; else test_fail "incomplete import staging is discarded"; fi
stale_merge="$fixture/merge-volume/.dx-store-import-stage.ready"
mkdir -p "$stale_merge/store/from-stage" "$stale_merge/quarantine/from-quarantine"
touch "$stale_merge/.ready"
cleanup_stale_nix_store_imports "$fixture/merge-volume"
if [ -d "$fixture/merge-volume/store/from-stage" ] && [ -d "$fixture/merge-volume/store/from-quarantine" ]; then test_pass "ready legacy staging restores store and quarantine entries"; else test_fail "ready legacy staging restores store and quarantine entries"; fi
if (
    nix() { return 19; }
    run_as_dx() { cat >/dev/null; }
    nix_install_image_essentials_root() { :; }
    ! nix_store_import_registered "$fixture/native-failure" "$test_uid" "$test_gid"
); then
    test_pass "native import rejects a failed source-store enumeration"
else
    test_fail "native import rejects a failed source-store enumeration"
fi
if (
    consumer_marker="$fixture/native-consumer-called"
    root_helper_marker="$fixture/native-consumer-root-helper-called"
    nix() { printf '%s\n' /nix/store/zzzz-essentials; }
    run_as_dx() { cat >/dev/null; : > "$consumer_marker"; return 23; }
    nix_install_image_essentials_root() { : > "$root_helper_marker"; return 99; }
    ! nix_store_import_registered "$fixture/native-consumer-failure" "$test_uid" "$test_gid" \
        && [ -f "$consumer_marker" ] && [ ! -e "$root_helper_marker" ]
); then
    test_pass "native import rejects a failed Nix-copy consumer"
else
    test_fail "native import rejects a failed Nix-copy consumer"
fi
if (
    nix_image_bootstrap_store_paths() { :; }
    DX_NIX_PENDING_IMAGE_STORE_IDENTITY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ! nix_install_image_essentials_root "$fixture/empty-roots" "$test_uid" "$test_gid"
); then
    test_pass "empty image GC root sets are rejected"
else
    test_fail "empty image GC root sets are rejected"
fi
if ! nix_seed_volume "$fixture/no-source" "$fixture/no-source-target" "$test_uid" "$test_gid"; then
    test_pass "fresh seed rejects an image without a store"
else
    test_fail "fresh seed rejects an image without a store"
fi
seed_source="$fixture/seed-source"
mkdir -p "$seed_source/store" "$fixture/collision-target/store"
if ! nix_seed_volume "$seed_source" "$fixture/collision-target" "$test_uid" "$test_gid"; then
    test_pass "fresh seed refuses to overwrite an existing volume entry"
else
    test_fail "fresh seed refuses to overwrite an existing volume entry"
fi
if (
    seed_entries="$fixture/seed-helper-entries"
    seed_target="$fixture/seed-helper-target"
    mkdir -p "$seed_entries" "$seed_target"
    printf visible > "$seed_entries/visible"
    printf hidden > "$seed_entries/.hidden"
    shopt -u dotglob nullglob
    dx_seed_staged_entries "$seed_entries" "$seed_target"
    [ -f "$seed_target/visible" ] && [ -f "$seed_target/.hidden" ] \
        && ! shopt -q dotglob && ! shopt -q nullglob
); then
    test_pass "seed helper moves hidden entries without leaking caller glob state"
else
    test_fail "seed helper moves hidden entries without leaking caller glob state"
fi
if (
    seed_entries="$fixture/seed-move-failure-entries"
    seed_target="$fixture/seed-move-failure-target"
    mkdir -p "$seed_entries" "$seed_target"
    printf first > "$seed_entries/a-first"
    printf fail > "$seed_entries/z-fail"
    shopt -u dotglob nullglob
    mv() { case "$1" in *z-fail*) return 41 ;; *) command mv "$@" ;; esac; }
    ! dx_seed_staged_entries "$seed_entries" "$seed_target" \
        && [ -f "$seed_target/a-first" ] && [ ! -e "$seed_target/z-fail" ] \
        && ! shopt -q dotglob && ! shopt -q nullglob
); then
    test_pass "seed helper reports a staged move failure without false success"
else
    test_fail "seed helper reports a staged move failure without false success"
fi
if (
    recovered_entries="$fixture/recovered-helper-entries"
    recovered_target="$fixture/recovered-helper-target"
    mkdir -p "$recovered_entries" "$recovered_target"
    printf hidden > "$recovered_entries/.hidden"
    shopt -s dotglob nullglob
    dx_move_missing_entries "$recovered_entries" "$recovered_target"
    [ -f "$recovered_target/.hidden" ] && shopt -q dotglob && shopt -q nullglob
); then
    test_pass "recovery helper moves hidden entries without changing caller glob state"
else
    test_fail "recovery helper moves hidden entries without changing caller glob state"
fi
durable_nix="$fixture/durable-nix"
durable_persist="$fixture/durable-persist"
mkdir -p "$durable_nix/store" "$durable_persist"
chown "$test_uid:$test_gid" "$durable_nix/store"
chown 1:1 "$durable_persist"
if DX_PERSIST_HOME="$durable_persist" record_durable_nix_identity "$durable_nix" \
    && [ "${DX_NIX_DURABLE_UID:-}" = "$test_uid" ] \
    && [ "${DX_PERSIST_IDENTITY_MIGRATION_REQUIRED:-false}" = true ]; then
    test_pass "Nix identity wins a durable Nix/persist mismatch and schedules migration"
else
    test_fail "Nix identity wins a durable Nix/persist mismatch and schedules migration"
fi
unset DX_PERSIST_IDENTITY_MIGRATION_REQUIRED
unsafe_nix="$fixture/unsafe-nix"
unsafe_persist="$fixture/unsafe-persist"
mkdir -p "$unsafe_nix/store" "$unsafe_nix/var/nix/db" "$unsafe_nix/var/nix" "$unsafe_persist"
touch "$unsafe_nix/var/nix/db/big-lock"
chown -R 0:0 "$unsafe_nix"
chown "$test_uid:$test_gid" "$unsafe_persist"
if DX_PERSIST_HOME="$unsafe_persist" record_durable_nix_identity "$unsafe_nix" \
    && [ "${DX_NIX_DURABLE_UID:-}" = "$test_uid" ] \
    && [ "${DX_NIX_DURABLE_GID:-}" = "$test_gid" ] \
    && [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ]; then
    test_pass "root-owned Nix store DB and big-lock defer to safe persist identity and schedule migration"
else
    test_fail "root-owned Nix store DB and big-lock defer to safe persist identity and schedule migration"
fi
unset DX_NIX_IDENTITY_MIGRATION_REQUIRED
if (
    id() { case "$1:$2" in -u:dx|-g:dx) printf '%s\n' 0 ;; *) command id "$@";; esac; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
    ! migrate_durable_nix_identity_if_needed "$fixture/migration-invalid"
); then
    test_pass "root durable identity is rejected before ownership migration"
else
    test_fail "root durable identity is rejected before ownership migration"
fi
if (
    mkdir -p "$fixture/migration-marker"
    id() { case "$1:$2" in -u:dx) printf '%s\n' "$test_uid";; -g:dx) printf '%s\n' "$test_gid";; *) command id "$@";; esac; }
    chown() { :; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
    migrate_durable_nix_identity_if_needed "$fixture/migration-marker"
    [ -f "$fixture/migration-marker/.dx-durable-identity-v1" ] && [ -f "$fixture/migration-marker/.dx-owner-set" ]
); then
    test_pass "durable identity migration publishes versioned and compatibility markers"
else
    test_fail "durable identity migration publishes versioned and compatibility markers"
fi

groupadd -g "$test_gid" "$test_group"
useradd -M -u "$test_uid" -g "$test_group" -s /usr/sbin/nologin "$test_user"

src="$fixture/image-nix"
dst="$fixture/volume-nix"
mkdir -p "$src/store/aaaa-existing/bin" "$src/store/bbbb-repaired/bin" "$src/store/cccc-linked/lib" "$src/store/dddd-metadata/readonly" "$src/store/zzzz-essentials" "$src/var/nix/profiles/per-user/root"
ln -s "$src/store/zzzz-essentials" "$src/var/nix/profiles/per-user/root/profile"
printf '%s\n' volume-existing > "$src/store/aaaa-existing/bin/tool"
printf '%s\n' whole-content > "$src/store/bbbb-repaired/bin/tool"
printf '%s\n' linked > "$src/store/cccc-linked/lib/one"
ln "$src/store/cccc-linked/lib/one" "$src/store/cccc-linked/lib/two"
ln -s ../aaaa-existing/bin/tool "$src/store/cccc-linked/tool-link"
printf '%s\n' hidden > "$src/store/.hidden-image-entry"
printf '%s\n' readonly > "$src/store/dddd-metadata/readonly/tool"
chmod 0555 "$src/store/dddd-metadata/readonly"
touch -t 202401020304 "$src/store/dddd-metadata/readonly/tool"

if nix_seed_volume "$src" "$dst" "$test_uid" "$test_gid"; then
    test_pass "fresh image store seeds through the parameterized boundary"
else
    test_fail "fresh image store seeds through the parameterized boundary"
fi

if [ "$(stat -c '%u:%g' "$dst/store")" = "$test_uid:$test_gid" ]; then
    test_pass "fresh destination store receives the durable non-root owner"
else
    test_fail "fresh destination store receives the durable non-root owner"
fi
if [ "$(stat -c '%u:%g' "$dst/store/bbbb-repaired/bin/tool")" = "$test_uid:$test_gid" ]; then
    test_pass "new and repaired paths are assigned the durable owner while written"
else
    test_fail "new and repaired paths are assigned the durable owner while written"
fi
if [ "$(stat -c '%i' "$dst/store/cccc-linked/lib/one")" = "$(stat -c '%i' "$dst/store/cccc-linked/lib/two")" ] && [ -L "$dst/store/cccc-linked/tool-link" ]; then
    test_pass "hard links and symlinks survive the import"
else
    test_fail "hard links and symlinks survive the import"
fi
if [ -f "$dst/store/.hidden-image-entry" ] && [ "$(stat -c '%a' "$dst/store/dddd-metadata/readonly")" = 555 ] && [ "$(stat -c '%Y' "$dst/store/dddd-metadata/readonly/tool")" = "$(stat -c '%Y' "$src/store/dddd-metadata/readonly/tool")" ]; then
    test_pass "dotfiles, modes, and timestamps survive the import"
else
    test_fail "dotfiles, modes, and timestamps survive the import"
fi
if ! find "$dst" -maxdepth 1 -name '.dx-store-import-stage.*' -print -quit | grep -q .; then
    test_pass "successful imports leave no staging directory visible"
else
    test_fail "successful imports leave no staging directory visible"
fi

printf '%s\n' zzzz-essentials > "$dst/.dx-image-store-identity"
nix_image_store_identity() { printf '%s\n' zzzz-essentials; }
verify_capture="$fixture/verify-command"
run_as_dx() {
    printf '%s\n' "$1" > "$verify_capture"
    return 0
}
if nix_image_store_import_required "$src" "$dst"; then
    test_fail "matching image identity and complete essentials closure skip the image-store walk"
else
    test_pass "matching image identity and complete essentials closure skip the image-store walk"
fi
if grep -F -- "store verify --store 'local?store=/nix/store&real=$dst/store&state=$dst/var/nix&log=$dst/var/log/nix' --recursive --no-trust" "$verify_capture" >/dev/null \
    && ! grep -F -- '--no-contents' "$verify_capture" >/dev/null; then
    test_pass "matching image identity verifies local contents without requiring signatures"
else
    test_fail "matching image identity verifies local contents without requiring signatures"
fi
rmdir "$dst/store/zzzz-essentials"  # Model GC removing a bootstrap closure.
run_as_dx() { return 1; }
if nix_image_store_import_required "$src" "$dst"; then
    test_pass "missing essentials reopens a matching image identity gate"
else
    test_fail "missing essentials reopens a matching image identity gate"
fi
unset -f run_as_dx
unset -f nix_image_store_identity
source "$CONTAINER_DIR/bootstrap/base-and-storage.sh"

# A crash after a complete fresh seed archive leaves its .ready contents below
# staging. Recovery publishes them rather than deleting the only valid copy.
stale="$dst/.dx-store-import-stage.crash"
mkdir -p "$stale/contents/eeee-recovered"
printf '%s\n' recovered > "$stale/contents/eeee-recovered/tool"
touch "$stale/.ready"
cleanup_stale_nix_store_imports "$dst"
if [ "$(cat "$dst/eeee-recovered/tool")" = recovered ]; then
    test_pass "ready interrupted stages recover without deleting the only valid copy"
else
    test_fail "ready interrupted stages recover without deleting the only valid copy"
fi

# The producer side of tar|tar must be checked even if the caller did not set
# pipefail; otherwise a failed archive creation could look like a successful,
# empty import.
bad_dst="$fixture/bad-volume-nix"
tar() {
    case " $* " in
        *' -cf '*) return 17 ;;
        *) command tar "$@" ;;
    esac
}
if nix_seed_volume "$src" "$bad_dst" "$test_uid" "$test_gid"; then
    test_fail "a failed tar producer makes the import fail without publication"
else
    test_pass "a failed tar producer makes the import fail without publication"
fi
unset -f tar
if [ ! -e "$bad_dst/store/aaaa-existing" ]; then
    test_pass "failed staging publishes no final store path"
else
    test_fail "failed staging publishes no final store path"
fi

# The incremental path delegates publication and database registration to Nix.
# This boundary test verifies the real target layout (logical /nix/store with
# the temporary mount as `real`) and that the producer and Nix-copy consumer
# are both checked, rather than accepting an unregistered filesystem merge.
registered_dst="$fixture/registered-volume-nix"
registered_capture="$fixture/registered-command"
nix() {
    case " $* " in *' path-info '*) printf '%s\n' /nix/store/zzzz-essentials ;; *) return 99 ;; esac
}
nix_install_image_essentials_root() { :; }
run_as_dx() {
    printf '%s\n' "$1" > "$registered_capture"
    cat >/dev/null
}
if nix_store_import_registered "$registered_dst" "$test_uid" "$test_gid"; then
    test_pass "incremental import uses Nix's registered copy transaction"
else
    test_fail "incremental import uses Nix's registered copy transaction"
fi
if grep -F 'copy --from' "$registered_capture" >/dev/null \
    && grep -F "real=$registered_dst/store" "$registered_capture" >/dev/null \
    && grep -F -- '--stdin --no-check-sigs' "$registered_capture" >/dev/null; then
    test_pass "registered copy targets the mounted store database and accepts image paths"
else
    test_fail "registered copy targets the mounted store database and accepts image paths"
fi
unset -f nix run_as_dx nix_install_image_essentials_root
source "$CONTAINER_DIR/bootstrap/base-and-storage.sh"

# The gate identity is the sorted registered source path set, not just one
# profile basename: a base-image /usr/bin target can change independently.
identity_capture="$fixture/image-identity"
nix() { printf '%s\n' /nix/store/b-path /nix/store/a-path; }
if declare -F nix_image_store_identity >/dev/null; then
    nix_image_store_identity > "$identity_capture"
fi
expected_identity="$(printf '%s\n' /nix/store/a-path /nix/store/b-path | sha256sum | awk '{print $1}')"
if [ "$(cat "$identity_capture" 2>/dev/null || true)" = "$expected_identity" ]; then
    test_pass "image identity derives from the complete registered path set"
else
    test_fail "image identity derives from the complete registered path set"
fi
unset -f nix

# A persisted home can outlive an absent/recreated Nix volume; it is still a
# durable identity source.  Root and malformed identities are rejected.
persist_only="$fixture/persist-only/home/dx"
mkdir -p "$persist_only"
chown "$test_uid:$test_gid" "$persist_only"
DX_PERSIST_HOME="$persist_only" record_durable_nix_identity "$fixture/no-nix" || true
if [ "${DX_NIX_DURABLE_UID:-}" = "$test_uid" ] && [ "${DX_NIX_DURABLE_GID:-}" = "$test_gid" ]; then
    test_pass "persist-only durable identity is reused"
else
    test_fail "persist-only durable identity is reused"
fi

# A failed marker publication must not strand a temp file that could be read as
# a successful import on a later boot.
marker_root="$fixture/marker-root"
mkdir -p "$marker_root"
DX_NIX_PENDING_IMAGE_STORE_IDENTITY=marker-test
chown() { return 1; }
if publish_nix_image_store_identity "$marker_root"; then
    test_fail "failed image marker ownership prevents publication"
else
    test_pass "failed image marker ownership prevents publication"
fi
unset -f chown
if ! find "$marker_root" -maxdepth 1 -name '.dx-image-store-identity.*' -print -quit | grep -q . \
    && [ ! -e "$marker_root/.dx-image-store-identity" ]; then
    test_pass "failed image marker publication cleans temporary state"
else
    test_fail "failed image marker publication cleans temporary state"
fi

# A directory at the image identity marker must not become a false-success
# destination for `mv`: the pending identity remains set so the next boot can
# retry after the durable state is repaired.
directory_image_marker="$fixture/directory-image-marker"
mkdir -p "$directory_image_marker/.dx-image-store-identity"
DX_NIX_PENDING_IMAGE_STORE_IDENTITY=directory-marker-test
directory_image_status=0
publish_nix_image_store_identity "$directory_image_marker" >/dev/null 2>&1 || directory_image_status=$?
if [ "$directory_image_status" -ne 0 ] \
    && [ -n "${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-}" ] \
    && [ -z "$(find "$directory_image_marker/.dx-image-store-identity" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    test_pass "directory-valued image identity markers fail without nested temporary files"
else
    test_fail "directory-valued image identity markers fail without nested temporary files"
fi
unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY

# A root-set refresh must never first delete the old roots.  This models a
# kill/failure between staging and publication: the next boot still has a
# valid GC root and can retry the bounded refresh.
roots_root="$fixture/gc-roots"
mkdir -p "$roots_root/var/nix/gcroots/dx-image-roots-old"
ln -s /nix/store/old-root "$roots_root/var/nix/gcroots/dx-image-roots-old/old-root"
DX_NIX_PENDING_IMAGE_STORE_IDENTITY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/new-root; }
mv() { return 1; }
if nix_install_image_essentials_root "$roots_root" "$test_uid" "$test_gid"; then
    test_fail "interrupted GC-root publication reports failure"
else
    test_pass "interrupted GC-root publication reports failure"
fi
unset -f mv
if [ -L "$roots_root/var/nix/gcroots/dx-image-roots-old/old-root" ]; then
    test_pass "interrupted GC-root publication retains the only prior valid roots"
else
    test_fail "interrupted GC-root publication retains the only prior valid roots"
fi
if nix_install_image_essentials_root "$roots_root" "$test_uid" "$test_gid" \
    && [ -L "$roots_root/var/nix/gcroots/dx-image-roots-v2-${DX_NIX_PENDING_IMAGE_STORE_IDENTITY}/new-root" ] \
    && [ ! -e "$roots_root/var/nix/gcroots/dx-image-roots-old" ]; then
    test_pass "completed GC-root publication atomically replaces stale root sets"
else
    test_fail "completed GC-root publication atomically replaces stale root sets"
fi
unset -f nix_image_bootstrap_store_paths
unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY

# A migration marker is a trust boundary: it must never be followed through a
# symlink before either the recursive repair or compatibility-marker publish.
migration_root="$fixture/migration-root"
mkdir -p "$migration_root/store"
ln -s /tmp "$migration_root/.dx-durable-identity-v1"
id() {
    case "${1:-}:${2:-}" in
        -u:dx) printf '%s\n' "$test_uid" ;;
        -g:dx) printf '%s\n' "$test_gid" ;;
        *) command id "$@" ;;
    esac
}
DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
if migrate_durable_nix_identity_if_needed "$migration_root"; then
    test_fail "symlinked durable ownership markers are rejected"
else
    test_pass "symlinked durable ownership markers are rejected"
fi
unset -f id
unset DX_NIX_IDENTITY_MIGRATION_REQUIRED

# Durable identity migration must reject directory-valued markers before any
# recursive repair or partial marker publication, and retain the retry flag.
directory_migration_root="$fixture/directory-migration-root"
mkdir -p "$directory_migration_root/store" "$directory_migration_root/.dx-durable-identity-v1" "$directory_migration_root/.dx-owner-set"
id() {
    case "${1:-}:${2:-}" in
        -u:dx) printf '%s\n' "$test_uid" ;;
        -g:dx) printf '%s\n' "$test_gid" ;;
        *) command id "$@" ;;
    esac
}
DX_NIX_IDENTITY_MIGRATION_REQUIRED=true
directory_migration_status=0
migrate_durable_nix_identity_if_needed "$directory_migration_root" >/dev/null 2>&1 || directory_migration_status=$?
if [ "$directory_migration_status" -ne 0 ] \
    && [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ] \
    && [ -z "$(find "$directory_migration_root/.dx-durable-identity-v1" "$directory_migration_root/.dx-owner-set" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    test_pass "directory-valued durable identity markers retain migration state safely"
else
    test_fail "directory-valued durable identity markers retain migration state safely"
fi
unset -f id
unset DX_NIX_IDENTITY_MIGRATION_REQUIRED

id() {
    case "${1:-}:${2:-}" in
        -u:dx|-g:dx) printf '%s\n' 1000 ;;
        *) command id "$@" ;;
    esac
}
DX_NIX_DURABLE_UID="$test_uid"
DX_NIX_DURABLE_GID="$test_gid"
unset DX_NIX_IDENTITY_MIGRATION_REQUIRED
if create_user && [ "${DX_NIX_IDENTITY_MIGRATION_REQUIRED:-false}" = true ]; then
    test_pass "existing dx identity conflict keeps the safe account and schedules migration"
else
    test_fail "existing dx identity conflict keeps the safe account and schedules migration"
fi
unset -f id
unset DX_NIX_DURABLE_UID DX_NIX_DURABLE_GID DX_NIX_IDENTITY_MIGRATION_REQUIRED

print_summary
exit_with_code
