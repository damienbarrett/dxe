#!/bin/bash
# tier: unit
# bash32: yes
set -euo pipefail

# tests/test_harness.sh -- Red for WP1.1 / Fable D1: tests/lib/harness.sh.
#
# Sources tests/lib/harness.sh directly, NOT tests/test_helpers.sh, so the
# harness's contract is proven standalone before test_helpers.sh's shims
# (test_pass/test_fail/print_summary/exit_with_code, WP1.1's Refactor step)
# are layered on top of it. Because of that, this file cannot grade the
# harness using the harness's own primitives -- a self-consistent bug (say,
# expect_exit always recording "pass" regardless of the actual exit code)
# would then pass its own regression test. So, like
# tests/test_refactor_contracts.sh, it carries its own tiny, independent
# check()/reject()/contains() vocabulary and calls the harness only as the
# code under test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
check() { if "$@"; then :; else echo "FAIL: $*" >&2; failures=$((failures + 1)); fi; }
reject() { ! "$@"; }
contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- (k) Import purity, run before anything below gives this shell its own
# $DXE_TEST_RESULTS -- the identical eight-way contract
# tests/test_refactor_contracts.sh applies to bin/lib/*.sh (its lines
# 10-33); the same shape lands on tests/lib/*.sh in WP1.6. Sourced inside
# its own command substitution (a subshell), so whatever state the harness
# sets while loading cannot leak back and contaminate the cases that
# follow.
purity_ok() {
    local before_flags="$-" before_ifs="$IFS" before_pwd="$PWD" before_umask before_traps
    before_umask="$(umask)"
    before_traps="$(trap -p)"
    local purity_stderr
    purity_stderr="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-purity.XXXXXX")"
    local output status
    output="$(source "$SCRIPT_DIR/lib/harness.sh" 2>"$purity_stderr")" && status=0 || status=$?
    local stderr_output
    stderr_output="$(cat "$purity_stderr")"
    rm -f "$purity_stderr"
    [ -z "$output" ] &&
        [ -z "$stderr_output" ] &&
        [ "$status" -eq 0 ] &&
        [ "$before_flags" = "$-" ] &&
        [ "$before_ifs" = "$IFS" ] &&
        [ "$before_pwd" = "$PWD" ] &&
        [ "$before_umask" = "$(umask)" ] &&
        [ "$before_traps" = "$(trap -p)" ] &&
        [ -z "${DXE_TEST_RESULTS:-}" ]
}
check purity_ok

# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

# This shell's own results file, isolated from anything else on the
# filesystem and from other suites -- set explicitly (rather than letting
# the harness lazily mktemp one) so every check below knows exactly which
# file to inspect. DXE_TEST_RESULTS_OWNER is claimed here too (normally only
# _dxe_harness_results_file itself stamps it, the first time a case is
# recorded): this process is choosing its OWN file up front rather than
# going through the lazy mint, so it must also claim ownership up front, or
# the owner check that same function now runs (Fable D10/CI -- see
# tests/lib/harness.sh) would see this $RESULTS as an inherited leftover
# from nothing (no ancestor set DXE_TEST_RESULTS_OWNER to this pid either)
# and silently replace it with an auto-minted file of its own the moment the
# first case below gets recorded.
RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-selftest.XXXXXX")"
DXE_TEST_RESULTS="$RESULTS"
DXE_TEST_RESULTS_OWNER="$$"
export DXE_TEST_RESULTS DXE_TEST_RESULTS_OWNER

record_count() { wc -l < "$RESULTS" | tr -d ' '; }
last_record() { tail -n1 "$RESULTS"; }

# --- (a) expect_exit 3 bash -c 'exit 3' passes.
n_before="$(record_count)"
expect_exit 3 bash -c 'exit 3' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass

# --- (b) expect_exit 0 false fails, and the failure is recorded, printing
# the captured stdout, stderr and actual exit status.
n_before="$(record_count)"
b_out="$(expect_exit 0 false)"
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail
check contains "$b_out" "expected exit 0"
check contains "$b_out" "got 1"

# --- (c) ( expect_exit 0 false ) inside a REAL subshell is still recorded
# -- the exact idiom that lost results before D1
# (tests/test_refactor_contracts.sh's F6 comment: "test_pass/test_fail
# called *inside* a ( … ) subshell incremented counters that die with the
# subshell").
n_before="$(record_count)"
( expect_exit 0 false >/dev/null )
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail

