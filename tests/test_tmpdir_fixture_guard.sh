#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
set -uo pipefail

# WP-TMPGUARD-b: every fixture directory a suite makes with mktemp fails
# closed, and the sites the first round (tests/test_tmpdir_failure_safety.sh)
# missed stop BEFORE they write, delete or hand to git anything outside their
# own temporary directory.
#
# Why: `X="$(mktemp -d ...)"` with no check leaves X empty when mktemp fails,
# and "$X/persist/home/dx" is then the REAL /persist/home/dx. Inside a dx
# guest /persist/home, /persist/git and /home/dx are real (and /persist lives
# on the user's NAS share): tests/test_dx_restore.sh would write into them and
# then `rm -rf /persist/home /persist/git`, tests/test_herdr_config_persistence.sh
# would run the herdr bootstrap on the real home and delete its config, and
# tests/test_persist_backup_select.sh would `git init/add/commit` in
# /persist/git/repo-a. A canonicalised empty fixture (`cd -P -- ""`) is the
# checkout itself (tests/test_persist_reclaim.sh). And a marker file that
# cannot be created turns "invokes no container/ssh command" into a vacuous
# pass (tests/test_section20_skip_integration.sh).
#
# Interface contract:
#
#  1. Fixture sites, pinned by behaviour. Each site below is run from a DECOY
#     copy of the checkout (cwd = the decoy root, the decoy's own copy of the
#     suite) with a real, writable TMPDIR in which ONLY the named mktemp call
#     fails: the Nth call whose template argument ends in TEMPLATE (a final
#     path component, also matched for `mktemp -t TEMPLATE`). The suite must:
#       a. reach that call (the template keeps its name and its place) with
#          no mktemp call failing before it: every temporary file and
#          directory the suite makes lives under its ${TMPDIR:-/tmp}. (macOS
#          `mktemp -t NAME` ignores TMPDIR and uses the per-user temporary
#          directory, which this suite's sandbox does not let it write, so
#          section 20's `-t` marker and results files fail here as they are
#          and must name "${TMPDIR:-/tmp}/NAME" instead);
#       b. exit non-zero by itself (not killed by the time bound);
#       c. print a line containing "cannot create a temporary" and TEMPLATE
#          -- dxe_test_mktemp_dir's refusal does; an explicit
#          `|| { echo "...: cannot create a temporary file from TEMPLATE" >&2; exit 1; }`
#          does too. mktemp's own error message does not count;
#       d. stop there: no case result line (✓ PASS / ✗ FAIL / ○ SKIP) after
#          the failure;
#       e. leave the decoy checkout as it was (its sentinel file present, no
#          file added, removed or changed);
#       f. after the failure, run no rm, rmdir, unlink, mv, chmod, chown,
#          chgrp, find, rsync, mkdir, cp, ln, git, tar, touch, install, tee
#          or mktemp with any operand outside the decoy and the run's TMPDIR
#          (git also not from a working directory outside them), and no
#          destructive command on an existing path outside them at any time.
#     Sites (file, TEMPLATE, N):
#       tests/test_dx_restore.sh               dxe-dx-restore-test.XXXXXX    1
#       tests/test_herdr_config_persistence.sh dxe-herdr-config-test.XXXXXX  1
#           (Linux-only past its uname check: on other hosts the decoy run
#            puts a `uname` first on PATH that answers Linux for -s)
#       tests/test_dx_backup.sh                dxe-dx-backup-test.XXXXXX     1
#       tests/test_persist_backup_select.sh    dxe-pbs-test.XXXXXX           1
#       tests/test_persist_backup_select.sh    dxe-pbs-findfail.XXXXXX       1
#       tests/test_persist_backup_select.sh    dxe-pbs-statfail.XXXXXX       1
#       tests/test_persist_reclaim.sh          dxe-persist-share.XXXXXX      2 (ROOT)
#       tests/test_persist_reclaim.sh          dxe-persist-share.XXXXXX      3 (EMPTY_ROOT)
#       tests/test_section20_skip_integration.sh dxe-stub-bin.XXXXXX         1
#       tests/test_section20_skip_integration.sh dxe-stub-marker.XXXXXX      1
#       tests/test_section20_skip_integration.sh dxe-stub-marker-runsh-unset.XXXXXX  1
#       tests/test_section20_skip_integration.sh dxe-stub-marker-runsh-refuse.XXXXXX 1
#       tests/test_section20_skip_integration.sh dxe-stub-marker-lt.XXXXXX   1 and 5
#       tests/test_section20_skip_integration.sh dxe-stub-marker-ev.XXXXXX   1
#       tests/test_persist_migrate.sh          dxe-persist-share.XXXXXX      2 (world's ROOT)
#       tests/test_persist_rollback.sh         dxe-persist-share.XXXXXX      2 (world's ROOT)
#           (world() canonicalises with CANON="$(cd -P "$ROOT" && pwd -P)",
#            which is the checkout when ROOT is empty)
#       tests/test_section27_qnap_scripts.sh   dxe-qnap-marker.XXXXXX        1
#       tests/test_section27_qnap_scripts.sh   dxe-qnap-run.XXXXXX           1
#           (the marker file is the "--dry-run never invokes ssh/docker"
#            proof; run_with_stubs makes its run directory inside "$(...)",
#            where a failure would leave only the substitution)
#     (persist_fixture_root_create is the dxe-persist-share caller: a
#     failure there must stop test_persist_reclaim.sh too, so its callers have
#     to check it.)
#
#  2. Static guard over tests/test_*.sh and tests/lib/*.sh. Every mktemp call
#     that makes a directory (an option word -d, -dt, -td, ... or
#     --directory) either goes through dxe_test_mktemp_dir (so there is no
#     such call left on the line) or fails closed on the same statement:
#         X="$(mktemp -d ...)" || exit [N]
#         X="$(mktemp -d ...)" || return [N]
#         X="$(mktemp -d ...)" || { ...; exit [N]; }      (or return)
#         X="$(mktemp -d ...)" || die ...
#     with N non-zero (or `$?`), `&& ...` steps allowed between the call and
#     the `||`, the `||` on a continuation line allowed, and `die` a function
#     defined in the same file or in tests/lib/harness.sh whose last
#     statement is `exit N` (N non-zero). The scan reads the shell syntax, so
#     none of these count: a comment, `||` inside quotes, `||` on another
#     statement (after `;` or a newline), a pipe, `!`, `local`/`export`/
#     `declare` (they hide the status), the call as a command argument or
#     inside `$(cd "$(mktemp -d)" && pwd -P)`, a second command substitution
#     in the same word, `if ! X=...`, or `{ ... }` that does not end in
#     exit/return. Command substitutions: when the call is the whole of a
#     `$( )` (or of its one and-or list, e.g. `$(cd D && mktemp -d T)`), the
#     substitution's value is the call's, so the statement holding it must
#     be guarded (`X="$(mktemp -d T)" || exit 1`; `$(mktemp -d T || exit 1)`
#     alone is not); when the call is one statement among several inside
#     `$( )`, its own statement there must be guarded (the exit leaves the
#     substitution before its later statements use the path). Program text
#     in strings and here-documents (probe scripts, fakes) is scanned the
#     same way.
#     Allowlist (file, exact trimmed line, reason), kept as small as
#     possible: the Nushell probe in tests/test_section15_nushell_env.sh,
#     and test_persist_fixtures.sh's case that expects
#     persist_fixture_nas_create to refuse a missing root.
#
#  2b. A call of a helper that makes and prints a new directory counts
#     exactly like a directory-making mktemp call (same accepted forms,
#     same rules for $( ), strings and here-documents), including the call
#     inside a wrapper. A helper is a function whose last statement is such
#     a call, or that ends printing "$V" (printf ... "$V" / echo "$V") where
#     V was assigned from such a call. The library helpers are the ones in
#     tests/lib/*.sh and tests/test_helpers.sh, known to every file; today
#     fake_tool_dir_create, persist_fixture_root_create and
#     persist_fixture_nas_create, and the scan must find at least these.
#     A suite's own helpers (new_tool_dir, vs_case, new_root, share, ...)
#     count in that suite. So `ROOT="$(persist_fixture_root_create "$S")"`
#     needs `|| exit 1` (a later `case "$ROOT" in ...` check is not the same
#     statement), and `new_root() { persist_fixture_root_create "$S"; }`
#     needs `|| return 1` as well as `R="$(new_root)" || exit 1`.
#
#  2c. The library helpers fail loudly. Called in "$(...)" (as callers do),
#     from a shell that sourced tests/test_helpers.sh, tests/lib/fake-tools.sh
#     and tests/lib/persist-fixtures.sh, when their own mktemp fails:
#       fake_tool_dir_create PARENT, persist_fixture_root_create PARENT and
#       persist_fixture_nas_create ROOT PARENT
#     each returns non-zero, prints nothing on stdout, prints on stderr one
#     line holding both its own name and "cannot create a temporary", and
#     creates or removes nothing. The same holds when mktemp exits 0 but
#     prints nothing.
#
#  2d. dxe_test_mktemp_dir is called only where tests/lib/harness.sh is
#     loaded. A tests/test_*.sh file that calls it sources
#     tests/test_helpers.sh or tests/lib/harness.sh (`source`/`.` of a path
#     ending in one of those names); program text in a string or a
#     here-document (run by another shell: a guest driver, `bash -c`, ssh)
#     that calls it sources one of them itself. Elsewhere the call fails
#     with "command not found" and the program carries on. tests/lib/*.sh
#     are sourced into suites and are exempt. The acceptance probes that run
#     under the harness are allowlisted (tests/test_harness.sh's (hh) body,
#     tests/test_tmpdir_failure_safety.sh's probe.sh).
#
#  3. tests/lib/harness.sh (pinned in tests/test_harness.sh, case (ii)):
#     with_fake_runtime exits non-zero, naming the "fake transcript", when the
#     transcript file cannot be made, and naming "fake <tool>" when the fake
#     cannot be made executable (a fake left non-executable is skipped by the
#     PATH lookup and the REAL tool answers); skip/test_skip exits non-zero,
#     naming the "results file", when the skip record cannot be appended.
#     None of them lets the caller go on to print a pass or a skip.
#
#  4. Section 14's two guest drivers (the <<'DRIVER_EOF' bodies of
#     tests/test_section14_tinty_theming.sh, shipped to the guest and run as
#     `bash DRIVER PROBE`), each run standalone as shipped with bash: with
#     every mktemp working it runs nvim once and exits 0; when its 1st or
#     2nd mktemp call fails it stops there, non-zero (no later mktemp call),
#     and runs neither nvim nor rm.
#
# Safety design of THIS suite (incidents 2026-10-11 and 2026-10-15):
#   - every suite run happens in a DECOY copy of tests/, bin/ and container/
#     inside this file's own scratch directory, checked before each run to be
#     neither the checkout, $HOME, / nor an ancestor of any of them;
#   - each run's PATH starts with a guard directory: fail-closed fakes for
#     ssh/scp/sftp/docker/tailscale/container/nix/curl, wrappers that refuse
#     rm/rmdir/unlink/mv/chmod/chown/chgrp/find/rsync on any existing path
#     outside the decoy and its TMPDIR, and -- once the injected failure has
#     happened -- refuse those and mkdir/cp/ln/git/tar/touch/install/tee/
#     mktemp on ANY operand outside them (the tripwire of contract item 1f:
#     /persist cannot exist on this Mac, so a regression shows up as the
#     attempt, recorded before anything runs);
#   - HOME is a scratch directory, GIT_CEILING_DIRECTORIES stops git above
#     the scratch directory, stdin is /dev/null, and a perl supervisor kills
#     each run's whole process group after 300 s;
#   - on macOS each run executes under sandbox-exec: no file write outside the
#     decoy and its run directory, no outbound network, no Apple container
#     runtime. Without sandbox-exec (Linux) the guest-path suites are NOT run
#     on a host where /persist or /home/dx exists (a dx guest): there a
#     regression could reach the real directories through a shell
#     redirection the PATH guards cannot see. They run on CI's Linux runner
#     and on the Mac, where those paths do not exist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

test_section "WP-TMPGUARD-b: fixture directories fail closed before touching anything outside them"

tgb_abort() {
    echo "test_tmpdir_fixture_guard: ABORT: $*" >&2
    exit 1
}

# tgb_covers A B: true when B is A or lies below A (whole components).
tgb_covers() {
    local a="${1%/}"
    case "$2/" in
        "$a"/*) return 0 ;;
    esac
    return 1
}

tgb_physical() {
    (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# --- this file's own scratch directory, checked before anything uses it ----
TGB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-tmpguard-b.XXXXXX")" || tgb_abort "cannot create a scratch directory under ${TMPDIR:-/tmp}"
if [ -z "$TGB_ROOT" ] || [ ! -d "$TGB_ROOT" ] || [ -L "$TGB_ROOT" ]; then
    tgb_abort "mktemp gave no usable scratch directory [$TGB_ROOT]"
fi
case "${TGB_ROOT##*/}" in
    dxe-tmpguard-b.??????) : ;;
    *) tgb_abort "unexpected scratch directory name [$TGB_ROOT]" ;;
esac
trap 'persist_fixture_cleanup "$TGB_ROOT"' EXIT
TGB_ROOT_P="$(tgb_physical "$TGB_ROOT")" || tgb_abort "cannot resolve the scratch directory [$TGB_ROOT]"
[ -n "$TGB_ROOT_P" ] || tgb_abort "empty physical scratch path"

