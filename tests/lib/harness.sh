#!/bin/bash
# tests/lib/harness.sh -- capture-based assertions with a results file that
# survives subshells and background jobs (Fable D1 / WP1.1).
#
# `test_pass`/`test_fail` (tests/test_helpers.sh) increment TESTS_PASSED/
# TESTS_FAILED in whichever shell calls them. A case recorded inside a
# `( ... )` subshell -- or a background job -- dies with that subshell: the
# counters revert to whatever the PARENT shell had, and the caller never
# learns a real failure happened (tests/test_refactor_contracts.sh's F6
# section exists only to prove that regression can still be caught).
# Fable D1's fix is this file: record each case as one line appended to a
# plain file instead of an in-memory counter. A file survives a subshell
# exiting -- only the counting SHELL's variables die with it, the write
# already landed on disk -- and an append (`>>`, opened O_APPEND) from a
# background job lands safely too, since each record here is one short
# `printf`, well under the platform's atomic pipe/write buffer, so
# concurrent short appends do not interleave into a corrupt line.
#
# Import-pure: sourcing this file only defines functions and one default
# variable (DXE_HARNESS_LABEL=""), with no I/O, no `exit`, and no change to
# the sourcing shell's control state ($-, IFS, PWD, umask, traps) -- the
# same eight-way contract tests/test_refactor_contracts.sh runs over
# bin/lib/*.sh (its lines 10-33), proven for this file by
# tests/test_harness.sh's own purity_ok case.
#
# $DXE_TEST_RESULTS is deliberately NOT created here at source time, only
# lazily, in _dxe_harness_results_file, the first time some function
# actually needs to record or read a case. This is what keeps each test
# suite's results private to itself: tests/run_all_tests.sh sources
# tests/test_helpers.sh (which sources this file) purely to reuse its
# shared setup, then runs every suite as `bash "$test_file"` -- a brand new
# process. If sourcing alone created and exported DXE_TEST_RESULTS in the
# runner, every suite it then launches would inherit that one export and
# all 30-odd suites would append into the SAME file, and a later suite's
# summary would include an earlier suite's cases. Because nothing here
# touches the variable until a case is actually recorded, and the runner
# itself never records one (it only forwards to `bash "$test_file"` and
# reads its exit code), the runner's own shell never sets or exports it.
# Each suite process, sourcing test_helpers.sh (and so this file) itself,
# is the first shell to call it/expect_*/skip/finish in its own execution,
# and so gets its own fresh mktemp file, private to that one
# `bash "$test_file"` process tree (subshells and background jobs of THAT
# process still see it without any export, since they are forks of it, not
# fresh interpreter invocations reading a fresh environment, and inherit
# every shell variable automatically; export only matters for a genuinely
# new `bash`/`bash -c` invocation, which is why it is exported here at all
# -- for the nested-bash cases this file's own test deliberately drives).
#
# Bash 3.2 host note (this file is sourced by tests/test_harness.sh under
# /bin/bash directly, per tests/run-bash32-tests.sh, and by every other
# suite via test_helpers.sh on this Mac's default /bin/bash): no
# `declare -A`, no namerefs, no `mapfile`, no `${var,,}`, no
# `local var=$(...)` (a real Bash 3.2 bug: `local` swallows the command
# substitution's exit status, so a failing command inside one never trips
# a caller's `set -e` -- every assignment here that calls a command splits
# `local var` from `var=$(...)` onto its own line instead).

# Colors, matching tests/test_helpers.sh's exactly, so `finish`'s summary
# line renders identically to `print_summary`'s. This file does not, and
# must not, source test_helpers.sh -- it has to stand on its own so
# test_helpers.sh can source IT instead, the direction WP1.1 requires
# (tests/test_harness.sh proves this file works with nothing but itself).
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# The label `it` set for whichever `expect_*` call comes next. It persists
# until the next `it` call -- it is not consumed after a single use: `it
# "does X"` followed by several `expect_*` calls names all of them "does
# X", matching `it` reading as "describe the case(s) now under test" more
# than a one-shot label. An `expect_*` call with no preceding `it` in the
# calling shell falls back to a label built from its own arguments.
DXE_HARNESS_LABEL=""

