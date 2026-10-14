#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
set -uo pipefail

# WP-TMPGUARD: a test fixture that cannot be created must never delete (or
# otherwise change) the checkout the suite runs from.
#
# Incident 2026-10-15: two agent worktrees were wiped. Many suites create
# their fixture with
#     X="$(mktemp -d "${TMPDIR:-/tmp}/dxe-....XXXXXX")"
#     X="$(cd "$X" && pwd -P)"          # sometimes followed by `|| exit 1`
#     trap 'rm -rf "$X"' EXIT           # or a later rm -rf "$X"
# When mktemp fails (disk full, a read-only or missing TMPDIR) X is empty,
# `cd ""` succeeds without moving, so X becomes the CURRENT DIRECTORY --
# normally the checkout root -- and the cleanup deletes the checkout. Two
# related defects ride along and are pinned here too:
#   - `git -C "" ...` also means "the current directory":
#     tests/test_runtime_boundary_audit.sh, given an empty fixture, runs
#     `git init`, `git config user.email/user.name/commit.gpgsign`,
#     `git add -A` and `git commit` IN THE CHECKOUT (its repository config
#     is shared by every worktree);
#   - the harness's own results file is a mktemp file too: when it cannot be
#     created every test_pass/test_fail is silently dropped and
#     print_summary + exit_with_code exit 0. Run with a missing TMPDIR, 57 of
#     the repository's suites currently "pass" that way.
#
# Interface contract:
#
#  1. dxe_test_mktemp_dir VAR TEMPLATE -- defined in tests/lib/harness.sh, so
#     every suite that sources tests/test_helpers.sh (or harness.sh itself)
#     has it. harness.sh stays import-pure (a function definition only).
#     - Runs `mktemp -d TEMPLATE`, with mktemp found through PATH.
#     - Success: assigns VAR -- in the CALLING shell, so not from a subshell
#       and not as a `local` -- the new directory's physical path, exactly
#       as `cd -P -- DIR && pwd -P` prints it; prints nothing (stdout or
#       stderr); returns 0. The directory is the new, empty one mktemp made.
#       A relative path from mktemp is resolved against the current
#       directory, never through CDPATH.
#     - Failure: the calling shell EXITS with status 1 (never `return`: a
#       caller without `set -e` must not carry on with a bad path), after a
#       stderr line containing the words "cannot create a temporary
#       directory" and TEMPLATE. Failure is any of:
#         a. mktemp exits non-zero;
#         b. mktemp prints an empty path (even with status 0);
#         c. the printed path is not an existing directory, or is a symlink;
#         d. the path, resolved physically, is the same as -- or an ancestor
#            of -- the current directory, $HOME, or the checkout harness.sh
#            belongs to (the directory two levels above tests/lib/harness.sh).
#            "/" and "." are therefore always refused.
#       On failure VAR is never assigned (an EXIT trap the caller installed
#       earlier still sees VAR's previous value) and nothing is created,
#       changed or removed: no rm, rmdir, unlink, mv, chmod, chown, chgrp or
#       find runs.
#     - The physical path is computed (cd -P --) only after checks a-c, never
#       with a bare `cd "$X"`.
#
#  2. Every suite site that makes a fixture directory with mktemp and later
#     removes it (directly, from an EXIT trap or through a cleanup helper)
#     or hands it to git uses dxe_test_mktemp_dir -- or an equivalent
#     explicit check that stops the suite before the path is used, e.g.
#         X="$(mktemp -d ...)" || exit 1
#         [ -n "$X" ] && [ -d "$X" ] && [ ! -L "$X" ] || exit 1
#         X="$(cd -P -- "$X" && pwd -P)" || exit 1
#     The fixture templates this file injects failures into keep their
#     names (tests/test_section17_dx_ai_runtime.sh: dxe-creds-test,
#     dxe-creds-idempotent, dxe-creds-unsafe, dxe-creds-hardening,
#     dxe-creds-statusline; tests/test_runtime_boundary_audit.sh: the four
#     dxe-runtime-audit fixtures, in file order).
#     Pinned per suite below. Run from a DECOY checkout (cwd = the decoy
#     root, invoking the decoy's own copy of the suite), either with TMPDIR
#     naming a directory that does not exist, or with only one named
#     fixture's mktemp failing, the suite:
#       - leaves the decoy root and its sentinel file in place;
#       - adds, removes or changes no file anywhere in the decoy;
#       - exits non-zero (a fixture it cannot create is a failure, not a
#         pass);
#       - stops at the first mktemp failure: no case result line
#         (✓ PASS / ✗ FAIL / ○ SKIP) is printed after it;
#       - runs no rm/rmdir/unlink/mv/chmod/chown/chgrp, find -delete or
#         rsync --delete on any existing path outside the decoy and its TMPDIR.
#
#  3. tests/lib/harness.sh fails closed whenever it cannot create a file or
#     directory it needs, instead of carrying on with an empty path:
#     - the results file (_dxe_harness_results_file): the suite exits
#       non-zero with an error naming the "results file", so with a missing
#       TMPDIR a suite that records only passes, or whose failures were
#       dropped, never exits 0 -- through print_summary + exit_with_code
#       (tests/test_helpers.sh) or through finish. It stops at the first
#       record it cannot store (most suites record a case before they make
#       their first fixture, so item 2's "stops at the first mktemp failure"
#       holds for them through this rule);
#     - with_fixture and with_fake_runtime: exit non-zero; the caller never
#       continues with HOME/TMPDIR derived from an empty directory, or with
#       PATH's fake directory empty (an empty PATH entry is the current
#       directory, and the REAL docker/ssh behind it would answer).
#
# Safety design of THIS suite (incidents 2026-10-11 and 2026-10-15). No
# affected suite is ever run from the real checkout, and nothing here hands a
# dangerous path to a real destructive command:
#   - every suite run happens in a DECOY: a fresh copy of tests/, bin/ and
#     container/ inside this file's own mktemp directory, with the decoy root
#     as the working directory. Before each run the decoy is checked to be a
#     real directory inside that scratch directory and not the checkout, $HOME
#     or / (or an ancestor of any of them); otherwise the whole file aborts;
#   - each run's PATH starts with a guard directory: fail-closed fakes for
#     ssh/scp/sftp/docker/tailscale/container/nix/curl (tests/lib/
#     fake-tools.sh), and wrappers for rm/rmdir/unlink/mv/chmod/chown/chgrp/
#     find/rsync that run the real tool only when every existing path operand
#     resolves inside the decoy (the decoy root included, so a suite that
#     deletes its checkout really deletes the decoy) or inside the run's own
#     TMPDIR (a scratch directory next to the decoy); anything else is
#     refused and logged;
#   - HOME is a scratch directory, git cannot discover a repository above
#     the scratch directory (GIT_CEILING_DIRECTORIES), stdin is /dev/null,
#     and each run is bounded in time by a perl supervisor that kills its
#     whole process group;
#   - on macOS each run also executes under sandbox-exec, which denies every
#     file write outside the decoy and the run's own directory and all
#     outbound network and Apple container-runtime connections;
#   - the dxe_test_mktemp_dir cases run the helper from a decoy copy of
#     harness.sh with recording stubs (record, do nothing) for every
#     destructive command first on PATH and cwd in a scratch directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