TGB_CHECKOUT_P="$(tgb_physical "$BASE_DIR")" || tgb_abort "cannot resolve the checkout [$BASE_DIR]"
TGB_CWD_P="$(pwd -P)"
TGB_HOME_P=""
[ -n "${HOME:-}" ] && TGB_HOME_P="$(tgb_physical "$HOME")"
TGB_ACCOUNT_HOME_P="$(perl -e 'my $h = (getpwuid($>))[7]; print $h if defined $h' 2>/dev/null)"
[ -n "$TGB_ACCOUNT_HOME_P" ] && TGB_ACCOUNT_HOME_P="$(tgb_physical "$TGB_ACCOUNT_HOME_P")"

[ "$TGB_ROOT_P" != / ] || tgb_abort "the scratch directory is /"
! tgb_covers "$TGB_ROOT_P" "$TGB_CHECKOUT_P" || tgb_abort "the scratch directory contains the checkout"
! tgb_covers "$TGB_CHECKOUT_P" "$TGB_ROOT_P" || tgb_abort "the scratch directory is inside the checkout (TMPDIR inside the repository)"
! tgb_covers "$TGB_ROOT_P" "$TGB_CWD_P" || tgb_abort "the scratch directory contains the working directory"
if [ -n "$TGB_HOME_P" ]; then
    ! tgb_covers "$TGB_ROOT_P" "$TGB_HOME_P" || tgb_abort "the scratch directory contains \$HOME"
fi

# tgb_refuse_dangerous LABEL DIR: abort the whole file unless DIR is a real
# directory strictly inside this file's scratch directory that neither is nor
# contains the checkout, the cwd, $HOME, the account home or /.
tgb_refuse_dangerous() {
    local label="$1" dir="$2" dir_p
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || tgb_abort "$label [$dir] is not a real directory"
    dir_p="$(tgb_physical "$dir")" || tgb_abort "$label [$dir] does not resolve"
    [ "$dir_p" != / ] || tgb_abort "$label is /"
    case "$dir_p" in
        "$TGB_ROOT_P"/?*) : ;;
        *) tgb_abort "$label [$dir_p] is not inside the scratch directory [$TGB_ROOT_P]" ;;
    esac
    ! tgb_covers "$dir_p" "$TGB_CHECKOUT_P" || tgb_abort "$label [$dir_p] is or contains the checkout"
    ! tgb_covers "$TGB_CHECKOUT_P" "$dir_p" || tgb_abort "$label [$dir_p] is inside the checkout"
    ! tgb_covers "$dir_p" "$TGB_CWD_P" || tgb_abort "$label [$dir_p] is or contains the working directory"
    if [ -n "$TGB_HOME_P" ]; then
        ! tgb_covers "$dir_p" "$TGB_HOME_P" || tgb_abort "$label [$dir_p] is or contains \$HOME"
    fi
    if [ -n "$TGB_ACCOUNT_HOME_P" ]; then
        ! tgb_covers "$dir_p" "$TGB_ACCOUNT_HOME_P" || tgb_abort "$label [$dir_p] is or contains the account home"
    fi
    return 0
}

TGB_BASH="$(command -v bash)" || TGB_BASH="$BASH"
TGB_PERL="$(command -v perl)" || tgb_abort "perl is required"
TGB_ENV="$(command -v env)" || tgb_abort "env is required"
TGB_SYS_PATH="$(dirname "$TGB_BASH"):/usr/bin:/bin:/usr/sbin:/sbin"
TGB_TOOL=mktemp

tgb_show() { # FILE [LINES]
    sed -n "1,${2:-12}p" "$1" 2>/dev/null | sed 's/^/      | /'
}

# tgb_supervise LIMIT CWD OUT -- CMD...: run CMD in its own process group
# with cwd CWD, stdin /dev/null, stdout and stderr appended to OUT; kill the
# whole group after LIMIT seconds (status 124). Returns CMD's status.
tgb_supervise() {
    local limit="$1" cwd="$2" out="$3"
    shift 4
    (
        cd -P -- "$cwd" || exit 125
        exec "$TGB_PERL" -e '
            my $limit = shift @ARGV;
            my $pid = fork();
            defined $pid or exit 125;
            if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127; }
            $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; print STDERR "dxe-tmpguard-b: killed after ${limit}s\n"; exit 124; };
            alarm $limit;
            waitpid($pid, 0);
            alarm 0;
            exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
        ' "$limit" "$@"
    ) </dev/null >>"$out" 2>&1
}

# =====================================================================
# 2. The static guard (contract item 2)
# =====================================================================
TGB_SCAN="$TGB_ROOT_P/scan.pl"
cat > "$TGB_SCAN" <<'SCAN'
#!/usr/bin/perl
# Static fixture-directory guard scanner. Usage:
#   perl scan.pl ALLOWLIST DIELIB FILE...
# Prints one line per directory-making temp-dir call found:
#   guarded<TAB>FILE:LINE<TAB>how<TAB>text
#   unguarded<TAB>FILE:LINE<TAB>why<TAB>text
#   allowed<TAB>FILE:LINE<TAB>reason<TAB>text
# and, for an allowlist entry that matched nothing:
#   stale<TAB>FILE<TAB>text
use strict;
use warnings;

my $TOOL = 'mk' . 'temp';
my $DTM = "dxe_test_" . $TOOL . "_dir";
# Functions whose call makes and prints a new directory (found below).
our %PRODUCER;
our $EMBED_RE = qr/\Q$TOOL\E/;
my ($allow_file, $dielib, @files) = @ARGV;

my %allow;
open(my $af, '<', $allow_file) or die "cannot read $allow_file\n";
while (my $l = <$af>) {
    chomp $l;
    next if $l =~ /^\s*$/;
    my ($f, $t, $r) = split /\t/, $l, 3;
    $allow{"$f\t$t"} = { reason => $r, used => 0, file => $f, text => $t };
}
close $af;

sub slurp { my ($p) = @_; open(my $h, '<', $p) or return undef; local $/; my $s = <$h>; close $h; return $s; }

# ---------------------------------------------------------------- lexer ----
# Token: { t => 'W'|'OP'|'NL', v => raw, line => n, ... }
# Word extras: lit (static value or undef), subs => [ { toks, line } ],
# strs => [ { text, line } ] (string literals, scanned again as code).
our @EMBED;    # string literals that mention the tool: { text, line }

my @OPS = (';;&', '<<<', '<<-', '&&', '||', ';;', ';&', '|&', '<<', '>>', '>&', '<&', '&>', '>|', '<>', ';', '&', '|', '(', ')', '<', '>');

