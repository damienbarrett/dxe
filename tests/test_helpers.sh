#!/bin/bash
# tier: unit
# bash32: yes
# Test helper functions for DX Experience tests

# No `set -uo pipefail` here (Fable D4 / WP1.6): this file is SOURCED, not
# executed, into every suite that calls it, and a sourced file's `set`
# changes the CALLING shell's own control state -- exactly the import-
# purity violation tests/test_refactor_contracts.sh's purity loop now
# actually catches (it used to be unable to see it at all; see that file's
# own WP1.6 history). Every suite that sources this file already sets both
# flags itself before doing so (confirmed by grep across every
# tests/test_*.sh that sources it), so nothing here needs to set them again
# -- and setting them again, in the sourced file, would silently overwrite
# whatever the caller chose (e.g. a suite that deliberately omits `-e` to
# capture a command's exit status by hand).

# Match stdin against a pattern without short-circuiting the writer.
#
# `writer | grep -q PATTERN` is unsafe in any script with `set -o pipefail`:
# grep -q exits at its *first* match, closing the pipe while the writer is
# still writing, so the writer dies of SIGPIPE (141) and pipefail promotes
# that to the pipeline's exit status. A *successful* match is then reported
# as failure. Whether it fires depends on the race between writer and reader,
# so the construct can pass for months and then fail deterministically after
# an unrelated environment change -- which is exactly what happened here,
# taking 16 assertions across four sections with it on an unmodified tree.
#
# Dropping -q keeps the exit status identical while making grep consume all
# of its input, so the writer is never signalled. Output is discarded here so
# callers need no redirection of their own and the fix is a drop-in rename.
#
# Guest-side probe scripts (tests/lib/tmux-probes.sh, container_exec_dx_bash
# blocks, run_guest strings) deliberately keep plain `grep -q`: they run in a
# fresh guest shell under `set -u` with no pipefail, so they are immune, and
# this helper does not exist over there.
stdin_matches() { grep "$@" >/dev/null; }

# Octal permission bits of a file, on either host. GNU coreutils and BSD stat
# disagree on both the flag and the format specifier, and these tests run on
# macOS locally and Ubuntu in CI, so neither spelling can be hardcoded.
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# A listing of every path under the REAL SSH known-hosts pin tree
# (dx_ssh_known_hosts_dir in dx-ssh-common.sh writes under
# "${XDG_STATE_HOME:-$HOME/.local/state}/dxe"), computed with THIS SHELL's
# own ambient HOME/XDG_STATE_HOME -- never call this from inside a subshell
# that has already overridden either variable to a fixture, or it silently
# snapshots the fixture instead of the real directory it exists to protect.
#
# Any test that drives dx_ssh_common_options/dx_ssh_known_hosts_prepare
# under DX_RUNTIME=docker-ssh MUST isolate HOME (or XDG_STATE_HOME) to its
# own fixture before doing so, AND call this helper once in the outer,
# unisolated shell before and once after, asserting the two listings are
# identical -- a fixture that fails to isolate still writes somewhere, and
# without this check it silently lands in the real directory instead of
# failing the test (exactly the incident this helper exists to catch).
dx_real_ssh_known_hosts_snapshot() {
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/dxe"
    # An absent directory is a legitimate, empty snapshot (the normal state
    # on a fresh runner/container/CI, before anything has ever pinned a
    # known-hosts file there) -- not an error. Without this guard, `find` on
    # a nonexistent path exits 1, and under a caller's `set -e` (several of
    # this function's callers have their own), the "$(...)" assignment
    # aborts the whole script instead of yielding an empty listing. Guarding
    # on the directory's existence, rather than swallowing find's own exit
    # status with `|| true`, still lets a real find error (e.g. a
    # permission problem on a directory that DOES exist) propagate.
    [ -d "$dir" ] || return 0
    find "$dir" -mindepth 1 2>/dev/null | sort
}

