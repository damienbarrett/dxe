#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.1 (plans/do D-1; R13, R14, R22): the /persist host-access config fields.
#
# Interface contract (pinned by this file; the implementation must match):
#   * Registry rows in bin/lib/dx-config.sh:
#       DX_PERSIST_STORAGE    enum:volume,host-path   default "volume"
#       DX_PERSIST_HOST_ROOT  optpath                 default "" (empty)
#     Per-field validation: DX_PERSIST_STORAGE accepts exactly volume and
#     host-path; DX_PERSIST_HOST_ROOT accepts empty or an absolute path and
#     rejects a relative one (the existing optpath kind).
#   * The guest directory is derived, never configured: no DX_PERSIST_HOST_DIR
#     (or similar) field exists.
#   * dx_config_validate_cross_fields gains three rules, each with its own
#     message on stderr and status 1. Essential fixed strings:
#       apple + host-path:
#           "DX_PERSIST_STORAGE=host-path"  "DX_RUNTIME=docker-ssh"
#           "docs/guest.md"
#       host-path with an empty root:
#           "DX_PERSIST_HOST_ROOT is required when DX_PERSIST_STORAGE=host-path"
#       root containing ':':
#           "DX_PERSIST_HOST_ROOT must not contain ':'"
#     A message never contains another rule's essential strings (the apple
#     message does not say "is required" or "must not contain"; the empty-root
#     message does not mention docs/guest.md; the colon message mentions
#     neither). Rule order when several fail at once is not pinned, so every
#     case below breaks exactly one rule.
#   * The rules apply both to dx_init_config and to loading a profile file
#     through bin/dx-profile (which ends in dx_init_config), and are
#     enforced for inherited snapshots (dx_validate_config_snapshot).
#   * Valid host-path configuration: DX_RUNTIME=docker-ssh, a non-empty
#     colon-free absolute root, plus the usual docker-ssh settings.
#   * volume mode ignores DX_PERSIST_HOST_ROOT entirely (a colon in it, or a
#     value under apple, is not an error while DX_PERSIST_STORAGE=volume).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"

test_section "WP3.1: /persist host-access config fields"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-config.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/root" "$fixture/profiles"
tools="$(fake_tool_dir_create "$fixture")"

expect_ok() { local label="$1"; shift; if "$@"; then test_pass "$label"; else test_fail "$label"; fi; }
expect_reject() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi; }
has() { grep -Fq -- "$2" <<<"$1"; }

# --- Registry rows ---------------------------------------------------------
expect_ok "DX_PERSIST_STORAGE is a registered config field" dx_config_is_field DX_PERSIST_STORAGE
[ "$(dx_config_default DX_PERSIST_STORAGE 2>/dev/null)" = volume ] \
    && test_pass "DX_PERSIST_STORAGE defaults to volume" || test_fail "DX_PERSIST_STORAGE defaults to volume"
expect_ok "DX_PERSIST_STORAGE accepts volume" dx_config_validate_value DX_PERSIST_STORAGE volume
expect_ok "DX_PERSIST_STORAGE accepts host-path" dx_config_validate_value DX_PERSIST_STORAGE host-path
expect_reject "DX_PERSIST_STORAGE rejects a bogus value" dx_config_validate_value DX_PERSIST_STORAGE bogus
expect_reject "DX_PERSIST_STORAGE rejects an empty value" dx_config_validate_value DX_PERSIST_STORAGE ''
expect_reject "DX_PERSIST_STORAGE rejects a comma-smuggled list" dx_config_validate_value DX_PERSIST_STORAGE volume,host-path

expect_ok "DX_PERSIST_HOST_ROOT is a registered config field" dx_config_is_field DX_PERSIST_HOST_ROOT
if dx_config_is_field DX_PERSIST_HOST_ROOT && [ -z "$(dx_config_default DX_PERSIST_HOST_ROOT)" ]; then
    test_pass "DX_PERSIST_HOST_ROOT defaults to empty"
else
    test_fail "DX_PERSIST_HOST_ROOT defaults to empty"
fi
expect_ok "DX_PERSIST_HOST_ROOT accepts empty" dx_config_validate_value DX_PERSIST_HOST_ROOT ''
expect_ok "DX_PERSIST_HOST_ROOT accepts an absolute path" dx_config_validate_value DX_PERSIST_HOST_ROOT /share/example-root
expect_reject "DX_PERSIST_HOST_ROOT rejects a relative path" dx_config_validate_value DX_PERSIST_HOST_ROOT relative/root
# The registry kinds themselves, so the field cannot be re-typed to something looser.
[ "$(dx_config_kind DX_PERSIST_STORAGE 2>/dev/null)" = enum:volume,host-path ] \
    && test_pass "DX_PERSIST_STORAGE kind is enum:volume,host-path" || test_fail "DX_PERSIST_STORAGE kind is enum:volume,host-path"
