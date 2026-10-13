#!/bin/bash
# Shared fixture for the root-owned Nix paths hand-back (fix/gc-rootpaths),
# used by tests/test_bootstrap_nix_rootpaths.sh and
# tests/test_nix_gc_rootpaths.sh. Safe to source: functions and constants
# only, nothing runs at import time; Bash 3.2 (the GC suite is bash32).
#
# The real-ownership half of both suites needs root (a non-root process
# cannot create a root-owned file, nor chown one back), so it runs only where
# rp_root_runner_reason prints nothing: Linux, uid 0, GNU find and chown --
# tests/run-coverage-linux.sh's isolated root runner. Everything such a case
# changes lies inside a temporary directory the suite created itself; the
# fixture's own symlinks point only into that directory.

# The stand-in for dx's store owner (numeric on purpose: the bootstrap's own
# hand-back runs before the dx account exists, so it can only use the store
# directory's numeric owner) and for some other non-root owner.
RP_DX_OWNER=4242:4243
RP_OTHER_OWNER=4343:4343

# What the full fixture's hand-back must change, relative to the case
# directory: every root-owned DIRECT store entry together with everything
# inside it (a symlink itself, never its target), the hard link in .links that
# shares an inode with one of those files (an inode has one owner), and every
# root-owned entry beneath the log directory. Nothing else.
# (The RP_HANDED_* constants are read by the suites that source this file.)
# shellcheck disable=SC2034
RP_HANDED_STORE="nix/store/.hidden-root
nix/store/.hidden-root/f
nix/store/.links/0hash-manifest
nix/store/aaaa-profile
nix/store/aaaa-profile/bin
nix/store/aaaa-profile/bin/tool
nix/store/aaaa-profile/manifest.json
nix/store/aaaa-profile/share-link
nix/store/bbbb-bootstrap-essentials.drv
nix/store/cccc-source
nix/store/cccc-source/nested
nix/store/cccc-source/nested/dir-link
nix/store/cccc-source/nested/flake.nix
nix/store/dddd-link"
# shellcheck disable=SC2034
RP_HANDED_LOG="nix/var/log/nix/drvs/ab/cd-root-built.drv.bz2
nix/var/log/nix/drvs/sy
nix/var/log/nix/drvs/sy/bfh-bootstrap-essentials.drv.bz2
nix/var/log/nix/drvs/zz-link"
# Counted once per root-owned direct store entry (5: .hidden-root,
# aaaa-profile, bbbb-bootstrap-essentials.drv, cccc-source, dddd-link) and
# once per root-owned log entry (4).
# shellcheck disable=SC2034
RP_HANDED_COUNT=9
# shellcheck disable=SC2034
RP_HANDED_STORE_COUNT=5

# rp_root_runner_reason -- prints nothing when this process can build and
# judge real-ownership fixtures; otherwise one line saying why not.
rp_root_runner_reason() {
    local version
    if [ "$(uname -s)" != Linux ]; then
        echo "needs Linux and root for real file ownership; runs in tests/run-coverage-linux.sh's isolated root runner"
        return 0
    fi
    if [ "$(id -u)" != 0 ]; then
        echo "needs root for real file ownership; runs in tests/run-coverage-linux.sh's isolated root runner"
        return 0
    fi
    version="$(find --version 2>/dev/null)"
    case "$version" in *"GNU findutils"*) ;; *) echo "needs GNU find"; return 0 ;; esac
    version="$(chown --version 2>/dev/null)"
    case "$version" in *"GNU coreutils"*) ;; *) echo "needs GNU chown"; return 0 ;; esac
}

# rp_case_dir_ok DIR -- DIR is a case directory under one of these suites'
# own mktemp roots (the guard in front of every real chown/chmod/rm below).
rp_case_dir_ok() {
    case "$1" in
        "${TMPDIR:-/tmp}"/dxe-*-rootpaths.*/case.?*) ;;
        *) return 1 ;;
    esac
    case "$1" in *..*) return 1 ;; esac
    [ -d "$1" ] && [ ! -L "$1" ]
}