# Test counters. Kept and updated for backward compatibility (some suites
# or ad-hoc debugging may read them directly), but they are no longer the
# source of truth for print_summary/exit_with_code below: a test_pass/
# test_fail/test_skip call made inside a `( ... )` subshell or a background
# job still increments these in whatever shell made the call, and that
# increment dies with the subshell exactly as it always has. The results
# file tests/lib/harness.sh records to (WP1.1, Fable D1) does not have that
# problem -- an append survives the subshell -- which is why the actual
# pass/fail decision below is read from it instead.
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Base directory. Fable D4 / WP1.6: this file's OWN directory, under its
# own name (DXE_TESTS_DIR), never the caller's SCRIPT_DIR -- every suite
# that sources this file already sets its own SCRIPT_DIR to this exact
# same directory first (a repo-wide convention), so reassigning it here
# used to be invisible: the clobber and the caller's own value always
# coincided. That is precisely why the import-purity probe pins a
# SCRIPT_DIR canary rather than diffing the caller's ambient value -- and
# precisely why this file must never assign to SCRIPT_DIR at all.
DXE_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$DXE_TESTS_DIR/.." && pwd)"

# dx_test_guest_dir -- the single guest tree every suite's CONTAINER_DIR/
# FLAKE_*/BOOTSTRAP/CONTAINERFILE/SHELL_NIX below is derived from. A
# function, not a hardcoded path repeated at every call site, so a future
# rename of the architecture-named directory is a one-line change here.
dx_test_guest_dir() {
    printf '%s' "$BASE_DIR/container/dx-nixos-26.05"
}

CONTAINER_DIR="$(dx_test_guest_dir)"
FLAKE_NIX="$CONTAINER_DIR/flake.nix"
FLAKE_LOCK="$CONTAINER_DIR/flake.lock"
NIXVIM_NIX="$CONTAINER_DIR/nixvim.nix"
BOOTSTRAP="$CONTAINER_DIR/bootstrap.sh"
CONTAINERFILE="$CONTAINER_DIR/Containerfile"
SHELL_NIX="$CONTAINER_DIR/home/shell.nix"
export FLAKE_NIX FLAKE_LOCK NIXVIM_NIX BOOTSTRAP CONTAINERFILE SHELL_NIX
DX_EXPECTED_NIXOS_RELEASE="${DX_EXPECTED_NIXOS_RELEASE:-26.05}"
DX_EXPECTED_NIXOS_BRANCH="${DX_EXPECTED_NIXOS_BRANCH:-nixos-$DX_EXPECTED_NIXOS_RELEASE}"
DX_CONTAINER_NAME="${DX_CONTAINER_NAME:-dx-host}"
DX_SSH_PORT="${DX_SSH_PORT:-2222}"
# Fable D4 / WP1.6: this file no longer sources production code (the
# dx-host-util.sh library) -- tests/test_refactor_contracts.sh asserts
# that directly (a literal, comment-blind substring check, so this
# comment itself is careful not to spell out the path it forbids). A
# suite that needs one of that library's functions sources it itself,
# right after sourcing this file.

# tests/lib/harness.sh (WP1.1, Fable D1): the results-file recorder
# test_pass/test_fail/test_skip/print_summary/exit_with_code below are now
# shims over. Also supplies RED/GREEN/YELLOW/NC, so this file no longer
# defines its own copies.
# shellcheck source=lib/harness.sh
source "$DXE_TESTS_DIR/lib/harness.sh"