test_section "WP-TMPGUARD: a fixture that cannot be created never deletes the checkout"

tg_abort() {
    echo "test_tmpdir_failure_safety: ABORT: $*" >&2
    exit 1
}

# tg_covers A B: true when B is A or lies below A (physical paths, whole
# components).
tg_covers() {
    local a="${1%/}"
    case "$2/" in
        "$a"/*) return 0 ;;
    esac
    return 1
}

tg_physical() {
    (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# --- this file's own scratch directory, checked before anything uses it ----
TG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-tmpguard.XXXXXX")" || tg_abort "cannot create a scratch directory under ${TMPDIR:-/tmp}"
if [ -z "$TG_ROOT" ] || [ ! -d "$TG_ROOT" ] || [ -L "$TG_ROOT" ]; then
    tg_abort "mktemp gave no usable scratch directory [$TG_ROOT]"
fi
case "${TG_ROOT##*/}" in
    dxe-tmpguard.??????) : ;;
    *) tg_abort "unexpected scratch directory name [$TG_ROOT]" ;;
esac
trap 'persist_fixture_cleanup "$TG_ROOT"' EXIT
TG_ROOT_P="$(tg_physical "$TG_ROOT")" || tg_abort "cannot resolve the scratch directory [$TG_ROOT]"
[ -n "$TG_ROOT_P" ] || tg_abort "empty physical scratch path"

TG_CHECKOUT_P="$(tg_physical "$BASE_DIR")" || tg_abort "cannot resolve the checkout [$BASE_DIR]"
TG_CWD_P="$(pwd -P)"
TG_HOME_P=""
[ -n "${HOME:-}" ] && TG_HOME_P="$(tg_physical "$HOME")"
TG_ACCOUNT_HOME_P="$(perl -e 'my $h = (getpwuid($>))[7]; print $h if defined $h' 2>/dev/null)"
[ -n "$TG_ACCOUNT_HOME_P" ] && TG_ACCOUNT_HOME_P="$(tg_physical "$TG_ACCOUNT_HOME_P")"

# tg_refuse_dangerous LABEL DIR: abort the whole file unless DIR is a real
# directory strictly inside this file's scratch directory that neither is nor
# contains the checkout, the cwd, $HOME, the account home or /.
tg_refuse_dangerous() {
    local label="$1" dir="$2" dir_p
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || tg_abort "$label [$dir] is not a real directory"
    dir_p="$(tg_physical "$dir")" || tg_abort "$label [$dir] does not resolve"
    [ "$dir_p" != / ] || tg_abort "$label is /"
    case "$dir_p" in
        "$TG_ROOT_P"/?*) : ;;
        *) tg_abort "$label [$dir_p] is not inside the scratch directory [$TG_ROOT_P]" ;;
    esac
    ! tg_covers "$dir_p" "$TG_CHECKOUT_P" || tg_abort "$label [$dir_p] is or contains the checkout"
    ! tg_covers "$TG_CHECKOUT_P" "$dir_p" || tg_abort "$label [$dir_p] is inside the checkout"
    ! tg_covers "$dir_p" "$TG_CWD_P" || tg_abort "$label [$dir_p] is or contains the working directory"
    if [ -n "$TG_HOME_P" ]; then
        ! tg_covers "$dir_p" "$TG_HOME_P" || tg_abort "$label [$dir_p] is or contains \$HOME"
    fi
    if [ -n "$TG_ACCOUNT_HOME_P" ]; then
        ! tg_covers "$dir_p" "$TG_ACCOUNT_HOME_P" || tg_abort "$label [$dir_p] is or contains the account home"
    fi
    return 0
}