[ "$(dx_config_kind DX_PERSIST_HOST_ROOT 2>/dev/null)" = optpath ] \
    && test_pass "DX_PERSIST_HOST_ROOT kind is optpath" || test_fail "DX_PERSIST_HOST_ROOT kind is optpath"
# The guest directory is derived (root/dxe/<container>/persist), never configured.
expect_reject "no DX_PERSIST_HOST_DIR field exists (the guest directory is derived)" dx_config_is_field DX_PERSIST_HOST_DIR
expect_reject "no DX_PERSIST_DIR_GUEST config field exists (it is a derived guest env var)" dx_config_is_field DX_PERSIST_DIR_GUEST

# --- Resolution through dx_init_config (fresh process, clean environment) ---
# resolve [NAME=value ...]: prints "rc=<n>", then stderr lines, then the
# resolved persist fields (when rc=0). Nothing inherited from this shell.
resolve() {
    local out
    out="$(env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" "$@" \
        bash -c 'source "$1/bin/lib/dx-config.sh"; dx_init_config "$2" 2>&1; rc=$?; echo "rc=$rc"; echo "STORAGE=${DX_PERSIST_STORAGE-unset}"; echo "ROOT=${DX_PERSIST_HOST_ROOT-unset}"' \
        _ "$BASE_DIR" "$fixture/root")"
    printf '%s\n' "$out"
}
DOCKER_BASE="DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume"
# shellcheck disable=SC2086
resolve_docker() { resolve $DOCKER_BASE "$@"; }

APPLE_MSG_A="DX_PERSIST_STORAGE=host-path"
APPLE_MSG_B="DX_RUNTIME=docker-ssh"
APPLE_MSG_C="docs/guest.md"
EMPTY_MSG="DX_PERSIST_HOST_ROOT is required when DX_PERSIST_STORAGE=host-path"
COLON_MSG="DX_PERSIST_HOST_ROOT must not contain ':'"

out="$(resolve)"
if has "$out" "rc=0" && has "$out" "STORAGE=volume" && has "$out" "ROOT="; then
    test_pass "apple defaults resolve to DX_PERSIST_STORAGE=volume with an empty root"
else test_fail "apple defaults resolve to DX_PERSIST_STORAGE=volume with an empty root"; printf "%s\n" "$out" | tail -n 6; fi

out="$(resolve_docker)"
if has "$out" "rc=0" && has "$out" "STORAGE=volume"; then
    test_pass "docker-ssh without the new fields resolves to volume (R14: default unchanged)"
else test_fail "docker-ssh without the new fields resolves to volume (R14: default unchanged)"; printf "%s\n" "$out" | tail -n 6; fi

out="$(resolve_docker DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/example-root)"
if has "$out" "rc=0" && has "$out" "STORAGE=host-path" && has "$out" "ROOT=/share/example-root"; then
    test_pass "docker-ssh + host-path + absolute root resolves and keeps both values"
else test_fail "docker-ssh + host-path + absolute root resolves and keeps both values"; printf "%s\n" "$out" | tail -n 6; fi

out="$(resolve_docker DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT=/share/with:colon)"
if has "$out" "rc=0"; then test_pass "volume mode ignores a colon in the (unused) root"
else test_fail "volume mode ignores a colon in the (unused) root"; printf "%s\n" "$out" | tail -n 6; fi

out="$(resolve DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT=/share/example-root)"
if has "$out" "rc=0"; then test_pass "apple + volume with a root set is not an error"
else test_fail "apple + volume with a root set is not an error"; printf "%s\n" "$out" | tail -n 6; fi

# apple + host-path: its own message, naming the Mac access docs.
out="$(resolve DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/example-root)"
if ! has "$out" "rc=0" && has "$out" "$APPLE_MSG_A" && has "$out" "$APPLE_MSG_B" && has "$out" "$APPLE_MSG_C" \
    && ! has "$out" "is required" && ! has "$out" "must not contain"; then
    test_pass "apple + host-path fails with the docs/guest.md pointer and no other rule's message"
else test_fail "apple + host-path fails with the docs/guest.md pointer and no other rule's message"; printf "%s\n" "$out" | tail -n 6; fi

# host-path with an empty root: its own message.
out="$(resolve_docker DX_PERSIST_STORAGE=host-path)"
if ! has "$out" "rc=0" && has "$out" "$EMPTY_MSG" && ! has "$out" "$APPLE_MSG_C" && ! has "$out" "must not contain"; then
    test_pass "host-path with an unset root fails with its own message"
