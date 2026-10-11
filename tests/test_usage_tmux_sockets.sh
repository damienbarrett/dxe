#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
#
# Stale tmux sockets left behind by the guest usage service
# (container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh).
#
# Root cause (read from the agent-stats sources, never from a real guest):
# every scrape of the agent-stats package (Rust scraper.rs and Python tmux.py
# alike) starts its OWN tmux server on a unique socket, `tmux -L
# agent-stats-<uuid> -f /dev/null`, and relies on `kill-server` (or the
# 120 s tmux-owned `run-shell -d 120 -C kill-server` timer) to end it. A
# server that dies without running its exit path (SIGKILL of the whole
# service, container stop, an s6 restart that kills the process group, OOM)
# leaves its socket file behind, and nothing ever names that socket again, so
# the files accumulate for ever: 1,440 sockets were seen under
# services/agent-stats/workspace/tmux/tmux-<uid>/ on a real guest. The service
# already sets TMUX_TMPDIR=<root>/workspace/tmux, so tmux keeps them in
# <root>/workspace/tmux/tmux-<uid>/. If the cause were different from this
# reading, the fix below is still correct for the general case: it removes
# only dead sockets, whoever made them.
#
# Interface contract:
#   dx_usage_service_prune_tmux_sockets DIR   (scripts/lib/dx-usage-service.sh)
#     DIR is "$TMUX_TMPDIR/tmux-<uid>" for the service's own uid (id -u).
#     * Refuses (status 1, stderr "Error: refusing to prune ..." naming DIR,
#       NOTHING touched, no rm/find/unlink/mv/chmod/chown run) when DIR is
#       empty, not absolute, contains a "." or ".." component, does not end in
#       exactly "/workspace/tmux/tmux-<id -u>" (so: wrong uid, trailing slash,
#       extra suffix, other parent all refuse), or exists but is a symlink or
#       not a directory.
#     * DIR absent: status 0, nothing created, silent.
#     * Otherwise removes, among the DIRECT children of DIR only, entries that
#       are sockets (type s, a symlink is never one) AND dead: a connect(2) to
#       the socket is refused or fails. A socket that accepts a connection
#       (a live tmux server, or anything else listening) is kept. Directories
#       (and their contents), regular files, symlinks (to anything, dangling
#       or not) and everything outside DIR are never touched. Names with
#       spaces or a leading "-" work. Dot-names included.
#     * Status 0 when it finished; then, when n > 0 sockets were removed,
#       stderr gets one line "Pruned <n> stale tmux socket(s) from DIR";
#       stdout stays empty; n = 0 prints nothing. Idempotent.
#     * Status 1 (with an "Error:" line) when a dead socket could not be
#       removed.
#   dx_usage_service_serve calls it as
#     dx_usage_service_prune_tmux_sockets "$root/workspace/tmux/tmux-$(id -u)"
#   after prepare_state and before the final exec of the package, so it sees
#   the same directory TMUX_TMPDIR will name. A non-zero status only prints
#   "Warning: could not prune stale tmux sockets" on stderr: the service still
#   starts (exec) exactly as before. Liveness is judged by connecting, not by
#   assuming a restart killed every earlier server, because an orphaned
#   server of an earlier run can outlive an s6 restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Usage service prunes stale tmux sockets (guest scripts/lib/dx-usage-service.sh)"

GUEST_SCRIPTS="$CONTAINER_DIR/scripts"
LIB="$GUEST_SCRIPTS/lib/dx-usage-service.sh"
FN=dx_usage_service_prune_tmux_sockets
uid="$(id -u)"
other_uid=$((uid + 1))

# Short root: a unix socket path is limited to ~104 bytes.
fx="$(mktemp -d /tmp/dxe-tm.XXXXXX)"
reap_live() {
    local p
    for p in $(ps -eo pid=,command= | awk -v pat="$fx/" '{ if (index($0, "live.pl") && index($0, pat)) print $1 }'); do kill "$p" 2>/dev/null || true; done
}
cleanup() {
    reap_live
    case "$fx" in /tmp/dxe-tm.??????) rm -rf "$fx" ;; esac
}
trap cleanup EXIT
mkdir -p "$fx/home" "$fx/cwd" "$fx/bin" "$fx/outside"

