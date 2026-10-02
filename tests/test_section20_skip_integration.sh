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
        case " $* " in
            *" --quiet "*) printf "%s\n" "$DX_CONTAINER_NAME" ;;
            *) printf "%s running\n" "$DX_CONTAINER_NAME" ;;
        esac
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
    SKIP_INTEGRATION=false DX_SSH_PORT=2399 DX_CONTAINER_NAME="$BIGLIST_TARGET" requires_container >/dev/null 2>&1
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

# --- The tests/run.sh --section/--file incident: --section/--file used to
# inherit SKIP_INTEGRATION from the CALLER's shell (WP1.4's own
# `${SKIP_INTEGRATION:-false}` design, section 20's own header above), so a
# bare `bash tests/run.sh --section 17` on a developer machine -- with
# SKIP_INTEGRATION simply unset, the ordinary state of an interactive shell --
# ran section 17's live dx-ai-in-guest case for real. The fix: --section,
# --file, --tier unit and --tier host-contract now force SKIP_INTEGRATION=true
# regardless of the environment unless a new --live flag is given; --tier
# live/destructive imply --live; and an environment SKIP_INTEGRATION=false
# given without --live is refused rather than silently honoured, so the old
# inherited path cannot be reached by accident either way. These cases drive
# the real runner (tests/run.sh) rather than a section file directly, reusing
# this file's own stub PATH/FAKE_CONTAINER_NAME from above so that even a
# still-broken runner cannot reach a real container here.

# Case 1: `--section 17` with SKIP_INTEGRATION unset in the environment (the
# incident's exact shape) must still make section 17 report its integration
# skip line, never reach requires_container/wait_for_ssh/guest work.
runsh_unset_marker="$(mktemp -t dxe-stub-marker-runsh-unset.XXXXXX)"
rm -f "$runsh_unset_marker"
runsh_unset_out="$(DXE_TEST_RESULTS="" DXE_STUB_MARKER="$runsh_unset_marker" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" PATH="$STUB_DIR:$PATH" env -u SKIP_INTEGRATION bash "$SCRIPT_DIR/run.sh" --section 17 2>&1)"
if printf '%s' "$runsh_unset_out" | stdin_matches -F 'dx-ai guest runtime checks'; then
    test_pass "tests/run.sh --section 17 with SKIP_INTEGRATION unset in the environment reports its integration skip line"
else
    test_fail "tests/run.sh --section 17 with SKIP_INTEGRATION unset in the environment reports its integration skip line (output: $runsh_unset_out)"
fi
if [ ! -s "$runsh_unset_marker" ]; then
    test_pass "tests/run.sh --section 17 with SKIP_INTEGRATION unset invokes no container/ssh/scp/dx-ai command"
else
    test_fail "tests/run.sh --section 17 with SKIP_INTEGRATION unset invokes no container/ssh/scp/dx-ai command (recorded: $(tr '\n' ';' < "$runsh_unset_marker"))"
fi
rm -f "$runsh_unset_marker"

# Case 2: --live is the explicit opt-in that must actually flip
# SKIP_INTEGRATION to false for the child suite. Asserted with a tiny fixture
# suite that just echoes the variable it was handed -- not by running a real
# live suite -- but the fixture still needs the `# tier:`/`# bash32:` header
# tests/run.sh's own suite_has_valid_tier check requires of every selected
# file, --file included.
probe_dir="$(mktemp -d -t dxe-run-sh-live-probe.XXXXXX)"
probe_file="$probe_dir/test_skip_integration_probe.sh"
# Built with printf rather than a literal heredoc so this suite's OWN source
# text never contains a contiguous `# tier: `/`# bash32: ` line: those two
# header lines are exactly what tests/test_refactor_contracts.sh's WP1.4
# contract greps for, over the WHOLE file, to prove every real tests/test_*.sh
# carries exactly one of each -- a literal fixture header here would be
# double-counted against THIS file's own real header the same way that
# contract's own self-reference comment already documents for its own
# fixtures (it excludes only itself from that scan).
{
    printf '#!/bin/bash\n'
    printf '%s tier: unit\n' '#'
    printf '%s bash32: no\n' '#'
    printf 'echo "SKIP_INTEGRATION=${SKIP_INTEGRATION:-unset}"\n'
    printf 'exit 0\n'
} > "$probe_file"
chmod +x "$probe_file"