sub lex {
    my ($sref, $iref, $lref, $close) = @_;    # $close: stop at an unmatched ')' (for $( ))
    my @toks;
    my @heredocs;
    my $depth = 0;
    my $case = 0;
    my $n = length $$sref;
    while ($$iref < $n) {
        my $c = substr($$sref, $$iref, 1);
        if ($c eq "\n") {
            push @toks, { t => 'NL', v => "\n", line => $$lref };
            $$iref++;
            $$lref++;
            for my $h (@heredocs) { read_heredoc($sref, $iref, $lref, $h); }
            @heredocs = ();
            next;
        }
        if ($c eq ' ' || $c eq "\t" || $c eq "\r") { $$iref++; next; }
        if ($c eq '\\' && substr($$sref, $$iref + 1, 1) eq "\n") { $$iref += 2; $$lref++; next; }
        if ($c eq '#') {
            while ($$iref < $n && substr($$sref, $$iref, 1) ne "\n") { $$iref++; }
            next;
        }
        my $op;
        for my $o (@OPS) {
            if (substr($$sref, $$iref, length $o) eq $o) { $op = $o; last; }
        }
        if (defined $op) {
            if ($op eq ")") {
                if ($depth > 0) { $depth--; }
                elsif ($case > 0) { }
                elsif ($close) { $$iref++; return \@toks; }
            }
            $depth++ if $op eq "(";
            push @toks, { t => 'OP', v => $op, line => $$lref };
            $$iref += length $op;
            if ($op eq '<<' || $op eq '<<-') {
                while ($$iref < $n && substr($$sref, $$iref, 1) =~ /[ \t]/) { $$iref++; }
                my $dw = read_word($sref, $iref, $lref);
                my $raw = $dw->{v};
                my $quoted = ($raw =~ /['"\\]/) ? 1 : 0;
                (my $delim = $raw) =~ s/['"\\]//g;
                push @heredocs, { delim => $delim, strip => ($op eq '<<-'), quoted => $quoted };
                push @toks, $dw;
            }
            next;
        }
        my $w = read_word($sref, $iref, $lref);
        if (defined $w->{lit} && cmdpos(\@toks)) {
            if ($w->{lit} eq "case") { $case++; }
            elsif ($w->{lit} eq "esac" && $case > 0) { $case--; }
        }
        push @toks, $w;
    }
    return \@toks;
}

sub cmdpos {
    my ($toks) = @_;
    return 1 unless @$toks;
    my $p = $toks->[-1];
    return 1 if $p->{t} eq "NL";
    return 1 if $p->{t} eq "OP" && $p->{v} =~ /^(;|&|&&|\|\||\||\|&|\(|;;|;&|;;&)$/;
    return 1 if $p->{t} eq "W" && defined $p->{lit} && $p->{lit} =~ /^(then|do|else|elif|\{|!)$/;
    return 0;
}

sub read_heredoc {
    my ($sref, $iref, $lref, $h) = @_;
    my $n = length $$sref;
    my $body = '';
    my $start = $$lref;
    while ($$iref < $n) {
        my $e = index($$sref, "\n", $$iref);
        $e = $n if $e < 0;
        my $line = substr($$sref, $$iref, $e - $$iref);
        $$iref = $e < $n ? $e + 1 : $n;
        $$lref++;
        my $cmp = $line;
        $cmp =~ s/^\t+// if $h->{strip};
        last if $cmp eq $h->{delim};
        $body .= "$line\n";
    }
    unless ($h->{quoted}) { $body =~ s/\\([\$`\\])/$1/g; }
    push @EMBED, { text => $body, line => $start } if $body =~ $EMBED_RE;
}

sub read_word {
    my ($sref, $iref, $lref) = @_;
    my $n = length $$sref;
    my $start_i = $$iref;
    my $w = { t => 'W', line => $$lref, subs => [], nsubs => 0 };
    my $lit = '';
    my $static = 1;
    while ($$iref < $n) {
        my $c = substr($$sref, $$iref, 1);
        last if $c =~ /[ \t\r\n;&|()<>]/;
        if ($c eq '\\') {
            my $d = substr($$sref, $$iref + 1, 1);
            if ($d eq "\n") { $$iref += 2; $$lref++; next; }
            $lit .= $d;
            $$iref += 2;
            next;
        }
        if ($c eq "'") {
            my $sl = $$lref;
            my $e = index($$sref, "'", $$iref + 1);
            $e = $n if $e < 0;
            my $text = substr($$sref, $$iref + 1, $e - $$iref - 1);
            $lit .= $text;
            $$lref += ($text =~ tr/\n//);
            $$iref = $e + 1;
            push @EMBED, { text => $text, line => $sl } if $text =~ $EMBED_RE;
            next;
        }
        if ($c eq '$' && substr($$sref, $$iref + 1, 1) eq "'") {
            my $j = $$iref + 2;
            while ($j < $n) {
                my $d = substr($$sref, $j, 1);
                if ($d eq '\\') { $j += 2; next; }
                last if $d eq "'";
                $j++;
            }
            my $text = substr($$sref, $$iref + 2, $j - $$iref - 2);
            $$lref += ($text =~ tr/\n//);
            $$iref = $j + 1;
            $static = 0;
            next;
        }
        if ($c eq '"') {
            $$iref++;
            my $sl = $$lref;
            my $text = '';
            while ($$iref < $n) {
                my $d = substr($$sref, $$iref, 1);
                if ($d eq '"') { $$iref++; last; }
                if ($d eq '\\') {
                    my $e = substr($$sref, $$iref + 1, 1);
                    if ($e eq "\n") { $$iref += 2; $$lref++; next; }
                    if ($e =~ /[\$`"\\]/) { $text .= $e; $lit .= $e; $$iref += 2; next; }
                    $text .= $d; $lit .= $d; $$iref++; next;
                }
                if ($d eq '$' || $d eq '`') {
                    if (expansion($sref, $iref, $lref, $w)) { $static = 0; $text .= ' _X_ '; next; }
                }
                $$lref++ if $d eq "\n";
                $text .= $d;
                $lit .= $d;
                $$iref++;
            }
            push @EMBED, { text => $text, line => $sl } if $text =~ $EMBED_RE;
            next;
        }
        if ($c eq '$' || $c eq '`') {
            if (expansion($sref, $iref, $lref, $w)) { $static = 0; next; }
        }
        $lit .= $c;
        $$iref++;
    }
    $w->{v} = substr($$sref, $start_i, $$iref - $start_i);
    $w->{lit} = $static ? $lit : undef;
    return $w;
}

# expansion: at $ or `; consumes a $( ), ` `, ${ }, $(( )) or $name and
# returns 1, or returns 0 when the character is a plain '$'.
sub expansion {
    my ($sref, $iref, $lref, $w) = @_;
    my $n = length $$sref;
    my $c = substr($$sref, $$iref, 1);
    if ($c eq '`') {
        my $j = $$iref + 1;
        my $text = '';
        while ($j < $n) {
            my $d = substr($$sref, $j, 1);
            if ($d eq '\\') { $text .= substr($$sref, $j + 1, 1); $j += 2; next; }
            last if $d eq '`';
            $text .= $d;
            $j++;
        }
        my $sl = $$lref;
        $$lref += ($text =~ tr/\n//);
        $$iref = $j + 1;
        my ($i2, $l2) = (0, $sl);
        my $toks = lex(\$text, \$i2, \$l2, 0);
        push @{ $w->{subs} }, { toks => $toks, line => $sl };
        $w->{nsubs}++;
        return 1;
    }
    my $d = substr($$sref, $$iref + 1, 1);
    if ($d eq '(' && substr($$sref, $$iref + 2, 1) eq '(') {
        my $j = $$iref + 3;
        my $dep = 2;
        while ($j < $n && $dep > 0) {
            my $e = substr($$sref, $j, 1);
            $dep++ if $e eq '(';
            $dep-- if $e eq ')';
            $$lref++ if $e eq "\n";
            $j++;
        }
        $$iref = $j;
        return 1;
    }
    if ($d eq '(') {
        my $sl = $$lref;
        $$iref += 2;
        my $toks = lex($sref, $iref, $lref, 1);
        push @{ $w->{subs} }, { toks => $toks, line => $sl };
        $w->{nsubs}++;
        return 1;
    }
    if ($d eq '{') {
        $$iref += 2;
        my $dep = 1;
        while ($$iref < $n && $dep > 0) {
            my $e = substr($$sref, $$iref, 1);
            if ($e eq '\\') { $$iref += 2; next; }
            if ($e eq '}') { $dep--; $$iref++; next; }
            if ($e eq "'") {
                my $f = index($$sref, "'", $$iref + 1);
                $f = $n if $f < 0;
                $$lref += (substr($$sref, $$iref, $f - $$iref) =~ tr/\n//);
                $$iref = $f + 1;
                next;
            }
            if ($e eq '"') {
                $$iref++;
                while ($$iref < $n) {
                    my $g = substr($$sref, $$iref, 1);
                    if ($g eq '\\') { $$iref += 2; next; }
                    if ($g eq '"') { $$iref++; last; }
                    if (($g eq '$' || $g eq '`') && expansion($sref, $iref, $lref, $w)) { next; }
                    $$lref++ if $g eq "\n";
                    $$iref++;
                }
                next;
            }
            if ($e eq '$' || $e eq '`') {
                if (substr($$sref, $$iref + 1, 1) eq '{') { $dep++; $$iref += 2; next; }
                if (expansion($sref, $iref, $lref, $w)) { next; }
            }
            $$lref++ if $e eq "\n";
            $$iref++;
        }
        return 1;
    }
    if ($d =~ /[A-Za-z0-9_?\$!#@*-]/) {
        my $j = $$iref + 1;
        if ($d =~ /[A-Za-z_]/) { $j++ while $j < $n && substr($$sref, $j, 1) =~ /[A-Za-z0-9_]/; }
        else { $j++; }
        $$iref = $j;
        return 1;
    }
    return 0;
}

# ------------------------------------------------------------- analysis ----
my %RESERVED_START = map { $_ => 1 } qw(if then else elif do while until { ! time);
my %RESERVED_END = map { $_ => 1 } qw(fi done esac });
my %TERM = map { $_ => 1 } (';', '&', ';;', ';&', ';;&', ')');

sub is_redir_op { my ($t) = @_; return $t->{t} eq 'OP' && $t->{v} =~ /^(<|>|>>|>&|<&|&>|>\||<>|<<<|<<|<<-)$/; }
sub lit { my ($t) = @_; return ($t && $t->{t} eq 'W' && defined $t->{lit}) ? $t->{lit} : undef; }
sub is_assign { my ($t) = @_; return $t->{t} eq 'W' && $t->{v} =~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/; }

# commands TOKS: splits a token list into simple commands, recording for each
# { start, end (exclusive), words => [idx...], name_idx } and the compound
# structure needed to judge an and-or list.
sub commands {
    my ($toks) = @_;
    my @cmds;
    my $i = 0;
    my $n = scalar @$toks;
    my @case_stack;    # 'pattern' | 'body'
    my $for_skip = 0;
    while ($i < $n) {
        my $t = $toks->[$i];
        if ($t->{t} eq 'NL' || ($t->{t} eq 'OP' && !is_redir_op($t))) {
            if ($t->{t} eq 'OP' && @case_stack && ($t->{v} eq ';;' || $t->{v} eq ';&' || $t->{v} eq ';;&')) { $case_stack[-1] = 'pattern'; }
            $i++;
            next;
        }
        my $l = lit($t);
        if (@case_stack && $case_stack[-1] eq 'pattern') {
            if (defined $l && $l eq 'esac') { pop @case_stack; $i++; next; }
            while ($i < $n && !($toks->[$i]{t} eq 'OP' && $toks->[$i]{v} eq ')')) { $i++; }
            $i++;
            $case_stack[-1] = 'body';
            next;
        }
        if (defined $l && $l eq 'esac' && @case_stack) { pop @case_stack; $i++; next; }
        if (defined $l && $l eq 'case') {
            $i++;
            while ($i < $n && !(defined lit($toks->[$i]) && lit($toks->[$i]) eq 'in')) { $i++; }
            $i++;
            push @case_stack, 'pattern';
            next;
        }
        if (defined $l && ($l eq 'for' || $l eq 'select')) {
            $i++;
            while ($i < $n && !(defined lit($toks->[$i]) && lit($toks->[$i]) eq 'do')) { $i++; }
            $i++;
            next;
        }
        if (defined $l && ($RESERVED_START{$l} || $RESERVED_END{$l})) { $i++; next; }
        if (defined $l && $l eq 'function') { $i += 2; next; }
        # function definition NAME ( )
        if ($i + 2 < $n && $toks->[$i + 1]{t} eq 'OP' && $toks->[$i + 1]{v} eq '(' && $toks->[$i + 2]{t} eq 'OP' && $toks->[$i + 2]{v} eq ')') { $i += 3; next; }
        # a simple command
        my $start = $i;
        my @words;
        my $neg = ($start > 0 && defined lit($toks->[$start - 1]) && lit($toks->[$start - 1]) eq '!') ? 1 : 0;
        while ($i < $n) {
            my $u = $toks->[$i];
            last if $u->{t} eq 'NL';
            if ($u->{t} eq 'OP') {
                if (is_redir_op($u)) { $i += 2; next; }
                last;
            }
            if ($u->{v} =~ /^[0-9]+$/ && $i + 1 < $n && is_redir_op($toks->[$i + 1])) { $i++; next; }
            push @words, $i;
            $i++;
        }
        push @cmds, { start => $start, end => $i, words => \@words, neg => $neg };
    }
    return \@cmds;
}

# Index of the command name within WORDS (skipping assignments and the
# command/exec/builtin/env wrappers), or undef.
sub name_index {
    my ($toks, $words) = @_;
    my $k = 0;
    $k++ while $k < @$words && is_assign($toks->[ $words->[$k] ]);
    while ($k < @$words) {
        my $l = lit($toks->[ $words->[$k] ]);
        last unless defined $l;
        if ($l eq 'command' || $l eq 'exec' || $l eq 'builtin') {
            $k++;
            $k++ while $k < @$words && defined lit($toks->[ $words->[$k] ]) && lit($toks->[ $words->[$k] ]) =~ /^-/;
            next;
        }
        if ($l eq 'env') {
            $k++;
            $k++ while $k < @$words && (is_assign($toks->[ $words->[$k] ]) || (defined lit($toks->[ $words->[$k] ]) && lit($toks->[ $words->[$k] ]) =~ /^-/));
            next;
        }
        last;
    }
    return $k < @$words ? $k : undef;
}

sub makes_dir {
    my ($toks, $words, $k) = @_;
    for my $j ($k + 1 .. $#$words) {
        my $l = lit($toks->[ $words->[$j] ]);
        next unless defined $l;
        last if $l eq '--';
        return 1 if $l eq '--directory';
        return 1 if $l =~ /^-[A-Za-z]*d[A-Za-z]*$/;
    }
    return 0;
}

my %DIE;
sub is_terminator {
    my ($t) = @_;
    return 1 unless $t;
    return 1 if $t->{t} eq 'NL';
    return 1 if $t->{t} eq 'OP' && $TERM{ $t->{v} };
    my $l = lit($t);
    return 1 if defined $l && ($l eq '}' || $RESERVED_END{$l} || $l eq 'then' || $l eq 'do' || $l eq 'else' || $l eq 'elif');
    return 0;
}

# exit_like TOKS P: P starts `exit|return [N]`, N nonzero or $?, ended by a
# terminator; or a call to a known die function. Returns the index after it, or -1.
sub exit_like {
    my ($toks, $p) = @_;
    my $t = $toks->[$p];
    my $l = lit($t);
    return -1 unless $t && $t->{t} eq 'W';
    if (defined $l && ($l eq 'exit' || $l eq 'return')) {
        my $a = $toks->[ $p + 1 ];
        return $p + 1 if is_terminator($a);
        my $al = lit($a);
        my $ok = (defined $al && $al =~ /^[1-9][0-9]*$/) || $a->{v} eq '$?' || $a->{v} eq '"$?"';
        return -1 unless $ok;
        return is_terminator($toks->[ $p + 2 ]) ? $p + 2 : -1;
    }
    if (defined $l && $DIE{$l}) {
        my $q = $p + 1;
        $q++ while $q < @$toks && !is_terminator($toks->[$q]) && !($toks->[$q]{t} eq 'OP' && ($toks->[$q]{v} eq '&&' || $toks->[$q]{v} eq '||' || $toks->[$q]{v} eq '|'));
        return $q;
    }
    return -1;
}

# skip_command TOKS P: index after one command (simple, group or subshell)
sub skip_command {
    my ($toks, $p) = @_;
    my $n = scalar @$toks;
    $p++ while $p < $n && $toks->[$p]{t} eq 'NL';
    my $l = lit($toks->[$p]);
    if (defined $l && $l eq '!') { $p++; $l = lit($toks->[$p]); }
    if (defined $l && $l eq '{') {
        my $dep = 0;
        while ($p < $n) {
            my $m = lit($toks->[$p]);
            if (defined $m && $m eq '{') { $dep++; }
            if (defined $m && $m eq '}') { $dep--; if ($dep == 0) { $p++; last; } }
            $p++;
        }
    } elsif ($toks->[$p] && $toks->[$p]{t} eq 'OP' && $toks->[$p]{v} eq '(') {
        my $dep = 0;
        while ($p < $n) {
            if ($toks->[$p]{t} eq 'OP' && $toks->[$p]{v} eq '(') { $dep++; }
            if ($toks->[$p]{t} eq 'OP' && $toks->[$p]{v} eq ')') { $dep--; if ($dep == 0) { $p++; last; } }
            $p++;
        }
    } else {
        while ($p < $n) {
            my $u = $toks->[$p];
            last if $u->{t} eq 'NL';
            if ($u->{t} eq 'OP') { if (is_redir_op($u)) { $p += 2; next; } last; }
            $p++;
        }
        return $p;
    }
    # redirections after a compound command
    while ($p < $n && is_redir_op($toks->[$p])) { $p += 2; }
    return $p;
}

# and_or_guard TOKS P: P is just after the carrier command. Returns
# (1, how) when the same and-or list continues (through && commands only)
# into `|| exit|return|{ ...; exit|return; }|die`, else (0, why).
sub and_or_guard {
    my ($toks, $p) = @_;
    my $n = scalar @$toks;
    while (1) {
        my $t = $toks->[$p];
        return (0, 'no || exit/return on the same statement') if !$t || $t->{t} eq 'NL';
        if ($t->{t} eq 'OP' && ($t->{v} eq '|' || $t->{v} eq '|&')) { return (0, "piped: the pipeline's status is not the temp-dir call's"); }
        if ($t->{t} eq 'OP' && $t->{v} eq '&&') { $p = skip_command($toks, $p + 1); next; }
        if ($t->{t} eq 'OP' && $t->{v} eq '||') {
            my $q = $p + 1;
            $q++ while $q < $n && $toks->[$q]{t} eq 'NL';
            my $l = lit($toks->[$q]);
            if (defined $l && $l eq '{') {
                # the group's last statement must be exit/return/die; no earlier exit/return
                my $dep = 0;
                my @stmt;
                my $last;
                my $early = 0;
                my $r = $q;
                while ($r < $n) {
                    my $m = lit($toks->[$r]);
                    if (defined $m && $m eq '{') { $dep++; if ($dep == 1) { $r++; next; } }
                    if (defined $m && $m eq '}' && $dep == 1) { last; }
                    if (defined $m && $m eq '}') { $dep--; }
                    if ($dep == 1 && ($toks->[$r]{t} eq 'NL' || ($toks->[$r]{t} eq 'OP' && $toks->[$r]{v} eq ';'))) {
                        if (@stmt) { $early++ if defined $last && $last->{exitish}; $last = { first => $stmt[0] }; my $fl = lit($toks->[ $stmt[0] ]); $last->{exitish} = (defined $fl && ($fl eq 'exit' || $fl eq 'return')) ? 1 : 0; @stmt = (); }
                        $r++;
                        next;
                    }
                    push @stmt, $r if $dep == 1;
                    $r++;
                }
                if (@stmt) { $early++ if defined $last && $last->{exitish}; $last = { first => $stmt[0] }; }
                return (0, '|| { ... } does not end in exit/return') unless defined $last;
                return (0, '|| { ... } returns or exits before its last statement') if $early;
                return (exit_like($toks, $last->{first}) >= 0) ? (1, '|| { ...; exit }') : (0, '|| { ... } does not end in exit/return with a non-zero status');
            }
            return (exit_like($toks, $q) >= 0) ? (1, '|| ' . $toks->[$q]{v}) : (0, '|| is not followed by exit/return with a non-zero status');
        }
        return (0, 'no || exit/return on the same statement');
    }
}

# propagates TOKS P: P is just after a call; true when the rest of its
# and-or list is only `&& ...` steps, so the call's failure is the list's.
sub propagates {
    my ($toks, $p) = @_;
    while (1) {
        my $t = $toks->[$p];
        return 1 if !$t || $t->{t} eq 'NL' || ($t->{t} eq 'OP' && $TERM{ $t->{v} });
        if ($t->{t} eq 'OP' && $t->{v} eq '&&') { $p = skip_command($toks, $p + 1); next; }
        return 0;
    }
}

our @RESULTS;
# Per program (a file, or program text in a string or here-document):
# helper (dxe_test_..._dir) calls, and whether it sources the harness that
# defines it.
our @DTM_CALLS;
our $SOURCES_HARNESS = 0;
sub check_dtm {
    my ($ctx, $where) = @_;
    return if $SOURCES_HARNESS || !@DTM_CALLS;
    for my $line (@DTM_CALLS) {
        push @RESULTS, [ 'unguarded', $ctx->{file}, $line, "$DTM in $where that does not source tests/lib/harness.sh (or tests/test_helpers.sh): there it is not defined, the call fails with 127 and the program carries on", $DTM ];
    }
}
# analyze TOKS CTX: finds temp-dir sites. CTX: { file, embedded_depth }
# Returns a list of "carriers": sites whose fate depends on the enclosing
# command substitution: [ { line, sole => 1 } ].
# site_name TOKS WORDS K: 'tempdir' for a directory-making call, 'helper:NAME'
# for a call of a function that makes and prints a new directory, else undef.
sub site_name {
    my ($toks, $words, $k) = @_;
    return undef unless defined $k;
    my $nm = lit($toks->[ $words->[$k] ]);
    return undef unless defined $nm;
    return 'tempdir' if $nm eq $TOOL && makes_dir($toks, $words, $k);
    return "helper:$nm" if $PRODUCER{$nm};
    return undef;
}

sub analyze {
    my ($toks, $ctx, $in_subst) = @_;
    my $cmds = commands($toks);
    my @up;
    my %covered;
    # single: the substitution is one and-or list, so its status (and its
    # output) is that list's.
    my $single = 1;
    if ($in_subst) {
        my @x = grep { $toks->[$_]{t} ne 'NL' } 0 .. $#$toks;
        pop @x while @x && $toks->[ $x[-1] ]{t} eq 'OP' && $toks->[ $x[-1] ]{v} eq ';';
        for my $i (@x) {
            my $u = $toks->[$i];
            $single = 0 if $u->{t} eq 'OP' && ($u->{v} eq ';' || $u->{v} eq '&');
        }
        if (@x) {
            for my $i ($x[0] .. $x[-1]) {
                next unless $toks->[$i]{t} eq 'NL';
                my $p = $i - 1;
                $p-- while $p >= 0 && $toks->[$p]{t} eq 'NL';
                $single = 0 unless $p >= 0 && $toks->[$p]{t} eq 'OP' && $toks->[$p]{v} =~ /^(&&|\|\||\|)$/;
            }
        }
    }
    for my $c (@$cmds) {
        my $words = $c->{words};
        next unless @$words;
        $covered{$_} = 1 for @$words;
        my $k = name_index($toks, $words);
        my @found;    # sites whose status this command carries: { line, kind, what }
        my $what = site_name($toks, $words, $k);
        if (defined $k) {
            my $nm = lit($toks->[ $words->[$k] ]);
            if (defined $nm && $nm eq $DTM) { push @DTM_CALLS, $toks->[ $words->[$k] ]{line}; }
            if (defined $nm && ($nm eq 'source' || $nm eq '.') && $k + 1 <= $#$words
                && $toks->[ $words->[ $k + 1 ] ]{v} =~ m{(?:^|/)(?:lib/harness|test_helpers)\.sh["']?$}) {
                $SOURCES_HARNESS = 1;
            }
        }
        push @found, { line => $toks->[ $words->[$k] ]{line}, kind => 'bare', what => $what } if defined $what;
        my $first = lit($toks->[ $words->[0] ]);
        for my $w (map { $toks->[$_] } @$words) {
            for my $s (@{ $w->{subs} }) {
                for my $cr (analyze($s->{toks}, $ctx, 1)) {
                    # The statement's status is the call's only when the
                    # statement is a single assignment word holding this one
                    # command substitution.
                    if (scalar(@$words) == 1 && is_assign($w) && $w->{nsubs} == 1) {
                        push @found, { line => $cr->{line}, kind => 'assign', what => $cr->{what} };
                        next;
                    }
                    my $why = (defined $first && $first =~ /^(local|export|declare|readonly|typeset)$/) ? "$first hides its status"
                        : (is_assign($w) && $w->{nsubs} > 1) ? 'another command substitution in the same word decides the status'
                        : is_assign($w) ? 'not the only word of its statement, so its status is not the statement\'s'
                        : 'its output is a command argument, so its status is never checked';
                    push @RESULTS, [ 'unguarded', $ctx->{file}, $cr->{line}, $why, $cr->{what} ];
                }
            }
        }
        for my $f (@found) {
            if ($c->{neg}) { push @RESULTS, [ 'unguarded', $ctx->{file}, $f->{line}, 'negated (! / if !): not an accepted form; use || exit or || return', $f->{what} ]; next; }
            my ($ok, $how) = and_or_guard($toks, $c->{end});
            if ($in_subst && $single) {
                # The substitution is this call's and-or list: its value is
                # the call's, so the statement holding it decides.
                if ($ok || propagates($toks, $c->{end})) { push @up, { line => $f->{line}, what => $f->{what} }; next; }
                push @RESULTS, [ 'unguarded', $ctx->{file}, $f->{line}, 'inside a command substitution where another command decides the status', $f->{what} ];
                next;
            }
            if ($in_subst) {
                # One statement of several inside $( ): its own statement
                # must fail closed (the exit leaves the substitution before
                # the later statements can use the path).
                push @RESULTS, [ $ok ? 'guarded' : 'unguarded', $ctx->{file}, $f->{line}, $ok ? "$how (inside a command substitution)" : $how, $f->{what} ];
                next;
            }
            push @RESULTS, [ $ok ? 'guarded' : 'unguarded', $ctx->{file}, $f->{line}, $how, $f->{what} ];
        }
    }
    # Words outside any simple command (for lists, case words, redirection
    # targets): a call substituted there has its status ignored.
    for my $x (0 .. $#$toks) {
        my $w = $toks->[$x];
        next if $covered{$x} || $w->{t} ne 'W';
        for my $s (@{ $w->{subs} }) {
            for my $cr (analyze($s->{toks}, $ctx, 1)) {
                push @RESULTS, [ 'unguarded', $ctx->{file}, $cr->{line}, 'substituted where its status is never checked', $cr->{what} ];
            }
        }
    }
    return @up;
}

# function_bodies TOKS: [ name, [ statements: [token indexes] ] ] for every
# `NAME() { ... }` definition.
sub function_bodies {
    my ($toks) = @_;
    my @out;
    my $n = scalar @$toks;
    for my $i (0 .. $n - 1) {
        my $t = $toks->[$i];
        next unless $t->{t} eq 'W' && $t->{v} =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
        next unless $i + 2 < $n && $toks->[ $i + 1 ]{t} eq 'OP' && $toks->[ $i + 1 ]{v} eq '(' && $toks->[ $i + 2 ]{t} eq 'OP' && $toks->[ $i + 2 ]{v} eq ')';
        my $p = $i + 3;
        $p++ while $p < $n && $toks->[$p]{t} eq 'NL';
        next unless defined lit($toks->[$p]) && lit($toks->[$p]) eq '{';
        my $dep = 0;
        my @stmts;
        my @cur;
        for my $r ($p .. $n - 1) {
            my $m = lit($toks->[$r]);
            if (defined $m && $m eq '{') { $dep++; next if $dep == 1; }
            if (defined $m && $m eq '}') { $dep--; if ($dep == 0) { push @stmts, [@cur] if @cur; last; } }
            if ($dep == 1 && ($toks->[$r]{t} eq 'NL' || ($toks->[$r]{t} eq 'OP' && $toks->[$r]{v} eq ';'))) { push @stmts, [@cur] if @cur; @cur = (); next; }
            push @cur, $r;
        }
        push @out, [ $t->{v}, \@stmts ];
    }
    return \@out;
}

sub die_functions {
    my ($toks) = @_;
    my %fn;
    for my $f (@{ function_bodies($toks) }) {
        my ($name, $stmts) = @$f;
        next unless @$stmts;
        my @lv = map { $toks->[$_]{v} } @{ $stmts->[-1] };
        $fn{$name} = 1 if @lv == 2 && $lv[0] eq 'exit' && $lv[1] =~ /^[1-9][0-9]*$/;
    }
    return \%fn;
}

# has_site TOKS: true when any command in TOKS (or its substitutions) is a
# directory-making call or a helper call.
sub has_site {
    my ($toks) = @_;
    for my $c (@{ commands($toks) }) {
        my $words = $c->{words};
        next unless @$words;
        return 1 if defined site_name($toks, $words, name_index($toks, $words));
        for my $w (map { $toks->[$_] } @$words) {
            for my $s (@{ $w->{subs} }) { return 1 if has_site($s->{toks}); }
        }
    }
    return 0;
}

# producers TOKS: functions that make and print a new directory: the last
# statement is such a call itself, or prints "$V" (printf ... / echo) where V
# was assigned from one.
sub producers {
    my ($toks) = @_;
    my %fn;
    for my $f (@{ function_bodies($toks) }) {
        my ($name, $stmts) = @$f;
        next unless @$stmts;
        my @last = @{ $stmts->[-1] };
        my @w = grep { $toks->[$_]{t} eq 'W' } @last;
        next unless @w;
        my $k = name_index($toks, \@w);
        if (defined site_name($toks, \@w, $k)) { $fn{$name} = 1; next; }
        my $cmd = lit($toks->[ $w[0] ]);
        next unless defined $cmd && ($cmd eq 'printf' || $cmd eq 'echo');
        my $v = $toks->[ $w[-1] ]{v};
        next unless $v =~ /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?$/;
        my $var = $1;
        for my $st (@$stmts) {
            for my $x (@$st) {
                my $t = $toks->[$x];
                next unless $t->{t} eq 'W' && $t->{v} =~ /^\Q$var\E=/;
                for my $s (@{ $t->{subs} }) { if (has_site($s->{toks})) { $fn{$name} = 1; } }
            }
        }
    }
    return \%fn;
}

# grow_producers TOKS...: adds every producer found in TOKS to %PRODUCER,
# until nothing new appears. Returns the names added.
sub grow_producers {
    my @lists = @_;
    my %added;
    while (1) {
        my $new = 0;
        for my $toks (@lists) {
            my $p = producers($toks);
            for my $nm (keys %$p) { next if $PRODUCER{$nm}; $PRODUCER{$nm} = 1; $added{$nm} = 1; $new++; }
        }
        last unless $new;
    }
    return sort keys %added;
}

sub lex_text {
    my ($text, $line) = @_;
    my ($i, $l) = (0, $line);
    return lex(\$text, \$i, \$l, 0);
}

my $dietoks = lex_text(slurp($dielib) // '', 1);
my $libdie = die_functions($dietoks);

# The shared libraries' helpers, known to every file.
my @libfiles = grep { m{(^|/)tests/lib/[^/]+\.sh$} || m{(^|/)tests/test_helpers\.sh$} } @files;
my %libsrc;
for my $lf (@libfiles) {
    my $s = slurp($lf);
    next unless defined $s;
    @EMBED = ();
    $libsrc{$lf} = lex_text($s, 1);
}
for my $nm (grow_producers(map { $libsrc{$_} } sort keys %libsrc)) {
    my ($where) = grep { $PRODUCER{$nm} && producers($libsrc{$_})->{$nm} } sort keys %libsrc;
    print join("\t", 'producer', $nm, $where // ''), "\n";
}
my %GLOBAL_PRODUCER = %PRODUCER;
{
    my $names = join('|', map { quotemeta } ($TOOL, sort keys %GLOBAL_PRODUCER));
    $EMBED_RE = qr/(?:$names)/;
}

for my $file (@files) {
    my $src = slurp($file);
    next unless defined $src;
    my @lines = split /\n/, $src, -1;
    @RESULTS = ();
    @EMBED = ();
    %PRODUCER = %GLOBAL_PRODUCER;
    my $toks = lex_text($src, 1);
    grow_producers($toks);
    %DIE = (%$libdie, %{ die_functions($toks) });
    my $ctx = { file => $file };
    @DTM_CALLS = ();
    $SOURCES_HARNESS = 0;
    analyze($toks, $ctx, 0);
    # tests/lib/*.sh are sourced into a suite that has the harness already.
    check_dtm($ctx, 'a script') unless $file =~ m{(?:^|/)tests/lib/[^/]+\.sh$};
    # string literals that mention the tool or a helper are scanned again as programs
    my %seen;
    my $rounds = 0;
    while (@EMBED && $rounds < 4) {
        my @batch = @EMBED;
        @EMBED = ();
        $rounds++;
        for my $e (@batch) {
            next if $seen{"$e->{line}\t$e->{text}"}++;
            my $etoks = lex_text($e->{text}, $e->{line});
            my %save = %DIE;
            my %psave = %PRODUCER;
            %DIE = (%DIE, %{ die_functions($etoks) });
            grow_producers($etoks);
            @DTM_CALLS = ();
            $SOURCES_HARNESS = 0;
            analyze($etoks, $ctx, 0);
            check_dtm($ctx, 'program text (a string or here-document run by another shell)');
            %DIE = %save;
            %PRODUCER = %psave;
        }
    }
    my %done;
    for my $r (@RESULTS) {
        my ($verdict, $f, $line, $detail, $what) = @$r;
        $what //= 'tempdir';
        next if $done{"$line\t$verdict\t$detail\t$what"}++;
        my $text = defined $lines[ $line - 1 ] ? $lines[ $line - 1 ] : '';
        (my $trim = $text) =~ s/^\s+|\s+$//g;
        if ($verdict eq 'unguarded' && $allow{"$f\t$trim"}) {
            $allow{"$f\t$trim"}{used}++;
            print join("\t", 'allowed', "$f:$line", $allow{"$f\t$trim"}{reason}, $trim, $what), "\n";
            next;
        }
        print join("\t", $verdict, "$f:$line", $detail, $trim, $what), "\n";
    }
}
for my $k (sort keys %allow) {
    next if $allow{$k}{used};
    my %scanned = map { $_ => 1 } @files;
    next unless $scanned{ $allow{$k}{file} };
    print join("\t", 'stale', $allow{$k}{file}, $allow{$k}{text}), "\n";
}
SCAN

# tgb_scan ALLOWLIST FILE...: runs the scanner from the checkout root (FILE
# relative to it, or absolute), with tests/lib/harness.sh as the library of
# fail-closed functions every suite shares.
tgb_scan() {
    local allow="$1"
    shift
    (cd -P -- "$BASE_DIR" && "$TGB_PERL" "$TGB_SCAN" "$allow" tests/lib/harness.sh "$@")
}

# --- 2a. the scanner itself: what counts as failing closed ------------------
# Each sample is a tiny shell file; @MK@, @FTD@ and @PFR@ stand for mktemp and
# two library helpers so this file's own text holds none of these shapes.
TGB_FTD=fake_tool_dir_create
TGB_PFR=persist_fixture_root_create
TGB_PFN=persist_fixture_nas_create
TGB_DTM=dxe_test_mktemp_dir
TGB_SAMPLES="$TGB_ROOT_P/samples"
mkdir "$TGB_SAMPLES" || tgb_abort "cannot create $TGB_SAMPLES"
TGB_SAMPLE_LIST=""
tgb_sample() { # NAME EXPECTED BODY -- EXPECTED: the site verdicts, in line order, comma-separated ("none": no site)
    printf '%s\n' "$3" | sed -e "s/@MK@/$TGB_TOOL/g" -e "s/@FTD@/$TGB_FTD/g" -e "s/@PFR@/$TGB_PFR/g" -e "s/@DTM@/$TGB_DTM/g" > "$TGB_SAMPLES/$1.sh"
    TGB_SAMPLE_LIST="$TGB_SAMPLE_LIST $1:$2"
}
tgb_sample plain unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")"
trap '"'"'rm -rf "$X"'"'"' EXIT'
tgb_sample exit guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || exit 1'
tgb_sample exit-status guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || exit $?'
tgb_sample return guarded 'f() {
    d="$(@MK@ -d "$1/a.XXXXXX")" || return 1
    printf "%s\n" "$d"
}'
tgb_sample bare-return guarded 'f() {
    @MK@ -d "$1/a.XXXXXX" || return 1
}'
tgb_sample bare unguarded 'f() {
    @MK@ -d "$1/a.XXXXXX"
}'
tgb_sample comment unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")" # || exit 1'
tgb_sample next-line unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")"
true || exit 1'
tgb_sample other-statement unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")"; : || exit 1'
tgb_sample quoted-or unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")"; echo "|| exit 1"'
tgb_sample exit-zero unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || exit 0'
tgb_sample return-zero unguarded 'f() {
    X="$(@MK@ -d "$T/a.XXXXXX")" || return 0
}'
tgb_sample local unguarded 'f() {
    local X="$(@MK@ -d "$T/a.XXXXXX")" || return 1
}'
tgb_sample export unguarded 'export X="$(@MK@ -d "$T/a.XXXXXX")" || exit 1'
tgb_sample canonicalise unguarded 'X="$(cd "$(@MK@ -d "$T/a.XXXXXX")" && pwd -P)" || exit 1'
tgb_sample two-substitutions unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")$(true)" || exit 1'
tgb_sample trailing-command unguarded 'X="$(@MK@ -d "$T/a.XXXXXX"; true)" || exit 1'
tgb_sample argument unguarded 'cd "$(@MK@ -d "$T/a.XXXXXX")" || exit 1'
tgb_sample piped unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")" | cat || exit 1'
tgb_sample negated unguarded '! X="$(@MK@ -d "$T/a.XXXXXX")" || exit 1'
tgb_sample group guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || { echo "no fixture" >&2; exit 1; }'
tgb_sample group-no-exit unguarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || { echo "no fixture" >&2; }'
tgb_sample group-early-return unguarded 'f() {
    X="$(@MK@ -d "$T/a.XXXXXX")" || { return 0; exit 1; }
}'
tgb_sample die guarded 'die() { echo "$*" >&2; exit 1; }
X="$(@MK@ -d "$T/a.XXXXXX")" || die "no fixture"'
tgb_sample not-die unguarded 'warn() { echo "$*" >&2; }
X="$(@MK@ -d "$T/a.XXXXXX")" || warn "no fixture"'
tgb_sample harness-die guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" || _dxe_harness_die "fixture"'
tgb_sample and-chain guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" && [ -d "$X" ] && [ ! -L "$X" ] \
    || exit 1'
tgb_sample or-newline guarded 'X="$(@MK@ -d "$T/a.XXXXXX")" ||
    exit 1'
tgb_sample probe-string unguarded 'fake_tool_write "$d" probe '"'"'X="$(@MK@ -d)"
cd "$X" && rm -rf ./*'"'"
tgb_sample here-document unguarded 'cat > "$p" <<'"'"'EOF'"'"'
X="$(@MK@ -d)"
EOF'
tgb_sample escaped-program unguarded 'printf "X=\$(@MK@ -d)\n" > "$p"'
tgb_sample backticks unguarded 'X=`@MK@ -d "$T/a.XXXXXX"`'
tgb_sample dt unguarded 'X="$(@MK@ -dt a.XXXXXX)"'
tgb_sample long-option unguarded 'X="$(@MK@ --directory "$T/a.XXXXXX")"'
tgb_sample file-only none 'X="$(@MK@ -t a.XXXXXX)" || exit 1
Y="$(@MK@ "$T/f.XXXXXX")"'
tgb_sample helper none 'source "$SCRIPT_DIR/test_helpers.sh"
@DTM@ X "$T/a.XXXXXX"'
# dxe_test_mktemp_dir is defined only where tests/lib/harness.sh is loaded
# (contract item 2d): not in a script, or in program text, that does not
# source it (a guest driver, a probe another shell runs).
tgb_sample helper-unsourced unguarded '@DTM@ X "$T/a.XXXXXX"
cd "$X"'
tgb_sample helper-here-document unguarded 'source "$SCRIPT_DIR/test_helpers.sh"
cat > "$p" <<'"'"'EOF'"'"'
#!/bin/bash
@DTM@ workdir /tmp/x-XXXXXX
cd "$workdir" || exit 1
EOF'
tgb_sample helper-here-document-sourced none 'source "$SCRIPT_DIR/test_helpers.sh"
cat > "$p" <<'"'"'EOF'"'"'
source "$1/tests/lib/harness.sh"
@DTM@ workdir /tmp/x-XXXXXX
EOF'
tgb_sample helper-string unguarded 'source "$SCRIPT_DIR/test_helpers.sh"
ssh h '"'"'@DTM@ X /tmp/x.XXXXXX; cd "$X"'"'"
tgb_sample helper-string-sourced none 'source "$SCRIPT_DIR/test_helpers.sh"
bash -c '"'"'source "$1/test_helpers.sh"; @DTM@ X /tmp/x.XXXXXX'"'"' _ "$D"'
tgb_sample commented-out none '# X="$(@MK@ -d "$T/a.XXXXXX")"'
tgb_sample tool-list none 'for t in rm @MK@ mkdir; do ln -s "$(command -v "$t")" "$d/$t"; done'
tgb_sample nested-guarded guarded 'Y="$(X="$(@MK@ -d "$T/a.XXXXXX")" || exit 1; printf "%s\n" "$X")" || exit 1'
tgb_sample nested-multi guarded 'out="$(X="$(@MK@ -d "$T/a.XXXXXX")" || exit 1; run "$X")"'
tgb_sample sole-list unguarded 'X="$(@MK@ -d "$T/a.XXXXXX" || exit 1)"'
tgb_sample and-list guarded 'X="$(cd "$T" && @MK@ -d a.XXXXXX)" || exit 1'
tgb_sample or-list unguarded 'X="$(@MK@ -d "$T/a.XXXXXX" || echo /tmp)" || exit 1'
tgb_sample multi-unguarded unguarded 'out="$(X="$(@MK@ -d "$T/a.XXXXXX")"; run "$X")"'
tgb_sample two-sites guarded,unguarded 'A="$(@MK@ -d "$T/a.XXXXXX")" || exit 1
B="$(@MK@ -d "$T/b.XXXXXX")"'
# Calls of a function that makes and prints a new directory count the same
# way (contract item 2b), whether it comes from tests/lib or the file itself.
tgb_sample helper-plain unguarded 'X="$(@FTD@ "$d")"'
tgb_sample helper-exit guarded 'X="$(@FTD@ "$d")" || exit 1'
tgb_sample helper-case-check unguarded 'S="$(@PFR@)"
case "$S" in /*/dxe-persist-share.*) : ;; *) exit 1 ;; esac'
tgb_sample helper-argument unguarded 'fake_tool_write "$(@FTD@ "$d")" ssh "exit 0" || exit 1'
tgb_sample helper-path unguarded 'PATH="$(@FTD@ "$d"):$PATH"'
tgb_sample helper-local unguarded 'f() {
    local t="$(@FTD@ "$d")" || return 1
}'
tgb_sample helper-in-string unguarded 'bash -c '"'"'X="$(@PFR@ "$S")"; cd "$X"'"'"
tgb_sample wrapper unguarded,guarded 'new_root() { @PFR@ "$S"; }
R="$(new_root)" || exit 1'
tgb_sample wrapper-guarded guarded,unguarded 'new_root() { @PFR@ "$S" || return 1; }
R="$(new_root)"'
tgb_sample printer guarded,unguarded 'mk() {
    local d
    d="$(@MK@ -d "$1/x.XXXXXX")" || return 1
    printf "%s\n" "$d"
}
Y="$(mk "$T")"'
tgb_sample not-a-printer none 'show() {
    local d="$1"
    printf "%s\n" "$d"
}
Y="$(show "$T")"'
TGB_SAMPLE_ALLOW="$TGB_ROOT_P/samples-allow.tsv"
tgb_sample allowed allowed 'P='"'"'let repo = (@MK@ -d)'"'"
printf '%s\t%s\t%s\n' "$TGB_SAMPLES/allowed.sh" "P='let repo = ($TGB_TOOL -d)'" "a reviewed exception" \
    "$TGB_SAMPLES/allowed.sh" "Q=never-there" "an entry that matches no site" > "$TGB_SAMPLE_ALLOW"