# --- (d) a failing expect_stdout prints the captured stdout. Run in a
# nested bash -c, a genuinely new process (its own $$), so the results-file
# owner check (Fable D10/CI) mints it a PRIVATE file rather than adopting
# whatever this OUTER process's own DXE_TEST_RESULTS is inherited as -- this
# process's file, and the counts already asserted above, stay untouched.
# The nested script reports its own file's line count and last record back
# over stdout, since the outer script no longer knows (or needs to know)
# that file's path in advance.
d_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    expect_stdout "goodbye" printf "hello world"
    echo "lines=$(wc -l < "$DXE_TEST_RESULTS" | tr -d " ")"
    echo "record=$(tail -n1 "$DXE_TEST_RESULTS")"
')"
check contains "$d_out" "hello world"
check contains "$d_out" "lines=1"
check contains "$d_out" "record=fail"

# --- (e) expect_stdout 'hello' printf 'hello world' passes.
n_before="$(record_count)"
expect_stdout 'hello' printf 'hello world' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass

# --- (f) expect_stderr matches, and a failing expect_stderr prints the
# captured stderr.
n_before="$(record_count)"
expect_stderr 'boom' bash -c 'echo boom >&2' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass
f_out="$(expect_stderr 'nomatch' bash -c 'echo boom >&2')"
check test "$(last_record | cut -f1)" = fail
check contains "$f_out" "boom"

# --- (g) expect_file_eq passes on an exact match, fails otherwise.
g_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-file.XXXXXX")"
printf 'exact contents' > "$g_file"
n_before="$(record_count)"
expect_file_eq "$g_file" 'exact contents' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = pass
n_before="$(record_count)"
expect_file_eq "$g_file" 'wrong contents' >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = fail
rm -f "$g_file"

# --- (h) finish exits 3 (not 1 -- reserved for an actual failure) when
# zero cases were recorded (nested bash, its own empty results file). Fable
# D11.
if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-empty.XXXXXX")"
    export DXE_TEST_RESULTS
    finish
' >/dev/null 2>&1; then
    h_status=0
else
    h_status=$?
fi
check test "$h_status" -eq 3

# --- (i) finish exits non-zero when one case failed, and zero when every
# recorded case passed.
if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-onefail.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 false >/dev/null
    expect_exit 0 true >/dev/null
    finish
' >/dev/null 2>&1; then
    i_fail_status=0
else
    i_fail_status=$?
fi
check test "$i_fail_status" -ne 0

if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-allpass.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 true >/dev/null
    expect_exit 3 bash -c "exit 3" >/dev/null
    finish
' >/dev/null 2>&1; then
    i_pass_status=0
else
    i_pass_status=$?
fi
check test "$i_pass_status" -eq 0

# --- (j) skip --class live "reason" records a skip line with the class.
n_before="$(record_count)"
skip --class live "container not running"
check test "$(record_count)" -eq "$((n_before + 1))"
check test "$(last_record | cut -f1)" = skip
check test "$(last_record | cut -f2)" = live
check contains "$(last_record)" "container not running"

# --- it() names the case the following expect_* call records.
n_before="$(record_count)"
it "custom label for this case"
expect_exit 0 true >/dev/null
check test "$(record_count)" -eq "$((n_before + 1))"
check contains "$(last_record)" "custom label for this case"

# =========================================================================
# WP1.2 -- shared runtime fakes (Fable D5, E3)
# =========================================================================

# --- (l) with_fake_runtime docker records two invocations as two
# %q-quoted argv lines, appended (not overwritten) to $FAKE_TRANSCRIPT.
# Also registers a second tool (ssh) in the SAME process: with_fake_runtime
# and its lazy dir/transcript init must be safe to call more than once,
# reusing the SAME $DXE_FAKE_RUNTIME_DIR and $FAKE_TRANSCRIPT rather than
# creating a fresh one per tool, so docker+ssh calls land in one ordered
# transcript.
l_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    with_fake_runtime docker
    dxe_l_dir1="$DXE_FAKE_RUNTIME_DIR"
    dxe_l_transcript1="$FAKE_TRANSCRIPT"
    docker exec -i -u dx foo >/dev/null 2>&1
    echo "rc1=$?"
    docker version --format >/dev/null 2>&1
    echo "rc2=$?"
    with_fake_runtime ssh
    echo "same_dir=$([ "$DXE_FAKE_RUNTIME_DIR" = "$dxe_l_dir1" ] && echo yes || echo no)"
    echo "same_transcript=$([ "$FAKE_TRANSCRIPT" = "$dxe_l_transcript1" ] && echo yes || echo no)"
    ssh somehost true >/dev/null 2>&1
    echo "rc3=$?"
    echo "lines=$(wc -l < "$FAKE_TRANSCRIPT" | tr -d " ")"
    cat "$FAKE_TRANSCRIPT"
