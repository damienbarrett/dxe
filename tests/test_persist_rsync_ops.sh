#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.2 (plans/do plan.md D-6, D-10 as revised 2026-10-11 and clarified
# 2026-10-11 after the WP6.2 verifier, finding A; spec R31, R32): acceptance
# tests for the rsync and volume-source operations. Written before the
# operations exist; the implementer builds them to satisfy exactly this
# contract. Amended by WP6.2b: rsync runs from the guest's nix volume.
#
# Interface contract (every name, argument, argv and message below is pinned):
#
#  Both operations are declared in bin/lib/dx-runtime.sh as
#      dx_runtime_host_rsync_check() { dx_runtime_dispatch host_rsync_check "$@"; }
#      dx_runtime_host_rsync()       { dx_runtime_dispatch host_rsync "$@"; }
#  and implemented as dx_runtime_docker_host_rsync_check / _host_rsync
#  (DX_RUNTIME=docker-ssh) and dx_runtime_apple_host_rsync_check / _host_rsync
#  (DX_RUNTIME=apple). Apple: non-zero, "unsupported" on stderr, nothing on
#  stdout, and NO runtime tool is called. (QTS's own rsync is 3.0.7 and the NAS
#  account is not root, so rsync runs INSIDE a one-off container on the NAS,
#  root via Docker.) Every docker call goes through the existing transport
#  (dx_runtime_docker_ssh_exec: one ssh call per docker call, arguments quoted
#  by dx_runtime_docker_quote_argv, no shell interpolation of any path).
#
#  Where rsync comes from (D-10, clarified): on docker-ssh $DX_IMAGE is only
#  the bare nixos/nix base image; the guest's tools, including
#  bootstrapEssentials' rsync, live in the guest's NIX VOLUME, in the root
#  profile /nix/var/nix/profiles/per-user/root/profile. So EVERY rsync
#  container (the check and both copy directions):
#    - first runs the DQ6 ownership check on the configured nix volume,
#          dx_runtime_docker_volume_owned "$DX_NIX_VOLUME" "run rsync from"
#      (role nix, derived from the name as for every DQ6 check; one
#      `volume inspect` call). Another profile's volume, a volume carrying
#      another role, an absent volume and an empty DX_NIX_VOLUME (no fallback
#      to a default name, even when a "dx-nix" volume of this profile exists)
#      are refused with that check's wording ("Error: refusing to run rsync
#      from volume '<name>': ..."; absent: "... it does not exist."), nothing
#      on stdout, and NO `run`;
#    - mounts that volume READ-ONLY at /nix: `-v <DX_NIX_VOLUME>:/nix:ro`;
#    - runs the absolute entrypoint
#          --entrypoint /nix/var/nix/profiles/per-user/root/profile/bin/rsync
#      (never a bare `rsync`);
#    - pins `--user 0:0` and `--pull never` beside `--rm --network none`.
#  The common prefix of every rsync `run`, in this exact order, is
#      run --rm --network none --user 0:0 --pull never -v <DX_NIX_VOLUME>:/nix:ro
#  The volume name always comes from the configuration (DX_NIX_VOLUME); this
#  suite sets it to dx-fix-nix.
#
#  dx_runtime_host_rsync_check [-A] [-X]
#    -A: ACL support is needed; -X: extended-attribute support is needed.
#    Makes exactly TWO docker calls, in this order: the nix volume's DQ6
#    `volume inspect`, then ONE `run` with exactly this argv ($DX_IMAGE is the
#    configured image; no other volume or host path is mounted):
#        run --rm --network none --user 0:0 --pull never
#            -v <DX_NIX_VOLUME>:/nix:ro
#            --entrypoint /nix/var/nix/profiles/per-user/root/profile/bin/rsync
#            $DX_IMAGE --version
#    A run that exits 127 (docker: the entrypoint is missing, "executable file
#    not found" / "no such file or directory": the guest's root profile has no
#    rsync yet) is refused with exactly ONE line starting "Error:" on stderr
#    that names the nix volume and contains the fixed strings
#    "boot the guest once" and "include rsync", e.g.
#        Error: rsync is not in the guest's nix volume 'dx-fix-nix'; boot the
#        guest once on the current image so its essentials include rsync.
#    (one line; docker's own stderr may pass through, it does not start with
#    "Error:"). Any other failing run (e.g. 125: image missing under
#    `--pull never`) does NOT say "boot the guest once".
#    It parses the run's stdout:
#      - the version is the first "rsync  version N.N.N" line; it is
#        compared NUMERICALLY by (major, minor, patch; a missing patch is 0)
#        against the floor 3.1.3 (WP6.7: the copy's --modify-window=-1
#        compares nanoseconds only from 3.1.3): 3.1.3, 3.10.0 and 4.0.0
#        pass, 3.0.7 and 2.6.9 are refused ("below 3.1.3" in the message,
#        with the version found named in it; 3.1.2 and the rest of the
#        floor are pinned by tests/test_persist_followup_hardening.sh B);
#      - capabilities are the comma-separated tokens after "Capabilities:"
#        up to the "Optimizations:" line (or the end), whitespace-trimmed,
#        across the wrapped lines. A capability is present only as an
#        EXACT token: "hardlinks" (or the older spelling "hard links"),
#        "ACLs", "xattrs". A token "no ACLs" / "no xattrs" / "no hardlinks"
#        means absent, and "hardlink-specials" / "hardlink-symlinks" do not
#        count as hard-link support;
#      - hard-link support is always required; ACLs only with -A; xattrs only
#        with -X.
#    On success: status 0 and stdout is exactly four lines
#        version=<N.N.N>
#        hard_links=yes
#        acls=yes|no
#        xattrs=yes|no
#    On refusal: non-zero, nothing on stdout, and ONE line starting "Error:"
#    on stderr naming rsync and the gap only: "below 3.1.3" plus the version,
#    "hard links", "ACLs" or "xattrs" respectively (the message for one gap
#    does not mention the others). Unparseable output (no version line) is
#    refused with "could not parse" in the message; a failing docker run is
#    refused with its non-zero status mapped to non-zero. An unknown option
#    is a usage error: non-zero, "Usage:" on stderr, no call at all (not even
#    the inspect).
#
#  dx_runtime_host_rsync DIRECTION VOLUME DIR [-A] [-X]
#    DIRECTION is "forward" (VOLUME -> DIR, the migration) or "reverse"
#    (DIR -> VOLUME, the rollback). DIR is an absolute host path on the NAS
#    (no ",", no newline, not "/"); -A / -X are the only options (they may
#    be combined; anything else, e.g. --delete, is refused). Refusals are
#    non-zero, an "Error:" line on stderr, nothing on stdout, and NO docker
#    run. Usage errors, an unknown direction or option and a bad DIR are
#    found before any remote call: NO docker call at all.
#    VOLUME must be the configured persist volume: VOLUME equal to
#    DX_NIX_VOLUME is refused (an Error: line, no run) even though its DQ6
#    labels are this profile's -- the nix volume is already mounted at /nix,
#    and a reverse copy would write into the guest's store.
#    Then, in this order, exactly three docker calls:
#     1. VOLUME's DQ6 ownership with the existing dx_runtime_docker_volume_owned
#        (role derived from the configured name; a `volume inspect`): another
#        profile's volume, another role, an absent volume and an unconfigured
#        name are refused with the "refusing" wording that check prints, and
#        nothing is run;
#     2. the nix volume's DQ6 check (above; refused the same way, no run);
#     3. exactly ONE `run`, whose argv (NIX = $DX_NIX_VOLUME; VOLUME and DIR
#        are the data; RSYNC = /nix/var/nix/profiles/per-user/root/profile/bin/rsync) is:
#     forward:
#        run --rm --network none --user 0:0 --pull never -v NIX:/nix:ro
#            -v VOLUME:/src:ro
#            --mount type=bind,source=DIR,target=/dst
#            --name dxe-persist-copy-PID LABELS(persist-copy)   (WP6.4c)
#            --entrypoint RSYNC $DX_IMAGE
#            -aH --numeric-ids --inplace --modify-window=-1 [-A] [-X]   (WP6.4c)
#            --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/
#     reverse:
#        run --rm --network none --user 0:0 --pull never -v NIX:/nix:ro
#            --mount type=bind,source=DIR,target=/src,readonly
#            -v VOLUME:/dst
#            --name dxe-persist-copy-PID LABELS(persist-copy)   (WP6.4c)
#            --entrypoint RSYNC $DX_IMAGE
#            -aH --numeric-ids --inplace --modify-window=-1 [-A] [-X]   (WP6.4c)
#            --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/
#    (WP6.4c, tests/test_persist_copy_resume.sh B: PID is the DQ6 profile id;
#    LABELS(ROLE) is dx_runtime_docker_label_flags ROLE.)
#    "-A" comes before "-X" when both are given. `--exclude=._*` is ONE argv
#    word (no shell globbing anywhere). The host directory is always a
#    `--mount` (a missing source then fails instead of being created), never
#    -v/--volume; the only -v words are the nix volume (read-only) and
#    VOLUME. The container's stdout/stderr pass through and its exit status
#    is returned unchanged.
#
#  The rsync argument list (everything after the image) is what the fidelity
#  cases below run for real, minus docker, against WP0.2 fixture trees under
#  the Linux coverage container: the same words with /src/ and /dst/ replaced
#  by local directories, then dx-persist-manifest.sh verify must match. (That
#  section runs the host's own rsync directly; it takes the words from the
#  recorded `run` call, whichever call number it is.)
#
#  The essentials pin: bootstrapEssentials in container/dx-nixos-26.05/flake.nix
#  lists rsync (the host-path migration's rsync comes from the guest's root
#  profile in its nix volume, installed there at boot).
#  RED is shown on the Mac by the list check (no nix needed); where nix is
#  available the evaluated checks.<system>.bootstrap-essentials is also asked
#  for its package names. CI evaluates only (--no-build), which is enough.
#
#  Not covered here (the plan's volume_mountpoint): the D-10 revision moves
#  all root-only volume access into one-off containers, so no host-side
#  volume path is ever needed; WP6.2 does not add dx_runtime_volume_mountpoint.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "WP6.2: rsync and volume-source operations"