TGB_SAMPLE_OUT="$TGB_ROOT_P/samples.out"
# shellcheck disable=SC2046  # one argument per sample file
tgb_scan "$TGB_SAMPLE_ALLOW" tests/lib/fake-tools.sh tests/lib/persist-fixtures.sh \
    $(for s in $TGB_SAMPLE_LIST; do printf '%s\n' "$TGB_SAMPLES/${s%%:*}.sh"; done) > "$TGB_SAMPLE_OUT" 2>&1
tgb_scan_rc=$?
if [ "$tgb_scan_rc" -eq 0 ]; then
    test_pass "static guard: the scanner runs over the samples"
else
    test_fail "static guard: the scanner runs over the samples (status $tgb_scan_rc)"
    tgb_show "$TGB_SAMPLE_OUT" 8
fi
for tgb_s in $TGB_SAMPLE_LIST; do
    tgb_name="${tgb_s%%:*}"
    tgb_want="${tgb_s#*:}"
    tgb_got=""
    while IFS=$'\t' read -r tgb_v tgb_loc _; do
        case "$tgb_loc" in
            "$TGB_SAMPLES/$tgb_name.sh":*) tgb_got="${tgb_got:+$tgb_got,}$tgb_v" ;;
        esac
    done < "$TGB_SAMPLE_OUT"
    [ -n "$tgb_got" ] || tgb_got=none
    if [ "$tgb_got" = "$tgb_want" ]; then
        test_pass "static guard sample '$tgb_name': $tgb_want"
    else
        test_fail "static guard sample '$tgb_name': want $tgb_want, got $tgb_got"
        tgb_show "$TGB_SAMPLES/$tgb_name.sh" 6
    fi