')"
check contains "$l_out" "rc1=0"
check contains "$l_out" "rc2=0"
check contains "$l_out" "rc3=0"
check contains "$l_out" "same_dir=yes"
check contains "$l_out" "same_transcript=yes"
check contains "$l_out" "lines=3"
check contains "$l_out" "exec -i -u dx foo"
check contains "$l_out" "version --format"
check contains "$l_out" "somehost"

# --- (m) fake_fail_nth docker 2 42 makes the second docker call exit 42;
# the first and third still exit 0.
m_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    with_fake_runtime docker
    fake_fail_nth docker 2 42
    docker one >/dev/null 2>&1; echo "rc1=$?"
    docker two >/dev/null 2>&1; echo "rc2=$?"
    docker three >/dev/null 2>&1; echo "rc3=$?"
')"
check contains "$m_out" "rc1=0"
check contains "$m_out" "rc2=42"
check contains "$m_out" "rc3=0"

# --- (n) expect_transcript PATTERN passes when some transcript line
# matches the ERE, and records (not just prints) a failure when none does.
n2_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-n2-results.XXXXXX")"
    export DXE_TEST_RESULTS
    with_fake_runtime docker
    docker exec -i -u dx bash -lc "echo hi" >/dev/null 2>&1
    expect_transcript "exec -i -u dx" >/dev/null
    echo "pass_line=$(tail -n1 "$DXE_TEST_RESULTS" | cut -f1)"
    expect_transcript "this ERE never matches anything here" >/dev/null
    echo "fail_line=$(tail -n1 "$DXE_TEST_RESULTS" | cut -f1)"
')"
check contains "$n2_out" "pass_line=pass"
check contains "$n2_out" "fail_line=fail"

# --- (o) fake_respond scripts stdout for a matching call (the shape the
# ~20 duplicated `"version --format") echo "27.3.1"` arms in
# test_docker_runtime_adapter.sh could collapse onto), and a call that
# matches none of the registered prefixes still falls through to the
# default: exit 0, no output.
o_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    with_fake_runtime docker
    fake_respond docker "version --format" "27.3.1"
    docker version --format
    echo "---"
    dxe_o_unmatched="$(docker info --format 2>&1)"
    echo "rc_unmatched=$?"
    echo "out_unmatched=[$dxe_o_unmatched]"
')"
check contains "$o_out" "27.3.1"
check contains "$o_out" "rc_unmatched=0"
check contains "$o_out" "out_unmatched=[]"

# --- (p) Fable E3: a fake written by with_fake_runtime executes under a
# PATH containing neither /bin nor /usr/bin -- simulating a NixOS host
# without /bin/bash -- as long as PATH still names wherever bash itself
# actually lives (found via `command -v bash` before restricting PATH,
# exactly what with_fake_runtime's own PATH pin already does for the
# CALLING shell). This only works because the fake's shebang is
# `#!/usr/bin/env bash`, not a hardcoded `#!/bin/bash`.
p_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    with_fake_runtime docker
    fake_respond docker "version --format" "27.3.1"
    dxe_p_bash_dir="$(dirname "$(command -v bash)")"
    env -i PATH="/var/empty:$dxe_p_bash_dir" "$DXE_FAKE_RUNTIME_DIR/docker" version --format
    echo "exit=$?"
')"
check contains "$p_out" "27.3.1"
check contains "$p_out" "exit=0"