it() {
    DXE_HARNESS_LABEL="$1"
}

# Ensure $DXE_TEST_RESULTS names a real, writable, append-only file OWNED BY
# THIS PROCESS, creating one with mktemp under ${TMPDIR:-/tmp} the first
# time it is needed, if the caller has not already set one -- or if
# whatever is already set belongs to a DIFFERENT process. See the file
# header for why this must stay lazy rather than running at source time.
#
# Root cause this owner check closes (found in CI, e.g.
# test_section20_skip_integration.sh spawning test_section15/16/17 as
# complete nested `bash <file>` processes): DXE_TEST_RESULTS is exported,
# so a suite that runs ANOTHER suite as a plain child process hands it down
# by ordinary environment inheritance. Before this check, the child's own
# first test_pass/test_fail/skip saw DXE_TEST_RESULTS already non-empty and
# happily appended its cases onto the PARENT's file -- and the child's own
# finish/exit_with_code then deleted that shared file as its last step, so
# an earlier real failure (or even the parent's own prior pass lines)
# leaked into an unrelated later suite's tally, and whichever suite ran
# after the child inherited a `finish` deleted out from under it.
#
# DXE_TEST_RESULTS_OWNER=$$ is exported alongside the path every time this
# function mints one, so it always names the PID of whichever process is
# actually recording into it. A subshell (`( … )`) or background job forked
# from a script shares that SAME script's $$ (Bash does not fork a new pid
# for those), so it still passes this check and keeps appending to the
# same file -- exactly Fable D1's original fix, undisturbed. Only a
# genuinely new interpreter (`bash file`, `bash -c '...'`) gets its own
# $$, so an inherited DXE_TEST_RESULTS whose recorded owner is not THIS
# $$ is treated as if it were never set at all, and a fresh, private file
# is minted (and its ownership claimed) instead of adopting the parent's.
_dxe_harness_results_file() {
    if [ -z "${DXE_TEST_RESULTS:-}" ] || [ "${DXE_TEST_RESULTS_OWNER:-}" != "$$" ]; then
        local file
        file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-results.XXXXXX")"
        DXE_TEST_RESULTS="$file"
        DXE_TEST_RESULTS_OWNER="$$"
        export DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER
    fi
}

# Append one pass/fail record. $1: pass|fail. $2: the case label.
_dxe_harness_record() {
    _dxe_harness_results_file
    printf '%s\t%s\n' "$1" "$2" >> "$DXE_TEST_RESULTS"
}

# Count of recorded lines of one kind (pass|fail|skip). The `-s` guard
# means a not-yet-created or still-empty results file reads as zero
# without ever invoking awk on a missing path.
_dxe_harness_count() {
    if [ -s "$DXE_TEST_RESULTS" ]; then
        awk -F'\t' -v want="$1" '$1 == want { c++ } END { print c + 0 }' "$DXE_TEST_RESULTS"
    else
        printf '0\n'
    fi
}

# expect_exit N cmd [args...]
#
# Runs cmd, capturing stdout, stderr and its exit status, without letting a
# non-zero status trip the CALLER's own `set -e`: this function always
# returns 0 itself, the same shape tests/test_refactor_state_machines.sh's
# expect_ok/expect_reject already use (their `if/then/else` always lands on
# a test_pass/test_fail call, and those always return 0) -- a case's
# pass/fail lives in the results file, not in this call's own exit status.
# Passes if the exit status equals N; otherwise records a failure and
# prints the captured stdout, stderr and actual exit status, so a Red run
# explains itself without anything having to be re-run by hand.
expect_exit() {
    local expected="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_exit $expected: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    local status
    if "$@" >"$out_file" 2>"$err_file"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq "$expected" ]; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected exit $expected, got $status"
        echo "  stdout:"
        sed 's/^/    /' "$out_file"
        echo "  stderr:"
        sed 's/^/    /' "$err_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_stdout PATTERN cmd [args...]
