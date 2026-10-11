#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.5 acceptance: the rollback of a guest's /persist from its NAS host
# directory into a NEW named volume (plans/do plan.md D-3, D-6, D-7, D-8, D-10
# with both 2026-10-11 paragraphs; spec R16, R26, R36 and section 6.1). Written
# before the command exists; the implementer builds exactly this contract. It
# reuses WP6.4's operations (tests/test_persist_migrate.sh, contract J1-J3),
# WP6.2's host_rsync and rsync_check, WP6.3's inventory script and the
# existing volume-create operation.
#
# Interface contract (pinned by this file; the implementation must match):
#
# A. The command. bin/dx-persist-rollback (executable, 100755) is a thin
#    wrapper, the shape of bin/dx-persist-migrate:
#        source "$SCRIPT_DIR/dx-lib.sh"
#        persist_rollback_main() { dx_persist_rollback_main "$@"; }
#        if [ "${BASH_SOURCE[0]}" = "$0" ]; then persist_rollback_main "$@"; fi
#    over dx_persist_rollback_main in bin/lib/dx-persist-dir.sh (kcov scope).
#    The guest is chosen like the sibling commands (environment / .env /
#    `bin/dx-profile NAME bin/dx-persist-rollback --volume NAME`).
#    Arguments: exactly the two words `--volume NAME`, or `-h` / `--help`
#    alone (usage on stdout, first line starting "Usage: dx-persist-rollback",
#    exit 0, no runtime call). Anything else -- no argument, `--volume`
#    without a NAME, `--volume=NAME`, a bare NAME, any other option, an extra
#    word, or a NAME that is empty or outside the volume-name class
#    [A-Za-z0-9][A-Za-z0-9_.-]* (dx_persist_marker_valid_name): "Usage:" on
#    stderr, exit 2, nothing on stdout, no runtime call.
#    DX_PERSIST_STORAGE is not consulted: the command works the same with the
#    profile still in host-path mode (the normal case) or already back in
#    volume mode. It never edits the profile and never starts the guest.
#
# B. Exit codes.
#      0  rolled back and verified: NAME exists with this profile's DQ6
#         persist labels and holds the directory's data, the marker is
#         `retired`, the report (I) ends stdout, no line starts "Error:";
#      1  refused, or failed anywhere but the verification (the volume could
#         not be created, the copy failed, the marker could not be retired).
#         A refusal prints exactly ONE stderr line starting "Error:" (naming
#         the fix), nothing starting "Error:" on stdout, and writes NOTHING:
#         the share, the original volume, NAME (absent, or an existing volume
#         left exactly as it was) and the controller's state directory are
#         unchanged, no volume is created, no container that writes runs (no
#         rsync copy, no marker-set), nothing is chowned;
#      2  usage;
#      3  the copy finished but the verification failed (the manifest run
#         exited non-zero): the marker stays `ready`, NAME is left as it is
#         for inspection, no marker-set, no report.
#    Nothing is ever deleted, on any path: not the directory, not the
#    original volume, not NAME (no `volume rm` at all, also after a failed
#    copy or a failed verification).
#
# C. Refusals before ANY runtime call (no lock, no ssh, no docker), checked
#    after the arguments, in this order, each exit 1 with one Error line
#    naming:
#      DX_RUNTIME is not docker-ssh             "DX_RUNTIME=docker-ssh"
#      DX_PERSIST_HOST_ROOT is empty            "DX_PERSIST_HOST_ROOT"
#      DX_PERSIST_HOST_MOUNT_SENTINEL is empty  "DX_PERSIST_HOST_MOUNT_SENTINEL"
#      NAME is DX_PERSIST_VOLUME's value        NAME and "DX_PERSIST_VOLUME"
#      NAME is DX_NIX_VOLUME's value            NAME and "DX_NIX_VOLUME"
#      NAME is DX_BOOTSTRAP_VOLUME's value      NAME and "DX_BOOTSTRAP_VOLUME"
#
# D. Then the lifecycle lock, exactly as WP6.4 (D): dx_lifecycle_lock_acquire,
#    held to the very end and released on every exit after it; the lock is
#    the first runtime effect and its release the last; a lock that cannot be
#    taken stops the command (exit 1) with no further call.
#
# E. The run, in this order of effects:
#    1. Guest stopped: the first call after the lock is
#           dx_runtime_container_state "$DX_CONTAINER_NAME"        (WP6.4 J1)
#       running -> refused, the Error names the guest and
#       "dx-stop-container"; unknown -> refused, the Error names the guest;
#       stopped or absent -> on.
#    2. The probe, dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT"
#       "$DX_CONTAINER_NAME" (WP4.2), decided as in F. It is the ONLY
#       NAS-shell (non-docker) call the command makes.
#    3. NAME against the marker: NAME equal to the ready marker's
#       source-volume (the original volume the directory was migrated from)
#       -> refused, naming NAME and "source-volume".
#    4. The target: dx_runtime_volume_state NAME (one `volume inspect NAME`):
#       absent -> on; present -> refused, naming NAME and "exists" (any
#       existing volume, even one with this profile's persist labels: the
#       rollback only ever fills a volume it has just created); unknown
#       (non-zero) -> refused, naming NAME.
#    5. The source's inventory: dx_runtime_host_dir_inventory DEST (J4, a
#       read-only run over the directory). A failure (non-zero, or no
#       status=ok line) is a refusal naming DEST. Its acl= and xattr= values
#       choose the rsync options as in WP6.4: -A unless acl=0, -X unless
#       xattr=0 ("unknown" and any count above 0 mean needed); its
#       appledouble= and apple= lines are the `._*` part of the report.
#    6. dx_runtime_host_rsync_check [-A] [-X] with those options; a refusal
#       stops the command (exactly one Error line, naming rsync and the gap).
#       Steps 1-6 write nothing.
#    7. The new volume: dx_runtime_volume_create NAME -- the existing
#       operation, so its labels are DQ6's with role persist -- giving
#       exactly ONE docker call with this argv:
#           volume create --label io.dxe.managed=true --label io.dxe.schema=1
#           --label io.dxe.profile=<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>
#           --label io.dxe.role=persist --label io.dxe.system=<DX_GUEST_SYSTEM>
#           NAME
#       Steps 7-9 run with DX_PERSIST_VOLUME=NAME in their environment, so
#       the existing name-derived DQ6 role of NAME is persist (no operation
#       gains a "rollback" purpose; see J5). Failure -> exit 1, one Error
#       line naming NAME; no copy.
#    8. dx_runtime_host_rsync reverse NAME DEST [-A] [-X] (WP6.2's pinned
#       reverse argv: DEST bound read-only at /src, `-v NAME:/dst`, the only
#       writable volume mount the command ever makes), after NAME's own DQ6
#       inspect (reading the labels step 7 wrote). Non-zero -> exit 1, one
#       Error line naming NAME and "--volume" (NAME is left as it is; run
#       again with a new --volume name); the marker stays ready; no
#       verification.
#    9. dx_runtime_host_manifest_verify reverse NAME DEST (WP6.4 J3's reverse
#       argv; the WP6.1 tool). Non-zero -> exit 3, one Error line naming NAME
#       and "ready" (the directory stays ready and usable).
#    10. dx_runtime_host_dir_marker_set CANON GUEST ready RETIRED (WP6.4 J2,
#       compare-and-set; its SOURCE word is the ready marker's source-volume,
#       "" when it has none). Failure -> exit 1, one Error line; the marker
#       stays ready, byte for byte; no report.
#    11. The report (I) on stdout.
#    CANON is the probe's root= (the canonical root) and DEST is always
#    "CANON/dxe/GUEST/persist"; every container operation gets them, never
#    the configured root.
#
# F. The directory decision, from the probe report (root=, mounted=, state=,
#    marker= and the marker bytes), first match:
#      probe failed or report malformed          refused ("DX_PERSIST_HOST_ROOT")
#      root= not absolute, "/", or holding ","   refused ("DX_PERSIST_HOST_ROOT")
#      mounted= not yes                          refused ("DX_PERSIST_HOST_MOUNT_SENTINEL")
#      state=symlink                             refused ("symlink")
#      state=absent                              refused ("missing")
#      state=empty, or nonempty without marker   refused ("marker")
#      a marker that does not parse              refused ("marker")
#      a marker naming another guest             refused (names that guest)
#      copying                                   refused ("copying")
#      retired                                   refused ("retired")
#      ready for this guest                      on (with or without source-volume)
#
# G. The retired marker (D-3), via dx_persist_marker_format:
#      RETIRED = format GUEST retired S C M T_R
#    S, C and M are the ready marker's own source-volume, created-at and
#    migrated-at, each kept exactly (one it lacks stays absent); T_R is a
#    controller UTC time taken after the verification passed, during the run.
#
# H. The D-7 record is never written, replaced or removed: the controller's
#    state directory is byte-for-byte unchanged by every run (with the
#    migration's record, or with none), and no file is moved on the
#    controller. The record keeps refusing an empty replacement directory;
#    the documented manual removal (WP5.1) covers it with the directory.
#
# I. The report: the LAST lines of stdout, exactly
#        rolled_back: <DEST>
#        volume: <NAME>
#        original_volume: <S, or "none">
#        marker: retired
#        copy_seconds: <N>
#        verify_seconds: <N>
#        appledouble_dropped_count: <the inventory's appledouble= value>
#        appledouble_dropped: <path>     one line per apple= line, in order;
#                                        "appledouble_dropped: none" if none
#        next: <one line containing "DX_PERSIST_STORAGE=volume",
#              "DX_PERSIST_VOLUME=<NAME>" and "dx-recreate">
#    copy_seconds / verify_seconds as WP6.4 (I): `date +%s` differences taken
#    immediately around the rsync copy run and the manifest run.
#
# J. Runtime operations.
#    J4 (new). dx_runtime_host_dir_inventory DIR -- WP6.3's inventory of a
#        host DIRECTORY instead of a volume. Declared in bin/lib/dx-runtime.sh
#        (dx_runtime_host_dir_inventory() { dx_runtime_dispatch
#        host_dir_inventory "$@"; }), implemented as
#        dx_runtime_docker_host_dir_inventory and
#        dx_runtime_apple_host_dir_inventory (Apple: non-zero, "unsupported"
#        on stderr, no tool call). docker-ssh refuses before any call
#        (status 1, nothing on stdout, a reason on stderr, no docker call)
#        on: not exactly one argument; a DIR that is not absolute, is "/", or
#        holds "," or a newline; an empty DX_IMAGE. Otherwise exactly ONE
#        docker call, argv exactly:
#            run --rm --network none --user 0:0 --pull never
#            --mount type=bind,source=<DIR>,target=/v,readonly
#            --entrypoint sh <DX_IMAGE> -c <SCRIPT> sh /v
#        SCRIPT is the very text dx_runtime_volume_inventory runs (ONE
#        inventory script for volumes and directories, so WP6.3b's bare-image
#        rule covers both). Its stdout, stderr and status pass through.
#    J5 (tightened). dx_runtime_host_rsync forward|reverse VOLUME DIR refuses
#        (non-zero, an Error: line naming VOLUME, nothing on stdout, NO docker
#        run) a VOLUME equal to DX_BOOTSTRAP_VOLUME, in both directions, as it
#        already refuses DX_NIX_VOLUME (closes the WP6.2b follow-up). Pinned
#        unchanged alongside: a VOLUME named like DX_PERSIST_VOLUME whose
#        labels carry role nix or bootstrap, and a VOLUME that is not one of
#        the configured volumes (even with this profile's persist labels), are
#        refused with no run; the configured persist volume is copied.
#
# K. Never: a NAS-shell write; a `-v` mount without ":ro" other than
#    `NAME:/dst` in the one rsync copy run; a docker `volume` command or a
#    `-v` mount that names the ORIGINAL volume (the marker's source-volume,
#    and the profile's DX_PERSIST_VOLUME) -- the rollback reads and writes
#    nothing of it, so it also works after that volume was deleted;
#    `volume rm`; a `start`; any change to the directory but its marker.
#
# Test-only conventions: as tests/test_persist_migrate.sh (one scratch area,
# the WP0.2 NAS fake behind a recording ssh, a docker fake that records every
# argv and an event line and EXECUTES the container scripts and copies on
# fixture roots, real rsync and the real manifest tool where the WP6.2
# fidelity toolchain exists and perl stand-ins otherwise, recording/guarded
# tools inside containers, a fake controller clock that advances only in the
# fake rsync copy (+100 s) and manifest run (+30 s)). Here the docker fake
# also creates volumes: `volume create` makes the fixture volume directory
# and stores the DQ6 labels read from its --label words, so every later DQ6
# check reads back what was created; an existing volume is returned as it
# is. The "migrated fixture directory" of the main case is made by running
# WP6.4's dx-persist-migrate, then changed by hand (files added, one changed,
# one deleted, one renamed, a ._* file dropped in by a Mac).

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