# rp_fixture_build CASE -- (root only) a stand-in for a guest's /nix under
# CASE, as a dx guest looks after root Nix ran in it (shapes from the probes
# in the Red commit message):
#
#   nix/store                  owner 4242:4243 ("dx"), mode 1775
#     aaaa-profile/            ROOT  a profile environment (dir 0555,
#                                    bin/ 0555, bin/tool 0555,
#                                    manifest.json 0444, share-link -> a
#                                    root-owned file OUTSIDE the Nix tree)
#     bbbb-bootstrap-essentials.drv  ROOT  a derivation file (0444)
#     cccc-source/             ROOT  a flake source copy (nested/ 0555,
#                                    nested/flake.nix 0444, nested/dir-link
#                                    -> a root-owned directory OUTSIDE)
#     dddd-link                ROOT  a top-level symlink -> that outside dir
#     .hidden-root/            ROOT  a dot-entry (f 0444)
#     eeee-dx-own/             dx    (mine dx; shared ROOT: a root-owned
#                                    inode inside a dx path, as auto-optimise
#                                    leaves it -- harmless to GC)
#     .links/                  dx    (0hash-manifest: a hard link to
#                                    aaaa-profile/manifest.json; 0hash-orphan
#                                    ROOT, its own inode)
#     ffff-other/              4343  (root-file ROOT)
#   nix/var/log/nix/drvs       dx
#     sy/                      ROOT  a log bucket root's build created
#       bfh-...drv.bz2         ROOT
#     ab/                      dx    (cd-root-built.drv.bz2 ROOT,
#                                    ef-dx-built.drv.bz2 dx)
#     zz-link                  ROOT  symlink -> the root-owned file OUTSIDE
#   nix/var/nix/{db,gcroots,profiles,temproots}  dx, holding root-owned
#     sentinels the hand-back must never touch: per-user/root/ (ROOT dir)
#     with profile-2-link, gcroots/auto/g60p, temproots/110 (0600);
#     db/db.sqlite is dx's.
#   outside/target-file, outside/target-dir/file   ROOT, never touched
#
# Every store entry's mtime is 1, as Nix leaves it.
rp_fixture_build() {
    local c="$1" s l
    rp_case_dir_ok "$c" || { echo "rp_fixture_build: refusing $c" >&2; return 1; }
    s="$c/nix/store"
    l="$c/nix/var/log/nix"
    mkdir -p "$s" "$l/drvs/sy" "$l/drvs/ab" "$c/nix/var/nix/db" "$c/nix/var/nix/gcroots/auto" \
        "$c/nix/var/nix/profiles/per-user/root" "$c/nix/var/nix/temproots" "$c/outside/target-dir" || return 1
    printf 'outside\n' > "$c/outside/target-file"
    printf 'outside\n' > "$c/outside/target-dir/file"

    mkdir -p "$s/aaaa-profile/bin" "$s/cccc-source/nested" "$s/.hidden-root" "$s/eeee-dx-own" "$s/.links" "$s/ffff-other"
    printf 'tool\n' > "$s/aaaa-profile/bin/tool"
    printf '{}\n' > "$s/aaaa-profile/manifest.json"
    ln -s "$c/outside/target-file" "$s/aaaa-profile/share-link"
    printf 'drv\n' > "$s/bbbb-bootstrap-essentials.drv"
    printf 'src\n' > "$s/cccc-source/nested/flake.nix"
    ln -s "$c/outside/target-dir" "$s/cccc-source/nested/dir-link"
    ln -s "$c/outside/target-dir" "$s/dddd-link"
    printf 'h\n' > "$s/.hidden-root/f"
    printf 'dx\n' > "$s/eeee-dx-own/mine"
    printf 'root inode\n' > "$s/eeee-dx-own/shared"
    ln "$s/aaaa-profile/manifest.json" "$s/.links/0hash-manifest"
    printf 'orphan\n' > "$s/.links/0hash-orphan"
    printf 'r\n' > "$s/ffff-other/root-file"

    printf 'log\n' > "$l/drvs/sy/bfh-bootstrap-essentials.drv.bz2"
    printf 'log\n' > "$l/drvs/ab/cd-root-built.drv.bz2"
    printf 'log\n' > "$l/drvs/ab/ef-dx-built.drv.bz2"
    ln -s "$c/outside/target-file" "$l/drvs/zz-link"

    ln -s "$s/aaaa-profile" "$c/nix/var/nix/profiles/per-user/root/profile-2-link"
    ln -s "$s/aaaa-profile" "$c/nix/var/nix/gcroots/auto/g60p"
    printf 'pid\n' > "$c/nix/var/nix/temproots/110"
    printf 'db\n' > "$c/nix/var/nix/db/db.sqlite"

    chmod 0555 "$s/aaaa-profile/bin/tool"
    chmod 0444 "$s/aaaa-profile/manifest.json" "$s/bbbb-bootstrap-essentials.drv" "$s/cccc-source/nested/flake.nix" \
        "$s/.hidden-root/f" "$s/eeee-dx-own/mine" "$s/eeee-dx-own/shared" "$s/.links/0hash-orphan" "$s/ffff-other/root-file"
    chmod 0600 "$c/nix/var/nix/temproots/110"

    # Everything so far is root's; hand dx (and the other owner) their parts.
    chown -h "$RP_DX_OWNER" "$c/nix" "$c/nix/var" "$c/nix/var/nix" "$c/nix/var/nix/db" "$c/nix/var/nix/db/db.sqlite" \
        "$c/nix/var/nix/gcroots" "$c/nix/var/nix/gcroots/auto" "$c/nix/var/nix/profiles" "$c/nix/var/nix/profiles/per-user" \
        "$c/nix/var/nix/temproots" "$c/nix/var/log" "$l" "$l/drvs" "$l/drvs/ab" "$l/drvs/ab/ef-dx-built.drv.bz2" \
        "$s" "$s/eeee-dx-own" "$s/eeee-dx-own/mine" "$s/.links" || return 1
    chown -h "$RP_OTHER_OWNER" "$s/ffff-other" || return 1

    # Store directories read-only, as Nix leaves them; the store itself 1775.
    chmod 0555 "$s/aaaa-profile/bin" "$s/aaaa-profile" "$s/cccc-source/nested" "$s/cccc-source" "$s/.hidden-root" \
        "$s/eeee-dx-own" "$s/ffff-other"
    chmod 1775 "$s"
    find "$s" -mindepth 1 -exec touch -h -d @1 {} + || return 1
}

