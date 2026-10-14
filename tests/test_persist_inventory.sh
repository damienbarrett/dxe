#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.3 (plans/do plan.md D-6, D-8, D-10 as revised 2026-10-11 and clarified
# 2026-10-11 after the WP6.2 verifier, finding A; spec R37, R31, spec section 6
# step 1): acceptance tests for `dx-persist-inventory`, the pre-migration
# inventory. Written before the command exists; the implementer builds exactly
# this contract. Amended by WP6.2b: the read-only inventory container pins
# `--user 0:0` and `--pull never`, and the rsync check (WP6.2's
# dx_runtime_host_rsync_check, unchanged here) now runs rsync from the guest's
# nix volume after a DQ6 check of that volume (tests/test_persist_rsync_ops.sh
# pins it), so a complete run makes four docker calls.
#
# Interface contract (every name, argv, line and exit code below is pinned):
#
#  1. The command. bin/dx-persist-inventory is a thin wrapper (the usual
#     `if [ "${BASH_SOURCE[0]}" = "$0" ]; then dx_persist_inventory_main "$@"; fi`
#     shape; executable, 100755) over dx_persist_inventory_main, defined in
#     bin/lib/dx-persist-dir.sh (kcov scope). Guest/profile selection is the
#     established one of the sibling dx-* commands: the resolved configuration
#     (DX_CONTAINER_NAME, DX_PERSIST_VOLUME, DX_PERSIST_HOST_ROOT, DX_IMAGE,
#     DX_RUNTIME, DX_REMOTE_HOST ...) from the environment / .env /
#     `bin/dx-profile NAME bin/dx-persist-inventory`. There are no positional
#     arguments. `-h` / `--help`: usage on stdout ("Usage: dx-persist-inventory"),
#     exit 0, no runtime call. Any other argument: "Usage:" on stderr, exit 2,
#     nothing on stdout, no runtime call.
#
#  2. Exit codes.
#       0  the report is complete and nothing blocks the migration;
#       1  a refusal or a failed read: exactly ONE line of stderr starts with
#          "Error:", and NOTHING is on stdout (no partial report);
#       2  usage;
#       3  the report is complete (printed in full on stdout, stderr empty) but
#          a blocker is named in it: rsync_check is "refused", or
#          target_room / rollback_room is "no".
#     Refusals (exit 1), each before any container is started where it can be:
#       - DX_RUNTIME is not docker-ssh: the Error names "DX_RUNTIME=docker-ssh";
#         NO tool is called;
#       - DX_PERSIST_HOST_ROOT is empty: the Error names "DX_PERSIST_HOST_ROOT";
#         no call;
#       - the DQ6 ownership check on DX_PERSIST_VOLUME fails (another
#         profile's volume, another role, an absent volume): the existing
#         `refusing to ...` wording is the Error line; the only docker call is
#         the `volume inspect`, so no `run` was made;
#       - the volume read fails (container non-zero, or its output lacks
#         `status=ok`, or lacks/garbles a required key), or the share root's
#         df fails: one Error line, no report.
#     NOT a refusal: the guest's NIX volume (DX_NIX_VOLUME, where rsync comes
#     from) failing its DQ6 check inside rsync_check (another profile's, another
#     role, absent), or rsync missing from it (the run exits 127). Those make
#     rsync_check "refused" -- a blocker, exit 3, the complete report -- with
#     the adapter's Error line in it ("refusing to run rsync from volume
#     '<DX_NIX_VOLUME>'..." / "... boot the guest once ... include rsync"),
#     and no rsync `run` for a DQ6 failure.
#
#  3. Stdout on exit 0 or 3: exactly these `key: value` lines in this order (the
#     separator is a colon and one space; list entries repeat their key):
#       volume: <DX_PERSIST_VOLUME>
#       size_kb: <N>                    kibibytes on disk of the volume (du -sk)
#       entries: <N>                    every path below the volume root
#       hard_links: <N>                 non-directory paths whose link count > 1
#       appledouble_count: <N>
#       appledouble: <relative path>    one line per ._* path, or "appledouble: none"
#       special_count: <N>              sockets, FIFOs, block and character devices
#       special: <relative path>        one line per path, or "special: none"
#       acls: present|none|unknown      (count > 0 / 0 / tool missing)
#       xattrs: present|none|unknown
#       rsync_version: <N.N.N>|unknown  unknown whenever rsync_check is refused
#       rsync_check: ok   |   rsync_check: refused: <the adapter's Error line minus "Error: ">
#                                       (the line of rsync_check's stderr that
#                                       starts "Error:"; any other stderr, e.g.
#                                       docker's own, is dropped, and the
#                                       command's stderr stays empty)
#       target_root: <DX_PERSIST_HOST_ROOT exactly as configured>
#       target_free_kb: <N>             free space of the share root's filesystem
#       target_room: yes|no             yes iff target_free_kb >= size_kb
#       rollback_free_kb: <N>           free space of the Docker volume pool
#       rollback_room: yes|no           yes iff rollback_free_kb >= size_kb
#     rsync_check runs after the volume read: `dx_runtime_host_rsync_check`
#     with -A iff acls is not "none" and -X iff xattrs is not "none" ("unknown"
#     counts as needed), so a missing ACL/xattr capability is a blocker only
#     when the volume needs it. Relative paths have no leading "./" or "/".
#     Paths come out in the order the container printed them. Names
#     containing a newline are outside this contract for the path lists (one
#     path per line), but every COUNT (entries, hard_links, appledouble_count,
#     special_count) counts them correctly.
#
#  4. Order and transcript. Docker calls in a complete run, exactly four, in
#     this order (a fake docker records every argv word, NUL-separated; <SCRIPT>
#     stands for the one multi-line word after -c; <NIX> is DX_NIX_VOLUME,
#     dx-fix-nix here):
#       1. volume inspect ... <VOLUME>             (the DQ6 check; first)
#       2. run --rm --network none --user 0:0 --pull never -v <VOLUME>:/v:ro
#              --entrypoint sh <IMAGE> -c <SCRIPT> sh /v
#                                                  (the one read-only container)
#       3. volume inspect ... <NIX>                (rsync_check's DQ6 check of
#                                                  the guest's nix volume)
#       4. run --rm --network none --user 0:0 --pull never -v <NIX>:/nix:ro
#              --entrypoint /nix/var/nix/profiles/per-user/root/profile/bin/rsync
#              <IMAGE> --version                   (rsync_check, WP6.2b)
#     plus exactly ONE NAS shell call (ssh), the share root's `df` (see 5b). No
#     NAS shell command or container writes anything: no mkdir, rm, mv, chmod,
#     chown, touch, tee, cp, ln, no redirection to a file, no --mount, no
#     writable bind (every -v ends in :ro). Nothing is created under the share
#     root or the controller's state directory (no D-7 record).
#
#  5. Two new neutral runtime operations, declared in bin/lib/dx-runtime.sh with
#       dx_runtime_volume_inventory()  { dx_runtime_dispatch volume_inventory "$@"; }
#       dx_runtime_host_dir_free()     { dx_runtime_dispatch host_dir_free "$@"; }
#     and implemented as dx_runtime_{docker,apple}_<op>. Apple: nothing on
#     stdout, "unsupported" on stderr, non-zero, NO tool call. (The command
#     itself never reaches the adapter on Apple: it refuses first, see 2.)
#     5a. dx_runtime_volume_inventory VOLUME (exactly one argument, else a
#         "Usage:" line on stderr, non-zero, no call): DQ6 check first with
#         `dx_runtime_docker_volume_owned VOLUME inventory` (a failure is
#         returned as is, and no `run` is made), then the ONE run of 4.2 through
#         dx_runtime_docker_cli. The container's stdout/stderr pass through
#         and its exit status is returned unchanged.
#         The container script is POSIX sh, reads the volume root from "$1"
#         (the mount, /v), contains no write verb and no redirection except to
#         /dev/null or &N (so no `>` comparison either), and prints tagged
#         `key=value` lines:
#           df_total_kb=N  df_avail_kb=N      `df -P -k "$1"` of the volume's pool (KiB)
#           size_kb=N                         `du -sk "$1"`
#           entries=N      hardlinks=N        as in 3
#           appledouble=N  then apple=<path>  one line per ._* path (find -name '._*'),
#                                             relative to "$1", bytewise sorted (LC_ALL=C)
#           special=N      then special_path=<path>   (sockets, FIFOs, devices), sorted
#           acl=N|unknown  xattr=N|unknown    N = number of "# file:" headers of
#                                             `getfacl -R -s -p "$1"` /
#                                             `getfattr -R -h -d -m - "$1"`;
#                                             "unknown" when the tool is missing
#           status=ok                         LAST line, printed only when every
#                                             measurement succeeded; a failing
#                                             find/du/df makes the script exit
#                                             non-zero WITHOUT status=ok (never
#                                             a partial number)
#         The host treats rc != 0, a missing status=ok, or a missing /
#         non-numeric size_kb, entries, hardlinks, appledouble, special,
#         df_avail_kb (acl/xattr may be N or unknown) as a failed read.
#     5b. dx_runtime_host_dir_free ROOT: one ssh call through
#         dx_runtime_docker_ssh_exec running `sh -c <constant single-line SCRIPT>
#         sh ROOT` (ROOT is only a data word); the script runs `df -P -k -- "$1"`
#         (any -k spelling; ROOT its last word; read-only). Stdout, exactly:
#             fs=<Filesystem column>
#             total_kb=<N>
#             avail_kb=<N>
#         A failing df: non-zero, nothing on stdout. ROOT empty or "-": refused
#         host-side, non-zero, no ssh call.
#
#  6. WP6.3b -- the container script runs on the BARE image. On docker-ssh
#     $DX_IMAGE is the bare nixos/nix base: it has sh and the coreutils/
#     findutils/grep commands, and NO sed, NO awk (found on the live NAS, 2026-10-12).
#     Every execution of the extracted script below therefore runs with
#     PATH restricted to a temp dir of symlinks to exactly this allowed set:
#         sh df du find grep sort head tail cat printf wc tr cut ls stat mktemp cksum
#     (df is a POSIX-sh stub of the same table the fake df prints; getfacl and
#     getfattr appear only as sh stubs when a case adds them). NO sed, NO awk, NO
#     perl, NO other tool. The script must get by with those, so a sed/awk call in it
#     makes the real-tree cases fail (sed/awk are verified absent first).
#
#  The fake `df` used below prints 1024-blocks when it is given a -k option and
#  512-blocks (twice the numbers) when it is not, like a Mac's `df -P`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "WP6.3: persist inventory (R37)"

