#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.4 acceptance: the forward migration of a guest's /persist volume into
# its NAS host directory (plans/do plan.md D-3, D-5, D-6, D-7, D-8, D-10 with
# both 2026-10-11 paragraphs; spec R31-R35, R37 and section 6). Written before
# the command exists; the implementer builds exactly this contract.
#
# Interface contract (pinned by this file; the implementation must match):
#
# A. The command. bin/dx-persist-migrate (executable, 100755) is a thin
#    wrapper, the shape of bin/dx-persist-inventory:
#        source "$SCRIPT_DIR/dx-lib.sh"
#        persist_migrate_main() { dx_persist_migrate_main "$@"; }
#        if [ "${BASH_SOURCE[0]}" = "$0" ]; then persist_migrate_main "$@"; fi
#    over dx_persist_migrate_main in bin/lib/dx-persist-dir.sh (kcov scope).
#    bin/dx-migrate-persist (the legacy dx-workspace migration) is untouched.
#    The guest is chosen like the sibling commands: the resolved configuration
#    from the environment / .env / `bin/dx-profile NAME bin/dx-persist-migrate`.
#    No positional arguments and no options besides -h / --help (resuming is
#    automatic, see F). `-h` / `--help`: usage on stdout, first line starting
#    "Usage: dx-persist-migrate", exit 0, no runtime call. Anything else:
#    "Usage:" on stderr, exit 2, nothing on stdout, no runtime call.
#
# B. Exit codes.
#      0  migrated and verified: the marker is `ready`, the D-7 record is
#         written, the report (I) ends stdout, no stderr line starts "Error:";
#      1  refused, or failed before the verification (copy failed, marker or
#         record write failed). A refusal prints exactly ONE stderr line
#         starting "Error:" (naming the fix), nothing starting "Error:" on
#         stdout, and writes NOTHING: the share, the source volume and the
#         controller's state directory are unchanged, no container runs
#         that could write (no establish, rsync copy or marker-set run) and
#         nothing is chowned;
#      2  usage;
#      3  the copy finished but the verification failed (the manifest run
#         exited non-zero): the marker stays `copying`, no record, no report.
#
# C. Refusals before ANY runtime call (no lock, no ssh, no docker), checked
#    in this order (the first that applies is the one reported), each exit 1
#    with one Error line naming:
#      DX_RUNTIME is not docker-ssh            "DX_RUNTIME=docker-ssh"
#      DX_PERSIST_HOST_ROOT is empty           "DX_PERSIST_HOST_ROOT"
#      DX_PERSIST_HOST_MOUNT_SENTINEL is empty "DX_PERSIST_HOST_MOUNT_SENTINEL"
#      the D-7 record path cannot be formed    "record"
#        (dx_persist_dir_record_path fails: no XDG_STATE_HOME and no HOME)
#
# D. Then the lifecycle lock, dx_lifecycle_lock_acquire, held until the very
#    end and released on every exit after it (trap): the lock is the first
#    runtime effect and its release the last. A lock that cannot be taken
#    stops the command (exit 1) with no further call: no guest check, no
#    probe, no run. (The lock's own Error lines are not counted.)
#
# E. The run, in this order of effects (the order of the plan's WP6.4 Red):
#    1. Guest stopped: the first remote call after the lock is
#           dx_runtime_container_state "$DX_CONTAINER_NAME"          (J1)
#       running -> refused, the Error names the guest and
#       "dx-stop-container"; unknown -> refused, the Error names the guest;
#       stopped or absent -> on. The command never starts the guest and never
#       edits the profile.
#    2. Pre-flight reads, all before anything is written, in any order:
#       - the DQ6 checks of DX_PERSIST_VOLUME (role persist) and of
#         DX_NIX_VOLUME (role nix): a `volume inspect --format ...` of each.
#         Every docker run that mounts a named volume is preceded, in the
#         same invocation, by that volume's DQ6 inspect. A failed check is
#         the refusal, with the check's own "refusing to ..." Error line
#         (it names the volume);
#       - the probe, dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT"
#         "$DX_CONTAINER_NAME" (WP4.2), decided as in F; it is the ONLY
#         NAS-shell (non-docker) call the command makes;
#       - the inventory, dx_runtime_volume_inventory "$DX_PERSIST_VOLUME"
#         (WP6.3, a read-only run): a failure (non-zero, or no status=ok) is
#         a refusal naming the volume. Its acl= and xattr= values choose the
#         rsync options: -A unless acl=0, -X unless xattr=0 ("unknown" and
#         any count above 0 mean needed). Its apple= lines are the `._*` list;
#       - dx_runtime_host_rsync_check [-A] [-X] with those options: a refusal
#         stops the command (exactly one Error line, naming rsync and the
#         gap -- e.g. "below 3.1", "ACLs").
#    3. The destination (F): absent ->
#           dx_runtime_host_dir_establish create CANON GUEST "$DX_PERSIST_DIR_OWNER" COPYING
#       empty -> the same with adopt; resumable -> no call at all. (CANON is
#       the probe's root=, the canonical root; the run is WP4.4's pinned
#       22-word argv with that root.)
#    4. dx_runtime_host_rsync forward "$DX_PERSIST_VOLUME" DEST [-A] [-X]
#       (WP6.2's pinned argv). Non-zero -> exit 1, one Error line naming
#       "dx-persist-migrate" (run it again to resume); the marker stays
#       copying; no verification, no record.
#    5. dx_runtime_host_manifest_verify forward "$DX_PERSIST_VOLUME" DEST (J3).
#       Non-zero -> exit 3 and the command's one Error line, naming "copying"
#       (a tool that itself printed "Error:" lines, exit 2, adds its own);
#       the marker stays copying; no marker-set, no record, no report.
#       Running the command again resumes (F) and verifies again. (The guest is stopped
#       for the copy and the verification, so the tree is quiescent: the
#       manifest's same-second mtime caveat does not arise.)
#    6. dx_runtime_host_dir_marker_set CANON GUEST copying READY (J2).
#       Failure -> exit 1, one Error line; the marker stays copying.
#    7. The D-7 record (dx_persist_dir_record_write), mode=migrate (H).
#       Failure -> exit 1, one Error line naming the record path.
#    8. The report (I) on stdout.
#    DEST is always "CANON/dxe/GUEST/persist", formed by the tooling from the
#    probe's root, never a user-supplied path; every container operation
#    above gets CANON (never the configured root) as its ROOT.
#
# F. The destination decision, from the probe report (WP4.2: root=,
#    mounted=, state=, marker= and the marker bytes):
#      probe failed or report malformed       refused ("DX_PERSIST_HOST_ROOT")
#      root= not absolute, "/", or holding ","   refused ("DX_PERSIST_HOST_ROOT")
#      mounted= not yes                       refused ("DX_PERSIST_HOST_MOUNT_SENTINEL")
#      state=symlink                          refused ("symlink")
#      state=absent                           create
#      state=empty                            adopt
#      state=nonempty, no marker              refused ("not empty")
#      a marker that does not parse           refused ("marker")
#      a marker naming another guest          refused (names that guest)
#      copying, source-volume=DX_PERSIST_VOLUME  RESUME (rsync again into the
#                                              same directory, then verify)
#      copying, another or no source-volume   refused ("copying", and the
#                                              other volume's name if any)
#      ready                                  refused ("ready")
#      retired                                refused ("retired")
#
# G. Markers (D-3), via dx_persist_marker_format:
#      COPYING = format GUEST copying "$DX_PERSIST_VOLUME" T_C
#        schema=1 / guest= / state=copying / source-volume= / created-at=T_C,
#        T_C a controller UTC time taken during the run that creates it;
#      READY   = format GUEST ready "$DX_PERSIST_VOLUME" T_C T_M
#        created-at = the copying marker's own created-at (on a resume, the
#        one the probe returned; a copying marker without one gives T_M);
#        migrated-at = T_M, a controller UTC time taken after the
#        verification passed, during the final run.
#
# H. The D-7 record, after the ready marker and only then: exactly WP4.4's
#    five lines (schema=1, guest=, root=DX_PERSIST_HOST_ROOT as configured,
#    mode=migrate, created-at=<the ready marker's created-at>), mode 0600,
#    ONE mv from a temp file in its own directory.
#
# I. The report: the LAST lines of stdout, exactly
#        migrated: <DEST>
#        source_volume: <DX_PERSIST_VOLUME>
#        marker: ready
#        record: <the record path>
#        copy_seconds: <N>
#        verify_seconds: <N>
#        appledouble_dropped_count: <the inventory's appledouble= value>
#        appledouble_dropped: <path>     one line per inventory apple= line,
#                                        in its order; "appledouble_dropped: none"
#                                        when there are none
#        next: <one line containing "DX_PERSIST_STORAGE=host-path" and
#              "dx-recreate">   (the switch itself is the user's)
#    copy_seconds / verify_seconds: whole seconds, each the difference of two
#    readings of the controller's clock as `date +%s` prints it, taken
#    immediately before and after the rsync copy run / the manifest run
#    (spec R37: the measured copy and verify time, the downtime).
#
# J. New neutral runtime operations, each declared in bin/lib/dx-runtime.sh
#    (dx_runtime_<op>() { dx_runtime_dispatch <op> "$@"; }) and implemented
#    as dx_runtime_docker_<op> and dx_runtime_apple_<op>:
#
#    J1. dx_runtime_container_state NAME -- exactly one line, running,
#        stopped or absent (status 0), or unknown (non-zero; no stderr line
#        starts "Error:"). docker-ssh: exactly ONE docker call, argv
#            container inspect --format {{.State.Running}} NAME
#        "true" -> running, "false" -> stopped; a failure whose message holds
#        "no such container" or "no such object" (any letter case) -> absent;
#        any other failure (daemon or ssh down) -> unknown. Apple: defined
#        (its answers are not exercised here; host-path is docker-ssh only).
#
#    J2. dx_runtime_host_dir_marker_set ROOT GUEST EXPECTED_STATE MARKER_TEXT
#        Replaces the marker of ROOT/dxe/GUEST/persist only if its CURRENT
#        marker is EXPECTED_STATE for this guest and source (compare-and-set,
#        so a transition never jumps a state). SOURCE below is MARKER_TEXT's
#        source-volume value ("" when it has none).
#        Apple: non-zero, "unsupported" on stderr, no tool call at all.
#        docker-ssh refuses before any call (status 1, nothing on stdout, a
#        reason on stderr, no stderr line starting "Error:", no ssh call)
#        when: not exactly four arguments; ROOT is empty, not absolute, or
#        holds "," or a newline; GUEST is not a marker-class name;
#        EXPECTED_STATE is not copying|ready|retired; MARKER_TEXT does not
#        satisfy dx_persist_marker_parse or names another guest; DX_IMAGE is
#        empty. Otherwise exactly ONE docker call, argv exactly these 21
#        words:
#            run --rm -i --network none --user 0:0 --pull never
#            --mount type=bind,source=<ROOT>,target=/dxe-share
#            --entrypoint sh <DX_IMAGE> -c <SCRIPT> sh
#            /dxe-share <GUEST> <EXPECTED_STATE> <SOURCE>
#        SCRIPT: one constant single-line POSIX sh program (the same text
#        for every input, holding no data word; passes `sh -n` and
#        `dash -n`). The marker bytes -- MARKER_TEXT plus one trailing
#        newline -- travel on stdin. Nothing on stdout. In the container
#        (root), working from the bind, the script refuses (non-zero,
#        nothing written) unless: dxe, dxe/GUEST and the leaf are not
#        symlinks and the leaf is a directory; .dxe-persist-dir is a regular
#        file (not a symlink); it holds the exact line `guest=GUEST`, the
#        exact line `state=EXPECTED_STATE`, and the exact line
#        `source-volume=SOURCE` (or, when SOURCE is "", no source-volume
#        line). Then WP4.2's marker step: a temp file in the leaf, mode
#        0644, ONE mv onto .dxe-persist-dir (the only mv); no chown.
#
#    J3. dx_runtime_host_manifest_verify forward|reverse VOLUME DIR
#        The WP6.1 manifest verify of the volume against the host directory,
#        on the NAS, read-only. Apple: non-zero, "unsupported", no call.
#        docker-ssh refuses before any call (status 1, nothing on stdout, a
#        reason on stderr, no docker call) on: not exactly three arguments;
#        a direction other than forward or reverse; a DIR that is not
#        absolute, is "/", or holds "," or a newline. Then VOLUME's DQ6
#        check (one `volume inspect --format`; a failure: status 1, no run), then
#        exactly ONE run from $DX_IMAGE -- its own bash 5, coreutils and
#        findutils (no nix volume: the guest's root profile has no
#        findutils) -- argv exactly:
#          forward:
#            run --rm --network none --user 0:0 --pull never
#            -v <VOLUME>:/src:ro
#            --mount type=bind,source=<DIR>,target=/dst,readonly
#            --name dxe-persist-verify-PID LABELS(persist-verify)   (WP6.4c)
#            --entrypoint bash <DX_IMAGE> -c <MANIFEST> dx-persist-manifest verify /src /dst
#          reverse (the rollback, WP6.5):
#            run --rm --network none --user 0:0 --pull never
#            --mount type=bind,source=<DIR>,target=/src,readonly
#            -v <VOLUME>:/dst:ro
#            --name dxe-persist-verify-PID LABELS(persist-verify)   (WP6.4c)
#            --entrypoint bash <DX_IMAGE> -c <MANIFEST> dx-persist-manifest verify /src /dst
#        (WP6.4c, tests/test_persist_copy_resume.sh B: PID is the DQ6
#        profile id; LABELS(ROLE) is dx_runtime_docker_label_flags ROLE. The
#        rsync copy run gains --name dxe-persist-copy-PID LABELS(persist-copy)
#        and --inplace --modify-window=-1 the same way, and after the guest
#        check the command makes two `ps -a` queries for those containers.)
#        MANIFEST is the text of
#        container/dx-nixos-26.05/scripts/lib/dx-persist-manifest.sh (D-8:
#        the inline script of a one-off container; trailing newlines may be
#        dropped). Its stdout, stderr and status pass through unchanged
#        (0 match, 1 differ, 2 error).
#
# K. Never: a NAS-shell write (every write into the share is a root one-off
#    container: establish, the rsync copy, marker-set); a `-v` mount without
#    ":ro" in any run (the source volume is never written); a `start`.
#
# Test-only conventions. Everything lives under one scratch area made by the
# WP0.2 fixtures. The share is a fixture root served by the WP0.2 NAS fake (a
# recording ssh in front of it logs every NAS-shell call). The NAS's docker is
# a fake that records every argv (NUL-separated, one file per call) and an
# event line, answers the DQ6 label inspects, the guest's state and the
# remote lock, maps `-v NAME` to a fixture "volume" directory and `--mount`
# binds to their sources (refusing any source outside the scratch area), and
# EXECUTES runs: the establish and marker-set scripts under sh, as root would,
# on a PATH whose chown is a RECORDING stub and whose chmod/mv/rm refuse
# anything recursive or outside the bound root (as in WP4.4's suite); the
# inventory and `rsync --version` from canned outputs; the rsync copy and the
# manifest verify for real (host rsync >= 3.1 and the real manifest text
# under bash 5 with GNU tools: the Linux coverage container and CI) or, where
# that toolchain is missing (this Mac's Bash 3.2), with small perl stand-ins
# on a simpler tree. The controller's `mv` and `date +%s` are recording
# fakes: the clock advances only inside the fake rsync copy (+100 s) and the
# fake manifest run (+30 s). The command's stdout is appended to the same
# event log as the fakes' events, so the order of effects is observable.
# Interruptions use the harness: fake_fail_nth on a gate the fake rsync asks
# (the kill), and on the container's mv (a crash between steps).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../bin/lib/dx-config.sh
source "$BASE_DIR/bin/lib/dx-config.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$CONTAINER_DIR/scripts/lib/dx-persist-marker.sh"