# Socket helpers (perl; bind by relative name after chdir for short paths).
cat > "$fx/stale.pl" <<'PL'
use Socket;
chdir $ARGV[0] or die "chdir: $!";
socket(S, PF_UNIX, SOCK_STREAM, 0) or die;
bind(S, sockaddr_un($ARGV[1])) or die "bind: $!";
exit 0;    # bound, never listening, file left behind: connect is refused
PL
cat > "$fx/live.pl" <<'PL'
use Socket;
chdir $ARGV[0] or die "chdir: $!";
socket(S, PF_UNIX, SOCK_STREAM, 0) or die;
bind(S, sockaddr_un($ARGV[1])) or die "bind: $!";
listen(S, 5) or die;
my $pid = fork();
exit 0 if $pid;
close STDOUT; close STDERR; close STDIN;
while (1) { accept(C, S) and close C; }
PL
cat > "$fx/probe.pl" <<'PL'
use Socket;
chdir $ARGV[0] or exit 2;
socket(S, PF_UNIX, SOCK_STREAM, 0) or exit 2;
exit(connect(S, sockaddr_un($ARGV[1])) ? 0 : 1);
PL
mk_stale() { perl "$fx/stale.pl" "$1" "$2"; }
mk_live() { perl "$fx/live.pl" "$1" "$2"; }
probe_alive() { perl "$fx/probe.pl" "$1" "$2"; }
listing() { (cd "$1" && ls -A | LC_ALL=C sort); }

root="$fx/r"
tmuxdir="$root/workspace/tmux"
tdir="$tmuxdir/tmux-$uid"
build_fixture() {
    # Fresh tree: $1 = the tmux-<uid> directory to populate.
    local d="$1"
    mkdir -p "$d/agent-stats-dir" "$fx/outside" "$(dirname "$d")/tmux-$other_uid"
    mk_stale "$d" agent-stats-aaaa
    mk_stale "$d" default
    mk_stale "$d" "agent-stats-a b"
    mk_stale "$d" -dash
    mk_stale "$d" .hidden
    mk_live "$d" agent-stats-live
    mk_live "$d" live-other
    : > "$d/agent-stats-file"
    mk_stale "$d/agent-stats-dir" inner
    mk_stale "$fx/outside" stale-out
    mk_live "$fx/outside" live-out
    ln -s "$fx/outside/stale-out" "$d/agent-stats-link"
    ln -s "$fx/outside/live-out" "$d/agent-stats-livelink"
    ln -s "$fx/outside/nowhere" "$d/agent-stats-dangling"
    mk_stale "$(dirname "$d")" sibling-stale
    mk_stale "$(dirname "$d")/tmux-$other_uid" other-uid-stale
}

run_prune() {
    # $1 = dir. Sets pr_rc, pr_out, pr_err. Runs in a subshell in $fx/cwd.
    pr_rc=0
    (
        cd "$fx/cwd"
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
        source "$LIB"
        "$FN" "$1"
    ) > "$fx/pr.out" 2> "$fx/pr.err" || pr_rc=$?
    pr_out="$(cat "$fx/pr.out")"; pr_err="$(cat "$fx/pr.err")"
}

# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
if ! ( source "$LIB"; type "$FN" >/dev/null 2>&1 ); then
    test_fail "the library defines $FN"
else
    test_pass "the library defines $FN"
fi

# --- pruning ---------------------------------------------------------------
build_fixture "$tdir"
run_prune "$tdir"
want="agent-stats-dangling
agent-stats-dir
agent-stats-file
agent-stats-link
agent-stats-live
agent-stats-livelink
live-other"
if [ "$pr_rc" -eq 0 ] && [ "$(listing "$tdir")" = "$want" ]; then
    test_pass "prune removes exactly the dead sockets (plain, default, spaced, dash, dot names)"
else
    test_fail "prune removes exactly the dead sockets (rc $pr_rc; left: $(listing "$tdir" | tr '\n' '|'); err: $pr_err)"
fi
[ "$pr_out" = "" ] && grep -qF "Pruned 5 stale tmux socket(s) from $tdir" "$fx/pr.err" \
    && test_pass "prune reports the count on stderr and prints nothing on stdout" \
    || test_fail "prune reports 'Pruned 5 stale tmux socket(s) from DIR' on stderr, stdout empty (out: $pr_out; err: $pr_err)"
{ [ -S "$tdir/agent-stats-live" ] && probe_alive "$tdir" agent-stats-live && probe_alive "$tdir" live-other; } \
    && test_pass "live listeners are kept and still accept connections" \
    || test_fail "live listeners are kept and still accept connections"
{ [ -f "$tdir/agent-stats-file" ] && [ -d "$tdir/agent-stats-dir" ] && [ -S "$tdir/agent-stats-dir/inner" ]; } \
    && test_pass "regular files and directories (with their sockets) are untouched" \
    || test_fail "regular files and directories (with their sockets) are untouched"
{ [ -L "$tdir/agent-stats-link" ] && [ -S "$fx/outside/stale-out" ] && [ -L "$tdir/agent-stats-dangling" ] && [ -L "$tdir/agent-stats-livelink" ] && [ -S "$fx/outside/live-out" ]; } \
    && test_pass "symlinks (to dead, live and missing targets) and their targets are untouched" \
    || test_fail "symlinks and their targets are untouched"
{ [ -S "$tmuxdir/sibling-stale" ] && [ -S "$tmuxdir/tmux-$other_uid/other-uid-stale" ]; } \
    && test_pass "dead sockets outside DIR (parent, other uid's directory) are untouched" \
    || test_fail "dead sockets outside DIR are untouched"