SCRATCH="$(persist_fixture_root_create)"
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT

eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
ne() { # LABEL UNEXPECTED ACTUAL
    if [ "$2" != "$3" ]; then test_pass "$1"; else test_fail "$1 (got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
hasline() { # LABEL TEXT LINE (whole line)
    if grep -Fqx -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no line [$3] in [$2])"; fi
}
nonzero() { # LABEL STATUS
    if [ "$2" != 0 ]; then test_pass "$1"; else test_fail "$1 (status 0)"; fi
}
have_fn() { type "$1" >/dev/null 2>&1; }
count_prefix() { # TEXT PREFIX: number of lines starting with PREFIX
    awk -v p="$2" 'index($0, p) == 1 { n++ } END { print n + 0 }' <<<"$1"
}
tree_sig() { # DIR: path, mode, size, mtime, nlink of every entry (lstat), sorted
    perl -e 'use File::Find; find({ no_chdir => 1, wanted => sub { my @s = lstat($_); print "$File::Find::name $s[2] $s[7] $s[9] $s[3]\n" } }, $ARGV[0]);' "$1" | sort
}

# --- recording fakes ----------------------------------------------------------
ROOT="$SCRATCH/dxe-nas-root"
mkdir "$ROOT"
mkdir "$SCRATCH/home"
TOOLS="$(persist_fixture_nas_create "$ROOT" "$SCRATCH")"
# docker: records every argv word NUL-separated in calls/N; `volume inspect`
# answers from labels/<name>; `run` answers from run-<entrypoint>.out/.err/.rc,
# <entrypoint> being the entrypoint's last path component (sh, rsync).
fake_tool_write "$TOOLS" docker 'd="${FAKE_DOCKER_DIR:?}"
mkdir -p "$d/calls"
n=$(( $(ls "$d/calls" | wc -l) + 1 ))
printf "%s\0" "$@" > "$d/calls/$n"
case "$1" in
    volume)
        if [ "$2" = inspect ]; then
            for a in "$@"; do name="$a"; done
            if [ -f "$d/labels/$name" ]; then cat "$d/labels/$name"; exit 0; fi
            echo "Error: No such volume: $name" >&2
            exit 1
        fi
        ;;
    run)
        ep=""; prev=""
        for a in "$@"; do if [ "$prev" = --entrypoint ]; then ep="${a##*/}"; fi; prev="$a"; done
        if [ -f "$d/run-$ep.out" ]; then cat "$d/run-$ep.out"; fi
        if [ -f "$d/run-$ep.err" ]; then cat "$d/run-$ep.err" >&2; fi
        rc=0
        if [ -f "$d/run-$ep.rc" ]; then rc="$(cat "$d/run-$ep.rc")"; fi
        exit "$rc"
        ;;
    info) echo /var/lib/docker; exit 0 ;;
    version) echo 24.0.0; exit 0 ;;
esac
echo "fake docker: unexpected call: $*" >&2
exit 98'
# df: logs every call (a "call" line, then one argv word per line), prints a
# one-row POSIX table: 1024-blocks with -k, 512-blocks (doubled) without.
fake_tool_write "$TOOLS" df 'log="${DF_LOG:?}"
{ echo call; printf "%s\n" "$@"; } >> "$log"
if [ -f "${DF_RC_FILE:-/nonexistent}" ]; then echo "df: fake failure" >&2; exit "$(cat "$DF_RC_FILE")"; fi
k=1
for a in "$@"; do
    case "$a" in -*k*) k=0 ;; esac
done
m=1; [ "$k" = 1 ] && m=2
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fakeshare $(( 1000000 * m )) $(( 400000 * m )) $(( ${DF_AVAIL:-600000} * m )) 40% /share"'
fake_tool_write "$TOOLS" container 'echo "$*" >> "${APPLE_LOG:?}"; exit 99'
PATH="$TOOLS:$PATH"
export PATH
export DXE_RUNTIME_DOCKER_BIN="$TOOLS/docker"
export HOME="$SCRATCH/home" XDG_STATE_HOME="$SCRATCH/state"
export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
export DX_CONTAINER_NAME=dx-fix DX_GUEST_SYSTEM=x86_64-linux
export DX_IMAGE=dxe-inv-image:7
export DX_PERSIST_VOLUME=dx-fix-persist
export DX_NIX_VOLUME=dx-fix-nix
export DX_PERSIST_HOST_ROOT="$ROOT"
export DX_NIX_STORAGE_MODE=direct-volume
unset DXE_FAKE_SSH_REMOTE_PATH DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION

PROFILE="${PERSIST_FIXTURE_NAS_HOST}__dx-fix"
OWN_LABELS="true|1|$PROFILE|persist|x86_64-linux"
NIX_LABELS="true|1|$PROFILE|nix|x86_64-linux"
export DF_LOG="$SCRATCH/df.log" DXE_FAKE_SSH_ARGV_LOG="$SCRATCH/ssh.log" APPLE_LOG="$SCRATCH/apple.log"

