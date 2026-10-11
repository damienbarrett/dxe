#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.2 (plans/do plan.md D-6, D-10 as revised 2026-10-11; spec R31, R32):
# acceptance tests for the rsync and volume-source operations. Written before
# the operations exist; the implementer builds them to satisfy exactly this
# contract.
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
#  root via Docker, from $DX_IMAGE, which ships a modern rsync in
#  bootstrapEssentials.) Every docker call goes through the existing transport
#  (dx_runtime_docker_ssh_exec: one ssh call per docker call, arguments quoted
#  by dx_runtime_docker_quote_argv, no shell interpolation of any path).
#
#  dx_runtime_host_rsync_check [-A] [-X]
#    -A: ACL support is needed; -X: extended-attribute support is needed.
#    Makes exactly ONE docker call, with exactly this argv ($DX_IMAGE is the
#    configured image; nothing else is run, no volume or host path is mounted):
#        run --rm --network none --entrypoint rsync $DX_IMAGE --version
#    and parses its stdout:
#      - the version is the first "rsync  version N.N.N" line; it is
#        compared NUMERICALLY by (major, minor): 3.10.0 and 4.0.0 pass,
#        3.0.7 and 2.6.9 are refused ("below 3.1" in the message, with the
#        version found named in it);
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
#    on stderr naming rsync and the gap only: "below 3.1" plus the version,
#    "hard links", "ACLs" or "xattrs" respectively (the message for one gap
#    does not mention the others). Unparseable output (no version line) is
#    refused with "could not parse" in the message; a failing docker run is
#    refused with its non-zero status mapped to non-zero. An unknown option
#    is a usage error: non-zero, "Usage:" on stderr, no call at all.
#
#  dx_runtime_host_rsync DIRECTION VOLUME DIR [-A] [-X]
#    DIRECTION is "forward" (VOLUME -> DIR, the migration) or "reverse"
#    (DIR -> VOLUME, the rollback). DIR is an absolute host path on the NAS
#    (no ",", no newline, not "/"); -A / -X are the only options (they may
#    be combined; anything else, e.g. --delete, is refused). Refusals are
#    non-zero, an "Error:" line on stderr, nothing on stdout, and NO docker
#    run (usage errors make no docker call at all).
#    First the volume's DQ6 ownership is checked with the existing
#    dx_runtime_docker_volume_owned (role derived from the configured
#    DX_PERSIST_VOLUME; an `volume inspect` call): another profile's volume,
#    another role, an absent volume and an unconfigured name are refused with
#    the "refusing" wording that check prints, and nothing is run.
#    Then exactly ONE `run`, whose argv (VOLUME and DIR are the data) is:
#     forward:
#        run --rm --network none -v VOLUME:/src:ro
#            --mount type=bind,source=DIR,target=/dst
#            --entrypoint rsync $DX_IMAGE
#            -aH --numeric-ids [-A] [-X]
#            --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/
#     reverse:
#        run --rm --network none
#            --mount type=bind,source=DIR,target=/src,readonly
#            -v VOLUME:/dst --entrypoint rsync $DX_IMAGE
#            -aH --numeric-ids [-A] [-X]
#            --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/
#    "-A" comes before "-X" when both are given. `--exclude=._*` is ONE argv
#    word (no shell globbing anywhere). The host directory is always a
#    `--mount` (a missing source then fails instead of being created), never
#    -v/--volume; the only -v is the volume. The container's stdout/stderr
#    pass through and its exit status is returned unchanged.
#
#  The rsync argument list (everything after the image) is what the fidelity
#  cases below run for real, minus docker, against WP0.2 fixture trees under
#  the Linux coverage container: the same words with /src/ and /dst/ replaced
#  by local directories, then dx-persist-manifest.sh verify must match.
#
#  The image pin: bootstrapEssentials in container/dx-nixos-26.05/flake.nix
#  lists rsync (the host-path migration's rsync comes from the guest image).
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
SCRATCH="$(persist_fixture_root_create)"
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
TOOLS="$(fake_tool_dir_create "$SCRATCH")"
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
unset DXE_FAKE_SSH_REMOTE_PATH

PROFILE="${PERSIST_FIXTURE_NAS_HOST}__dx-fix"
OWN_LABELS="true|1|$PROFILE|persist|x86_64-linux"