before="$(listing "$tdir")"
run_prune "$tdir"
if [ "$pr_rc" -eq 0 ] && [ "$(listing "$tdir")" = "$before" ] && [ "$pr_err" = "" ] && [ "$pr_out" = "" ]; then
    test_pass "a second prune changes nothing and prints nothing"
else
    test_fail "a second prune changes nothing and prints nothing (rc $pr_rc, err: $pr_err)"
fi

absent="$fx/none/workspace/tmux/tmux-$uid"
run_prune "$absent"
if [ "$pr_rc" -eq 0 ] && [ ! -e "$fx/none" ] && [ "$pr_out$pr_err" = "" ]; then
    test_pass "an absent directory is fine: nothing created, nothing printed"
else
    test_fail "an absent directory is fine (rc $pr_rc, out/err: $pr_out$pr_err)"
fi

# --- refusals, with recording stubs first on PATH (incident rule) -----------
stubs="$fx/stubs"; mkdir -p "$stubs"
for t in rm find unlink mv chmod chown rmdir rsync; do
    printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/stub.log"\nexit 0\n' "$t" "$fx" > "$stubs/$t"
    chmod +x "$stubs/$t"
done
: > "$fx/stub.log"
mkdir -p "$fx/linkroot/workspace/tmux" "$fx/outside-dir" "$fx/fileroot/workspace/tmux"
mk_stale "$fx/outside-dir" victim
ln -s "$fx/outside-dir" "$fx/linkroot/workspace/tmux/tmux-$uid"
: > "$fx/fileroot/workspace/tmux/tmux-$uid"
refuse_case() {
    # $1 = label, $2 = dir. Real rm & friends are replaced by recording stubs.
    pr_rc=0
    (
        cd "$fx/cwd"
        PATH="$stubs:$PATH"
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
        source "$LIB"
        "$FN" "$2"
    ) > "$fx/pr.out" 2> "$fx/pr.err" || pr_rc=$?
    if [ "$pr_rc" -eq 1 ] && grep -qF "refusing to prune" "$fx/pr.err" && [ ! -s "$fx/stub.log" ] && [ ! -s "$fx/pr.out" ]; then
        test_pass "refuses $1 without touching anything"
    else
        test_fail "refuses $1 (rc $pr_rc, err: $(cat "$fx/pr.err"), stub calls: $(cat "$fx/stub.log"))"
    fi
}
refuse_case "an empty path" ""
refuse_case "a relative path" "workspace/tmux/tmux-$uid"
refuse_case "a relative path with the right tail" "r/workspace/tmux/tmux-$uid"
refuse_case "root" "/"
refuse_case "the current directory" "."
refuse_case "the parent directory" ".."
refuse_case "a fixture home" "$fx/home"
refuse_case "tmux's parent directory" "$tmuxdir"
refuse_case "another uid's directory" "$tmuxdir/tmux-$other_uid"
refuse_case "a non-numeric tmux-name" "$tmuxdir/tmux-abc"
refuse_case "a bare tmux- name" "$tmuxdir/tmux-"
refuse_case "a uid with a suffix" "$tmuxdir/tmux-${uid}x"
refuse_case "a trailing slash" "$tdir/"
refuse_case "a subdirectory of the tmux dir" "$tdir/agent-stats-dir"
refuse_case "a wrong parent shape" "$root/workspacex/tmux/tmux-$uid"
refuse_case "a .. component" "$root/x/../workspace/tmux/tmux-$uid"
refuse_case "a . component" "$root/./workspace/tmux/tmux-$uid"
refuse_case "a symlinked directory" "$fx/linkroot/workspace/tmux/tmux-$uid"
refuse_case "a regular file in place of the directory" "$fx/fileroot/workspace/tmux/tmux-$uid"
[ -S "$fx/outside-dir/victim" ] && [ -f "$fx/fileroot/workspace/tmux/tmux-$uid" ] \
    && test_pass "the symlink target's and the file's content survive the refusals" \
    || test_fail "the symlink target's and the file's content survive the refusals"