new_case() { # fresh recording area, owned persist and nix volumes, df ok with 600000 free
    FAKE_DOCKER_DIR="$(mktemp -d "$SCRATCH/dxe-fake-docker.XXXXXX")"
    export FAKE_DOCKER_DIR
    mkdir "$FAKE_DOCKER_DIR/calls" "$FAKE_DOCKER_DIR/labels"
    printf '%s\n' "$OWN_LABELS" >"$FAKE_DOCKER_DIR/labels/dx-fix-persist"
    printf '%s\n' "$NIX_LABELS" >"$FAKE_DOCKER_DIR/labels/dx-fix-nix"
    : >"$DF_LOG"
    : >"$DXE_FAKE_SSH_ARGV_LOG"
    : >"$APPLE_LOG"
    rm -f "$SCRATCH/df.rc"
    unset DF_RC_FILE
    export DF_AVAIL=600000
    RUN_PRE=""
}
set_labels() { printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/labels/$1"; }
put() { # NAME CONTENT: a canned file in the fake docker area (newline-terminated)
    printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/$1"
}
ncalls() { ls "$FAKE_DOCKER_DIR/calls" | wc -l | tr -d ' '; }
kind_of() {
    if [ ! -f "$FAKE_DOCKER_DIR/calls/$1" ]; then printf '<no call %s>' "$1"; return 0; fi
    perl -0777 -e 'my $s = <STDIN>; my @w = split /\0/, $s, -1; print $w[0];' <"$FAKE_DOCKER_DIR/calls/$1"
}
last_word_of() { # N -> the last argv word of call N
    if [ ! -f "$FAKE_DOCKER_DIR/calls/$1" ]; then printf '<no call %s>' "$1"; return 0; fi
    perl -0777 -e 'my $s = <STDIN>; my @w = split /\0/, $s, -1; pop @w if @w && $w[-1] eq ""; print $w[-1];' <"$FAKE_DOCKER_DIR/calls/$1"
}
call_of() { # N -> <word><word>..., the word after -c shown as SCRIPT
    if [ ! -f "$FAKE_DOCKER_DIR/calls/$1" ]; then printf '<no call %s>\n' "$1"; return 0; fi
    perl -0777 -e 'my $s = <STDIN>; my @w = split /\0/, $s, -1; pop @w if @w && $w[-1] eq "";
        my $o = ""; for my $i (0 .. $#w) { my $x = $w[$i]; $x = "SCRIPT" if $i > 0 && $w[$i-1] eq "-c"; $o .= "<$x>"; }
        print "$o\n";' <"$FAKE_DOCKER_DIR/calls/$1"
}
script_of() { # N -> the word after -c, byte-exact
    perl -0777 -e 'my $s = <STDIN>; my @w = split /\0/, $s, -1; for my $i (1 .. $#w) { if ($w[$i-1] eq "-c") { print $w[$i]; last } }' <"$FAKE_DOCKER_DIR/calls/$1"
}
nruns() {
    local n=0 i=1 total
    total="$(ncalls)"
    while [ "$i" -le "$total" ]; do
        if [ "$(kind_of "$i")" = run ]; then n=$((n + 1)); fi
        i=$((i + 1))
    done
    printf '%s' "$n"
}
ssh_calls() { grep -Fxc BatchMode=yes "$DXE_FAKE_SSH_ARGV_LOG" || true; }
df_calls() { grep -Fxc call "$DF_LOG" || true; }

# Canned `rsync --version` outputs.
caps_of() { # VERSION CAPS
    printf 'rsync  version %s  protocol version 31\nCopyright (C) 1996-2024 by Andrew Tridgell, Wayne Davison, and others.\n\nCapabilities:\n    %s\nOptimizations:\n    SIMD-roll, no asm-roll\n\nrsync comes with ABSOLUTELY NO WARRANTY.\n' "$1" "$2"
}
CAPS_FULL='64-bit files, socketpairs, symlinks, symtimes, hardlinks, hardlink-specials, hardlink-symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, prealloc'
V_330="$(caps_of 3.3.0 "$CAPS_FULL")"
V_307="$(caps_of 3.0.7 'hardlinks, symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, symtimes, prealloc')"
V_NOACL="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, no ACLs, xattrs')"
V_NOXATTR="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, ACLs, no xattrs')"

# Canned container output (the tagged lines of contract 5a).
INV_STD="$(cat <<'EOF'
df_total_kb=2000000
df_avail_kb=900000
size_kb=51200
entries=1234
hardlinks=7
appledouble=3
apple=._root-meta
apple=dir with space/._x
apple=nested/a/._deep-meta
special=2
special_path=special/fifo
special_path=special/sock
acl=0
xattr=0
status=ok
EOF
)"
inv_variant() { # SED-EXPRESSION: INV_STD with edits
    printf '%s\n' "$INV_STD" | sed "$1"
}

# --- running the command in process / as a wrapper -------------------------------
INV_OUT="" INV_ERR="" INV_RC=0 RUN_PRE=""
run_main() { # ARGS...: dx_persist_inventory_main in a subshell that sourced dx-lib.sh
    INV_OUT="$( (
        eval "$RUN_PRE"
        # shellcheck source=../bin/dx-lib.sh
        source "$BASE_DIR/bin/dx-lib.sh" || exit 96
        if ! type dx_persist_inventory_main >/dev/null 2>&1; then echo "dx_persist_inventory_main is not defined" >&2; exit 97; fi
        dx_persist_inventory_main "$@"
    ) 2>"$SCRATCH/inv.err")"
    INV_RC=$?
    INV_ERR="$(cat "$SCRATCH/inv.err")"
}
WRAPPER="$BASE_DIR/bin/dx-persist-inventory"
run_wrapper() { # ARGS...
    INV_OUT="$(bash "$WRAPPER" "$@" 2>"$SCRATCH/inv.err")"
    INV_RC=$?
    INV_ERR="$(cat "$SCRATCH/inv.err")"
}
errlines() { count_prefix "$INV_ERR" "Error:"; }

# Docker argv for the two runs of a complete inventory.
INV_RUN_ARGV="<run><--rm><--network><none><--user><0:0><--pull><never><-v><dx-fix-persist:/v:ro><--entrypoint><sh><dxe-inv-image:7><-c><SCRIPT><sh></v>"
RSYNC_RUN_ARGV="<run><--rm><--network><none><--user><0:0><--pull><never><-v><dx-fix-nix:/nix:ro><--entrypoint></nix/var/nix/profiles/per-user/root/profile/bin/rsync><dxe-inv-image:7><--version>"

expected_report() { # SIZE ENTRIES HL TARGET_FREE ROLLBACK_FREE -- the standard dataset
    printf '%s\n' \
        "volume: dx-fix-persist" \
        "size_kb: $1" \
        "entries: $2" \
        "hard_links: $3" \
        "appledouble_count: 3" \
        "appledouble: ._root-meta" \
        "appledouble: dir with space/._x" \
        "appledouble: nested/a/._deep-meta" \
        "special_count: 2" \
        "special: special/fifo" \
        "special: special/sock" \
        "acls: none" \
        "xattrs: none" \
        "rsync_version: 3.3.0" \
        "rsync_check: ok" \
        "target_root: $ROOT" \
        "target_free_kb: $4" \
        "target_room: yes" \
        "rollback_free_kb: $5" \
        "rollback_room: yes"
}
STD_REPORT="$(expected_report 51200 1234 7 600000 900000)"

# =============================================================================
test_section "WP6.3: the neutral operations exist"
for fn in dx_runtime_volume_inventory dx_runtime_host_dir_free dx_runtime_docker_volume_inventory dx_runtime_docker_host_dir_free dx_runtime_apple_volume_inventory dx_runtime_apple_host_dir_free; do
    if have_fn "$fn"; then test_pass "$fn is defined"; else test_fail "$fn is defined"; fi