#
# Runs cmd (its exit status is not checked); passes if its stdout matches
# PATTERN as an ERE (`grep -E`). On failure, prints the captured stdout.
# grep reads it from a completed file here, never from a live pipe, so
# this is not the `writer | grep -q` SIGPIPE-under-pipefail hazard
# documented at the top of tests/test_helpers.sh (stdin_matches).
expect_stdout() {
    local pattern="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_stdout $pattern: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    "$@" >"$out_file" 2>"$err_file" || true
    if grep -Eq -- "$pattern" "$out_file"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected stdout to match (ERE): $pattern"
        echo "  captured stdout:"
        sed 's/^/    /' "$out_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_stderr PATTERN cmd [args...] -- expect_stdout's mirror, over stderr.
expect_stderr() {
    local pattern="$1"
    shift
    local label="${DXE_HARNESS_LABEL:-expect_stderr $pattern: $*}"
    local out_file err_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-out.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-err.XXXXXX")"
    "$@" >"$out_file" 2>"$err_file" || true
    if grep -Eq -- "$pattern" "$err_file"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected stderr to match (ERE): $pattern"
        echo "  captured stderr:"
        sed 's/^/    /' "$err_file"
    fi
    rm -f "$out_file" "$err_file"
    return 0
}

# expect_file_eq FILE EXPECTED_STRING -- exact-match FILE's whole content
# (trailing newlines stripped by the command substitution that reads it,
# same as any other `$(cat ...)` in this codebase) against EXPECTED_STRING.
expect_file_eq() {
    local file="$1" expected="$2"
    local label="${DXE_HARNESS_LABEL:-expect_file_eq $file}"
    local actual
    actual="$(cat "$file" 2>/dev/null)" || actual=""
    if [ "$actual" = "$expected" ]; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
    return 0
}

# --- Bounded polling (Fable D10) ----------------------------------------
#
# wait_until 'cond' [max-attempts] -- polls `eval "$1"` up to $2 times
# (default 50), sleeping between attempts via ${DX_SLEEP:-sleep} (the same
# injectable seam bin/lib/dx-host-util.sh's dx_wait_until already honours,
# WP4.2 / Fable A6) rather than a bare `sleep N`. This is that same
# discipline applied to a TEST that must synchronise with a real external
# condition -- a fixture file another process writes, a pid exiting -- so a
# fixture can drive it deterministically by faking DX_SLEEP, and a real
# caller still gets a real (if bounded) wait.
#
# Bounded by attempt COUNT, never by a wall-clock read (SECONDS, date,
# etc.): a test asserting on wait_until's outcome asserts what happened
# (the condition matched, or it did not within the bound), never how long
# it took. Checks BEFORE ever sleeping, so an already-true condition
# returns immediately with zero recorded sleeps -- dx_wait_until's own
# contract, mirrored here.
#
# "$cond" is evaluated with `eval` in THIS shell (never a subshell), so a
# condition that sets an outer local -- exactly the dynamic-scoping trick
# dx_bootstrap_confirm_publication_check and dx_lock_acquire_check already
# rely on -- is visible to the caller once wait_until returns.
wait_until() {
    local cond="$1" limit="${2:-50}" attempt=0
    while :; do
        eval "$cond" && return 0
        attempt=$((attempt + 1))
        [ "$attempt" -lt "$limit" ] || return 1
        "${DX_SLEEP:-sleep}" 0.1
    done
}

# wait_for_pid_exit PID [max-attempts] -- wait_until's predicate applied to
# "has this pid stopped being alive" (kill -0 fails once it has), the other
# half of the same bounded-attempts contract for a test that needs to know
# a background process it started (or is watching) has actually gone away,
# rather than guessing how long that takes with a fixed sleep.
wait_for_pid_exit() {
    local pid="$1" limit="${2:-50}"
    wait_until "! kill -0 '$pid' 2>/dev/null" "$limit"
}

# --- Shared runtime fakes (Fable D5, E3) --------------------------------
#
# tests/lib/fake-tools.sh already covers the DX guest ssh boundary and the
# docker-ssh management-plane ssh boundary; what was missing was a shared
# `docker`/`container`/`ssh` fake ANY fixture could ask for without
# re-writing a pass-through body and a PATH ritual per suite (D5's evidence:
# test_docker_runtime_adapter.sh alone carries 105 hand-written docker
# bodies and pins its own PATH 126 times). `with_fake_runtime` is that
# shared fake: one private directory, reused across every tool a fixture
# asks for, on a SINGLE PATH convention every fixture can now share instead
# of inventing its own.
#
# Lazy, process-private state (mirrors _dxe_harness_results_file/
# DXE_TEST_RESULTS): nothing here runs at source time, only the first time
# with_fake_runtime is actually called.
_dxe_harness_fake_runtime_dir() {
    if [ -z "${DXE_FAKE_RUNTIME_DIR:-}" ]; then
        local dir
        dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-fake-runtime.XXXXXX")"
        DXE_FAKE_RUNTIME_DIR="$dir"
        export DXE_FAKE_RUNTIME_DIR
    fi
}

# $FAKE_TRANSCRIPT: one shared, append-only log for every tool this process
# fakes (docker AND ssh AND container all land in the SAME file), so a
# fixture can assert ordering across tools, not just per-tool.
_dxe_harness_fake_transcript_file() {
    if [ -z "${FAKE_TRANSCRIPT:-}" ]; then
        local file
        file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-fake-transcript.XXXXXX")"
        FAKE_TRANSCRIPT="$file"
        export FAKE_TRANSCRIPT
    fi
}

# with_fake_runtime docker|container|ssh
#
# Writes a fake executable named $1 into the shared private directory
# (creating it, and $FAKE_TRANSCRIPT, on first use), then pins
# PATH="$DXE_FAKE_RUNTIME_DIR:$(dirname "$(command -v bash)"):/usr/bin:/bin"
# in the CALLING shell -- the single convention this codebase's fixtures
# should now share. Naming bash's own directory explicitly (rather than
# relying on /bin or /usr/bin already containing it) is what lets a fake
# written with `#!/usr/bin/env bash` (E3) still resolve bash on a host
# without /bin/bash, e.g. NixOS (Fable E3's whole point -- see the (p) case
# in tests/test_harness.sh, which proves this under a PATH containing
# neither /bin nor /usr/bin at all).
#
# Calling this again for a second/third tool in the same process reuses the
# SAME directory (so docker+ssh+container fakes coexist on one PATH) but
# resets that ONE tool's own call count, fail plan and scripted responses --
# re-registering a tool's fake starts that boundary over, without touching
# any other tool's state or the shared transcript (which is cumulative for
# the whole fixture by design).
#
# Each invocation of the fake appends one line to $FAKE_TRANSCRIPT: its
# whole argv, each argument `%q`-quoted and space-joined (so
# `expect_transcript` can match it as an ERE without caring how the
# original call happened to quote anything). By default a call exits 0
# with no output; fake_fail_nth and fake_respond script anything else.
with_fake_runtime() {
    local tool="$1"
    _dxe_harness_fake_runtime_dir
    _dxe_harness_fake_transcript_file
    rm -f "$DXE_FAKE_RUNTIME_DIR/.count-$tool" "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool" "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
    : > "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
    : > "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
    cat > "$DXE_FAKE_RUNTIME_DIR/$tool" <<FAKE_EOF
#!/usr/bin/env bash
dxe_fake_transcript="$FAKE_TRANSCRIPT"
dxe_fake_count_file="$DXE_FAKE_RUNTIME_DIR/.count-$tool"
dxe_fake_failplan="$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
dxe_fake_responses="$DXE_FAKE_RUNTIME_DIR/.responses-$tool"

dxe_fake_line=""
for dxe_fake_arg in "\$@"; do
    dxe_fake_line="\$dxe_fake_line\$(printf '%q ' "\$dxe_fake_arg")"
done
printf '%s\n' "\$dxe_fake_line" >> "\$dxe_fake_transcript"

dxe_fake_n=0
[ -s "\$dxe_fake_count_file" ] && dxe_fake_n="\$(cat "\$dxe_fake_count_file")"
dxe_fake_n=\$((dxe_fake_n + 1))
printf '%s\n' "\$dxe_fake_n" > "\$dxe_fake_count_file"

if [ -s "\$dxe_fake_failplan" ]; then
    dxe_fake_code="\$(awk -v n="\$dxe_fake_n" '\$1 == n { print \$2; exit }' "\$dxe_fake_failplan")"
    if [ -n "\$dxe_fake_code" ]; then
        exit "\$dxe_fake_code"
    fi
fi

if [ -s "\$dxe_fake_responses" ]; then
    dxe_fake_joined="\$*"
    while IFS=\$'\t' read -r dxe_fake_key dxe_fake_out; do
        case "\$dxe_fake_joined" in
            "\$dxe_fake_key"*)
                printf '%s\n' "\$dxe_fake_out"
                exit 0
                ;;
        esac
    done < "\$dxe_fake_responses"
fi
exit 0
FAKE_EOF
    chmod 0755 "$DXE_FAKE_RUNTIME_DIR/$tool"
    PATH="$DXE_FAKE_RUNTIME_DIR:$(dirname "$(command -v bash)"):/usr/bin:/bin"
}