done
if grep -Fqx "$(printf 'stale\t%s\t%s' "$TGB_SAMPLES/allowed.sh" "Q=never-there")" "$TGB_SAMPLE_OUT" \
    && [ "$(grep -c '^stale' "$TGB_SAMPLE_OUT")" -eq 1 ]; then
    test_pass "static guard: an allowlist entry that matches no site is reported stale"
else
    test_fail "static guard: an allowlist entry that matches no site is reported stale"
    grep '^stale' "$TGB_SAMPLE_OUT" | sed 's/^/      | /'
fi

# --- 2b. the tree ------------------------------------------------------------
# The allowlist: file, exact trimmed line, reason. Keep it this small.
TGB_ALLOW="$TGB_ROOT_P/allowlist.tsv"
printf '%s\t%s\t%s\n' \
    tests/test_section15_nushell_env.sh "let repo = ($TGB_TOOL -d)" \
    "Nushell program text (LAZYGIT_PROBE) run by nu in the guest: a failing call raises a Nushell error that ends the program before 'cd \$repo'; there is no shell || exit form" \
    tests/test_persist_fixtures.sh "err=\"\$($TGB_PFN \"\$missing\" \"\$SCRATCH\" 2>&1)\"; rc=\$?" \
    "the case asserts that the helper refuses a missing share root: it expects the failure, and the value it captures is the error text, never a path" \
    tests/test_harness.sh "hh_out=\"\$(hh_probe lib/harness.sh '$TGB_DTM not-a-name \"\$PWD/dxe-hh-name.XXXXXX\"')\" && hh_status=0 || hh_status=\$?" \
    "acceptance probe body: hh_probe runs it in a bash that has sourced tests/lib/harness.sh first" \
    tests/test_tmpdir_failure_safety.sh "$TGB_DTM X \"\$2\"" \
    "acceptance probe (probe.sh) that sources the harness copy it is given as \$1 before this call" \
    > "$TGB_ALLOW"