test_section "WP6.4: forward migration (dx-persist-migrate)"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
SCRATCH_PHYS="$(cd -P "$SCRATCH" && pwd -P)"
mkdir -p "$SCRATCH/home"

GUEST=dx-fix
NAS="$PERSIST_FIXTURE_NAS_HOST"
SENTINEL=dxe-share-mounted
IMAGE=dx-fix-image
OWNER_PIN=30033:30001
MARKER_NAME=.dxe-persist-dir
RSYNC_EP=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
MANIFEST_FILE="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"
WRAPPER="$BASE_DIR/bin/dx-persist-migrate"
CLOCK0=1760000000
SH_BIN="$(command -v sh)"
DASH_BIN="$(command -v dash 2>/dev/null || true)"
HOST_RSYNC="$(command -v rsync 2>/dev/null || true)"
REAL_BASH="$(command -v bash)"

# --- real or stand-in copy and verification -----------------------------------
# The real rsync and the real manifest tool need Bash 5, GNU findutils and
# coreutils, sha256sum and rsync >= 3.1 (the WP6.2 fidelity toolchain).
toolchain_ok() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in *"version "[5-9].*) : ;; *) return 1 ;; esac
    v="$(find --version 2>/dev/null)" || return 1
    case "$v" in *"GNU findutils"*) : ;; *) return 1 ;; esac
    v="$(stat --version 2>/dev/null)" || return 1
    case "$v" in *"GNU coreutils"*) : ;; *) return 1 ;; esac
    command -v sha256sum >/dev/null 2>&1 || return 1
    [ -n "$HOST_RSYNC" ] || return 1
    v="$("$HOST_RSYNC" --version 2>/dev/null)" || return 1
    v="${v%%$'\n'*}"
    v="${v#*version}"
    v="${v# }"
    v="${v# }"
    case "$v" in 3.[1-9]* | [4-9].*) return 0 ;; esac
    return 1
}
REAL=no
if toolchain_ok; then REAL=yes; fi
echo "  (copy and verification: $([ "$REAL" = yes ] && echo "real rsync and the real manifest tool" || echo "perl stand-ins; the real ones run on Linux"))"

HELPERS="$SCRATCH/helpers"
mkdir -p "$HELPERS"
# The rsync stand-in: copies SRC to DST like `rsync -a --exclude=/.dxe-persist-dir
# --exclude=._*` (dirs, files, symlinks; size+mtime quick check), skipping the
# top-level name SKIP when given (the "killed mid-run" partial copy).
cat >"$HELPERS/sim-copy.pl" <<'PERL'
use strict;
use warnings;
use File::Copy ();
my ($src, $dst, $skip) = @ARGV;
$skip = '' unless defined $skip;
s{/+$}{} for ($src, $dst);
sub walk {
    my ($rel) = @_;
    my $sdir = $rel eq '' ? $src : "$src/$rel";
    opendir(my $dh, $sdir) or die "sim rsync: opendir $sdir: $!\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    for my $n (@names) {
        my $r = $rel eq '' ? $n : "$rel/$n";
        next if $n =~ /^\._/ || $r eq '.dxe-persist-dir' || ($skip ne '' && $r eq $skip);
        my ($s, $t) = ("$src/$r", "$dst/$r");
        my @st = lstat($s) or die "sim rsync: lstat $s: $!\n";
        if (-l _) {
            unlink($t) if -l $t || -f $t;
            symlink(readlink($s), $t) or die "sim rsync: symlink $t: $!\n";
        } elsif (-d _) {
            mkdir($t) unless -d $t;
            walk($r);
            chmod($st[2] & 07777, $t);
            utime($st[8], $st[9], $t);
        } elsif (-f _) {
            my @dt = lstat($t);
            unless (@dt && -f _ && $dt[7] == $st[7] && $dt[9] == $st[9]) {
                File::Copy::copy($s, "$t.simtmp") or die "sim rsync: copy $s: $!\n";
                rename("$t.simtmp", $t) or die "sim rsync: rename $t: $!\n";
            }
            chmod($st[2] & 07777, $t);
            utime($st[8], $st[9], $t);
        } else {
            die "sim rsync: unsupported file type at $r\n";
        }
    }
}
walk('');
my @root = stat($src);
chmod($root[2] & 07777, $dst);
utime($root[8], $root[9], $dst);
PERL
# The manifest stand-in: compares type, mode, owner, size, mtime and content
# (and symlink targets) of two trees, without ._* names and the top-level
# marker; prints and exits like dx-persist-manifest verify.
cat >"$HELPERS/sim-manifest.pl" <<'PERL'
use strict;
use warnings;
use Digest::SHA ();
my ($a, $b) = @ARGV;
sub walk {
    my ($root) = @_;
    my %m;
    my @rs = lstat($root) or die "Error: cannot read $root\n";
    $m{'.'} = sprintf("d %04o %d:%d", $rs[2] & 07777, $rs[4], $rs[5]);
    my @stack = ('');
    while (@stack) {
        my $rel = pop @stack;
        my $dir = $rel eq '' ? $root : "$root/$rel";
        opendir(my $dh, $dir) or die "Error: cannot read $dir\n";
        for my $n (grep { $_ ne '.' && $_ ne '..' } readdir($dh)) {
            next if $n =~ /^\._/;
            my $r = $rel eq '' ? $n : "$rel/$n";
            next if $r eq '.dxe-persist-dir';
            my @st = lstat("$root/$r");
            if (-l _) {
                $m{$r} = 'l ' . readlink("$root/$r");
            } elsif (-d _) {
                $m{$r} = sprintf("d %04o %d:%d", $st[2] & 07777, $st[4], $st[5]);
                push @stack, $r;
            } elsif (-f _) {
                $m{$r} = sprintf("f %04o %d:%d %d %d %s", $st[2] & 07777, $st[4], $st[5], $st[7], $st[9],
                    Digest::SHA->new(256)->addfile("$root/$r")->hexdigest);
            } else {
                $m{$r} = 'o';
            }
        }
        closedir($dh);
    }
    return \%m;
}
my ($ma, $mb) = (walk($a), walk($b));
my @d;
for my $k (sort keys %$ma) {
    if (!exists $mb->{$k}) { push @d, "missing ./$k" }
    elsif ($ma->{$k} ne $mb->{$k}) { push @d, "changed ./$k" }
}
for my $k (sort keys %$mb) { push @d, "extra ./$k" unless exists $ma->{$k} }
if (!@d) { printf "Manifests match: entries=%d\n", scalar(keys %$ma); exit 0 }
printf "Manifests differ: differences=%d entries-a=%d entries-b=%d\n", scalar(@d), scalar(keys %$ma), scalar(keys %$mb);
print "$_\n" for @d[0 .. ($#d < 19 ? $#d : 19)];
exit 1;
PERL

# The snapshot walker behind snap (below): every entry of the current
# directory with its type, permission bits, link target and content digest.
cat >"$HELPERS/snap.pl" <<'PERL'
use strict;
use warnings;
use Digest::MD5 ();
my @out;
sub walk {
    my ($p) = @_;
    my @st = lstat($p) or return;
    my $mode = sprintf("%o", $st[2] & 07777);
    if (-l _) {
        push @out, "L $p -> " . readlink($p);
    } elsif (-d _) {
        push @out, "D $p $mode";
        opendir(my $dh, $p) or return;
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);
        walk("$p/$_") for @names;
    } elsif (-f _) {
        my $digest = '?';
        if (open(my $fh, '<', $p)) { binmode($fh); $digest = Digest::MD5->new->addfile($fh)->hexdigest; close($fh); }
        push @out, "F $p $mode $digest";
    } else {
        push @out, "O $p";
    }
}
walk('.');
print map { "$_\n" } sort @out;
PERL

# --- the container's tools: a recording chown, guarded chmod/mv/rm (WP4.4) ---
GUARD="$SCRATCH/guard-bin"
mkdir -p "$GUARD"
GUARD_BODY='log="${DXE_FAKE_CLOG:?}"
conf="${DXE_FAKE_CONFINE:?}"
res() {
    local p="$1" d b
    if [ -d "$p" ] && [ ! -L "$p" ]; then
        (cd -P -- "$p" 2>/dev/null && pwd -P) || printf "?%s" "$p"
        return 0
    fi
    d="$(dirname -- "$p")"
    b="$(basename -- "$p")"
    if d="$(cd -P -- "$d" 2>/dev/null && pwd -P)"; then printf "%s/%s" "${d%/}" "$b"; else printf "?%s" "$p"; fi
}
spec=""
first=1
ops=()
for a in "$@"; do
    case "$a" in
        --) continue ;;
        --recursive | -*[Rr]*) printf "%s REFUSED-RECURSIVE %s\n" "$tool" "$*" >>"$log"; exit 97 ;;
        -*) continue ;;
    esac
    if [ "$first" = 1 ] && { [ "$tool" = chown ] || [ "$tool" = chmod ]; }; then
        spec="$a"
        first=0
        continue
    fi
    first=0
    ops+=("$a")