# fake_fail_nth TOOL N CODE -- makes the Nth call to TOOL's fake (TOOL must
# already have one from with_fake_runtime) exit CODE; every other call
# exits 0 (or whatever fake_respond separately scripted for it -- fail_nth
# always wins over a scripted response on a matching call number, the same
# way a real boundary failing pre-empts whatever it would otherwise have
# returned).
fake_fail_nth() {
    local tool="$1" n="$2" code="$3"
    _dxe_harness_fake_runtime_dir
    printf '%s\t%s\n' "$n" "$code" >> "$DXE_FAKE_RUNTIME_DIR/.failplan-$tool"
}

# fake_respond TOOL 'match prefix' 'output' -- scripts stdout for any call
# to TOOL's fake whose whole argv, space-joined, STARTS WITH 'match prefix'.
# This is the shape the ~20 `"$1 $2") echo "27.3.1" ;;` arms in
# test_docker_runtime_adapter.sh already hand-roll one case statement at a
# time; fake_respond docker 'version --format' '27.3.1' is the same
# contract as one line instead of a case arm, so those bodies can collapse
# onto this later (not migrated by this change). First-registered matching
# prefix wins. TOOL must already have a fake from with_fake_runtime.
fake_respond() {
    local tool="$1" match="$2" output="$3"
    _dxe_harness_fake_runtime_dir
    printf '%s\t%s\n' "$match" "$output" >> "$DXE_FAKE_RUNTIME_DIR/.responses-$tool"
}