test_section "WP6.5: rollback into a new volume (dx-persist-rollback)"

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
MARKER_NAME=.dxe-persist-dir
RSYNC_EP=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
MANIFEST_FILE="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"
WRAPPER="$BASE_DIR/bin/dx-persist-rollback"
ORIG=dx-fix-persist
NEW=dx-fix-rollback
CLOCK0=1760000000
C0=2026-10-01T10:00:00Z
M0=2026-10-01T11:00:00Z
SH_BIN="$(command -v sh)"
HOST_RSYNC="$(command -v rsync 2>/dev/null || true)"
REAL_BASH="$(command -v bash)"

# --- real or stand-in copy and verification (as WP6.4) ------------------------
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
# --exclude=._*` (dirs, files, symlinks), skipping the top-level name SKIP when
# given (the "killed mid-run" partial copy).
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
# As WP6.4's, plus: `volume create` (makes the fixture volume and stores the
# DQ6 labels from its --label words; an existing volume is returned as it is;
# P_VOL_CREATE_RC fails it), and P_VOL_STATE_FAIL=NAME makes the plain
# `volume inspect NAME` (the volume-state question) fail like a daemon that
# cannot be reached.
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
        if [ "${3:-}" != --format ] && [ -n "${P_VOL_STATE_FAIL:-}" ] && [ "$last" = "$P_VOL_STATE_FAIL" ]; then
            echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
            exit 1
        fi
        if [ -f "${P_LABELS:?}/$last" ]; then
            if [ "${3:-}" = --format ]; then cat "$P_LABELS/$last"; else echo "[{\"Name\":\"$last\"}]"; fi
            exit 0
        fi
        echo "Error: No such volume: $last" >&2
        exit 1 ;;
    "volume create")
        ev volume-create "$last"
        case "$last" in
            "" | */* | .*) echo "fake docker: refusing the volume name [$last]" >&2; exit 99 ;;
        esac
        if [ -n "${P_VOL_CREATE_RC:-}" ]; then
            echo "Error response from daemon: create $last: no space left on device" >&2
            exit "$P_VOL_CREATE_RC"
        fi
        if [ -f "${P_LABELS:?}/$last" ]; then echo "$last"; exit 0; fi
        lm=""
        lsch=""
        lp=""
        lr=""
        ly=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = --label ]; then
                case "$a" in
                    io.dxe.managed=*) lm="${a#*=}" ;;
                    io.dxe.schema=*) lsch="${a#*=}" ;;
                    io.dxe.profile=*) lp="${a#*=}" ;;
                    io.dxe.role=*) lr="${a#*=}" ;;
                    io.dxe.system=*) ly="${a#*=}" ;;
                esac
            fi
            prev="$a"
        done
        mkdir -p "${P_VOLROOT:?}/$last" || exit 1
        printf "%s|%s|%s|%s|%s\n" "$lm" "$lsch" "$lp" "$lr" "$ly" >"$P_LABELS/$last"
        echo "$last"
        exit 0 ;;
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
    "run "*) shift ;;
    *) ev other "$*"; echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
mt=()
ms=()
entry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rm | -i) shift ;;
        --network | --user | --pull) shift 2 ;;
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
                    -aH | --numeric-ids | -A | -X) : ;;
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

# A recording ssh in front of the NAS fake (as WP6.4): docker calls log
# themselves; every other (NAS-shell) call is logged here as probe, free or
# other. P_SSH_FAIL (a glob over the remote command) fails matching calls;
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

# The controller's mv (recorded: the rollback moves no file on the controller)
# and date (+%s reads the fake clock; every other format is the real date).
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
# The directory's inventory (canned): one ._* file a Mac dropped in.
INV_DIR='df_total_kb=9000000
df_avail_kb=8000000
size_kb=96
entries=25
hardlinks=0
appledouble=1
apple=._mac-meta
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

# snap DIR: every path below DIR (DIR itself entered as cd -P would) with its
# type, mode, link target and file checksum, bytewise sorted; "ABSENT" when DIR
# does not exist.
snap() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        echo ABSENT
        return 0
    fi
    (cd -P -- "$1" && perl "$HELPERS/snap.pl")
}
# dir_data: the guest directory's snapshot without its marker file (a
# rollback may change only the marker).
dir_data() { snap "$GDIR" | grep -v '^F \./\.dxe-persist-dir ' || true; }
# mirror_of DIR: what a copy of DIR without the marker and ._* names holds.
mirror_of() { snap "$1" | grep -v -e '^F \./\.dxe-persist-dir ' -e '/\._' || true; }

stamp_tree() {
    local i=0 p
    while IFS= read -r -d "" p; do
        i=$((i + 1))
        touch -h -d "@$((1600000000 + i)).$((100000000 + i * 7919))" -- "$p"
    done < <(find "$1" -depth -print0)
}

# build_source DIR: a guest's /persist tree. Real mode: the WP0.2 tree;
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
# directory, logs and clock; the original persist volume and the nix volume
# exist with this profile's DQ6 labels; the original holds the source tree;
# the new volume NEW does not exist.
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
    mkdir -p "$DDIR" "$STATE" "$LABELS" "$VOLROOT/$ORIG" "$VOLROOT/dx-fix-nix" "$LOCKDIR"
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
    SRCVOL="$VOLROOT/$ORIG"
    NEWVOL="$VOLROOT/$NEW"
    REC_FILE="$STATE/dxe/persist-dirs/${NAS}__$GUEST"
    set_labels "$ORIG" persist
    set_labels dx-fix-nix nix
    build_source "$SRCVOL"
    printf '%s\n' "$INV_DIR" >"$W/inv.out"
    printf '%s\n' "$V_330" >"$W/rsync-version.out"
    : >"$ROOT/$SENTINEL"
}
set_labels() { # VOLUME ROLE [PROFILE]
    printf 'true|1|%s|%s|x86_64-linux\n' "${3:-${NAS}__$GUEST}" "$2" >"$LABELS/$1"
}
inv_set() { # SED-EXPRESSION: edit the canned inventory output
    printf '%s\n' "$INV_DIR" | sed "$1" >"$W/inv.out"
}
marker_text() { # STATE [SOURCE [CREATED [MIGRATED [GUEST]]]]
    dx_persist_marker_format "${5:-$GUEST}" "$1" "${2:-}" "${3:-}" "${4:-}"
}
marker_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
# ready_dir [SOURCE]: a hand-made migrated directory: the source tree and a
# ready marker (source-volume SOURCE, ORIG by default, "" for none).
ready_dir() {
    mkdir -p "$GDIR"
    build_source "$GDIR"
    printf '%s\n' "$(marker_text ready "${1-$ORIG}" "$C0" "$M0")" >"$GDIR/$MARKER_NAME"
}
# put_marker DIR TEXT: a marker and one data file.
put_marker() {
    mkdir -p "$1"
    printf '%s\n' "$2" >"$1/$MARKER_NAME"
    printf 'data\n' >"$1/plain.txt"
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
    export DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME="$ORIG" DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
    export DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT="$ROOT" DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
}

# cil [VAR=VALUE...] [@VAR=VALUE...] -- FN [ARGS...]: FN in a subshell that
# sourced bin/dx-lib.sh with this world's configuration (VAR=VALUE exported
# before dx-lib.sh is sourced, @VAR=VALUE after it). The subshell's stdout is
# appended to the event log; its stderr goes to ERR. Sets RC OUT ERR EVENTS
# T0 T1 and BEFORE/AFTER snapshots of the share, the state directory, the
# original volume, the new volume and the directory's data. Each call starts
# a fresh docker call numbering.
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
    NEW_BEFORE="$(snap "$NEWVOL")"
    DIR_BEFORE="$(dir_data)"
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
    NEW_AFTER="$(snap "$NEWVOL")"
    DIR_AFTER="$(dir_data)"
}
# rb [VAR=VALUE...] [@VAR=VALUE...] [-- ARGS...]: dx_persist_rollback_main in
# host-path mode (the profile as it is before a rollback); ARGS default to
# `--volume NEW`.
rb() {
    local kv=() args=no
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        kv+=("$1")
        shift
    done
    if [ "$#" -gt 0 ]; then
        shift
        args=yes
    fi
    if [ "$args" = no ]; then set -- --volume "$NEW"; fi
    cil DX_PERSIST_STORAGE=host-path "${kv[@]+"${kv[@]}"}" -- dx_persist_rollback_main "$@"
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
    [ -f "$DDIR/call.$1" ] || return 1
    perl -e 'local $/; my @w = split(/\0/, <STDIN>, -1); for my $i (0 .. $#w - 1) { if ($w[$i] eq "-c") { print $w[$i + 1]; exit 0 } } exit 1' <"$DDIR/call.$1"
}
line_of() { # PREFIX: the line number in the event log of the first line starting PREFIX (0: none)
    awk -v s="$1" 'index($0, s) == 1 { print NR; f = 1; exit } END { if (!f) print 0 }' "$EVLOG"
}
nas_other() { grep -cE "^nas (other|free)" <<<"$EVENTS" || true; }
write_runs() { grep -cE "^docker run (establish|marker-set|rsync-copy)" <<<"$EVENTS" || true; }

# expected argv (one word per line, <SCRIPT> for the word after -c)
argv_marker_set() { # ROOT GUEST EXPECTED SOURCE
    printf '%s\n' run --rm -i --network none --user 0:0 --pull never --mount \
        "type=bind,source=$1,target=/dxe-share" --entrypoint sh "$IMAGE" -c '<SCRIPT>' sh \
        /dxe-share "$2" "$3" "$4"
}
argv_rsync_reverse() { # DIR [-A] [-X]: into NEW
    local dir="$1"
    shift
    printf '%s\n' run --rm --network none --user 0:0 --pull never -v dx-fix-nix:/nix:ro \
        --mount "type=bind,source=$dir,target=/src,readonly" -v "$NEW:/dst" --entrypoint "$RSYNC_EP" "$IMAGE" \
        -aH --numeric-ids "$@" --exclude=/.dxe-persist-dir '--exclude=._*' /src/ /dst/
}
argv_manifest_reverse() { # VOLUME DIR
    printf '%s\n' run --rm --network none --user 0:0 --pull never \
        --mount "type=bind,source=$2,target=/src,readonly" -v "$1:/dst:ro" --entrypoint bash "$IMAGE" -c '<SCRIPT>' \
        dx-persist-manifest verify /src /dst
}
argv_inventory_dir() { # DIR
    printf '%s\n' run --rm --network none --user 0:0 --pull never \
        --mount "type=bind,source=$1,target=/v,readonly" --entrypoint sh "$IMAGE" -c '<SCRIPT>' sh /v
}
argv_volume_create() { # NAME
    printf '%s\n' volume create --label io.dxe.managed=true --label io.dxe.schema=1 \
        --label "io.dxe.profile=${NAS}__$GUEST" --label io.dxe.role=persist --label io.dxe.system=x86_64-linux "$1"
}
expect_argv() { # LABEL KIND EXPECTED: the first docker call of KIND has exactly EXPECTED
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

# expect_no_write LABEL: nothing written anywhere (share, state, original
# volume, new volume), no volume created, no container that writes ran,
# nothing chowned, no NAS-shell call but the probe, nothing moved on the
# controller.
expect_no_write() {
    local label="$1"
    if [ "$BEFORE" = "$AFTER" ]; then test_pass "$label: the share is unchanged"
    else test_fail "$label: the share is unchanged (before: $(tr '\n' '|' <<<"$BEFORE") | after: $(tr '\n' '|' <<<"$AFTER"))"; fi
    if [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then test_pass "$label: the state directory (the D-7 record) is unchanged"
    else test_fail "$label: the state directory (the D-7 record) is unchanged"; fi
    if [ "$VOL_BEFORE" = "$VOL_AFTER" ]; then test_pass "$label: the original volume is unchanged"
    else test_fail "$label: the original volume is unchanged"; fi
    if [ "$NEW_BEFORE" = "$NEW_AFTER" ]; then test_pass "$label: $NEW is as it was"
    else test_fail "$label: $NEW is as it was (before: $(tr '\n' '|' <<<"$NEW_BEFORE") | after: $(tr '\n' '|' <<<"$NEW_AFTER"))"; fi
    eq "$label: no volume created" 0 "$(count_kind 'volume-create')"
    eq "$label: no rsync copy or marker-set run" 0 "$(write_runs)"
    eq "$label: no manifest run" 0 "$(count_kind 'run manifest')"
    if grep -q '^chown' "$CLOG"; then test_fail "$label: nothing was chowned"; else test_pass "$label: nothing was chowned"; fi
    eq "$label: no NAS-shell call other than the probe" 0 "$(nas_other)"
    eq "$label: nothing moved on the controller" "" "$(cat "$MVLOG")"
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
    lacks "$label: no report" "$OUT" "rolled_back:"
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
expect_never_started() { # LABEL: no docker call besides the classified ones (no start, rm, or stray run)
    eq "$1: no unexpected docker call (no start, no volume rm)" "" \
        "$(grep -E "^docker (other|run unexpected|run bad-mount|run refused-outside|run no-volume|run missing-bind)" <<<"$EVENTS" || true)"
}
# expect_original_untouched LABEL [NAME]: the original volume (ORIG, or NAME)
# is unchanged, and no docker call is a `volume` command naming it or mounts
# it with -v.
expect_original_untouched() {
    local label="$1" orig="${2:-$ORIG}" n=1 w prev first bad=""
    if [ "$VOL_BEFORE" = "$VOL_AFTER" ]; then test_pass "$label: the original volume's content is unchanged"
    else test_fail "$label: the original volume's content is unchanged"; fi
    while [ -e "$DDIR/call.$n" ]; do
        prev=""
        first=""
        while IFS= read -r w; do
            [ -n "$first" ] || first="$w"
            if [ "$first" = volume ] && [ "$w" = "$orig" ]; then bad="$bad $n:volume"; fi
            if [ "$prev" = -v ] && [ "${w%%:*}" = "$orig" ]; then bad="$bad $n:-v"; fi
            prev="$w"
        done <<<"$(words_of "$n")"
        n=$((n + 1))
    done
    eq "$label: no docker call names the original volume $orig (no volume command, no -v mount)" "" "$bad"
}
# expect_mounts_safe LABEL: every -v of every run is :ro except NEW:/dst in
# the rsync copy (the only writable volume mount), and every mounted volume
# had its DQ6 inspect earlier in the same invocation.
expect_mounts_safe() {
    local label="$1" n=1 seen=" " w prev kind bad_ro="" bad_dq6="" rw=""
    while [ -e "$DDIR/call.$n" ]; do
        kind="$(kind_of "$n")"
        case "$kind" in
            "dq6 "*) seen="$seen${kind#dq6 } " ;;
            "run "*)
                prev=""
                while IFS= read -r w; do
                    if [ "$prev" = -v ]; then
                        case "$w" in
                            *:ro) : ;;
                            "$NEW:/dst")
                                if [ "$kind" = "run rsync-copy" ]; then rw="$rw $n"; else bad_ro="$bad_ro $n:$w"; fi ;;
                            *) bad_ro="$bad_ro $n:$w" ;;
                        esac
                        case "$seen" in *" ${w%%:*} "*) : ;; *) bad_dq6="$bad_dq6 $n:${w%%:*}" ;; esac
                    fi
                    prev="$w"
                done <<<"$(words_of "$n")"
                ;;
        esac
        n=$((n + 1))
    done
    eq "$label: every other named volume is mounted read-only (:ro)" "" "$bad_ro"
    eq "$label: every mounted volume had its DQ6 check first" "" "$bad_dq6"
    eq "$label: the one writable volume mount is $NEW:/dst in the rsync copy" " $(first_call 'run rsync-copy')" "$rw"
}
# expect_retired LABEL SOURCE CREATED MIGRATED: the marker is exactly the
# retired marker G, its retired-at taken during this run.
expect_retired() {
    local label="$1" tr want
    tr="$(marker_field "$GDIR/$MARKER_NAME" retired-at)"
    want="$(dx_persist_marker_format "$GUEST" retired "$2" "$3" "$4" "$tr" 2>/dev/null)"
    if [ -n "$tr" ] && [ -f "$GDIR/$MARKER_NAME" ] && [ ! -L "$GDIR/$MARKER_NAME" ] && [ "$(cat "$GDIR/$MARKER_NAME")" = "$want" ] \
        && [ "$(tail -c 1 "$GDIR/$MARKER_NAME" | od -An -c | tr -d ' ')" = '\n' ]; then
        test_pass "$label: the marker is exactly retired, keeping source-volume, created-at and migrated-at"
    else
        test_fail "$label: the marker is exactly retired, keeping source-volume, created-at and migrated-at (got: $(tr '\n' '|' <"$GDIR/$MARKER_NAME" 2>/dev/null))"
    fi
    if dx_persist_marker_valid_timestamp "$tr" && not_after "$T0" "$tr" && not_after "$tr" "$T1" && { [ -z "$4" ] || not_after "$4" "$tr"; }; then
        test_pass "$label: retired-at was taken during the run, not before migrated-at"
    else
        test_fail "$label: retired-at was taken during the run, not before migrated-at ([$tr] not in $T0..$T1)"
    fi
    eq "$label: the marker's mode is 0644" 644 "$(file_mode "$GDIR/$MARKER_NAME" 2>/dev/null)"
}
# expect_report LABEL COPY VERIFY ORIGINAL [APPLE...]: the last lines of stdout.
expect_report() {
    local label="$1" copy="$2" verify="$3" orig="$4" want tail_n got next a
    shift 4
    want="$(
        printf 'rolled_back: %s\n' "$CDEST"
        printf 'volume: %s\n' "$NEW"
        printf 'original_volume: %s\n' "$orig"
        printf 'marker: retired\n'
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
    has "$label: the next step names DX_PERSIST_STORAGE=volume" "$next" "DX_PERSIST_STORAGE=volume"
    has "$label: the next step names DX_PERSIST_VOLUME=$NEW" "$next" "DX_PERSIST_VOLUME=$NEW"
    has "$label: the next step names dx-recreate" "$next" "dx-recreate"
}
# expect_mirror LABEL: the new volume holds exactly the directory's data,
# without its marker and without ._* names.
expect_mirror() {
    local want got
    want="$(mirror_of "$GDIR")"
    got="$(snap "$NEWVOL")"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then test_pass "$1: the new volume mirrors the directory (no marker, no ._* files)"
    else test_fail "$1: the new volume mirrors the directory (no marker, no ._* files) (want: $(tr '\n' '|' <<<"$want") | got: $(tr '\n' '|' <<<"$got"))"; fi
    not "$1: the directory's marker was not copied into the volume" test -e "$NEWVOL/$MARKER_NAME"
}
expect_ok_run() { # LABEL: exit 0, no Error line anywhere
    eq "$1: exit 0" 0 "$RC"
    eq "$1: no Error: line" 0 "$(error_lines "$(printf '%s\n%s' "$ERR" "$OUT")")"
}

# The WP4.3 decisions in host-path mode, as dx-start-container and
# dx-create-volumes reach them.
start_check() { cil DX_PERSIST_STORAGE=host-path -- dx_persist_start_check; }
create_check() { cil DX_PERSIST_STORAGE=host-path -- dx_persist_create_decision; }

# The main case's directory: migrated by WP6.4's command, then changed while
# the guest ran on it.
migrated_world() {
    world
    cil -- dx_persist_migrate_main
    if [ "$RC" = 0 ] && [ "$(marker_field "$GDIR/$MARKER_NAME" state)" = ready ]; then
        test_pass "setup: dx-persist-migrate made a ready directory"
    else
        test_fail "setup: dx-persist-migrate made a ready directory (exit $RC; stderr: $ERR)"
    fi
    printf 'added\n' >"$GDIR/added-after.txt"
    mkdir "$GDIR/new-dir"
    printf 'new\n' >"$GDIR/new-dir/new.txt"
    printf 'plain changed\n' >"$GDIR/plain.txt"
    rm -f "$GDIR/secret-0600.txt"
    mv "$GDIR/nested/a/b/c/deep.txt" "$GDIR/nested/a/b/c/deep-renamed.txt"
    : >"$GDIR/._mac-meta"
}

# =============================================================================
test_section "WP6.5 J4: the new runtime operation is declared and implemented"
if type dx_runtime_host_dir_inventory >/dev/null 2>&1; then test_pass "dx_runtime_host_dir_inventory is declared (dx-runtime.sh)"
else test_fail "dx_runtime_host_dir_inventory is declared (dx-runtime.sh)"; fi
for adapter in docker apple; do
    if type "dx_runtime_${adapter}_host_dir_inventory" >/dev/null 2>&1; then test_pass "dx_runtime_${adapter}_host_dir_inventory is implemented"
    else test_fail "dx_runtime_${adapter}_host_dir_inventory is implemented"; fi
done

# -----------------------------------------------------------------------------
test_section "WP6.5 J4: dx_runtime_host_dir_inventory"
world
ready_dir
cil -- dx_runtime_volume_inventory "$ORIG"
VOL_INV_SCRIPT="$(cword_of "$(first_call 'run inventory')" 2>/dev/null || true)"
cil -- dx_runtime_host_dir_inventory "$CDEST"
eq "host_dir_inventory: status 0" 0 "$RC"
eq "host_dir_inventory: the container's output passes through unchanged" "$INV_DIR" "$OUT"
eq "host_dir_inventory: exactly one docker call" 1 "$(n_calls)"
eq "host_dir_inventory: it is the inventory run" "run inventory" "$(kind_of 1)"
eq "host_dir_inventory: the argv is exactly the pinned one (the directory bound read-only at /v, no volume)" \
    "$(argv_inventory_dir "$CDEST")" "$(words_of 1)"
if [ -n "$VOL_INV_SCRIPT" ] && [ "$(cword_of 1 2>/dev/null)" = "$VOL_INV_SCRIPT" ]; then
    test_pass "host_dir_inventory: the script is the very text the volume inventory runs"
else
    test_fail "host_dir_inventory: the script is the very text the volume inventory runs"
fi
if [ "$BEFORE" = "$AFTER" ]; then test_pass "host_dir_inventory: the share is unchanged"; else test_fail "host_dir_inventory: the share is unchanged"; fi
cil P_INV_RC=3 -- dx_runtime_host_dir_inventory "$CDEST"
eq "host_dir_inventory: the container's status passes through" 3 "$RC"
hdi_precall() { # LABEL ARGS...
    local label="$1"
    shift
    cil @PATH="$STUBS:$CTRL:$REC:$TOOLS:/usr/bin:/bin" -- dx_runtime_host_dir_inventory "$@"
    eq "$label: refused (status 1)" 1 "$RC"
    expect_no_call "$label"
    eq "$label: nothing on stdout" "" "$OUT"
    if [ -n "$ERR" ]; then test_pass "$label: a reason on stderr"; else test_fail "$label: a reason on stderr"; fi
}
hdi_precall "host_dir_inventory, relative DIR" "share/dxe"
hdi_precall "host_dir_inventory, DIR is /" /
hdi_precall "host_dir_inventory, DIR with a comma" "$CDEST,readonly=false"
hdi_precall "host_dir_inventory, DIR with a newline" "$CDEST
/x"
hdi_precall "host_dir_inventory, no argument"
hdi_precall "host_dir_inventory, two arguments" "$CDEST" "$CDEST"
eq "host_dir_inventory refusals: no destructive stub was reached" "" "$(cat "$STUBLOG")"
cil @DX_IMAGE= -- dx_runtime_host_dir_inventory "$CDEST"
eq "host_dir_inventory, empty DX_IMAGE: status 1" 1 "$RC"
expect_no_call "host_dir_inventory, empty DX_IMAGE"
cil DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image -- dx_runtime_host_dir_inventory "$CDEST"
if [ "$RC" -ne 0 ]; then test_pass "host_dir_inventory, Apple: non-zero"; else test_fail "host_dir_inventory, Apple: non-zero"; fi
has "host_dir_inventory, Apple: unsupported" "$ERR" "unsupported"
expect_no_call "host_dir_inventory, Apple"

# -----------------------------------------------------------------------------
test_section "WP6.5 J5: host_rsync never copies into or out of the bootstrap volume, or any volume but the persist one"
world
ready_dir
BOOTVOL="$VOLROOT/dx-fix-bootstrap"
mkdir -p "$BOOTVOL"
printf 'boot\n' >"$BOOTVOL/keep.txt"
set_labels dx-fix-bootstrap bootstrap
rsync_refused() { # LABEL VOLUME: after a cil call
    local label="$1"
    if [ "$RC" -ne 0 ]; then test_pass "$label: non-zero"; else test_fail "$label: non-zero"; fi
    eq "$label: no docker run" 0 "$(count_kind 'run ')"
    has "$label: an Error line names the volume" "$(grep '^Error:' <<<"$ERR" || true)" "$2"
    eq "$label: nothing on stdout" "" "$OUT"
    if [ "$BEFORE" = "$AFTER" ]; then test_pass "$label: the share is unchanged"; else test_fail "$label: the share is unchanged"; fi
}
for direction in reverse forward; do
    BOOT_BEFORE="$(snap "$BOOTVOL")"
    cil -- dx_runtime_host_rsync "$direction" dx-fix-bootstrap "$CDEST"
    rsync_refused "host_rsync $direction with the configured bootstrap volume" dx-fix-bootstrap
    eq "host_rsync $direction with the bootstrap volume: that volume is unchanged" "$BOOT_BEFORE" "$(snap "$BOOTVOL")"
done
cil -- dx_runtime_host_rsync reverse dx-fix-nix "$CDEST"
rsync_refused "host_rsync reverse into the configured nix volume (still refused)" dx-fix-nix
set_labels "$ORIG" bootstrap
cil -- dx_runtime_host_rsync reverse "$ORIG" "$CDEST"
rsync_refused "host_rsync reverse, the persist volume's name with role bootstrap" "$ORIG"
set_labels "$ORIG" nix
cil -- dx_runtime_host_rsync reverse "$ORIG" "$CDEST"
rsync_refused "host_rsync reverse, the persist volume's name with role nix" "$ORIG"
set_labels "$ORIG" persist
eq "the original volume is unchanged by the refused copies" "$VOL_BEFORE" "$(snap "$SRCVOL")"
mkdir -p "$NEWVOL"
set_labels "$NEW" persist
cil -- dx_runtime_host_rsync reverse "$NEW" "$CDEST"
rsync_refused "host_rsync reverse into a volume that is not configured (this profile's persist labels)" "$NEW"
eq "host_rsync into an unconfigured volume: it stays empty" "" "$(ls -A "$NEWVOL")"
cil DX_PERSIST_VOLUME="$NEW" -- dx_runtime_host_rsync reverse "$NEW" "$CDEST"
eq "host_rsync reverse into the configured persist volume (DX_PERSIST_VOLUME=$NEW): status 0" 0 "$RC"
eq "host_rsync reverse into the configured persist volume: one rsync copy" 1 "$(count_kind 'run rsync-copy')"
expect_argv "host_rsync reverse: the pinned WP6.2 reverse argv" "run rsync-copy" "$(argv_rsync_reverse "$CDEST")"
eq "host_rsync reverse: the data arrived" plain "$(cat "$NEWVOL/plain.txt" 2>/dev/null)"

# =============================================================================
test_section "WP6.5 A, C: the command's surface and its refusals before any call"
world
ready_dir
for flag in -h --help; do
    rb -- "$flag"
    eq "dx-persist-rollback $flag: exit 0" 0 "$RC"
    case "$(sed -n 1p <<<"$OUT")" in
        "Usage: dx-persist-rollback"*) test_pass "dx-persist-rollback $flag: usage on stdout" ;;
        *) test_fail "dx-persist-rollback $flag: usage on stdout (got: $OUT)" ;;
    esac
    expect_no_call "dx-persist-rollback $flag"
done
usage_case() { # LABEL ARGS...
    local label="$1"
    shift
    rb -- "$@"
    eq "$label: exit 2 (usage)" 2 "$RC"
    has "$label: Usage: on stderr" "$ERR" "Usage:"
    eq "$label: nothing on stdout" "" "$OUT"
    expect_no_call "$label"
    if [ "$BEFORE" = "$AFTER" ] && [ "$NEW_BEFORE" = "$NEW_AFTER" ]; then test_pass "$label: nothing written"; else test_fail "$label: nothing written"; fi
}
usage_case "no argument"
usage_case "--volume without a name" --volume
usage_case "--volume=NAME" "--volume=$NEW"
usage_case "a bare name" "$NEW"
usage_case "an extra word" --volume "$NEW" extra
usage_case "another option" -x
usage_case "an empty name" --volume ""
usage_case "a name with a leading dash" --volume -bad
usage_case "a name with a slash" --volume a/b
usage_case "a name with a leading dot" --volume .hidden
usage_case "a name with a space" --volume "two words"
config_refused() { # LABEL KEYWORD...
    local label="$1" k
    shift
    eq "$label: exit 1" 1 "$RC"
    eq "$label: exactly one Error: line" 1 "$(error_lines "$ERR")"
    for k in "$@"; do
        has "$label: the Error names [$k]" "$(grep '^Error:' <<<"$ERR" || true)" "$k"
    done
    expect_no_call "$label"
    if [ "$BEFORE" = "$AFTER" ] && [ "$STATE_BEFORE" = "$STATE_AFTER" ] && [ "$NEW_BEFORE" = "$NEW_AFTER" ]; then test_pass "$label: nothing written"
    else test_fail "$label: nothing written"; fi
}
rb DX_PERSIST_STORAGE=volume DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image
config_refused "not docker-ssh" "DX_RUNTIME=docker-ssh"
rb DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT=
config_refused "no DX_PERSIST_HOST_ROOT" "DX_PERSIST_HOST_ROOT"
rb DX_PERSIST_HOST_MOUNT_SENTINEL=
config_refused "no DX_PERSIST_HOST_MOUNT_SENTINEL" "DX_PERSIST_HOST_MOUNT_SENTINEL"
rb -- --volume "$ORIG"
config_refused "--volume names the configured persist volume" "$ORIG" "DX_PERSIST_VOLUME"
rb -- --volume dx-fix-nix
config_refused "--volume names the nix volume" dx-fix-nix "DX_NIX_VOLUME"
rb -- --volume dx-fix-bootstrap
config_refused "--volume names the bootstrap volume" dx-fix-bootstrap "DX_BOOTSTRAP_VOLUME"
if [ -x "$WRAPPER" ]; then test_pass "bin/dx-persist-rollback exists and is executable"; else test_fail "bin/dx-persist-rollback exists and is executable"; fi
(
    env_fakes
    env_config
    bash "$WRAPPER" --help
) >"$W/wrap.out" 2>"$W/wrap.err" </dev/null
eq "bin/dx-persist-rollback --help: exit 0" 0 "$?"
has "bin/dx-persist-rollback --help: usage" "$(cat "$W/wrap.out")" "Usage: dx-persist-rollback"
(
    env_fakes
    env_config
    bash "$WRAPPER" extra
) >"$W/wrap.out" 2>"$W/wrap.err" </dev/null
eq "bin/dx-persist-rollback extra: exit 2" 2 "$?"

# =============================================================================
test_section "WP6.5 E: a migrated directory, changed since, rolled back into a new volume"
migrated_world
RC0="$(marker_field "$GDIR/$MARKER_NAME" created-at)"
RM0="$(marker_field "$GDIR/$MARKER_NAME" migrated-at)"
eq "setup: the ready marker names the original volume" "$ORIG" "$(marker_field "$GDIR/$MARKER_NAME" source-volume)"
REC_BEFORE="$(cat "$REC_FILE" 2>/dev/null)"
rb
expect_ok_run "rollback"
eq "rollback: the first effect is the lock" "docker lock" "$(sed -n 1p <<<"$EVENTS")"
eq "rollback: the first call after the lock is the guest-state check" "docker guest-state $GUEST" "$(sed -n 2p <<<"$EVENTS")"
expect_argv "rollback: the guest-state argv" "guest-state" "$(printf '%s\n' container inspect --format '{{.State.Running}}' "$GUEST")"
prev="$(line_of "~EV~ docker guest-state")"
order_ok=yes
trail=""
for step in "~EV~ nas probe" "~EV~ docker vol-state $NEW" "~EV~ docker run inventory" \
    "~EV~ docker run rsync-version" "~EV~ docker volume-create $NEW" "~EV~ docker dq6 $NEW" "~EV~ docker run rsync-copy" \
    "~EV~ docker run manifest" "~EV~ docker run marker-set ready" "rolled_back: " "~EV~ docker unlock"; do
    at="$(line_of "$step")"
    trail="$trail [${step#\~EV\~ }]@$at"
    if [ "$at" -eq 0 ] || [ "$at" -le "$prev" ]; then order_ok=no; fi
    prev="$at"
done
if [ "$order_ok" = yes ]; then
    test_pass "rollback: guest check, probe, target check, inventory, rsync check, create, DQ6 of the new volume, copy, verify, retire, report, unlock -- in that order"
else
    test_fail "rollback: guest check, probe, target check, inventory, rsync check, create, DQ6 of the new volume, copy, verify, retire, report, unlock -- in that order ($trail)"
fi
eq "rollback: the lock is released last" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"
for k in "volume-create" "run inventory" "run rsync-copy" "run manifest" "run marker-set"; do
    eq "rollback: exactly one [$k]" 1 "$(count_kind "$k")"
done
eq "rollback: no establish run (the directory is never re-created)" 0 "$(count_kind 'run establish')"
eq "rollback: the only NAS-shell call is one probe" "nas probe" "$(grep '^nas ' <<<"$EVENTS" | tr '\n' '|' | sed 's/|$//')"
expect_argv "rollback: the target check is a plain volume inspect of $NEW" "vol-state" "$(printf '%s\n' volume inspect "$NEW")"
expect_argv "rollback: the directory's inventory (read-only bind of the canonical directory)" "run inventory" "$(argv_inventory_dir "$CDEST")"
expect_argv "rollback: $NEW is created with this profile's DQ6 persist labels" "volume-create" "$(argv_volume_create "$NEW")"
expect_argv "rollback: rsync from the directory (read-only) into $NEW, marker and ._* excluded, no -A/-X (acl=0 xattr=0)" \
    "run rsync-copy" "$(argv_rsync_reverse "$CDEST")"
expect_argv "rollback: the manifest verify, reverse, both sides read-only" "run manifest" "$(argv_manifest_reverse "$NEW" "$CDEST")"
if manifest_text_ok "$(first_call 'run manifest')"; then test_pass "rollback: the verification runs the WP6.1 manifest tool"
else test_fail "rollback: the verification runs the WP6.1 manifest tool"; fi
expect_argv "rollback: marker-set ready -> retired on the canonical root, source $ORIG" \
    "run marker-set" "$(argv_marker_set "$CANON" "$GUEST" ready "$ORIG")"
eq "rollback: $NEW carries this profile's DQ6 persist labels" "true|1|${NAS}__$GUEST|persist|x86_64-linux" "$(cat "$LABELS/$NEW" 2>/dev/null)"
expect_retired "rollback" "$ORIG" "$RC0" "$RM0"
eq "rollback: exactly one mv in the container, onto the marker" \
    1 "$(grep -c "^mv @/dxe/$GUEST/persist/[^ /]* @/dxe/$GUEST/persist/$MARKER_NAME\$" "$CLOG" || true)"
eq "rollback: no other mv in a container" 1 "$(grep -c '^mv' "$CLOG" || true)"
if grep -q '^chown' "$CLOG"; then test_fail "rollback: nothing chowned"; else test_pass "rollback: nothing chowned"; fi
if grep -q REFUSED "$CLOG"; then test_fail "rollback: no recursive or out-of-share tool use"; else test_pass "rollback: no recursive or out-of-share tool use"; fi
expect_mirror "rollback"
eq "rollback: the new volume has the file added after the migration" added "$(cat "$NEWVOL/added-after.txt" 2>/dev/null)"
eq "rollback: the new volume has the new directory and its file" new "$(cat "$NEWVOL/new-dir/new.txt" 2>/dev/null)"
eq "rollback: the new volume has the changed content" "plain changed" "$(cat "$NEWVOL/plain.txt" 2>/dev/null)"
not "rollback: the deleted file is not in the new volume" test -e "$NEWVOL/secret-0600.txt"
not "rollback: the renamed file's old name is not in the new volume" test -e "$NEWVOL/nested/a/b/c/deep.txt"
eq "rollback: the renamed file is in the new volume under its new name" deep "$(cat "$NEWVOL/nested/a/b/c/deep-renamed.txt" 2>/dev/null)"
not "rollback: the Mac's ._mac-meta was dropped" test -e "$NEWVOL/._mac-meta"
expect_original_untouched "rollback"
eq "rollback: the original still has the deleted file" secret "$(cat "$SRCVOL/secret-0600.txt" 2>/dev/null)"
eq "rollback: the original still has the old content" plain "$(cat "$SRCVOL/plain.txt" 2>/dev/null)"
not "rollback: the original did not get the added file" test -e "$SRCVOL/added-after.txt"
eq "rollback: the directory's data is unchanged (only its marker changed)" "$DIR_BEFORE" "$DIR_AFTER"
eq "rollback: the D-7 record is unchanged" "$STATE_BEFORE" "$STATE_AFTER"
eq "rollback: the record is still the migration's" "$REC_BEFORE" "$(cat "$REC_FILE" 2>/dev/null)"
has "rollback: the record says mode=migrate" "$REC_BEFORE" "mode=migrate"
eq "rollback: nothing moved on the controller" "" "$(cat "$MVLOG")"
expect_report "rollback" 100 30 "$ORIG" ._mac-meta
expect_mounts_safe "rollback"
expect_never_started "rollback"
not "rollback: the lock is not left held" test -e "$LOCKDIR/held"
NEW_DONE="$(snap "$NEWVOL")"

start_check
eq "afterwards: a host-path start on the retired directory is refused (WP4.3)" 1 "$RC"
has "afterwards: the start refusal says retired" "$(grep '^Error:' <<<"$ERR" || true)" "retired"
create_check
eq "afterwards: dx-create-volumes in host-path mode refuses too" 1 "$RC"
cil DX_PERSIST_STORAGE=volume DX_PERSIST_VOLUME="$NEW" -- dx_persist_storage_ensure ""
eq "afterwards: with the profile switched (volume mode, DX_PERSIST_VOLUME=$NEW), dx-create-volumes' persist step succeeds" 0 "$RC"
eq "afterwards: it adopts the new volume, creating nothing" 0 "$(count_kind 'volume-create')"
eq "afterwards: it checked the new volume's DQ6 labels" 1 "$(count_kind "dq6 $NEW")"
rb
expect_refused "afterwards: rolling back the retired directory again" "retired"
eq "afterwards: the new volume is as the rollback left it" "$NEW_DONE" "$(snap "$NEWVOL")"

# =============================================================================
test_section "WP6.5 E5: -A/-X from the directory's inventory; an absent guest; a symlinked root"
world
ready_dir
inv_set 's/^acl=0$/acl=unknown/;s/^xattr=0$/xattr=unknown/;/^apple=/d;s/^appledouble=1$/appledouble=0/'
rb P_GUEST_STATE=absent
expect_ok_run "acl=unknown xattr=unknown, guest container absent"
expect_argv "unknown ACLs/xattrs: rsync gets -A -X" "run rsync-copy" "$(argv_rsync_reverse "$CDEST" -A -X)"
expect_report "no ._* files" 100 30 "$ORIG"
expect_retired "acl=unknown xattr=unknown" "$ORIG" "$C0" "$M0"
world
ready_dir
ln -s "$ROOT" "$W/share-link"
inv_set 's/^acl=0$/acl=4/'
rb DX_PERSIST_HOST_ROOT="$W/share-link"
expect_ok_run "acl=4 xattr=0, the configured root is a symlink"
expect_argv "ACLs present: rsync gets -A only" "run rsync-copy" "$(argv_rsync_reverse "$CDEST" -A)"
expect_argv "a symlinked root: the inventory reads the canonical directory" "run inventory" "$(argv_inventory_dir "$CDEST")"
expect_argv "a symlinked root: the verification reads the canonical directory" "run manifest" "$(argv_manifest_reverse "$NEW" "$CDEST")"
expect_argv "a symlinked root: marker-set uses the canonical root" "run marker-set" "$(argv_marker_set "$CANON" "$GUEST" ready "$ORIG")"
expect_report "a symlinked root (the report names the canonical directory)" 100 30 "$ORIG" ._mac-meta
world
ready_dir
inv_set 's/^xattr=0$/xattr=12/'
printf '%s\n' "$V_NOACL" >"$W/rsync-version.out"
rb
expect_ok_run "acl=0 xattr=12, an rsync without ACLs (ACLs not needed)"
expect_argv "xattrs present: rsync gets -X only" "run rsync-copy" "$(argv_rsync_reverse "$CDEST" -X)"

# The original volume was deleted after the migration: the rollback needs
# nothing of it (K).
world
ready_dir
rm -f "$LABELS/$ORIG"
rb
expect_ok_run "the original volume no longer exists"
expect_retired "the original volume no longer exists" "$ORIG" "$C0" "$M0"
expect_report "the original volume no longer exists (the report still names it)" 100 30 "$ORIG" ._mac-meta
expect_original_untouched "the original volume no longer exists"

# A directory the tooling created for a new guest (a ready marker with no
# source-volume), with the profile already back in volume mode and no record.
world
ready_dir ""
rb DX_PERSIST_STORAGE=volume
expect_ok_run "a ready marker without source-volume, the profile already in volume mode, no record"
expect_argv "no source-volume: marker-set's SOURCE word is empty" "run marker-set" "$(argv_marker_set "$CANON" "$GUEST" ready "")"
expect_retired "no source-volume" "" "$C0" "$M0"
not "no source-volume: the retired marker has no source-volume line" grep -q '^source-volume=' "$GDIR/$MARKER_NAME"
expect_report "no source-volume" 100 30 none ._mac-meta
expect_mirror "no source-volume"
eq "no record before: none is created (the state directory is unchanged)" "$STATE_BEFORE" "$STATE_AFTER"
not "no record before: still no record" test -e "$REC_FILE"
expect_original_untouched "no source-volume (the profile's DX_PERSIST_VOLUME)"

# =============================================================================
test_section "WP6.5 E1, D: refusals -- the guest and the lock"
world
ready_dir
rb P_GUEST_STATE=running
expect_refused "the guest is running" "$GUEST" "dx-stop-container"
eq "the guest is running: nothing is probed, inspected or run after the guest check" "" \
    "$(grep -E '^(nas|docker run|docker vol-state|docker volume-create|docker dq6)' <<<"$EVENTS" || true)"
rb P_GUEST_STATE=down
expect_refused "the guest's state cannot be read" "$GUEST"
printf 'someone-else\n' >"$LOCKDIR/held"
rb
eq "the lock is held elsewhere: exit 1" 1 "$RC"
eq "the lock is held elsewhere: no guest check, probe or run" "" \
    "$(grep -vE '^docker (lock|lock-inspect)$' <<<"$EVENTS" || true)"
if [ "$BEFORE" = "$AFTER" ] && [ "$NEW_BEFORE" = "$NEW_AFTER" ]; then test_pass "the lock is held elsewhere: nothing written"
else test_fail "the lock is held elsewhere: nothing written"; fi
eq "the lock is held elsewhere: the other holder's lock is kept" someone-else "$(cat "$LOCKDIR/held" 2>/dev/null)"

# =============================================================================
test_section "WP6.5 F: refusals -- the directory's marker isn't ready for this guest"
dir_case() { # LABEL KEYWORD... (the world is prepared by the caller)
    local label="$1"
    shift
    rb
    expect_refused "$label" "$@"
}
world
dir_case "no directory" "missing" "dxe/$GUEST/persist"
world
mkdir -p "$GDIR"
dir_case "an empty directory without a marker" "marker"
world
mkdir -p "$GDIR"
printf 'stray\n' >"$GDIR/stray.txt"
dir_case "a non-empty directory without a marker" "marker"
world
put_marker "$GDIR" "garbage"
dir_case "a marker that does not parse" "marker"
world
put_marker "$GDIR" "$(marker_text ready "$ORIG" "$C0" "$M0" dx-other)"
dir_case "a ready marker for another guest" "dx-other"
world
put_marker "$GDIR" "$(marker_text copying "$ORIG" "$C0")"
dir_case "a copying marker (the migration never finished)" "copying"
world
put_marker "$GDIR" "$(dx_persist_marker_format "$GUEST" retired "$ORIG" "$C0" "$M0" 2026-10-02T09:00:00Z)"
dir_case "a retired marker" "retired"
world
mkdir -p "$W/elsewhere" "$ROOT/dxe/$GUEST"
put_marker "$W/elsewhere" "$(marker_text ready "$ORIG" "$C0" "$M0")"
EL_BEFORE="$(snap "$W/elsewhere")"
ln -s "$W/elsewhere" "$GDIR"
dir_case "a symlinked leaf" "symlink"
eq "a symlinked leaf: nothing was read into a volume or written through it" "$EL_BEFORE" "$(snap "$W/elsewhere")"

# =============================================================================
test_section "WP6.5 F: refusals -- the share root"
world
ready_dir
rb DX_PERSIST_HOST_ROOT="$ROOT/no-such-share"
expect_refused "the root probe fails (not a directory)" "DX_PERSIST_HOST_ROOT"
world
ready_dir
rb 'P_SSH_FAIL=sh -c *'
expect_refused "the root probe's ssh call fails" "DX_PERSIST_HOST_ROOT"
world
ready_dir
rm -f "$ROOT/$SENTINEL"
rb
expect_refused "the share does not look mounted (no sentinel)" "DX_PERSIST_HOST_MOUNT_SENTINEL"
world
COMMA_ROOT="$W/share,comma"
mkdir -p "$COMMA_ROOT/dxe/$GUEST/persist"
: >"$COMMA_ROOT/$SENTINEL"
put_marker "$COMMA_ROOT/dxe/$GUEST/persist" "$(marker_text ready "$ORIG" "$C0" "$M0")"
BEFORE_COMMA="$(snap "$COMMA_ROOT")"
rb DX_PERSIST_HOST_ROOT="$COMMA_ROOT"
expect_refused "a root whose canonical path holds a comma" "DX_PERSIST_HOST_ROOT"
eq "a root with a comma: nothing written under it" "$BEFORE_COMMA" "$(snap "$COMMA_ROOT")"
# A root that canonicalises to "/": the probe is answered from a canned report
# (nothing reads the real /), and every destructive tool on the controller is a
# recording stub for this call; the docker fake refuses any bind outside the
# scratch area besides.
world
printf 'root=/\nmounted=yes\nstate=nonempty\nmarker=present\n%s\n' "$(marker_text ready "$ORIG" "$C0" "$M0")" >"$W/probe-root-slash"
rb P_PROBE_CANNED="$W/probe-root-slash" @PATH="$STUBS:$CTRL:$REC:$TOOLS:/usr/bin:/bin"
expect_refused "a root that canonicalises to /" "DX_PERSIST_HOST_ROOT"
eq "a root that canonicalises to /: no run at all touched a bind" "" \
    "$(grep -E '^docker run (inventory|marker-set|rsync-copy|manifest|refused-outside|missing-bind)' <<<"$EVENTS" || true)"
eq "a root that canonicalises to /: no destructive stub was reached" "" "$(grep -v '^rm -f ' "$STUBLOG" || true)"

# =============================================================================
test_section "WP6.5 E3, E4: refusals -- the target volume"
world
ready_dir
mkdir -p "$NEWVOL"
printf 'someone else\n' >"$NEWVOL/theirs.txt"
set_labels "$NEW" persist
rb
expect_refused "the target volume already exists (this profile's persist labels)" "$NEW" "exists"
eq "the target exists: its file is untouched" "someone else" "$(cat "$NEWVOL/theirs.txt" 2>/dev/null)"
world
ready_dir
mkdir -p "$NEWVOL"
set_labels "$NEW" persist other-host__other-guest
rb
expect_refused "the target volume already exists (another profile's)" "$NEW" "exists"
world
ready_dir
rb P_VOL_STATE_FAIL="$NEW"
expect_refused "whether the target volume exists cannot be told" "$NEW"
eq "the target's state is unknown: it is not created" ABSENT "$(snap "$NEWVOL")"
# The original volume is gone (deleted after the migration); --volume names it.
world
ready_dir dx-fix-old
rb -- --volume dx-fix-old
expect_refused "--volume names the marker's source-volume (the original volume)" dx-fix-old "source-volume"
not "--volume names the original: it is not re-created" test -e "$VOLROOT/dx-fix-old"

# =============================================================================
test_section "WP6.5 E5, E6: refusals -- the inventory and rsync"
world
ready_dir
rb P_INV_RC=1
expect_refused "the directory's inventory run fails" "dxe/$GUEST/persist"
world
ready_dir
inv_set '/^status=ok$/d'
rb
expect_refused "the directory's inventory does not finish (no status=ok)" "dxe/$GUEST/persist"
world
ready_dir
printf '%s\n' "$V_307" >"$W/rsync-version.out"
rb
expect_refused "rsync in the nix volume is 3.0.7" "rsync" "3.1"
world
ready_dir
: >"$W/rsync-version.out"
rb P_RSYNC_VERSION_RC=127
expect_refused "rsync is missing from the nix volume" "rsync"
world
ready_dir
inv_set 's/^acl=0$/acl=unknown/'
printf '%s\n' "$V_NOACL" >"$W/rsync-version.out"
rb
expect_refused "ACLs unknown and an rsync without ACLs" "ACLs"
world
ready_dir
set_labels dx-fix-nix persist
rb
expect_refused "the nix volume carries another role (DQ6)" "dx-fix-nix"

# =============================================================================
test_section "WP6.5 E7-E10: failures after the volume exists -- nothing is deleted"
# The volume cannot be created.
world
ready_dir
MS_BEFORE="$(cat "$GDIR/$MARKER_NAME")"
rb P_VOL_CREATE_RC=1
eq "volume create fails: exit 1" 1 "$RC"
eq "volume create fails: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "volume create fails: the Error names the volume" "$(grep '^Error:' <<<"$ERR" || true)" "$NEW"
eq "volume create fails: no copy" 0 "$(count_kind 'run rsync-copy')"
eq "volume create fails: no marker-set" 0 "$(count_kind 'run marker-set')"
eq "volume create fails: the marker is still ready, byte for byte" "$MS_BEFORE" "$(cat "$GDIR/$MARKER_NAME")"
lacks "volume create fails: no report" "$OUT" "rolled_back:"
expect_lock_released "volume create fails"
expect_original_untouched "volume create fails"

# The copy is killed: the new volume is left as it is, and the next attempt
# needs a new name.
world
ready_dir
MS_BEFORE="$(cat "$GDIR/$MARKER_NAME")"
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime rsync-kill
fake_fail_nth rsync-kill 1 137
PATH="$SAVED_PATH"
rb P_KILL_GATE="$DXE_FAKE_RUNTIME_DIR/rsync-kill"
eq "killed copy: exit 1" 1 "$RC"
eq "killed copy: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "killed copy: the Error names the volume" "$(grep '^Error:' <<<"$ERR" || true)" "$NEW"
has "killed copy: the Error says to run again with another --volume" "$(grep '^Error:' <<<"$ERR" || true)" "--volume"
eq "killed copy: the marker is still ready, byte for byte" "$MS_BEFORE" "$(cat "$GDIR/$MARKER_NAME")"
eq "killed copy: no verification" 0 "$(count_kind 'run manifest')"
eq "killed copy: no marker-set" 0 "$(count_kind 'run marker-set')"
lacks "killed copy: no report" "$OUT" "rolled_back:"
ok "killed copy: the partial volume is kept" test -d "$NEWVOL"
not "killed copy: the copy is partial" test -e "$NEWVOL/nested"
ok "killed copy: its labels are kept" test -f "$LABELS/$NEW"
expect_never_started "killed copy"
expect_lock_released "killed copy"
expect_original_untouched "killed copy"
eq "killed copy: the directory's data is unchanged" "$DIR_BEFORE" "$DIR_AFTER"
PARTIAL="$(snap "$NEWVOL")"
rb
expect_refused "after a killed copy, the same --volume again" "$NEW" "exists"
rb -- --volume dx-fix-rollback2
expect_ok_run "after a killed copy, a new --volume"
eq "a new --volume: the partial volume is still there, unchanged" "$PARTIAL" "$(snap "$NEWVOL")"
eq "a new --volume: the copy is complete there" deep "$(cat "$VOLROOT/dx-fix-rollback2/nested/a/b/c/deep.txt" 2>/dev/null)"
eq "a new --volume: the marker is retired" retired "$(marker_field "$GDIR/$MARKER_NAME" state)"

# The verification fails: exit 3, the directory stays ready and usable.
world
ready_dir
MS_BEFORE="$(cat "$GDIR/$MARKER_NAME")"
rb P_CORRUPT=yes
eq "failed verification: exit 3" 3 "$RC"
eq "failed verification: exactly one Error: line" 1 "$(error_lines "$ERR")"
has "failed verification: the Error names the volume" "$(grep '^Error:' <<<"$ERR" || true)" "$NEW"
has "failed verification: the Error says the directory stays ready" "$(grep '^Error:' <<<"$ERR" || true)" "ready"
eq "failed verification: the manifest compare ran" 1 "$(count_kind 'run manifest')"
eq "failed verification: no marker-set" 0 "$(count_kind 'run marker-set')"
eq "failed verification: the marker is still ready, byte for byte" "$MS_BEFORE" "$(cat "$GDIR/$MARKER_NAME")"
ok "failed verification: the new volume is left for inspection" test -d "$NEWVOL"
lacks "failed verification: no report" "$OUT" "rolled_back:"
expect_never_started "failed verification"
expect_lock_released "failed verification"
expect_original_untouched "failed verification"
eq "failed verification: the D-7 record is unchanged" "$STATE_BEFORE" "$STATE_AFTER"
start_check
eq "failed verification: the guest can still start on the directory (WP4.3: ready)" 0 "$RC"
world
ready_dir
rb P_MANIFEST_FORCE_RC=2
eq "the verification cannot run (manifest error): exit 3" 3 "$RC"
eq "the verification cannot run: the marker stays ready" ready "$(marker_field "$GDIR/$MARKER_NAME" state)"
eq "the verification cannot run: no marker-set" 0 "$(count_kind 'run marker-set')"

# The retire step fails (the marker-set container's mv).
world
ready_dir
MS_BEFORE="$(cat "$GDIR/$MARKER_NAME")"
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime mv
fake_fail_nth mv 1 1
PATH="$SAVED_PATH"
rb P_CPRE="$DXE_FAKE_RUNTIME_DIR"
eq "marker-set fails: exit 1" 1 "$RC"
eq "marker-set fails: exactly one Error: line" 1 "$(error_lines "$ERR")"
eq "marker-set fails: the marker is still ready, byte for byte" "$MS_BEFORE" "$(cat "$GDIR/$MARKER_NAME")"
lacks "marker-set fails: no report" "$OUT" "rolled_back:"
eq "marker-set fails: the verified volume is kept" deep "$(cat "$NEWVOL/nested/a/b/c/deep.txt" 2>/dev/null)"
expect_lock_released "marker-set fails"

# =============================================================================
test_section "WP6.5: the profile is never edited (through bin/dx-profile)"
world
ready_dir
mkdir -p "$W/profiles"
cat >"$W/profiles/fixprof.env" <<EOF
export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=$NAS
export DX_GUEST_SYSTEM=x86_64-linux
export DX_CONTAINER_NAME=$GUEST
export DX_IMAGE=$IMAGE
export DX_NIX_STORAGE_MODE=direct-volume
export DX_NIX_VOLUME=dx-fix-nix
export DX_PERSIST_VOLUME=$ORIG
export DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
export DX_PERSIST_STORAGE=host-path
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
    bash "$BASE_DIR/bin/dx-profile" fixprof "$WRAPPER" --volume "$NEW"
) >>"$EVLOG" 2>"$W/err" </dev/null
RC=$?
ERR="$(cat "$W/err")"
OUT="$(grep -v '^~EV~ ' "$EVLOG" || true)"
EVENTS="$(sed -n 's/^~EV~ //p' "$EVLOG")"
eq "dx-profile fixprof dx-persist-rollback --volume $NEW: exit 0" 0 "$RC"
has "dx-profile: the report names the profile's directory" "$OUT" "rolled_back: $CDEST"
eq "dx-profile: the marker is retired" retired "$(marker_field "$GDIR/$MARKER_NAME" state)"
if cmp -s "$W/profile.orig" "$W/profiles/fixprof.env"; then test_pass "the profile file is byte-for-byte unchanged"
else test_fail "the profile file is byte-for-byte unchanged"; fi
eq "the profiles directory is unchanged (nothing added, removed or re-moded)" "$PROFILES_BEFORE" "$(snap "$W/profiles")"
eq "the profile still says DX_PERSIST_STORAGE=host-path" "export DX_PERSIST_STORAGE=host-path" \
    "$(grep '^export DX_PERSIST_STORAGE=' "$W/profiles/fixprof.env")"
eq "the profile still says DX_PERSIST_VOLUME=$ORIG" "export DX_PERSIST_VOLUME=$ORIG" \
    "$(grep '^export DX_PERSIST_VOLUME=' "$W/profiles/fixprof.env")"
eq "dx-profile: the lock was the first effect" "docker lock" "$(sed -n 1p <<<"$EVENTS")"
eq "dx-profile: and its release the last" "docker unlock" "$(tail -n 1 <<<"$EVENTS")"

print_summary
exit_with_code