# --- (q) tests/lib/fake-tools.sh's fake_tool_write also writes
# `#!/usr/bin/env bash`, not `#!/bin/bash` (Fable E3 applies to every fake
# writer, not just this file's own).
q_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-q-tools.XXXXXX")"
fake_tool_write "$q_dir" probe 'echo ok'
q_shebang="$(head -n1 "$q_dir/probe")"
check test "$q_shebang" = "#!/usr/bin/env bash"
rm -rf "$q_dir"

# --- (r) Fable D5: fake_qnap_ssh_write's DXE_FAKE_SSH_ARGV_LOG APPENDS
# across calls (fake-tools.sh:73 was `>`, which only ever left the last
# call's argv visible, so "assert there was no second call" could never be
# proven). Two single-argument calls must leave two lines, not one.
r_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-r-tools.XXXXXX")"
r_log="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-r-log.XXXXXX")"
rm -f "$r_log"
fake_qnap_ssh_write "$r_dir"
DXE_FAKE_SSH_ARGV_LOG="$r_log" PATH="$r_dir:$PATH" ssh call-one >/dev/null 2>&1 || true
DXE_FAKE_SSH_ARGV_LOG="$r_log" PATH="$r_dir:$PATH" ssh call-two >/dev/null 2>&1 || true
check test "$(wc -l < "$r_log" | tr -d ' ')" -eq 2
check contains "$(cat "$r_log")" "call-one"
check contains "$(cat "$r_log")" "call-two"
rm -rf "$r_dir"
rm -f "$r_log"

# =========================================================================
# WP1.3 -- fixture isolation and skip semantics (Fable D9, D11)
# =========================================================================

# --- (s) with_fixture points HOME, XDG_STATE_HOME and TMPDIR under a fresh
# directory in the CALLING shell, and unsets every already-set DXE_CONFIG_*
# variable.
s_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    unset XDG_STATE_HOME
    DXE_CONFIG_RESOLVED=1
    DXE_CONFIG_SNAPSHOT_VERSION=1
    DXE_CONFIG_ORIGIN_DX_RUNTIME=env
    export DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DXE_CONFIG_ORIGIN_DX_RUNTIME
    dxe_s_before_home="$HOME"
    with_fixture
    echo "fixture=$DXE_FIXTURE_DIR"
    echo "home=$HOME"
    echo "before_home=$dxe_s_before_home"
    echo "xdg=$XDG_STATE_HOME"
    echo "tmpdir=$TMPDIR"
    echo "resolved=${DXE_CONFIG_RESOLVED:-UNSET}"
    echo "snapver=${DXE_CONFIG_SNAPSHOT_VERSION:-UNSET}"
    echo "origin=${DXE_CONFIG_ORIGIN_DX_RUNTIME:-UNSET}"