[ "$TG_ROOT_P" != / ] || tg_abort "the scratch directory is /"
! tg_covers "$TG_ROOT_P" "$TG_CHECKOUT_P" || tg_abort "the scratch directory contains the checkout"
! tg_covers "$TG_CHECKOUT_P" "$TG_ROOT_P" || tg_abort "the scratch directory is inside the checkout (TMPDIR inside the repository)"
! tg_covers "$TG_ROOT_P" "$TG_CWD_P" || tg_abort "the scratch directory contains the working directory"
if [ -n "$TG_HOME_P" ]; then
    ! tg_covers "$TG_ROOT_P" "$TG_HOME_P" || tg_abort "the scratch directory contains \$HOME"
fi

# --- tools ----------------------------------------------------------------
TG_BASH="$(command -v bash)" || TG_BASH="$BASH"
TG_PERL="$(command -v perl)" || tg_abort "perl is required"
TG_ENV="$(command -v env)" || tg_abort "env is required"
TG_SYS_PATH="$(dirname "$TG_BASH"):/usr/bin:/bin:/usr/sbin:/sbin"
TG_SENTINEL=DECOY-SENTINEL
TG_CASE_MARK='@@dxe-tmpguard: mktemp failed'
TG_SANDBOX=no
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] \
    && /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    TG_SANDBOX=yes
fi
case "$TG_ROOT_P" in
    *'"'* | *'\'*) TG_SANDBOX=no ;;
esac

# tg_supervise LIMIT CWD OUT -- CMD...: run CMD in its own process group with
# cwd CWD, stdin /dev/null, stdout and stderr appended to OUT; kill the whole
# group after LIMIT seconds (status 124). Returns CMD's status.
tg_supervise() {
    local limit="$1" cwd="$2" out="$3"
    shift 4
    (
        cd -P -- "$cwd" || exit 125
        exec "$TG_PERL" -e '
            my $limit = shift @ARGV;
            my $pid = fork();
            defined $pid or exit 125;
            if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127; }
            $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; print STDERR "dxe-tmpguard: killed after ${limit}s\n"; exit 124; };
            alarm $limit;
            waitpid($pid, 0);
            alarm 0;
            exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
        ' "$limit" "$@"
    ) </dev/null >>"$out" 2>&1
}

# --- the pristine copy every decoy is made from ----------------------------
TG_PRISTINE="$TG_ROOT_P/pristine"
mkdir "$TG_PRISTINE" || tg_abort "cannot create $TG_PRISTINE"
for tg_d in tests bin container; do
    cp -R "$BASE_DIR/$tg_d" "$TG_PRISTINE/$tg_d" || tg_abort "cannot copy $tg_d into the pristine decoy"
done
tg_refuse_dangerous "the pristine decoy" "$TG_PRISTINE"

# Guard bodies, sourced by the per-run wrappers (which set the tg_* values).
TG_TOOLS="$TG_ROOT_P/tools"
mkdir "$TG_TOOLS" || tg_abort "cannot create $TG_TOOLS"
cat > "$TG_TOOLS/destructive-guard.sh" <<'GUARD'
# Sourced by a destructive-command wrapper with tg_tool, tg_real, tg_log,
# tg_decoy and tg_tmp (the decoy and the run's TMPDIR, physical, no trailing
# slash) set. Uses builtins only.
tg_canon() {
    local p="$1" parent base rest="" c
    case "$p" in
        /*) : ;;
        *) p="$(pwd -P)/$p" ;;
    esac
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    base="${p##*/}"
    parent="${p%/*}"
    [ -n "$parent" ] || parent=/
    case "$base" in
        "" | . | ..)
            c="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || c="?"
            printf '%s\n' "$c"
            return 0
            ;;
    esac
    while [ ! -d "$parent" ]; do
        rest="/${parent##*/}$rest"
        parent="${parent%/*}"
        [ -n "$parent" ] || parent=/
    done
    case "$rest" in
        */. | */./* | */.. | */../*) printf '?\n'; return 0 ;;
    esac
    c="$(cd -P -- "$parent" 2>/dev/null && pwd -P)" || { printf '?\n'; return 0; }
    printf '%s%s/%s\n' "${c%/}" "$rest" "$base"
}
tg_check=yes
case "$tg_tool" in
    find)
        tg_check=no
        for tg_a in "$@"; do [ "$tg_a" = -delete ] && tg_check=yes; done
        ;;
    rsync)
        tg_check=no
        for tg_a in "$@"; do
            case "$tg_a" in --delete* | --remove-source-files) tg_check=yes ;; esac
        done
        ;;
esac
if [ "$tg_check" = yes ]; then
    tg_opts=yes
    for tg_a in "$@"; do
        if [ "$tg_opts" = yes ]; then
            case "$tg_a" in
                --) tg_opts=no; continue ;;
                -?*) continue ;;
            esac
        fi
        [ -n "$tg_a" ] || continue
        [ -e "$tg_a" ] || [ -L "$tg_a" ] || continue
        tg_c="$(tg_canon "$tg_a")"
        case "$tg_c/" in
            "$tg_decoy"/* | "$tg_tmp"/*) : ;;
            *)
                printf '%s %s [operand %s resolves to %s]\n' "$tg_tool" "$*" "$tg_a" "$tg_c" >> "$tg_log"
                printf 'dxe-tmpguard: refused %s on %s: outside the decoy checkout and its TMPDIR\n' "$tg_tool" "$tg_a" >&2
                exit 1
                ;;
        esac
    done
fi
exec "$tg_real" "$@"
GUARD
cat > "$TG_TOOLS/mktemp-guard.sh" <<'GUARD'
# Sourced by the mktemp wrapper with tg_real, tg_pattern (empty: never
# inject), tg_nth, tg_count, tg_hits and tg_events set. Uses builtins only.
tg_inject=no
if [ -n "$tg_pattern" ]; then
    for tg_a in "$@"; do
        case "$tg_a" in
            "$tg_pattern" | */"$tg_pattern") tg_inject=yes ;;
        esac
    done
    if [ "$tg_inject" = yes ]; then
        tg_n=0
        if [ -s "$tg_count" ]; then read -r tg_n < "$tg_count"; fi
        tg_n=$((tg_n + 1))
        printf '%s\n' "$tg_n" > "$tg_count"
        [ "$tg_n" -eq "$tg_nth" ] || tg_inject=no
    fi