# rp_fixture_build_clean CASE -- (root only) the same layout with nothing
# root-owned in the store or the log directory: just dx's store with one dx
# path, dx's log directory, and the out-of-scope root-owned sentinels.
rp_fixture_build_clean() {
    local c="$1" s l
    rp_case_dir_ok "$c" || { echo "rp_fixture_build_clean: refusing $c" >&2; return 1; }
    s="$c/nix/store"
    l="$c/nix/var/log/nix"
    mkdir -p "$s/eeee-dx-own" "$l/drvs" "$c/nix/var/nix/profiles/per-user/root" "$c/nix/var/nix/temproots" || return 1
    printf 'dx\n' > "$s/eeee-dx-own/mine"
    printf 'pid\n' > "$c/nix/var/nix/temproots/110"
    chmod 0600 "$c/nix/var/nix/temproots/110"
    chown -h "$RP_DX_OWNER" "$c/nix" "$c/nix/var" "$c/nix/var/nix" "$c/nix/var/nix/profiles" "$c/nix/var/nix/profiles/per-user" \
        "$c/nix/var/nix/temproots" "$c/nix/var/log" "$l" "$l/drvs" "$s" "$s/eeee-dx-own" "$s/eeee-dx-own/mine" || return 1
    chmod 0444 "$s/eeee-dx-own/mine"
    chmod 0555 "$s/eeee-dx-own"
    chmod 1775 "$s"
}

# rp_manifest CASE -- one line per path of the fixture under CASE (its nix,
# outside and elsewhere trees, relative to CASE; never the suites' own
# logs and captures beside them), C-sorted:
# "path<TAB>uid:gid<TAB>mode<TAB>mtime". GNU find (root runner only); never
# follows a symlink.
rp_manifest() {
    (
        cd "$1" || exit 1
        set --
        for rp_tree in nix outside elsewhere; do
            if [ -e "$rp_tree" ] || [ -L "$rp_tree" ]; then set -- "$@" "$rp_tree"; fi
        done
        [ "$#" -gt 0 ] || exit 0
        find "$@" -printf '%p\t%U:%G\t%m\t%T@\n' | LC_ALL=C sort
    )
}

# rp_expect OWNER PATHS -- reads a manifest on stdin and prints it with the
# owner field of exactly the newline-separated relative PATHS replaced by
# OWNER (modes and mtimes kept).
rp_expect() {
    local owner="$1" paths="$2" line path rest
    while IFS= read -r line; do
        path="${line%%	*}"
        rest="${line#*	}"
        if printf '%s\n' "$paths" | grep -Fx -- "$path" >/dev/null; then
            printf '%s\t%s\t%s\n' "$path" "$owner" "${rest#*	}"
        else
            printf '%s\n' "$line"
        fi
    done
}

# rp_root_owned_left CASE -- prints every root-owned direct store entry and
# every root-owned entry beneath the log directory (empty when none).
rp_root_owned_left() {
    find "$1/nix/store" -mindepth 1 -maxdepth 1 -uid 0 -printf 'store:%P\n'
    [ ! -d "$1/nix/var/log/nix" ] || find "$1/nix/var/log/nix" -mindepth 1 -uid 0 -printf 'log:%P\n'
}