probe_live_out="$(DXE_TEST_RESULTS="" bash "$SCRIPT_DIR/run.sh" --live --file "$probe_file" 2>&1)"
if printf '%s' "$probe_live_out" | stdin_matches -F -x 'SKIP_INTEGRATION=false'; then
    test_pass "tests/run.sh --live --file sets SKIP_INTEGRATION=false for the child suite"
else
    test_fail "tests/run.sh --live --file sets SKIP_INTEGRATION=false for the child suite (output: $probe_live_out)"
fi

probe_no_live_out="$(DXE_TEST_RESULTS="" env -u SKIP_INTEGRATION bash "$SCRIPT_DIR/run.sh" --file "$probe_file" 2>&1)"
if printf '%s' "$probe_no_live_out" | stdin_matches -F -x 'SKIP_INTEGRATION=true'; then
    test_pass "tests/run.sh --file with no --live forces SKIP_INTEGRATION=true for the child suite"
else
    test_fail "tests/run.sh --file with no --live forces SKIP_INTEGRATION=true for the child suite (output: $probe_no_live_out)"
fi
rm -rf "$probe_dir"

# Case 3: an explicit SKIP_INTEGRATION=false in the environment WITHOUT --live
# must be refused loudly (exit 2, naming --live) rather than silently
# honoured, so a caller who sets the variable on purpose but forgets the new
# flag cannot reach the old inherited path either. Still driven through the
# stub PATH/FAKE_CONTAINER_NAME: a still-broken runner would otherwise run
# section 17's live case for real with SKIP_INTEGRATION=false exactly as
# case 1 above demonstrates.
refuse_marker="$(mktemp -t dxe-stub-marker-runsh-refuse.XXXXXX)"
rm -f "$refuse_marker"
refuse_out="$(DXE_TEST_RESULTS="" DXE_STUB_MARKER="$refuse_marker" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" PATH="$STUB_DIR:$PATH" SKIP_INTEGRATION=false bash "$SCRIPT_DIR/run.sh" --section 17 2>&1)"
refuse_status=$?
if [ "$refuse_status" -eq 2 ]; then
    test_pass "SKIP_INTEGRATION=false without --live exits 2"
else
    test_fail "SKIP_INTEGRATION=false without --live exits 2 (got $refuse_status)"
fi
if printf '%s' "$refuse_out" | stdin_matches -F -- '--live'; then
    test_pass "SKIP_INTEGRATION=false without --live names --live in its error"
else
    test_fail "SKIP_INTEGRATION=false without --live names --live in its error (output: $refuse_out)"
fi
if [ ! -s "$refuse_marker" ]; then
    test_pass "SKIP_INTEGRATION=false without --live invokes no container/ssh/scp/dx-ai command"
else
    test_fail "SKIP_INTEGRATION=false without --live invokes no container/ssh/scp/dx-ai command (recorded: $(tr '\n' ';' < "$refuse_marker"))"
fi
rm -f "$refuse_marker"

# --- Live-tail guard (fix/live-tail-guards, increment 1): only an explicit
# SKIP_INTEGRATION=false enables a unit-tier file's live tail. The old
# `${SKIP_INTEGRATION:-false}` default meant a file invoked DIRECTLY (not via
# tests/run.sh, which forces the variable) with it unset ran its tail against
# whatever guest the registry default named. These cases use only this file's
# stub PATH and fake container name, so even a broken guard reaches no real
# guest; the marker records any container/ssh/scp/dx-ai call.

live_probe() {
    # live_probe <marker> <skip-integration-setting: unset|true|false|other> <probe body>
    local marker="$1" setting="$2" body="$3"
    if [ "$setting" = unset ]; then
        DXE_TEST_RESULTS="" DXE_STUB_MARKER="$marker" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" DX_SSH_PORT=2399 \
            PATH="$STUB_DIR:$PATH" env -u SKIP_INTEGRATION \
            bash -c 'source "$1/test_helpers.sh" >/dev/null 2>&1; '"$body" _ "$SCRIPT_DIR" 2>&1
    else
        DXE_TEST_RESULTS="" DXE_STUB_MARKER="$marker" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" DX_SSH_PORT=2399 \
            PATH="$STUB_DIR:$PATH" SKIP_INTEGRATION="$setting" \
            bash -c 'source "$1/test_helpers.sh" >/dev/null 2>&1; '"$body" _ "$SCRIPT_DIR" 2>&1
    fi
}

