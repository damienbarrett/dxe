#!/bin/bash
# Section 20: --skip-integration Truthfulness
#
# Sections 15, 16, and 17 each self-gate their live guest work behind
# requires_container (running-container check), but only sections 5 and 11-12
# ever checked SKIP_INTEGRATION before that self-gate. That means
# `run_all_tests.sh --skip-integration` still performed live SSH/SCP/container
# work in those three sections whenever a guest happened to be running.
#
# This test proves the fix behaviourally rather than by grepping source: it
# shadows `container`, `ssh`, `scp`, and `dx-ai` on PATH with stub executables
# that record every invocation to a marker file, makes the stub `container`
# report a (fake, never-real) container as running so the requires_container
# self-gate would pass, then runs each real section script with
# SKIP_INTEGRATION=true. If the section's SKIP_INTEGRATION check fires before
# the self-gate (the fix), the marker stays empty. If the self-gate is
# consulted first and live work proceeds (the bug), the marker is populated.
#
# Safety: the stub `container` binary is first on PATH for these subprocesses
# and is never the real `container` CLI, so nothing here can list, inspect, or
# touch a real dx-host/dx-test container, volume, or key -- regardless of
# what the stub reports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 20: --skip-integration Truthfulness"

STUB_DIR="$(mktemp -d -t dxe-stub-bin.XXXXXX)"
FAKE_CONTAINER_NAME="dxe-stub-fake-container-$$"

cleanup_stub_dir() {
    rm -rf "$STUB_DIR"
}
trap cleanup_stub_dir EXIT

write_stub() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Records every invocation. On `list` (with or without `-a`), prints the fake
# container name as running/existing so container_is_running/container_exists
# in bin/dx-lib.sh -- which both just awk the first field of `container list`
# -- report a match without ever calling the real `container` CLI.
write_stub "container" '
printf "container %s\n" "$*" >> "$DXE_STUB_MARKER"
case "${1:-}" in
    list)
        printf "%s running\n" "$DX_CONTAINER_NAME"
        ;;
esac
exit 0
'

write_stub "ssh" '
printf "ssh %s\n" "$*" >> "$DXE_STUB_MARKER"
exit 0
'

write_stub "scp" '
printf "scp %s\n" "$*" >> "$DXE_STUB_MARKER"
exit 0
'

write_stub "dx-ai" '
printf "dx-ai %s\n" "$*" >> "$DXE_STUB_MARKER"
exit 0
'

# Sanity-check the stub against the real predicates in bin/dx-lib.sh before
# trusting it to drive the sections below.
SANITY_MARKER="$(mktemp -t dxe-stub-marker-sanity.XXXXXX)"
rm -f "$SANITY_MARKER"

sanity_out="$(DXE_STUB_MARKER="$SANITY_MARKER" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" PATH="$STUB_DIR:$PATH" container list | awk '{print $1}')"
if [ "$sanity_out" = "$FAKE_CONTAINER_NAME" ]; then
    test_pass "stub container binary satisfies container_is_running's parsing of \`container list\`"
else
    test_fail "stub container binary satisfies container_is_running's parsing of \`container list\` (got '$sanity_out')"
fi

sanity_out_a="$(DXE_STUB_MARKER="$SANITY_MARKER" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" PATH="$STUB_DIR:$PATH" container list -a | awk '{print $1}')"
if [ "$sanity_out_a" = "$FAKE_CONTAINER_NAME" ]; then
    test_pass "stub container binary satisfies container_exists's parsing of \`container list -a\`"
else
    test_fail "stub container binary satisfies container_exists's parsing of \`container list -a\` (got '$sanity_out_a')"
fi
rm -f "$SANITY_MARKER"

# Run one real section script under SKIP_INTEGRATION=true with the stub PATH
# and fake (always "running") container name, then assert it did no guest
# work and exited cleanly.
run_section_under_skip() {
    local section_file="$1"
    local label="$2"
    local marker rc

    marker="$(mktemp -t dxe-stub-marker.XXXXXX)"
    rm -f "$marker"

    rc=0
    DXE_STUB_MARKER="$marker" \
        DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" \
        PATH="$STUB_DIR:$PATH" \
        SKIP_INTEGRATION=true \
        bash "$section_file" >/dev/null 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
        test_pass "$label exits 0 under --skip-integration"
    else
        test_fail "$label exits 0 under --skip-integration (exit $rc)"
    fi

    if [ ! -s "$marker" ]; then
        test_pass "$label invokes no container/ssh/scp/dx-ai command under --skip-integration"
    else
        test_fail "$label invokes no container/ssh/scp/dx-ai command under --skip-integration (recorded: $(tr '\n' ';' < "$marker"))"
    fi

    rm -f "$marker"
}

run_section_under_skip "$SCRIPT_DIR/test_section15_nushell_env.sh" "section 15"
run_section_under_skip "$SCRIPT_DIR/test_section16_persist_storage.sh" "section 16"
run_section_under_skip "$SCRIPT_DIR/test_section17_dx_ai_runtime.sh" "section 17"

print_summary
exit_with_code