# expect_transcript PATTERN -- asserts some line of $FAKE_TRANSCRIPT
# matches PATTERN as an ERE (grep -E), expect_stdout's shape applied to the
# fakes' shared transcript file instead of one command's captured stdout.
expect_transcript() {
    local pattern="$1"
    local label="${DXE_HARNESS_LABEL:-expect_transcript $pattern}"
    _dxe_harness_fake_transcript_file
    if [ -s "$FAKE_TRANSCRIPT" ] && grep -Eq -- "$pattern" "$FAKE_TRANSCRIPT"; then
        _dxe_harness_record pass "$label"
    else
        _dxe_harness_record fail "$label"
        echo "FAIL: $label"
        echo "  expected some transcript line to match (ERE): $pattern"
        echo "  transcript:"
        sed 's/^/    /' "$FAKE_TRANSCRIPT" 2>/dev/null
    fi
    return 0
}

# --- Fixture isolation and skip semantics (Fable D9, D11) ---------------
#
# with_fixture -- creates a private fixture directory and, in the CALLING
# shell, points HOME, XDG_STATE_HOME and TMPDIR under it, and unsets every
# already-set DXE_CONFIG_* variable (DXE_CONFIG_RESOLVED,
# DXE_CONFIG_SNAPSHOT_VERSION, and each DXE_CONFIG_ORIGIN_<field>
# bin/lib/dx-config.sh exports -- swept by prefix with `${!DXE_CONFIG_@}`,
# Bash 3.2-clean, rather than hand-copying dx-config.sh's own
# DXE_CONFIG_FIELDS list here and risking drift) so a suite that sources
# dx-config.sh next resolves fresh, from the fixture, instead of reusing
# whatever the developer's own real environment already resolved (Fable D9's
# evidence: this exact five-variable `unset` loop, hand-written, appears
# five times in test_refactor_state_machines.sh and six in
# test_sourceable_coverage.sh).
#
# NEVER call this inside a `( ... )` subshell, and NEVER capture it via
# `$(with_fixture)` -- command substitution forks a subshell exactly like
# `( ... )` does, so EVERY environment mutation below (HOME, XDG_STATE_HOME,
# TMPDIR, the DXE_CONFIG_* unsets) would die with that subshell the instant
# it exited, the same "state dies with the subshell" trap this file's own
# header describes for test_pass/test_fail before WP1.1 -- every command
# that follows in the REAL calling shell would still see the developer's
# real environment, silently. This is why the fixture directory is NOT
# returned via stdout: call this plainly (`with_fixture`, no `$(...)`) and
# read $DXE_FIXTURE_DIR afterward if you need the raw directory (to place
# something outside HOME/XDG_STATE_HOME/TMPDIR, say); HOME/XDG_STATE_HOME/
# TMPDIR themselves are usually all a caller needs.
#
# The FIRST with_fixture call in a process also snapshots the real,
# not-yet-redirected known-hosts pin tree (dx_real_ssh_known_hosts_snapshot's
# idea, tests/test_helpers.sh -- reimplemented here, not called there,
# because this file must stay sourceable standalone, the direction WP1.1
# fixed) so finish can prove later that it never changed. The real HOME/
# XDG_STATE_HOME are captured from THIS call's ambient values, before either
# is reassigned below -- capturing them any later would already be reading
# the fixture's own.
with_fixture() {
    if [ -z "${DXE_HARNESS_FIXTURE_REAL_HOME:-}" ]; then
        DXE_HARNESS_FIXTURE_REAL_HOME="$HOME"
        DXE_HARNESS_FIXTURE_REAL_XDG_STATE_HOME="${XDG_STATE_HOME:-}"
        DXE_HARNESS_FIXTURE_KNOWN_HOSTS_BEFORE="$(_dxe_harness_known_hosts_snapshot)"
    fi
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-fixture.XXXXXX")"
    DXE_FIXTURE_DIR="$dir"
    HOME="$dir/home"
    XDG_STATE_HOME="$dir/xdg-state"
    TMPDIR="$dir/tmp"
    mkdir -p "$HOME" "$XDG_STATE_HOME" "$TMPDIR"
    export DXE_FIXTURE_DIR HOME XDG_STATE_HOME TMPDIR
    local dxe_fixture_config_var
    for dxe_fixture_config_var in ${!DXE_CONFIG_@}; do
        unset "$dxe_fixture_config_var"
    done
    return 0
}