done

# =============================================================================
test_section "WP6.3: dx_runtime_volume_inventory (docker-ssh)"
if have_fn dx_runtime_volume_inventory; then
    new_case
    put run-sh.out "$INV_STD"
    out="$(dx_runtime_volume_inventory dx-fix-persist 2>"$SCRATCH/op.err")"
    rc=$?
    eq "inventory op: status 0" "0" "$rc"
    eq "inventory op: the container's stdout passes through unchanged" "$INV_STD" "$out"
    eq "inventory op: exactly two docker calls (inspect, then run)" "2" "$(ncalls)"
    eq "inventory op: the first call is the DQ6 volume inspect" "volume" "$(kind_of 1)"
    eq "inventory op: the exact run argv (read-only mount, no network, no other mount)" "$INV_RUN_ARGV" "$(call_of 2)"
    eq "inventory op: one ssh call per docker call" "2" "$(ssh_calls)"

    new_case
    put run-sh.out "partial=1"
    put run-sh.err "boom"
    put run-sh.rc 3
    out="$(dx_runtime_volume_inventory dx-fix-persist 2>"$SCRATCH/op.err")"
    rc=$?
    eq "inventory op: the container's exit status is returned unchanged" "3" "$rc"
    has "inventory op: the container's stderr passes through" "$(cat "$SCRATCH/op.err")" "boom"

    # DQ6 refusals: no run at all.
    inv_refused() { # LABEL EXPECTED-WORD ARGS...
        local label="$1" word="$2"
        shift 2
        out="$(dx_runtime_volume_inventory "$@" 2>"$SCRATCH/op.err")"
        rc=$?
        nonzero "$label: refused" "$rc"
        eq "$label: nothing on stdout" "" "$out"
        has "$label: the reason" "$(cat "$SCRATCH/op.err")" "$word"
        eq "$label: no docker run" "0" "$(nruns)"
    }
    new_case
    set_labels dx-fix-persist "true|1|other-host__other-guest|persist|x86_64-linux"
    inv_refused "another profile's volume" "refusing" dx-fix-persist
    new_case
    set_labels dx-fix-persist "true|1|$PROFILE|nix|x86_64-linux"
    inv_refused "a volume carrying another role" "refusing" dx-fix-persist
    new_case
    rm -f "$FAKE_DOCKER_DIR/labels/dx-fix-persist"
    inv_refused "an absent volume" "does not exist" dx-fix-persist
    new_case
    set_labels other-volume "$OWN_LABELS"
    inv_refused "an unconfigured volume name" "refusing" other-volume
    new_case
    inv_refused "no argument" "Usage:"
    eq "no argument: no docker call at all" "0" "$(ncalls)"
    inv_refused "two arguments" "Usage:" dx-fix-persist extra
    eq "two arguments: no docker call at all" "0" "$(ncalls)"
fi

# =============================================================================
test_section "WP6.3: dx_runtime_host_dir_free (docker-ssh)"
if have_fn dx_runtime_host_dir_free; then
    new_case
    out="$(dx_runtime_host_dir_free "$ROOT" 2>"$SCRATCH/op.err")"
    rc=$?
    eq "free op: status 0" "0" "$rc"
    eq "free op: exactly the three fact lines (1024-blocks, so -k was passed)" "fs=/dev/fakeshare
total_kb=1000000
avail_kb=600000" "$out"
    eq "free op: one ssh call" "1" "$(ssh_calls)"
    eq "free op: no docker call" "0" "$(ncalls)"
    eq "free op: df ran once" "1" "$(df_calls)"
    eq "free op: ROOT is df's last word, as one word" "$ROOT" "$(tail -n 1 "$DF_LOG")"
    has "free op: df -P is used" "$(cat "$DF_LOG")" "-P"
    export PWNED="$SCRATCH/pwned"
    SPACED="$SCRATCH/dxe odd dir\$(touch \"\$PWNED\")'q\"x"
    new_case
    out="$(dx_runtime_host_dir_free "$SPACED" 2>"$SCRATCH/op.err")"
    rc=$?
    eq "free op: a path with spaces, quotes and a substitution: status 0" "0" "$rc"
    eq "free op: it reaches df as one word" "$SPACED" "$(tail -n 1 "$DF_LOG")"
    if [ -e "$PWNED" ]; then test_fail "free op: the substitution in a path was not executed"; else test_pass "free op: the substitution in a path was not executed"; fi

    new_case
    echo 1 >"$SCRATCH/df.rc"
    export DF_RC_FILE="$SCRATCH/df.rc"
    out="$(dx_runtime_host_dir_free "$ROOT" 2>"$SCRATCH/op.err")"
    rc=$?
    nonzero "free op: a failing df is a failure" "$rc"
    eq "free op: a failing df prints nothing on stdout" "" "$out"
    unset DF_RC_FILE

    new_case
    for bad in "" "-"; do
        out="$(dx_runtime_host_dir_free "$bad" 2>"$SCRATCH/op.err")"
        rc=$?
        nonzero "free op: ROOT [$bad] is refused" "$rc"
        eq "free op: ROOT [$bad]: nothing on stdout" "" "$out"
    done
    eq "free op: degenerate roots make no ssh call" "0" "$(ssh_calls)"
fi

# =============================================================================
test_section "WP6.3: the operations under apple are unsupported and call nothing"
if have_fn dx_runtime_volume_inventory && have_fn dx_runtime_host_dir_free; then
    new_case
    for opcall in "dx_runtime_volume_inventory dx-fix-persist" "dx_runtime_host_dir_free $ROOT"; do
        # shellcheck disable=SC2086  # opcall is "function arg"
        out="$( (export DX_RUNTIME=apple DX_REMOTE_HOST=; $opcall) 2>"$SCRATCH/op.err")"
        rc=$?
        nonzero "apple: ${opcall%% *} is non-zero" "$rc"
        eq "apple: ${opcall%% *}: nothing on stdout" "" "$out"
        has "apple: ${opcall%% *}: says unsupported" "$(cat "$SCRATCH/op.err")" "unsupported"
    done
    eq "apple: no container call" "" "$(cat "$APPLE_LOG")"
    eq "apple: no ssh call" "0" "$(ssh_calls)"
    eq "apple: no docker call" "0" "$(ncalls)"
fi

# =============================================================================
test_section "WP6.3: the command, a complete inventory"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
find "$ROOT" | sort >"$SCRATCH/root.before"
run_main
eq "complete: exit 0" "0" "$INV_RC"
eq "complete: stderr is empty" "" "$INV_ERR"
eq "complete: the exact report" "$STD_REPORT" "$INV_OUT"
eq "complete: exactly four docker calls" "4" "$(ncalls)"
eq "complete: call 1 is the DQ6 volume inspect (before any container)" "volume" "$(kind_of 1)"
eq "complete: call 1 inspects the guest's persist volume" "dx-fix-persist" "$(last_word_of 1)"
eq "complete: call 2 is the read-only volume container (--user 0:0, --pull never)" "$INV_RUN_ARGV" "$(call_of 2)"
case "$(call_of 3)" in
    "<volume><inspect>"*) test_pass "complete: call 3 is the nix volume's DQ6 inspect (rsync_check, before its run)" ;;
    *) test_fail "complete: call 3 is the nix volume's DQ6 inspect (rsync_check, before its run) ($(call_of 3))" ;;
esac
eq "complete: call 3 inspects the configured nix volume" "dx-fix-nix" "$(last_word_of 3)"
eq "complete: call 4 is the rsync version check from the guest's nix volume" "$RSYNC_RUN_ARGV" "$(call_of 4)"
eq "complete: exactly one NAS shell call (the df), besides four docker calls" "5" "$(ssh_calls)"
eq "complete: df ran once" "1" "$(df_calls)"
eq "complete: df's last word is the configured share root" "$ROOT" "$(tail -n 1 "$DF_LOG")"