TGB_TREE_OUT="$TGB_ROOT_P/tree.out"
(cd -P -- "$BASE_DIR" && set -- tests/test_*.sh tests/lib/*.sh && tgb_scan "$TGB_ALLOW" "$@") > "$TGB_TREE_OUT" 2>&1
tgb_scan_rc=$?
# Column 5 names what was called: tempdir (mktemp -d), or helper:NAME. The library
# helpers are the "producer" lines (helpers found in tests/lib/*.sh and
# tests/test_helpers.sh).
tgb_unguarded="$(awk -F'\t' '$1 == "unguarded" && $5 == "tempdir"' "$TGB_TREE_OUT" | grep -c .)"
TGB_LIB_HELPERS="$(awk -F'\t' '$1 == "producer" { print $2 }' "$TGB_TREE_OUT" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
tgb_lib_calls="$TGB_ROOT_P/tree-lib-calls.out"
tgb_local_calls="$TGB_ROOT_P/tree-local-calls.out"
awk -F'\t' -v libs=" $TGB_LIB_HELPERS " '
    $1 == "unguarded" && $5 ~ /^helper:/ {
        name = substr($5, 8)
        if (index(libs, " " name " ")) { print > lib } else { print > loc }
    }' lib="$tgb_lib_calls" loc="$tgb_local_calls" "$TGB_TREE_OUT"
touch "$tgb_lib_calls" "$tgb_local_calls"
tgb_guarded="$(grep -c '^guarded' "$TGB_TREE_OUT")"
if [ "$tgb_scan_rc" -eq 0 ] && grep -q "$(printf '^guarded\ttests/lib/harness.sh:')" "$TGB_TREE_OUT"; then
    test_pass "static guard: the scan runs over the tree and finds the harness's own fail-closed call ($tgb_guarded guarded site(s))"
else
    test_fail "static guard: the scan runs over the tree and finds the harness's own fail-closed call (status $tgb_scan_rc)"
    tgb_show "$TGB_TREE_OUT" 8
fi
if [ "$tgb_unguarded" -eq 0 ]; then
    test_pass "static guard: every directory-making $TGB_TOOL call in tests/test_*.sh and tests/lib/*.sh uses dxe_test_mktemp_dir or fails closed on the same statement"
else
    test_fail "static guard: every directory-making $TGB_TOOL call in tests/test_*.sh and tests/lib/*.sh uses dxe_test_mktemp_dir or fails closed on the same statement ($tgb_unguarded unguarded)"
    awk -F'\t' '$1 == "unguarded" && $5 == "tempdir" { printf "      | %s  (%s)\n", $2, $3 }' "$TGB_TREE_OUT"
fi
tgb_missing=""
for tgb_h in fake_tool_dir_create persist_fixture_nas_create persist_fixture_root_create; do
    case " $TGB_LIB_HELPERS " in
        *" $tgb_h "*) : ;;
        *) tgb_missing="$tgb_missing $tgb_h" ;;
    esac
done
if [ -z "$tgb_missing" ]; then
    test_pass "static guard: the scan finds the library helpers that make and print a new directory ($TGB_LIB_HELPERS)"
else
    test_fail "static guard: the scan finds the library helpers that make and print a new directory (missing:$tgb_missing; found: $TGB_LIB_HELPERS)"
fi
if [ ! -s "$tgb_lib_calls" ]; then
    test_pass "static guard: every call of a library helper that makes a directory ($TGB_LIB_HELPERS) fails closed on the same statement"
else
    test_fail "static guard: every call of a library helper that makes a directory ($TGB_LIB_HELPERS) fails closed on the same statement ($(grep -c . "$tgb_lib_calls") unguarded)"
    awk -F'\t' '{ printf "      | %s  %s  (%s)\n", $2, $5, $3 }' "$tgb_lib_calls"
fi
if [ ! -s "$tgb_local_calls" ]; then
    test_pass "static guard: every call of a suite's own function that makes and prints a directory fails closed on the same statement"
else
    test_fail "static guard: every call of a suite's own function that makes and prints a directory fails closed on the same statement ($(grep -c . "$tgb_local_calls") unguarded)"
    awk -F'\t' '{ printf "      | %s  %s  (%s)\n", $2, $5, $3 }' "$tgb_local_calls"
fi
tgb_dtm_calls="$(awk -F'\t' -v dtm="$TGB_DTM" '$1 == "unguarded" && $5 == dtm' "$TGB_TREE_OUT")"
if [ -z "$tgb_dtm_calls" ]; then
    test_pass "static guard: dxe_test_mktemp_dir is called only where tests/lib/harness.sh is loaded (never in program text another shell runs)"
else
    test_fail "static guard: dxe_test_mktemp_dir is called only where tests/lib/harness.sh is loaded (never in program text another shell runs) ($(grep -c . <<<"$tgb_dtm_calls") unguarded)"
    awk -F'\t' '{ printf "      | %s  %s\n", $2, $4 }' <<<"$tgb_dtm_calls"
fi
if ! grep -q '^stale' "$TGB_TREE_OUT"; then
    test_pass "static guard: every allowlist entry still names a site"
else
    test_fail "static guard: every allowlist entry still names a site"
    grep '^stale' "$TGB_TREE_OUT" | sed 's/^/      | /'
fi

# --- 2c. the library helpers fail loudly (contract item 2c) -----------------
# Each helper is called the way its callers call it, in "$(...)", from a
# probe that sources the libraries a suite sources; mktemp is a stub that
# records its arguments and fails, the destructive commands are recording
# stubs that change nothing, and cwd, HOME and TMPDIR are the probe's own.
TGB_HELPERS_DIR="$TGB_ROOT_P/helpers"
mkdir "$TGB_HELPERS_DIR" || tgb_abort "cannot create $TGB_HELPERS_DIR"
cat > "$TGB_HELPERS_DIR/probe.sh" <<'PROBE'
#!/bin/bash
# probe.sh CHECKOUT RESULT FUNCTION ARG...: records FUNCTION's status (as
# "status=N" in RESULT) and its stdout (RESULT.stdout) when called in $(...).
set -uo pipefail
probe_checkout="$1"
probe_result="$2"
shift 2
# shellcheck source=/dev/null
source "$probe_checkout/tests/test_helpers.sh" >/dev/null
# shellcheck source=/dev/null
source "$probe_checkout/tests/lib/fake-tools.sh"
# shellcheck source=/dev/null
source "$probe_checkout/tests/lib/persist-fixtures.sh"
probe_out="$("$@")"
printf 'status=%s\n' "$?" > "$probe_result"
printf '%s' "$probe_out" > "$probe_result.stdout"
exit 0
PROBE

# tgb_helper_fails ID FUNCTION [MODE]: the four checks of contract item 2c,
# with the arguments in TGB_HELPER_ARGS (@PARENT@ and @ROOT@ name two empty
# directories of the probe's own). MODE fail (the default): mktemp exits 1;
# MODE empty: mktemp exits 0 and prints nothing.
tgb_helper_fails() {
    local id="$1" fn="$2" mode="${3:-fail}" h label tool a tgb_helper_args stub_exit=1 what="fails"
    if [ "$mode" = empty ]; then
        stub_exit=0
        what="exits 0 but prints nothing"
    fi
    h="$TGB_HELPERS_DIR/$id"
    mkdir -p "$h/cwd" "$h/tmp" "$h/parent" "$h/root" "$h/stub" "$h/rec" || tgb_abort "cannot create $h"
    tgb_refuse_dangerous "helper probe $id" "$h/cwd"
    fake_tool_write "$h/stub" "$TGB_TOOL" "printf '%s\n' \"\$*\" >> $(printf '%q' "$h/mktemp.log")
exit $stub_exit"
    for tool in rm rmdir unlink mv chmod chown chgrp find; do
        fake_tool_write "$h/rec" "$tool" "printf '%s %s\n' \"\${0##*/}\" \"\$*\" >> $(printf '%q' "$h/destructive.log")
exit 0"
    done
    : > "$h/stderr"
    tgb_helper_args=()
    for a in "${TGB_HELPER_ARGS[@]}"; do
        case "$a" in
            @PARENT@) tgb_helper_args+=("$h/parent") ;;
            @ROOT@) tgb_helper_args+=("$h/root") ;;
            *) tgb_helper_args+=("$a") ;;
        esac
    done
    tgb_supervise 60 "$h/cwd" "$h/stderr" -- "$TGB_ENV" -i HOME="$h/cwd" LANG="${LANG:-C}" \
        PATH="$h/stub:$h/rec:$TGB_SYS_PATH" TMPDIR="$h/tmp" \
        "$TGB_BASH" "$TGB_HELPERS_DIR/probe.sh" "$TGB_CHECKOUT_P" "$h/result" "$fn" "${tgb_helper_args[@]+"${tgb_helper_args[@]}"}"
    label="library helper $fn, called in \$(...) when its mktemp $what"
    if [ -s "$h/result" ] && ! grep -qx 'status=0' "$h/result"; then
        test_pass "$label: returns non-zero ($(cat "$h/result"))"
    else
        test_fail "$label: returns non-zero ($(cat "$h/result" 2>/dev/null))"
        tgb_show "$h/stderr" 4
    fi
    if [ -f "$h/result.stdout" ] && [ ! -s "$h/result.stdout" ]; then
        test_pass "$label: prints nothing on stdout"
    else
        test_fail "$label: prints nothing on stdout (got [$(cat "$h/result.stdout" 2>/dev/null)])"
    fi
    if grep -F 'cannot create a temporary' "$h/stderr" | grep -Fq -- "$fn"; then
        test_pass "$label: says on stderr that $fn cannot create a temporary directory"
    else
        test_fail "$label: says on stderr that $fn cannot create a temporary directory"
        tgb_show "$h/stderr" 4
    fi
    if [ -s "$h/mktemp.log" ] && [ ! -s "$h/destructive.log" ] && [ -z "$(find "$h/parent" "$h/root" "$h/cwd" -mindepth 1 -print)" ]; then
        test_pass "$label: its mktemp ran, and nothing was created or removed"
    else
        test_fail "$label: its mktemp ran, and nothing was created or removed"
        tgb_show "$h/mktemp.log" 2
        tgb_show "$h/destructive.log" 3
    fi
}
TGB_HELPER_ARGS=(@PARENT@)
tgb_helper_fails ftd fake_tool_dir_create
TGB_HELPER_ARGS=(@PARENT@)
tgb_helper_fails pfr persist_fixture_root_create
TGB_HELPER_ARGS=(@ROOT@ @PARENT@)
tgb_helper_fails pfn persist_fixture_nas_create
TGB_HELPER_ARGS=(@PARENT@)
tgb_helper_fails ftd-empty fake_tool_dir_create empty
TGB_HELPER_ARGS=(@PARENT@)
tgb_helper_fails pfr-empty persist_fixture_root_create empty
TGB_HELPER_ARGS=(@ROOT@ @PARENT@)
tgb_helper_fails pfn-empty persist_fixture_nas_create empty

