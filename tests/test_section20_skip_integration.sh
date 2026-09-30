#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
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

# Regression: container_is_running/container_exists must not report a real
# match as "not found" under set -o pipefail.
#
# dx_container_list_names captures the whole `container list [-a] --quiet`
# output into a variable, then re-emits it with a single
# `printf '%s\n' "$output"` into the pipe that container_exists/
# container_is_running read with `grep -F -x -q`. `grep -q` stops reading and
# closes its end of the pipe as soon as it finds a match; if printf still has
# unwritten output queued (because the captured list is bigger than the pipe
# buffer), its next write() gets EPIPE ("printf: write error: Broken pipe"),
# and under `set -o pipefail` -- true for every caller here, e.g.
# bin/dx-wait-ssh -- that failure, not grep's success, becomes the pipeline's
# exit status: a real match reported as absent. See tests/test_helpers.sh's
# stdin_matches comment for the general shape of this bug; this is
# bin/lib/dx-container.sh's own copy of it, observed for real during a Step 4
# bring-up (dxe-recovery/progress/logs/step4-bringup.log lines 52, 67-68):
# dx-wait-ssh reported "Container dx-test stopped before SSH became
# responsive" while the guest was in fact running and bootstrapping.
#
# Reproduce deterministically with a stub `container` whose `list`/`list -a`
# output puts the target name FIRST, then tens of thousands of filler lines --
# enough that the captured output exceeds the pipe buffer and grep is certain
# to have exited (and closed the pipe) before printf finishes writing the
# rest.
BIGLIST_STUB_DIR="$(mktemp -d -t dxe-biglist-stub-bin.XXXXXX)"
BIGLIST_TARGET="dxe-biglist-target-$$"
BIGLIST_ABSENT="dxe-biglist-absent-$$"
BIGLIST_FILLER_LINES=20000

cleanup_biglist_stub_dir() {
    rm -rf "$BIGLIST_STUB_DIR"
}
trap 'cleanup_stub_dir; cleanup_biglist_stub_dir' EXIT

cat > "$BIGLIST_STUB_DIR/container" <<STUBEOF
#!/bin/bash
case "\$1" in
    list)
        printf '%s\n' "$BIGLIST_TARGET"
        i=1
        while [ "\$i" -le $BIGLIST_FILLER_LINES ]; do
            printf 'other-%d\n' "\$i"
            i=\$((i + 1))
        done
        ;;
esac
exit 0
STUBEOF
chmod +x "$BIGLIST_STUB_DIR/container"

# Call container_is_running/container_exists from a fresh subshell with
# pipefail on and the big-list stub first on PATH, so the pipe inside the
# library function is the one under test rather than anything in this test
# script's own pipeline.
biglist_is_running() (
    set -o pipefail
    PATH="$BIGLIST_STUB_DIR:$PATH"
    source "$BASE_DIR/bin/lib/dx-container.sh"
    container_is_running "$1"
)
biglist_exists() (
    set -o pipefail
    PATH="$BIGLIST_STUB_DIR:$PATH"
    source "$BASE_DIR/bin/lib/dx-container.sh"
    container_exists "$1"
)

if biglist_is_running "$BIGLIST_TARGET"; then
    test_pass "container_is_running finds a match past a large stub list under pipefail"
else
    test_fail "container_is_running finds a match past a large stub list under pipefail"
fi

if biglist_exists "$BIGLIST_TARGET"; then
    test_pass "container_exists finds a match past a large stub list under pipefail"
else
    test_fail "container_exists finds a match past a large stub list under pipefail"
fi

if biglist_is_running "$BIGLIST_ABSENT"; then
    test_fail "container_is_running correctly reports an absent name as not running"
else
    test_pass "container_is_running correctly reports an absent name as not running"
fi

if biglist_exists "$BIGLIST_ABSENT"; then
    test_fail "container_exists correctly reports an absent name as not existing"
else
    test_pass "container_exists correctly reports an absent name as not existing"
fi