# no write: transcript and effects
sub_ok=1
for n in 1 2 3 4; do
    case "$(kind_of "$n")" in volume|run|info|version) : ;; *) sub_ok=0 ;; esac
done
eq "no write: every docker subcommand is a read (volume inspect / run / info / version)" "1" "$sub_ok"
for n in 1 3; do
    case "$(call_of "$n")" in
        "<volume><inspect>"*) test_pass "no write: volume subcommand $n is inspect" ;;
        *) test_fail "no write: volume subcommand $n is inspect ($(call_of "$n"))" ;;
    esac
done
ro_ok=1
for n in 2 4; do
    c="$(call_of "$n")"
    case "$c" in *"<--mount>"*|*"<--volume>"*|*":rw>"*|*"<--privileged>"*) ro_ok=0 ;; esac
    case "$c" in *"<--network><none>"*) : ;; *) ro_ok=0 ;; esac
    case "$c" in *"<--user><0:0>"*) : ;; *) ro_ok=0 ;; esac
    case "$c" in *"<--pull><never>"*) : ;; *) ro_ok=0 ;; esac
    # every -v mount is read-only
    if [ -n "$(perl -e 'my @w = split /></, substr($ARGV[0], 1, -1); for my $i (1 .. $#w) { print "$w[$i]\n" if $w[$i-1] eq "-v" && $w[$i] !~ /:ro$/ }' "$c")" ]; then ro_ok=0; fi
done
eq "no write: both containers are --network none, --user 0:0, --pull never, every -v :ro, no --mount, no --volume" "1" "$ro_ok"
script="$(script_of 2)"
write_verb=""
for verb in rm mv cp chmod chown chgrp touch tee mkdir mkfifo ln dd truncate install mktemp rsync rmdir unlink shred; do
    if grep -Fqw -e "$verb" <<<"$script"; then write_verb="$write_verb $verb"; fi
done
for flag in -delete -fprint -fprintf -fls; do
    if grep -Fq -e " $flag" <<<"$script"; then write_verb="$write_verb $flag"; fi
done
eq "no write: the container script has no write verb" "" "$write_verb"
ne "no write: the container script was captured" "" "$script"
stripped="$(sed -e 's/[0-9]*>[ ]*\/dev\/null//g' -e 's/[0-9]*>&[0-9-]//g' <<<"$script")"
lacks "no write: the container script redirects only to /dev/null or &N" "$stripped" ">"
# NAS shell commands: every ssh argument that is not an option, the host or a docker call
nas_cmds="$(grep -Fv -e "$TOOLS/docker" "$DXE_FAKE_SSH_ARGV_LOG" | grep -Fvx -e '-o' -e BatchMode=yes -e ConnectTimeout=15 -e LogLevel=ERROR -e "$PERSIST_FIXTURE_NAS_HOST")"
ne "no write: the NAS shell command was captured" "" "$nas_cmds"
nas_write=""
for verb in rm mv cp chmod chown chgrp touch tee mkdir mkfifo ln dd truncate install mktemp rsync rmdir unlink shred; do
    if grep -Fqw -e "$verb" <<<"$nas_cmds"; then nas_write="$nas_write $verb"; fi
done
eq "no write: the NAS shell command has no write verb" "" "$nas_write"
nas_stripped="$(sed -e 's/[0-9]*\\*>[ ]*\/dev\/null//g' -e 's/[0-9]*\\*>&[0-9-]//g' <<<"$nas_cmds")"
lacks "no write: the NAS shell command has no redirection to a file" "$nas_stripped" ">"
find "$ROOT" | sort >"$SCRATCH/root.after"
eq "no write: nothing was created under the share root" "$(cat "$SCRATCH/root.before")" "$(cat "$SCRATCH/root.after")"
eq "no write: no per-profile record under the state directory" "" "$(find "$SCRATCH/state" "$SCRATCH/home" -mindepth 1 2>/dev/null)"

# --- the dataset drives the report (not a constant) ----------------------------------
test_section "WP6.3: an empty volume"
new_case
put run-sh.out 'df_total_kb=100
df_avail_kb=60
size_kb=4
entries=0
hardlinks=0
appledouble=0
special=0
acl=0
xattr=0
status=ok'
put run-rsync.out "$V_330"
export DF_AVAIL=4
run_main
eq "empty: exit 0 (free == size is room)" "0" "$INV_RC"
eq "empty: the exact report" "volume: dx-fix-persist
size_kb: 4
entries: 0
hard_links: 0
appledouble_count: 0
appledouble: none
special_count: 0
special: none
acls: none
xattrs: none
rsync_version: 3.3.0
rsync_check: ok
target_root: $ROOT
target_free_kb: 4
target_room: yes
rollback_free_kb: 60
rollback_room: yes" "$INV_OUT"

test_section "WP6.3: ACLs and extended attributes"
new_case
put run-sh.out "$(inv_variant 's/^acl=0$/acl=3/; s/^xattr=0$/xattr=12/')"
put run-rsync.out "$V_330"
run_main
eq "acl+xattr present, rsync can: exit 0" "0" "$INV_RC"
hasline "acls: present" "$INV_OUT" "acls: present"
hasline "xattrs: present" "$INV_OUT" "xattrs: present"
eq "the rsync check is still the one version run" "$RSYNC_RUN_ARGV" "$(call_of 4)"
new_case
put run-sh.out "$(inv_variant 's/^acl=0$/acl=unknown/; s/^xattr=0$/xattr=unknown/')"
put run-rsync.out "$V_330"
run_main
eq "acl+xattr unknown: exit 0 when rsync has both" "0" "$INV_RC"
hasline "acls: unknown" "$INV_OUT" "acls: unknown"
hasline "xattrs: unknown" "$INV_OUT" "xattrs: unknown"

new_case
put run-sh.out "$(inv_variant 's/^acl=0$/acl=3/')"
put run-rsync.out "$V_NOACL"
run_main
eq "ACLs needed, rsync has none: exit 3" "3" "$INV_RC"
eq "that is a complete report, not an error" "" "$INV_ERR"
has "the refusal names ACLs" "$(grep -F 'rsync_check:' <<<"$INV_OUT")" "ACLs"
hasline "the version is unknown when the check is refused" "$INV_OUT" "rsync_version: unknown"
eq "the report is complete (20 lines for the standard dataset)" "20" "$(wc -l <<<"$INV_OUT" | tr -d ' ')"
new_case
put run-sh.out "$(inv_variant 's/^acl=0$/acl=unknown/')"
put run-rsync.out "$V_NOACL"
run_main
eq "ACLs unknown counts as needed: exit 3" "3" "$INV_RC"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_NOACL"
run_main
eq "no ACLs on the volume: a rsync without ACL support is fine" "0" "$INV_RC"
hasline "that rsync check is ok" "$INV_OUT" "rsync_check: ok"
new_case
put run-sh.out "$(inv_variant 's/^xattr=0$/xattr=2/')"
put run-rsync.out "$V_NOXATTR"
run_main
eq "xattrs needed, rsync has none: exit 3" "3" "$INV_RC"
has "the refusal names xattrs" "$(grep -F 'rsync_check:' <<<"$INV_OUT")" "xattrs"
lacks "the refusal does not name ACLs" "$(grep -F 'rsync_check:' <<<"$INV_OUT")" "ACLs"

