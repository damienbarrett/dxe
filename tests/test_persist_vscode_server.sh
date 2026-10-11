#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP1.4 (plans/do plan.md WP1.4; spec 5.2 items 7 and 11, 7.3; the WP1.3
# result of 2026-10-11): VS Code's Remote-SSH server runs in the guest
# through nix-ld. Acceptance tests written before the implementation; the
# implementer builds exactly this contract.
#
# Interface contract (every name, path, argument and message below is pinned):
#
#  Flake (container/dx-nixos-26.05/flake.nix)
#    - bootstrapEssentials (root's toolchain, installed at boot into
#      /nix/var/nix/profiles/per-user/root/profile) gains two plain lines,
#      one identifier per line like the rest of the list (no trailing
#      comment on the line):
#          nix-ld
#          nixLdLibraries
#      tests/test_contracts_source.sh's bootstrapEssentials parse pins both.
#    - nixLdLibraries is a perSystem let-binding,
#          pkgs.linkFarm "dx-nix-ld-libraries" { ... }   (or the list form)
#      with EXACTLY these four entries (linkFarm's `entries`):
#          share/nix-ld/lib/ld.so          = pkgs.stdenv.cc.bintools.dynamicLinker
#              (glibc's loader: <glibc>/lib/ld-linux-aarch64.so.1 on
#              aarch64-linux, <glibc>/lib/ld-linux-x86-64.so.2 on x86_64-linux)
#          share/nix-ld/lib/libstdc++.so.6 = "${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6"
#          share/nix-ld/lib/libgcc_s.so.1  = "${pkgs.stdenv.cc.cc.lib}/lib/libgcc_s.so.1"
#          share/nix-ld/lib/libz.so.1      = "${pkgs.lib.getLib pkgs.zlib}/lib/libz.so.1"
#      Where nix is installed (CI's Linux job; or this file run inside the
#      nixos/nix container), packages.<system>.bootstrap-essentials is
#      evaluated for both systems: its `paths` hold exactly one `nix-ld` and
#      one `dx-nix-ld-libraries`, and the latter's entries are exactly the
#      four above (store-path shapes checked). Without nix that part is one
#      skip.
#
#  Bootstrap step: configure_vscode_server_support
#    Defined in container/dx-nixos-26.05/bootstrap/system.sh (safe to
#    source, as today). No arguments. Runs as root on every boot.
#    Inputs:
#      P = "$(essentials_profile_store_path)" (bootstrap/common.sh), so
#          DX_ESSENTIALS_ROOT prefixes the profile lookup in tests.
#      R = "${DX_VSCODE_SERVER_ROOT:-}", a prefix for every guest path the
#          step inspects or creates (the loader path, the nix-ld library
#          directory, the /tmp marker). Production never sets it. It is
#          never added to link TARGETS (those point into P).
#    Preconditions, all checked before ANY change:
#      1. P resolves and P/libexec/nix-ld exists. The nix-ld PACKAGE is the
#         store directory two levels above that file's fully resolved path
#         (readlink -f gives <pkg>/bin/nix-ld, since nixpkgs ships
#         libexec/nix-ld -> ../bin/nix-ld). The profile itself has no
#         nix-support/ (Nix's profile builder drops it).
#      2. LOADER = the first line of <pkg>/nix-support/ldpath: an absolute
#         path whose directory is exactly /lib or /lib64
#         (/lib/ld-linux-aarch64.so.1, /lib64/ld-linux-x86-64.so.2). It is
#         never derived from uname or hard-coded (the QNAP is x86_64).
#      3. P/share/nix-ld/lib/ provides ld.so, libstdc++.so.6, libgcc_s.so.1
#         and libz.so.1 (each resolving to an existing file).
#      4. R$LOADER is absent or a symlink (dangling or not). A regular file,
#         a directory or anything else there is NEVER replaced.
#      5. R/tmp/vscode-skip-server-requirements-check is absent or a regular
#         file; a symlink there is never followed or replaced.
#      A failed precondition: exactly ONE line on stderr, starting
#      "Warning:" and containing "VS Code" and the reason's key word --
#        no profile, or no nix-ld in it        -> "nix-ld"
#        ldpath missing or not /lib|/lib64     -> "ldpath"
#        a library missing                     -> that library's name
#        non-symlink at the loader path        -> LOADER (e.g. /lib/ld-linux-aarch64.so.1)
#        unusable marker path                  -> "vscode-skip-server-requirements-check"
#      -- nothing on stdout, NOTHING changed under R, no chown call, status 0.
#    Changes:
#      6. R$LOADER becomes a symlink that resolves to the same file as
#         P/libexec/nix-ld. An existing symlink is replaced, including one
#         that points at a directory (ln -sfn; a link must never be created
#         inside that directory).
#      7. R/run/current-system/sw/share/nix-ld/lib is a real directory
#         holding exactly one symlink per library name, each resolving to
#         the same file as P/share/nix-ld/lib/<name> (stale links replaced).
#         nix-ld's built-in defaults then find ld.so and the libraries: no
#         NIX_LD* variable is needed.
#      8. R/tmp/vscode-skip-server-requirements-check is a regular file,
#         mode 0644, made root-owned with `chown root:root <marker>` (or
#         0:0), run through the `chown` on PATH (the tests record it; never
#         `install -o/-g`, which a non-root test run cannot record). R/tmp
#         is assumed to exist; it is never created, removed or re-moded.
#      Every directory the step creates (the loader's directory, and
#      R/run/current-system ... /nix-ld/lib) is mode 0755 whatever the
#      caller's umask: the VS Code server runs as dx and must traverse them.
#      chown is only ever used to give root ownership, never with -R, and
#      only on paths under R.
#      Success: exactly ONE line on stdout containing
#      "VS Code server support" and LOADER; nothing on stderr; status 0.
#      A failure while making the changes (e.g. R/run is a regular file):
#      exactly ONE "Warning:" line naming "VS Code" on stderr, no stdout,
#      status 0 -- VS Code support is optional and boot continues.
#      Idempotent: a second run gives the same tree and the same one line.
#    The step is always called under `set -euo pipefail` (bootstrap.sh's
#    own options) and must never abort its caller. It must also run on
#    macOS (this suite runs there under /bin/bash 3.2): `ln -sfn` (no GNU
#    -T), `readlink -f`, no Bash 4 syntax. The suite puts recording stubs
#    first on PATH: chown (records, changes nothing) and ln, rm, mv, chmod,
#    mkdir, touch, install, cp, find (record, and refuse any absolute path
#    outside the case's fixture -- for ln only the destination), plus a
#    uname that reports the OTHER architecture for -m.
#
#  Boot sequence (bootstrap.sh bootstrap_phases): called exactly once,
#    immediately after configure_ssh and before configure_guest (pinned in
#    tests/test_section3_bootstrap.sh's phase-order case). The call site
#    tolerates failure the way activation.sh treats dx_activate_herdr:
#        configure_vscode_server_support || echo "Warning: ... VS Code ..." >&2
#    i.e. if it ever returns non-zero, bootstrap_phases prints one
#    "Warning:" line naming "VS Code" on stderr and runs the remaining
#    phases; when it returns 0 the call site prints nothing.
#
#  Docs: docs/guest.md's "## Browsing /persist from the Mac" section names
#    nix-ld, the "first connection" and the server "download"
#    (tests/test_persist_mac_access_docs.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP1.4: VS Code server support in the guest (nix-ld)"

BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$BOOTSTRAP_DIR/common.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/system.sh
source "$BOOTSTRAP_DIR/system.sh"

MARKER_NAME=vscode-skip-server-requirements-check
LIB_SUBDIR=run/current-system/sw/share/nix-ld/lib
LIB_NAMES="ld.so libgcc_s.so.1 libstdc++.so.6 libz.so.1"

# The real tools, resolved before any stub directory reaches PATH.
REAL_UNAME="$(command -v uname)"
REAL_NIX="$(command -v nix 2>/dev/null || true)"

# The REAL /tmp marker must not appear because of this suite (an
# implementation that ignored DX_VSCODE_SERVER_ROOT would write it).
REAL_MARKER_PRESENT_BEFORE=no
if [ -e "/tmp/$MARKER_NAME" ] || [ -L "/tmp/$MARKER_NAME" ]; then REAL_MARKER_PRESENT_BEFORE=yes; fi

# Fixtures are built under a known umask, and WORK is canonical (pwd -P: no
# "//" and no /var vs /private/var difference), so a path the step derives
# with readlink -f compares equal to the one the suite built.
umask 022
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxe-vscode-server.XXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)" || exit 1
case "$WORK" in
    /*/dxe-vscode-server.*) : ;;
    *) echo "unexpected scratch dir [$WORK]" >&2; exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE (fixed string, one line)
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
ok() { # LABEL COMMAND... -- passes when the command succeeds
    local label="$1"; shift
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
line_count() { # FILE -- lines, counting an unterminated last line
    if [ -f "$1" ]; then awk 'END { print NR }' "$1"; else echo 0; fi
}
resolved() { # PATH -- fully resolved path, or "<unresolvable>"
    readlink -f "$1" 2>/dev/null || printf '<unresolvable>\n'
}
absent() { # PATH -- true when nothing (not even a dangling link) is there
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# ---------------------------------------------------------------------------
# Fixtures
#
# vs_case NAME -- a fresh case directory (printed): store-root/ is
# DX_ESSENTIALS_ROOT, guest-root/ is DX_VSCODE_SERVER_ROOT, bin/ holds the
# stubs, and the logs live beside them (outside both roots).
vs_case() {
    local dir
    dir="$(mktemp -d "$WORK/case-$1.XXXXXX")" || return 1
    mkdir -p "$dir/store-root" "$dir/guest-root/run" "$dir/guest-root/tmp" "$dir/bin"
    chmod 0755 "$dir/guest-root/run"
    chmod 1777 "$dir/guest-root/tmp"
    printf '%s\n' "$dir"
}

# vs_store CASE ARCH -- a Nix-store-shaped fixture with the layout the real
# guest has: nix-ld 2.0.6 (libexec/nix-ld -> ../bin/nix-ld, nix-support/
# ldpath), glibc/gcc-lib/zlib outputs, the dx-nix-ld-libraries link farm,
# a buildEnv-shaped dx-bootstrap-essentials and a nix-profile-shaped
# generation (no nix-support/ in it) behind per-user/root/profile. A decoy
# nix-ld package that sorts first in the store is NOT in the profile.
vs_store() {
    local a="$1/store-root" arch="$2" loader ldpath
    case "$arch" in
        aarch64) loader=ld-linux-aarch64.so.1; ldpath=/lib/ld-linux-aarch64.so.1 ;;
        *) loader=ld-linux-x86-64.so.2; ldpath=/lib64/ld-linux-x86-64.so.2 ;;
    esac
    local store="$a/nix/store"
    local decoy="$store/0000decoy-nix-ld-1.0.0"
    local nixld="$store/1111aaaa-nix-ld-2.0.6"
    local glibc="$store/2222bbbb-glibc-2.42-67"
    local gcc="$store/3333cccc-gcc-15.2.0-lib"
    local zlib="$store/4444dddd-zlib-1.3.2"
    local libset="$store/5555eeee-dx-nix-ld-libraries"
    local ess="$store/6666ffff-dx-bootstrap-essentials"
    local gen="$store/7777gggg-profile"
    local profiles="$a/nix/var/nix/profiles/per-user/root"
    mkdir -p "$decoy/bin" "$decoy/libexec" "$decoy/nix-support" \
        "$nixld/bin" "$nixld/libexec" "$nixld/nix-support" \
        "$glibc/lib" "$gcc/lib" "$zlib/lib" "$libset/share/nix-ld/lib" \
        "$ess/bin" "$ess/libexec" "$ess/share" "$gen" "$profiles"
    printf 'decoy nix-ld\n' > "$decoy/bin/nix-ld"
    ln -s ../bin/nix-ld "$decoy/libexec/nix-ld"
    printf '/lib/ld-decoy.so.1\n' > "$decoy/nix-support/ldpath"
    printf 'fake nix-ld 2.0.6 (%s)\n' "$arch" > "$nixld/bin/nix-ld"
    chmod 0755 "$nixld/bin/nix-ld"
    ln -s ../bin/nix-ld "$nixld/libexec/nix-ld"
    printf '%s\n' "$ldpath" > "$nixld/nix-support/ldpath"
    printf 'fake glibc loader (%s)\n' "$arch" > "$glibc/lib/$loader"
    printf 'fake libstdc++\n' > "$gcc/lib/libstdc++.so.6.0.34"
    ln -s libstdc++.so.6.0.34 "$gcc/lib/libstdc++.so.6"
    printf 'fake libgcc_s\n' > "$gcc/lib/libgcc_s.so.1"
    printf 'fake zlib\n' > "$zlib/lib/libz.so.1.3.2"
    ln -s libz.so.1.3.2 "$zlib/lib/libz.so.1"
    ln -s "$glibc/lib/$loader" "$libset/share/nix-ld/lib/ld.so"
    ln -s "$gcc/lib/libstdc++.so.6" "$libset/share/nix-ld/lib/libstdc++.so.6"
    ln -s "$gcc/lib/libgcc_s.so.1" "$libset/share/nix-ld/lib/libgcc_s.so.1"
    ln -s "$zlib/lib/libz.so.1" "$libset/share/nix-ld/lib/libz.so.1"
    ln -s "$nixld/bin/nix-ld" "$ess/bin/nix-ld"
    ln -s "$nixld/libexec/nix-ld" "$ess/libexec/nix-ld"
    ln -s "$libset/share/nix-ld" "$ess/share/nix-ld"
    ln -s "$ess/bin" "$gen/bin"
    ln -s "$ess/libexec" "$gen/libexec"
    ln -s "$ess/share" "$gen/share"
    printf '{"elements":{},"version":3}\n' > "$gen/manifest.json"
    ln -s "$gen" "$profiles/profile-1-link"
    ln -s profile-1-link "$profiles/profile"
}

# The fixture's resolved profile generation (what essentials_profile_store_path
# returns for it).
vs_profile() { resolved "$1/store-root/nix/var/nix/profiles/per-user/root/profile"; }
vs_nixld_pkg() { printf '%s\n' "$1/store-root/nix/store/1111aaaa-nix-ld-2.0.6"; }

# vs_stubs CASE OTHER_ARCH -- the recording stubs (see the contract).
vs_stubs() {
    local dir="$1" other_arch="$2" bin="$1/bin" dir_real tool real
    dir_real="$(cd "$dir" && pwd -P)"
    cat > "$bin/confine.sh" <<'CONFINE'
#!/usr/bin/env bash
# confine.sh TOOL REAL CASE CASE_REAL ARGS... -- record, then run the real
# tool only if every absolute path it is given (ln: its destination) lies
# inside this case's fixture.
tool="$1"; real="$2"; case_dir="$3"; case_real="$4"; shift 4
printf '%s %s\n' "$tool" "$*" >> "$case_dir/calls.log"
inside() {
    case "$1" in
        "$case_dir"|"$case_dir"/*|"$case_real"|"$case_real"/*) return 0 ;;
    esac
    return 1
}
if [ "$tool" = ln ]; then
    last=""
    for arg in "$@"; do last="$arg"; done
    set -- "$last"
fi
for arg in "$@"; do
    case "$arg" in
        /*)
            if ! inside "$arg"; then
                printf 'REFUSED %s %s\n' "$tool" "$arg" >> "$case_dir/calls.log"
                echo "confine: refusing $tool outside the fixture: $arg" >&2
                exit 97
            fi
            ;;
    esac
done
exit 0
CONFINE
    chmod 0755 "$bin/confine.sh"
    for tool in ln rm mv chmod mkdir touch install cp find; do
        real="$(command -v "$tool")"
        printf '#!/usr/bin/env bash\nbash %q %q %q %q %q "$@" || exit $?\nexec %q "$@"\n' \
            "$bin/confine.sh" "$tool" "$real" "$dir" "$dir_real" "$real" > "$bin/$tool"
        chmod 0755 "$bin/$tool"
    done
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexit 0\n' "$dir/chown.log" > "$bin/chown"
    chmod 0755 "$bin/chown"
    printf '#!/usr/bin/env bash\nif [ "${1:-}" = -m ]; then echo %q; exit 0; fi\nexec %q "$@"\n' \
        "$other_arch" "$REAL_UNAME" > "$bin/uname"
    chmod 0755 "$bin/uname"
}

# vs_snapshot DIR -- every entry under DIR: path, type, mode and content
# checksum or link text. Two equal snapshots mean nothing changed.
vs_snapshot() {
    (
        cd "$1" || exit 1
        find . -print | LC_ALL=C sort | while IFS= read -r entry; do
            if [ -L "$entry" ]; then
                printf '%s L %s\n' "$entry" "$(readlink "$entry")"
            elif [ -d "$entry" ]; then
                printf '%s D %s\n' "$entry" "$(file_mode "$entry")"
            elif [ -f "$entry" ]; then
                printf '%s F %s %s\n' "$entry" "$(file_mode "$entry")" "$(cksum < "$entry")"
            else
                printf '%s O\n' "$entry"
            fi
        done
    )
}

# vs_run CASE [UMASK] -- one configure_vscode_server_support call, the way
# bootstrap makes it (errexit, nounset, pipefail), stubs first on PATH.
# Sets VS_RC, VS_OUT, VS_ERR and VS_CONTINUED (yes when the caller went on
# after the call). Call it as a plain statement: an if/||/&& context would
# switch errexit off inside it.
vs_run() {
    local dir="$1" mask="${2:-022}"
    : > "$dir/stdout"
    : > "$dir/stderr"
    rm -f "$dir/continued"
    (
        set -euo pipefail
        umask "$mask"
        PATH="$dir/bin:$PATH"
        DX_ESSENTIALS_ROOT="$dir/store-root"
        DX_VSCODE_SERVER_ROOT="$dir/guest-root"
        export DX_ESSENTIALS_ROOT DX_VSCODE_SERVER_ROOT
        for tool in ln rm mv chmod mkdir touch install cp find chown uname; do
            if [ "$(command -v "$tool")" != "$dir/bin/$tool" ]; then
                echo "interlock: the $tool stub does not resolve first; not running" >&2
                exit 98
            fi
        done
        configure_vscode_server_support
        printf 'yes\n' > "$dir/continued"
    ) > "$dir/stdout" 2> "$dir/stderr"
    VS_RC=$?
    VS_OUT="$(cat "$dir/stdout")"
    VS_ERR="$(cat "$dir/stderr")"
    VS_CONTINUED=no
    if [ -f "$dir/continued" ]; then
        VS_CONTINUED=yes
    fi
}

# chown_ok CASE MARKER -- the recorded chown calls give root ownership only
# (root:root, 0:0, root or 0), never recursively, only to paths under the
# guest root, and include the marker. Prints the first violation.
chown_check() {
    local dir="$1" marker="$2" log="$1/chown.log" guest guest_real line word owner saw_marker=no
    guest="$dir/guest-root"
    guest_real="$(cd "$guest" && pwd -P)"
    if [ ! -s "$log" ]; then
        echo "no chown was recorded"
        return 0
    fi
    while IFS= read -r line; do
        owner=""
        for word in $line; do
            case "$word" in
                -R|-[a-zA-Z]*R*|--recursive) echo "recursive chown: $line"; return 0 ;;
                --) : ;;
                -*) : ;;
                *)
                    if [ -z "$owner" ]; then
                        owner="$word"
                        case "$owner" in
                            root:root|0:0|root|0) : ;;
                            *) echo "chown to a non-root owner: $line"; return 0 ;;
                        esac
                    else
                        case "$word" in
                            "$guest"/*|"$guest_real"/*) : ;;
                            *) echo "chown outside the guest root: $line"; return 0 ;;
                        esac
                        if [ "$word" = "$marker" ] || [ "$word" = "$guest_real/tmp/$MARKER_NAME" ]; then
                            case "$owner" in root:root|0:0) saw_marker=yes ;; esac
                        fi
                    fi
                    ;;
            esac
        done
    done < "$log"
    [ "$saw_marker" = yes ] || echo "the marker was never chowned root:root (log: $(tr '\n' ';' < "$log"))"
}

# vs_assert_refused LABEL CASE KEYWORD BEFORE_SNAPSHOT -- a failed
# precondition: one Warning line, nothing changed, the boot goes on.
vs_assert_refused() {
    local label="$1" dir="$2" keyword="$3" before="$4"
    eq "$label: status 0" 0 "$VS_RC"
    eq "$label: the caller continues under errexit" yes "$VS_CONTINUED"
    eq "$label: nothing on stdout" "" "$VS_OUT"
    eq "$label: exactly one line on stderr" 1 "$(line_count "$dir/stderr")"
    case "$VS_ERR" in
        Warning:*) test_pass "$label: the line starts with Warning:" ;;
        *) test_fail "$label: the line starts with Warning: (got [$VS_ERR])" ;;
    esac
    has "$label: the warning names VS Code" "$VS_ERR" "VS Code"
    has "$label: the warning names $keyword" "$VS_ERR" "$keyword"
    eq "$label: nothing under the guest root changed" "$before" "$(vs_snapshot "$dir/guest-root")"
    eq "$label: no chown was attempted" "" "$(cat "$dir/chown.log" 2>/dev/null)"
    lacks "$label: no command was refused by the confinement stubs" "$(cat "$dir/calls.log" 2>/dev/null)" "REFUSED"
}

# vs_assert_configured LABEL CASE LOADER -- a successful run's final state.
vs_assert_configured() {
    local label="$1" dir="$2" loader="$3" guest="$2/guest-root" profile lib_dir name listing expected_listing
    profile="$(vs_profile "$dir")"
    eq "$label: status 0" 0 "$VS_RC"
    eq "$label: the caller continues under errexit" yes "$VS_CONTINUED"
    eq "$label: nothing on stderr" "" "$VS_ERR"
    eq "$label: exactly one line on stdout" 1 "$(line_count "$dir/stdout")"
    has "$label: the line names VS Code server support" "$VS_OUT" "VS Code server support"
    has "$label: the line names the loader path" "$VS_OUT" "$loader"
    lacks "$label: the line is not a warning" "$VS_OUT" "Warning"

    ok "$label: $loader is a symlink" test -L "$guest$loader"
    eq "$label: $loader resolves to nix-ld" "$(resolved "$profile/libexec/nix-ld")" "$(resolved "$guest$loader")"
    eq "$label: the loader's directory is 0755" 755 "$(file_mode "$(dirname "$guest$loader")" 2>/dev/null)"

    lib_dir="$guest/$LIB_SUBDIR"
    if [ -d "$lib_dir" ] && [ ! -L "$lib_dir" ]; then
        test_pass "$label: /$LIB_SUBDIR is a real directory"
    else
        test_fail "$label: /$LIB_SUBDIR is a real directory"
    fi
    listing="$(cd "$lib_dir" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' ' ')"
    expected_listing="$(printf '%s\n' $LIB_NAMES | LC_ALL=C sort | tr '\n' ' ')"
    eq "$label: the nix-ld library directory holds exactly the four libraries" "$expected_listing" "$listing"
    for name in $LIB_NAMES; do
        ok "$label: $name is a symlink" test -L "$lib_dir/$name"
        eq "$label: $name resolves to the library set's $name" \
            "$(resolved "$profile/share/nix-ld/lib/$name")" "$(resolved "$lib_dir/$name")"
    done
    for name in run/current-system run/current-system/sw run/current-system/sw/share \
        run/current-system/sw/share/nix-ld "$LIB_SUBDIR"; do
        eq "$label: /$name is 0755" 755 "$(file_mode "$guest/$name" 2>/dev/null)"
    done

    if [ -f "$guest/tmp/$MARKER_NAME" ] && [ ! -L "$guest/tmp/$MARKER_NAME" ]; then
        test_pass "$label: the skip-requirements marker is a regular file"
    else
        test_fail "$label: the skip-requirements marker is a regular file"
    fi
    eq "$label: the marker is 0644" 644 "$(file_mode "$guest/tmp/$MARKER_NAME" 2>/dev/null)"
    eq "$label: chown gives root ownership only, never -R, and covers the marker" "" \
        "$(chown_check "$dir" "$guest/tmp/$MARKER_NAME")"
    lacks "$label: no command was refused by the confinement stubs" "$(cat "$dir/calls.log" 2>/dev/null)" "REFUSED"
}

# ---------------------------------------------------------------------------
test_section "WP1.4: the bootstrap step exists where bootstrap.sh sources it"

if (
    # shellcheck source=../container/dx-nixos-26.05/bootstrap/system.sh
    source "$BOOTSTRAP_DIR/system.sh"
    declare -F configure_vscode_server_support >/dev/null
); then
    test_pass "bootstrap/system.sh defines configure_vscode_server_support"
else
    test_fail "bootstrap/system.sh defines configure_vscode_server_support"
fi

# ---------------------------------------------------------------------------
test_section "WP1.4: aarch64 boot links nix-ld, the libraries and the marker"

C="$(vs_case arm)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
RUN_MODE_BEFORE="$(file_mode "$C/guest-root/run")"
TMP_MODE_BEFORE="$(file_mode "$C/guest-root/tmp")"
vs_run "$C" 077
vs_assert_configured "aarch64" "$C" /lib/ld-linux-aarch64.so.1
ok "aarch64: no /lib64 was created (the loader path comes from ldpath)" absent "$C/guest-root/lib64"
ok "aarch64: the decoy nix-ld package's ldpath was not used" absent "$C/guest-root/lib/ld-decoy.so.1"
eq "aarch64: /run keeps its mode" "$RUN_MODE_BEFORE" "$(file_mode "$C/guest-root/run")"
eq "aarch64: /tmp keeps its mode" "$TMP_MODE_BEFORE" "$(file_mode "$C/guest-root/tmp")"
case "$(readlink "$C/guest-root/lib/ld-linux-aarch64.so.1" 2>/dev/null)" in
    "$C/guest-root"/*) test_fail "aarch64: the loader link targets the profile, not the guest root" ;;
    *) test_pass "aarch64: the loader link targets the profile, not the guest root" ;;
esac

# Idempotent: a second boot leaves the same tree and logs the same line.
FIRST_OUT="$VS_OUT"
AFTER_FIRST="$(vs_snapshot "$C/guest-root")"
: > "$C/chown.log"
vs_run "$C"
eq "second run: status 0" 0 "$VS_RC"
eq "second run: the caller continues under errexit" yes "$VS_CONTINUED"
eq "second run: nothing on stderr" "" "$VS_ERR"
eq "second run: the same single summary line" "$FIRST_OUT" "$VS_OUT"
eq "second run: exactly one line on stdout" 1 "$(line_count "$C/stdout")"
eq "second run: the guest tree is unchanged" "$AFTER_FIRST" "$(vs_snapshot "$C/guest-root")"

# ---------------------------------------------------------------------------
test_section "WP1.4: x86_64 boot uses /lib64 from nix-ld's ldpath"

C="$(vs_case x86)"
vs_store "$C" x86_64
vs_stubs "$C" aarch64
vs_run "$C" 077
vs_assert_configured "x86_64" "$C" /lib64/ld-linux-x86-64.so.2
ok "x86_64: no /lib was created (uname -m says aarch64; ldpath wins)" absent "$C/guest-root/lib"

# ---------------------------------------------------------------------------
test_section "WP1.4: stale links from an earlier boot are replaced"

C="$(vs_case stale)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib" "$C/guest-root/stale-dir" "$C/guest-root/$LIB_SUBDIR"
ln -s "$C/guest-root/stale-dir" "$C/guest-root/lib/ld-linux-aarch64.so.1"
printf 'old zlib\n' > "$C/guest-root/old-libz"
ln -s "$C/guest-root/old-libz" "$C/guest-root/$LIB_SUBDIR/libz.so.1"
printf 'left by dx\n' > "$C/guest-root/tmp/$MARKER_NAME"
chmod 0600 "$C/guest-root/tmp/$MARKER_NAME"
vs_run "$C"
vs_assert_configured "stale" "$C" /lib/ld-linux-aarch64.so.1
eq "stale: nothing was created inside the directory the old loader link pointed at" "" \
    "$(ls -A "$C/guest-root/stale-dir" 2>&1)"
eq "stale: the file the old libz link pointed at is untouched" "old zlib" "$(cat "$C/guest-root/old-libz" 2>&1)"

C="$(vs_case dangling)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib"
ln -s "$C/store-root/nix/store/9999gone-nix-ld-1.0/libexec/nix-ld" "$C/guest-root/lib/ld-linux-aarch64.so.1"
vs_run "$C"
vs_assert_configured "dangling" "$C" /lib/ld-linux-aarch64.so.1

# ---------------------------------------------------------------------------
test_section "WP1.4: a failed precondition warns, changes nothing, and boot goes on"

C="$(vs_case noprofile)"
vs_stubs "$C" x86_64
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "no essentials profile" "$C" "nix-ld" "$BEFORE"

C="$(vs_case nonixld)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
rm -f "$C/store-root/nix/store/6666ffff-dx-bootstrap-essentials/libexec/nix-ld" \
    "$C/store-root/nix/store/6666ffff-dx-bootstrap-essentials/bin/nix-ld"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "nix-ld not in the profile" "$C" "nix-ld" "$BEFORE"

C="$(vs_case noldpath)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
rm -f "$(vs_nixld_pkg "$C")/nix-support/ldpath"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "ldpath missing" "$C" "ldpath" "$BEFORE"

for bad_ldpath in lib/ld-linux-aarch64.so.1 /etc/ld-linux-aarch64.so.1 /lib/../etc/ld-linux-aarch64.so.1; do
    C="$(vs_case badldpath)"
    vs_store "$C" aarch64
    vs_stubs "$C" x86_64
    printf '%s\n' "$bad_ldpath" > "$(vs_nixld_pkg "$C")/nix-support/ldpath"
    BEFORE="$(vs_snapshot "$C/guest-root")"
    vs_run "$C"
    vs_assert_refused "ldpath $bad_ldpath" "$C" "ldpath" "$BEFORE"
done

C="$(vs_case nolibstdcxx)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
rm -f "$C/store-root/nix/store/5555eeee-dx-nix-ld-libraries/share/nix-ld/lib/libstdc++.so.6"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "libstdc++ missing from the library set" "$C" "libstdc++.so.6" "$BEFORE"

C="$(vs_case realloader)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib"
printf 'a real glibc loader\n' > "$C/guest-root/lib/ld-linux-aarch64.so.1"
chmod 0755 "$C/guest-root/lib/ld-linux-aarch64.so.1"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a regular file at the loader path" "$C" "/lib/ld-linux-aarch64.so.1" "$BEFORE"
eq "a regular file at the loader path: its content is untouched" "a real glibc loader" \
    "$(cat "$C/guest-root/lib/ld-linux-aarch64.so.1" 2>&1)"

C="$(vs_case loaderdir)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib/ld-linux-aarch64.so.1"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a directory at the loader path" "$C" "/lib/ld-linux-aarch64.so.1" "$BEFORE"

C="$(vs_case markerlink)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/etc"
printf 'secret\n' > "$C/guest-root/etc/shadow"
chmod 0600 "$C/guest-root/etc/shadow"
ln -s "$C/guest-root/etc/shadow" "$C/guest-root/tmp/$MARKER_NAME"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a symlink at the marker path" "$C" "$MARKER_NAME" "$BEFORE"
eq "a symlink at the marker path: its target keeps mode 0600" 600 "$(file_mode "$C/guest-root/etc/shadow")"

# ---------------------------------------------------------------------------
test_section "WP1.4: a failure while linking is a warning, not a boot failure"

C="$(vs_case runfile)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
rmdir "$C/guest-root/run"
printf 'not a directory\n' > "$C/guest-root/run"
vs_run "$C"
eq "run is a file: status 0" 0 "$VS_RC"
eq "run is a file: the caller continues under errexit" yes "$VS_CONTINUED"
eq "run is a file: nothing on stdout" "" "$VS_OUT"
eq "run is a file: exactly one line on stderr" 1 "$(line_count "$C/stderr")"
case "$VS_ERR" in
    Warning:*) test_pass "run is a file: the line starts with Warning:" ;;
    *) test_fail "run is a file: the line starts with Warning: (got [$VS_ERR])" ;;
esac
has "run is a file: the warning names VS Code" "$VS_ERR" "VS Code"
eq "run is a file: the file is untouched" "not a directory" "$(cat "$C/guest-root/run" 2>&1)"
lacks "run is a file: no command was refused by the confinement stubs" "$(cat "$C/calls.log" 2>/dev/null)" "REFUSED"

# ---------------------------------------------------------------------------
test_section "WP1.4: bootstrap_phases runs it after configure_ssh and survives a failure"

# vs_phases CASE RC -- bootstrap_phases with every phase shadowed by a
# logger (nothing real runs) and configure_vscode_server_support returning
# RC, under bootstrap.sh's own shell options.
vs_phases() {
    local dir="$1" rc="$2"
    : > "$dir/phases.log"
    (
        set -euo pipefail
        # shellcheck source=../container/dx-nixos-26.05/bootstrap.sh
        source "$BOOTSTRAP"
        vs_log_phase() { printf '%s\n' "$1" >> "$dir/phases.log"; }
        dx_read_durable_identity_record() { :; }
        configure_single_user_nix() { vs_log_phase "${FUNCNAME[0]}"; }
        install_essentials() { vs_log_phase "${FUNCNAME[0]}"; }
        link_system_bash() { vs_log_phase "${FUNCNAME[0]}"; }
        capture_nix_image_default_profile() { vs_log_phase "${FUNCNAME[0]}"; }
        prepare_nix_volume() { vs_log_phase "${FUNCNAME[0]}"; }
        materialize_auth_files() { vs_log_phase "${FUNCNAME[0]}"; }
        create_user() { vs_log_phase "${FUNCNAME[0]}"; }
        populate_prepared_nix_volume() { vs_log_phase "${FUNCNAME[0]}"; }
        verify_remount_prerequisites() { vs_log_phase "${FUNCNAME[0]}"; }
        nix_restore_image_default_profile() { vs_log_phase "${FUNCNAME[0]}"; }
        ensure_essentials_valid() { vs_log_phase "${FUNCNAME[0]}"; }
        publish_nix_image_store_identity() { vs_log_phase "${FUNCNAME[0]}"; }
        configure_release_identity() { vs_log_phase "${FUNCNAME[0]}"; }
        setup_persist() { vs_log_phase "${FUNCNAME[0]}"; }
        configure_ssh() { vs_log_phase "${FUNCNAME[0]}"; }
        configure_vscode_server_support() { vs_log_phase "${FUNCNAME[0]}"; return "$rc"; }
        configure_guest() { vs_log_phase "${FUNCNAME[0]}"; }
        verify_guest_tools() { vs_log_phase "${FUNCNAME[0]}"; }
        configure_timezone() { vs_log_phase "${FUNCNAME[0]}"; }
        bootstrap_phases
        vs_log_phase after-bootstrap_phases
    ) > "$dir/stdout" 2> "$dir/stderr"
    VS_RC=$?
    VS_OUT="$(cat "$dir/stdout")"
    VS_ERR="$(cat "$dir/stderr")"
}
PHASES_EXPECTED="configure_single_user_nix
install_essentials
link_system_bash
capture_nix_image_default_profile
prepare_nix_volume
materialize_auth_files
create_user
populate_prepared_nix_volume
verify_remount_prerequisites
nix_restore_image_default_profile
ensure_essentials_valid
publish_nix_image_store_identity
configure_release_identity
setup_persist
configure_ssh
configure_vscode_server_support
configure_guest
verify_guest_tools
configure_timezone
after-bootstrap_phases"

C="$(vs_case phases-ok)"
vs_phases "$C" 0
eq "phases (step succeeds): bootstrap_phases returns 0" 0 "$VS_RC"
eq "phases (step succeeds): configure_vscode_server_support runs once, right after configure_ssh" \
    "$PHASES_EXPECTED" "$(cat "$C/phases.log")"
eq "phases (step succeeds): the call site adds nothing on stderr" "" "$VS_ERR"

C="$(vs_case phases-fail)"
vs_phases "$C" 1
eq "phases (step fails): bootstrap_phases still returns 0" 0 "$VS_RC"
eq "phases (step fails): every later phase still runs" "$PHASES_EXPECTED" "$(cat "$C/phases.log")"
eq "phases (step fails): exactly one line on stderr" 1 "$(line_count "$C/stderr")"
case "$VS_ERR" in
    Warning:*) test_pass "phases (step fails): the line starts with Warning:" ;;
    *) test_fail "phases (step fails): the line starts with Warning: (got [$VS_ERR])" ;;
esac
has "phases (step fails): the warning names VS Code" "$VS_ERR" "VS Code"

# ---------------------------------------------------------------------------
test_section "WP1.4: the flake's root toolchain holds nix-ld and the library set"

# Evaluated, never built: --apply reads buildEnv's `paths` and linkFarm's
# `entries`, both plain attributes.
VS_NIX_APPLY='d: let
  pname = p: (builtins.parseDrvName p.name).name;
  sets = builtins.filter (p: pname p == "dx-nix-ld-libraries") d.paths;
  entries = if sets == [ ] then { } else ((builtins.head sets).entries or { });
in builtins.concatStringsSep "\n" (
  (map (p: "package " + pname p) d.paths)
  ++ (builtins.attrValues (builtins.mapAttrs
    (k: v: "entry " + k + " " + builtins.unsafeDiscardStringContext (toString v)) entries)))'

if [ -n "$REAL_NIX" ]; then
    for system in aarch64-linux x86_64-linux; do
        case "$system" in
            aarch64-linux) loader=ld-linux-aarch64.so.1 ;;
            *) loader=ld-linux-x86-64.so.2 ;;
        esac
        if nix_out="$("$REAL_NIX" --extra-experimental-features 'nix-command flakes' eval --raw --no-write-lock-file \
            "path:$CONTAINER_DIR#packages.$system.bootstrap-essentials" --apply "$VS_NIX_APPLY" 2>&1)"; then
            test_pass "packages.$system.bootstrap-essentials evaluates"
        else
            test_fail "packages.$system.bootstrap-essentials evaluates ($nix_out)"
        fi
        eq "$system: bootstrap-essentials holds nix-ld once" 1 "$(grep -Fxc 'package nix-ld' <<<"$nix_out")"
        eq "$system: bootstrap-essentials holds dx-nix-ld-libraries once" 1 \
            "$(grep -Fxc 'package dx-nix-ld-libraries' <<<"$nix_out")"
        eq "$system: the library set has exactly the four entries" \
            "share/nix-ld/lib/ld.so share/nix-ld/lib/libgcc_s.so.1 share/nix-ld/lib/libstdc++.so.6 share/nix-ld/lib/libz.so.1 " \
            "$(sed -n 's/^entry \([^ ]*\) .*/\1/p' <<<"$nix_out" | LC_ALL=C sort | tr '\n' ' ')"
        entry_target() { sed -n "s#^entry share/nix-ld/lib/$1 ##p" <<<"$nix_out"; }
        ld_target="$(entry_target 'ld\.so')"
        stdcxx_target="$(entry_target 'libstdc++\.so\.6')"
        gcc_s_target="$(entry_target 'libgcc_s\.so\.1')"
        z_target="$(entry_target 'libz\.so\.1')"
        case "$ld_target" in
            /nix/store/*-glibc-*/lib/"$loader") test_pass "$system: ld.so is glibc's $loader" ;;
            *) test_fail "$system: ld.so is glibc's $loader (got [$ld_target])" ;;
        esac
        case "$stdcxx_target" in
            /nix/store/*-gcc-*-lib/lib/libstdc++.so.6) test_pass "$system: libstdc++.so.6 comes from gcc's lib output" ;;
            *) test_fail "$system: libstdc++.so.6 comes from gcc's lib output (got [$stdcxx_target])" ;;
        esac
        case "$gcc_s_target" in
            /nix/store/*-gcc-*-lib/lib/libgcc_s.so.1) test_pass "$system: libgcc_s.so.1 comes from gcc's lib output" ;;
            *) test_fail "$system: libgcc_s.so.1 comes from gcc's lib output (got [$gcc_s_target])" ;;
        esac
        if [ -n "$stdcxx_target" ] && [ "$(dirname "$stdcxx_target")" = "$(dirname "$gcc_s_target")" ]; then
            test_pass "$system: libstdc++ and libgcc_s come from the same gcc output"
        else
            test_fail "$system: libstdc++ and libgcc_s come from the same gcc output (got [$stdcxx_target] and [$gcc_s_target])"
        fi
        case "$z_target" in
            /nix/store/*-zlib-*/lib/libz.so.1) test_pass "$system: libz.so.1 comes from zlib" ;;
            *) test_fail "$system: libz.so.1 comes from zlib (got [$z_target])" ;;
        esac
    done
else
    test_skip "nix is not available; the nix-ld flake entries are evaluated by CI's Linux job (or this file run in the nixos/nix container)"
fi

# ---------------------------------------------------------------------------
test_section "WP1.4: the suite stayed inside its fixtures"

REAL_MARKER_PRESENT_AFTER=no
if [ -e "/tmp/$MARKER_NAME" ] || [ -L "/tmp/$MARKER_NAME" ]; then REAL_MARKER_PRESENT_AFTER=yes; fi
if [ "$REAL_MARKER_PRESENT_BEFORE" = no ] && [ "$REAL_MARKER_PRESENT_AFTER" = yes ]; then
    test_fail "the real /tmp/$MARKER_NAME was not created (DX_VSCODE_SERVER_ROOT was ignored; remove it by hand)"
else
    test_pass "the real /tmp/$MARKER_NAME was not created"
fi

print_summary
exit_with_code