# The real (pre-fixture) known-hosts pin tree, read from whichever of
# HOME/XDG_STATE_HOME with_fixture's FIRST call captured before redirecting
# either. Same formula as dx_real_ssh_known_hosts_snapshot
# (tests/test_helpers.sh): ${XDG_STATE_HOME:-$HOME/.local/state}/dxe, and
# an absent directory is a legitimate, empty snapshot, not an error.
_dxe_harness_known_hosts_snapshot() {
    local dir
    dir="${DXE_HARNESS_FIXTURE_REAL_XDG_STATE_HOME:-$DXE_HARNESS_FIXTURE_REAL_HOME/.local/state}/dxe"
    [ -d "$dir" ] || return 0
    find "$dir" -mindepth 1 2>/dev/null | sort
}

# True if $1 (a suite file path, `finish` passes its own $0) carries a
# `# skip-ok:` header line anywhere in its source -- the escape hatch for a
# suite that legitimately records only skips (e.g. every case needs a
# container that genuinely is not present here). A suite invoked as
# `bash -c '...'` (no real file backing $0) reads as absent, which is the
# conservative/correct answer: there is no header to find.
_dxe_harness_skip_ok_header() {
    local file="$1"
    [ -n "$file" ] && [ -r "$file" ] && grep -q '^# skip-ok:' "$file" 2>/dev/null
}