test_section "WP6.3: rsync blockers"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_307"
run_main
eq "rsync 3.0.7 in the image: exit 3" "3" "$INV_RC"
has "refused line shape" "$INV_OUT" "rsync_check: refused: "
has "refused names the version gap" "$(grep -F 'rsync_check:' <<<"$INV_OUT")" "below 3.1"
hasline "the version is unknown" "$INV_OUT" "rsync_version: unknown"
eq "the volume facts are still all there" "1234" "$(sed -n 's/^entries: //p' <<<"$INV_OUT")"
new_case
put run-sh.out "$INV_STD"
put run-rsync.rc 1
run_main
eq "rsync cannot run in the image: exit 3" "3" "$INV_RC"
has "refused line shape" "$INV_OUT" "rsync_check: refused: "

test_section "WP6.3: the guest's nix volume (where rsync comes from) is a blocker, not a refusal"
new_case
put run-sh.out "$INV_STD"
put run-rsync.rc 127
put run-rsync.err "docker: Error response from daemon: failed to create task for container: exec: \"/nix/var/nix/profiles/per-user/root/profile/bin/rsync\": stat /nix/var/nix/profiles/per-user/root/profile/bin/rsync: no such file or directory: unknown."
run_main
eq "rsync missing from the guest's root profile (127): exit 3" "3" "$INV_RC"
eq "rsync missing: stderr is empty (docker's own stderr is dropped)" "" "$INV_ERR"
RCHECK="$(grep -F 'rsync_check:' <<<"$INV_OUT")"
has "rsync missing: refused line shape" "$RCHECK" "rsync_check: refused: "
has "rsync missing: the report says to boot the guest once" "$RCHECK" "boot the guest once"
has "rsync missing: ... so its essentials include rsync" "$RCHECK" "include rsync"
lacks "rsync missing: docker's own text is not the reason" "$RCHECK" "Error response from daemon"
hasline "rsync missing: the version is unknown" "$INV_OUT" "rsync_version: unknown"
eq "rsync missing: the report is complete (20 lines)" "20" "$(wc -l <<<"$INV_OUT" | tr -d ' ')"

nix_blocked() { # LABEL NEEDLE (after the case set up the nix volume's labels)
    put run-sh.out "$INV_STD"
    put run-rsync.out "$V_330"
    run_main
    eq "$1: exit 3 (a blocker)" "3" "$INV_RC"
    eq "$1: stderr is empty" "" "$INV_ERR"
    has "$1: rsync_check is refused with the DQ6 wording" "$(grep -F 'rsync_check:' <<<"$INV_OUT")" "rsync_check: refused: $2"
    hasline "$1: the version is unknown" "$INV_OUT" "rsync_version: unknown"
    eq "$1: the volume facts are still all there" "1234" "$(sed -n 's/^entries: //p' <<<"$INV_OUT")"
    eq "$1: only the inventory container ran (no rsync run)" "1" "$(nruns)"
    eq "$1: the inspects of both volumes, the one run" "3" "$(ncalls)"
}
new_case
set_labels dx-fix-nix "true|1|other-host__other-guest|nix|x86_64-linux"
nix_blocked "another profile's nix volume" "refusing to run rsync from volume 'dx-fix-nix'"
new_case
set_labels dx-fix-nix "true|1|$PROFILE|persist|x86_64-linux"
nix_blocked "a nix volume carrying another role" "refusing to run rsync from volume 'dx-fix-nix'"
new_case
rm -f "$FAKE_DOCKER_DIR/labels/dx-fix-nix"
nix_blocked "an absent nix volume" "refusing to run rsync from volume 'dx-fix-nix': it does not exist"

test_section "WP6.3: room for the copy and for a rollback volume"
new_case
export DF_AVAIL=51199
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
run_main
eq "target one KiB short: exit 3" "3" "$INV_RC"
hasline "target_room: no" "$INV_OUT" "target_room: no"
hasline "target_free_kb: 51199" "$INV_OUT" "target_free_kb: 51199"
hasline "rollback room is judged separately" "$INV_OUT" "rollback_room: yes"
new_case
export DF_AVAIL=51200
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
run_main
eq "target free == size: exit 0" "0" "$INV_RC"
hasline "target_room: yes at the boundary" "$INV_OUT" "target_room: yes"
new_case
put run-sh.out "$(inv_variant 's/^df_avail_kb=900000$/df_avail_kb=51199/')"
put run-rsync.out "$V_330"
run_main
eq "pool one KiB short for a rollback volume: exit 3" "3" "$INV_RC"
hasline "rollback_room: no" "$INV_OUT" "rollback_room: no"
hasline "rollback_free_kb comes from the container's df" "$INV_OUT" "rollback_free_kb: 51199"
hasline "target room is judged separately" "$INV_OUT" "target_room: yes"
new_case
put run-sh.out "$(inv_variant 's/^df_avail_kb=900000$/df_avail_kb=51200/')"
put run-rsync.out "$V_330"
run_main
eq "pool free == size: exit 0" "0" "$INV_RC"
hasline "rollback_room: yes at the boundary" "$INV_OUT" "rollback_room: yes"

# =============================================================================
test_section "WP6.3: refusals and failed reads print no report"
refused() { # LABEL WORD (after run_main/run_wrapper)
    eq "$1: exit 1" "1" "$INV_RC"
    eq "$1: nothing on stdout" "" "$INV_OUT"
    eq "$1: exactly one Error: line" "1" "$(errlines)"
    has "$1: the Error says why" "$INV_ERR" "$2"
}
new_case
set_labels dx-fix-persist "true|1|other-host__other-guest|persist|x86_64-linux"
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
run_main
refused "another profile's volume" "refusing"
eq "another profile's volume: only the inspect was made" "1" "$(ncalls)"
eq "another profile's volume: no container started" "0" "$(nruns)"
new_case
set_labels dx-fix-persist "true|1|$PROFILE|nix|x86_64-linux"
run_main
refused "a volume with another role" "refusing"
eq "another role: no container started" "0" "$(nruns)"
new_case
rm -f "$FAKE_DOCKER_DIR/labels/dx-fix-persist"
run_main
refused "an absent volume" "does not exist"
has "an absent volume: the volume is named" "$INV_ERR" "dx-fix-persist"
eq "an absent volume: no container started" "0" "$(nruns)"

new_case
put run-sh.out "partial=1"
put run-sh.err "container exploded"
put run-sh.rc 1
run_main
refused "the volume read fails" "Error:"
eq "a failed read: the rsync check is not run" "1" "$(nruns)"
eq "a failed read: nor the nix volume's inspect (two calls in all)" "2" "$(ncalls)"
new_case
put run-sh.out "$(printf '%s\n' "$INV_STD" | sed '/^status=ok$/d')"
run_main
refused "no status=ok" "Error:"
new_case
put run-sh.out "$(printf '%s\n' "$INV_STD" | sed '/^entries=/d')"
run_main
refused "a missing required key (entries)" "Error:"
new_case
put run-sh.out "$(inv_variant 's/^size_kb=51200$/size_kb=n\/a/')"
run_main
refused "a non-numeric size_kb" "Error:"
new_case
put run-sh.out "$(inv_variant 's/^df_avail_kb=900000$/df_avail_kb=/')"
run_main
refused "an empty df_avail_kb" "Error:"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
echo 1 >"$SCRATCH/df.rc"
export DF_RC_FILE="$SCRATCH/df.rc"
run_main
refused "the share root's df fails" "Error:"
unset DF_RC_FILE

new_case
put run-sh.out "$INV_STD"
RUN_PRE='export DX_PERSIST_HOST_ROOT='
run_main
refused "no DX_PERSIST_HOST_ROOT" "DX_PERSIST_HOST_ROOT"
eq "no DX_PERSIST_HOST_ROOT: no docker call" "0" "$(ncalls)"
eq "no DX_PERSIST_HOST_ROOT: no ssh call" "0" "$(ssh_calls)"