for setting in unset true other; do
    lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
    rm -f "$lt_marker"
    lt_out="$(live_probe "$lt_marker" "$setting" 'live_tail_enabled; echo "enabled=$?"')"
    if printf '%s' "$lt_out" | stdin_matches -F -x 'enabled=1'; then
        test_pass "live_tail_enabled is false when SKIP_INTEGRATION is $setting"
    else
        test_fail "live_tail_enabled is false when SKIP_INTEGRATION is $setting (output: $lt_out)"
    fi
    lt_out="$(live_probe "$lt_marker" "$setting" 'requires_container; echo "rc=$?"; wait_for_ssh 1; echo "wait=$?"')"
    if printf '%s' "$lt_out" | stdin_matches -F -x 'rc=1' && printf '%s' "$lt_out" | stdin_matches -F -x 'wait=1' && [ ! -s "$lt_marker" ]; then
        test_pass "requires_container and wait_for_ssh refuse and call nothing when SKIP_INTEGRATION is $setting"
    else
        test_fail "requires_container and wait_for_ssh refuse and call nothing when SKIP_INTEGRATION is $setting (output: $lt_out; recorded: $(tr '\n' ';' < "$lt_marker" 2>/dev/null))"
    fi
    rm -f "$lt_marker"
done

lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
rm -f "$lt_marker"
lt_out="$(live_probe "$lt_marker" false 'live_tail_enabled; echo "enabled=$?"; requires_container; echo "rc=$?"')"
if printf '%s' "$lt_out" | stdin_matches -F -x 'enabled=0' && printf '%s' "$lt_out" | stdin_matches -F -x 'rc=0' && stdin_matches -F 'container list' < "$lt_marker"; then
    test_pass "SKIP_INTEGRATION=false enables the live tail (requires_container reaches the stub container)"
else
    test_fail "SKIP_INTEGRATION=false enables the live tail (output: $lt_out; recorded: $(tr '\n' ';' < "$lt_marker" 2>/dev/null))"
fi
rm -f "$lt_marker"

# A unit-tier file invoked directly (no runner) with SKIP_INTEGRATION unset
# must skip its tail without touching container/ssh/scp/dx-ai.
for lt_file in test_section17_dx_ai_runtime.sh test_section7_lazyvim.sh test_section4_ssh.sh; do
    lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
    rm -f "$lt_marker"
    DXE_TEST_RESULTS="" DXE_STUB_MARKER="$lt_marker" DX_CONTAINER_NAME="$FAKE_CONTAINER_NAME" \
        PATH="$STUB_DIR:$PATH" env -u SKIP_INTEGRATION bash "$SCRIPT_DIR/$lt_file" >/dev/null 2>&1
    if [ ! -s "$lt_marker" ]; then
        test_pass "$lt_file run directly with SKIP_INTEGRATION unset invokes no container/ssh/scp/dx-ai command"
    else
        test_fail "$lt_file run directly with SKIP_INTEGRATION unset invokes no container/ssh/scp/dx-ai command (recorded: $(tr '\n' ';' < "$lt_marker"))"
    fi
    rm -f "$lt_marker"
done

# --- Live-tail guard (increment 2): even when enabled, never the default
# guest. The registry default name (read from bin/lib/dx-config.sh, not a
# second copy) or the registry default port is refused with a test_fail that
# names the disposable fixture, and no container/ssh/scp/dx-ai call happens.
default_name="$(DX_PROJECT_ROOT="$SCRIPT_DIR/.." bash -c 'source "$1/bin/lib/dx-config.sh"; dx_config_default DX_CONTAINER_NAME' _ "$SCRIPT_DIR/..")"
default_port="$(DX_PROJECT_ROOT="$SCRIPT_DIR/.." bash -c 'source "$1/bin/lib/dx-config.sh"; dx_config_default DX_SSH_PORT' _ "$SCRIPT_DIR/..")"
for lt_case in "name:DX_CONTAINER_NAME=$default_name" "port:DX_SSH_PORT=$default_port"; do
    lt_label="${lt_case%%:*}"
    lt_assign="${lt_case#*:}"
    lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
    rm -f "$lt_marker"
    lt_out="$(live_probe "$lt_marker" false "$lt_assign; live_tail_enabled; echo \"enabled=\$?\"; requires_container; echo \"rc=\$?\"; wait_for_ssh 1; echo \"wait=\$?\"")"
    if printf '%s' "$lt_out" | stdin_matches -F -x 'enabled=1' \
        && printf '%s' "$lt_out" | stdin_matches -F -x 'rc=1' \
        && printf '%s' "$lt_out" | stdin_matches -F -x 'wait=1' \
        && printf '%s' "$lt_out" | stdin_matches -F 'FAIL' \
        && printf '%s' "$lt_out" | stdin_matches -F './bin/dx-profile dx-test tests/run.sh --live' \
        && [ ! -s "$lt_marker" ]; then
        test_pass "an enabled live tail refuses the registry default $lt_label and calls nothing"
    else
        test_fail "an enabled live tail refuses the registry default $lt_label and calls nothing (output: $lt_out; recorded: $(tr '\n' ';' < "$lt_marker" 2>/dev/null))"
    fi
    rm -f "$lt_marker"