else test_fail "host-path with an unset root fails with its own message"; printf "%s\n" "$out" | tail -n 6; fi
out="$(resolve_docker DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=)"
if ! has "$out" "rc=0" && has "$out" "$EMPTY_MSG"; then
    test_pass "host-path with an explicitly empty root fails with the same message"
else test_fail "host-path with an explicitly empty root fails with the same message"; printf "%s\n" "$out" | tail -n 6; fi

# a root containing ':'.
out="$(resolve_docker DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/with:colon)"
if ! has "$out" "rc=0" && has "$out" "$COLON_MSG" && ! has "$out" "$APPLE_MSG_C" && ! has "$out" "is required"; then
    test_pass "a root containing ':' fails with its own message"
else test_fail "a root containing ':' fails with its own message"; printf "%s\n" "$out" | tail -n 6; fi
out="$(resolve_docker DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/:)"
if ! has "$out" "rc=0" && has "$out" "$COLON_MSG"; then
    test_pass "a root that is only a colon-bearing path fails too"
else test_fail "a root that is only a colon-bearing path fails too"; printf "%s\n" "$out" | tail -n 6; fi

# per-field errors still win through dx_init_config.
out="$(resolve_docker DX_PERSIST_STORAGE=bogus)"
if ! has "$out" "rc=0" && has "$out" "DX_PERSIST_STORAGE" && ! has "$out" "unknown configuration field"; then test_pass "a bogus DX_PERSIST_STORAGE fails dx_init_config"
else test_fail "a bogus DX_PERSIST_STORAGE fails dx_init_config"; printf "%s\n" "$out" | tail -n 6; fi
out="$(resolve_docker DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=relative/root)"
if ! has "$out" "rc=0" && has "$out" "DX_PERSIST_HOST_ROOT" && ! has "$out" "unknown configuration field"; then test_pass "host-path with a relative root fails dx_init_config"
else test_fail "host-path with a relative root fails dx_init_config"; printf "%s\n" "$out" | tail -n 6; fi

# --- Inherited snapshots re-run the cross-field rules ----------------------
# Resolve a valid docker-ssh host-path snapshot in a fresh process, then
# alter one resolved value (as a corrupted or hand-edited inherited snapshot
# would) and ask dx_validate_config_snapshot to accept it.
snapshot_after() {
    env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" $DOCKER_BASE \
        DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/example-root \
        bash -c 'source "$1/bin/lib/dx-config.sh"
            dx_init_config "$2" >/dev/null 2>&1 || { echo "init-failed"; exit 0; }
            dx_validate_config_snapshot "$2" >/dev/null 2>&1 || { echo "baseline-invalid"; exit 0; }
            eval "$3"
            dx_validate_config_snapshot "$2" 2>&1; echo "rc=$?"' _ "$BASE_DIR" "$fixture/root" "$1"
}
out="$(snapshot_after 'DX_RUNTIME=apple; DX_REMOTE_HOST=; DX_NIX_STORAGE_MODE=apple-image')"
if has "$out" "rc=1" && has "$out" "$APPLE_MSG_C"; then
    test_pass "a snapshot altered to apple + host-path is refused with the docs pointer"
else test_fail "a snapshot altered to apple + host-path is refused with the docs pointer"; printf "%s\n" "$out" | tail -n 6; fi
out="$(snapshot_after 'DX_PERSIST_HOST_ROOT=')"
if has "$out" "rc=1" && has "$out" "$EMPTY_MSG"; then
    test_pass "a snapshot altered to an empty host-path root is refused"
else test_fail "a snapshot altered to an empty host-path root is refused"; printf "%s\n" "$out" | tail -n 6; fi
out="$(snapshot_after 'DX_PERSIST_HOST_ROOT=/share/a:b')"
if has "$out" "rc=1" && has "$out" "$COLON_MSG"; then
    test_pass "a snapshot altered to a colon-bearing root is refused"
else test_fail "a snapshot altered to a colon-bearing root is refused"; printf "%s\n" "$out" | tail -n 6; fi
out="$(snapshot_after ':')"
if has "$out" "rc=0"; then test_pass "an unaltered host-path snapshot validates"
else test_fail "an unaltered host-path snapshot validates"; printf "%s\n" "$out" | tail -n 6; fi