# =====================================================================
# 1. Fixture sites, from decoys with one mktemp failing (contract item 1)
# =====================================================================
TGB_SENTINEL=DECOY-SENTINEL
TGB_INJECT_MARK='@@dxe-tmpguard-b: injected failure'
TGB_REAL_MARK='@@dxe-tmpguard-b: real failure'
TGB_SANDBOX=no
if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] \
    && /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    TGB_SANDBOX=yes
fi
case "$TGB_ROOT_P" in
    *'"'* | *'\'*) TGB_SANDBOX=no ;;
esac
# Without a sandbox, a host that has the guest's real directories is a guest:
# the suites that would write there are not run (see the header).
TGB_GUEST_REAL=no
if [ "$TGB_SANDBOX" = no ] && { [ -e /persist ] || [ -e /home/dx ]; }; then
    TGB_GUEST_REAL=yes
fi

TGB_PRISTINE="$TGB_ROOT_P/pristine"
mkdir "$TGB_PRISTINE" || tgb_abort "cannot create $TGB_PRISTINE"
for tgb_d in tests bin container; do
    cp -R "$BASE_DIR/$tgb_d" "$TGB_PRISTINE/$tgb_d" || tgb_abort "cannot copy $tgb_d into the pristine decoy"
done
tgb_refuse_dangerous "the pristine decoy" "$TGB_PRISTINE"

TGB_TOOLS="$TGB_ROOT_P/tools"
mkdir "$TGB_TOOLS" || tgb_abort "cannot create $TGB_TOOLS"
cat > "$TGB_TOOLS/guard.sh" <<'GUARD'
# Sourced by every wrapper with tgb_tool, tgb_real, tgb_kind (destructive |
# write | inject), tgb_decoy, tgb_tmp, tgb_run (physical, no trailing slash),
# tgb_refused, tgb_trip, tgb_hits, tgb_events, tgb_pattern, tgb_nth and
# tgb_count set. Builtins only.
tgb_canon() {
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
tgb_armed=no
[ -s "$tgb_hits" ] && tgb_armed=yes
if [ "$tgb_kind" = inject ] && [ -n "$tgb_pattern" ]; then
    tgb_inject=no
    for tgb_a in "$@"; do
        case "$tgb_a" in
            "$tgb_pattern" | */"$tgb_pattern") tgb_inject=yes ;;
        esac
    done
    if [ "$tgb_inject" = yes ]; then
        tgb_n=0
        if [ -s "$tgb_count" ]; then read -r tgb_n < "$tgb_count"; fi
        tgb_n=$((tgb_n + 1))
        printf '%s\n' "$tgb_n" > "$tgb_count"
        if [ "$tgb_n" -eq "$tgb_nth" ]; then
            printf '%s\n' "$*" >> "$tgb_hits"
            printf '@@dxe-tmpguard-b: injected failure: %s@@\n' "$*" >> "$tgb_events"
            printf 'mktemp: %s: injected failure (dxe-tmpguard-b)\n' "$*" >&2
            exit 1
        fi
    fi