done

# The dx-test fixture profile (profiles dir = tests/profiles) proceeds, both
# directly and through the real runner exactly as the coordinator invokes the
# Apple live tier: ./bin/dx-profile dx-test tests/run.sh --live ...
lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
rm -f "$lt_marker"
lt_out="$(DXE_TEST_RESULTS="" DXE_STUB_MARKER="$lt_marker" PATH="$STUB_DIR:$PATH" SKIP_INTEGRATION=false \
    DX_PROFILES_DIR="$SCRIPT_DIR/profiles" "$SCRIPT_DIR/../bin/dx-profile" dx-test \
    bash -c 'source "$1/test_helpers.sh" >/dev/null 2>&1; live_tail_enabled; echo "enabled=$?"; requires_container; echo "rc=$?"' _ "$SCRIPT_DIR" 2>&1)"
if printf '%s' "$lt_out" | stdin_matches -F -x 'enabled=0' && printf '%s' "$lt_out" | stdin_matches -F -x 'rc=0' && stdin_matches -F 'container list' < "$lt_marker"; then
    test_pass "the dx-test fixture profile passes the default-guest guard"
else
    test_fail "the dx-test fixture profile passes the default-guest guard (output: $lt_out)"
fi
rm -f "$lt_marker"

lt_probe_dir="$(mktemp -d -t dxe-run-sh-live-guard.XXXXXX)"
lt_probe="$lt_probe_dir/test_live_guard_probe.sh"
{
    printf '#!/bin/bash\n'
    printf '%s tier: unit\n' '#'
    printf '%s bash32: no\n' '#'
    printf 'source "%s/test_helpers.sh" >/dev/null 2>&1\n' "$SCRIPT_DIR"
    printf 'requires_container; echo "probe-rc=$?"\n'
    printf 'exit 0\n'
} > "$lt_probe"
chmod +x "$lt_probe"
lt_marker="$(mktemp -t dxe-stub-marker-lt.XXXXXX)"
rm -f "$lt_marker"
lt_out="$(DXE_TEST_RESULTS="" DXE_STUB_MARKER="$lt_marker" PATH="$STUB_DIR:$PATH" env -u SKIP_INTEGRATION \
    DX_PROFILES_DIR="$SCRIPT_DIR/profiles" "$SCRIPT_DIR/../bin/dx-profile" dx-test \
    bash "$SCRIPT_DIR/run.sh" --live --file "$lt_probe" 2>&1)"
if printf '%s' "$lt_out" | stdin_matches -F -x 'probe-rc=0'; then
    test_pass "./bin/dx-profile dx-test tests/run.sh --live reaches the live tail"
else
    test_fail "./bin/dx-profile dx-test tests/run.sh --live reaches the live tail (output: $lt_out)"
fi
# "No profile" must mean registry defaults even when THIS suite itself runs
# under a profile (./bin/dx-profile dx-test tests/run_all_tests.sh --live
# exports the whole resolved-config snapshot): start from an empty
# environment, carrying only what the inner run needs.
lt_out="$(env -i PATH="$STUB_DIR:$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    DXE_TEST_RESULTS="" DXE_STUB_MARKER="$lt_marker" \
    bash "$SCRIPT_DIR/run.sh" --live --file "$lt_probe" 2>&1)"
if printf '%s' "$lt_out" | stdin_matches -F -x 'probe-rc=1' && printf '%s' "$lt_out" | stdin_matches -F 'FAIL'; then
    test_pass "tests/run.sh --live without a profile (default guest) is refused"
else
    test_fail "tests/run.sh --live without a profile (default guest) is refused (output: $lt_out)"
fi
rm -rf "$lt_probe_dir" "$lt_marker"

print_summary
exit_with_code