fi
if [ "$tg_inject" = yes ]; then
    printf '%s\n' "$*" >> "$tg_hits"
    printf '@@dxe-tmpguard: mktemp failed: %s@@\n' "$*" >> "$tg_events"
    printf 'mktemp: %s: injected failure (dxe-tmpguard)\n' "$*" >&2
    exit 1
fi
"$tg_real" "$@"
tg_rc=$?
if [ "$tg_rc" -ne 0 ]; then
    printf '@@dxe-tmpguard: mktemp failed: %s@@\n' "$*" >> "$tg_events"
fi
exit "$tg_rc"
GUARD

# tg_guard_build DIR DECOY_P TMP_P LOG EVENTS PATTERN NTH COUNT HITS
tg_guard_build() {
    local dir="$1" decoy_p="$2" tmp_p="$3" log="$4" events="$5" pattern="$6" nth="$7" count="$8" hits="$9" tool real
    mkdir "$dir" || tg_abort "cannot create the guard directory $dir"
    for tool in $FAKE_TOOLS_FAIL_CLOSED_LIST; do
        fake_tool_write "$dir" "$tool" "echo 'dxe-tmpguard: no real $tool from a decoy run' >&2
exit 99"
    done
    for tool in rm rmdir unlink mv chmod chown chgrp find rsync; do
        real="$(command -v "$tool")" || continue
        printf '#!%s\ntg_tool=%q; tg_real=%q; tg_decoy=%q; tg_tmp=%q; tg_log=%q\n. %q\n' \
            "$TG_BASH" "$tool" "$real" "$decoy_p" "$tmp_p" "$log" "$TG_TOOLS/destructive-guard.sh" > "$dir/$tool"
        chmod 0755 "$dir/$tool"
    done
    real="$(command -v mktemp)" || tg_abort "mktemp is required"
    printf '#!%s\ntg_real=%q; tg_pattern=%q; tg_nth=%q; tg_count=%q; tg_hits=%q; tg_events=%q\n. %q\n' \
        "$TG_BASH" "$real" "$pattern" "$nth" "$count" "$hits" "$events" "$TG_TOOLS/mktemp-guard.sh" > "$dir/mktemp"
    chmod 0755 "$dir/mktemp"
}

tg_sandbox_profile() { # DECOY_P RUN_P
    printf '(version 1)(allow default)(deny file-write* (subpath "/"))'
    printf '(allow file-write* (subpath "%s") (subpath "%s")' "$1" "$2"
    printf ' (literal "/dev/null") (literal "/dev/tty") (literal "/dev/zero") (regex #"^/dev/fd/"))'
    printf '(deny network-outbound)(deny mach-lookup (global-name-prefix "com.apple.container"))'
}

tg_snapshot() { # DIR
    if [ ! -d "$1" ]; then
        echo "(the decoy directory is gone)"
        return 0
    fi
    (
        cd -P -- "$1" || exit 1
        find . -print 2>&1 | LC_ALL=C sort
        find . -type f -exec cksum {} + 2>&1 | LC_ALL=C sort
    )
}