new_fake() { # fresh recording area; sets and exports FAKE_DOCKER_DIR
    FAKE_DOCKER_DIR="$(mktemp -d "$SCRATCH/dxe-fake-docker.XXXXXX")"
    export FAKE_DOCKER_DIR
    mkdir "$FAKE_DOCKER_DIR/calls" "$FAKE_DOCKER_DIR/labels"
}
set_labels() { printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/labels/$1"; }
ncalls() { ls "$FAKE_DOCKER_DIR/calls" | wc -l | tr -d ' '; }
call_of() { # N -> <word><word>... (one record per docker call)
    awk '{ printf "<%s>", $0 } END { print "" }' "$FAKE_DOCKER_DIR/calls/$1"
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
    test_section "WP6.2: rsync_check accepts capable builds and runs rsync in the image"
    check_rsync "$V_330" 0
    eq "3.3.0: status 0" "0" "$CHECK_RC"
    eq "3.3.0: stdout is the four fact lines" "version=3.3.0
hard_links=yes
acls=yes
xattrs=yes" "$CHECK_OUT"
    eq "3.3.0: nothing on stderr" "" "$CHECK_ERR"
    eq "3.3.0: exactly one docker call" "1" "$(ncalls)"
    eq "3.3.0: the exact one-off container argv" "<run><--rm><--network><none><--entrypoint><rsync><dxe-rsync-image:7><--version>" "$(call_of 1)"
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
    has "3.0.7: the message says below 3.1" "$CHECK_ERR" "below 3.1"
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
    check_rsync "$V_330" 0 --bogus
    if [ "$CHECK_RC" != 0 ]; then test_pass "an unknown option is refused"; else test_fail "an unknown option is refused"; fi
    has "unknown option: usage on stderr" "$CHECK_ERR" "Usage:"
    eq "unknown option: no docker call" "0" "$(ncalls)"
fi

# ---------------------------------------------------------------------------
test_section "WP6.2: Apple answers unsupported and makes no call"
apple_cases() {
    local calls="$SCRATCH/apple-calls" atools out err rc
    atools="$(fake_tool_dir_create "$SCRATCH")"
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
fwd_argv() { # VOLUME DIR [EXTRA<..>...]
    printf '<run><--rm><--network><none><-v><%s:/src:ro><--mount><type=bind,source=%s,target=/dst><--entrypoint><rsync><%s><-aH><--numeric-ids>%s%s' \
        "$1" "$2" "$IMG" "${3:-}" "$TAIL"
}
rev_argv() { # VOLUME DIR [EXTRA<..>...]
    printf '<run><--rm><--network><none><--mount><type=bind,source=%s,target=/src,readonly><-v><%s:/dst><--entrypoint><rsync><%s><-aH><--numeric-ids>%s%s' \
        "$2" "$1" "$IMG" "${3:-}" "$TAIL"
}
run_rsync() { # ARGS...: sets RS_OUT RS_ERR RS_RC; fresh fake with the volume owned
    new_fake
    set_labels dx-fix-persist "$OWN_LABELS"
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
    eq "forward: an ownership inspect, then exactly one run" "2" "$(ncalls)"
    has "forward: the first call is the volume inspect" "$(call_of 1)" "<volume><inspect>"
    has "forward: the inspect names the volume" "$(call_of 1)" "<dx-fix-persist>"
    eq "forward: the exact D-10 argv" "$(fwd_argv dx-fix-persist "$DEST")" "$(call_of 2)"
    eq "forward: one run only" "1" "$(nruns)"
    run_rsync forward dx-fix-persist "$DEST" -A
    eq "forward -A: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-A>')" "$(call_of 2)"
    run_rsync forward dx-fix-persist "$DEST" -X
    eq "forward -X: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-X>')" "$(call_of 2)"
    run_rsync forward dx-fix-persist "$DEST" -A -X
    eq "forward -A -X: argv" "$(fwd_argv dx-fix-persist "$DEST" '<-A><-X>')" "$(call_of 2)"
    lacks "forward: the host directory is never a -v/--volume" "$(call_of 2)" "<-v><$DEST"
    lacks "forward: no --delete anywhere" "$(call_of 2)" "delete"

    new_fake
    set_labels dx-fix-persist "$OWN_LABELS"
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
    eq "reverse: an ownership inspect, then exactly one run" "2" "$(ncalls)"
    has "reverse: the first call is the volume inspect" "$(call_of 1)" "<volume><inspect>"
    eq "reverse: the exact argv (source mount read-only, volume as destination)" "$(rev_argv dx-fix-persist "$DEST")" "$(call_of 2)"
    run_rsync reverse dx-fix-persist "$DEST" -A -X
    eq "reverse -A -X: argv" "$(rev_argv dx-fix-persist "$DEST" '<-A><-X>')" "$(call_of 2)"
    lacks "reverse: the host directory is never a -v/--volume" "$(call_of 2)" "<-v><$DEST"

    # -----------------------------------------------------------------------
    test_section "WP6.2: paths are data, never shell text"
    export PWNED="$SCRATCH/pwned"
    ODD="$SCRATCH/dxe-odd dir\$(touch \"\$PWNED\")'q\"x"
    mkdir "$ODD"
    run_rsync forward dx-fix-persist "$ODD"
    eq "a path with spaces, quotes and a command substitution is passed as one word" "$(fwd_argv dx-fix-persist "$ODD")" "$(call_of 2)"
    if [ -e "$SCRATCH/pwned" ]; then test_fail "the command substitution in a path was not executed"; else test_pass "the command substitution in a path was not executed"; fi
    run_rsync reverse dx-fix-persist "$ODD"
    eq "reverse: same, one word" "$(rev_argv dx-fix-persist "$ODD")" "$(call_of 2)"
    if [ -e "$SCRATCH/pwned" ]; then test_fail "reverse: the command substitution was not executed"; else test_pass "reverse: the command substitution was not executed"; fi

    # -----------------------------------------------------------------------
    test_section "WP6.2: refusals run nothing"
    refused() { # LABEL EXPECTED-WORD ARGS... (volume owned unless the case changed it)
        local label="$1" word="$2"
        shift 2
        run_rsync "$@"
        if [ "$RS_RC" != 0 ]; then test_pass "$label: refused"; else test_fail "$label: refused"; fi
        eq "$label: nothing on stdout" "" "$RS_OUT"
        has "$label: an Error: line naming the problem" "$RS_ERR" "$word"
        eq "$label: no docker run" "0" "$(nruns)"
    }
    new_fake
    set_labels dx-fix-persist "true|1|other-host__other-guest|persist|x86_64-linux"
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
    out="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "a volume carrying another role: refused"; else test_fail "a volume carrying another role: refused"; fi
    eq "another role: no docker run" "0" "$(nruns)"
    new_fake
    out="$(dx_runtime_host_rsync forward dx-fix-persist "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    err="$(cat "$SCRATCH/rs.err")"
    if [ "$rc" != 0 ]; then test_pass "an absent volume: refused"; else test_fail "an absent volume: refused"; fi
    has "an absent volume: says so" "$err" "does not exist"
    eq "an absent volume: no docker run" "0" "$(nruns)"
    new_fake
    set_labels other-volume "$OWN_LABELS"
    out="$(dx_runtime_host_rsync forward other-volume "$DEST" 2>"$SCRATCH/rs.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "an unconfigured volume name: refused"; else test_fail "an unconfigured volume name: refused"; fi
    eq "an unconfigured volume name: no docker run" "0" "$(nruns)"

    refused "an unknown direction" "Error:" sideways dx-fix-persist "$DEST"
    refused "a relative directory" "Error:" forward dx-fix-persist "relative/dir"
    refused "an empty directory" "Error:" forward dx-fix-persist ""
    refused "the filesystem root as the directory" "Error:" forward dx-fix-persist "/"
    refused "a comma in the directory (would inject --mount options)" "Error:" forward dx-fix-persist "$SCRATCH/a,readonly"
    refused "--delete as an option" "Error:" forward dx-fix-persist "$DEST" --delete
    refused "an unknown option after -A" "Error:" forward dx-fix-persist "$DEST" -A --bogus
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
        local direction="$1" s="$2" d="$3" f line seen=0
        shift 3
        new_fake
        set_labels dx-fix-persist "$OWN_LABELS"
        dx_runtime_host_rsync "$direction" dx-fix-persist "$SCRATCH/dxe-dest" "$@" >/dev/null 2>&1
        f="$FAKE_DOCKER_DIR/calls/2"
        RS_WORDS=()
        [ -f "$f" ] || return 1
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