# Test assertion functions
assert_file_exists() {
    local file="$1"
    local message="${2:-File $file exists}"
    if [ -f "$file" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_not_exists() {
    local file="$1"
    local message="${2:-File $file does not exist}"
    if [ ! -f "$file" ]; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File $file contains '$pattern'}"
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_contains_literal() {
    local file="$1"
    local literal="$2"
    local message="${3:-File $file contains literal '$literal'}"
    if grep -Fq -- "$literal" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File $file does not contain '$pattern'}"
    if ! grep -q -- "$pattern" "$file" 2>/dev/null; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_grep_in_file() {
    local file="$1"
    local pattern="$2"
    local message="${3:-Pattern found in $file}"
    if [ -f "$file" ] && grep -Eq "$pattern" "$file"; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

assert_git_not_tracked() {
    local file="$1"
    local message="${2:-$file is not tracked by git}"
    if ! git -C "$BASE_DIR" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
        test_pass "$message"
    else
        test_fail "$message"
    fi
    return 0
}

# Test result functions -- shims over tests/lib/harness.sh (WP1.1, Fable
# D1). Each one still prints the exact colored line it always has (other
# tooling and humans read these) and still updates the TESTS_PASSED/
# TESTS_FAILED/TESTS_SKIPPED counters in the calling shell for backward
# compatibility, but the call this file's own print_summary/exit_with_code
# actually trust is _dxe_harness_record/skip's append to $DXE_TEST_RESULTS,
# which -- unlike these counters -- is still there to read even when the
# call was made inside a `( ... )` subshell or a background job.
test_pass() {
    local message="$1"
    echo -e "  ${GREEN}✓ PASS${NC}: $message"
    _dxe_harness_record pass "$message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local message="$1"
    echo -e "  ${RED}✗ FAIL${NC}: $message"
    _dxe_harness_record fail "$message"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_skip() {
    local message="$1"
    echo -e "  ${YELLOW}○ SKIP${NC}: $message"
    skip "$message"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

test_section() {
    local title="$1"
    echo ""
    echo -e "${YELLOW}=== $title ===${NC}"
}

# live_tail_enabled -- the one place that decides whether a unit-tier file's
# live tail (real guest work through requires_container / wait_for_ssh /
# dx-ssh) may run. Succeeds ONLY when SKIP_INTEGRATION is explicitly the
# string `false`; unset (an interactive shell, a file invoked directly rather
# than through tests/run.sh, which forces the variable), `true` or anything
# else means skip. The old `${SKIP_INTEGRATION:-false}` default let a direct
# `bash tests/test_section17_*.sh` reach whatever guest the registry default
# named (the user's primary guest). requires_container and wait_for_ssh call
# this first, so a file that forgets its own top-level check still cannot
# reach a guest.
live_tail_enabled() {
    [ "${SKIP_INTEGRATION-}" = false ] || return 1
    # Enabled: never let it be the user's default guest. The defaults come
    # from the config registry (via lib/registry-defaults.sh), so no
    # second copy of them exists here and no production code is sourced into
    # the suite. A profile (tests/profiles/dx-test.env) moves both off the
    # defaults. The refusal is a test_fail, recorded once per process.
    local default_name default_port
    # shellcheck source=lib/registry-defaults.sh
    source "$DXE_TESTS_DIR/lib/registry-defaults.sh"
    default_name="$(registry_default DX_CONTAINER_NAME)"
    default_port="$(registry_default DX_SSH_PORT)"
    if [ "$DX_CONTAINER_NAME" = "$default_name" ] || [ "$DX_SSH_PORT" = "$default_port" ]; then
        if [ -z "${DXE_LIVE_TAIL_REFUSED-}" ]; then
            DXE_LIVE_TAIL_REFUSED=1
            test_fail "Refusing live guest work against the default guest ($DX_CONTAINER_NAME, port $DX_SSH_PORT); use the disposable fixture: ./bin/dx-profile dx-test tests/run.sh --live ..."
        fi
        return 1
    fi
    return 0
}

# The invocation that legitimately runs live tails, for skip messages.
DXE_LIVE_TAIL_REFUSED=""
LIVE_TAIL_HINT="live tails run only via: ./bin/dx-profile dx-test tests/run.sh --live ..."

# Requires running container
#
# Uses stdin_matches (this file's own read-all idiom, see its comment above)
# rather than `grep -F -x -q` directly: every suite that sources this file
# sets its own `set -uo pipefail` (or `-euo pipefail`) before doing so, and
# a `grep -q` pipeline can read a real match as absent under pipefail the
# same way dx-container.sh's container_is_running/container_exists did
# before their fix (tests/test_section20_skip_integration.sh).
#
# Skips (returns 1, no container call) unless live_tail_enabled: only an
# explicit SKIP_INTEGRATION=false opts in to live work. Callers that need a
# real container match (section 20's requires_container cases) set
# SKIP_INTEGRATION=false around the call.
requires_container() {
    if ! live_tail_enabled; then
        # A refusal of the default guest already recorded its own test_fail.
        [ -n "$DXE_LIVE_TAIL_REFUSED" ] || test_skip "Live guest checks skipped (SKIP_INTEGRATION is not false; $LIVE_TAIL_HINT)"
        return 1
    fi
    if ! dxe_runtime_call dx_runtime_container_running "$DX_CONTAINER_NAME" 2>/dev/null; then
        test_skip "Container '$DX_CONTAINER_NAME' is not running"
        return 1
    fi
    return 0
}

# dxe_runtime_call FUNCTION [ARGS...] -- run one production, runtime-neutral
# function (the bin/dx-lib.sh facade: dx_runtime_container_running,
# dx_runtime_exec, dx_ssh_endpoint, ...) in a SUBSHELL, so the suite itself
# still sources no production code (WP1.6) yet asks the same adapter dispatch
# (DX_RUNTIME: apple or docker-ssh) that dx-status and every entrypoint use,
# rather than the Apple `container` CLI directly. A library that fails to
# load, or an unresolvable configuration, is a failure of the call (exit 2),
# never a pass.
dxe_runtime_call() {
    (
        # shellcheck source=/dev/null
        source "$BASE_DIR/bin/dx-lib.sh" >/dev/null 2>&1 || exit 2
        "$@"
    )
}

# guest_ssh_endpoint -- dx@<address> the guest's SSH server is reached at,
# resolved by the active runtime (Apple: loopback; docker-ssh: the NAS's
# discovered address), for suites that call ssh/scp themselves.
guest_ssh_endpoint() {
    dxe_runtime_call dx_ssh_endpoint
}

# Global failure tracker
GLOBAL_FAILED=0

# Wait for SSH to be available on the active profile port.
wait_for_ssh() {
    local timeout="${1:-180}"
    if ! live_tail_enabled; then
        echo "  Not waiting for the guest: live tail not enabled for this target ($LIVE_TAIL_HINT)."
        return 1
    fi
    echo "  Waiting for guest bootstrap (${DX_RUNTIME:-apple} runtime, SSH port $DX_SSH_PORT, up to ${timeout}s)..."
    if DX_SSH_WAIT_TIMEOUT="$timeout" "$BASE_DIR/bin/dx-wait-ssh"; then
        echo "  Guest bootstrap complete (authenticated SSH is responsive)."
        return 0
    fi
    echo "  Timeout waiting for authenticated SSH."
    return 1
}

guest_ssh() {
    "$BASE_DIR/bin/dx-ssh" "$@"
}

guest_bash() {
    guest_ssh "$1"
}

container_exec_dx() {
    dxe_runtime_call dx_runtime_exec -u dx "$DX_CONTAINER_NAME" "$@"
}

container_exec_dx_bash() {
    container_exec_dx bash -lc "$1"
}

# dxe_require_tmux_probes -- lazy, idempotent loader for
# tests/lib/tmux-probes.sh (Fable D4 / WP1.6): live-guest tmux probes
# (tmux_guest_probe and friends) that only two suites actually call
# (test_section6_tools.sh, test_section14_tinty_theming.sh) but every OTHER
# suite that sources this file used to pay to source anyway. Callers
# invoke this unconditionally near their own top, right after sourcing this
# file -- NOT gated behind requires_container: test_section6_tools.sh calls
# tmux_guest_resurrect_probe at unit tier against a fully faked
# container_exec_dx_bash, with no real container present, so gating this
# loader behind container discovery would make that unit-tier case fail to
# find the function it needs.
DXE_TMUX_PROBES_LOADED=""
dxe_require_tmux_probes() {
    if [ -z "$DXE_TMUX_PROBES_LOADED" ]; then
        # shellcheck source=lib/tmux-probes.sh
        source "$DXE_TESTS_DIR/lib/tmux-probes.sh"
        DXE_TMUX_PROBES_LOADED=1
    fi
}

# Extract one value from a captured tmux_guest_probe blob.
#   probe_value "$blob" status-keys
probe_value() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Assert a probed runtime value equals an expected value.
#   assert_tmux_runtime "$blob" status-keys emacs "tmux status-keys is emacs"
assert_tmux_runtime() {
    local blob="$1" key="$2" expected="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if [ "$got" = "$expected" ]; then
        test_pass "$message (runtime $key=$got)"
    else
        test_fail "$message (expected $key=$expected, got '$got')"
    fi
    return 0
}

# Assert a probed runtime value contains a substring.
assert_tmux_runtime_contains() {
    local blob="$1" key="$2" needle="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if printf '%s' "$got" | stdin_matches -F "$needle"; then
        test_pass "$message (runtime $key=$got)"
    else
        test_fail "$message (expected $key to contain '$needle', got '$got')"
    fi
    return 0
}

# Assert a probed runtime value does NOT contain a substring.
assert_tmux_runtime_not_contains() {
    local blob="$1" key="$2" needle="$3" message="$4"
    local got
    got="$(probe_value "$blob" "$key")"
    if printf '%s' "$got" | stdin_matches -F "$needle"; then
        test_fail "$message (expected $key to omit '$needle', got '$got')"
    else
        test_pass "$message (runtime $key=$got)"
    fi
    return 0
}

# Summary. Prints the byte-identical line print_summary always has, but the
# counts come from $DXE_TEST_RESULTS (tests/lib/harness.sh), not from
# $TESTS_PASSED/$TESTS_FAILED/$TESTS_SKIPPED -- see the comment above
# test_pass for why.
print_summary() {
    _dxe_harness_results_file
    local passed failed skipped
    passed="$(_dxe_harness_count pass)"
    failed="$(_dxe_harness_count fail)"
    skipped="$(_dxe_harness_count skip)"
    echo ""
    echo "=============================="
    echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
    echo "=============================="

    if [ "$failed" -gt 0 ]; then
        GLOBAL_FAILED=1
    fi
}

# Exit with proper code after all tests. Non-zero if $DXE_TEST_RESULTS has
# any fail line (not just if GLOBAL_FAILED was already set by a preceding
# print_summary call, so a suite that calls exit_with_code without ever
# calling print_summary still exits correctly). Deliberately does NOT apply
# tests/lib/harness.sh finish's "zero recorded cases is itself a failure"
# rule: several existing suites legitimately record only skips when no
# container is present (e.g. test_section19_reverse_forward.sh: 0 passed,
# 1 skipped) and must keep exiting 0. Removes the results file as its own
# last step, explicitly, rather than via a trap: many suites install their
# own `trap ... EXIT` for fixture cleanup (test_dx_backup.sh,
# test_docker_runtime_adapter.sh, ...), and a trap installed here would
# either clobber theirs or be clobbered by them depending on source order.
# Since every call site in this suite immediately exits afterward (grep
# confirms print_summary is always followed by exit_with_code, and
# exit_with_code always calls `exit`), there is no later reader of the file
# left to break by removing it here.
exit_with_code() {
    _dxe_harness_results_file
    local failed
    failed="$(_dxe_harness_count fail)"
    if [ "$failed" -gt 0 ]; then
        GLOBAL_FAILED=1
    fi
    rm -f "${DXE_TEST_RESULTS:-}"
    exit $GLOBAL_FAILED
}