# --- failure to remove is an error status, not a crash -----------------------
ro="$fx/ro"; rodir="$ro/workspace/tmux/tmux-$uid"
mkdir -p "$rodir"; mk_stale "$rodir" gone
failrm="$fx/failrm"; mkdir -p "$failrm"
for t in rm unlink find; do printf '#!/bin/bash\nexit 1\n' > "$failrm/$t"; chmod +x "$failrm/$t"; done
pr_rc=0
(
    cd "$fx/cwd"; PATH="$failrm:$PATH"
    # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
    source "$LIB"
    "$FN" "$rodir"
) > "$fx/pr.out" 2> "$fx/pr.err" || pr_rc=$?
if [ "$pr_rc" -eq 1 ] && grep -qF "Error:" "$fx/pr.err" && [ -S "$rodir/gone" ]; then
    test_pass "a dead socket that cannot be removed gives status 1 and an Error line"
else
    test_fail "a dead socket that cannot be removed gives status 1 and an Error line (rc $pr_rc, err: $(cat "$fx/pr.err"))"
fi

# --- wiring into serve ---------------------------------------------------------
release="$fx/store/rel"; mkdir -p "$release/bin"
cat > "$release/bin/agent-stats-rust" <<'PKG'
#!/bin/bash
{
    printf 'exe=%s\n' "${0##*/}"
    printf 'tmux=%s\n' "${TMUX_TMPDIR:-}"
    printf 'seen=%s\n' "$(cd "$TMUX_TMPDIR/tmux-$(id -u)" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' '|')"
} >> "$US_LOG"
PKG
chmod +x "$release/bin/agent-stats-rust"
export US_LOG="$fx/log"
export HOME="$fx/home"
ai_state="$fx/ai-state"; mkdir -p "$ai_state"
us_serve() {
    : > "$US_LOG"
    (
        source "$GUEST_SCRIPTS/lib/dx-keyring.sh"
        # shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-usage-service.sh
        source "$LIB"
        dx_keyring_start() { return 0; }
        dx_keyring_read_address() { printf 'unix:path=%s/bus\n' "$fx"; }
        us_sleep() { :; }
        export DX_USAGE_SLEEP=us_sleep DX_USAGE_SERVICE_ROOT="$1" DX_AI_STATE_ROOT="$ai_state" DX_KEYRING_ADDRESS_FILE="$fx/keyring-address"
        dx_usage_service_serve
    ) > "$fx/serve.out" 2>&1
}

sroot="$fx/s"; sdir="$sroot/workspace/tmux/tmux-$uid"
mkdir -p "$sdir"; ln -s "$release" "$sroot/current"
mk_stale "$sdir" agent-stats-dead
mk_live "$sdir" agent-stats-alive
: > "$sdir/keep.txt"
us_serve "$sroot" && s_rc=0 || s_rc=$?
if [ "$s_rc" -eq 0 ] && grep -qx 'seen=agent-stats-alive|keep.txt|' "$US_LOG" && grep -qx "tmux=$sroot/workspace/tmux" "$US_LOG"; then
    test_pass "serve prunes dead sockets before it execs the package (live socket and file kept)"
else
    test_fail "serve prunes dead sockets before exec (rc $s_rc, log: $(cat "$US_LOG"), out: $(cat "$fx/serve.out"))"
fi
! grep -qF "could not prune" "$fx/serve.out" && test_pass "a successful prune raises no warning" || test_fail "a successful prune raises no warning"

# no tmux directory yet: starts quietly
nroot="$fx/n"; mkdir -p "$nroot"; ln -s "$release" "$nroot/current"
us_serve "$nroot" && s_rc=0 || s_rc=$?
if [ "$s_rc" -eq 0 ] && grep -qx 'exe=agent-stats-rust' "$US_LOG" && ! grep -qF "could not prune" "$fx/serve.out" && [ ! -e "$nroot/workspace/tmux/tmux-$uid" ]; then
    test_pass "serve without a tmux-<uid> directory starts without warning and creates none"
else
    test_fail "serve without a tmux-<uid> directory starts quietly (rc $s_rc, out: $(cat "$fx/serve.out"))"
fi

# prune refuses (a file where the directory should be): warning, service up
wroot="$fx/w"; mkdir -p "$wroot/workspace/tmux"; ln -s "$release" "$wroot/current"
: > "$wroot/workspace/tmux/tmux-$uid"
us_serve "$wroot" && s_rc=0 || s_rc=$?
if [ "$s_rc" -eq 0 ] && grep -qx 'exe=agent-stats-rust' "$US_LOG" && grep -qF "Warning: could not prune stale tmux sockets" "$fx/serve.out"; then
    test_pass "a prune failure is only a warning: the service still starts"
else
    test_fail "a prune failure is only a warning (rc $s_rc, log: $(cat "$US_LOG"), out: $(cat "$fx/serve.out"))"
fi

reap_live
print_summary
exit_with_code