# rp_write_chown_stub DIR -- writes DIR/chown: a recording, FENCED chown for
# the root runner. Every call appends its argv to $RP_CHOWN_LOG as one line,
# each argument in brackets. It refuses -- appends "REFUSED <why>", changes
# nothing, exits 97 -- any symlink-following option (-L, -H, --dereference)
# and any path operand that is not strictly inside $RP_FENCE (or that
# contains ".."). Operands containing $RP_CHOWN_FAIL_MATCH (when set) are left
# unchanged and make the call exit 1, as a real chown does when it cannot
# change one of its operands; every other operand goes to the real chown,
# $RP_REAL_CHOWN, with the same options.
rp_write_chown_stub() {
    mkdir -p "$1"
    cat > "$1/chown" <<'RP_CHOWN_STUB'
#!/usr/bin/env bash
record=""
for a in "$@"; do record="$record[$a]"; done
printf '%s\n' "$record" >> "$RP_CHOWN_LOG"
refuse() { printf 'REFUSED %s\n' "$1" >> "$RP_CHOWN_LOG"; exit 97; }
opts=()
ops=()
owner=""
have_ref=no
after_dd=no
for a in "$@"; do
    if [ "$after_dd" = no ]; then
        case "$a" in
            --) after_dd=yes; continue ;;
            --dereference) refuse "$a" ;;
            --reference=*) have_ref=yes; opts+=("$a"); continue ;;
            --*) opts+=("$a"); continue ;;
            -*) case "$a" in *L*|*H*) refuse "$a" ;; esac; opts+=("$a"); continue ;;
        esac
    fi
    if [ "$have_ref" = no ] && [ -z "$owner" ]; then owner="$a"; continue; fi
    ops+=("$a")
done
failed=no
keep=()
for p in "${ops[@]}"; do
    case "$p" in "$RP_FENCE"/?*) ;; *) refuse "outside the fence: $p" ;; esac
    case "$p" in *..*) refuse "dot-dot: $p" ;; esac
    if [ -n "${RP_CHOWN_FAIL_MATCH:-}" ]; then
        case "$p" in *"$RP_CHOWN_FAIL_MATCH"*) failed=yes; continue ;; esac
    fi
    keep+=("$p")
done
[ "${#ops[@]}" -gt 0 ] || refuse "no path operand"
rc=0
if [ "${#keep[@]}" -gt 0 ]; then
    if [ "$have_ref" = yes ]; then
        "$RP_REAL_CHOWN" "${opts[@]}" -- "${keep[@]}" || rc=$?
    else
        "$RP_REAL_CHOWN" "${opts[@]}" -- "$owner" "${keep[@]}" || rc=$?
    fi
fi
[ "$failed" = no ] || exit 1
exit "$rc"
RP_CHOWN_STUB
    chmod 0755 "$1/chown"
}

# rp_chown_calls -- number of chown calls recorded in $RP_CHOWN_LOG.
rp_chown_calls() {
    local n=0 line
    [ -f "$RP_CHOWN_LOG" ] || { echo 0; return 0; }
    while IFS= read -r line; do
        case "$line" in REFUSED*) ;; *) n=$((n + 1)) ;; esac
    done < "$RP_CHOWN_LOG"
    echo "$n"
}

# rp_chown_refused -- true when the stub refused anything.
rp_chown_refused() { grep '^REFUSED' "$RP_CHOWN_LOG" >/dev/null 2>&1; }

# rp_chown_operands_in_scope STORE LOG -- every recorded chown call's path
# operands lie strictly beneath STORE or strictly beneath LOG (never STORE or
# LOG themselves, never anywhere else), and no call carries a
# symlink-following option.
rp_chown_operands_in_scope() {
    local store="$1" log="$2" line rest arg owner_seen after_dd have_ref
    [ -f "$RP_CHOWN_LOG" ] || return 0
    while IFS= read -r line; do
        case "$line" in REFUSED*) return 1 ;; esac
        rest="$line"
        owner_seen=no
        after_dd=no
        have_ref=no
        case "$line" in *"[--reference="*) have_ref=yes ;; esac
        while [ -n "$rest" ]; do
            arg="${rest#\[}"
            arg="${arg%%\]*}"
            rest="${rest#*\]}"
            if [ "$after_dd" = no ]; then
                case "$arg" in
                    --) after_dd=yes; continue ;;
                    --dereference) return 1 ;;
                    --*) continue ;;
                    -*) case "$arg" in *L*|*H*) return 1 ;; esac; continue ;;
                esac
            fi
            if [ "$have_ref" = no ] && [ "$owner_seen" = no ]; then owner_seen=yes; continue; fi
            case "$arg" in
                "$store"/?*|"$log"/?*) ;;
                *) return 1 ;;
            esac
        done
    done < "$RP_CHOWN_LOG"
}