# tg_decoy_run ID SUITE_REL [PATTERN NTH] [PROBE_SOURCE]
# Builds decoy-ID and run-ID, then runs the decoy's copy of SUITE_REL from
# the decoy root. With PATTERN empty, TMPDIR names a directory that does not
# exist; otherwise TMPDIR is a real scratch directory and only the NTH mktemp
# call whose template ends in PATTERN fails. PROBE_SOURCE, if given, is
# copied to SUITE_REL inside the decoy first.
# Sets TG_RUN TG_DECOY TG_RC TG_EVENTS.
tg_decoy_run() {
    local id="$1" suite="$2" pattern="${3:-}" nth="${4:-1}" probe="${5:-}" tmp sandbox_args
    TG_RUN="$TG_ROOT_P/run-$id"
    TG_DECOY="$TG_ROOT_P/decoy-$id"
    TG_EVENTS="$TG_RUN/events"
    mkdir "$TG_RUN" "$TG_RUN/home" || tg_abort "cannot create $TG_RUN"
    cp -R "$TG_PRISTINE" "$TG_DECOY" || tg_abort "cannot copy the decoy for $id"
    if [ -n "$probe" ]; then
        cp "$probe" "$TG_DECOY/$suite" || tg_abort "cannot place the probe for $id"
    fi
    printf 'decoy checkout sentinel for %s\n' "$id" > "$TG_DECOY/$TG_SENTINEL"
    tg_refuse_dangerous "decoy $id" "$TG_DECOY"
    TG_DECOY="$(tg_physical "$TG_DECOY")"
    [ -f "$TG_DECOY/$suite" ] || tg_abort "decoy $id has no $suite"
    tg_snapshot "$TG_DECOY" > "$TG_RUN/before"
    : > "$TG_RUN/refused.log"
    : > "$TG_EVENTS"
    if [ -n "$pattern" ]; then
        tmp="$TG_RUN/tmp"
        mkdir "$tmp" || tg_abort "cannot create $tmp"
    else
        tmp="$TG_RUN/missing-tmpdir"
    fi
    tg_guard_build "$TG_RUN/guard" "$TG_DECOY" "$tmp" "$TG_RUN/refused.log" "$TG_EVENTS" \
        "$pattern" "$nth" "$TG_RUN/mktemp-count" "$TG_RUN/mktemp-hits.log"
    sandbox_args=()
    if [ "$TG_SANDBOX" = yes ]; then
        sandbox_args=(/usr/bin/sandbox-exec -p "$(tg_sandbox_profile "$TG_DECOY" "$TG_RUN")")
    fi
    tg_supervise 300 "$TG_DECOY" "$TG_EVENTS" -- "$TG_ENV" -i \
        HOME="$TG_RUN/home" USER="${USER:-dxe}" LOGNAME="${LOGNAME:-${USER:-dxe}}" LANG="${LANG:-C}" TERM=dumb \
        PATH="$TG_RUN/guard:$TG_SYS_PATH" TMPDIR="$tmp" SKIP_INTEGRATION=true \
        DX_PROFILES_DIR="$TG_DECOY/tests/profiles" GIT_CEILING_DIRECTORIES="$TG_ROOT_P" GIT_CONFIG_NOSYSTEM=1 \
        "${sandbox_args[@]+"${sandbox_args[@]}"}" "$TG_BASH" "$suite"
    TG_RC=$?
    tg_snapshot "$TG_DECOY" > "$TG_RUN/after"
}

# Prints the first case result line that follows the first mktemp failure
# marker in EVENTS (nothing when there is none).
tg_case_after_failure() {
    LC_ALL=C awk -v mark="$TG_CASE_MARK" '
        index($0, mark) { seen = 1; next }
        seen && (index($0, "✓ PASS") || index($0, "✗ FAIL") || index($0, "○ SKIP")) { print; exit }
    ' "$1"
}

tg_show() { # FILE [LINES]
    sed -n "1,${2:-12}p" "$1" 2>/dev/null | sed 's/^/      | /'
}

# The five checks every decoy run of a real suite must pass.
tg_assert_decoy_run() { # LABEL
    local label="$1" after
    if [ -d "$TG_DECOY" ] && [ -f "$TG_DECOY/$TG_SENTINEL" ]; then
        test_pass "$label: the decoy checkout root and its sentinel survive"
    else
        test_fail "$label: the decoy checkout root and its sentinel survive (the suite deleted its checkout)"
    fi
    if cmp -s "$TG_RUN/before" "$TG_RUN/after"; then
        test_pass "$label: no file in the decoy checkout is added, removed or changed"
    else
        test_fail "$label: no file in the decoy checkout is added, removed or changed"
        diff "$TG_RUN/before" "$TG_RUN/after" 2>/dev/null | sed -n '1,8p' | sed 's/^/      | /'
    fi
    if [ "$TG_RC" -ne 0 ] && [ "$TG_RC" -ne 124 ]; then
        test_pass "$label: exits non-zero (status $TG_RC)"
    else
        test_fail "$label: exits non-zero (status $TG_RC; 124 = killed by the time bound)"
        tail -n 4 "$TG_EVENTS" | sed 's/^/      | /'
    fi
    after="$(tg_case_after_failure "$TG_EVENTS")"
    if ! grep -Fq -- "$TG_CASE_MARK" "$TG_EVENTS"; then
        test_fail "$label: stops at the first mktemp failure (no mktemp failure was seen at all)"
    elif [ -z "$after" ]; then
        test_pass "$label: stops at the first mktemp failure (no case result after it)"
    else
        test_fail "$label: stops at the first mktemp failure (still ran: $after)"
    fi
    if [ ! -s "$TG_RUN/refused.log" ]; then
        test_pass "$label: no destructive command reaches outside the decoy and its TMPDIR"
    else
        test_fail "$label: no destructive command reaches outside the decoy and its TMPDIR"
        tg_show "$TG_RUN/refused.log" 6
    fi
}