new_case
RUN_PRE='export DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image'
run_main
refused "DX_RUNTIME=apple" "DX_RUNTIME=docker-ssh"
eq "apple: no container call" "" "$(cat "$APPLE_LOG")"
eq "apple: no ssh call" "0" "$(ssh_calls)"
eq "apple: no docker call" "0" "$(ncalls)"

test_section "WP6.3: usage"
new_case
run_main --bogus
eq "an unknown argument: exit 2" "2" "$INV_RC"
eq "an unknown argument: nothing on stdout" "" "$INV_OUT"
has "an unknown argument: Usage on stderr" "$INV_ERR" "Usage:"
run_main dx-fix
eq "a positional argument: exit 2" "2" "$INV_RC"
run_main --help
eq "--help: exit 0" "0" "$INV_RC"
has "--help: usage on stdout" "$INV_OUT" "Usage: dx-persist-inventory"
run_main -h
eq "-h: exit 0" "0" "$INV_RC"
eq "usage and help make no runtime call" "0" "$(( $(ncalls) + $(ssh_calls) ))"

test_section "WP6.3: a share root with spaces and a command substitution is data"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
export PWNED="$SCRATCH/pwned"
# shellcheck disable=SC2089,SC2090  # a deliberately hostile literal path
ODD="$SCRATCH/dxe odd root\$(touch \"\$PWNED\")'q\"x"
RUN_PRE='export DX_PERSIST_HOST_ROOT="$ODD"'
# shellcheck disable=SC2090
export ODD
run_main
eq "odd root: exit 0" "0" "$INV_RC"
hasline "odd root: reported exactly as configured" "$INV_OUT" "target_root: $ODD"
eq "odd root: df received it as one word" "$ODD" "$(tail -n 1 "$DF_LOG")"
if [ -e "$PWNED" ]; then test_fail "odd root: the substitution was not executed"; else test_pass "odd root: the substitution was not executed"; fi

# =============================================================================
test_section "WP6.3: the wrapper and profile selection"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
if [ -x "$WRAPPER" ]; then test_pass "bin/dx-persist-inventory is executable"; else test_fail "bin/dx-persist-inventory is executable"; fi
run_wrapper
eq "wrapper: exit 0" "0" "$INV_RC"
eq "wrapper: the same report as the library function" "$STD_REPORT" "$INV_OUT"
run_wrapper --bogus
eq "wrapper: usage exit is propagated (2)" "2" "$INV_RC"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_307"
run_wrapper
eq "wrapper: the blocker exit (3) is propagated" "3" "$INV_RC"
new_case
set_labels dx-fix-persist "true|1|other-host__other-guest|persist|x86_64-linux"
run_wrapper
eq "wrapper: the refusal exit (1) is propagated" "1" "$INV_RC"

# Through bin/dx-profile, the way the sibling dx-* commands select a guest.
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
mkdir "$SCRATCH/profiles"
cat >"$SCRATCH/profiles/fixprof.env" <<EOF
export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=$PERSIST_FIXTURE_NAS_HOST
export DX_GUEST_SYSTEM=x86_64-linux
export DX_CONTAINER_NAME=dx-fix
export DX_IMAGE=dxe-inv-image:7
export DX_PERSIST_VOLUME=dx-fix-persist
export DX_NIX_VOLUME=dx-fix-nix
export DX_NIX_STORAGE_MODE=direct-volume
export DX_PERSIST_HOST_ROOT=$ROOT
EOF
INV_OUT="$(env -u DX_RUNTIME -u DX_REMOTE_HOST -u DX_CONTAINER_NAME -u DX_IMAGE -u DX_PERSIST_VOLUME -u DX_NIX_VOLUME -u DX_PERSIST_HOST_ROOT -u DX_NIX_STORAGE_MODE DX_PROFILES_DIR="$SCRATCH/profiles" bash "$BASE_DIR/bin/dx-profile" fixprof "$WRAPPER" 2>"$SCRATCH/inv.err")"
INV_RC=$?
INV_ERR="$(cat "$SCRATCH/inv.err")"
eq "dx-profile fixprof dx-persist-inventory: exit 0" "0" "$INV_RC"
eq "dx-profile: the report is the profile's guest" "$STD_REPORT" "$INV_OUT"
eq "dx-profile: the profile's DX_NIX_VOLUME is the volume mounted for rsync" "$RSYNC_RUN_ARGV" "$(call_of 4)"

# =============================================================================
# The container script, for real, on WP0.2 trees. The script is taken from the
# recorded docker argv above and run locally the way the container runs it
# (`sh -c SCRIPT sh <root>`), with the stub df on PATH.
test_section "WP6.3: the container script measures a real tree"
new_case
put run-sh.out "$INV_STD"
put run-rsync.out "$V_330"
run_main >/dev/null 2>&1
SCRIPT_TEXT="$(script_of 2)"
if [ -z "$SCRIPT_TEXT" ]; then
    test_fail "the container script could be taken from the recorded run"