REAL_NIX="$(command -v nix 2>/dev/null || true)"
SCRATCH="$(persist_fixture_root_create)" || exit 1
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT

eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE (fixed string, one line)
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
have_fn() { type "$1" >/dev/null 2>&1; }

# --- the recording fakes ------------------------------------------------------
# One fake ssh (evaluates the already-quoted remote command here, like a login
# shell would) and one fake docker that records every call's argv, one word
# per line, in $FAKE_DOCKER_DIR/calls/N, answers `volume inspect` from
# $FAKE_DOCKER_DIR/labels/<name> and `run` from run.out / run.err / run.rc.
TOOLS="$(fake_tool_dir_create "$SCRATCH")" || exit 1
fake_qnap_ssh_write "$TOOLS"
fake_tool_write "$TOOLS" docker 'd="${FAKE_DOCKER_DIR:?}"
mkdir -p "$d/calls"
n=$(( $(ls "$d/calls" | wc -l) + 1 ))
printf "%s\n" "$@" > "$d/calls/$n"
case "$1 $2" in
    "volume inspect")
        for a in "$@"; do name="$a"; done
        if [ -f "$d/labels/$name" ]; then cat "$d/labels/$name"; exit 0; fi
        echo "Error: No such volume: $name" >&2
        exit 1
        ;;
    "run --rm")
        if [ -f "$d/run.out" ]; then cat "$d/run.out"; fi
        if [ -f "$d/run.err" ]; then cat "$d/run.err" >&2; fi
        rc=0
        if [ -f "$d/run.rc" ]; then rc="$(cat "$d/run.rc")"; fi
        exit "$rc"
        ;;
esac
echo "fake docker: unexpected call: $*" >&2
exit 98'
PATH="$TOOLS:$PATH"
export PATH
export DXE_RUNTIME_DOCKER_BIN="$TOOLS/docker"
export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
export DX_CONTAINER_NAME=dx-fix DX_GUEST_SYSTEM=x86_64-linux
export DX_IMAGE=dxe-rsync-image:7
export DX_PERSIST_VOLUME=dx-fix-persist
export DX_NIX_VOLUME=dx-fix-nix
unset DXE_FAKE_SSH_REMOTE_PATH DX_BOOTSTRAP_VOLUME

PROFILE="${PERSIST_FIXTURE_NAS_HOST}__dx-fix"
OWN_LABELS="true|1|$PROFILE|persist|x86_64-linux"
NIX_LABELS="true|1|$PROFILE|nix|x86_64-linux"
RSYNC_EP=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
# The common prefix of every rsync container's argv (D-10 clarified).
RUN_PREFIX="<run><--rm><--network><none><--user><0:0><--pull><never><-v><dx-fix-nix:/nix:ro>"