fi
# The tripwire: after the injected failure, no operand outside the decoy, the
# run's TMPDIR and the run directory, whether or not it exists yet.
if [ "$tgb_armed" = yes ]; then
    tgb_where="$(pwd -P 2>/dev/null)" || tgb_where="?"
    if [ "$tgb_tool" = git ]; then
        case "$tgb_where/" in
            "$tgb_decoy"/* | "$tgb_tmp"/* | "$tgb_run"/*) : ;;
            *)
                printf '%s %s [working directory %s]\n' "$tgb_tool" "$*" "$tgb_where" >> "$tgb_trip"
                printf 'dxe-tmpguard-b: refused git in %s after the injected failure\n' "$tgb_where" >&2
                exit 1
                ;;
        esac
    fi
    tgb_opts=yes
    for tgb_a in "$@"; do
        if [ "$tgb_opts" = yes ]; then
            case "$tgb_a" in
                --) tgb_opts=no; continue ;;
                -?*) continue ;;
            esac
        fi
        [ -n "$tgb_a" ] || continue
        tgb_c="$(tgb_canon "$tgb_a")"
        case "$tgb_c/" in
            "$tgb_decoy"/* | "$tgb_tmp"/* | "$tgb_run"/*) : ;;
            *)
                printf '%s %s [operand %s resolves to %s; cwd %s]\n' "$tgb_tool" "$*" "$tgb_a" "$tgb_c" "$tgb_where" >> "$tgb_trip"
                printf 'dxe-tmpguard-b: refused %s on %s after the injected failure: outside the decoy checkout and its TMPDIR\n' "$tgb_tool" "$tgb_a" >&2
                exit 1
                ;;
        esac
    done
fi
if [ "$tgb_kind" = destructive ]; then
    tgb_check=yes
    case "$tgb_tool" in
        find)
            tgb_check=no
            for tgb_a in "$@"; do [ "$tgb_a" = -delete ] && tgb_check=yes; done
            ;;
        rsync)
            tgb_check=no
            for tgb_a in "$@"; do
                case "$tgb_a" in --delete* | --remove-source-files) tgb_check=yes ;; esac
            done
            ;;
    esac
    if [ "$tgb_check" = yes ]; then
        tgb_opts=yes
        for tgb_a in "$@"; do
            if [ "$tgb_opts" = yes ]; then
                case "$tgb_a" in
                    --) tgb_opts=no; continue ;;
                    -?*) continue ;;
                esac
            fi
            [ -n "$tgb_a" ] || continue
            [ -e "$tgb_a" ] || [ -L "$tgb_a" ] || continue
            tgb_c="$(tgb_canon "$tgb_a")"
            case "$tgb_c/" in
                "$tgb_decoy"/* | "$tgb_tmp"/*) : ;;
                *)
                    printf '%s %s [operand %s resolves to %s]\n' "$tgb_tool" "$*" "$tgb_a" "$tgb_c" >> "$tgb_refused"
                    printf 'dxe-tmpguard-b: refused %s on %s: outside the decoy checkout and its TMPDIR\n' "$tgb_tool" "$tgb_a" >&2
                    exit 1
                    ;;
            esac
        done
    fi
fi
if [ "$tgb_kind" = inject ]; then
    "$tgb_real" "$@"
    tgb_rc=$?
    if [ "$tgb_rc" -ne 0 ]; then
        printf '@@dxe-tmpguard-b: real failure: %s@@\n' "$*" >> "$tgb_events"
    fi
    exit "$tgb_rc"
fi
exec "$tgb_real" "$@"
GUARD

# tgb_guard_build DIR DECOY_P TMP_P RUN_P PATTERN NTH UNAME_LINUX
tgb_guard_build() {
    local dir="$1" decoy_p="$2" tmp_p="$3" run_p="$4" pattern="$5" nth="$6" uname_linux="$7" tool real kind
    mkdir "$dir" || tgb_abort "cannot create the guard directory $dir"
    for tool in $FAKE_TOOLS_FAIL_CLOSED_LIST; do
        fake_tool_write "$dir" "$tool" "echo 'dxe-tmpguard-b: no real $tool from a decoy run' >&2
exit 99"
    done
    for tool in rm rmdir unlink mv chmod chown chgrp find rsync mkdir cp ln git tar touch install tee "$TGB_TOOL"; do
        real="$(command -v "$tool")" || continue
        case "$tool" in
            rm | rmdir | unlink | mv | chmod | chown | chgrp | find | rsync) kind="destructive" ;;
            "$TGB_TOOL") kind="inject" ;;
            *) kind="write" ;;
        esac
        printf '#!%s\ntgb_tool=%q; tgb_real=%q; tgb_kind=%q; tgb_decoy=%q; tgb_tmp=%q; tgb_run=%q\ntgb_refused=%q; tgb_trip=%q; tgb_hits=%q; tgb_events=%q; tgb_pattern=%q; tgb_nth=%q; tgb_count=%q\n. %q\n' \
            "$TGB_BASH" "$tool" "$real" "$kind" "$decoy_p" "$tmp_p" "$run_p" \
            "$run_p/refused.log" "$run_p/tripwire.log" "$run_p/mktemp-hits.log" "$run_p/events" "$pattern" "$nth" "$run_p/mktemp-count" \
            "$TGB_TOOLS/guard.sh" > "$dir/$tool"
        chmod 0755 "$dir/$tool" || tgb_abort "cannot make $dir/$tool executable"
    done
    if [ "$uname_linux" = yes ]; then
        real="$(command -v uname)" || tgb_abort "uname is required"
        printf '#!%s\ncase " $* " in\n    "  " | *" -s "*) echo Linux; exit 0 ;;\nesac\nexec %q "$@"\n' "$TGB_BASH" "$real" > "$dir/uname"
        chmod 0755 "$dir/uname" || tgb_abort "cannot make $dir/uname executable"
    fi
}

tgb_sandbox_profile() { # DECOY_P RUN_P
    printf '(version 1)(allow default)(deny file-write* (subpath "/"))'
    printf '(allow file-write* (subpath "%s") (subpath "%s")' "$1" "$2"
    printf ' (literal "/dev/null") (literal "/dev/tty") (literal "/dev/zero") (regex #"^/dev/fd/"))'
    printf '(deny network-outbound)(deny mach-lookup (global-name-prefix "com.apple.container"))'
}

tgb_snapshot() { # DIR
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

# tgb_decoy_run ID SUITE_REL PATTERN NTH [UNAME_LINUX]: builds decoy-ID and
# run-ID and runs the decoy's copy of SUITE_REL from the decoy root, TMPDIR a
# real scratch directory in which only the NTH mktemp call whose template
# ends in PATTERN fails. Sets TGB_RUN TGB_DECOY TGB_RC TGB_EVENTS.
tgb_decoy_run() {
    local id="$1" suite="$2" pattern="$3" nth="$4" uname_linux="${5:-no}" tmp sandbox_args
    TGB_RUN="$TGB_ROOT_P/run-$id"
    TGB_DECOY="$TGB_ROOT_P/decoy-$id"
    TGB_EVENTS="$TGB_RUN/events"
    mkdir "$TGB_RUN" "$TGB_RUN/home" "$TGB_RUN/tmp" || tgb_abort "cannot create $TGB_RUN"
    cp -R "$TGB_PRISTINE" "$TGB_DECOY" || tgb_abort "cannot copy the decoy for $id"
    printf 'decoy checkout sentinel for %s\n' "$id" > "$TGB_DECOY/$TGB_SENTINEL"
    tgb_refuse_dangerous "decoy $id" "$TGB_DECOY"
    TGB_DECOY="$(tgb_physical "$TGB_DECOY")"
    [ -f "$TGB_DECOY/$suite" ] || tgb_abort "decoy $id has no $suite"
    tgb_snapshot "$TGB_DECOY" > "$TGB_RUN/before"
    : > "$TGB_RUN/refused.log"
    : > "$TGB_RUN/tripwire.log"
    : > "$TGB_EVENTS"
    tmp="$TGB_RUN/tmp"
    tgb_guard_build "$TGB_RUN/guard" "$TGB_DECOY" "$tmp" "$TGB_RUN" "$pattern" "$nth" "$uname_linux"
    sandbox_args=()
    if [ "$TGB_SANDBOX" = yes ]; then
        sandbox_args=(/usr/bin/sandbox-exec -p "$(tgb_sandbox_profile "$TGB_DECOY" "$TGB_RUN")")
    fi
    tgb_supervise 300 "$TGB_DECOY" "$TGB_EVENTS" -- "$TGB_ENV" -i \
        HOME="$TGB_RUN/home" USER="${USER:-dxe}" LOGNAME="${LOGNAME:-${USER:-dxe}}" LANG="${LANG:-C}" TERM=dumb \
        PATH="$TGB_RUN/guard:$TGB_SYS_PATH" TMPDIR="$tmp" SKIP_INTEGRATION=true \
        DX_PROFILES_DIR="$TGB_DECOY/tests/profiles" GIT_CEILING_DIRECTORIES="$TGB_ROOT_P" GIT_CONFIG_NOSYSTEM=1 \
        "${sandbox_args[@]+"${sandbox_args[@]}"}" "$TGB_BASH" "$suite"
    TGB_RC=$?
    tgb_snapshot "$TGB_DECOY" > "$TGB_RUN/after"
}

# Prints the first case result line after the injected failure.
tgb_case_after_failure() {
    LC_ALL=C awk -v mark="$TGB_INJECT_MARK" '
        index($0, mark) { seen = 1; next }
        seen && (index($0, "✓ PASS") || index($0, "✗ FAIL") || index($0, "○ SKIP")) { print; exit }
    ' "$1"
}

# Prints the first real (not injected) mktemp failure before the injected one.
tgb_real_failure_before() {
    LC_ALL=C awk -v inject="$TGB_INJECT_MARK" -v real="$TGB_REAL_MARK" '
        index($0, inject) { exit }
        index($0, real) { print; exit }
    ' "$1"
}

# tgb_site ID SUITE TEMPLATE NTH WHAT [UNAME_LINUX]: one injected run and the
# six checks of contract item 1.
tgb_site() {
    local id="$1" suite="$2" template="$3" nth="$4" what="$5" uname_linux="${6:-no}" label after refusals earlier
    label="${suite#tests/} when only $what cannot be created"
    tgb_decoy_run "$id" "$suite" "$template" "$nth" "$uname_linux"
    earlier="$(tgb_real_failure_before "$TGB_EVENTS")"
    if [ ! -s "$TGB_RUN/mktemp-hits.log" ]; then
        test_fail "$label: the injected failure is reached (fewer than $nth calls end in $template${earlier:+; earlier: $earlier})"
    elif [ -n "$earlier" ]; then
        test_fail "$label: the injected failure is reached with no mktemp failing before it (earlier: $earlier)"
    else
        test_pass "$label: the injected failure is reached with no mktemp failing before it"
    fi
    if [ "$TGB_RC" -ne 0 ] && [ "$TGB_RC" -ne 124 ]; then
        test_pass "$label: exits non-zero (status $TGB_RC)"
    else
        test_fail "$label: exits non-zero (status $TGB_RC; 124 = killed by the time bound)"
        tail -n 4 "$TGB_EVENTS" | sed 's/^/      | /'
    fi
    refusals="$(grep -F 'cannot create a temporary' "$TGB_EVENTS")"
    if [ -n "$refusals" ] && grep -Fq -- "$template" <<<"$refusals"; then
        test_pass "$label: says it cannot create a temporary directory from $template"
    else
        test_fail "$label: says it cannot create a temporary directory from $template"
        tail -n 4 "$TGB_EVENTS" | sed 's/^/      | /'
    fi
    after="$(tgb_case_after_failure "$TGB_EVENTS")"
    if ! grep -Fq -- "$TGB_INJECT_MARK" "$TGB_EVENTS"; then
        test_fail "$label: stops at the failure (no mktemp failure was seen at all)"
    elif [ -z "$after" ]; then
        test_pass "$label: stops at the failure (no case result after it)"
    else
        test_fail "$label: stops at the failure (still ran: $after)"
    fi
    if [ -d "$TGB_DECOY" ] && [ -f "$TGB_DECOY/$TGB_SENTINEL" ] && cmp -s "$TGB_RUN/before" "$TGB_RUN/after"; then
        test_pass "$label: the decoy checkout is untouched"
    else
        test_fail "$label: the decoy checkout is untouched (sentinel or files added, removed or changed)"
        diff "$TGB_RUN/before" "$TGB_RUN/after" 2>/dev/null | sed -n '1,6p' | sed 's/^/      | /'
    fi
    if [ ! -s "$TGB_RUN/tripwire.log" ] && [ ! -s "$TGB_RUN/refused.log" ]; then
        test_pass "$label: nothing outside the decoy and its TMPDIR is written, deleted or given to git"
    else
        test_fail "$label: nothing outside the decoy and its TMPDIR is written, deleted or given to git"
        tgb_show "$TGB_RUN/tripwire.log" 5
        tgb_show "$TGB_RUN/refused.log" 3
    fi
}

tgb_guest_site() { # like tgb_site, for a suite that writes guest paths when its fixture is empty
    if [ "$TGB_GUEST_REAL" = yes ]; then
        test_skip "${2#tests/} when only $5 cannot be created: not run on a host with real /persist or /home/dx and no sandbox"
        return 0
    fi
    tgb_site "$@"
}

# The guest-path sites (/persist/home, /persist/git, /home/dx).
tgb_guest_site restore tests/test_dx_restore.sh dxe-dx-restore-test.XXXXXX 1 "the FIXTURE directory"
tgb_uname=no
[ "$(uname -s)" = Linux ] || tgb_uname=yes
tgb_guest_site herdr tests/test_herdr_config_persistence.sh dxe-herdr-config-test.XXXXXX 1 "the fixture directory" "$tgb_uname"
tgb_guest_site backup tests/test_dx_backup.sh dxe-dx-backup-test.XXXXXX 1 "the FIXTURE directory"
tgb_guest_site pbs tests/test_persist_backup_select.sh dxe-pbs-test.XXXXXX 1 "the FIXTURE directory"
tgb_guest_site pbs-findfail tests/test_persist_backup_select.sh dxe-pbs-findfail.XXXXXX 1 "the find-failure root"
tgb_guest_site pbs-statfail tests/test_persist_backup_select.sh dxe-pbs-statfail.XXXXXX 1 "the stat-failure root"
# The share roots tests/test_persist_reclaim.sh canonicalises with cd -P.
tgb_site reclaim-root tests/test_persist_reclaim.sh dxe-persist-share.XXXXXX 2 "the share root ROOT"
tgb_site reclaim-empty tests/test_persist_reclaim.sh dxe-persist-share.XXXXXX 3 "the share root EMPTY_ROOT"
# world() in the migrate and rollback suites: CANON="$(cd -P "$ROOT" && pwd -P)"
# is the checkout when ROOT is empty.
tgb_site migrate-world tests/test_persist_migrate.sh dxe-persist-share.XXXXXX 2 "the first world() share root"
tgb_site rollback-world tests/test_persist_rollback.sh dxe-persist-share.XXXXXX 2 "the first world() share root"
# Section 20: its stub directory, and the marker files whose emptiness is
# the "invokes no container/ssh/scp/dx-ai command" proof.
tgb_site s20-stub-bin tests/test_section20_skip_integration.sh dxe-stub-bin.XXXXXX 1 "the stub directory"
tgb_site s20-marker tests/test_section20_skip_integration.sh dxe-stub-marker.XXXXXX 1 "the section 15 marker file"
tgb_site s20-runsh-unset tests/test_section20_skip_integration.sh dxe-stub-marker-runsh-unset.XXXXXX 1 "the run.sh (SKIP_INTEGRATION unset) marker file"
tgb_site s20-runsh-refuse tests/test_section20_skip_integration.sh dxe-stub-marker-runsh-refuse.XXXXXX 1 "the run.sh refusal marker file"
tgb_site s20-lt-1 tests/test_section20_skip_integration.sh dxe-stub-marker-lt.XXXXXX 1 "the first live-tail marker file"
tgb_site s20-lt-5 tests/test_section20_skip_integration.sh dxe-stub-marker-lt.XXXXXX 5 "the directly-run section 17 marker file"
tgb_site s20-ev tests/test_section20_skip_integration.sh dxe-stub-marker-ev.XXXXXX 1 "the run_all_tests marker file"

# Section 27: its marker file (the "--dry-run never invokes ssh/docker"
# proof) and run_with_stubs' run directory, made inside "$(...)".
tgb_site s27-marker tests/test_section27_qnap_scripts.sh dxe-qnap-marker.XXXXXX 1 "the marker file"
tgb_site s27-run tests/test_section27_qnap_scripts.sh dxe-qnap-run.XXXXXX 1 "the first run_with_stubs directory"

# =====================================================================
# 4. Section 14's guest drivers, run standalone (contract item 4)
# =====================================================================
# The suite ships each <<'DRIVER_EOF' body to the guest and runs it there as
# `bash DRIVER PROBE`: no harness, no test_helpers.sh. Each body is
# extracted as shipped and run with bash from a scratch directory, with
# recording stubs for nvim and rm, a mktemp that makes its directories in the
# scratch directory (or fails on the Nth call), and, on macOS, sandbox-exec
# keeping every write inside the scratch directory.
TGB_DRIVERS="$TGB_ROOT_P/drivers"
mkdir "$TGB_DRIVERS" || tgb_abort "cannot create $TGB_DRIVERS"
tgb_driver_count="$("$TGB_PERL" -e '
    my ($src, $dir) = @ARGV;
    open(my $h, "<", $src) or die "cannot read $src\n";
    my ($n, $in, $body) = (0, 0, "");
    while (my $l = <$h>) {
        if ($in) {
            if ($l =~ /^DRIVER_EOF$/) {
                $n++;
                open(my $o, ">", "$dir/driver-$n.sh") or die "cannot write\n";
                print $o $body;
                close $o;
                ($in, $body) = (0, "");
            } else {
                $body .= $l;
            }
        } elsif ($l =~ /<<\x27DRIVER_EOF\x27\s*$/) {
            $in = 1;
        }
    }
    print "$n\n";
' "$BASE_DIR/tests/test_section14_tinty_theming.sh" "$TGB_DRIVERS")" || tgb_driver_count=0
if [ "$tgb_driver_count" = 2 ]; then
    test_pass "section 14 ships two guest drivers (<<'DRIVER_EOF' bodies)"
else
    test_fail "section 14 ships two guest drivers (<<'DRIVER_EOF' bodies): found [$tgb_driver_count]"
fi

# tgb_driver_run ID DRIVER NTH: runs DRIVER; NTH 0 = every mktemp works.
# Sets TGB_DR (the run directory) and TGB_DRC.
tgb_driver_run() {
    local id="$1" driver="$2" nth="$3" sandbox_args
    TGB_DR="$TGB_DRIVERS/run-$id"
    mkdir -p "$TGB_DR/cwd" "$TGB_DR/bin" "$TGB_DR/made" "$TGB_DR/tmp" || tgb_abort "cannot create $TGB_DR"
    tgb_refuse_dangerous "driver run $id" "$TGB_DR"
    : > "$TGB_DR/probe.lua"
    : > "$TGB_DR/mktemp.log"
    : > "$TGB_DR/nvim.log"
    : > "$TGB_DR/rm.log"
    fake_tool_write "$TGB_DR/bin" "$TGB_TOOL" "n=0
[ -s $(printf '%q' "$TGB_DR/mktemp.count") ] && read -r n < $(printf '%q' "$TGB_DR/mktemp.count")
n=\$((n + 1))
printf '%s\n' \"\$n\" > $(printf '%q' "$TGB_DR/mktemp.count")
printf '%s\n' \"\$*\" >> $(printf '%q' "$TGB_DR/mktemp.log")
[ \"\$n\" -ne $nth ] || exit 1
d=$(printf '%q' "$TGB_DR/made")/m\$n
mkdir \"\$d\" || exit 1
printf '%s\n' \"\$d\""
    fake_tool_write "$TGB_DR/bin" nvim "printf '%s | cwd=%s | XDG_DATA_HOME=%s\n' \"\$*\" \"\$(pwd -P)\" \"\${XDG_DATA_HOME:-}\" >> $(printf '%q' "$TGB_DR/nvim.log")
exit 0"
    fake_tool_write "$TGB_DR/bin" rm "printf '%s\n' \"\$*\" >> $(printf '%q' "$TGB_DR/rm.log")
exit 0"
    sandbox_args=()
    if [ "$TGB_SANDBOX" = yes ]; then
        sandbox_args=(/usr/bin/sandbox-exec -p "$(tgb_sandbox_profile "$TGB_DR" "$TGB_DR")")
    fi
    : > "$TGB_DR/out"
    tgb_supervise 60 "$TGB_DR/cwd" "$TGB_DR/out" -- "$TGB_ENV" -i HOME="$TGB_DR/cwd" LANG="${LANG:-C}" \
        PATH="$TGB_DR/bin:$TGB_SYS_PATH" TMPDIR="$TGB_DR/tmp" \
        "${sandbox_args[@]+"${sandbox_args[@]}"}" "$TGB_BASH" "$driver" "$TGB_DR/probe.lua"
    TGB_DRC=$?
}

tgb_n=1
while [ "$tgb_n" -le "$tgb_driver_count" ]; do
    tgb_driver="$TGB_DRIVERS/driver-$tgb_n.sh"
    tgb_label="section 14 guest driver $tgb_n, run standalone as shipped"
    tgb_driver_run "d$tgb_n-ok" "$tgb_driver" 0
    if [ "$TGB_DRC" -eq 0 ] && [ "$(grep -c . "$TGB_DR/nvim.log")" -eq 1 ] && [ -s "$TGB_DR/mktemp.log" ]; then
        test_pass "$tgb_label: with every mktemp working it runs nvim once and exits 0"
    else
        test_fail "$tgb_label: with every mktemp working it runs nvim once and exits 0 (status $TGB_DRC)"
        tgb_show "$TGB_DR/out" 4
    fi
    for tgb_nth in 1 2; do
        tgb_driver_run "d$tgb_n-fail$tgb_nth" "$tgb_driver" "$tgb_nth"
        if [ "$TGB_DRC" -ne 0 ] && [ "$TGB_DRC" -ne 124 ] && [ "$(grep -c . "$TGB_DR/mktemp.log")" -eq "$tgb_nth" ]; then
            test_pass "$tgb_label: stops non-zero at its failing mktemp call $tgb_nth (status $TGB_DRC)"
        else
            test_fail "$tgb_label: stops non-zero at its failing mktemp call $tgb_nth (status $TGB_DRC; mktemp calls: $(grep -c . "$TGB_DR/mktemp.log"))"
            tgb_show "$TGB_DR/out" 4
        fi
        if [ ! -s "$TGB_DR/nvim.log" ] && [ ! -s "$TGB_DR/rm.log" ]; then
            test_pass "$tgb_label: after a failing mktemp call $tgb_nth it runs neither nvim nor rm"
        else
            test_fail "$tgb_label: after a failing mktemp call $tgb_nth it runs neither nvim nor rm"
            tgb_show "$TGB_DR/nvim.log" 2
            tgb_show "$TGB_DR/rm.log" 2
        fi
    done
    tgb_n=$((tgb_n + 1))
done

if [ "$TGB_SANDBOX" = yes ]; then
    echo "  (decoy runs executed under sandbox-exec: no write outside the decoy and its run directory)"
else
    echo "  (sandbox-exec unavailable: decoy runs relied on the decoy cwd and the PATH guards)"
fi

print_summary
exit_with_code