done
line="$tool"
[ -z "$spec" ] || line="$line $spec"
for a in "${ops[@]}"; do
    r="$(res "$a")"
    case "$r" in
        "$conf") line="$line @" ;;
        "$conf"/*) line="$line @${r#"$conf"}" ;;
        *) printf "%s REFUSED-OUTSIDE %s\n" "$tool" "$r" >>"$log"; exit 97 ;;
    esac
done
printf "%s\n" "$line" >>"$log"
[ "$real" = yes ] || exit 0
exec "/bin/$tool" "$@"'
fake_tool_write "$GUARD" chown "$(printf 'tool=chown\nreal=no\n%s' "$GUARD_BODY")"
for t in chmod mv rm; do
    fake_tool_write "$GUARD" "$t" "$(printf 'tool=%s\nreal=yes\n%s' "$t" "$GUARD_BODY")"
done

# --- the NAS's docker ------------------------------------------------------------
DOCKER_FAKE='d="${P_DDIR:?}"
n=1
while [ -e "$d/call.$n" ]; do n=$((n + 1)); done
printf "%s\0" "$@" >"$d/call.$n"
ev() {
    printf "%s\n" "$*" >"$d/kind.$n"
    printf "~EV~ docker %s\n" "$*" >>"${P_EVLOG:?}"
}
phys() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
tick() { local c; c="$(cat "${P_CLOCK:?}")"; printf "%s\n" "$((c + $1))" >"$P_CLOCK"; }
last=""
for a in "$@"; do last="$a"; done
case "${1:-} ${2:-}" in
    "volume inspect")
        if [ "${3:-}" = --format ]; then ev dq6 "$last"; else ev vol-state "$last"; fi
        if [ -f "${P_LABELS:?}/$last" ]; then
            if [ "${3:-}" = --format ]; then cat "$P_LABELS/$last"; else echo "[{\"Name\":\"$last\"}]"; fi
            exit 0
        fi
        echo "Error: No such volume: $last" >&2
        exit 1 ;;
    "container inspect")
        case "$last" in
            dxe-lock-*)
                ev lock-inspect
                [ -f "${P_LOCKDIR:?}/held" ] || { echo "Error: No such container: $last" >&2; exit 1; }
                case "$*" in
                    *io.dxe.managed*) printf "true|%s__%s|lock|%s\n" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME" "$(cat "$P_LOCKDIR/held")" ;;
                    *) printf "%s|2026-10-12T00:00:00Z\n" "$(cat "$P_LOCKDIR/held")" ;;
                esac
                exit 0 ;;
        esac
        ev guest-state "$last"
        case "${P_GUEST_STATE:-stopped}" in
            running) echo true ;;
            stopped) echo false ;;
            absent) echo "Error: No such container: $last" >&2; exit 1 ;;
            object) echo "Error: No such object: $last" >&2; exit 1 ;;
            *) echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1 ;;
        esac
        exit 0 ;;
    "create --name")
        ev lock
        if [ -e "${P_LOCKDIR:?}/held" ]; then
            echo "docker: Error response from daemon: Conflict. The container name \"/$3\" is already in use." >&2
            exit 125
        fi
        owner=""
        for a in "$@"; do case "$a" in io.dxe.owner=*) owner="${a#io.dxe.owner=}" ;; esac; done
        printf "%s\n" "$owner" >"$P_LOCKDIR/held"
        echo 0123456789ab
        exit 0 ;;
    "rm dxe-lock-"*)
        ev unlock
        /bin/rm -f "${P_LOCKDIR:?}/held"
        exit 0 ;;
    "ps -a")
        ev ps "$4"
        exit 0 ;;
    "run "*) shift ;;
    *) ev other "$*"; echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
mt=()
ms=()
entry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rm | -i) shift ;;
        --network | --user | --pull | --name | --label) shift 2 ;;
        -v)
            name="${2%%:*}"
            rest="${2#*:}"
            src="${P_VOLROOT:?}/$name"
            [ -d "$src" ] || { ev run no-volume "$name"; echo "docker: Error response from daemon: no such volume: $name" >&2; exit 125; }
            mt+=("${rest%%:*}")
            ms+=("$(phys "$src")")
            shift 2 ;;
        --mount)
            case "$2" in type=bind,source=*,target=*) : ;; *) ev run bad-mount "$2"; exit 99 ;; esac
            rest="${2#type=bind,source=}"
            src="${rest%%,target=*}"
            tgt="${rest#*,target=}"
            if [ ! -d "$src" ]; then
                ev run missing-bind "$src"
                echo "docker: Error response from daemon: invalid mount config for type \"bind\": bind source path does not exist: $src" >&2
                exit 125
            fi
            sp="$(phys "$src")"
            case "$sp/" in
                "${P_SCRATCH:?}"/*) : ;;
                *) ev run refused-outside "$sp"; echo "fake docker: refusing a bind source outside the scratch area: $sp" >&2; exit 99 ;;
            esac
            mt+=("${tgt%%,*}")
            ms+=("$sp")
            shift 2 ;;
        --entrypoint) entry="$2"; shift 2 ;;
        -*) ev run unexpected-option "$1"; echo "fake docker: unexpected run option $1" >&2; exit 99 ;;
        *) break ;;
    esac
done
shift
mapped=()
for a in "$@"; do
    i=0
    while [ "$i" -lt "${#mt[@]}" ]; do
        t="${mt[$i]}"
        case "$a" in
            "$t") a="${ms[$i]}"; break ;;
            "$t"/*) a="${ms[$i]}/${a#"$t"/}"; break ;;
        esac
        i=$((i + 1))
    done
    mapped+=("$a")
done
cword=""
prev=""
for a in "$@"; do
    [ "$prev" != -c ] || cword="$a"
    prev="$a"
done
case "$entry" in
    sh)
        if [ "$cword" = "${P_INVENTORY_SCRIPT:-}" ]; then
            ev run inventory
            [ ! -f "${P_INV_OUT:-}" ] || cat "$P_INV_OUT"
            exit "${P_INV_RC:-0}"
        fi
        if [ "${#ms[@]}" -ne 1 ] || [ "${mt[0]}" != /dxe-share ]; then ev run unexpected sh; exit 99; fi
        if [ "$cword" = "${P_ESTABLISH_SCRIPT:-}" ]; then ev run establish "${6:-}"
        elif [ "$#" -eq 7 ]; then ev run marker-set "${6:-}"
        else ev run unexpected sh-script
        fi
        croot="$(mktemp -d "$P_SCRATCH/dxe-croot.XXXXXX")" || exit 125
        conf="${ms[0]}"
        (
            cd "$croot" || exit 125
            umask 022
            DXE_FAKE_CONFINE="$conf"
            DXE_FAKE_CLOG="${P_CLOG:?}"
            PATH="${P_CPRE:+$P_CPRE:}${P_GUARD:?}:/usr/bin:/bin"
            export DXE_FAKE_CONFINE DXE_FAKE_CLOG PATH
            exec "${P_SH:?}" "${mapped[@]}"
        )
        rc=$?
        if [ -f "$conf/dxe/${5:-}/persist/.dxe-persist-dir" ]; then cp "$conf/dxe/${5:-}/persist/.dxe-persist-dir" "$d/marker.$n"; fi
        exit "$rc" ;;
    /nix/var/nix/profiles/per-user/root/profile/bin/rsync)
        if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
            ev run rsync-version
            [ ! -f "${P_RSYNC_VERSION:-}" ] || cat "$P_RSYNC_VERSION"
            exit "${P_RSYNC_VERSION_RC:-0}"
        fi
        ev run rsync-copy
        tick 100
        k="${#mapped[@]}"
        srcp="${mapped[$((k - 2))]}"
        dstp="${mapped[$((k - 1))]}"
        partial=""
        if [ -n "${P_KILL_GATE:-}" ]; then
            "$P_KILL_GATE" rsync-copy
            krc=$?
            [ "$krc" -eq 0 ] || partial="$krc"
        fi
        if [ "${P_REAL:-no}" = yes ]; then
            if [ -n "$partial" ]; then "${P_HOST_RSYNC:?}" --exclude=/nested "${mapped[@]}"; exit "$partial"; fi
            "${P_HOST_RSYNC:?}" "${mapped[@]}" || exit $?
        else
            ex1=no
            ex2=no
            i=0
            while [ "$i" -lt "$((k - 2))" ]; do
                case "${mapped[$i]}" in
                    -aH | --numeric-ids | --inplace | --modify-window=-1 | -A | -X) : ;;
                    --exclude=/.dxe-persist-dir) ex1=yes ;;
                    "--exclude=._*") ex2=yes ;;
                    *) echo "rsync: unknown option ${mapped[$i]} (sim)" >&2; exit 1 ;;
                esac
                i=$((i + 1))
            done
            [ "$ex1$ex2" = yesyes ] || { echo "rsync: the stand-in needs both excludes" >&2; exit 1; }
            if [ -n "$partial" ]; then perl "${P_SIM_COPY:?}" "$srcp" "$dstp" nested; exit "$partial"; fi
            perl "${P_SIM_COPY:?}" "$srcp" "$dstp" || exit $?
        fi
        if [ "${P_CORRUPT:-no}" = yes ]; then printf "corrupt\n" >>"${dstp%/}/plain.txt"; fi
        exit 0 ;;
    bash)
        ev run manifest
        tick 30
        case "${P_MANIFEST_FORCE_RC:-}" in
            0) echo "Manifests match: entries=7"; exit 0 ;;
            1) echo "Manifests differ: differences=1 entries-a=7 entries-b=7"; echo "changed size,sha256 ./plain.txt"; exit 1 ;;
            2) echo "Error: cannot read manifest [x]" >&2; exit 2 ;;
        esac
        if [ "${P_REAL:-no}" = yes ]; then exec "${P_REAL_BASH:?}" "${mapped[@]}"; fi
        want="$(cat "${P_MANIFEST_FILE:?}")"
        got="$(printf "%s" "${mapped[1]:-}")"
        if [ "$got" != "$want" ] || [ "${mapped[2]:-}" != dx-persist-manifest ] || [ "${mapped[3]:-}" != verify ]; then
            echo "Error: the fake container was not given the manifest tool (verify)" >&2
            exit 2
        fi
        exec perl "${P_SIM_MANIFEST:?}" "${mapped[4]:-}" "${mapped[5]:-}" ;;
esac
ev run unexpected "$entry"
echo "fake docker: unexpected entrypoint [$entry]" >&2
exit 99'

# A recording ssh in front of the NAS fake: docker calls log themselves; every
# other (NAS-shell) call is logged here as probe, free or other. P_SSH_FAIL (a
# glob over the remote command) fails matching calls like an unreachable host;
# P_PROBE_CANNED answers the probe from a file instead of the share.
REC="$SCRATCH/rec-ssh"
mkdir -p "$REC"
fake_tool_write "$REC" ssh 'orig=("$@")
last=""
for a in "$@"; do last="$a"; done
eval "set -- $last"
if [ "${1:-}" != docker ]; then
    kind=other
    if [ "${1:-}" = sh ] && [ "${2:-}" = -c ]; then
        if [ "${3:-}" = "${P_PROBE_SCRIPT:-}" ]; then kind=probe
        elif [ "${3:-}" = "${P_FREE_SCRIPT:-}" ]; then kind=free
        fi
    fi
    printf "~EV~ nas %s\n" "$kind" >>"${P_EVLOG:?}"
    if [ -n "${P_SSH_FAIL:-}" ]; then
        case "$last" in
            $P_SSH_FAIL) echo "ssh: connect to host dxe-fixture-nas.invalid port 22: Connection refused" >&2; exit 255 ;;
        esac
    fi
    if [ "$kind" = probe ] && [ -n "${P_PROBE_CANNED:-}" ]; then cat "$P_PROBE_CANNED"; exit 0; fi
fi
exec "${P_REAL_SSH:?}" "${orig[@]}"'

# The controller's mv (recorded: the D-7 record must arrive by one mv) and
# date (+%s reads the fake clock; every other format is the real date).
CTRL="$SCRATCH/ctrl-bin"
mkdir -p "$CTRL"
fake_tool_write "$CTRL" mv 'ops=()
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    ops+=("$a")
done
printf "%s\n" "${ops[*]}" >>"${P_MVLOG:?}"
printf "~EV~ ctrl-mv %s\n" "${ops[$((${#ops[@]} - 1))]}" >>"${P_EVLOG:?}"
exec /bin/mv "$@"'
fake_tool_write "$CTRL" date 'case "$*" in
    "+%s" | "-u +%s") cat "${P_CLOCK:?}"; exit 0 ;;
esac
exec /bin/date "$@"'

# Recording stubs that do nothing, for the cases that hand a dangerous path
# ("/") to the code under test (common brief, safety rules).
STUBS="$SCRATCH/stub-bin"
mkdir -p "$STUBS"
for t in rm chmod chown mv find; do
    fake_tool_write "$STUBS" "$t" "printf '%s %s\n' $t \"\$*\" >>\"\${P_STUBLOG:?}\"
exit 0"
done

# Canned outputs.
V_330='rsync  version 3.3.0  protocol version 31
Copyright (C) 1996-2024 by Andrew Tridgell, Wayne Davison, and others.
Web site: https://rsync.samba.org/

Capabilities:
    64-bit files, 64-bit inums, 64-bit timestamps, 64-bit long ints,
    socketpairs, symlinks, symtimes, hardlinks, hardlink-specials,
    hardlink-symlinks, IPv6, atimes, batchfiles, inplace, append, ACLs,
    xattrs, optional secluded-args, iconv, prealloc, stop-at, no crtimes
Optimizations:
    SIMD-roll, no asm-roll, openssl-crypto, asm-MD5
Checksum list:
    xxh128 xxh3 xxh64 (xxhash) md5 md4 sha1 none

rsync comes with ABSOLUTELY NO WARRANTY.  This is free software, and you
are welcome to redistribute it under certain conditions.  See the GNU
General Public Licence for details.'
caps_of() { # VERSION CAPS
    printf 'rsync  version %s  protocol version 31\nCopyright (C) 1996-2024 by Andrew Tridgell, Wayne Davison, and others.\n\nCapabilities:\n    %s\nOptimizations:\n    SIMD-roll, no asm-roll\n\nrsync comes with ABSOLUTELY NO WARRANTY.\n' "$1" "$2"
}
V_307="$(caps_of 3.0.7 'hardlinks, symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, symtimes, prealloc')"
V_NOACL="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, no ACLs, xattrs')"
INV_STD='df_total_kb=9000000
df_avail_kb=8000000
size_kb=96
entries=24
hardlinks=0
appledouble=2
apple=._root-meta
apple=nested/a/._deep-meta
special=0
acl=0
xattr=0
status=ok'

# --- small assertion helpers -------------------------------------------------
eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE (fixed string)
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
ok() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_pass "$label"; else test_fail "$label"; fi
}
not() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi
}
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
not_after() { [ "$1" = "$2" ] || [ "$1" \< "$2" ]; }
error_lines() { grep -c '^Error:' <<<"$1" || true; }
inode_of() { ls -di -- "$1" 2>/dev/null | awk '{ print $1 }'; }

# snap DIR: every path below DIR (DIR itself entered as cd -P would) with its
# type, mode, link target and file checksum, bytewise sorted; "ABSENT" when DIR
# does not exist. One perl process per snapshot.
snap() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        echo ABSENT
        return 0
    fi
    (cd -P -- "$1" && perl "$HELPERS/snap.pl")
}
entries_of() { (cd -P -- "$1" && find . -mindepth 1 | LC_ALL=C sort); }

# Give every entry of a tree its own old, nanosecond-precise mtime (GNU touch;
# real mode only), as WP6.2's fidelity cases do.
stamp_tree() {
    local i=0 p
    while IFS= read -r -d "" p; do
        i=$((i + 1))
        touch -h -d "@$((1600000000 + i)).$((100000000 + i * 7919))" -- "$p"
    done < <(find "$1" -depth -print0)
}

# build_source DIR: the guest's persist volume. Real mode: the WP0.2 tree;
# otherwise a simpler tree with the same key names. Both hold ._* files at two
# depths and a stray marker at the top (never copied).
build_source() {
    if [ "$REAL" = yes ]; then
        persist_fixture_tree_build "$1"
        printf 'volume-marker\n' >"$1/$MARKER_NAME"
        stamp_tree "$1"
        return 0
    fi
    mkdir -p "$1/nested/a/b/c" "$1/links" "$1/private-0700" "$1/names"
    printf 'plain\n' >"$1/plain.txt"
    : >"$1/empty-file"
    printf 'secret\n' >"$1/secret-0600.txt"
    chmod 0600 "$1/secret-0600.txt"
    printf 'inner\n' >"$1/private-0700/inner.txt"
    chmod 0700 "$1/private-0700"
    : >"$1/._root-meta"
    printf 'deep\n' >"$1/nested/a/b/c/deep.txt"
    : >"$1/nested/a/._deep-meta"
    printf 'group-a\n' >"$1/links/a-one"
    ln -s ../plain.txt "$1/links/to-plain"
    : >"$1/names/-dash.txt"
    : >"$1/names/with space.txt"
    printf 'volume-marker\n' >"$1/$MARKER_NAME"
}

# world: a fresh share root (with its sentinel), NAS fake, docker fake, state
# directory, logs and clock; the persist and nix volumes exist with this
# profile's DQ6 labels; the persist volume holds the source tree.
N=0
world() {
    N=$((N + 1))
    W="$SCRATCH/w.$N"
    mkdir -p "$W/tmp"
    ROOT="$(persist_fixture_root_create "$W")"
    CANON="$(cd -P "$ROOT" && pwd -P)"
    TOOLS="$(persist_fixture_nas_create "$ROOT" "$W")"
    fake_tool_write "$TOOLS" docker "$DOCKER_FAKE"
    DDIR="$W/docker"
    STATE="$W/state"
    LABELS="$W/labels"
    VOLROOT="$W/volumes"
    LOCKDIR="$W/lock"
    mkdir -p "$DDIR" "$STATE" "$LABELS" "$VOLROOT/dx-fix-persist" "$VOLROOT/dx-fix-nix" "$LOCKDIR"
    EVLOG="$W/evlog"
    CLOG="$W/clog"
    MVLOG="$W/mvlog"
    STUBLOG="$W/stublog"
    CLOCK="$W/clock"
    : >"$EVLOG"
    : >"$CLOG"
    : >"$MVLOG"
    : >"$STUBLOG"
    printf '%s\n' "$CLOCK0" >"$CLOCK"
    GDIR="$ROOT/dxe/$GUEST/persist"
    CDEST="$CANON/dxe/$GUEST/persist"
    SRCVOL="$VOLROOT/dx-fix-persist"
    REC_FILE="$STATE/dxe/persist-dirs/${NAS}__$GUEST"
    set_labels dx-fix-persist persist
    set_labels dx-fix-nix nix
    build_source "$SRCVOL"
    printf '%s\n' "$INV_STD" >"$W/inv.out"
    printf '%s\n' "$V_330" >"$W/rsync-version.out"
    : >"$ROOT/$SENTINEL"
}
set_labels() { # VOLUME ROLE [PROFILE]
    printf 'true|1|%s|%s|x86_64-linux\n' "${3:-${NAS}__$GUEST}" "$2" >"$LABELS/$1"
}
inv_set() { # SED-EXPRESSION: edit the canned inventory output
    printf '%s\n' "$INV_STD" | sed "$1" >"$W/inv.out"
}
# put_marker DIR TEXT: a marker (and one data file) as an earlier run left it.
put_marker() {
    mkdir -p "$1"
    printf '%s\n' "$2" >"$1/$MARKER_NAME"
    printf 'half\n' >"$1/plain.txt"
}
marker_text() { # STATE [SOURCE [CREATED [MIGRATED [GUEST]]]]
    dx_persist_marker_format "${5:-$GUEST}" "$1" "${2:-}" "${3:-}" "${4:-}"
}

env_fakes() {
    HOME="$SCRATCH/home" XDG_STATE_HOME="$STATE" TMPDIR="$W/tmp" PATH="$CTRL:$REC:$TOOLS:/usr/bin:/bin"
    export HOME XDG_STATE_HOME TMPDIR PATH
    export DXE_RUNTIME_DOCKER_BIN=docker
    export P_EVLOG="$EVLOG" P_DDIR="$DDIR" P_LABELS="$LABELS" P_VOLROOT="$VOLROOT" P_LOCKDIR="$LOCKDIR"
    export P_SCRATCH="$SCRATCH_PHYS" P_GUARD="$GUARD" P_CLOG="$CLOG" P_SH="$SH_BIN" P_CLOCK="$CLOCK"
    export P_MVLOG="$MVLOG" P_STUBLOG="$STUBLOG" P_INV_OUT="$W/inv.out" P_RSYNC_VERSION="$W/rsync-version.out"
    export P_REAL="$REAL" P_HOST_RSYNC="$HOST_RSYNC" P_REAL_BASH="$REAL_BASH" P_REAL_SSH="$TOOLS/ssh"
    export P_SIM_COPY="$HELPERS/sim-copy.pl" P_SIM_MANIFEST="$HELPERS/sim-manifest.pl" P_MANIFEST_FILE="$MANIFEST_FILE"
    export P_PROBE_SCRIPT="$DX_RUNTIME_DOCKER_HOST_DIR_PROBE_SCRIPT" P_FREE_SCRIPT="$DX_RUNTIME_DOCKER_HOST_DIR_FREE_SCRIPT"
    export P_INVENTORY_SCRIPT="$DX_RUNTIME_DOCKER_VOLUME_INVENTORY_SCRIPT" P_ESTABLISH_SCRIPT="$DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT"
}
env_config() {
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume
    export DX_CONTAINER_NAME="$GUEST" DX_IMAGE="$IMAGE"
    export DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
    export DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT="$ROOT" DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
}

# cil [VAR=VALUE...] [@VAR=VALUE...] -- FN [ARGS...]: FN in a subshell that
# sourced bin/dx-lib.sh with this world's configuration (VAR=VALUE exported
# before dx-lib.sh is sourced, @VAR=VALUE after it). The subshell's stdout is
# appended to the event log; its stderr goes to ERR. Sets RC OUT ERR EVENTS
# T0 T1 and the BEFORE/AFTER snapshots of the share, the state directory and
# the source volume. Each call starts a fresh docker call numbering.
cil() {
    local pre=() post=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        case "$1" in
            @*) post+=("${1#@}") ;;
            *) pre+=("$1") ;;
        esac
        shift
    done
    shift
    rm -f "$DDIR"/call.* "$DDIR"/kind.* "$DDIR"/marker.*
    : >"$EVLOG"
    : >"$CLOG"
    : >"$MVLOG"
    BEFORE="$(snap "$ROOT")"
    STATE_BEFORE="$(snap "$STATE")"
    VOL_BEFORE="$(snap "$SRCVOL")"
    T0="$(utc_now)"
    (
        for _n in $DXE_CONFIG_FIELDS; do unset "$_n"; done
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PERSIST_FRESH_START DXE_RUNTIME_DOCKER_DAEMON_ID \
            DX_LEGACY_WORKSPACE_VOLUME DXE_LIFECYCLE_LOCK_OWNER DXE_LIFECYCLE_LOCK_HELD DX_PROFILES_DIR
        env_fakes
        env_config
        for _kv in "${pre[@]+"${pre[@]}"}"; do export "${_kv?}"; done
        # shellcheck source=../bin/dx-lib.sh
        source "$BASE_DIR/bin/dx-lib.sh" || exit 96
        for _kv in "${post[@]+"${post[@]}"}"; do export "${_kv?}"; done
        if ! type "$1" >/dev/null 2>&1; then
            echo "$1 is not defined" >&2
            exit 97
        fi
        "$@"
    ) >>"$EVLOG" 2>"$W/err" </dev/null
    RC=$?
    T1="$(utc_now)"
    ERR="$(cat "$W/err")"
    OUT="$(grep -v '^~EV~ ' "$EVLOG" || true)"
    EVENTS="$(sed -n 's/^~EV~ //p' "$EVLOG")"
    AFTER="$(snap "$ROOT")"
    STATE_AFTER="$(snap "$STATE")"
    VOL_AFTER="$(snap "$SRCVOL")"
}
mig() { # [VAR=VALUE...] [@VAR=VALUE...] [-- ARGS...]: dx_persist_migrate_main
    local kv=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        kv+=("$1")
        shift
    done
    [ "$#" -eq 0 ] || shift
    cil "${kv[@]+"${kv[@]}"}" -- dx_persist_migrate_main "$@"
}

# --- reading what happened ----------------------------------------------------
kind_of() { cat "$DDIR/kind.$1" 2>/dev/null; }
calls_where() { # PREFIX: the docker call numbers whose kind starts with PREFIX
    local n=1
    while [ -e "$DDIR/call.$n" ]; do
        case "$(kind_of "$n")" in "$1"*) echo "$n" ;; esac
        n=$((n + 1))
    done
}
count_kind() { calls_where "$1" | awk 'END { print NR }'; }
first_call() { calls_where "$1" | sed -n 1p; }
n_calls() { local n=0; while [ -e "$DDIR/call.$((n + 1))" ]; do n=$((n + 1)); done; echo "$n"; }
words_of() { # N: the argv of docker call N, one word per line; the word after -c as <SCRIPT>
    local w prev=""
    [ -f "$DDIR/call.$1" ] || { echo "<no call $1>"; return 0; }
    while IFS= read -r -d '' w; do
        if [ "$prev" = -c ]; then printf '<SCRIPT>\n'; else printf '%s\n' "$w"; fi
        prev="$w"
    done <"$DDIR/call.$1"
}
cword_of() { # N: the exact word after -c of docker call N
    perl -e 'local $/; my @w = split(/\0/, <STDIN>, -1); for my $i (0 .. $#w - 1) { if ($w[$i] eq "-c") { print $w[$i + 1]; exit 0 } } exit 1' <"$DDIR/call.$1"
}
line_of() { # PREFIX: the line number in the event log of the first line starting PREFIX (0: none)
    awk -v s="$1" 'index($0, s) == 1 { print NR; f = 1; exit } END { if (!f) print 0 }' "$EVLOG"
}
nas_other() { grep -cE "^nas (other|free)" <<<"$EVENTS" || true; }
write_runs() { grep -cE "^docker run (establish|marker-set|rsync-copy)" <<<"$EVENTS" || true; }

# expected argv (one word per line, <SCRIPT> for the word after -c)
argv_establish() { # ROOT MODE
    printf '%s\n' run --rm -i --network none --user 0:0 --pull never --mount \
        "type=bind,source=$1,target=/dxe-share" --entrypoint sh "$IMAGE" -c '<SCRIPT>' sh \
        /dxe-share "$GUEST" "$2" "$OWNER_PIN" "$SENTINEL"
}
argv_marker_set() { # ROOT GUEST EXPECTED SOURCE
    printf '%s\n' run --rm -i --network none --user 0:0 --pull never --mount \
        "type=bind,source=$1,target=/dxe-share" --entrypoint sh "$IMAGE" -c '<SCRIPT>' sh \
        /dxe-share "$2" "$3" "$4"
}
# WP6.4c: the copy and verify containers' names and DQ6 labels, before --entrypoint.
COPY_ID=(--name "dxe-persist-copy-${NAS}__$GUEST" --label io.dxe.managed=true --label io.dxe.schema=1
    --label "io.dxe.profile=${NAS}__$GUEST" --label io.dxe.role=persist-copy --label io.dxe.system=x86_64-linux)
VERIFY_ID=(--name "dxe-persist-verify-${NAS}__$GUEST" --label io.dxe.managed=true --label io.dxe.schema=1
    --label "io.dxe.profile=${NAS}__$GUEST" --label io.dxe.role=persist-verify --label io.dxe.system=x86_64-linux)
argv_rsync() { # DIR [-A] [-X]
    local dir="$1"
    shift
    printf '%s\n' run --rm --network none --user 0:0 --pull never -v dx-fix-nix:/nix:ro \
        -v dx-fix-persist:/src:ro --mount "type=bind,source=$dir,target=/dst" "${COPY_ID[@]}" --entrypoint "$RSYNC_EP" "$IMAGE" \
        -aH --numeric-ids --inplace --modify-window=-1 "$@" --exclude=/.dxe-persist-dir '--exclude=._*' /src/ /dst/
}
argv_manifest() { # forward|reverse VOLUME DIR
    if [ "$1" = forward ]; then
        printf '%s\n' run --rm --network none --user 0:0 --pull never -v "$2:/src:ro" \
            --mount "type=bind,source=$3,target=/dst,readonly" "${VERIFY_ID[@]}" --entrypoint bash "$IMAGE" -c '<SCRIPT>' \
            dx-persist-manifest verify /src /dst
    else
        printf '%s\n' run --rm --network none --user 0:0 --pull never \
            --mount "type=bind,source=$3,target=/src,readonly" -v "$2:/dst:ro" "${VERIFY_ID[@]}" --entrypoint bash "$IMAGE" -c '<SCRIPT>' \
            dx-persist-manifest verify /src /dst
    fi
}
expect_argv() { # LABEL KIND EXPECTED: the one docker call of KIND has exactly EXPECTED
    local label="$1" n got
    n="$(first_call "$2")"
    if [ -z "$n" ]; then
        test_fail "$label (no [$2] call; events: $(tr '\n' '|' <<<"$EVENTS"))"
        return 0
    fi
    got="$(words_of "$n")"
    if [ "$got" = "$3" ]; then test_pass "$label"; else test_fail "$label (got: $(tr '\n' ' ' <<<"$got"))"; fi
}
manifest_text_ok() { # N: the -c word of call N is the manifest tool's text
    local want got
    want="$(cat "$MANIFEST_FILE")"
    got="$(cword_of "$1")"
    [ -n "$got" ] && [ "$got" = "$want" ]
}

# expect_no_write LABEL: nothing written anywhere (share, state, volume), no
# container that writes ran, nothing chowned, no NAS-shell call but the probe.
expect_no_write() {
    local label="$1"
    if [ "$BEFORE" = "$AFTER" ]; then test_pass "$label: the share is unchanged"
    else test_fail "$label: the share is unchanged (before: $(tr '\n' '|' <<<"$BEFORE") | after: $(tr '\n' '|' <<<"$AFTER"))"; fi
    if [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then test_pass "$label: the state directory (the D-7 record) is unchanged"
    else test_fail "$label: the state directory (the D-7 record) is unchanged"; fi
    if [ "$VOL_BEFORE" = "$VOL_AFTER" ]; then test_pass "$label: the source volume is unchanged"
    else test_fail "$label: the source volume is unchanged"; fi
    eq "$label: no establish, rsync copy or marker-set run" 0 "$(write_runs)"
    eq "$label: no manifest run" 0 "$(count_kind 'run manifest')"
    if grep -q '^chown' "$CLOG"; then test_fail "$label: nothing was chowned"; else test_pass "$label: nothing was chowned"; fi
    eq "$label: no NAS-shell call other than the probe" 0 "$(nas_other)"
}

# expect_refused LABEL KEYWORD...: exit 1, exactly one Error line (stderr)
# naming every KEYWORD, no report, nothing written, the lock released.
expect_refused() {
    local label="$1" k line
    shift
    eq "$label: exit 1" 1 "$RC"
    if [ "$(error_lines "$ERR")" = 1 ] && [ "$(error_lines "$OUT")" = 0 ]; then
        test_pass "$label: exactly one Error: line, on stderr"
    else
        test_fail "$label: exactly one Error: line, on stderr (stderr: $ERR | stdout: $OUT)"
    fi
    line="$(grep '^Error:' <<<"$ERR" || true)"
    for k in "$@"; do
        if grep -Fq -- "$k" <<<"$line"; then test_pass "$label: the Error line names [$k]"
        else test_fail "$label: the Error line names [$k] (stderr: $ERR)"; fi
    done
    lacks "$label: no report" "$OUT" "migrated:"
    expect_no_write "$label"
    expect_lock_released "$label"
}
expect_lock_released() { # LABEL: the lock was the first effect and its release the last
    eq "$1: the lifecycle lock was taken first" "docker lock" "$(sed -n 1p <<<"$EVENTS")"
    eq "$1: the lifecycle lock was released last" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"
    not "$1: the lock is not left held" test -e "$LOCKDIR/held"
}
expect_no_call() { # LABEL: no runtime call at all (no lock, ssh or docker)
    eq "$1: no runtime call at all" "" "$EVENTS"
    eq "$1: no docker call" 0 "$(n_calls)"
}

# expect_marker_exact LABEL FILE STATE CREATED [MIGRATED]
expect_marker_exact() {
    local want
    want="$(marker_text "$3" dx-fix-persist "$4" "${5:-}")"
    if [ -f "$2" ] && [ ! -L "$2" ] && [ "$(cat "$2")" = "$want" ] && [ "$(tail -c 1 "$2" | od -An -c | tr -d ' ')" = '\n' ]; then
        test_pass "$1"
    else
        test_fail "$1 (got: $(tr '\n' '|' <"$2" 2>/dev/null); want: $(tr '\n' '|' <<<"$want"))"
    fi
}
marker_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
in_window() { # T: a valid UTC timestamp within this call's T0..T1
    dx_persist_marker_valid_timestamp "$1" && not_after "$T0" "$1" && not_after "$1" "$T1"
}
expect_record() { # LABEL CREATED [ROOT]
    local label="$1" want movers tmp_file
    want="$(printf 'schema=1\nguest=%s\nroot=%s\nmode=migrate\ncreated-at=%s' "$GUEST" "${3:-$ROOT}" "$2")"
    if [ -f "$REC_FILE" ] && [ "$(cat "$REC_FILE")" = "$want" ]; then
        test_pass "$label: the D-7 record is exactly schema/guest/root/mode=migrate/created-at"
    else
        test_fail "$label: the D-7 record is exactly schema/guest/root/mode=migrate/created-at (got: $(tr '\n' '|' <"$REC_FILE" 2>/dev/null))"
    fi
    eq "$label: the record's mode is 0600" 600 "$(file_mode "$REC_FILE" 2>/dev/null)"
    movers="$(awk -v r="$REC_FILE" '{ n = split($0, w, " "); if (n >= 2 && w[n] == r) c++ } END { print c + 0 }' "$MVLOG")"
    tmp_file="$(awk -v r="$REC_FILE" '{ n = split($0, w, " "); if (n >= 2 && w[n] == r) print w[n - 1] }' "$MVLOG" | head -n 1)"
    if [ "$movers" = 1 ] && [ "${tmp_file%/*}" = "${REC_FILE%/*}" ] && [ ! -e "$tmp_file" ]; then
        test_pass "$label: the record arrives by ONE mv from a temp file in its own directory"
    else
        test_fail "$label: the record arrives by ONE mv from a temp file in its own directory (mv log: $(tr '\n' '|' <"$MVLOG"))"
    fi
}
# expect_report LABEL COPY VERIFY [APPLE...]: the last lines of stdout.
expect_report() {
    local label="$1" copy="$2" verify="$3" want tail_n got next a
    shift 3
    want="$(
        printf 'migrated: %s\n' "$CDEST"
        printf 'source_volume: dx-fix-persist\n'
        printf 'marker: ready\n'
        printf 'record: %s\n' "$REC_FILE"
        printf 'copy_seconds: %s\n' "$copy"
        printf 'verify_seconds: %s\n' "$verify"
        printf 'appledouble_dropped_count: %s\n' "$#"
        if [ "$#" -eq 0 ]; then printf 'appledouble_dropped: none\n'; fi
        for a in "$@"; do printf 'appledouble_dropped: %s\n' "$a"; done
    )"
    tail_n="$(($(printf '%s\n' "$want" | awk 'END { print NR }') + 1))"
    got="$(printf '%s\n' "$OUT" | tail -n "$tail_n" | sed '$d')"
    next="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [ "$got" = "$want" ]; then test_pass "$label: the report ends stdout with the pinned lines"
    else test_fail "$label: the report ends stdout with the pinned lines (stdout: $(tr '\n' '|' <<<"$OUT"))"; fi
    case "$next" in
        "next: "*) test_pass "$label: the report's last line is the next step" ;;
        *) test_fail "$label: the report's last line is the next step (got [$next])" ;;
    esac
    has "$label: the next step names DX_PERSIST_STORAGE=host-path" "$next" "DX_PERSIST_STORAGE=host-path"
    has "$label: the next step names dx-recreate" "$next" "dx-recreate"
}
# expect_tree LABEL: the destination holds the source's data, without the
# ._* files and without the volume's stray marker.
expect_tree() {
    local label="$1"
    eq "$label: plain.txt was copied" plain "$(cat "$GDIR/plain.txt" 2>/dev/null)"
    eq "$label: a deep file was copied" deep "$(cat "$GDIR/nested/a/b/c/deep.txt" 2>/dev/null)"
    eq "$label: a symlink was copied as a symlink" ../plain.txt "$(readlink "$GDIR/links/to-plain" 2>/dev/null)"
    not "$label: ._root-meta was dropped" test -e "$GDIR/._root-meta"
    not "$label: nested/a/._deep-meta was dropped" test -e "$GDIR/nested/a/._deep-meta"
    if grep -Fqx 'volume-marker' "$GDIR/$MARKER_NAME" 2>/dev/null; then
        test_fail "$label: the volume's own .dxe-persist-dir did not replace the marker"
    else
        test_pass "$label: the volume's own .dxe-persist-dir did not replace the marker"
    fi
}
# expect_volume_mounts_safe LABEL: every -v of every run is :ro and follows a
# DQ6 inspect of that volume made earlier in the same invocation.
expect_volume_mounts_safe() {
    local label="$1" n=1 seen=" " w prev kind bad_ro="" bad_dq6=""
    while [ -e "$DDIR/call.$n" ]; do
        kind="$(kind_of "$n")"
        case "$kind" in
            "dq6 "*) seen="$seen${kind#dq6 } " ;;
            "run "*)
                prev=""
                while IFS= read -r w; do
                    if [ "$prev" = -v ]; then
                        case "$w" in *:ro) : ;; *) bad_ro="$bad_ro $n:$w" ;; esac
                        case "$seen" in *" ${w%%:*} "*) : ;; *) bad_dq6="$bad_dq6 $n:${w%%:*}" ;; esac
                    fi
                    prev="$w"
                done <<<"$(words_of "$n")"
                ;;
        esac
        n=$((n + 1))
    done
    eq "$label: every named volume is mounted read-only (:ro)" "" "$bad_ro"
    eq "$label: every mounted volume had its DQ6 check first" "" "$bad_dq6"
}
expect_never_started() { # LABEL: no docker call besides the classified ones (no start, create or rm of the guest)
    eq "$1: no unexpected docker call (the guest is never started)" "" "$(grep -E "^docker (other|run unexpected|run bad-mount|run refused-outside|run no-volume|run missing-bind)" <<<"$EVENTS" || true)"
}

# The WP4.3 decision in host-path mode, after a migration run, as
# dx-start-container and dx-create-volumes reach it.
start_check() { cil DX_PERSIST_STORAGE=host-path -- dx_persist_start_check; }
create_check() { cil DX_PERSIST_STORAGE=host-path -- dx_persist_create_decision; }

# =============================================================================
test_section "WP6.4: the new runtime operations are declared and implemented"
for op in container_state host_dir_marker_set host_manifest_verify; do
    if type "dx_runtime_$op" >/dev/null 2>&1; then test_pass "dx_runtime_$op is declared (dx-runtime.sh)"
    else test_fail "dx_runtime_$op is declared (dx-runtime.sh)"; fi
    for adapter in docker apple; do
        if type "dx_runtime_${adapter}_$op" >/dev/null 2>&1; then test_pass "dx_runtime_${adapter}_$op is implemented"
        else test_fail "dx_runtime_${adapter}_$op is implemented"; fi
    done
done

# -----------------------------------------------------------------------------
test_section "WP6.4 J1: dx_runtime_container_state"
world
for pair in running:running stopped:stopped absent:absent object:absent; do
    cil P_GUEST_STATE="${pair%%:*}" -- dx_runtime_container_state "$GUEST"
    eq "container_state, docker says ${pair%%:*}: prints ${pair#*:}" "${pair#*:}" "$OUT"
    eq "container_state, docker says ${pair%%:*}: status 0" 0 "$RC"
done
eq "container_state: exactly one docker call" 1 "$(n_calls)"
eq "container_state: the argv is container inspect --format {{.State.Running}} NAME" \
    "$(printf '%s\n' container inspect --format '{{.State.Running}}' "$GUEST")" "$(words_of 1)"
cil P_GUEST_STATE=down -- dx_runtime_container_state "$GUEST"
eq "container_state, daemon unreachable: prints unknown" unknown "$OUT"
if [ "$RC" -ne 0 ]; then test_pass "container_state, daemon unreachable: non-zero"; else test_fail "container_state, daemon unreachable: non-zero"; fi
eq "container_state, daemon unreachable: no Error: line (the caller's refusal is the only one)" 0 "$(error_lines "$ERR")"

# -----------------------------------------------------------------------------
test_section "WP6.4 J2: dx_runtime_host_dir_marker_set"
COPYING_T=2026-10-01T10:00:00Z
READY_M=2026-10-01T11:00:00Z
READY_TEXT="$(marker_text ready dx-fix-persist "$COPYING_T" "$READY_M")"

# Success: copying -> ready, compare-and-set.
world
put_marker "$GDIR" "$(marker_text copying dx-fix-persist "$COPYING_T")"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
eq "marker_set copying->ready: status 0" 0 "$RC"
eq "marker_set: nothing on stdout" "" "$OUT"
eq "marker_set: exactly one docker call" 1 "$(n_calls)"
eq "marker_set: it is classified as the marker-set run" "run marker-set copying" "$(kind_of 1)"
eq "marker_set: the argv is exactly the pinned 21 words" "$(argv_marker_set "$CANON" "$GUEST" copying dx-fix-persist)" "$(words_of 1)"
expect_marker_exact "marker_set: the marker now holds exactly the new text" "$GDIR/$MARKER_NAME" ready "$COPYING_T" "$READY_M"
eq "marker_set: the marker's mode is 0644" 644 "$(file_mode "$GDIR/$MARKER_NAME")"
eq "marker_set: exactly one mv in the container, from a temp in the leaf onto the marker" \
    "1" "$(grep -c "^mv @/dxe/$GUEST/persist/[^ /]* @/dxe/$GUEST/persist/$MARKER_NAME\$" "$CLOG" || true)"
eq "marker_set: no other mv in the container" 1 "$(grep -c '^mv' "$CLOG" || true)"
if grep -q '^chown' "$CLOG"; then test_fail "marker_set: nothing chowned"; else test_pass "marker_set: nothing chowned"; fi
if grep -q REFUSED "$CLOG"; then test_fail "marker_set: no recursive or out-of-share tool use"; else test_pass "marker_set: no recursive or out-of-share tool use"; fi
eq "marker_set: the leaf holds only the marker and its data (no temp file left)" \
    "$(printf './%s\n./plain.txt' "$MARKER_NAME")" "$(entries_of "$GDIR")"
SCRIPT1="$(cword_of 1 2>/dev/null || true)"
NL=$'\n'
case "$SCRIPT1" in
    "" | *"$NL"*) test_fail "marker_set: SCRIPT is a single line" ;;
    *) test_pass "marker_set: SCRIPT is a single line" ;;
esac
lacks "marker_set: SCRIPT names no data word (guest)" "$SCRIPT1" "$GUEST"
lacks "marker_set: SCRIPT names no data word (bind target)" "$SCRIPT1" "/dxe-share"
printf '%s\n' "$SCRIPT1" >"$SCRATCH/marker-set-script.sh"
ok "marker_set: SCRIPT passes sh -n" "$SH_BIN" -n "$SCRATCH/marker-set-script.sh"
if [ -n "$DASH_BIN" ]; then ok "marker_set: SCRIPT passes dash -n" "$DASH_BIN" -n "$SCRATCH/marker-set-script.sh"; fi

# ready -> retired with another guest and source: the same constant SCRIPT.
world
put_marker "$GDIR" "$(marker_text ready dx-fix-persist "$COPYING_T" "$READY_M")"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" ready \
    "$(dx_persist_marker_format "$GUEST" retired dx-fix-persist "$COPYING_T" "$READY_M" 2026-10-02T09:00:00Z)"
eq "marker_set ready->retired: status 0" 0 "$RC"
eq "marker_set ready->retired: state is retired" retired "$(marker_field "$GDIR/$MARKER_NAME" state)"
eq "marker_set: SCRIPT is the same constant text for another transition" "$SCRIPT1" "$(cword_of 1 2>/dev/null || true)"

# Both without a source volume: allowed (both absent counts as equal).
world
put_marker "$GDIR" "$(marker_text copying "" "$COPYING_T")"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$(marker_text ready "" "$COPYING_T" "$READY_M")"
eq "marker_set without a source on either side: status 0" 0 "$RC"
eq "marker_set without a source: the SOURCE word is empty" "" "$(words_of 1 | sed -n 21p)"
eq "marker_set without a source: state is ready" ready "$(marker_field "$GDIR/$MARKER_NAME" state)"

# In-container refusals: nothing is written.
ms_refused() { # LABEL: after a cil call
    if [ "$RC" -ne 0 ]; then test_pass "$1: non-zero"; else test_fail "$1: non-zero"; fi
    eq "$1: exactly one docker run" 1 "$(count_kind 'run ')"
    if [ "$BEFORE" = "$AFTER" ]; then test_pass "$1: the share is unchanged"; else test_fail "$1: the share is unchanged (after: $(tr '\n' '|' <<<"$AFTER"))"; fi
    eq "$1: no mv in the container" 0 "$(grep -c '^mv' "$CLOG" || true)"
    eq "$1: nothing on stdout" "" "$OUT"
}
for case_ in "ready:$GUEST:dx-fix-persist:current state is not the expected one" \
    "copying:dx-other:dx-fix-persist:current marker names another guest" \
    "copying:dx-fix2:dx-fix-persist:current guest only shares a prefix" \
    "copying:$GUEST:dx-other-persist:current source volume differs" \
    "copying:$GUEST::current marker has no source volume"; do
    IFS=: read -r c_state c_guest c_src c_label <<<"$case_"
    world
    put_marker "$GDIR" "$(marker_text "$c_state" "$c_src" "$COPYING_T" "" "$c_guest")"
    cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
    ms_refused "marker_set refuses ($c_label)"
done
world
mkdir -p "$GDIR"
printf 'data\n' >"$GDIR/plain.txt"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
ms_refused "marker_set refuses (no marker)"
not "marker_set (no marker): no marker was created" test -e "$GDIR/$MARKER_NAME"
world
mkdir -p "$W/elsewhere" "$ROOT/dxe/$GUEST"
printf '%s\n' "$(marker_text copying dx-fix-persist "$COPYING_T")" >"$W/elsewhere/$MARKER_NAME"
ln -s "$W/elsewhere" "$GDIR"
EL_BEFORE="$(snap "$W/elsewhere")"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
ms_refused "marker_set refuses (the leaf is a symlink)"
eq "marker_set (leaf symlink): nothing written through it" "$EL_BEFORE" "$(snap "$W/elsewhere")"
world
mkdir -p "$W/elsewhere/persist" "$ROOT/dxe"
printf '%s\n' "$(marker_text copying dx-fix-persist "$COPYING_T")" >"$W/elsewhere/persist/$MARKER_NAME"
ln -s "$W/elsewhere" "$ROOT/dxe/$GUEST"
EL_BEFORE="$(snap "$W/elsewhere")"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
ms_refused "marker_set refuses (dxe/<guest> is a symlink)"
eq "marker_set (guest symlink): nothing written through it" "$EL_BEFORE" "$(snap "$W/elsewhere")"
world
mkdir -p "$GDIR"
printf '%s\n' "$(marker_text copying dx-fix-persist "$COPYING_T")" >"$W/marker-target"
ln -s "$W/marker-target" "$GDIR/$MARKER_NAME"
cil -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
ms_refused "marker_set refuses (the marker is a symlink)"
eq "marker_set (marker symlink): its target is untouched" copying "$(marker_field "$W/marker-target" state)"

# Refusals before any call.
ms_precall() { # LABEL ARGS...
    local label="$1"
    shift
    cil -- dx_runtime_host_dir_marker_set "$@"
    eq "$label: status 1" 1 "$RC"
    expect_no_call "$label"
    eq "$label: nothing on stdout" "" "$OUT"
    if [ -n "$ERR" ] && [ "$(error_lines "$ERR")" = 0 ]; then test_pass "$label: a reason on stderr, not an Error: line"
    else test_fail "$label: a reason on stderr, not an Error: line (stderr: $ERR)"; fi
}
world
put_marker "$GDIR" "$(marker_text copying dx-fix-persist "$COPYING_T")"
ms_precall "marker_set, empty ROOT" "" "$GUEST" copying "$READY_TEXT"
ms_precall "marker_set, relative ROOT" "share" "$GUEST" copying "$READY_TEXT"
ms_precall "marker_set, ROOT with a comma" "$CANON,readonly=false" "$GUEST" copying "$READY_TEXT"
ms_precall "marker_set, ROOT with a newline" "$CANON
/x" "$GUEST" copying "$READY_TEXT"
ms_precall "marker_set, invalid GUEST" "$CANON" "-bad" copying "$READY_TEXT"
ms_precall "marker_set, GUEST with a slash" "$CANON" "a/b" copying "$READY_TEXT"
ms_precall "marker_set, unknown EXPECTED_STATE" "$CANON" "$GUEST" finished "$READY_TEXT"
ms_precall "marker_set, invalid MARKER_TEXT" "$CANON" "$GUEST" copying "hello"
ms_precall "marker_set, MARKER_TEXT for another guest" "$CANON" "$GUEST" copying \
    "$(marker_text ready dx-fix-persist "$COPYING_T" "$READY_M" dx-other)"
ms_precall "marker_set, three arguments" "$CANON" "$GUEST" copying
cil @DX_IMAGE= -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
eq "marker_set, empty DX_IMAGE: status 1" 1 "$RC"
expect_no_call "marker_set, empty DX_IMAGE"
cil DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image -- dx_runtime_host_dir_marker_set "$CANON" "$GUEST" copying "$READY_TEXT"
if [ "$RC" -ne 0 ]; then test_pass "marker_set, Apple: non-zero"; else test_fail "marker_set, Apple: non-zero"; fi
has "marker_set, Apple: unsupported" "$ERR" "unsupported"
expect_no_call "marker_set, Apple"

# -----------------------------------------------------------------------------
test_section "WP6.4 J3: dx_runtime_host_manifest_verify"
world
mkdir -p "$GDIR"
cil P_MANIFEST_FORCE_RC=0 -- dx_runtime_host_manifest_verify forward dx-fix-persist "$CDEST"
eq "manifest_verify forward: status passes through (0)" 0 "$RC"
eq "manifest_verify forward: stdout passes through" "Manifests match: entries=7" "$OUT"
eq "manifest_verify forward: exactly two docker calls" 2 "$(n_calls)"
eq "manifest_verify forward: the first is the volume's DQ6 inspect" "dq6 dx-fix-persist" "$(kind_of 1)"
eq "manifest_verify forward: the argv is exactly the pinned one" "$(argv_manifest forward dx-fix-persist "$CDEST")" "$(words_of 2)"
if manifest_text_ok 2; then test_pass "manifest_verify: the inline script is the manifest tool's text (D-8)"
else test_fail "manifest_verify: the inline script is the manifest tool's text (D-8)"; fi
cil P_MANIFEST_FORCE_RC=1 -- dx_runtime_host_manifest_verify forward dx-fix-persist "$CDEST"
eq "manifest_verify: a difference passes through (1)" 1 "$RC"
has "manifest_verify: the difference report passes through" "$OUT" "Manifests differ"
cil P_MANIFEST_FORCE_RC=2 -- dx_runtime_host_manifest_verify forward dx-fix-persist "$CDEST"
eq "manifest_verify: an error passes through (2)" 2 "$RC"
has "manifest_verify: the tool's error passes through" "$ERR" "cannot read manifest"
cil P_MANIFEST_FORCE_RC=0 -- dx_runtime_host_manifest_verify reverse dx-fix-persist "$CDEST"
eq "manifest_verify reverse: status 0" 0 "$RC"
eq "manifest_verify reverse: the argv is exactly the pinned one" "$(argv_manifest reverse dx-fix-persist "$CDEST")" "$(words_of 2)"
set_labels dx-fix-persist persist other-host__other-guest
cil P_MANIFEST_FORCE_RC=0 -- dx_runtime_host_manifest_verify forward dx-fix-persist "$CDEST"
eq "manifest_verify, another profile's volume: refused (status 1)" 1 "$RC"
eq "manifest_verify, another profile's volume: the only docker call is its DQ6 inspect" "dq6 dx-fix-persist" "$(kind_of 1)$(n_calls | sed 's/^1$//')"
eq "manifest_verify, another profile's volume: no run" 0 "$(count_kind 'run ')"
set_labels dx-fix-persist persist
mv_precall() { # LABEL ARGS...
    local label="$1"
    shift
    cil P_MANIFEST_FORCE_RC=0 @PATH="$STUBS:$CTRL:$REC:$TOOLS:/usr/bin:/bin" -- dx_runtime_host_manifest_verify "$@"
    eq "$label: refused (status 1)" 1 "$RC"
    expect_no_call "$label"
    eq "$label: nothing on stdout" "" "$OUT"
}
mv_precall "manifest_verify, unknown direction" sideways dx-fix-persist "$CDEST"
mv_precall "manifest_verify, relative DIR" forward dx-fix-persist "share/dxe"
mv_precall "manifest_verify, DIR is /" forward dx-fix-persist /
mv_precall "manifest_verify, DIR with a comma" forward dx-fix-persist "$CDEST,readonly=false"
mv_precall "manifest_verify, DIR with a newline" forward dx-fix-persist "$CDEST
/x"
mv_precall "manifest_verify, two arguments" forward dx-fix-persist
eq "manifest_verify refusals: no destructive stub was reached" "" "$(cat "$STUBLOG")"
cil DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image -- dx_runtime_host_manifest_verify forward dx-fix-persist "$CDEST"
if [ "$RC" -ne 0 ]; then test_pass "manifest_verify, Apple: non-zero"; else test_fail "manifest_verify, Apple: non-zero"; fi
has "manifest_verify, Apple: unsupported" "$ERR" "unsupported"
expect_no_call "manifest_verify, Apple"

# =============================================================================
test_section "WP6.4 A, C: the command's surface and its refusals before any call"
world
for flag in -h --help; do
    mig -- "$flag"
    eq "dx-persist-migrate $flag: exit 0" 0 "$RC"
    case "$(sed -n 1p <<<"$OUT")" in
        "Usage: dx-persist-migrate"*) test_pass "dx-persist-migrate $flag: usage on stdout" ;;
        *) test_fail "dx-persist-migrate $flag: usage on stdout (got: $OUT)" ;;
    esac
    expect_no_call "dx-persist-migrate $flag"
done
for bad in extra --resume -x; do
    mig -- "$bad"
    eq "dx-persist-migrate $bad: exit 2 (usage)" 2 "$RC"
    has "dx-persist-migrate $bad: Usage: on stderr" "$ERR" "Usage:"
    eq "dx-persist-migrate $bad: nothing on stdout" "" "$OUT"
    expect_no_call "dx-persist-migrate $bad"
done
config_refused() { # LABEL KEYWORD
    eq "$1: exit 1" 1 "$RC"
    eq "$1: exactly one Error: line" 1 "$(error_lines "$ERR")"
    has "$1: the Error names [$2]" "$(grep '^Error:' <<<"$ERR" || true)" "$2"
    expect_no_call "$1"
    if [ "$BEFORE" = "$AFTER" ] && [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then test_pass "$1: nothing written"; else test_fail "$1: nothing written"; fi
}
mig DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image
config_refused "not docker-ssh" "DX_RUNTIME=docker-ssh"
mig DX_PERSIST_HOST_ROOT=
config_refused "no DX_PERSIST_HOST_ROOT" "DX_PERSIST_HOST_ROOT"
mig DX_PERSIST_HOST_MOUNT_SENTINEL=
config_refused "no DX_PERSIST_HOST_MOUNT_SENTINEL" "DX_PERSIST_HOST_MOUNT_SENTINEL"
mig @XDG_STATE_HOME= @HOME=
config_refused "the record path cannot be formed" "record"
if [ -x "$WRAPPER" ]; then test_pass "bin/dx-persist-migrate exists and is executable"; else test_fail "bin/dx-persist-migrate exists and is executable"; fi
(
    env_fakes
    env_config
    bash "$WRAPPER" --help
) >"$W/wrap.out" 2>"$W/wrap.err" </dev/null
eq "bin/dx-persist-migrate --help: exit 0" 0 "$?"
has "bin/dx-persist-migrate --help: usage" "$(cat "$W/wrap.out")" "Usage: dx-persist-migrate"
(
    env_fakes
    env_config
    bash "$WRAPPER" extra
) >"$W/wrap.out" 2>"$W/wrap.err" </dev/null
eq "bin/dx-persist-migrate extra: exit 2" 2 "$?"

# =============================================================================
test_section "WP6.4 E: the happy path and its order of effects"
world
mig
eq "happy path: exit 0" 0 "$RC"
eq "happy path: no Error: line" 0 "$(error_lines "$(printf "%s\n%s" "$ERR" "$OUT")")"
eq "happy path: the first effect is the lock" "docker lock" "$(sed -n 1p <<<"$EVENTS")"
eq "happy path: the first call after the lock is the guest-state check" "docker guest-state $GUEST" "$(sed -n 2p <<<"$EVENTS")"
expect_argv "happy path: the guest-state argv" "guest-state" "$(printf '%s\n' container inspect --format '{{.State.Running}}' "$GUEST")"
L_STATE="$(line_of "~EV~ docker guest-state")"
L_EST="$(line_of "~EV~ docker run establish create")"
for pre in "~EV~ docker dq6 dx-fix-persist" "~EV~ docker dq6 dx-fix-nix" "~EV~ nas probe" \
    "~EV~ docker run inventory" "~EV~ docker run rsync-version"; do
    at="$(line_of "$pre")"
    if [ "$at" -gt "$L_STATE" ] && [ "$at" -lt "$L_EST" ]; then
        test_pass "happy path: [${pre#\~EV\~ }] comes after the guest check and before the destination is created"
    else
        test_fail "happy path: [${pre#\~EV\~ }] comes after the guest check and before the destination is created (at $at; guest $L_STATE; establish $L_EST)"
    fi
done
prev=0
order_ok=yes
trail=""
for step in "~EV~ docker run establish create" "~EV~ docker run rsync-copy" "~EV~ docker run manifest" \
    "~EV~ docker run marker-set copying" "~EV~ ctrl-mv $REC_FILE" "migrated: " "~EV~ docker unlock"; do
    at="$(line_of "$step")"
    trail="$trail [${step#\~EV\~ }]@$at"
    if [ "$at" -eq 0 ] || [ "$at" -le "$prev" ]; then order_ok=no; fi
    prev="$at"
done
if [ "$order_ok" = yes ]; then
    test_pass "happy path: destination+copying marker, rsync, manifest compare, marker ready, record, report, unlock -- in that order"
else
    test_fail "happy path: destination+copying marker, rsync, manifest compare, marker ready, record, report, unlock -- in that order ($trail)"
fi
eq "happy path: the lock is released last" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"
for k in "run establish" "run rsync-copy" "run manifest" "run marker-set"; do
    eq "happy path: exactly one [$k]" 1 "$(count_kind "$k")"
done
eq "happy path: the only NAS-shell call is the probe" "nas probe" "$(grep '^nas ' <<<"$EVENTS" | sort -u)"
expect_argv "happy path: establish (create) with the CANONICAL root, the pinned owner and the sentinel" \
    "run establish" "$(argv_establish "$CANON" create)"
expect_argv "happy path: rsync forward into the canonical destination, no -A/-X (acl=0 xattr=0)" \
    "run rsync-copy" "$(argv_rsync "$CDEST")"
expect_argv "happy path: the manifest verify (read-only)" "run manifest" "$(argv_manifest forward dx-fix-persist "$CDEST")"
if manifest_text_ok "$(first_call 'run manifest')"; then test_pass "happy path: the verification runs the WP6.1 manifest tool"
else test_fail "happy path: the verification runs the WP6.1 manifest tool"; fi
expect_argv "happy path: marker-set copying -> ready on the canonical root" \
    "run marker-set" "$(argv_marker_set "$CANON" "$GUEST" copying dx-fix-persist)"
EST_N="$(first_call 'run establish')"
TC="$(marker_field "$DDIR/marker.$EST_N" created-at)"
expect_marker_exact "happy path: the destination was created with exactly the copying marker" "$DDIR/marker.$EST_N" copying "$TC"
if in_window "$TC"; then test_pass "happy path: the copying marker's created-at was taken during the run"
else test_fail "happy path: the copying marker's created-at was taken during the run ([$TC] not in $T0..$T1)"; fi
TM="$(marker_field "$GDIR/$MARKER_NAME" migrated-at)"
expect_marker_exact "happy path: the final marker is exactly ready, with source-volume, created-at and migrated-at" "$GDIR/$MARKER_NAME" ready "$TC" "$TM"
if in_window "$TM" && not_after "$TC" "$TM"; then test_pass "happy path: migrated-at was taken during the run, not before created-at"
else test_fail "happy path: migrated-at was taken during the run, not before created-at ([$TM])"; fi
expect_record "happy path" "$TC"
expect_report "happy path" 100 30 ._root-meta nested/a/._deep-meta
expect_tree "happy path"
eq "happy path: one chown, by establish, of the leaf to the pinned owner" "chown $OWNER_PIN @/dxe/$GUEST/persist" \
    "$(grep '^chown' "$CLOG" | tr '\n' '|' | sed 's/|$//')"
eq "happy path: two mv onto the marker in containers (copying, then ready)" 2 \
    "$(grep -c "^mv .* @/dxe/$GUEST/persist/$MARKER_NAME\$" "$CLOG" || true)"
if grep -q REFUSED "$CLOG"; then test_fail "happy path: no recursive or out-of-share tool use"; else test_pass "happy path: no recursive or out-of-share tool use"; fi
if [ "$VOL_BEFORE" = "$VOL_AFTER" ]; then test_pass "happy path: the source volume is unchanged"; else test_fail "happy path: the source volume is unchanged"; fi
expect_volume_mounts_safe "happy path"
expect_never_started "happy path"
not "happy path: the lock is not left held" test -e "$LOCKDIR/held"
start_check
eq "after the migration, the WP4.3 start decision (host-path) is ok" 0 "$RC"
create_check
eq "after the migration, dx-create-volumes' decision (host-path) is ok" 0 "$RC"
eq "after the migration, dx-create-volumes' decision token" ok "$(sed -n 1p <<<"$OUT")"

# =============================================================================
test_section "WP6.4 E2, E1: -A/-X from the inventory; an absent guest; a symlinked root"
world
inv_set 's/^acl=0$/acl=unknown/;s/^xattr=0$/xattr=unknown/;/^apple=/d;s/^appledouble=2$/appledouble=0/'
mig P_GUEST_STATE=absent
eq "acl=unknown xattr=unknown, guest container absent: exit 0" 0 "$RC"
expect_argv "unknown ACLs/xattrs: rsync gets -A -X" "run rsync-copy" "$(argv_rsync "$CDEST" -A -X)"
expect_report "no ._* files" 100 30
world
ln -s "$ROOT" "$W/share-link"
inv_set 's/^acl=0$/acl=4/'
mig DX_PERSIST_HOST_ROOT="$W/share-link"
eq "acl=4 xattr=0, configured root is a symlink: exit 0" 0 "$RC"
expect_argv "ACLs present: rsync gets -A only" "run rsync-copy" "$(argv_rsync "$CDEST" -A)"
expect_argv "a symlinked root: establish binds the canonical root" "run establish" "$(argv_establish "$CANON" create)"
expect_argv "a symlinked root: marker-set uses the canonical root" "run marker-set" "$(argv_marker_set "$CANON" "$GUEST" copying dx-fix-persist)"
expect_argv "a symlinked root: the verification reads the canonical destination" "run manifest" "$(argv_manifest forward dx-fix-persist "$CDEST")"
expect_record "a symlinked root (the record keeps the configured root)" "$(marker_field "$GDIR/$MARKER_NAME" created-at)" "$W/share-link"
world
inv_set 's/^xattr=0$/xattr=12/'
printf '%s\n' "$V_NOACL" >"$W/rsync-version.out"
mig
eq "acl=0 xattr=12, an rsync without ACLs: exit 0 (ACLs not needed)" 0 "$RC"
expect_argv "xattrs present: rsync gets -X only" "run rsync-copy" "$(argv_rsync "$CDEST" -X)"

# =============================================================================
test_section "WP6.4 E1, D: refusals -- the guest and the lock"
world
mig P_GUEST_STATE=running
expect_refused "the guest is running" "$GUEST" "dx-stop-container"
eq "the guest is running: nothing is probed or run after the guest check" "" \
    "$(grep -E '^(nas|docker run)' <<<"$EVENTS" || true)"
world
mig P_GUEST_STATE=down
expect_refused "the guest's state cannot be read" "$GUEST"
world
printf 'someone-else\n' >"$LOCKDIR/held"
mig
eq "the lock is held elsewhere: exit 1" 1 "$RC"
eq "the lock is held elsewhere: no guest check, probe or run" "" \
    "$(grep -vE '^docker (lock|lock-inspect)$' <<<"$EVENTS" || true)"
if [ "$BEFORE" = "$AFTER" ] && [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then test_pass "the lock is held elsewhere: nothing written"
else test_fail "the lock is held elsewhere: nothing written"; fi
eq "the lock is held elsewhere: the other holder's lock is kept" someone-else "$(cat "$LOCKDIR/held" 2>/dev/null)"

# =============================================================================
test_section "WP6.4 F: refusals -- the destination"
dest_case() { # LABEL KEYWORD... (the world is prepared by the caller)
    local label="$1"
    shift
    mig
    expect_refused "$label" "$@"
}
world
mkdir -p "$GDIR"
printf 'stray\n' >"$GDIR/stray.txt"
dest_case "a non-empty destination without a marker" "not empty"
world
put_marker "$GDIR" "$(marker_text copying dx-other-persist 2026-10-01T10:00:00Z)"
dest_case "a copying marker for this guest but another source volume" "copying" "dx-other-persist"
world
put_marker "$GDIR" "$(marker_text copying "" 2026-10-01T10:00:00Z)"
dest_case "a copying marker without a source volume" "copying"
world
put_marker "$GDIR" "$(marker_text copying dx-fix-persist 2026-10-01T10:00:00Z "" dx-other)"
dest_case "a copying marker for another guest" "dx-other"
world
put_marker "$GDIR" "$(marker_text ready dx-fix-persist 2026-10-01T10:00:00Z 2026-10-01T11:00:00Z)"
dest_case "a ready marker (already migrated)" "ready"
world
put_marker "$GDIR" "$(dx_persist_marker_format "$GUEST" retired dx-fix-persist 2026-10-01T10:00:00Z 2026-10-01T11:00:00Z 2026-10-02T09:00:00Z)"
dest_case "a retired marker" "retired"
world
put_marker "$GDIR" "garbage"
dest_case "a marker that does not parse" "marker"
world
mkdir -p "$W/elsewhere" "$ROOT/dxe/$GUEST"
ln -s "$W/elsewhere" "$GDIR"
dest_case "a symlinked leaf" "symlink"
eq "a symlinked leaf: nothing was written through it" "" "$(entries_of "$W/elsewhere")"
world
mkdir -p "$W/elsewhere"
ln -s "$W/elsewhere" "$ROOT/dxe"
dest_case "a symlinked dxe level" "symlink"
eq "a symlinked dxe level: nothing was written through it" "" "$(entries_of "$W/elsewhere")"

# =============================================================================
test_section "WP6.4 F: refusals -- the share root"
world
mig DX_PERSIST_HOST_ROOT="$ROOT/no-such-share"
expect_refused "the root probe fails (not a directory)" "DX_PERSIST_HOST_ROOT"
not "the root probe fails: the root is not created" test -e "$ROOT/no-such-share"
world
mig 'P_SSH_FAIL=sh -c *'
expect_refused "the root probe's ssh call fails" "DX_PERSIST_HOST_ROOT"
world
rm -f "$ROOT/$SENTINEL"
mig
expect_refused "the share does not look mounted (no sentinel)" "DX_PERSIST_HOST_MOUNT_SENTINEL"
world
COMMA_ROOT="$W/share,comma"
mkdir -p "$COMMA_ROOT"
: >"$COMMA_ROOT/$SENTINEL"
BEFORE_COMMA="$(snap "$COMMA_ROOT")"
mig DX_PERSIST_HOST_ROOT="$COMMA_ROOT"
expect_refused "a root whose canonical path holds a comma" "DX_PERSIST_HOST_ROOT"
eq "a root with a comma: nothing written under it" "$BEFORE_COMMA" "$(snap "$COMMA_ROOT")"
# A root that canonicalises to "/": the probe is answered from a canned report
# (nothing reads the real /), and every destructive tool on the controller is a
# recording stub for this call; the docker fake refuses any bind outside the
# scratch area besides.
world
printf 'root=/\nmounted=yes\nstate=absent\nmarker=absent\n' >"$W/probe-root-slash"
mig P_PROBE_CANNED="$W/probe-root-slash" @PATH="$STUBS:$CTRL:$REC:$TOOLS:/usr/bin:/bin"
expect_refused "a root that canonicalises to /" "DX_PERSIST_HOST_ROOT"
eq "a root that canonicalises to /: no run at all touched a bind" "" \
    "$(grep -E '^docker run (establish|marker-set|rsync-copy|manifest|refused-outside|missing-bind)' <<<"$EVENTS" || true)"
eq "a root that canonicalises to /: no destructive stub was reached" "" "$(grep -v '^rm -f ' "$STUBLOG" || true)"

# =============================================================================
test_section "WP6.4 E2: refusals -- volumes, inventory, rsync"
world
set_labels dx-fix-persist persist other-host__other-guest
mig
expect_refused "the persist volume belongs to another profile (DQ6)" "dx-fix-persist" "refusing"
world
rm -f "$LABELS/dx-fix-persist"
mig
expect_refused "the persist volume does not exist" "dx-fix-persist"
world
set_labels dx-fix-nix persist
mig
expect_refused "the nix volume carries another role (DQ6)" "dx-fix-nix"
world
mig P_INV_RC=1
expect_refused "the inventory run fails" "dx-fix-persist"
world
inv_set '/^status=ok$/d'
mig
expect_refused "the inventory does not finish (no status=ok)" "dx-fix-persist"
world
printf '%s\n' "$V_307" >"$W/rsync-version.out"
mig
expect_refused "rsync in the nix volume is 3.0.7" "rsync" "3.1"
world
: >"$W/rsync-version.out"
mig P_RSYNC_VERSION_RC=127
expect_refused "rsync is missing from the nix volume" "rsync"
world
inv_set 's/^acl=0$/acl=unknown/'
printf '%s\n' "$V_NOACL" >"$W/rsync-version.out"
mig
expect_refused "ACLs unknown and an rsync without ACLs" "ACLs"

# =============================================================================
test_section "WP6.4 R35: interrupted during the copy, then resumed"
world
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime rsync-kill
fake_fail_nth rsync-kill 1 137
PATH="$SAVED_PATH"
mig P_KILL_GATE="$DXE_FAKE_RUNTIME_DIR/rsync-kill"
eq "killed copy: exit 1" 1 "$RC"
eq "killed copy: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "killed copy: the Error says how to resume" "$(grep '^Error:' <<<"$ERR" || true)" "dx-persist-migrate"
EST_N="$(first_call 'run establish')"
KTC="$(marker_field "$GDIR/$MARKER_NAME" created-at)"
expect_marker_exact "killed copy: the marker stays copying" "$GDIR/$MARKER_NAME" copying "$KTC"
eq "killed copy: no verification" 0 "$(count_kind 'run manifest')"
eq "killed copy: no marker-set" 0 "$(count_kind 'run marker-set')"
not "killed copy: no record" test -e "$REC_FILE"
lacks "killed copy: no report" "$OUT" "migrated:"
not "killed copy: the copy is partial" test -e "$GDIR/nested"
eq "killed copy: the lock is released" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"
INODE_BEFORE="$(inode_of "$GDIR/plain.txt")"
start_check
eq "killed copy: a start is refused (WP4.3)" 1 "$RC"
has "killed copy: the start refusal says copying" "$ERR" "copying"
mig
eq "resume: exit 0" 0 "$RC"
eq "resume: no establish (the directory is reused)" 0 "$(count_kind 'run establish')"
eq "resume: one rsync copy" 1 "$(count_kind 'run rsync-copy')"
expect_argv "resume: rsync into the same destination" "run rsync-copy" "$(argv_rsync "$CDEST")"
eq "resume: the verification passed and the marker was set" 1 "$(count_kind 'run marker-set')"
eq "resume: a file copied before the kill is the same file (same destination, not a fresh one)" \
    "$INODE_BEFORE" "$(inode_of "$GDIR/plain.txt")"
TM="$(marker_field "$GDIR/$MARKER_NAME" migrated-at)"
expect_marker_exact "resume: the ready marker keeps the first run's created-at" "$GDIR/$MARKER_NAME" ready "$KTC" "$TM"
if in_window "$TM"; then test_pass "resume: migrated-at was taken during the resumed run"; else test_fail "resume: migrated-at was taken during the resumed run ([$TM])"; fi
expect_record "resume" "$KTC"
expect_report "resume" 100 30 ._root-meta nested/a/._deep-meta
expect_tree "resume"
expect_volume_mounts_safe "resume"

# A crash inside the establish container (its marker mv fails): an empty,
# unmarked leaf is left; the next run adopts it.
world
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime mv
fake_fail_nth mv 1 1
PATH="$SAVED_PATH"
mig P_CPRE="$DXE_FAKE_RUNTIME_DIR"
eq "crash in establish: exit 1" 1 "$RC"
eq "crash in establish: exactly one Error: line" 1 "$(error_lines "$ERR")"
eq "crash in establish: no rsync copy" 0 "$(count_kind 'run rsync-copy')"
eq "crash in establish: an empty unmarked leaf is left" "" "$(entries_of "$GDIR" 2>/dev/null)"
not "crash in establish: no record" test -e "$REC_FILE"
mig
eq "after the crash: exit 0" 0 "$RC"
expect_argv "after the crash: the empty leaf is adopted" "run establish" "$(argv_establish "$CANON" adopt)"
expect_marker_exact "after the crash: the marker is ready" "$GDIR/$MARKER_NAME" ready \
    "$(marker_field "$GDIR/$MARKER_NAME" created-at)" "$(marker_field "$GDIR/$MARKER_NAME" migrated-at)"
expect_tree "after the crash"

# The ready transition fails (the marker-set container's mv): still copying.
world
put_marker "$GDIR" "$(marker_text copying dx-fix-persist 2026-10-01T10:00:00Z)"
MS_BEFORE="$(cat "$GDIR/$MARKER_NAME")"
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime mv
fake_fail_nth mv 1 1
PATH="$SAVED_PATH"
mig P_CPRE="$DXE_FAKE_RUNTIME_DIR"
eq "marker-set fails: exit 1" 1 "$RC"
eq "marker-set fails: exactly one Error: line" 1 "$(error_lines "$ERR")"
eq "marker-set fails: the marker is still the copying one, byte for byte" "$MS_BEFORE" "$(cat "$GDIR/$MARKER_NAME")"
not "marker-set fails: no record" test -e "$REC_FILE"
lacks "marker-set fails: no report" "$OUT" "migrated:"

# The record cannot be written: the directory is ready, the command fails.
world
mkdir -p "$W/state-blocked"
: >"$W/state-blocked/dxe"
mig XDG_STATE_HOME="$W/state-blocked"
eq "the record cannot be written: exit 1" 1 "$RC"
eq "the record cannot be written: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "the record cannot be written: the Error names the record path" "$(grep '^Error:' <<<"$ERR" || true)" \
    "$W/state-blocked/dxe/persist-dirs/${NAS}__$GUEST"
eq "the record cannot be written: the marker is ready" ready "$(marker_field "$GDIR/$MARKER_NAME" state)"
lacks "the record cannot be written: no report" "$OUT" "migrated:"

# =============================================================================
test_section "WP6.4 R35: a failed verification"
world
mig P_CORRUPT=yes
eq "failed verification: exit 3" 3 "$RC"
eq "failed verification: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "failed verification: the Error says the marker stays copying" "$(grep '^Error:' <<<"$ERR" || true)" "copying"
EST_N="$(first_call 'run establish')"
FTC="$(marker_field "$DDIR/marker.$EST_N" created-at)"
eq "failed verification: the marker is still exactly the copying marker" "$(cat "$DDIR/marker.$EST_N" 2>/dev/null)" "$(cat "$GDIR/$MARKER_NAME" 2>/dev/null)"
expect_marker_exact "failed verification: state copying, this guest and source" "$GDIR/$MARKER_NAME" copying "$FTC"
eq "failed verification: the manifest compare ran" 1 "$(count_kind 'run manifest')"
eq "failed verification: no marker-set" 0 "$(count_kind 'run marker-set')"
not "failed verification: no record" test -e "$REC_FILE"
lacks "failed verification: no report" "$OUT" "migrated:"
eq "failed verification: the lock is released" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"
if [ "$VOL_BEFORE" = "$VOL_AFTER" ]; then test_pass "failed verification: the source volume is unchanged"; else test_fail "failed verification: the source volume is unchanged"; fi
start_check
eq "failed verification: a later start is refused (WP4.3)" 1 "$RC"
has "failed verification: the start refusal names copying" "$(grep '^Error:' <<<"$ERR" || true)" "copying"
create_check
eq "failed verification: dx-create-volumes refuses too" 1 "$RC"
mig
eq "failed verification, investigated, run again: exit 0" 0 "$RC"
eq "run again: no establish (resumed)" 0 "$(count_kind 'run establish')"
expect_marker_exact "run again: ready, keeping the first created-at" "$GDIR/$MARKER_NAME" ready "$FTC" \
    "$(marker_field "$GDIR/$MARKER_NAME" migrated-at)"
eq "run again: the corrupted file was repaired" plain "$(cat "$GDIR/plain.txt")"
world
mig P_MANIFEST_FORCE_RC=2
eq "the verification cannot run (manifest error): exit 3" 3 "$RC"
eq "the verification cannot run: the marker stays copying" copying "$(marker_field "$GDIR/$MARKER_NAME" state)"
not "the verification cannot run: no record" test -e "$REC_FILE"

# =============================================================================
test_section "WP6.4: the profile is never edited (through bin/dx-profile)"
world
mkdir -p "$W/profiles"
cat >"$W/profiles/fixprof.env" <<EOF
export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=$NAS
export DX_GUEST_SYSTEM=x86_64-linux
export DX_CONTAINER_NAME=$GUEST
export DX_IMAGE=$IMAGE
export DX_NIX_STORAGE_MODE=direct-volume
export DX_NIX_VOLUME=dx-fix-nix
export DX_PERSIST_VOLUME=dx-fix-persist
export DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
export DX_PERSIST_STORAGE=volume
export DX_PERSIST_HOST_ROOT=$ROOT
export DX_PERSIST_HOST_MOUNT_SENTINEL=$SENTINEL
EOF
cp -p "$W/profiles/fixprof.env" "$W/profile.orig"
PROFILES_BEFORE="$(snap "$W/profiles")"
: >"$EVLOG"
(
    for _n in $DXE_CONFIG_FIELDS; do unset "$_n"; done
    env_fakes
    export DX_PROFILES_DIR="$W/profiles"
    bash "$BASE_DIR/bin/dx-profile" fixprof "$WRAPPER"
) >>"$EVLOG" 2>"$W/err" </dev/null
RC=$?
ERR="$(cat "$W/err")"
OUT="$(grep -v '^~EV~ ' "$EVLOG" || true)"
EVENTS="$(sed -n 's/^~EV~ //p' "$EVLOG")"
eq "dx-profile fixprof dx-persist-migrate: exit 0" 0 "$RC"
has "dx-profile: the report names the profile's destination" "$OUT" "migrated: $CDEST"
eq "dx-profile: the marker is ready" ready "$(marker_field "$GDIR/$MARKER_NAME" state)"
if cmp -s "$W/profile.orig" "$W/profiles/fixprof.env"; then test_pass "the profile file is byte-for-byte unchanged"
else test_fail "the profile file is byte-for-byte unchanged"; fi
eq "the profiles directory is unchanged (nothing added, removed or re-moded)" "$PROFILES_BEFORE" "$(snap "$W/profiles")"
eq "the profile still says DX_PERSIST_STORAGE=volume" "export DX_PERSIST_STORAGE=volume" \
    "$(grep '^export DX_PERSIST_STORAGE=' "$W/profiles/fixprof.env")"
eq "dx-profile: the lock was the first effect" "docker lock" "$(sed -n 1p <<<"$EVENTS")"
eq "dx-profile: and its release the last" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"

print_summary
exit_with_code