# --- 1. dxe_test_mktemp_dir ------------------------------------------------
TG_HELPER="$TG_ROOT_P/helper"
mkdir "$TG_HELPER" || tg_abort "cannot create $TG_HELPER"
TG_HARNESS="$TG_PRISTINE/tests/lib/harness.sh"
cat > "$TG_HELPER/probe.sh" <<'PROBE'
#!/bin/bash
# probe.sh HARNESS TEMPLATE RESULT_FILE
set -uo pipefail
# shellcheck disable=SC1090
source "$1"
PROBE_RESULT="$3"
X=canary-before
trap 'printf "trap X=[%s]\n" "$X" >> "$PROBE_RESULT"' EXIT
dxe_test_mktemp_dir X "$2"
printf 'returned=%s X=[%s]\n' "$?" "$X" >> "$PROBE_RESULT"
exit 0
PROBE

# tg_helper_run ID TEMPLATE [MKTEMP_STUB_BODY [CDPATH]]: runs the probe with
# cwd helper/ID/cwd, HOME helper/ID/home and recording stubs for every
# destructive command. Sets TG_H (the case directory) and TG_HRC.
tg_helper_run() {
    local id="$1" template="$2" stub="${3:-}" cdpath="${4:-}" tool
    TG_H="$TG_HELPER/$id"
    mkdir -p "$TG_H/cwd" "$TG_H/home" "$TG_H/bin" "$TG_H/rec" || tg_abort "cannot create $TG_H"
    tg_refuse_dangerous "helper case $id" "$TG_H/cwd"
    for tool in rm rmdir unlink mv chmod chown chgrp find; do
        fake_tool_write "$TG_H/rec" "$tool" "printf '%s %s\n' \"\${0##*/}\" \"\$*\" >> $(printf '%q' "$TG_H/destructive.log")
exit 0"
    done
    if [ -n "$stub" ]; then
        fake_tool_write "$TG_H/bin" mktemp "$stub"
    fi
    : > "$TG_H/result"
    : > "$TG_H/out"
    tg_supervise 60 "$TG_H/cwd" "$TG_H/out" -- "$TG_ENV" -i HOME="$TG_H/home" \
        PATH="$TG_H/bin:$TG_H/rec:$TG_SYS_PATH" TMPDIR="$TG_H/missing-tmpdir" LANG="${LANG:-C}" CDPATH="$cdpath" \
        "$TG_BASH" "$TG_HELPER/probe.sh" "$TG_HARNESS" "$template" "$TG_H/result"
    TG_HRC=$?
}

tg_helper_refuses() { # ID WHAT TEMPLATE [STUB]
    local id="$1" what="$2" template="$3" stub="${4:-}" label
    label="dxe_test_mktemp_dir, $what"
    tg_helper_run "$id" "$template" "$stub"
    if [ "$TG_HRC" -eq 1 ] && ! grep -q '^returned=' "$TG_H/result" \
        && grep -Fqx 'trap X=[canary-before]' "$TG_H/result"; then
        test_pass "$label: the caller exits 1 at once and VAR keeps its previous value"
    else
        test_fail "$label: the caller exits 1 at once and VAR keeps its previous value (status $TG_HRC)"
        tg_show "$TG_H/result" 4
        tg_show "$TG_H/out" 4
    fi
    if grep -Fq 'cannot create a temporary directory' "$TG_H/out" && grep -Fq -- "$template" "$TG_H/out"; then
        test_pass "$label: says it cannot create a temporary directory and names the template"
    else
        test_fail "$label: says it cannot create a temporary directory and names the template"
        tg_show "$TG_H/out" 4
    fi
    if [ ! -s "$TG_H/destructive.log" ]; then
        test_pass "$label: runs no destructive command"
    else
        test_fail "$label: runs no destructive command"
        tg_show "$TG_H/destructive.log" 4
    fi
}

# Success: the template's parent is reached through a symlink, so the value
# must be the physical path.
mkdir -p "$TG_HELPER/ok/real" || tg_abort "cannot create the success fixture"
ln -s real "$TG_HELPER/ok/link" || tg_abort "cannot create the success symlink"
TG_OK_REAL="$(tg_physical "$TG_HELPER/ok/real")"
tg_helper_run ok "$TG_HELPER/ok/link/dxe-ok.XXXXXX"
tg_ok_value="$(sed -n 's/^returned=0 X=\[\(.*\)\]$/\1/p' "$TG_H/result")"
if [ "$TG_HRC" -eq 0 ] && [ -n "$tg_ok_value" ] && grep -Fqx "trap X=[$tg_ok_value]" "$TG_H/result"; then
    test_pass "dxe_test_mktemp_dir, success: returns 0 and assigns VAR in the calling shell"
else
    test_fail "dxe_test_mktemp_dir, success: returns 0 and assigns VAR in the calling shell (status $TG_HRC)"
    tg_show "$TG_H/result" 4
    tg_show "$TG_H/out" 4