new_fake() { # fresh recording area; sets and exports FAKE_DOCKER_DIR
    dxe_test_mktemp_dir FAKE_DOCKER_DIR "$SCRATCH/dxe-fake-docker.XXXXXX"
    export FAKE_DOCKER_DIR
    mkdir "$FAKE_DOCKER_DIR/calls" "$FAKE_DOCKER_DIR/labels"
}
set_labels() { printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/labels/$1"; }
ncalls() { ls "$FAKE_DOCKER_DIR/calls" | wc -l | tr -d ' '; }
call_of() { # N -> <word><word>... (one record per docker call)
    if [ ! -f "$FAKE_DOCKER_DIR/calls/$1" ]; then echo "<no call $1>"; return 0; fi
    awk '{ printf "<%s>", $0 } END { print "" }' "$FAKE_DOCKER_DIR/calls/$1"
}
last_word_of() { # N -> the last argv word of call N (the inspected name)
    if [ ! -f "$FAKE_DOCKER_DIR/calls/$1" ]; then echo "<no call $1>"; return 0; fi
    tail -n 1 "$FAKE_DOCKER_DIR/calls/$1"
}
is_inspect_of() { # LABEL N NAME: call N is a `volume inspect` whose last word is NAME
    case "$(call_of "$2")" in
        "<volume><inspect>"*) eq "$1" "$3" "$(last_word_of "$2")" ;;
        *) test_fail "$1 (call $2 is not a volume inspect: $(call_of "$2"))" ;;
    esac
}
errlines() { # TEXT: number of lines starting with "Error:"
    awk 'index($0, "Error:") == 1 { n++ } END { print n + 0 }' <<<"$1"
}
nruns() { # how many recorded calls were a `run`
    local n=0 f
    for f in "$FAKE_DOCKER_DIR"/calls/*; do
        [ -f "$f" ] || continue
        if [ "$(sed -n 1p "$f")" = run ]; then n=$((n + 1)); fi
    done
    printf '%s' "$n"
}

# Canned `rsync --version` outputs (the capability lines are shaped as the
# real tool prints them).
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
caps_of() { # VERSION CAPS...: a canned output with the given capability text
    local version="$1" caps="$2"
    printf 'rsync  version %s  protocol version 31\nCopyright (C) 1996-2024 by Andrew Tridgell, Wayne Davison, and others.\n\nCapabilities:\n    %s\nOptimizations:\n    SIMD-roll, no asm-roll\n\nrsync comes with ABSOLUTELY NO WARRANTY.\n' "$version" "$caps"
}
CAPS_FULL='64-bit files, socketpairs, symlinks, symtimes, hardlinks, hardlink-specials, hardlink-symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, prealloc'
V_307="$(caps_of 3.0.7 'hardlinks, symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, symtimes, prealloc')"
V_313="$(caps_of 3.1.3 "$CAPS_FULL")"
V_3100="$(caps_of 3.10.0 "$CAPS_FULL")"
V_400="$(caps_of 4.0.0 "$CAPS_FULL")"
V_269="$(caps_of 2.6.9 '64-bit files, socketpairs, hard links, symlinks, batchfiles, inplace, IPv6, 64-bit system inums, 64-bit internal inums')"
V_OLDSPELL="$(caps_of 3.2.7 'socketpairs, symlinks, hard links, IPv6, ACLs, xattrs')"
V_NOHL="$(caps_of 3.3.0 '64-bit files, socketpairs, symlinks, symtimes, no hardlinks, IPv6, atimes, batchfiles, ACLs, xattrs')"
V_HLONLYSPEC="$(caps_of 3.3.0 'socketpairs, symlinks, hardlink-specials, hardlink-symlinks, IPv6, ACLs, xattrs')"
V_NOACL="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, no ACLs, xattrs')"
V_NOXATTR="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, ACLs, no xattrs')"
V_NOBOTH="$(caps_of 3.3.0 'socketpairs, symlinks, hardlinks, IPv6, batchfiles, no ACLs, no xattrs')"

check_rsync() { # OUTPUT [RC] ARGS...: run rsync_check against a canned output
    local output="$1" rc="$2"
    shift 2
    new_fake
    set_labels dx-fix-nix "$NIX_LABELS"
    printf '%s\n' "$output" >"$FAKE_DOCKER_DIR/run.out"
    printf '%s' "$rc" >"$FAKE_DOCKER_DIR/run.rc"
    CHECK_OUT="$(dx_runtime_host_rsync_check "$@" 2>"$SCRATCH/check.err")"
    CHECK_RC=$?
    CHECK_ERR="$(cat "$SCRATCH/check.err")"
}

# ---------------------------------------------------------------------------
test_section "WP6.2: operations are declared and implemented"
for op in host_rsync_check host_rsync; do
    if have_fn "dx_runtime_$op"; then test_pass "dx_runtime_$op is declared (dx-runtime.sh)"; else test_fail "dx_runtime_$op is declared (dx-runtime.sh)"; fi
    for adapter in docker apple; do
        if have_fn "dx_runtime_${adapter}_$op"; then test_pass "dx_runtime_${adapter}_$op is implemented"; else test_fail "dx_runtime_${adapter}_$op is implemented"; fi
    done
done

# ---------------------------------------------------------------------------
test_section "WP6.2: the guest image ships rsync"
FLAKE="$CONTAINER_DIR/flake.nix"
essentials="$(awk '/bootstrapEssentials = with pkgs; \[/ { on = 1; next } on && /^[[:space:]]*\];/ { exit } on { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "$FLAKE")"
if grep -Fqx rsync <<<"$essentials"; then test_pass "bootstrapEssentials lists rsync (one package per line)"; else test_fail "bootstrapEssentials lists rsync (one package per line)"; fi
if grep -Fqx openssh <<<"$essentials"; then test_pass "the list was read correctly (it still holds openssh)"; else test_fail "the list was read correctly (it still holds openssh)"; fi
if [ -n "$REAL_NIX" ]; then
    for system in aarch64-linux x86_64-linux; do
        names="$("$REAL_NIX" eval --json --no-write-lock-file "$CONTAINER_DIR#checks.$system.bootstrap-essentials" \
            --apply 'd: map (p: (builtins.parseDrvName p.name).name) d.paths' 2>&1)"
        if grep -Fq '"rsync"' <<<"$names"; then test_pass "checks.$system.bootstrap-essentials evaluates with rsync in it"; else test_fail "checks.$system.bootstrap-essentials evaluates with rsync in it (got: $names)"; fi
    done
else
    test_skip "nix is not available; the evaluated bootstrap-essentials package names are checked by CI's Linux job"
fi

if ! have_fn dx_runtime_host_rsync_check || ! have_fn dx_runtime_docker_host_rsync_check; then
    test_fail "rsync_check cases need dx_runtime_host_rsync_check and its docker implementation"
else
    # -----------------------------------------------------------------------
    test_section "WP6.2: rsync_check accepts capable builds and runs rsync from the guest's nix volume"
    check_rsync "$V_330" 0
    eq "3.3.0: status 0" "0" "$CHECK_RC"
    eq "3.3.0: stdout is the four fact lines" "version=3.3.0
hard_links=yes
acls=yes
xattrs=yes" "$CHECK_OUT"
    eq "3.3.0: nothing on stderr" "" "$CHECK_ERR"
    eq "3.3.0: exactly two docker calls (the nix volume's DQ6 inspect, then the run)" "2" "$(ncalls)"
    is_inspect_of "3.3.0: call 1 is the DQ6 inspect of the configured nix volume" 1 dx-fix-nix
    eq "3.3.0: the exact one-off container argv (nix volume read-only at /nix, absolute root-profile rsync, --user 0:0, --pull never)" \
        "$RUN_PREFIX<--entrypoint><$RSYNC_EP><dxe-rsync-image:7><--version>" "$(call_of 2)"
    eq "3.3.0: one run only" "1" "$(nruns)"
    lacks "3.3.0: the nix volume is never mounted writable" "$(call_of 2)" "<dx-fix-nix:/nix>"
    lacks "3.3.0: no bare rsync entrypoint" "$(call_of 2)" "<--entrypoint><rsync>"
    # The name comes from the configuration, not a constant.
    new_fake
    set_labels dx-other-nix "$NIX_LABELS"
    printf '%s\n' "$V_330" >"$FAKE_DOCKER_DIR/run.out"
    CHECK_OUT="$(DX_NIX_VOLUME=dx-other-nix dx_runtime_host_rsync_check 2>"$SCRATCH/check.err")"
    CHECK_RC=$?
    eq "another configured DX_NIX_VOLUME: accepted" "0" "$CHECK_RC"
    is_inspect_of "another configured DX_NIX_VOLUME: that volume is the one inspected" 1 dx-other-nix
    eq "another configured DX_NIX_VOLUME: that volume is the one mounted at /nix" \
        "<run><--rm><--network><none><--user><0:0><--pull><never><-v><dx-other-nix:/nix:ro><--entrypoint><$RSYNC_EP><dxe-rsync-image:7><--version>" "$(call_of 2)"
    check_rsync "$V_313" 0 -A -X
    eq "3.1.3 with -A -X: accepted" "0:version=3.1.3
hard_links=yes
acls=yes
xattrs=yes" "$CHECK_RC:$CHECK_OUT"
    check_rsync "$V_3100" 0 -A -X
    eq "3.10.0 is newer than 3.1 (numeric compare)" "0:version=3.10.0" "$CHECK_RC:$(sed -n 1p <<<"$CHECK_OUT")"
    check_rsync "$V_400" 0
    eq "4.0.0 is accepted" "0:version=4.0.0" "$CHECK_RC:$(sed -n 1p <<<"$CHECK_OUT")"
    check_rsync "$V_OLDSPELL" 0
    eq "the older 'hard links' spelling counts as hard-link support" "0:hard_links=yes" "$CHECK_RC:$(sed -n 2p <<<"$CHECK_OUT")"

    # -----------------------------------------------------------------------
    test_section "WP6.2: rsync_check refuses what the migration cannot rely on"
    check_rsync "$V_307" 0
    if [ "$CHECK_RC" != 0 ]; then test_pass "3.0.7 (the QTS build) is refused"; else test_fail "3.0.7 (the QTS build) is refused"; fi
    has "3.0.7: the message names the version" "$CHECK_ERR" "3.0.7"
    has "3.0.7: the message says below 3.1.3 (WP6.7: the floor is 3.1.3)" "$CHECK_ERR" "below 3.1.3"
    eq "3.0.7: Error: line, nothing on stdout" "Error:|" "$(printf '%s' "$CHECK_ERR" | cut -d' ' -f1)|$CHECK_OUT"
    check_rsync "$V_269" 0
    if [ "$CHECK_RC" != 0 ]; then test_pass "2.6.9 is refused"; else test_fail "2.6.9 is refused"; fi
    has "2.6.9: the message names the version" "$CHECK_ERR" "2.6.9"
    check_rsync "$V_NOHL" 0
    if [ "$CHECK_RC" != 0 ]; then test_pass "a build with 'no hardlinks' is refused"; else test_fail "a build with 'no hardlinks' is refused"; fi
    has "no hardlinks: the message names hard links" "$CHECK_ERR" "hard links"
    lacks "no hardlinks: the message does not blame ACLs" "$CHECK_ERR" "ACLs"
    check_rsync "$V_HLONLYSPEC" 0
    if [ "$CHECK_RC" != 0 ]; then test_pass "hardlink-specials / hardlink-symlinks alone are not hard-link support"; else test_fail "hardlink-specials / hardlink-symlinks alone are not hard-link support"; fi
    check_rsync "$V_NOACL" 0 -A
    if [ "$CHECK_RC" != 0 ]; then test_pass "'no ACLs' is refused when -A is needed"; else test_fail "'no ACLs' is refused when -A is needed"; fi
    has "no ACLs: the message names ACLs" "$CHECK_ERR" "ACLs"
    lacks "no ACLs: the message does not blame xattrs" "$CHECK_ERR" "xattrs"
    check_rsync "$V_NOACL" 0
    eq "'no ACLs' is fine when ACLs are not needed, and reported" "0:acls=no" "$CHECK_RC:$(sed -n 3p <<<"$CHECK_OUT")"
    check_rsync "$V_NOACL" 0 -X
    eq "'no ACLs' with only -X needed: accepted" "0:xattrs=yes" "$CHECK_RC:$(sed -n 4p <<<"$CHECK_OUT")"
    check_rsync "$V_NOXATTR" 0 -X
    if [ "$CHECK_RC" != 0 ]; then test_pass "'no xattrs' is refused when -X is needed"; else test_fail "'no xattrs' is refused when -X is needed"; fi
    has "no xattrs: the message names xattrs" "$CHECK_ERR" "xattrs"
    lacks "no xattrs: the message does not blame ACLs" "$CHECK_ERR" "ACLs"
    check_rsync "$V_NOXATTR" 0 -A
    eq "'no xattrs' with only -A needed: accepted" "0:xattrs=no" "$CHECK_RC:$(sed -n 4p <<<"$CHECK_OUT")"
    check_rsync "$V_NOBOTH" 0 -A -X
    if [ "$CHECK_RC" != 0 ]; then test_pass "a build with neither is refused when both are needed"; else test_fail "a build with neither is refused when both are needed"; fi
    check_rsync "$V_NOBOTH" 0
    eq "a build with neither is fine when neither is needed" "0:acls=no:xattrs=no" "$CHECK_RC:$(sed -n 3p <<<"$CHECK_OUT"):$(sed -n 4p <<<"$CHECK_OUT")"
    check_rsync "this is not rsync output" 0
    if [ "$CHECK_RC" != 0 ]; then test_pass "output without a version line is refused"; else test_fail "output without a version line is refused"; fi
    has "unparseable output: the message says could not parse" "$CHECK_ERR" "could not parse"
    check_rsync "" 125
    if [ "$CHECK_RC" != 0 ]; then test_pass "a failing docker run (image missing, daemon down) is refused"; else test_fail "a failing docker run (image missing, daemon down) is refused"; fi
    eq "a failing docker run: nothing on stdout" "" "$CHECK_OUT"
    lacks "a failing docker run (125): not blamed on a missing rsync" "$CHECK_ERR" "boot the guest once"
    check_rsync "$V_330" 0 --bogus
    if [ "$CHECK_RC" != 0 ]; then test_pass "an unknown option is refused"; else test_fail "an unknown option is refused"; fi
    has "unknown option: usage on stderr" "$CHECK_ERR" "Usage:"
    eq "unknown option: no docker call (not even the inspect)" "0" "$(ncalls)"

    # -----------------------------------------------------------------------
    test_section "WP6.2: rsync_check when the guest's nix volume has no rsync yet"
    new_fake
    set_labels dx-fix-nix "$NIX_LABELS"
    printf '127' >"$FAKE_DOCKER_DIR/run.rc"
    printf '%s\n' "docker: Error response from daemon: failed to create task for container: exec: \"$RSYNC_EP\": stat $RSYNC_EP: no such file or directory: unknown." >"$FAKE_DOCKER_DIR/run.err"
    CHECK_OUT="$(dx_runtime_host_rsync_check 2>"$SCRATCH/check.err")"
    CHECK_RC=$?
    CHECK_ERR="$(cat "$SCRATCH/check.err")"
    if [ "$CHECK_RC" != 0 ]; then test_pass "rsync missing from the root profile (run exits 127): refused"; else test_fail "rsync missing from the root profile (run exits 127): refused"; fi
    eq "rsync missing: nothing on stdout" "" "$CHECK_OUT"
    eq "rsync missing: exactly one Error: line" "1" "$(errlines "$CHECK_ERR")"
    ERRLINE="$(grep -F 'Error:' <<<"$CHECK_ERR" | head -n 1)"
    has "rsync missing: the Error says to boot the guest once" "$ERRLINE" "boot the guest once"
    has "rsync missing: ... so that its essentials include rsync" "$ERRLINE" "include rsync"
    has "rsync missing: the Error names the nix volume" "$ERRLINE" "dx-fix-nix"
    lacks "rsync missing: not reported as unparseable output" "$ERRLINE" "could not parse"

    # -----------------------------------------------------------------------
    test_section "WP6.2: rsync_check refuses a nix volume that fails DQ6 (no run)"
    nix_check_refused() { # LABEL NEEDLE: rsync_check after the case set up the labels
        printf '%s\n' "$V_330" >"$FAKE_DOCKER_DIR/run.out"
        CHECK_OUT="$(dx_runtime_host_rsync_check "${@:3}" 2>"$SCRATCH/check.err")"
        CHECK_RC=$?
        CHECK_ERR="$(cat "$SCRATCH/check.err")"
        if [ "$CHECK_RC" != 0 ]; then test_pass "$1: refused"; else test_fail "$1: refused"; fi
        eq "$1: nothing on stdout" "" "$CHECK_OUT"
        has "$1: the DQ6 refusal wording" "$CHECK_ERR" "$2"
        eq "$1: no docker run" "0" "$(nruns)"
    }
    new_fake
    set_labels dx-fix-nix "true|1|other-host__other-guest|nix|x86_64-linux"
    nix_check_refused "another profile's nix volume" "refusing to run rsync from volume 'dx-fix-nix'"
    eq "another profile's nix volume: only the inspect was made" "1" "$(ncalls)"
    new_fake
    set_labels dx-fix-nix "true|1|$PROFILE|persist|x86_64-linux"
    nix_check_refused "a nix volume carrying another role" "refusing to run rsync from volume 'dx-fix-nix'"
    new_fake
    nix_check_refused "an absent nix volume" "does not exist"
    has "an absent nix volume: it is named" "$CHECK_ERR" "dx-fix-nix"
    new_fake
    set_labels dx-fix-nix "$NIX_LABELS"
    set_labels dx-nix "$NIX_LABELS"
    DX_NIX_VOLUME_SAVED="$DX_NIX_VOLUME"
    DX_NIX_VOLUME=""
    nix_check_refused "an empty DX_NIX_VOLUME (unconfigured)" "refusing to run rsync from volume"
    DX_NIX_VOLUME="$DX_NIX_VOLUME_SAVED"
    new_fake
    set_labels dx-fix-nix "true|1|other-host__other-guest|nix|x86_64-linux"
    nix_check_refused "another profile's nix volume, with -A -X" "refusing" -A -X
fi

# ---------------------------------------------------------------------------
test_section "WP6.2: Apple answers unsupported and makes no call"
apple_cases() {
    local calls="$SCRATCH/apple-calls" atools out err rc
    atools="$(fake_tool_dir_create "$SCRATCH")" || exit 1
    : >"$calls"
    local t
    for t in container ssh docker; do
        fake_tool_write "$atools" "$t" "echo $t >> '$calls'; exit 99"
    done
    if ! have_fn dx_runtime_host_rsync_check || ! have_fn dx_runtime_host_rsync; then
        test_fail "apple cases need both operations declared"
        return
    fi
    out="$(DX_RUNTIME=apple PATH="$atools:$PATH" dx_runtime_host_rsync_check 2>"$SCRATCH/apple.err")"
    rc=$?
    err="$(cat "$SCRATCH/apple.err")"
    if [ "$rc" != 0 ] && [ "$rc" != 99 ]; then test_pass "apple rsync_check: non-zero status"; else test_fail "apple rsync_check: non-zero status (rc=$rc)"; fi
    eq "apple rsync_check: nothing on stdout" "" "$out"
    has "apple rsync_check: stderr says unsupported" "$err" "unsupported"
    out="$(DX_RUNTIME=apple PATH="$atools:$PATH" dx_runtime_host_rsync forward dx-fix-persist "$SCRATCH" 2>"$SCRATCH/apple.err")"
    rc=$?
    err="$(cat "$SCRATCH/apple.err")"
    if [ "$rc" != 0 ] && [ "$rc" != 99 ]; then test_pass "apple host_rsync: non-zero status"; else test_fail "apple host_rsync: non-zero status (rc=$rc)"; fi
    eq "apple host_rsync: nothing on stdout" "" "$out"
    has "apple host_rsync: stderr says unsupported" "$err" "unsupported"
    eq "apple: no runtime tool was called" "0" "$(wc -l <"$calls" | tr -d ' ')"
}
apple_cases

# --- host_rsync -----------------------------------------------------------------
IMG=dxe-rsync-image:7
TAIL='<--exclude=/.dxe-persist-dir><--exclude=._*></src/></dst/>'
# WP6.4c: the copy container's name and DQ6 labels, before --entrypoint.
COPY_ID="<--name><dxe-persist-copy-$PROFILE><--label><io.dxe.managed=true><--label><io.dxe.schema=1><--label><io.dxe.profile=$PROFILE><--label><io.dxe.role=persist-copy><--label><io.dxe.system=x86_64-linux>"
fwd_argv() { # VOLUME DIR [EXTRA<..>...]
    printf '%s<-v><%s:/src:ro><--mount><type=bind,source=%s,target=/dst>%s<--entrypoint><%s><%s><-aH><--numeric-ids><--inplace><--modify-window=-1>%s%s' \
        "$RUN_PREFIX" "$1" "$2" "$COPY_ID" "$RSYNC_EP" "$IMG" "${3:-}" "$TAIL"
}
rev_argv() { # VOLUME DIR [EXTRA<..>...]
    printf '%s<--mount><type=bind,source=%s,target=/src,readonly><-v><%s:/dst>%s<--entrypoint><%s><%s><-aH><--numeric-ids><--inplace><--modify-window=-1>%s%s' \
        "$RUN_PREFIX" "$2" "$1" "$COPY_ID" "$RSYNC_EP" "$IMG" "${3:-}" "$TAIL"
}
run_rsync() { # ARGS...: sets RS_OUT RS_ERR RS_RC; fresh fake, both volumes owned
    new_fake
    set_labels dx-fix-persist "$OWN_LABELS"
    set_labels dx-fix-nix "$NIX_LABELS"
    RS_OUT="$(dx_runtime_host_rsync "$@" 2>"$SCRATCH/rs.err")"
    RS_RC=$?
    RS_ERR="$(cat "$SCRATCH/rs.err")"
}

if ! have_fn dx_runtime_host_rsync || ! have_fn dx_runtime_docker_host_rsync; then
    test_fail "host_rsync cases need dx_runtime_host_rsync and its docker implementation"
else
    DEST="$SCRATCH/dxe-dest"
    mkdir "$DEST"

    # -----------------------------------------------------------------------
    test_section "WP6.2: host_rsync forward (volume to directory)"
    run_rsync forward dx-fix-persist "$DEST"
    eq "forward: status 0" "0" "$RS_RC"
    eq "forward: two ownership inspects, then exactly one run" "3" "$(ncalls)"
    has "forward: the first call is the volume inspect" "$(call_of 1)" "<volume><inspect>"
    has "forward: the inspect names the volume" "$(call_of 1)" "<dx-fix-persist>"
    is_inspect_of "forward: call 1 inspects the source volume" 1 dx-fix-persist
    is_inspect_of "forward: call 2 inspects the configured nix volume (DQ6, before any run)" 2 dx-fix-nix
    eq "forward: the exact D-10 argv (nix volume read-only at /nix, root-profile rsync)" "$(fwd_argv dx-fix-persist "$DEST")" "$(call_of 3)"
    eq "forward: one run only" "1" "$(nruns)"
    run_rsync forward dx-fix-persist "$DEST" -A
    eq "forward -A: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-A>')" "$(call_of 3)"
    run_rsync forward dx-fix-persist "$DEST" -X
    eq "forward -X: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-X>')" "$(call_of 3)"
    run_rsync forward dx-fix-persist "$DEST" -A -X
    eq "forward -A -X: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-A><-X>')" "$(call_of 3)"
    lacks "forward: the host directory is never a -v/--volume" "$(call_of 3)" "<-v><$DEST"
    lacks "forward: no --delete anywhere" "$(call_of 3)" "delete"
    lacks "forward: the nix volume is never mounted writable" "$(call_of 3)" "<dx-fix-nix:/nix>"

    new_fake
    set_labels dx-fix-persist "$OWN_LABELS"
    set_labels dx-fix-nix "$NIX_LABELS"
    printf 'sent 5 bytes\n' >"$FAKE_DOCKER_DIR/run.out"
    printf 'rsync warning: some files vanished\n' >"$FAKE_DOCKER_DIR/run.err"
    printf '24' >"$FAKE_DOCKER_DIR/run.rc"
    RS_OUT="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    RS_RC=$?
    eq "rsync's exit status passes through unchanged" "24" "$RS_RC"
    eq "rsync's stdout passes through" "sent 5 bytes" "$RS_OUT"
    has "rsync's stderr passes through" "$(cat "$SCRATCH/rs.err")" "some files vanished"

    # -----------------------------------------------------------------------
    test_section "WP6.2: host_rsync reverse (directory to volume, rollback)"
    run_rsync reverse dx-fix-persist "$DEST"
    eq "reverse: status 0" "0" "$RS_RC"
    eq "reverse: two ownership inspects, then exactly one run" "3" "$(ncalls)"
    has "reverse: the first call is the volume inspect" "$(call_of 1)" "<volume><inspect>"
    is_inspect_of "reverse: call 1 inspects the destination volume" 1 dx-fix-persist
    is_inspect_of "reverse: call 2 inspects the configured nix volume" 2 dx-fix-nix
    eq "reverse: the exact argv (source mount read-only, volume as destination, nix read-only)" "$(rev_argv dx-fix-persist "$DEST")" "$(call_of 3)"
    run_rsync reverse dx-fix-persist "$DEST" -A -X
    eq "reverse -A -X: argv" "$(rev_argv dx-fix-persist "$DEST" '<-A><-X>')" "$(call_of 3)"
    lacks "reverse: the host directory is never a -v/--volume" "$(call_of 3)" "<-v><$DEST"
    lacks "reverse: the nix volume is never mounted writable" "$(call_of 3)" "<dx-fix-nix:/nix>"

    # -----------------------------------------------------------------------
    test_section "WP6.2: paths are data, never shell text"
    export PWNED="$SCRATCH/pwned"
    ODD="$SCRATCH/dxe-odd dir\$(touch \"\$PWNED\")'q\"x"
    mkdir "$ODD"
    run_rsync forward dx-fix-persist "$ODD"
    eq "a path with spaces, quotes and a command substitution is passed as one word" "$(fwd_argv dx-fix-persist "$ODD")" "$(call_of 3)"
    if [ -e "$SCRATCH/pwned" ]; then test_fail "the command substitution in a path was not executed"; else test_pass "the command substitution in a path was not executed"; fi
    run_rsync reverse dx-fix-persist "$ODD"
    eq "reverse: same, one word" "$(rev_argv dx-fix-persist "$ODD")" "$(call_of 3)"
    if [ -e "$SCRATCH/pwned" ]; then test_fail "reverse: the command substitution was not executed"; else test_pass "reverse: the command substitution was not executed"; fi

    # -----------------------------------------------------------------------
    test_section "WP6.2: refusals run nothing"
    refused() { # LABEL EXPECTED-WORD ARGS... (both volumes owned)
        local label="$1" word="$2"
        shift 2
        run_rsync "$@"
        if [ "$RS_RC" != 0 ]; then test_pass "$label: refused"; else test_fail "$label: refused"; fi
        eq "$label: nothing on stdout" "" "$RS_OUT"
        has "$label: an Error: line naming the problem" "$RS_ERR" "$word"
        eq "$label: no docker run" "0" "$(nruns)"
    }
    refused_early() { # LABEL EXPECTED-WORD ARGS...: as refused, and found before any remote call
        refused "$@"
        eq "$1: no docker call at all (found before any remote call)" "0" "$(ncalls)"
    }
    new_fake
    set_labels dx-fix-persist "true|1|other-host__other-guest|persist|x86_64-linux"
    set_labels dx-fix-nix "$NIX_LABELS"
    out="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    err="$(cat "$SCRATCH/rs.err")"
    if [ "$rc" != 0 ]; then test_pass "forward from another profile's volume: refused"; else test_fail "forward from another profile's volume: refused"; fi
    has "another profile's volume: the DQ6 refusal wording" "$err" "refusing"
    eq "another profile's volume: nothing on stdout" "" "$out"
    eq "another profile's volume (forward): no docker run" "0" "$(nruns)"
    out="$(dx_runtime_host_rsync reverse dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "reverse into another profile's volume: refused"; else test_fail "reverse into another profile's volume: refused"; fi
    eq "another profile's volume (reverse): no docker run" "0" "$(nruns)"
    new_fake
    set_labels dx-fix-persist "true|1|$PROFILE|nix|x86_64-linux"
    set_labels dx-fix-nix "$NIX_LABELS"
    out="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "a volume carrying another role: refused"; else test_fail "a volume carrying another role: refused"; fi
    eq "another role: no docker run" "0" "$(nruns)"
    new_fake
    set_labels dx-fix-nix "$NIX_LABELS"
    out="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    err="$(cat "$SCRATCH/rs.err")"
    if [ "$rc" != 0 ]; then test_pass "an absent volume: refused"; else test_fail "an absent volume: refused"; fi
    has "an absent volume: says so" "$err" "does not exist"
    eq "an absent volume: no docker run" "0" "$(nruns)"
    new_fake
    set_labels other-volume "$OWN_LABELS"
    set_labels dx-fix-nix "$NIX_LABELS"
    out="$(dx_runtime_host_rsync forward other-volume "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "an unconfigured volume name: refused"; else test_fail "an unconfigured volume name: refused"; fi
    eq "an unconfigured volume name: no docker run" "0" "$(nruns)"

    # The guest's nix volume (where rsync comes from) must pass DQ6 too.
    nix_refused() { # LABEL NEEDLE DIRECTION: host_rsync after the case set up the nix labels
        set_labels dx-fix-persist "$OWN_LABELS"
        out="$(dx_runtime_host_rsync "$3" dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
        rc=$?
        err="$(cat "$SCRATCH/rs.err")"
        if [ "$rc" != 0 ]; then test_pass "$1: refused"; else test_fail "$1: refused"; fi
        eq "$1: nothing on stdout" "" "$out"
        has "$1: the DQ6 refusal wording" "$err" "$2"
        eq "$1: no docker run" "0" "$(nruns)"
    }
    for dir_word in forward reverse; do
        new_fake
        set_labels dx-fix-nix "true|1|other-host__other-guest|nix|x86_64-linux"
        nix_refused "$dir_word with another profile's nix volume" "refusing to run rsync from volume 'dx-fix-nix'" "$dir_word"
        new_fake
        set_labels dx-fix-nix "true|1|$PROFILE|bootstrap|x86_64-linux"
        nix_refused "$dir_word with a nix volume carrying another role" "refusing to run rsync from volume 'dx-fix-nix'" "$dir_word"
        new_fake
        nix_refused "$dir_word with an absent nix volume" "does not exist" "$dir_word"
        has "$dir_word with an absent nix volume: it is named" "$err" "dx-fix-nix"
        new_fake
        set_labels dx-nix "$NIX_LABELS"
        DX_NIX_VOLUME=""
        nix_refused "$dir_word with an empty DX_NIX_VOLUME (unconfigured)" "refusing to run rsync from volume" "$dir_word"
        DX_NIX_VOLUME=dx-fix-nix
    done

    # VOLUME may not be the nix volume itself: it is already at /nix, and a
    # reverse copy would write into the guest's store.
    refused "reverse into the nix volume" "Error:" reverse dx-fix-nix "$DEST"
    refused "forward from the nix volume" "Error:" forward dx-fix-nix "$DEST"

    refused_early "an unknown direction" "Error:" sideways dx-fix-persist "$DEST"
    refused_early "a relative directory" "Error:" forward dx-fix-persist "relative/dir"
    refused_early "an empty directory" "Error:" forward dx-fix-persist ""
    refused_early "the filesystem root as the directory" "Error:" forward dx-fix-persist "/"
    refused_early "a comma in the directory (would inject --mount options)" "Error:" forward dx-fix-persist "$SCRATCH/a,readonly"
    refused_early "--delete as an option" "Error:" forward dx-fix-persist "$DEST" --delete
    refused_early "an unknown option after -A" "Error:" forward dx-fix-persist "$DEST" -A --bogus
    run_rsync forward dx-fix-persist
    if [ "$RS_RC" != 0 ]; then test_pass "a missing directory argument: refused"; else test_fail "a missing directory argument: refused"; fi
    eq "a missing directory argument: no docker run" "0" "$(nruns)"
    run_rsync
    if [ "$RS_RC" != 0 ]; then test_pass "no arguments: refused"; else test_fail "no arguments: refused"; fi
    eq "no arguments: no docker call at all" "0" "$(ncalls)"
fi

# --- fidelity: the SAME argument list, for real ------------------------------------
test_section "WP6.2: fidelity of the rsync argument list (real rsync, Linux)"
fidelity_toolchain_ok() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in
        *"version "[5-9].*) : ;;
        *) return 1 ;;
    esac
    v="$(find --version 2>/dev/null)" || return 1
    case "$v" in
        *"GNU findutils"*) : ;;
        *) return 1 ;;
    esac
    v="$(stat --version 2>/dev/null)" || return 1
    case "$v" in
        *"GNU coreutils"*) : ;;
        *) return 1 ;;
    esac
    command -v sha256sum >/dev/null 2>&1 || return 1
    v="$(rsync --version 2>/dev/null)" || return 1
    v="${v%%$'\n'*}"
    v="${v#*version}"
    v="${v# }"
    v="${v# }"
    case "$v" in
        3.[1-9]*|3.[1-9][0-9]*|[4-9].*) : ;;
        *) return 1 ;;
    esac
}
MANIFEST="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"
if ! fidelity_toolchain_ok; then
    test_skip "needs Bash 5, GNU findutils/coreutils and rsync >= 3.1; covered by run-coverage-linux.sh and CI's Linux job"
elif ! have_fn dx_runtime_host_rsync || ! have_fn dx_runtime_docker_host_rsync; then
    test_fail "fidelity cases need dx_runtime_host_rsync to produce the argument list"
else
    # The argument list is taken from what host_rsync actually asks docker to
    # run: everything after the image word, with /src/ and /dst/ swapped for
    # local directories.
    rsync_words() { # DIRECTION SRCDIR DSTDIR [-A] [-X] -> sets RS_WORDS (array)
        local direction="$1" s="$2" d="$3" f="" c line seen=0
        shift 3
        new_fake
        set_labels dx-fix-persist "$OWN_LABELS"
        set_labels dx-fix-nix "$NIX_LABELS"
        dx_runtime_host_rsync "$direction" dx-fix-persist "$SCRATCH/dxe-dest" "$@" >/dev/null 2>&1
        for c in "$FAKE_DOCKER_DIR"/calls/*; do
            [ -f "$c" ] || continue
            if [ "$(sed -n 1p "$c")" = run ]; then f="$c"; fi
        done
        RS_WORDS=()
        [ -n "$f" ] || return 1
        while IFS= read -r line; do
            if [ "$seen" = 1 ]; then
                case "$line" in
                    /src/) RS_WORDS+=("$s/") ;;
                    /dst/) RS_WORDS+=("$d/") ;;
                    *) RS_WORDS+=("$line") ;;
                esac
            elif [ "$line" = "$IMG" ]; then
                seen=1
            fi
        done <"$f"
        [ "${#RS_WORDS[@]}" -gt 0 ]
    }
    manifest_verify() { # A B -> sets MV_OUT MV_RC
        MV_OUT="$(bash "$MANIFEST" verify "$1" "$2" 2>&1)"
        MV_RC=$?
    }

    SRC="$SCRATCH/dxe-fid-src"
    mkdir "$SRC"
    persist_fixture_tree_build "$SRC"
    printf 'marker\n' >"$SRC/.dxe-persist-dir"
    # Give every entry its own old, nanosecond-precise mtime. A tree built a
    # moment ago shares its whole second with the copy, and rsync then sees
    # no second-level difference on directories and leaves their nanoseconds
    # alone: a fixture artefact, not what a migration of an old tree meets.
    stamp_tree() { # DIR: a distinct mtime (seconds and nanoseconds) per entry
        local i=0 p
        while IFS= read -r -d "" p; do
            i=$((i + 1))
            touch -h -d "@$((1600000000 + i)).$((100000000 + i * 7919))" -- "$p"
        done < <(find "$1" -depth -print0)
    }
    stamp_tree "$SRC"

    # Forward, whole tree.
    FWD="$SCRATCH/dxe-fid-fwd"
    mkdir "$FWD"
    if rsync_words forward "$SRC" "$FWD"; then
        test_pass "the argument list could be taken from host_rsync's docker run"
        rsync "${RS_WORDS[@]}" >/dev/null 2>"$SCRATCH/rsync.err"
        eq "forward: rsync exits 0 on the fixture tree" "0" "$?"
        manifest_verify "$SRC" "$FWD"
        eq "forward: the manifest verify matches (marker and ._* excluded on both sides)" "0" "$MV_RC"
        has "forward: verify says the manifests match" "$MV_OUT" "Manifests match"
        if [ ! -e "$FWD/.dxe-persist-dir" ]; then test_pass "forward: the marker was not copied"; else test_fail "forward: the marker was not copied"; fi
        if [ ! -e "$FWD/._root-meta" ] && [ ! -e "$FWD/nested/a/._deep-meta" ]; then test_pass "forward: ._* files were not copied at any depth"; else test_fail "forward: ._* files were not copied at any depth"; fi
        if [ "$(stat -c %i "$FWD/links/a-one")" = "$(stat -c %i "$FWD/links/a-two")" ] && [ "$(stat -c %i "$FWD/links/a-one")" = "$(stat -c %i "$FWD/nested/a/a-three")" ]; then test_pass "forward: the hard-link group is preserved"; else test_fail "forward: the hard-link group is preserved"; fi

        # Control: the comparison really catches a copy without -H.
        NOH="$SCRATCH/dxe-fid-noh"
        mkdir "$NOH"
        words=()
        for w in "${RS_WORDS[@]}"; do
            if [ "$w" = "$FWD/" ]; then words+=("$NOH/"); elif [ "$w" = -aH ]; then words+=(-a); else words+=("$w"); fi
        done
        rsync "${words[@]}" >/dev/null 2>&1
        manifest_verify "$SRC" "$NOH"
        eq "control: a copy without -H does not verify (hard-link groups differ)" "1" "$MV_RC"
    else
        test_fail "the argument list could be taken from host_rsync's docker run"
    fi

    # -A -X (the inventory found ACLs or xattrs): same fidelity.
    AX="$SCRATCH/dxe-fid-ax"
    mkdir "$AX"
    if rsync_words forward "$SRC" "$AX" -A -X; then
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        eq "forward with -A -X: rsync exits 0" "0" "$?"
        manifest_verify "$SRC" "$AX"
        eq "forward with -A -X: the manifest verify matches" "0" "$MV_RC"
    else
        test_fail "forward with -A -X: the argument list could be taken from host_rsync"
    fi

    # Existing marker in the destination survives a re-run.
    DM="$SCRATCH/dxe-fid-marked"
    mkdir "$DM"
    printf 'dest-marker\n' >"$DM/.dxe-persist-dir"
    if rsync_words forward "$SRC" "$DM"; then
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        eq "a marker already in the destination is left alone" "dest-marker" "$(cat "$DM/.dxe-persist-dir")"
        manifest_verify "$SRC" "$DM"
        eq "the destination with its own marker still verifies" "0" "$MV_RC"
    fi

    # Resume: interrupted copy (part of the tree, a stale partial file), re-run.
    RES="$SCRATCH/dxe-fid-resume"
    mkdir "$RES"
    printf 'part' >"$RES/plain.txt"
    if rsync_words forward "$SRC" "$RES"; then
        partial=(-aH --numeric-ids --exclude=/nested --exclude=/names)
        rest=("${RS_WORDS[@]:2}")
        rsync "${partial[@]}" "${rest[@]}" >/dev/null 2>&1
        manifest_verify "$SRC" "$RES"
        eq "interrupted copy: the half-copied tree does not verify" "1" "$MV_RC"
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        manifest_verify "$SRC" "$RES"
        eq "resume: re-running the same argument list completes it" "0" "$MV_RC"
        eq "resume: the stale partial file was replaced" "plain" "$(cat "$RES/plain.txt")"
        if [ "$(stat -c %i "$RES/links/a-one")" = "$(stat -c %i "$RES/nested/a/a-three")" ]; then test_pass "resume: the hard link across the interrupted part is restored"; else test_fail "resume: the hard link across the interrupted part is restored"; fi
    fi

    # Reverse (rollback): directory back into a new directory standing for the volume.
    BACK="$SCRATCH/dxe-fid-back"
    mkdir "$BACK"
    if rsync_words reverse "$FWD" "$BACK"; then
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        eq "reverse: rsync exits 0" "0" "$?"
        manifest_verify "$SRC" "$BACK"
        eq "reverse: the rolled-back tree verifies against the original source" "0" "$MV_RC"
    else
        test_fail "reverse: the argument list could be taken from host_rsync's docker run"
    fi
fi

print_summary
exit_with_code