# Regression: tests/test_helpers.sh's own requires_container has the same
# grep -q-under-pipefail shape Branch 4a fixed in bin/lib/dx-container.sh's
# container_is_running/container_exists above. requires_container pipes
# `container list --quiet` into `grep -F -x -q`, even though this same file
# defines set -uo pipefail at its own top and already documents the pitfall
# via the stdin_matches comment. A caller under pipefail (or requires_container
# itself, sourced into a pipefail script) can read a real match as "not
# running" and skip live checks that should have run.
#
# Reuse the big-list stub from above: DX_CONTAINER_NAME set to the target
# that is really first in a 20,000-line `container list --quiet` output must
# be reported as present (no skip), and an absent name must still skip.
requires_container_reports_running() (
    set -o pipefail
    PATH="$BIGLIST_STUB_DIR:$PATH"
    # requires_container is defined in the separately-sourced test_helpers.sh,
    # so ShellCheck can't see it read this global; the inline VAR=val prefix
    # (matching this file's own sanity_out/sanity_out_a calls above) keeps
    # the assignment and its one consumer on the same statement instead of a
    # separate one SC2034 would flag as unused.
    DX_CONTAINER_NAME="$BIGLIST_TARGET" requires_container >/dev/null 2>&1
)
requires_container_reports_absent() (
    set -o pipefail
    PATH="$BIGLIST_STUB_DIR:$PATH"
    DX_CONTAINER_NAME="$BIGLIST_ABSENT" requires_container >/dev/null 2>&1
)

if requires_container_reports_running; then
    test_pass "requires_container finds a real match past a large stub list under pipefail"
else
    test_fail "requires_container finds a real match past a large stub list under pipefail"
fi

if requires_container_reports_absent; then
    test_fail "requires_container correctly skips for an absent container name"
else
    test_pass "requires_container correctly skips for an absent container name"
fi

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
    # DXE_TEST_RESULTS="" (not merely inherited) is deliberate, not
    # incidental: tests/lib/harness.sh's own header explains that its
    # lazy-create/export design is safe only because "the runner itself
    # never records one" before forwarding to `bash "$test_file"` -- an
    # invariant tests/run_all_tests.sh honours but THIS script does not,
    # since the sanity/biglist/requires_container cases above already
    # called test_pass/test_fail and so already exported DXE_TEST_RESULTS
    # pointing at THIS suite's own results file before we ever get here.
    # Without the override below, section_file inherits that same path,
    # appends its cases onto our file, and its own exit_with_code/finish
    # deletes it out from under us as its last step -- so an unrelated
    # earlier fail (or even just our own prior pass lines) leaks into
    # section_file's pass/fail tally, and our own later print_summary
    # under-counts whatever it recreates after the deletion. Reproduced
    # directly: with tests/test_section16_persist_storage.sh's now-fixed
    # config-registry assertion still broken, this exact leak made
    # test_section17_dx_ai_runtime.sh exit 1 with zero failing cases of its
    # own, and made "a dispatchable --section still runs" below fail too.
    DXE_TEST_RESULTS="" \
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

# A --section the runner cannot dispatch must fail, not report success over an
# empty run. tests/run-tier.sh selects whole tiers by section number, so a
# silent no-op would let a tier shrink to nothing while CI still went green --
# the same "reports success without doing the work" failure this section exists
# to catch.
#
# DXE_TEST_RESULTS="" below, same reasoning as run_section_under_skip above:
# by this point our own preamble cases have already exported it pointing at
# THIS suite's results file, and --section=1 really does dispatch a whole
# suite (unlike --section=nonexistent, which errors out before sourcing
# test_helpers.sh at all) that would otherwise inherit and delete it.
unknown_output="$(DXE_TEST_RESULTS="" "$SCRIPT_DIR/run_all_tests.sh" --skip-integration --section=nonexistent 2>&1)"
unknown_status=$?
if [ "$unknown_status" -ne 0 ] && ! printf '%s' "$unknown_output" | stdin_matches 'All tests PASSED'; then
    test_pass "unknown --section fails instead of reporting an empty success"
else
    test_fail "unknown --section fails instead of reporting an empty success (status $unknown_status)"
fi

# The guard must not reject sections the runner really does dispatch.
if DXE_TEST_RESULTS="" "$SCRIPT_DIR/run_all_tests.sh" --skip-integration --section=1 >/dev/null 2>&1; then
    test_pass "a dispatchable --section still runs"
else
    test_fail "a dispatchable --section still runs"
fi

print_summary
exit_with_code