fi
tg_ok_entries="$(find "$TG_OK_REAL" -mindepth 1 -print 2>/dev/null)"
case "$tg_ok_value" in
    "$TG_OK_REAL"/dxe-ok.??????)
        if [ -d "$tg_ok_value" ] && [ ! -L "$tg_ok_value" ] && [ "$(tg_physical "$tg_ok_value")" = "$tg_ok_value" ] \
            && [ "$tg_ok_entries" = "$tg_ok_value" ]; then
            test_pass "dxe_test_mktemp_dir, success: VAR is the physical path of the one new, empty directory"
        else
            test_fail "dxe_test_mktemp_dir, success: VAR is the physical path of the one new, empty directory (got [$tg_ok_value]; entries [$tg_ok_entries])"
        fi
        ;;
    *) test_fail "dxe_test_mktemp_dir, success: VAR is the physical path of the one new, empty directory (got [$tg_ok_value], want $TG_OK_REAL/dxe-ok.??????)" ;;
esac
if [ ! -s "$TG_H/destructive.log" ] && [ ! -s "$TG_H/out" ]; then
    test_pass "dxe_test_mktemp_dir, success: prints nothing and runs no destructive command"
else
    test_fail "dxe_test_mktemp_dir, success: prints nothing and runs no destructive command"
    tg_show "$TG_H/out" 4
    tg_show "$TG_H/destructive.log" 4
fi

# A relative path from mktemp (a relative TMPDIR) names a directory in the
# current directory; a same-named directory reachable through CDPATH must not
# be picked instead.
mkdir -p "$TG_HELPER/cdpath/cwd/dxe-rel.abcdef" "$TG_HELPER/cdpath/elsewhere/dxe-rel.abcdef" \
    || tg_abort "cannot create the CDPATH fixture"
tg_helper_run cdpath "dxe-rel.XXXXXX" "printf '%s\n' dxe-rel.abcdef" "$TG_HELPER/cdpath/elsewhere"
tg_want="$(tg_physical "$TG_HELPER/cdpath/cwd")/dxe-rel.abcdef"
if [ "$TG_HRC" -eq 0 ] && grep -Fqx "returned=0 X=[$tg_want]" "$TG_H/result" \
    && [ ! -s "$TG_H/out" ] && [ ! -s "$TG_H/destructive.log" ]; then
    test_pass "dxe_test_mktemp_dir, relative path with CDPATH set: resolved against the current directory, not CDPATH"
else
    test_fail "dxe_test_mktemp_dir, relative path with CDPATH set: resolved against the current directory, not CDPATH (status $TG_HRC, want [$tg_want])"
    tg_show "$TG_H/result" 4
    tg_show "$TG_H/out" 4
fi

tg_helper_refuses mktemp-fails "mktemp fails (missing parent directory)" \
    "$TG_HELPER/mktemp-fails/no-such-dir/dxe-x.XXXXXX"
tg_helper_refuses empty "mktemp prints nothing but exits 0" \
    "$TG_HELPER/empty/dxe-x.XXXXXX" 'exit 0'
mkdir -p "$TG_HELPER/file" && : > "$TG_HELPER/file/a-regular-file"
tg_helper_refuses file "mktemp prints a regular file" \
    "$TG_HELPER/file/dxe-x.XXXXXX" "printf '%s\n' $(printf '%q' "$TG_HELPER/file/a-regular-file")"
mkdir -p "$TG_HELPER/symlink/target" && ln -s target "$TG_HELPER/symlink/a-link"
tg_helper_refuses symlink "mktemp prints a symlink to a directory" \
    "$TG_HELPER/symlink/dxe-x.XXXXXX" "printf '%s\n' $(printf '%q' "$TG_HELPER/symlink/a-link")"
tg_helper_refuses root "mktemp prints /" \
    "$TG_HELPER/root/dxe-x.XXXXXX" "printf '%s\n' /"
tg_helper_refuses cwd "mktemp prints . (the current directory)" \
    "$TG_HELPER/cwd/dxe-x.XXXXXX" "printf '%s\n' ."
tg_helper_refuses parent "mktemp prints .. (an ancestor of the current directory)" \
    "$TG_HELPER/parent/dxe-x.XXXXXX" "printf '%s\n' .."
tg_helper_refuses checkout "mktemp prints the checkout harness.sh belongs to" \
    "$TG_HELPER/checkout/dxe-x.XXXXXX" "printf '%s\n' $(printf '%q' "$TG_PRISTINE")"
tg_helper_refuses home "mktemp prints \$HOME" \
    "$TG_HELPER/home/dxe-x.XXXXXX" "printf '%s\n' $(printf '%q' "$TG_HELPER/home/home")"

# --- 2. the harness fails closed -------------------------------------------
TG_PROBES="$TG_ROOT_P/probes"
mkdir "$TG_PROBES" || tg_abort "cannot create $TG_PROBES"
tg_write_probe() { # NAME BODY
    printf '#!/bin/bash\nset -uo pipefail\nSCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n%s\n' "$2" > "$TG_PROBES/$1"
}
tg_write_probe results-pass '# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_helpers.sh"
test_pass "tmpguard probe: a passing case"
print_summary
exit_with_code'
tg_write_probe results-fail '# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_helpers.sh"
test_fail "tmpguard probe: a failing case"
print_summary
exit_with_code'
tg_write_probe results-finish '# shellcheck source=/dev/null
source "$SCRIPT_DIR/test_helpers.sh"
test_pass "tmpguard probe: a passing case"
finish'
tg_write_probe with-fixture '# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/harness.sh"
with_fixture
printf "@@probe-continued@@ HOME=%s TMPDIR=%s\n" "$HOME" "$TMPDIR"
exit 0'
tg_write_probe with-fake-runtime '# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/harness.sh"
with_fake_runtime docker
printf "@@probe-continued@@ PATH=%s\n" "$PATH"
exit 0'

