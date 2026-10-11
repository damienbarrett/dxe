#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.2 implementer cases the acceptance suite (test_persist_rsync_ops.sh)
# does not pin: a newline in the NAS directory is refused before any call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "WP6.2: a newline in the rsync directory is refused"
TOOLS="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rsync-unit.XXXXXX")"
trap 'rm -f "$TOOLS/calls" "$TOOLS/ssh" "$TOOLS/docker" "$TOOLS/err"; rmdir "$TOOLS"' EXIT
for t in ssh docker; do
    printf '#!/bin/sh\necho %s >> "%s/calls"\nexit 99\n' "$t" "$TOOLS" >"$TOOLS/$t"
    chmod +x "$TOOLS/$t"
done
: >"$TOOLS/calls"
export DXE_RUNTIME_DOCKER_BIN="$TOOLS/docker" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
export DX_IMAGE=img:1 DX_PERSIST_VOLUME=dx-fix-persist
nl=$'\n'
out="$(PATH="$TOOLS:$PATH" dx_runtime_host_rsync forward dx-fix-persist "/share/a${nl}b" 2>"$TOOLS/err")"
rc=$?
if [ "$rc" != 0 ]; then test_pass "refused"; else test_fail "refused"; fi
if [ -z "$out" ]; then test_pass "nothing on stdout"; else test_fail "nothing on stdout"; fi
if grep -Fq "Error:" "$TOOLS/err"; then test_pass "Error: line"; else test_fail "Error: line"; fi
rm -f "$TOOLS/err"
if [ ! -s "$TOOLS/calls" ]; then test_pass "no ssh or docker call"; else test_fail "no ssh or docker call"; fi

print_summary
exit_with_code