# --- Loading a profile file through bin/dx-profile --------------------------
# The command run after loading is `env`: nothing reaches a runtime.
write_profile() { printf '%s\n' "$2" > "$fixture/profiles/$1.env"; }
profile_run() {
    local name="$1"; shift
    env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" DX_PROFILES_DIR="$fixture/profiles" \
        "$BASE_DIR/bin/dx-profile" "$name" /usr/bin/env 2>&1
    echo "rc=$?"
}
PROFILE_DOCKER='export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=dxe-fixture-nas.invalid
export DX_GUEST_SYSTEM=x86_64-linux
export DX_NIX_STORAGE_MODE=direct-volume'

write_profile ok-hostpath "$PROFILE_DOCKER
export DX_PERSIST_STORAGE=host-path
export DX_PERSIST_HOST_ROOT=/share/example-root"
out="$(profile_run ok-hostpath)"
if has "$out" "rc=0" && has "$out" "DX_PERSIST_STORAGE=host-path" && has "$out" "DX_PERSIST_HOST_ROOT=/share/example-root"; then
    test_pass "dx-profile loads a valid host-path profile and exports both fields"
else test_fail "dx-profile loads a valid host-path profile and exports both fields"; printf "%s\n" "$out" | tail -n 6; fi

write_profile ok-volume "$PROFILE_DOCKER"
out="$(profile_run ok-volume)"
if has "$out" "rc=0" && has "$out" "DX_PERSIST_STORAGE=volume"; then
    test_pass "dx-profile resolves a profile without the fields to volume"
else test_fail "dx-profile resolves a profile without the fields to volume"; printf "%s\n" "$out" | tail -n 6; fi

write_profile apple-hostpath 'export DX_PERSIST_STORAGE=host-path
export DX_PERSIST_HOST_ROOT=/share/example-root'
out="$(profile_run apple-hostpath)"
if ! has "$out" "rc=0" && has "$out" "$APPLE_MSG_A" && has "$out" "$APPLE_MSG_C" && ! grep -Fqx -- "DX_PERSIST_STORAGE=host-path" <<<"$out"; then
    test_pass "dx-profile reports the apple + host-path error and runs nothing"
else test_fail "dx-profile reports the apple + host-path error and runs nothing"; printf "%s\n" "$out" | tail -n 6; fi

write_profile empty-root "$PROFILE_DOCKER
export DX_PERSIST_STORAGE=host-path"
out="$(profile_run empty-root)"
if ! has "$out" "rc=0" && has "$out" "$EMPTY_MSG"; then
    test_pass "dx-profile reports the empty-root error"
else test_fail "dx-profile reports the empty-root error"; printf "%s\n" "$out" | tail -n 6; fi

write_profile colon-root "$PROFILE_DOCKER
export DX_PERSIST_STORAGE=host-path
export DX_PERSIST_HOST_ROOT=/share/with:colon"
out="$(profile_run colon-root)"
if ! has "$out" "rc=0" && has "$out" "$COLON_MSG"; then
    test_pass "dx-profile reports the colon-in-root error"
else test_fail "dx-profile reports the colon-in-root error"; printf "%s\n" "$out" | tail -n 6; fi

write_profile bogus-mode "$PROFILE_DOCKER
export DX_PERSIST_STORAGE=bogus"
out="$(profile_run bogus-mode)"
if ! has "$out" "rc=0" && has "$out" "DX_PERSIST_STORAGE" && ! has "$out" "unknown configuration field"; then
    test_pass "dx-profile rejects a bogus DX_PERSIST_STORAGE naming the field"
else test_fail "dx-profile rejects a bogus DX_PERSIST_STORAGE naming the field"; printf "%s\n" "$out" | tail -n 6; fi

# --- Every tracked profile still validates ---------------------------------
tracked=0
for f in "$BASE_DIR"/tests/profiles/*.env; do
    name="$(basename "$f" .env)"
    tracked=$((tracked + 1))
    out="$(env -i HOME="$fixture/home" PATH="$tools:/usr/bin:/bin" DX_PROFILES_DIR="$BASE_DIR/tests/profiles" \
        "$BASE_DIR/bin/dx-profile" "$name" /usr/bin/env 2>&1; echo "rc=$?")"
    if has "$out" "rc=0" && has "$out" "DX_PERSIST_STORAGE=volume"; then
        test_pass "tracked profile $name validates and resolves to DX_PERSIST_STORAGE=volume"
    else test_fail "tracked profile $name validates and resolves to DX_PERSIST_STORAGE=volume"; printf "%s\n" "$out" | tail -n 6; fi
done
[ "$tracked" -ge 5 ] && test_pass "tracked profile set is non-empty ($tracked)" || test_fail "tracked profile set is non-empty ($tracked)"

print_summary
exit_with_code