else
    printf '%s' "$SCRIPT_TEXT" >"$SCRATCH/inventory-script.sh"
    if sh -n "$SCRATCH/inventory-script.sh" 2>/dev/null; then test_pass "the container script is valid POSIX sh"; else test_fail "the container script is valid POSIX sh"; fi
    TREE="$SCRATCH/dxe-tree"
    mkdir "$TREE"
    CWD_EMPTY="$SCRATCH/dxe-cwd"
    mkdir "$CWD_EMPTY"
    export DF_AVAIL=777000
    # WP6.3b: the bare image's tools only (interface contract 6).
    BARE="$SCRATCH/dxe-bare-bin"
    mkdir "$BARE"
    BARE_MISSING=""
    for tool in sh du find grep sort head tail cat printf wc tr cut ls stat mktemp cksum; do
        real=""
        for cand in "/usr/bin/$tool" "/bin/$tool"; do
            if [ -x "$cand" ]; then real="$cand"; break; fi
        done
        if [ -z "$real" ]; then real="$(command -v "$tool" 2>/dev/null || true)"; fi
        case "$real" in
            /*) ln -s "$real" "$BARE/$tool" ;;
            *) BARE_MISSING="$BARE_MISSING $tool" ;;
        esac
    done
    eq "bare PATH: every allowed tool exists on this host" "" "$BARE_MISSING"
    cat >"$BARE/df" <<'DFSTUB'
#!/bin/sh
k=1
for a in "$@"; do
    case "$a" in -*k*) k=0 ;; esac
done
m=1; [ "$k" = 1 ] && m=2
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fakeshare $(( 1000000 * m )) $(( 400000 * m )) $(( ${DF_AVAIL:-600000} * m )) 40% /share"
DFSTUB
    chmod 0755 "$BARE/df"
    bare_run() { # EXTRA_PATH_DIR(or empty) ROOT -> stdout; PATH is the bare dir alone (plus the stub dir)
        ( cd "$CWD_EMPTY" && PATH="${1:+$1:}$BARE" LC_ALL=en_US.UTF-8 /bin/sh "$SCRATCH/inventory-script.sh" "$2" 2>/dev/null )
    }
    bare_missing_rc=0
    ( PATH="$BARE" /bin/sh -c 'command -v sed >/dev/null 2>&1 || command -v awk >/dev/null 2>&1' ) && bare_missing_rc=1
    eq "bare PATH: sed and awk are absent (as on the bare nixos/nix image)" "0" "$bare_missing_rc"
    sed_probe_rc=0
    ( PATH="$BARE" /bin/sh -c 'sed p </dev/null' ) >/dev/null 2>&1 || sed_probe_rc=$?
    eq "bare PATH: calling sed fails with 127" "127" "$sed_probe_rc"
    S_OUT="" S_RC=0
    script_run() { # ROOT -> sets S_OUT S_RC; run with an empty cwd and a non-C locale
        S_OUT="$(bare_run "" "$1")"
        S_RC=$?
    }
    key() { sed -n "s/^$1=//p" <<<"$S_OUT" | head -n 1; }
    keys() { sed -n "s/^$1=//p" <<<"$S_OUT"; }
    if persist_fixture_tree_build "$TREE"; then
        before="$(tree_sig "$TREE")"
        script_run "$TREE"
        eq "real tree: the script exits 0" "0" "$S_RC"
        eq "real tree: status=ok is the last line" "status=ok" "$(tail -n 1 <<<"$S_OUT")"
        eq "real tree: df_total_kb (1024-blocks: -k was used)" "1000000" "$(key df_total_kb)"
        eq "real tree: df_avail_kb" "777000" "$(key df_avail_kb)"
        eq "real tree: size_kb is du -sk" "$(du -sk "$TREE" | awk '{print $1}')" "$(key size_kb)"
        eq "real tree: entries counts every path below the root" "$(persist_fixture_tree_list "$TREE" | tr -cd '\0' | wc -c | tr -d ' ')" "$(key entries)"
        eq "real tree: hardlinks counts the paths with a link count above 1 (3 + 2)" "5" "$(key hardlinks)"
        eq "real tree: appledouble count" "2" "$(key appledouble)"
        eq "real tree: the ._ paths, relative, sorted" "._root-meta
nested/a/._deep-meta" "$(keys apple)"
        eq "real tree: special count (socket and FIFO)" "2" "$(key special)"
        eq "real tree: the special paths" "special/fifo
special/sock" "$(keys special_path)"
        case "$(key acl)" in unknown|[0-9]*) test_pass "real tree: acl is a count or unknown" ;; *) test_fail "real tree: acl is a count or unknown ($(key acl))" ;; esac
        case "$(key xattr)" in unknown|[0-9]*) test_pass "real tree: xattr is a count or unknown" ;; *) test_fail "real tree: xattr is a count or unknown ($(key xattr))" ;; esac
        eq "real tree: the tree is untouched" "$before" "$(tree_sig "$TREE")"
        eq "real tree: nothing was written to the working directory" "" "$(ls -A "$CWD_EMPTY")"

        # ACL and xattr counts come from the tools' "# file:" headers.
        STUBS="$SCRATCH/dxe-acl-stubs"
        mkdir "$STUBS"
        stub_sh() { printf '#!/bin/sh\n%s\n' "$3" >"$1/$2"; chmod 0755 "$1/$2"; }
        stub_sh "$STUBS" getfacl 'printf "# file: a\n# owner: x\n# file: b\n"'
        stub_sh "$STUBS" getfattr 'printf "# file: a\n# file: b\n# file: c\nuser.x=\"1\"\n"'
        S_OUT="$(bare_run "$STUBS" "$TREE")"
        S_RC=$?
        eq "tools present: the script exits 0" "0" "$S_RC"
        eq "tools present: acl counts the # file: headers of getfacl" "2" "$(key acl)"
        eq "tools present: xattr counts the # file: headers of getfattr" "3" "$(key xattr)"
        stub_sh "$STUBS" getfacl 'printf ""'
        S_OUT="$(bare_run "$STUBS" "$TREE")"
        eq "tools present, nothing to report: acl=0" "0" "$(key acl)"
    else
        test_fail "the WP0.2 fixture tree could be built"
    fi

    # An empty volume.
    EMPTY="$SCRATCH/dxe-empty"
    mkdir "$EMPTY"
    script_run "$EMPTY"
    eq "empty volume: exit 0" "0" "$S_RC"
    eq "empty volume: entries=0" "0" "$(key entries)"
    eq "empty volume: hardlinks=0" "0" "$(key hardlinks)"
    eq "empty volume: appledouble=0" "0" "$(key appledouble)"
    eq "empty volume: no apple= lines" "" "$(keys apple)"
    eq "empty volume: special=0" "0" "$(key special)"
    eq "empty volume: no special_path= lines" "" "$(keys special_path)"
    eq "empty volume: status=ok" "status=ok" "$(tail -n 1 <<<"$S_OUT")"

    # Odd names and a complete, nested ._ list.
    ODDT="$SCRATCH/dxe-oddtree"
    mkdir "$ODDT"
    mkdir -p "$ODDT/-dir/in side" "$ODDT/deep/er/est" "$ODDT/sp ace"
    : >"$ODDT/._with space"
    : >"$ODDT/-dir/._-lead"
    : >"$ODDT/-dir/in side/._x y"
    : >"$ODDT/deep/er/est/._z"
    : >"$ODDT/sp ace/._a"
    : >"$ODDT/sp ace/plain"
    : >"$ODDT/not-apple._x"
    script_run "$ODDT"
    eq "odd names: exit 0" "0" "$S_RC"
    eq "odd names: five ._ files" "5" "$(key appledouble)"
    eq "odd names: the complete nested list, bytewise sorted, names intact" "-dir/._-lead
-dir/in side/._x y
._with space
deep/er/est/._z
sp ace/._a" "$(keys apple)"
    eq "odd names: entries" "$(find "$ODDT" -mindepth 1 | wc -l | tr -d ' ')" "$(key entries)"

    # WP6.3c: regression fixtures for the three shell details the loops and the
    # sort depend on. Each is run the restricted way (bare PATH, en_US.UTF-8).
    # (a) A ._ name that ends with a space survives the while-read loops
    #     (pins `IFS=`: without it read strips the trailing blank).
    TRAILT="$SCRATCH/dxe-trailing"
    mkdir "$TRAILT"
    mkdir "$TRAILT/sub dir"
    : >"$TRAILT/sub dir/._notes "
    script_run "$TRAILT"
    eq "trailing space: exit 0" "0" "$S_RC"
    eq "trailing space: the apple= line carries the exact name, trailing space included" "sub dir/._notes " "$(keys apple)"

    # (b) A special file at a path containing a backslash is reported
    #     byte-for-byte (pins `read -r`: without it the backslash is eaten).
    BSLT="$SCRATCH/dxe-backslash"
    mkdir "$BSLT"
    mkdir "$BSLT/back\\dir"
    mkfifo "$BSLT/back\\dir/fi\\fo"
    script_run "$BSLT"
    eq "backslash: exit 0" "0" "$S_RC"
    eq "backslash: special count" "1" "$(key special)"
    eq "backslash: the special_path= line carries the path byte-for-byte" 'back\dir/fi\fo' "$(keys special_path)"

    # (c) Names that sort differently under C and en_US.UTF-8; the test runs
    #     the script with LC_ALL=en_US.UTF-8 (bare_run), the script's own
    #     LC_ALL=C must still give byte order (pins `export LC_ALL=C`).
    # (No names differing only in case: macOS volumes are case-insensitive.)
    SORTT="$SCRATCH/dxe-sortorder"
    mkdir "$SORTT"
    for n in ._B ._a ._Z ._c ._ ._1 ._-x ._y; do : >"$SORTT/$n"; done
    script_run "$SORTT"
    eq "sort order: exit 0" "0" "$S_RC"
    eq "sort order: the apple= lines are in C byte order under LC_ALL=en_US.UTF-8" "._
._-x
._1
._B
._Z
._a
._c
._y" "$(keys apple)"

    # A partly unreadable tree is a failed read, never a partial number.
    if [ "$(id -u)" = 0 ]; then
        test_skip "an unreadable subtree fails the script (root can read everything)"
    else
        BAD="$SCRATCH/dxe-badtree"
        mkdir "$BAD"
        mkdir "$BAD/locked"
        : >"$BAD/locked/secret"
        : >"$BAD/open"
        chmod 000 "$BAD/locked"
        script_run "$BAD"
        chmod 755 "$BAD/locked"
        nonzero "unreadable subtree: the script exits non-zero" "$S_RC"
        lacks "unreadable subtree: status=ok is not printed" "$S_OUT" "status=ok"
    fi
fi

print_summary
exit_with_code