# One line summarising how many skips were recorded per --class, sorted by
# class name (`skip "reason"` with no --class records an empty class and is
# left out of this summary -- finish's caller already sees its count in the
# main "N skipped" line).
_dxe_harness_skip_class_summary() {
    awk -F'\t' '
        $1 == "skip" && $2 != "" { c[$2]++ }
        END { for (k in c) print k"="c[k] }
    ' "$DXE_TEST_RESULTS" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//'
}

# skip --class live|linux-root|destructive "reason"
skip() {
    local class="" reason=""
    if [ "${1:-}" = "--class" ]; then
        class="${2:-}"
        reason="${3:-}"
    else
        reason="${1:-}"
    fi
    _dxe_harness_results_file
    printf 'skip\t%s\t%s\n' "$class" "$reason" >> "$DXE_TEST_RESULTS"
}

# finish -- prints the same summary line print_summary does (byte-identical
# format, different data source, plus a second "Skipped classes:" line when
# any skip was recorded, Fable D11), then exits:
#   1  if any case failed, OR every recorded case was a skip and this
#      suite's own source (its $0) carries no `# skip-ok:` header line
#      (Fable D11 -- a suite whose every case skipped is not, on its own, a
#      suite that passed, unless it says so up front), OR the with_fixture
#      known-hosts guard below (Fable D9) caught the real
#      ~/.local/state/dxe tree changing during this run;
#   3  if zero cases were recorded at all -- kept distinct from 1 so a
#      dispatch bug (the suite never ran a single case) reads differently
#      from a suite that ran cases and every one of them skipped.
# This is deliberately NOT shared with test_helpers.sh's exit_with_code shim
# -- several existing suites legitimately record 0 passed / 1 skipped when
# no container is present (e.g. test_section19_reverse_forward.sh) and must
# keep exiting 0; only callers of this native `finish` opt into these
# stricter rules.
finish() {
    _dxe_harness_results_file

    # Fable D9: if with_fixture ever ran in this process, prove the real,
    # pre-fixture known-hosts pin tree it snapshotted before the first
    # redirection is byte-identical to what it is now. A suite that leaks
    # past its own fixture (or a bug in with_fixture itself) writes
    # somewhere under the developer's real ~/.local/state/dxe; this is the
    # only place that would ever be caught, since nothing else here re-reads
    # it after setup.
    if [ -n "${DXE_HARNESS_FIXTURE_REAL_HOME:-}" ]; then
        local known_hosts_after
        known_hosts_after="$(_dxe_harness_known_hosts_snapshot)"
        if [ "$known_hosts_after" != "$DXE_HARNESS_FIXTURE_KNOWN_HOSTS_BEFORE" ]; then
            _dxe_harness_record fail "with_fixture isolation: the real ~/.local/state/dxe known-hosts tree changed during this suite"
            echo "FAIL: with_fixture isolation breach"
            echo "  the real ~/.local/state/dxe known-hosts tree changed during this suite run"
        fi
    fi

    local passed failed skipped total
    passed="$(_dxe_harness_count pass)"
    failed="$(_dxe_harness_count fail)"
    skipped="$(_dxe_harness_count skip)"
    total=$((passed + failed + skipped))

    # Fable D11: every recorded case was a skip (total > 0, since a truly
    # empty run is handled below by the "zero cases" rule, exit 3, not
    # this one) -- fail unless this suite's own source says that is fine.
    if [ "$total" -gt 0 ] && [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
        if ! _dxe_harness_skip_ok_header "$0"; then
            _dxe_harness_record fail "finish: every recorded case was a skip and $0 carries no '# skip-ok:' header"
            failed="$(_dxe_harness_count fail)"
            total=$((passed + failed + skipped))
        fi
    fi

    echo ""
    echo "=============================="
    echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}, ${YELLOW}${skipped} skipped${NC}"
    if [ "$skipped" -gt 0 ]; then
        echo "Skipped classes: $(_dxe_harness_skip_class_summary)"
    fi
    echo "=============================="
    local status=0
    if [ "$failed" -gt 0 ]; then
        status=1
    elif [ "$total" -eq 0 ]; then
        status=3
    fi
    rm -f "$DXE_TEST_RESULTS"
    exit "$status"
}