for tg_probe in results-pass results-fail results-finish; do
    tg_decoy_run "probe-$tg_probe" "tests/test_tmpguard_probe.sh" "" 1 "$TG_PROBES/$tg_probe"
    tg_label="harness probe ($tg_probe) with a missing TMPDIR"
    if [ "$TG_RC" -ne 0 ] && [ "$TG_RC" -ne 124 ]; then
        test_pass "$tg_label: the suite exits non-zero (status $TG_RC)"
    else
        test_fail "$tg_label: the suite exits non-zero (status $TG_RC): a suite whose results cannot be recorded reported success"
        tail -n 4 "$TG_EVENTS" | sed 's/^/      | /'
    fi
    if grep -Fq 'results file' "$TG_EVENTS"; then
        test_pass "$tg_label: the error names the results file"
    else
        test_fail "$tg_label: the error names the results file"
        tail -n 4 "$TG_EVENTS" | sed 's/^/      | /'
    fi
done
for tg_probe in with-fixture with-fake-runtime; do
    tg_decoy_run "probe-$tg_probe" "tests/test_tmpguard_probe.sh" "" 1 "$TG_PROBES/$tg_probe"
    tg_label="harness probe ($tg_probe) with a missing TMPDIR"
    if [ "$TG_RC" -ne 0 ] && [ "$TG_RC" -ne 124 ]; then
        test_pass "$tg_label: the caller exits non-zero (status $TG_RC)"
    else
        test_fail "$tg_label: the caller exits non-zero (status $TG_RC)"
    fi
    if ! grep -Fq '@@probe-continued@@' "$TG_EVENTS"; then
        test_pass "$tg_label: the caller does not carry on without its directory"
    else
        test_fail "$tg_label: the caller does not carry on without its directory ($(grep -F '@@probe-continued@@' "$TG_EVENTS" | head -n 1))"
    fi
done

# --- 3. whole suites, run from a decoy with TMPDIR missing ------------------
# Affected (the checkout is deleted or changed today): section 17, section 20
# (it runs section 17 nested, from the same cwd and with the same TMPDIR) and
# the runtime boundary audit. The others are the sites the incident review
# named that are already guarded (mktemp `|| exit 1`, a name check before
# the cleanup, or `set -e`); they are pinned here so they stay that way.
for tg_suite in \
    test_section17_dx_ai_runtime \
    test_section20_skip_integration \
    test_runtime_boundary_audit \
    test_persist_rsync_optional \
    test_persist_vscode_server \
    test_persist_guest_check \
    test_persist_guest_check_unit \
    test_section6_tools \
    test_section3_bootstrap; do
    tg_decoy_run "missing-$tg_suite" "tests/$tg_suite.sh"
    tg_assert_decoy_run "$tg_suite.sh with TMPDIR missing"
done

# --- 4. one fixture at a time: only the named mktemp fails ------------------
# The canonicalise-then-delete sites of section 17. Each run fails only that
# fixture's mktemp, so every site is pinned, not just the suite's first one.
for tg_site in dxe-creds-test dxe-creds-idempotent dxe-creds-unsafe dxe-creds-hardening dxe-creds-statusline; do
    tg_decoy_run "site-$tg_site" "tests/test_section17_dx_ai_runtime.sh" "$tg_site.XXXXXX" 1
    tg_label="test_section17_dx_ai_runtime.sh when only the $tg_site fixture cannot be created"
    if [ -s "$TG_RUN/mktemp-hits.log" ]; then
        test_pass "$tg_label: the injected mktemp failure is reached"
    else
        test_fail "$tg_label: the injected mktemp failure is reached (no mktemp call ends in $tg_site.XXXXXX)"
    fi
    tg_assert_decoy_run "$tg_label"
done
# The four dxe-runtime-audit fixtures (git init/config/add/commit on them).
for tg_nth in 1 2 3 4; do
    tg_decoy_run "site-runtime-audit-$tg_nth" "tests/test_runtime_boundary_audit.sh" "dxe-runtime-audit.XXXXXX" "$tg_nth"
    tg_label="test_runtime_boundary_audit.sh when only dxe-runtime-audit fixture #$tg_nth cannot be created"
    if [ -s "$TG_RUN/mktemp-hits.log" ]; then
        test_pass "$tg_label: the injected mktemp failure is reached"
    else
        test_fail "$tg_label: the injected mktemp failure is reached (fewer than $tg_nth mktemp calls end in dxe-runtime-audit.XXXXXX)"
    fi
    tg_assert_decoy_run "$tg_label"
done

if [ "$TG_SANDBOX" = yes ]; then
    echo "  (decoy runs executed under sandbox-exec: no write outside the decoy and its run directory)"
else
    echo "  (sandbox-exec unavailable: decoy runs relied on the decoy cwd and the PATH guards)"
fi

print_summary
exit_with_code
