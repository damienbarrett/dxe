#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.3: in-process coverage of the /persist create-spec helpers.
# tests/test_persist_dir_mount.sh drives bin/dx-create-container from `env -i`
# children, which kcov cannot trace; this suite calls the helpers in this
# process so the new lines in bin/lib/dx-container.sh are measured.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"

test_section "WP3.3: persist create-spec helpers (in-process)"

DX_CONTAINER_NAME=dx-fix DX_PERSIST_VOLUME=dx-fix-persist DX_PERSIST_HOST_ROOT=/fixture-root

got="$(DX_PERSIST_STORAGE=volume dx_persist_create_volume_spec)"
[ "$got" = 'persist:dx-fix-persist:/persist:rw' ] \
    && test_pass "volume mode keeps the named persist volume spec" \
    || test_fail "volume mode keeps the named persist volume spec (got: $got)"
got="$(unset DX_PERSIST_STORAGE; dx_persist_create_volume_spec)"
[ "$got" = 'persist:dx-fix-persist:/persist:rw' ] \
    && test_pass "an unset mode is volume mode" \
    || test_fail "an unset mode is volume mode (got: $got)"
got="$(DX_PERSIST_STORAGE=host-path dx_persist_create_volume_spec)"
[ "$got" = 'persist-dir:/fixture-root/dxe/dx-fix/persist:/persist:rw' ] \
    && test_pass "host-path mode derives <root>/dxe/<guest>/persist as a persist-dir spec" \
    || test_fail "host-path mode derives <root>/dxe/<guest>/persist as a persist-dir spec (got: $got)"

CREATE_ARGS=(--name x)
DX_PERSIST_STORAGE=volume dx_persist_create_env_args
[ "${CREATE_ARGS[*]}" = '--name x' ] \
    && test_pass "volume mode appends no guest variables" \
    || test_fail "volume mode appends no guest variables (got: ${CREATE_ARGS[*]})"
DX_PERSIST_STORAGE=host-path dx_persist_create_env_args
[ "${CREATE_ARGS[*]}" = '--name x --env DX_PERSIST_STORAGE=host-path --env DX_PERSIST_DIR_GUEST=dx-fix' ] \
    && test_pass "host-path mode appends DX_PERSIST_STORAGE and DX_PERSIST_DIR_GUEST" \
    || test_fail "host-path mode appends DX_PERSIST_STORAGE and DX_PERSIST_DIR_GUEST (got: ${CREATE_ARGS[*]})"

print_summary
exit_with_code