')"
check contains "$s_out" "resolved=UNSET"
check contains "$s_out" "snapver=UNSET"
check contains "$s_out" "origin=UNSET"
s_fixture="$(printf '%s\n' "$s_out" | sed -n 's/^fixture=//p')"
s_home="$(printf '%s\n' "$s_out" | sed -n 's/^home=//p')"
s_before_home="$(printf '%s\n' "$s_out" | sed -n 's/^before_home=//p')"
s_xdg="$(printf '%s\n' "$s_out" | sed -n 's/^xdg=//p')"
s_tmpdir="$(printf '%s\n' "$s_out" | sed -n 's/^tmpdir=//p')"
check test -n "$s_fixture"
check test "$s_home" != "$s_before_home"
case "$s_home" in
    "$s_fixture"/*) s_home_ok=yes ;;
    *) s_home_ok=no ;;
esac
check test "$s_home_ok" = yes
case "$s_xdg" in
    "$s_fixture"/*) s_xdg_ok=yes ;;
    *) s_xdg_ok=no ;;
esac
check test "$s_xdg_ok" = yes
case "$s_tmpdir" in
    "$s_fixture"/*) s_tmpdir_ok=yes ;;
    *) s_tmpdir_ok=no ;;
esac
check test "$s_tmpdir_ok" = yes

# --- (s2) a SECOND with_fixture call in the same process gets a fresh
# directory (never reuses the first fixture) but keeps anchoring the "real"
# baseline to the ORIGINAL environment captured by the first call, never to
# the first fixture's own fake HOME.
s2_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    unset XDG_STATE_HOME
    dxe_s2_real_home="$HOME"
    with_fixture
    dxe_s2_first_fixture="$DXE_FIXTURE_DIR"
    dxe_s2_first_real="$DXE_HARNESS_FIXTURE_REAL_HOME"
    with_fixture
    echo "second_fixture_differs=$([ "$DXE_FIXTURE_DIR" != "$dxe_s2_first_fixture" ] && echo yes || echo no)"
    echo "real_still_original=$([ "$DXE_HARNESS_FIXTURE_REAL_HOME" = "$dxe_s2_real_home" ] && echo yes || echo no)"
    echo "real_unchanged_by_second_call=$([ "$DXE_HARNESS_FIXTURE_REAL_HOME" = "$dxe_s2_first_real" ] && echo yes || echo no)"
')"
check contains "$s2_out" "second_fixture_differs=yes"
check contains "$s2_out" "real_still_original=yes"
check contains "$s2_out" "real_unchanged_by_second_call=yes"

# --- (t) finish fails when every recorded case is a skip and the suite's
# own source ($0) carries no `# skip-ok:` header. A `bash -c` invocation's
# $0 is literally "bash" (no readable file backs it), so this is also the
# "no header at all" case.
if SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-t-results.XXXXXX")"
    export DXE_TEST_RESULTS
    skip --class live "no container"
    finish
' >/dev/null 2>&1; then
    t_status=0
else
    t_status=$?
fi
check test "$t_status" -ne 0

# --- (u) finish does NOT force-fail an all-skip run when the suite's own
# source carries a `# skip-ok:` header -- a real file, so $0 actually
# resolves to something readable.
u_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-u-suite.XXXXXX")"
cat > "$u_file" <<EOF
#!/bin/bash
# skip-ok: every case in this fixture legitimately requires live infra
source "$SCRIPT_DIR/lib/harness.sh"
DXE_TEST_RESULTS="\$(mktemp "\${TMPDIR:-/tmp}/dxe-harness-u-results.XXXXXX")"
export DXE_TEST_RESULTS
skip --class live "no container"
finish
EOF
if bash "$u_file" >/dev/null 2>&1; then
    u_status=0
else
    u_status=$?
fi
check test "$u_status" -eq 0
rm -f "$u_file"

# --- (u2) the (t) case again, but through a REAL, readable file with no
# `# skip-ok:` line -- distinct from (t)'s "$0 is literally not a file at
# all" path through the same guard.
u2_file="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-u2-suite.XXXXXX")"
cat > "$u2_file" <<EOF
#!/bin/bash
# no skip-ok header on this suite
source "$SCRIPT_DIR/lib/harness.sh"
DXE_TEST_RESULTS="\$(mktemp "\${TMPDIR:-/tmp}/dxe-harness-u2-results.XXXXXX")"
export DXE_TEST_RESULTS
skip --class live "no container"
finish
EOF
if bash "$u2_file" >/dev/null 2>&1; then
    u2_status=0
else
    u2_status=$?
fi
check test "$u2_status" -ne 0
rm -f "$u2_file"

# --- (v) finish's summary prints a second "Skipped classes:" line, with
# per-class counts, only when at least one skip was recorded.
v_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-v-results.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 true >/dev/null
    skip --class live "one"
    skip --class live "two"
    skip --class destructive "three"
    finish
' 2>&1)"
check contains "$v_out" "Skipped classes:"
check contains "$v_out" "live=2"
check contains "$v_out" "destructive=1"

v2_out="$(SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-v2-results.XXXXXX")"
    export DXE_TEST_RESULTS
    expect_exit 0 true >/dev/null
    finish
' 2>&1)"
check reject contains "$v2_out" "Skipped classes:"

# --- (w) finish fails when the real (pre-fixture) ~/.local/state/dxe tree
# changed during a with_fixture suite (Fable D9). Runs in a nested bash -c
# whose HOME is a throwaway temp dir standing in for "the real HOME" --
# this never touches the actual developer machine's home. The real HOME is
# captured by with_fixture's first call, before it redirects HOME to the
# fixture; the rogue write below lands in the ORIGINAL (pre-fixture) tree,
# simulating something that failed to isolate.
w_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-w-realhome.XXXXXX")"
if SCRIPT_DIR="$SCRIPT_DIR" W_HOME="$w_home" bash -c '
    HOME="$W_HOME"
    unset XDG_STATE_HOME
    export HOME
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-w-results.XXXXXX")"
    export DXE_TEST_RESULTS
    with_fixture >/dev/null
    expect_exit 0 true >/dev/null
    mkdir -p "$W_HOME/.local/state/dxe/known_hosts.d"
    : > "$W_HOME/.local/state/dxe/known_hosts.d/rogue"
    finish
' >/dev/null 2>&1; then
    w_status=0
else
    w_status=$?
fi
check test "$w_status" -ne 0
rm -rf "$w_home"

# --- (x) sanity: finish does NOT report a breach when with_fixture was
# used and the real tree was genuinely never touched.
x_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-x-realhome.XXXXXX")"
if SCRIPT_DIR="$SCRIPT_DIR" X_HOME="$x_home" bash -c '
    HOME="$X_HOME"
    unset XDG_STATE_HOME
    export HOME
    source "$SCRIPT_DIR/lib/harness.sh"
    DXE_TEST_RESULTS="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-x-results.XXXXXX")"
    export DXE_TEST_RESULTS
    with_fixture >/dev/null
    expect_exit 0 true >/dev/null
    finish
' >/dev/null 2>&1; then
    x_status=0
else
    x_status=$?
fi
check test "$x_status" -eq 0
rm -rf "$x_home"

# =========================================================================
# WP1.7 -- wait_until / wait_for_pid_exit (Fable D10): bounded-attempt
# polling that never asserts elapsed wall-clock time.
# =========================================================================

y_fake_dir="$(fake_tool_dir_create "$SCRIPT_DIR")"
fake_tool_write "$y_fake_dir" fake-sleep '
[ -z "${DXE_FAKE_SLEEP_LOG:-}" ] || printf "%s\n" "$1" >> "$DXE_FAKE_SLEEP_LOG"
exit 0
'

# --- (y) An already-true condition returns 0 immediately, with zero sleeps
# recorded -- wait_until must check before ever sleeping, exactly like
# dx_wait_until (bin/lib/dx-host-util.sh).
y_sleep_log="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-y-sleep.XXXXXX")"
rm -f "$y_sleep_log"
y_out="$(SCRIPT_DIR="$SCRIPT_DIR" Y_FAKE_DIR="$y_fake_dir" Y_LOG="$y_sleep_log" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    PATH="$Y_FAKE_DIR:$PATH"
    DX_SLEEP=fake-sleep
    export DXE_FAKE_SLEEP_LOG="$Y_LOG"
    wait_until "true" 5
    echo "status=$?"
')"
check contains "$y_out" "status=0"
check test ! -s "$y_sleep_log"
rm -f "$y_sleep_log"

# --- (z) A condition that only becomes true after a few failed checks
# succeeds once it does, having recorded exactly that many sleeps -- proves
# wait_until actually retries rather than checking once and giving up.
z_counter="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-z-counter.XXXXXX")"
printf '0\n' > "$z_counter"
z_sleep_log="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-z-sleep.XXXXXX")"
rm -f "$z_sleep_log"
z_out="$(SCRIPT_DIR="$SCRIPT_DIR" Y_FAKE_DIR="$y_fake_dir" Z_COUNTER="$z_counter" Z_LOG="$z_sleep_log" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    PATH="$Y_FAKE_DIR:$PATH"
    DX_SLEEP=fake-sleep
    export DXE_FAKE_SLEEP_LOG="$Z_LOG"
    z_ready() {
        local n
        n="$(cat "$Z_COUNTER")"
        n=$((n + 1))
        printf "%s\n" "$n" > "$Z_COUNTER"
        [ "$n" -ge 3 ]
    }
    wait_until z_ready 10
    echo "status=$?"
')"
check contains "$z_out" "status=0"
check test "$(wc -l < "$z_sleep_log" | tr -d ' ')" -eq 2
rm -f "$z_counter" "$z_sleep_log"

# --- (aa) A condition that never becomes true fails once the attempt limit
# is reached -- bounded by attempt COUNT, never a wall-clock read. The last
# of the 4 checks exhausts the limit without a trailing sleep, so 4 checks
# leave exactly 3 recorded sleeps (checked-then-slept, checked-then-slept,
# checked-then-slept, checked-then-gave-up).
aa_sleep_log="$(mktemp "${TMPDIR:-/tmp}/dxe-harness-aa-sleep.XXXXXX")"
rm -f "$aa_sleep_log"
aa_out="$(SCRIPT_DIR="$SCRIPT_DIR" Y_FAKE_DIR="$y_fake_dir" AA_LOG="$aa_sleep_log" bash -c '
    source "$SCRIPT_DIR/lib/harness.sh"
    PATH="$Y_FAKE_DIR:$PATH"
    DX_SLEEP=fake-sleep
    export DXE_FAKE_SLEEP_LOG="$AA_LOG"
    wait_until "false" 4
    echo "status=$?"
')"
check contains "$aa_out" "status=1"
check test "$(wc -l < "$aa_sleep_log" | tr -d ' ')" -eq 3
rm -f "$aa_sleep_log"
rm -rf "$y_fake_dir"

# --- (bb) wait_for_pid_exit returns 0 once a real background process has
# actually exited -- a genuine liveness check, not a fixed wait. The child
# is spawned via `bash -c` (never a bare `sleep <number>` line -- WP1.7's
# own bare-sleep contract forbids that in a `# tier: unit` suite, and this
# file carries that header).
bash -c 'exit 0' & bb_pid=$!
wait "$bb_pid" 2>/dev/null || true
check wait_for_pid_exit "$bb_pid" 20

# --- (cc) wait_for_pid_exit fails (bounded, not a hang) against a pid that
# is still alive once the attempt limit is reached.
bash -c 'exec sleep 5' & cc_pid=$!
check reject wait_for_pid_exit "$cc_pid" 3
kill "$cc_pid" 2>/dev/null || true
wait "$cc_pid" 2>/dev/null || true

# =========================================================================
# Root cause found in CI: DXE_TEST_RESULTS is exported, so a suite that
# runs ANOTHER suite as a plain child process (`bash tests/test_sectionN.sh`,
# as test_section20_skip_integration.sh does for 15/16/17) used to hand its
# own results file down by ordinary environment inheritance. The child's
# own first test_pass/test_fail/skip appended onto the PARENT's file, and
# the child's own finish/exit_with_code then deleted that shared file as
# its last step -- so an earlier real failure (or even the parent's own
# prior pass lines) leaked into an unrelated later suite's tally, and
# whichever suite ran after the child inherited a `finish` deleted out from
# under it. _dxe_harness_results_file's owner check (DXE_TEST_RESULTS_OWNER
# above) is the by-construction fix; this proves it end to end against a
# REAL nested suite process, not just a synthetic condition.
# =========================================================================

# --- (ee) An OUTER script records one case of its own, then runs a real
# nested SUITE FILE (its own `bash` process, inheriting the outer's
# DXE_TEST_RESULTS/OWNER purely by ordinary environment inheritance -- no
# explicit override, exactly test_section20_skip_integration.sh's shape)
# that records two cases of its own and calls finish. The outer's own
# results file must still show exactly its own one line afterwards (proven
# by the outer script itself reading $DXE_TEST_RESULTS AFTER the nested run
# returns -- environment inheritance is one-way, so the child's own
# reassignment cannot have touched the parent's shell variable regardless
# of what this check does; what could break it is the child appending
# INTO the same file, which is exactly what the owner check prevents), and
# the nested run's own summary must report only its own two cases, never
# three.
ee_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-harness-ee.XXXXXX")"
ee_nested_file="$ee_dir/test_ee_nested.sh"
cat > "$ee_nested_file" <<EOF
#!/bin/bash
source "$SCRIPT_DIR/lib/harness.sh"
expect_exit 0 true >/dev/null
expect_exit 0 true >/dev/null
finish
EOF
ee_outer_file="$ee_dir/outer.sh"
cat > "$ee_outer_file" <<EOF
#!/bin/bash
source "$SCRIPT_DIR/lib/harness.sh"
expect_exit 0 true >/dev/null
bash "$ee_nested_file"
echo "outer_lines=\$(wc -l < "\$DXE_TEST_RESULTS" | tr -d ' ')"
EOF
ee_out="$(bash "$ee_outer_file" 2>&1)" && ee_status=0 || ee_status=$?
check test "$ee_status" -eq 0
check contains "$ee_out" "2 passed"
check contains "$ee_out" "outer_lines=1"
rm -rf "$ee_dir"

rm -f "$RESULTS"

[ "$failures" -eq 0 ]
